// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ForkBase } from "./ForkBase.t.sol";
import { BscAddresses } from "../../src/config/BscAddresses.sol";
import { UnifiedGridManager } from "../../src/core/UnifiedGridManager.sol";
import { FlapYieldAdapter } from "../../src/adapters/FlapYieldAdapter.sol";
import { CreateGridParams } from "../../src/libraries/GridTypes.sol";
import { DividendVault } from "../../src/vault/DividendVault.sol";
import { VaultFactory } from "../../src/vault/VaultFactory.sol";
import { MockFlapToken } from "../mocks/MockFlapToken.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice BSC-fork proof that OUR {DividendVault} is a drop-in for a real Flap `dividendContract`
///         on the existing adapter -> grid path, with NO changes to the adapter or UGM.
///
///         Wiring mirrors production: a {VaultFactory} clone (reward = WBNB) is registered as a Flap
///         token's `dividendContract()`; the FlapYieldAdapter holds a share in the vault; WBNB is
///         distributed to the vault; and `adapter.collectYield` claims it from the vault via the
///         canonical `withdrawDividend()` selector and forwards it into the grid, where Harberger
///         seats split it and a holder realizes WBNB yield. Ties src/vault/ to the adapter/grid.
contract VaultAdapterFlowForkTest is ForkBase {
    UnifiedGridManager internal ugm;
    FlapYieldAdapter internal adapter;
    DividendVault internal implementation;
    VaultFactory internal factory;
    DividendVault internal vault;
    MockFlapToken internal flapToken;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal gridId;
    bytes32 internal assetHash;

    function setUp() public {
        _forkBsc();

        ugm = new UnifiedGridManager(address(this), 0, 0, 0);
        adapter = new FlapYieldAdapter(
            address(ugm), BscAddresses.FLAP_PORTAL, BscAddresses.FLAP_VAULT_PORTAL, address(this)
        );
        ugm.setApprovedAdapter(address(adapter), true);
        ugm.setAllowedTaxToken(BscAddresses.WBNB, true);

        // Our vault, cloned from the factory, distributing WBNB (the grid's quote/yield token).
        implementation = new DividendVault();
        factory = new VaultFactory(address(implementation));
        vault = DividendVault(factory.createVault(BscAddresses.WBNB, address(this)));

        // A Flap-token stand-in whose dividendContract() returns OUR vault and quoteToken() == WBNB.
        flapToken = new MockFlapToken(address(vault), BscAddresses.WBNB);

        gridId = ugm.createGrid(
            CreateGridParams({
                totalSeats: 4,
                taxRateBps: 500,
                forfeitureDuration: 0,
                taxToken: BscAddresses.WBNB,
                yieldToken: BscAddresses.WBNB,
                initialPrice: 1 ether
            })
        );

        // The adapter reads and stores our vault as the token's dividendContract (contract, not EOA,
        // so the adapter's code-length guard passes and it actually records it).
        assetHash = adapter.registerFlapToken(gridId, address(flapToken), BscAddresses.WBNB);
    }

    function test_OurVaultDrivesAdapterYieldToSeats() public {
        // The adapter picked up OUR vault as the dividendContract via the standard interface.
        assertEq(adapter.dividendContractOf(assetHash), address(vault), "adapter wired to our vault");

        // The adapter is entitled to dividends by holding a SHARE in the vault (mirrors holding the
        // Flap token). Sole shareholder here, so it claims the whole distribution.
        vault.setShare(address(adapter), 1);

        // Two holders take seats before yield is distributed (proven-correct ordering).
        _fundAndApprove(alice);
        _fundAndApprove(bob);
        vm.prank(alice);
        ugm.buySeat(gridId, 0, 1 ether, 50 ether, 0);
        vm.prank(bob);
        ugm.buySeat(gridId, 1, 1 ether, 50 ether, 0);

        // Flap fee revenue in WBNB is funded into the vault and distributed to shareholders.
        _mintWBNB(address(this), 4 ether);
        IERC20(address(WBNB)).approve(address(vault), 4 ether);
        vault.distribute(4 ether);

        // The adapter's claimable reads THROUGH our vault via the standard view (never reverts).
        assertEq(vault.withdrawableDividendOf(address(adapter)), 4 ether, "adapter owed the full 4 WBNB");
        assertEq(adapter.pendingYield(assetHash), 4 ether, "adapter.pendingYield reads our vault");

        // collectYield: withdrawDividend() from our vault (adapter is caller) -> sweep -> forward.
        uint256 ugmBefore = IERC20(address(WBNB)).balanceOf(address(ugm));
        uint256 forwarded = adapter.collectYield(assetHash);

        assertEq(forwarded, 4 ether, "adapter forwarded the claimed WBNB");
        assertEq(vault.withdrawableDividendOf(address(adapter)), 0, "vault dividend claimed");
        assertEq(IERC20(address(WBNB)).balanceOf(address(ugm)) - ugmBefore, 4 ether, "UGM received the yield");
        assertEq(ugm.pendingYieldSeat(gridId, 0), 1 ether, "4 WBNB across 4 seats");

        // Idempotency: nothing new to claim -> forwards 0.
        assertEq(adapter.collectYield(assetHash), 0, "2nd collectYield forwards 0");

        // Seats actually get yield: alice realizes her seat-0 WBNB.
        ugm.claimYield(gridId, 0);
        uint256 aliceBefore = IERC20(address(WBNB)).balanceOf(alice);
        vm.prank(alice);
        ugm.claimPayout(BscAddresses.WBNB);
        assertEq(IERC20(address(WBNB)).balanceOf(alice) - aliceBefore, 1 ether, "alice earns 1 WBNB of yield");
    }

    function _fundAndApprove(address who) internal {
        _mintWBNB(who, 100 ether);
        vm.prank(who);
        IERC20(address(WBNB)).approve(address(ugm), type(uint256).max);
    }
}
