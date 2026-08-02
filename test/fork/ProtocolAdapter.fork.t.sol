// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ForkBase } from "./ForkBase.t.sol";
import { BscAddresses } from "../../src/config/BscAddresses.sol";
import { UnifiedGridManager } from "../../src/core/UnifiedGridManager.sol";
import { ProtocolYieldAdapter } from "../../src/adapters/ProtocolYieldAdapter.sol";
import { CreateGridParams } from "../../src/libraries/GridTypes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Fork test for the ProtocolYieldAdapter against BSC mainnet. This adapter has no
///         external vault: it is simply named as the recipient of some protocol's fees, so
///         those fees accrue directly to its balance. Here we simulate accrued WBNB protocol
///         fees (minted to the adapter) and assert `collect` forwards the whole balance into
///         the grid, split evenly across seats.
contract ProtocolAdapterForkTest is ForkBase {
    UnifiedGridManager internal ugm;
    ProtocolYieldAdapter internal adapter;

    function setUp() public {
        _forkBsc();
        ugm = new UnifiedGridManager(address(this), 0, 0, 0);
        adapter = new ProtocolYieldAdapter(address(ugm), address(this));
        ugm.setApprovedAdapter(address(adapter), true);
        ugm.setAllowedTaxToken(BscAddresses.WBNB, true);
    }

    function _createWbnbGrid() internal returns (uint256 gridId) {
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
    }

    function test_CollectYieldForwardsAccruedProtocolFees() public {
        uint256 gridId = _createWbnbGrid();

        bytes32 assetHash = adapter.registerFeeStream(gridId, BscAddresses.WBNB);
        assertTrue(adapter.isAssetRegistered(assetHash));
        assertEq(assetHash, adapter.assetHashFor(gridId, BscAddresses.WBNB));

        // Simulate protocol fees routed to the adapter (as the fee recipient).
        _mintWBNB(address(adapter), 3 ether);

        // pendingYield mirrors the adapter's accrued balance (exactly what collectYield forwards).
        assertEq(adapter.pendingYield(assetHash), 3 ether, "pendingYield == accrued balance");

        uint256 ugmBefore = IERC20(address(WBNB)).balanceOf(address(ugm));
        uint256 forwarded = adapter.collectYield(assetHash);

        assertEq(forwarded, 3 ether, "adapter forwards accrued fees");
        assertEq(IERC20(address(WBNB)).balanceOf(address(ugm)) - ugmBefore, 3 ether, "UGM WBNB +3");
        assertEq(ugm.pendingYieldSeat(gridId, 0), 0.75 ether, "3 WBNB across 4 seats");

        // Idempotency: a second collectYield with no new fees forwards 0.
        assertEq(adapter.pendingYield(assetHash), 0, "pendingYield back to 0 after sweep");
        uint256 forwarded2 = adapter.collectYield(assetHash);
        assertEq(forwarded2, 0, "2nd collectYield with no activity forwards 0");
        assertEq(IERC20(address(WBNB)).balanceOf(address(ugm)) - ugmBefore, 3 ether, "UGM unchanged by idempotent call");
    }

    function test_CollectYieldWithZeroBalanceReturnsZero() public {
        uint256 gridId = _createWbnbGrid();
        bytes32 assetHash = adapter.registerFeeStream(gridId, BscAddresses.WBNB);

        // pendingYield never reverts and is 0 with nothing accrued (and 0 for an unknown asset).
        assertEq(adapter.pendingYield(assetHash), 0, "no accrual -> 0");
        assertEq(adapter.pendingYield(bytes32(uint256(0xdead))), 0, "unregistered asset -> 0");

        uint256 ugmBefore = IERC20(address(WBNB)).balanceOf(address(ugm));
        uint256 forwarded = adapter.collectYield(assetHash);

        assertEq(forwarded, 0, "nothing accrued forwards zero");
        assertEq(IERC20(address(WBNB)).balanceOf(address(ugm)), ugmBefore, "UGM balance unchanged");
        assertEq(ugm.pendingYieldSeat(gridId, 0), 0, "no yield credited");
    }
}
