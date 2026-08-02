// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { UnifiedGridManager } from "../../src/core/UnifiedGridManager.sol";
import { GridConfig, Seat, CreateGridParams } from "../../src/libraries/GridTypes.sol";
import { HarbergerMath } from "../../src/libraries/HarbergerMath.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

/// @title Stateless fuzz tests for UGM math + a single state transition
/// @notice Complements the stateful invariants: pins down `HarbergerMath.taxOwed`
///         monotonicity/exactness and that `buySeat` writes the seat struct exactly for
///         arbitrary bounded inputs.
contract UGMFuzzTest is Test {
    // Mirror of HarbergerMath's denominator terms for an independent reference.
    uint256 internal constant SECONDS_PER_WEEK = 7 days; // 604800
    uint256 internal constant BPS = 10_000;
    uint256 internal constant MAX_TAX_BPS = 1000; // 10% / week ceiling in the engine

    // Bounds chosen so price * rate * elapsed can never overflow uint256:
    // 1e30 * 1e3 * (520 * 604800) ~= 3.1e41 << 1.15e77.
    uint256 internal constant MAX_PRICE_FUZZ = 1e30;
    uint256 internal constant MAX_ELAPSED = 520 weeks;

    // Fixtures for the buySeat state-setting test.
    UnifiedGridManager internal ugm;
    MockERC20 internal token;
    uint256 internal gridId;

    uint16 internal constant FEE_BPS = 100;
    uint16 internal constant TAX_BPS = 500;
    uint128 internal constant INIT_PRICE = 1 ether;
    uint32 internal constant SEATS = 4;

    address internal creator = makeAddr("creator");

    function setUp() public {
        token = new MockERC20("Mock", "MOCK");
        ugm = new UnifiedGridManager(address(this), FEE_BPS, 0, 0);
        ugm.setAllowedTaxToken(address(token), true);
        vm.prank(creator);
        gridId = ugm.createGrid(
            CreateGridParams({
                totalSeats: SEATS,
                taxRateBps: TAX_BPS,
                forfeitureDuration: 0,
                taxToken: address(token),
                yieldToken: address(token),
                initialPrice: INIT_PRICE
            })
        );
    }

    // ------------------------------------------------------------------ //
    //                    HarbergerMath.taxOwed fuzzing                   //
    // ------------------------------------------------------------------ //

    /// @dev Independent reference implementation of the library formula.
    function _ref(uint256 price, uint256 rate, uint256 elapsed) internal pure returns (uint256) {
        if (price == 0 || rate == 0 || elapsed == 0) return 0;
        return (price * rate * elapsed) / (SECONDS_PER_WEEK * BPS);
    }

    /// @notice taxOwed matches the documented closed form exactly, without overflowing.
    function testFuzz_TaxOwed_MatchesReference(uint256 price, uint256 rate, uint256 elapsed) public pure {
        price = bound(price, 0, MAX_PRICE_FUZZ);
        rate = bound(rate, 0, MAX_TAX_BPS);
        elapsed = bound(elapsed, 0, MAX_ELAPSED);
        assertEq(HarbergerMath.taxOwed(price, rate, elapsed), _ref(price, rate, elapsed), "taxOwed == reference");
    }

    /// @notice Any zero input yields zero tax.
    function testFuzz_TaxOwed_ZeroInputsYieldZero(uint256 price, uint256 rate, uint256 elapsed) public pure {
        price = bound(price, 0, MAX_PRICE_FUZZ);
        rate = bound(rate, 0, MAX_TAX_BPS);
        elapsed = bound(elapsed, 0, MAX_ELAPSED);
        assertEq(HarbergerMath.taxOwed(0, rate, elapsed), 0, "price 0 -> 0");
        assertEq(HarbergerMath.taxOwed(price, 0, elapsed), 0, "rate 0 -> 0");
        assertEq(HarbergerMath.taxOwed(price, rate, 0), 0, "elapsed 0 -> 0");
    }

    /// @notice Monotonic non-decreasing in price (rate, elapsed fixed).
    function testFuzz_TaxOwed_MonotonicInPrice(uint256 p1, uint256 p2, uint256 rate, uint256 elapsed) public pure {
        p1 = bound(p1, 0, MAX_PRICE_FUZZ);
        p2 = bound(p2, 0, MAX_PRICE_FUZZ);
        rate = bound(rate, 0, MAX_TAX_BPS);
        elapsed = bound(elapsed, 0, MAX_ELAPSED);
        if (p1 > p2) (p1, p2) = (p2, p1);
        assertLe(HarbergerMath.taxOwed(p1, rate, elapsed), HarbergerMath.taxOwed(p2, rate, elapsed), "mono price");
    }

    /// @notice Monotonic non-decreasing in elapsed time (price, rate fixed).
    function testFuzz_TaxOwed_MonotonicInElapsed(uint256 price, uint256 rate, uint256 e1, uint256 e2) public pure {
        price = bound(price, 0, MAX_PRICE_FUZZ);
        rate = bound(rate, 0, MAX_TAX_BPS);
        e1 = bound(e1, 0, MAX_ELAPSED);
        e2 = bound(e2, 0, MAX_ELAPSED);
        if (e1 > e2) (e1, e2) = (e2, e1);
        assertLe(HarbergerMath.taxOwed(price, rate, e1), HarbergerMath.taxOwed(price, rate, e2), "mono elapsed");
    }

    /// @notice Monotonic non-decreasing in tax rate (price, elapsed fixed).
    function testFuzz_TaxOwed_MonotonicInRate(uint256 price, uint256 r1, uint256 r2, uint256 elapsed) public pure {
        price = bound(price, 0, MAX_PRICE_FUZZ);
        r1 = bound(r1, 0, MAX_TAX_BPS);
        r2 = bound(r2, 0, MAX_TAX_BPS);
        elapsed = bound(elapsed, 0, MAX_ELAPSED);
        if (r1 > r2) (r1, r2) = (r2, r1);
        assertLe(HarbergerMath.taxOwed(price, r1, elapsed), HarbergerMath.taxOwed(price, r2, elapsed), "mono rate");
    }

    // ------------------------------------------------------------------ //
    //                    buySeat state-setting fuzzing                   //
    // ------------------------------------------------------------------ //

    /// @notice Claiming a creator-owned seat writes the buyer's holder/price/deposit and both
    ///         timestamps exactly, for arbitrary bounded price and deposit.
    function testFuzz_BuySeat_SetsState(uint128 newPrice, uint256 deposit) public {
        newPrice = uint128(bound(newPrice, 1, type(uint128).max));
        deposit = bound(deposit, 1, 1e27); // non-zero (a zero deposit reverts as underwater)

        address buyer = makeAddr("buyer");
        token.mint(buyer, 1e30);
        vm.prank(buyer);
        token.approve(address(ugm), type(uint256).max);

        uint256 ts = block.timestamp;
        vm.prank(buyer);
        ugm.buySeat(gridId, 0, newPrice, deposit, 0);

        Seat memory s = ugm.seatInfo(gridId, 0);
        assertEq(s.holder, buyer, "holder set to buyer");
        assertEq(uint256(s.price), uint256(newPrice), "price set to newPrice");
        assertEq(uint256(s.deposit), deposit, "deposit set to depositAmount");
        assertEq(uint256(s.acquiredAt), ts, "acquiredAt set to now");
        assertEq(uint256(s.lastSettledAt), ts, "lastSettledAt set to now");

        // Protocol fee on the creator's INIT_PRICE was routed to gridTaxRevenue.
        uint256 fee = (uint256(INIT_PRICE) * FEE_BPS) / BPS;
        assertEq(ugm.gridTaxRevenue(gridId), fee, "tile-sale fee booked to gridTaxRevenue");
    }
}
