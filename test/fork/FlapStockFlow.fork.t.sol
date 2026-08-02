// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ForkBase } from "./ForkBase.t.sol";
import { BscAddresses } from "../../src/config/BscAddresses.sol";
import { UnifiedGridManager } from "../../src/core/UnifiedGridManager.sol";
import { FlapYieldAdapter } from "../../src/adapters/FlapYieldAdapter.sol";
import { CreateGridParams, Seat } from "../../src/libraries/GridTypes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice End-to-end canonical product flow on a BSC mainnet fork, using the REAL STOCK
///         token ("SpaceX" / SPCXB, 0xbe9D…03E1):
///
///           Flap launch paired with STOCK  →  trading fees accrue in STOCK
///             →  FlapYieldAdapter forwards the STOCK fee stream into a grid
///               →  Takeover Harberger seats split the STOCK yield across holders
///
///         Seats are priced/taxed and paid out entirely in STOCK (single-asset grid).
///         See docs/DECISIONS.md D9.
contract FlapStockFlowForkTest is ForkBase {
    IERC20 internal stock = IERC20(BscAddresses.STOCK);
    UnifiedGridManager internal ugm;
    FlapYieldAdapter internal adapter;

    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    // Stands in for the token launched on Flap and paired against STOCK.
    address internal flapLaunch = makeAddr("spacexPairedLaunch");

    uint256 internal gridId;
    bytes32 internal assetHash;

    function setUp() public {
        _forkBsc();
        ugm = new UnifiedGridManager(address(this), 100, 0, 0); // 1% protocol seat-sale cut
        adapter = new FlapYieldAdapter(
            address(ugm), BscAddresses.FLAP_PORTAL, BscAddresses.FLAP_VAULT_PORTAL, address(this)
        );
        ugm.setApprovedAdapter(address(adapter), true);
        ugm.setAllowedTaxToken(BscAddresses.STOCK, true);

        address[3] memory actors = [creator, alice, bob];
        for (uint256 i = 0; i < actors.length; i++) {
            deal(BscAddresses.STOCK, actors[i], 100_000 ether);
            vm.prank(actors[i]);
            stock.approve(address(ugm), type(uint256).max);
        }

        // Creator opens a STOCK-denominated grid: seats are priced, taxed and paid in STOCK.
        vm.prank(creator);
        gridId = ugm.createGrid(
            CreateGridParams({
                totalSeats: 4,
                taxRateBps: 500,
                forfeitureDuration: 0,
                taxToken: BscAddresses.STOCK,
                yieldToken: BscAddresses.STOCK,
                initialPrice: 1 ether
            })
        );

        // Wire the Flap launch's STOCK fee stream to the grid.
        assetHash = adapter.registerFlapToken(gridId, flapLaunch, BscAddresses.STOCK);
    }

    function test_FlapStockFeesToHarbergerSeats() public {
        // 1) alice + bob each claim a seat, paying the price + posting a deposit in STOCK.
        vm.prank(alice);
        ugm.buySeat(gridId, 0, 5 ether, 100 ether, 0);
        vm.prank(bob);
        ugm.buySeat(gridId, 1, 5 ether, 100 ether, 0);
        assertEq(ugm.seatInfo(gridId, 0).holder, alice);
        assertEq(ugm.seatInfo(gridId, 1).holder, bob);

        // 2) Flap trading fees accrue in STOCK to the adapter (dividend/fee recipient);
        //    collectYield best-effort claims the dividendContract then sweeps the STOCK balance.
        deal(BscAddresses.STOCK, address(adapter), 40 ether);
        uint256 forwarded = adapter.collectYield(assetHash);
        assertEq(forwarded, 40 ether, "adapter forwards the STOCK fee stream");
        assertEq(ugm.pendingYieldSeat(gridId, 0), 10 ether, "40 STOCK split across 4 seats");

        // Idempotency: a second collectYield with no newly accrued fees forwards 0.
        assertEq(adapter.collectYield(assetHash), 0, "2nd collectYield forwards 0");

        // 3) Everyone earns STOCK: alice (seat 0), bob (seat 1), creator (seats 2 + 3).
        _claimAndAssert(alice, 0, 10 ether);
        _claimAndAssert(bob, 1, 10 ether);

        uint256[] memory creatorSeats = new uint256[](2);
        creatorSeats[0] = 2;
        creatorSeats[1] = 3;
        ugm.claimYieldBatch(gridId, creatorSeats);
        uint256 creatorBefore = stock.balanceOf(creator);
        vm.prank(creator);
        ugm.claimPayout(BscAddresses.STOCK);
        assertEq(stock.balanceOf(creator) - creatorBefore, 20 ether, "creator earns STOCK on its 2 seats");

        // 4) A takeover: alice buys bob's seat out (buyouts are never cooldown-gated) — all in STOCK.
        vm.warp(block.timestamp + 21 minutes); // let a little tax accrue on bob's deposit
        uint256 bobBefore = stock.balanceOf(bob);
        vm.prank(alice);
        ugm.buySeat(gridId, 1, 6 ether, 100 ether, 0);
        assertEq(ugm.seatInfo(gridId, 1).holder, alice, "seat taken over by alice");
        // bob received his ~100 STOCK deposit refund + sale proceeds (5 STOCK - 1% fee), minus tiny tax.
        assertGt(stock.balanceOf(bob) - bobBefore, 100 ether, "bob refunded deposit + proceeds in STOCK");
    }

    function _claimAndAssert(address who, uint256 seatId, uint256 expected) internal {
        ugm.claimYield(gridId, seatId);
        uint256 before = stock.balanceOf(who);
        vm.prank(who);
        ugm.claimPayout(BscAddresses.STOCK);
        assertEq(stock.balanceOf(who) - before, expected, "holder earns STOCK yield");
    }
}
