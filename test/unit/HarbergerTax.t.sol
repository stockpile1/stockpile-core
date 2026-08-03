// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { UnifiedGridManager } from "../../src/core/UnifiedGridManager.sol";
import { GridConfig, Seat, CreateGridParams } from "../../src/libraries/GridTypes.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

/// @title Harberger tax + Dutch-forfeiture accounting unit tests (NON-fork)
/// @notice Exact-arithmetic tests for the continuous self-assessed tax engine, aligned to the
///         verified core: precise-seconds settlement (`lastSettledAt` advances by the exact seconds
///         the integer-rounded tax represents, closing the dust hole), the protocol/creator tax
///         split (here protocolTaxBps == 0, so all tax accrues to the creator's claimable payouts),
///         and Dutch-auction forfeiture (a depleted seat goes VACANT with its price preserved).
contract HarbergerTaxTest is Test {
    UnifiedGridManager internal ugm;
    MockERC20 internal token; // single token: tax == yield

    uint16 internal constant PROT_SEAT_BPS = 100; // 1% protocol seat-sale cut
    uint16 internal constant TAX_BPS = 500; // 5% / week Harberger tax
    uint128 internal constant INIT_PRICE = 1 ether;
    uint32 internal constant SEATS = 4;

    uint256 internal constant SECONDS_PER_WEEK = 7 days;
    uint256 internal constant BPS = 10_000;

    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        token = new MockERC20("Mock", "MOCK");
        ugm = new UnifiedGridManager(address(this), PROT_SEAT_BPS, 0, 0); // protocolTaxBps 0 -> tax to creator
        ugm.setAllowedTaxToken(address(token), true);

        address[3] memory actors = [creator, alice, bob];
        for (uint256 i = 0; i < actors.length; ++i) {
            token.mint(actors[i], 1000 ether);
            vm.prank(actors[i]);
            token.approve(address(ugm), type(uint256).max);
        }
    }

    // ------------------------------------------------------------------ //
    //                              Helpers                               //
    // ------------------------------------------------------------------ //
    function _params(uint32 seats, uint16 taxBps, address tax, address yield, uint128 initPrice)
        internal
        pure
        returns (CreateGridParams memory)
    {
        return CreateGridParams({
            totalSeats: seats,
            taxRateBps: taxBps,
            forfeitureDuration: 0,
            taxToken: tax,
            yieldToken: yield,
            initialPrice: initPrice
        });
    }

    function _createDefaultGrid() internal returns (uint256 gridId) {
        vm.prank(creator);
        gridId = ugm.createGrid(_params(SEATS, TAX_BPS, address(token), address(token), INIT_PRICE));
    }

    /// @dev Exact mirror of `HarbergerMath.taxOwed`.
    function _taxOwed(uint256 price, uint256 taxRateBps, uint256 elapsed) internal pure returns (uint256) {
        if (price == 0 || taxRateBps == 0 || elapsed == 0) return 0;
        return (price * taxRateBps * elapsed) / (SECONDS_PER_WEEK * BPS);
    }


    function _aliceClaimsSeat0(uint256 gridId, uint128 price, uint256 deposit) internal {
        vm.prank(alice);
        ugm.buySeat(gridId, 0, price, deposit, 0);
    }

    // ================================================================== //
    //   1. taxDue: exact uncapped tax over a fixed duration              //
    // ================================================================== //

    function test_TaxDue_ExactOverFixedDuration() public {
        uint256 gridId = _createDefaultGrid();

        uint128 price = 100 ether;
        _aliceClaimsSeat0(gridId, price, 100 ether);

        assertEq(ugm.taxDue(gridId, 0), 0, "no tax at t=0");

        uint256 elapsed = 3 days + 12 hours; // half a week
        vm.warp(block.timestamp + elapsed);

        uint256 expected = _taxOwed(price, TAX_BPS, elapsed);
        assertEq(expected, 2.5 ether, "half a week @5%/wk on 100e18 == 2.5e18");
        assertEq(ugm.taxDue(gridId, 0), expected, "taxDue matches the exact formula");

        Seat memory s = ugm.seatInfo(gridId, 0);
        assertEq(s.deposit, 100 ether, "deposit untouched by the view");
        assertEq(s.holder, alice, "holder unchanged by the view");
    }

    function test_TaxDue_ZeroForCreatorHeldSeat() public {
        uint256 gridId = _createDefaultGrid();

        vm.warp(block.timestamp + 7 days);
        assertEq(ugm.taxDue(gridId, 0), 0, "creator-held seat accrues no tax");

        _aliceClaimsSeat0(gridId, 100 ether, 100 ether);
        vm.warp(block.timestamp + 7 days);
        assertEq(ugm.taxDue(gridId, 0), _taxOwed(100 ether, TAX_BPS, 7 days), "alice-held seat accrues tax");
    }

    // ================================================================== //
    //   2. pokeTax: partial settlement, precise-seconds + tax split      //
    // ================================================================== //

    /// @notice A well-funded seat settles without forfeiture: the deposit drops by exactly the
    ///         accrued tax, `lastSettledAt` advances to the current block time (the floored `owed`
    ///         is a sub-unit under-charge in the holder's favour, never re-charged later), and the
    ///         settled tax accrues to the creator's claimable payouts (protocolTaxBps == 0).
    function test_PokeTax_PartialSettle_PreciseSecondsAndCreatorSplit() public {
        uint256 gridId = _createDefaultGrid();

        uint128 price = 100 ether;
        uint256 deposit = 10 ether;
        _aliceClaimsSeat0(gridId, price, deposit);
        uint256 creatorStart = ugm.payouts(address(token), creator);

        // ---- First interval ----
        vm.warp(block.timestamp + 1 days);
        uint64 lst0 = ugm.seatInfo(gridId, 0).lastSettledAt;
        uint256 owed1 = _taxOwed(price, TAX_BPS, block.timestamp - lst0);
        assertGt(owed1, 0, "some tax accrued");
        assertLt(owed1, deposit, "below deposit -> no forfeit");
        assertEq(ugm.taxDue(gridId, 0), owed1, "taxDue == expected before settle");

        ugm.pokeTax(gridId, 0);

        Seat memory s1 = ugm.seatInfo(gridId, 0);
        assertEq(s1.holder, alice, "seat retained");
        assertEq(s1.deposit, deposit - owed1, "deposit reduced by exactly the tax");
        assertEq(s1.lastSettledAt, uint64(block.timestamp), "clock advanced to now");
        assertEq(ugm.payouts(address(token), creator) - creatorStart, owed1, "tax -> creator payouts");
        assertEq(ugm.taxDue(gridId, 0), 0, "clock advanced to now -> no residue re-charged");

        // ---- Second interval, independent arithmetic on the residual clock ----
        vm.warp(block.timestamp + 2 days);
        uint64 lst1 = ugm.seatInfo(gridId, 0).lastSettledAt;
        uint256 owed2 = _taxOwed(price, TAX_BPS, block.timestamp - lst1);
        assertEq(ugm.taxDue(gridId, 0), owed2, "second-interval taxDue independent of the first");

        ugm.pokeTax(gridId, 0);

        Seat memory s2 = ugm.seatInfo(gridId, 0);
        assertEq(s2.deposit, deposit - owed1 - owed2, "deposit reduced by cumulative tax");
        assertEq(s2.lastSettledAt, uint64(block.timestamp), "clock advanced to now again");
        assertEq(ugm.payouts(address(token), creator) - creatorStart, owed1 + owed2, "cumulative tax -> creator");
    }

    // ================================================================== //
    //   3. Forfeiture: thin deposit fully consumed -> Dutch window       //
    // ================================================================== //

    /// @notice When accrued tax reaches the deposit, the seat forfeits into its Dutch window: it
    ///         goes VACANT with its price PRESERVED, the entire remaining deposit is booked as tax
    ///         (100% -> creator here), and the forfeited holder is snapshotted for compensation.
    function test_Forfeiture_ThinDepositToDutchWindow() public {
        uint256 gridId = _createDefaultGrid();

        uint128 price = 100 ether; // 5e18 / week
        uint256 thinDeposit = 0.1 ether;
        _aliceClaimsSeat0(gridId, price, thinDeposit);

        uint256 claimFee = (uint256(INIT_PRICE) * PROT_SEAT_BPS) / BPS;
        assertEq(ugm.gridTaxRevenue(gridId), claimFee, "claim fee booked to protocol bucket");
        uint256 creatorStart = ugm.payouts(address(token), creator);

        vm.warp(block.timestamp + 1 days);
        uint256 uncapped = _taxOwed(price, TAX_BPS, 1 days);
        assertEq(ugm.taxDue(gridId, 0), uncapped, "taxDue reports uncapped liability");
        assertGt(uncapped, thinDeposit, "liability exceeds deposit -> forfeiture");

        ugm.pokeTax(gridId, 0);

        Seat memory s = ugm.seatInfo(gridId, 0);
        assertEq(s.holder, address(0), "seat forfeited into its Dutch window");
        assertEq(s.price, price, "price preserved to anchor the Dutch decay");
        assertEq(s.deposit, 0, "deposit fully consumed");
        assertEq(ugm.forfeitedFrom(gridId, 0), alice, "forfeited holder recorded");

        // Only the remaining deposit (capped) is booked, all to the creator (protocolTaxBps 0).
        assertEq(ugm.gridTaxRevenue(gridId), claimFee, "protocol bucket unchanged");
        assertEq(ugm.payouts(address(token), creator) - creatorStart, thinDeposit, "consumed deposit -> creator");

        vm.warp(block.timestamp + 1 days);
        assertEq(ugm.taxDue(gridId, 0), 0, "vacant seat -> no further tax");
    }

    // ================================================================== //
    //   4. Deposit-refund-on-buyout regression                          //
    // ================================================================== //

    /// @notice On buyout the previous holder is made whole: sale proceeds (price - protocol fee)
    ///         plus their remaining deposit (original minus tax settled at buyout). The seat-sale
    ///         protocol fee accrues to the protocol bucket; the settled tax accrues to the creator.
    function test_BuyoutRefundsSellerRemainingDepositPlusProceeds() public {
        uint256 gridId = _createDefaultGrid();

        uint128 alicePrice = 2 ether;
        uint256 aliceDeposit = 5 ether;
        _aliceClaimsSeat0(gridId, alicePrice, aliceDeposit);

        vm.warp(block.timestamp + 1 hours); // tax accrues on alice's deposit

        uint64 lst0 = ugm.seatInfo(gridId, 0).lastSettledAt;
        uint256 owed = _taxOwed(alicePrice, TAX_BPS, block.timestamp - lst0);
        assertEq(ugm.taxDue(gridId, 0), owed, "settled tax == formula");
        assertGt(owed, 0, "nonzero tax at buyout");
        assertLt(owed, aliceDeposit, "tax below deposit");

        uint256 aliceBefore = token.balanceOf(alice);
        uint256 revBefore = ugm.gridTaxRevenue(gridId);
        uint256 creatorBefore = ugm.payouts(address(token), creator);

        vm.prank(bob);
        ugm.buySeat(gridId, 0, 3 ether, 5 ether, 0);

        // Buyout proceeds + remaining-deposit refund are now pull-based: alice withdraws via
        // claimPayout so the seller balance-delta assertion below holds as under the old push model.
        vm.prank(alice);
        ugm.claimPayout(address(token));

        Seat memory s = ugm.seatInfo(gridId, 0);
        assertEq(s.holder, bob, "holder is bob");
        assertEq(s.price, 3 ether, "bob's price");
        assertEq(s.deposit, 5 ether, "bob's fresh deposit");

        uint256 buyoutFee = (uint256(alicePrice) * PROT_SEAT_BPS) / BPS;
        uint256 expectedAliceGain = (uint256(alicePrice) - buyoutFee) + (aliceDeposit - owed);
        assertEq(token.balanceOf(alice) - aliceBefore, expectedAliceGain, "proceeds + remaining deposit refund");
        assertEq(ugm.gridTaxRevenue(gridId) - revBefore, buyoutFee, "seat-sale fee -> protocol bucket");
        assertEq(ugm.payouts(address(token), creator) - creatorBefore, owed, "settled tax -> creator");
    }

    // ================================================================== //
    //   5. withdrawDeposit settles tax first (precise seconds)          //
    // ================================================================== //

    function test_WithdrawDeposit_SettlesTaxFirst() public {
        uint256 gridId = _createDefaultGrid();

        uint128 price = 100 ether;
        uint256 deposit = 10 ether;
        _aliceClaimsSeat0(gridId, price, deposit);

        vm.warp(block.timestamp + 1 days);

        uint64 lst0 = ugm.seatInfo(gridId, 0).lastSettledAt;
        uint256 owed = _taxOwed(price, TAX_BPS, block.timestamp - lst0);
        assertEq(ugm.taxDue(gridId, 0), owed, "accrued tax == formula");
        assertGt(owed, 0);
        assertLt(owed, deposit);

        // Full original deposit is no longer withdrawable: settlement first consumes `owed`.
        vm.prank(alice);
        vm.expectRevert(bytes("exceeds deposit"));
        ugm.withdrawDeposit(gridId, 0, deposit);

        uint256 available = deposit - owed;
        uint256 aliceBefore = token.balanceOf(alice);
        uint256 creatorBefore = ugm.payouts(address(token), creator);

        vm.prank(alice);
        ugm.withdrawDeposit(gridId, 0, available);

        Seat memory s = ugm.seatInfo(gridId, 0);
        assertEq(s.holder, alice, "alice retains the seat");
        assertEq(s.deposit, 0, "deposit drained after settle + withdraw");
        assertEq(s.lastSettledAt, uint64(block.timestamp), "clock advanced to now on settle");
        assertEq(token.balanceOf(alice) - aliceBefore, available, "alice received deposit - accrued tax");
        assertEq(ugm.payouts(address(token), creator) - creatorBefore, owed, "settled tax -> creator");
    }
}
