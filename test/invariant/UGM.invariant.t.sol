// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { UnifiedGridManager } from "../../src/core/UnifiedGridManager.sol";
import { Seat } from "../../src/libraries/GridTypes.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { Handler } from "./Handler.sol";

/// @title UnifiedGridManager stateful invariants
/// @notice Fuzzed sequences of seat/yield/tax operations (driven by `Handler`) must never break the
///         core accounting guarantees of the engine. Because the tax token and the yield token are
///         the SAME `MockERC20`, the contract's single token balance must simultaneously cover every
///         bucket it owes: seat deposits, the protocol fee bucket, pending (unsettled) yield, and the
///         claimable payouts (yield + tax creator-share + creator seat-sale cut + Dutch-reclaim
///         seller proceeds).
contract UGMInvariantTest is Test {
    Handler internal handler;
    UnifiedGridManager internal ugm;
    MockERC20 internal token;
    uint256 internal gridId;

    function setUp() public {
        handler = new Handler();
        ugm = handler.ugm();
        token = handler.token();
        gridId = handler.gridId();

        targetContract(address(handler));
    }

    // --------------------------------------------------------------------- //
    //                          Bucket accumulators                          //
    // --------------------------------------------------------------------- //
    function _sumDepositsAndPending() internal view returns (uint256 deposits, uint256 pending) {
        uint256 seats = ugm.totalSeats(gridId);
        for (uint256 i = 0; i < seats; ++i) {
            deposits += ugm.seatInfo(gridId, i).deposit;
            pending += ugm.pendingYieldSeat(gridId, i);
        }
    }

    function _sumPayouts() internal view returns (uint256 total) {
        uint256 n = handler.actorCount();
        for (uint256 j = 0; j < n; ++j) {
            total += ugm.payouts(address(token), handler.actorAt(j));
        }
    }

    // --------------------------------------------------------------------- //
    //                             Invariants                                //
    // --------------------------------------------------------------------- //

    /// @notice The UGM's token balance must cover every owed bucket simultaneously: deposits +
    ///         protocol fee bucket + pending yield + settled payouts. `>=` (not `==`) because
    ///         integer-division dust in yield distribution leaves a small permanent surplus.
    function invariant_solvency() public view {
        (uint256 deposits, uint256 pending) = _sumDepositsAndPending();
        uint256 owed = deposits + pending + ugm.gridTaxRevenue(gridId) + _sumPayouts();
        assertGe(token.balanceOf(address(ugm)), owed, "UGM balance must cover all owed buckets");
    }

    /// @notice Unsettled pending yield can never exceed the total yield ever injected (the yield
    ///         accumulator only ever grows from `receiveYieldERC20`). Settled payouts now commingle
    ///         tax/sale proceeds with yield, so only the still-pending leg is bounded here.
    function invariant_pendingYieldNeverExceedsInjected() public view {
        (, uint256 pending) = _sumDepositsAndPending();
        assertLe(pending, handler.totalYieldInjected(), "pending yield must not exceed injected yield");
    }

    /// @notice Every observed forfeiture left the seat VACANT with its deposit cleared and its price
    ///         preserved (the Dutch-decay anchor), as asserted inside the handler.
    function invariant_forfeitPostState() public view {
        assertTrue(handler.forfeitPostStateOk(), "forfeited seat must be vacant, deposit 0, price preserved");
    }

    // --------------------------------------------------------------------- //
    //                    Forfeit machinery (deterministic)                  //
    // --------------------------------------------------------------------- //
    /// @notice Because invariant runs revert state between sequences, forfeiture may not appear in a
    ///         displayed run's summary. This deterministic drive proves the handler's forfeit
    ///         detection + post-state assertion actually fires: a thinly-deposited, highly-priced
    ///         seat is forfeited into its Dutch window (vacant, deposit 0, price preserved).
    function test_ForfeitPostStateExercised() public {
        // alice (actor 1) claims seat 1 at price 100e18 with a thin 0.01e18 deposit.
        handler.buySeat(1, 1, 100 ether, 0.01 ether);
        assertEq(ugm.seatInfo(gridId, 1).holder, handler.actorAt(1), "alice holds seat 1 pre-forfeit");

        handler.warpTime(30 days);
        handler.pokeTax(1);

        assertEq(handler.forfeits(), 1, "exactly one forfeiture detected");
        assertTrue(handler.forfeitPostStateOk(), "forfeited seat post-state validated by handler");

        Seat memory s = ugm.seatInfo(gridId, 1);
        assertEq(s.holder, address(0), "seat forfeited into its Dutch window (vacant)");
        assertEq(uint256(s.price), 100 ether, "price preserved to anchor the Dutch decay");
        assertEq(uint256(s.deposit), 0, "deposit fully consumed");
        assertEq(ugm.forfeitedFrom(gridId, 1), handler.actorAt(1), "forfeited holder recorded");
    }
}
