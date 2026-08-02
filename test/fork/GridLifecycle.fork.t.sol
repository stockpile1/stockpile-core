// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ForkBase } from "./ForkBase.t.sol";
import { UnifiedGridManager } from "../../src/core/UnifiedGridManager.sol";
import { GridConfig, Seat, CreateGridParams } from "../../src/libraries/GridTypes.sol";

/// @notice Full Harberger-engine lifecycle on a BSC mainnet fork, using real WBNB as both the tax
///         and yield token. Exercises grid creation, claiming a seat from the creator, an immediate
///         (non-cooldown-gated) buyout, continuous tax -> Dutch-auction forfeiture, and equal-share
///         yield distribution + payout, aligned to the verified core.
contract GridLifecycleForkTest is ForkBase {
    UnifiedGridManager internal ugm;

    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        _forkBsc();
        // guardian = this test contract, 1% protocol seat-sale cut, no creator/tax cuts.
        ugm = new UnifiedGridManager(address(this), 100, 0, 0);
        ugm.setAllowedTaxToken(address(WBNB), true);

        _mintWBNB(creator, 1000 ether);
        _mintWBNB(alice, 1000 ether);
        _mintWBNB(bob, 1000 ether);

        vm.prank(creator);
        WBNB.approve(address(ugm), type(uint256).max);
        vm.prank(alice);
        WBNB.approve(address(ugm), type(uint256).max);
        vm.prank(bob);
        WBNB.approve(address(ugm), type(uint256).max);
    }

    function _createGrid(uint16 taxBps, uint128 initPrice) internal returns (uint256 gridId) {
        CreateGridParams memory p = CreateGridParams({
            totalSeats: 4,
            taxRateBps: taxBps,
            forfeitureDuration: 0,
            taxToken: address(WBNB),
            yieldToken: address(WBNB),
            initialPrice: initPrice
        });
        vm.prank(creator);
        gridId = ugm.createGrid(p);
    }

    function test_CreateGrid() public {
        uint256 gridId = _createGrid(500, 1 ether);
        GridConfig memory c = ugm.gridConfig(gridId);
        assertEq(c.creator, creator);
        assertEq(c.totalSeats, 4);
        assertEq(c.taxRateBps, 500);
        assertEq(c.taxToken, address(WBNB));

        for (uint256 i = 0; i < 4; i++) {
            Seat memory s = ugm.seatInfo(gridId, i);
            assertEq(s.holder, creator, "seat should start creator-owned");
            assertEq(s.price, 1 ether);
        }
    }

    function test_ClaimSeatFromCreator() public {
        uint256 gridId = _createGrid(500, 1 ether);

        uint256 creatorBefore = WBNB.balanceOf(creator);
        vm.prank(alice);
        ugm.buySeat(gridId, 0, 2 ether, 1 ether, 0);

        Seat memory s = ugm.seatInfo(gridId, 0);
        assertEq(s.holder, alice);
        assertEq(s.price, 2 ether);
        assertEq(s.deposit, 1 ether);

        // creator received price (1e18) minus 1% protocol seat-sale fee => 0.99e18
        assertEq(WBNB.balanceOf(creator) - creatorBefore, 0.99 ether);
        assertEq(ugm.gridTaxRevenue(gridId), 0.01 ether);
    }

    /// @notice Buyouts are not cooldown-gated: a fresh holder can be bought out immediately.
    function test_BuyoutImmediateNoCooldown() public {
        uint256 gridId = _createGrid(500, 1 ether);

        vm.prank(alice);
        ugm.buySeat(gridId, 0, 2 ether, 5 ether, 0);

        // bob buys alice out in the same block (no cooldown on buyouts).
        uint256 aliceBefore = WBNB.balanceOf(alice);
        vm.prank(bob);
        ugm.buySeat(gridId, 0, 3 ether, 5 ether, 0);

        Seat memory s = ugm.seatInfo(gridId, 0);
        assertEq(s.holder, bob);
        assertEq(s.price, 3 ether);
        // alice received: 2e18 price minus 1% fee (=1.98e18) PLUS her full 5e18 deposit refund
        // (no tax accrued in the same block).
        assertEq(WBNB.balanceOf(alice) - aliceBefore, 6.98 ether, "proceeds + full deposit refund");
    }

    function test_ContinuousTaxToDutchForfeit() public {
        uint256 gridId = _createGrid(500, 1 ether); // 5% / week

        // Alice claims at a high price with a thin deposit so tax depletes quickly.
        vm.prank(alice);
        ugm.buySeat(gridId, 0, 10 ether, 0.1 ether, 0);

        vm.warp(block.timestamp + 1 days);
        assertGt(ugm.taxDue(gridId, 0), 0);

        vm.warp(block.timestamp + 1 days); // 2 days total; tax > 0.1 deposit
        uint256 creatorPayoutBefore = ugm.payouts(address(WBNB), creator);
        ugm.pokeTax(gridId, 0);

        Seat memory s = ugm.seatInfo(gridId, 0);
        assertEq(s.holder, address(0), "seat forfeited into its Dutch window");
        assertEq(s.price, 10 ether, "price preserved for the Dutch auction");
        assertEq(s.deposit, 0);
        assertEq(ugm.forfeitedFrom(gridId, 0), alice, "alice recorded as forfeited holder");

        // Protocol bucket holds only the 1% claim fee; the consumed 0.1 deposit accrues to the
        // creator (protocolTaxBps == 0).
        assertEq(ugm.gridTaxRevenue(gridId), 0.01 ether, "claim fee only");
        assertEq(ugm.payouts(address(WBNB), creator) - creatorPayoutBefore, 0.1 ether, "consumed tax -> creator");
    }

    function test_YieldDistributionEqualShare() public {
        uint256 gridId = _createGrid(500, 1 ether);

        vm.prank(alice);
        ugm.buySeat(gridId, 0, 1 ether, 10 ether, 0);
        vm.prank(bob);
        ugm.buySeat(gridId, 1, 1 ether, 10 ether, 0);

        ugm.setApprovedAdapter(address(this), true);
        bytes32 assetHash = keccak256("grid-asset-1");
        ugm.registerAsset(gridId, assetHash);

        _mintWBNB(address(this), 4 ether);
        WBNB.approve(address(ugm), type(uint256).max);
        ugm.receiveYieldERC20(assetHash, address(WBNB), 4 ether); // 1 WBNB per seat

        assertEq(ugm.pendingYieldSeat(gridId, 0), 1 ether);
        assertEq(ugm.pendingYield(gridId, creator), 2 ether); // seats 2 + 3

        uint256 aliceBefore = WBNB.balanceOf(alice);
        ugm.claimYield(gridId, 0);
        vm.prank(alice);
        ugm.claimPayout(address(WBNB));
        assertEq(WBNB.balanceOf(alice) - aliceBefore, 1 ether);

        uint256[] memory ids = new uint256[](2);
        ids[0] = 2;
        ids[1] = 3;
        ugm.claimYieldBatch(gridId, ids);
        uint256 creatorBefore = WBNB.balanceOf(creator);
        vm.prank(creator);
        ugm.claimPayout(address(WBNB));
        assertEq(WBNB.balanceOf(creator) - creatorBefore, 2 ether);
    }
}
