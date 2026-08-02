// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ForkBase } from "./ForkBase.t.sol";
import { BscAddresses } from "../../src/config/BscAddresses.sol";
import { UnifiedGridManager } from "../../src/core/UnifiedGridManager.sol";
import { FlapYieldAdapter } from "../../src/adapters/FlapYieldAdapter.sol";
import { CreateGridParams } from "../../src/libraries/GridTypes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Fork test for the Flap adapter (Flaunch replacement) against the real Flap
///         Portal/VaultPortal addresses on BSC. The adapter's `collectYield` best-effort claims
///         its holder dividends from the Flap token's dividendContract (try/catch) and then
///         forwards its yield-token balance to the UGM via an authoritative balance sweep. Here
///         the Flap token is an EOA stand-in with no `dividendContract()`, so the claim try/catch
///         falls through to 0 and the sweep does the work — mirroring fees routed to the adapter
///         as the fee recipient — and we assert they flow through to grid seats. See DECISIONS D12.
contract FlapAdapterForkTest is ForkBase {
    UnifiedGridManager internal ugm;
    FlapYieldAdapter internal adapter;

    address internal flapToken = makeAddr("flapTaxToken");

    function setUp() public {
        _forkBsc();
        ugm = new UnifiedGridManager(address(this), 0, 0, 0);
        adapter = new FlapYieldAdapter(
            address(ugm), BscAddresses.FLAP_PORTAL, BscAddresses.FLAP_VAULT_PORTAL, address(this)
        );
        ugm.setApprovedAdapter(address(adapter), true);
        ugm.setAllowedTaxToken(BscAddresses.WBNB, true);
    }

    function test_CollectYieldForwardsAccruedFlapFees() public {
        uint256 gridId = ugm.createGrid(
            CreateGridParams({
                totalSeats: 4,
                taxRateBps: 500,
                forfeitureDuration: 0,
                taxToken: BscAddresses.WBNB,
                yieldToken: BscAddresses.WBNB,
                initialPrice: 1 ether
            })
        );

        bytes32 assetHash = adapter.registerFlapToken(gridId, flapToken, BscAddresses.WBNB);
        assertTrue(adapter.isAssetRegistered(assetHash));
        // The EOA stand-in exposes no dividendContract(), so none was stored.
        assertEq(adapter.dividendContractOf(assetHash), address(0), "no dividendContract for EOA token");
        // pendingYield reads the (absent) dividendContract best-effort and never reverts -> 0.
        assertEq(adapter.pendingYield(assetHash), 0, "pendingYield 0 without a dividendContract");

        // Simulate Flap trading-tax revenue routed to the adapter (as the dividend/fee recipient).
        _mintWBNB(address(adapter), 3 ether);

        // collectYield() best-effort claims the dividendContract (caught) then sweeps the balance.
        uint256 ugmBefore = IERC20(address(WBNB)).balanceOf(address(ugm));
        uint256 forwarded = adapter.collectYield(assetHash);

        assertEq(forwarded, 3 ether, "adapter forwards accrued fees");
        assertEq(IERC20(address(WBNB)).balanceOf(address(ugm)) - ugmBefore, 3 ether);
        assertEq(ugm.pendingYieldSeat(gridId, 0), 0.75 ether, "3 WBNB across 4 seats");

        // Idempotency: a second collectYield with no new fees forwards 0.
        uint256 forwarded2 = adapter.collectYield(assetHash);
        assertEq(forwarded2, 0, "2nd collectYield with no activity forwards 0");
        assertEq(IERC20(address(WBNB)).balanceOf(address(ugm)) - ugmBefore, 3 ether, "UGM unchanged by idempotent call");
    }
}
