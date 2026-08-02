// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { UnifiedGridManager } from "../../src/core/UnifiedGridManager.sol";
import { GridConfig, Seat, CreateGridParams } from "../../src/libraries/GridTypes.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

/// @title UnifiedGridManager unit tests (NON-fork)
/// @notice Self-contained tests for the core Harberger-seat engine, aligned to the verified
///         Takeover v2.2 core: protocol/creator fee splits, Dutch-auction forfeiture, re-pricing
///         cooldown (buyouts never gated), tax-token allowlist and grid deprecation. A single
///         freshly deployed MockERC20 is used as BOTH the tax token and the yield token, so no
///         mainnet fork / RPC is required. The test contract is the guardian (Ownable owner).
contract UGMUnitTest is Test {
    UnifiedGridManager internal ugm;
    MockERC20 internal token; // single token: tax == yield

    // Default knobs: 1% protocol seat-sale cut, no creator cut, no protocol tax cut (tax -> creator).
    uint16 internal constant PROT_SEAT_BPS = 100;
    uint16 internal constant CREATOR_SEAT_BPS = 0;
    uint16 internal constant PROT_TAX_BPS = 0;
    uint16 internal constant TAX_BPS = 500; // 5% / week Harberger tax
    uint128 internal constant INIT_PRICE = 1 ether; // uniform creator seat price
    uint32 internal constant SEATS = 4;
    uint256 internal constant BPS = 10_000;

    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        token = new MockERC20("Mock", "MOCK");
        ugm = new UnifiedGridManager(address(this), PROT_SEAT_BPS, CREATOR_SEAT_BPS, PROT_TAX_BPS);
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
            forfeitureDuration: 0, // -> DEFAULT_FORFEITURE_DURATION (10 min)
            taxToken: tax,
            yieldToken: yield,
            initialPrice: initPrice
        });
    }

    function _createDefaultGrid() internal returns (uint256 gridId) {
        vm.prank(creator);
        gridId = ugm.createGrid(_params(SEATS, TAX_BPS, address(token), address(token), INIT_PRICE));
    }

    function _taxOwed(uint256 price, uint256 rateBps, uint256 elapsed) internal pure returns (uint256) {
        if (price == 0 || rateBps == 0 || elapsed == 0) return 0;
        return (price * rateBps * elapsed) / (7 days * BPS);
    }

    // ================================================================== //
    //                          Grid creation                            //
    // ================================================================== //

    function test_CreateGrid_HappyPath() public {
        uint256 gridId = _createDefaultGrid();

        assertEq(gridId, 1, "first grid is 1-indexed");
        assertEq(ugm.gridCount(), 1);

        GridConfig memory c = ugm.gridConfig(gridId);
        assertEq(c.creator, creator, "creator");
        assertEq(c.createdAt, uint64(block.timestamp), "createdAt");
        assertEq(c.totalSeats, SEATS, "totalSeats");
        assertEq(c.taxRateBps, TAX_BPS, "taxRateBps");
        assertEq(c.forfeitureDuration, ugm.DEFAULT_FORFEITURE_DURATION(), "forfeitureDuration defaulted");
        assertEq(c.taxToken, address(token), "taxToken");
        assertEq(c.yieldToken, address(token), "yieldToken");
        assertEq(ugm.totalSeats(gridId), SEATS);

        for (uint256 i = 0; i < SEATS; ++i) {
            Seat memory s = ugm.seatInfo(gridId, i);
            assertEq(s.holder, creator, "seat starts creator-owned");
            assertFalse(s.seatEverSold, "seat starts unsold");
            assertEq(s.price, INIT_PRICE, "seat starts at initialPrice");
            assertEq(s.deposit, 0, "creator seats carry no deposit");
            assertEq(s.lastSettledAt, uint64(block.timestamp));
            assertEq(s.acquiredAt, uint64(block.timestamp));
        }
    }

    function test_CreateGrid_RevertBelowMinSeats() public {
        uint32 tooFew = uint32(ugm.MIN_TOTAL_SEATS() - 1); // 3
        vm.prank(creator);
        vm.expectRevert(bytes("seats"));
        ugm.createGrid(_params(tooFew, TAX_BPS, address(token), address(token), INIT_PRICE));
    }

    function test_CreateGrid_RevertAboveMaxSingleTxSeats() public {
        uint32 tooMany = uint32(ugm.MAX_SINGLE_TX_CREATE_TOTAL_SEATS() + 1); // 1025
        vm.prank(creator);
        vm.expectRevert(bytes("seats"));
        ugm.createGrid(_params(tooMany, TAX_BPS, address(token), address(token), INIT_PRICE));
    }

    /// @notice F-06 / KI1: `MAX_TOTAL_SEATS` is enforced as the absolute per-grid ceiling
    ///         (checked before the single-tx cap), locking in that the constant is live.
    function test_CreateGrid_EnforcesMaxTotalSeatsCeiling() public {
        assertGe(ugm.MAX_TOTAL_SEATS(), ugm.MAX_SINGLE_TX_CREATE_TOTAL_SEATS(), "ceiling dominates single-tx cap");

        uint32 aboveCeiling = uint32(ugm.MAX_TOTAL_SEATS() + 1); // 4097
        vm.prank(creator);
        vm.expectRevert(bytes("maxSeats"));
        ugm.createGrid(_params(aboveCeiling, TAX_BPS, address(token), address(token), INIT_PRICE));

        uint32 aboveSingleTx = uint32(ugm.MAX_SINGLE_TX_CREATE_TOTAL_SEATS() + 1); // 1025
        vm.prank(creator);
        vm.expectRevert(bytes("seats"));
        ugm.createGrid(_params(aboveSingleTx, TAX_BPS, address(token), address(token), INIT_PRICE));
    }

    function test_CreateGrid_RevertTaxRateBelowMin() public {
        uint16 tooLow = uint16(ugm.MIN_TAX_BPS() - 1); // 9
        vm.prank(creator);
        vm.expectRevert(bytes("taxRate"));
        ugm.createGrid(_params(SEATS, tooLow, address(token), address(token), INIT_PRICE));
    }

    function test_CreateGrid_RevertTaxRateAboveMax() public {
        uint16 tooHigh = uint16(ugm.MAX_TAX_BPS() + 1); // 1001
        vm.prank(creator);
        vm.expectRevert(bytes("taxRate"));
        ugm.createGrid(_params(SEATS, tooHigh, address(token), address(token), INIT_PRICE));
    }

    function test_CreateGrid_RevertZeroTaxToken() public {
        vm.prank(creator);
        vm.expectRevert(bytes("token"));
        ugm.createGrid(_params(SEATS, TAX_BPS, address(0), address(token), INIT_PRICE));
    }

    function test_CreateGrid_RevertZeroYieldToken() public {
        vm.prank(creator);
        vm.expectRevert(bytes("token"));
        ugm.createGrid(_params(SEATS, TAX_BPS, address(token), address(0), INIT_PRICE));
    }

    /// @notice A grid can only be created with a guardian-allowed tax token.
    function test_CreateGrid_RevertTaxTokenNotAllowed() public {
        MockERC20 other = new MockERC20("Other", "OTH");
        vm.prank(creator);
        vm.expectRevert(bytes("taxToken"));
        ugm.createGrid(_params(SEATS, TAX_BPS, address(other), address(other), INIT_PRICE));

        // Once the guardian allows it, creation succeeds.
        ugm.setAllowedTaxToken(address(other), true);
        vm.prank(creator);
        uint256 gridId = ugm.createGrid(_params(SEATS, TAX_BPS, address(other), address(other), INIT_PRICE));
        assertEq(ugm.gridConfig(gridId).taxToken, address(other));
    }

    // ================================================================== //
    //                          buySeat: claiming                        //
    // ================================================================== //

    /// @notice Claim a creator-owned seat: buyer pays the price (minus the protocol seat-sale fee,
    ///         which accrues to the protocol bucket), posts a deposit, and sets a new price.
    function test_BuySeat_ClaimFromCreator() public {
        uint256 gridId = _createDefaultGrid();

        uint256 creatorBefore = token.balanceOf(creator);
        uint256 aliceBefore = token.balanceOf(alice);
        uint256 ugmBefore = token.balanceOf(address(ugm));

        vm.prank(alice);
        ugm.buySeat(gridId, 0, 2 ether, 1 ether, 0); // pay 1e18 price, post 1e18 deposit

        Seat memory s = ugm.seatInfo(gridId, 0);
        assertEq(s.holder, alice, "holder");
        assertTrue(s.seatEverSold, "seat marked sold");
        assertEq(s.price, 2 ether, "new self-assessed price");
        assertEq(s.deposit, 1 ether, "posted deposit");
        assertEq(s.acquiredAt, uint64(block.timestamp));

        uint256 fee = (1 ether * uint256(PROT_SEAT_BPS)) / BPS; // 0.01 ether
        assertEq(ugm.gridTaxRevenue(gridId), fee, "protocol seat-sale fee -> protocol bucket");
        assertEq(token.balanceOf(creator) - creatorBefore, 1 ether - fee, "creator proceeds");
        assertEq(aliceBefore - token.balanceOf(alice), 1 ether + 1 ether, "alice outflow");
        assertEq(token.balanceOf(address(ugm)) - ugmBefore, fee + 1 ether, "ugm holds fee + deposit");
    }

    function test_BuySeat_RevertOwnSeat() public {
        uint256 gridId = _createDefaultGrid();
        vm.prank(alice);
        ugm.buySeat(gridId, 0, 2 ether, 5 ether, 0);

        vm.prank(alice);
        vm.expectRevert(bytes("own seat"));
        ugm.buySeat(gridId, 0, 3 ether, 5 ether, 0);
    }

    function test_BuySeat_RevertNonexistentGrid() public {
        vm.prank(alice);
        vm.expectRevert(bytes("grid"));
        ugm.buySeat(999, 0, 1 ether, 1 ether, 0);
    }

    function test_BuySeat_RevertBadSeatId() public {
        uint256 gridId = _createDefaultGrid();
        vm.prank(alice);
        vm.expectRevert(bytes("seatId"));
        ugm.buySeat(gridId, SEATS, 1 ether, 1 ether, 0);
    }

    function test_BuySeat_RevertZeroNewPrice() public {
        uint256 gridId = _createDefaultGrid();
        vm.prank(alice);
        vm.expectRevert(bytes("newPrice"));
        ugm.buySeat(gridId, 0, 0, 1 ether, 0);
    }

    /// @notice A seat cannot be acquired with a zero deposit (it would be instantly underwater).
    function test_BuySeat_RevertZeroDeposit() public {
        uint256 gridId = _createDefaultGrid();
        vm.prank(alice);
        vm.expectRevert(bytes("deposit"));
        ugm.buySeat(gridId, 0, 2 ether, 0, 0);
    }

    /// @notice `maxPrice` is a slippage bound: the acquisition reverts if the seat's price is above it.
    function test_BuySeat_RevertMaxPriceSlippage() public {
        uint256 gridId = _createDefaultGrid(); // creator price is INIT_PRICE (1e18)
        vm.prank(alice);
        vm.expectRevert(bytes("maxPrice"));
        ugm.buySeat(gridId, 0, 2 ether, 1 ether, 0.5 ether); // price 1e18 > maxPrice 0.5e18

        // At/above the price it goes through.
        vm.prank(alice);
        ugm.buySeat(gridId, 0, 2 ether, 1 ether, 1 ether);
        assertEq(ugm.seatInfo(gridId, 0).holder, alice);
    }

    // ================================================================== //
    //                    buySeat: buyout (no cooldown)                  //
    // ================================================================== //

    /// @notice Buyouts are NOT cooldown-gated: a fresh holder can be bought out immediately at
    ///         their stated price. The seller receives sale proceeds (price - protocol fee) plus
    ///         their unspent deposit; the protocol seat-sale fee accrues to the protocol bucket.
    function test_BuySeat_BuyoutImmediateNoCooldown() public {
        uint256 gridId = _createDefaultGrid();

        vm.prank(alice);
        ugm.buySeat(gridId, 0, 2 ether, 5 ether, 0);
        uint256 feeClaim = (1 ether * uint256(PROT_SEAT_BPS)) / BPS; // 0.01
        assertEq(ugm.gridTaxRevenue(gridId), feeClaim);

        // No warp: bob buys alice out in the same block (no cooldown on buyouts).
        uint256 aliceBefore = token.balanceOf(alice);
        vm.prank(bob);
        ugm.buySeat(gridId, 0, 3 ether, 5 ether, 0);

        Seat memory s = ugm.seatInfo(gridId, 0);
        assertEq(s.holder, bob, "holder is bob");
        assertEq(s.price, 3 ether, "bob price");
        assertEq(s.deposit, 5 ether, "bob deposit");

        // No tax accrued (same block), so alice gets full deposit back + proceeds.
        uint256 feeBuyout = (2 ether * uint256(PROT_SEAT_BPS)) / BPS; // 0.02
        uint256 expectedAliceGain = (2 ether - feeBuyout) + 5 ether;
        assertEq(token.balanceOf(alice) - aliceBefore, expectedAliceGain, "seller proceeds + deposit refund");
        assertEq(ugm.gridTaxRevenue(gridId) - feeClaim, feeBuyout, "buyout protocol fee -> protocol bucket");
    }

    // ================================================================== //
    //                             setPrice                              //
    // ================================================================== //

    function test_SetPrice_RevertNotHolder() public {
        uint256 gridId = _createDefaultGrid();
        vm.prank(bob);
        vm.expectRevert(bytes("not holder"));
        ugm.setPrice(gridId, 0, 5 ether);
    }

    /// @notice A holder cannot re-price within PRICE_COOLDOWN of acquiring the seat.
    function test_SetPrice_RevertCooldown() public {
        uint256 gridId = _createDefaultGrid();
        vm.prank(alice);
        ugm.buySeat(gridId, 0, 2 ether, 5 ether, 0);

        vm.prank(alice);
        vm.expectRevert(bytes("cooldown"));
        ugm.setPrice(gridId, 0, 7 ether);
    }

    function test_SetPrice_HappyPathAfterCooldown() public {
        uint256 gridId = _createDefaultGrid();
        vm.prank(alice);
        ugm.buySeat(gridId, 0, 2 ether, 5 ether, 0);

        vm.warp(block.timestamp + 21 minutes); // clear the re-pricing cooldown
        vm.prank(alice);
        ugm.setPrice(gridId, 0, 7 ether);
        assertEq(ugm.seatInfo(gridId, 0).price, 7 ether, "price updated");
    }

    // ================================================================== //
    //                            addDeposit                             //
    // ================================================================== //

    function test_AddDeposit_HappyPath() public {
        uint256 gridId = _createDefaultGrid();
        vm.prank(alice);
        ugm.buySeat(gridId, 0, 2 ether, 5 ether, 0);

        uint256 aliceBefore = token.balanceOf(alice);
        uint256 ugmBefore = token.balanceOf(address(ugm));

        vm.prank(alice);
        ugm.addDeposit(gridId, 0, 3 ether);

        assertEq(ugm.seatInfo(gridId, 0).deposit, 8 ether, "deposit topped up");
        assertEq(aliceBefore - token.balanceOf(alice), 3 ether, "alice paid the top-up");
        assertEq(token.balanceOf(address(ugm)) - ugmBefore, 3 ether, "ugm received the top-up");
    }

    function test_AddDeposit_RevertNotHolder() public {
        uint256 gridId = _createDefaultGrid();
        vm.prank(alice);
        ugm.buySeat(gridId, 0, 2 ether, 5 ether, 0);

        vm.prank(bob);
        vm.expectRevert(bytes("not holder"));
        ugm.addDeposit(gridId, 0, 1 ether);
    }

    // ================================================================== //
    //                          withdrawDeposit                          //
    // ================================================================== //

    function test_WithdrawDeposit_RevertExceedsDeposit() public {
        uint256 gridId = _createDefaultGrid();
        vm.prank(alice);
        ugm.buySeat(gridId, 0, 2 ether, 5 ether, 0);

        vm.prank(alice);
        vm.expectRevert(bytes("exceeds deposit"));
        ugm.withdrawDeposit(gridId, 0, 6 ether);
    }

    function test_WithdrawDeposit_HappyPath() public {
        uint256 gridId = _createDefaultGrid();
        vm.prank(alice);
        ugm.buySeat(gridId, 0, 2 ether, 5 ether, 0);

        uint256 aliceBefore = token.balanceOf(alice);
        uint256 ugmBefore = token.balanceOf(address(ugm));

        vm.prank(alice);
        ugm.withdrawDeposit(gridId, 0, 2 ether);

        assertEq(ugm.seatInfo(gridId, 0).deposit, 3 ether, "deposit reduced");
        assertEq(token.balanceOf(alice) - aliceBefore, 2 ether, "alice received withdrawal");
        assertEq(ugmBefore - token.balanceOf(address(ugm)), 2 ether, "ugm paid out withdrawal");
    }

    // ================================================================== //
    //                    abandonSeat -> Dutch window                    //
    // ================================================================== //

    /// @notice Abandoning sends the seat into its Dutch window: holder cleared, PRICE PRESERVED to
    ///         anchor the decay, the abandoner snapshotted into `forfeitedFrom`, deposit refunded.
    function test_AbandonSeat_EntersDutchAndRefunds() public {
        uint256 gridId = _createDefaultGrid();
        vm.prank(alice);
        ugm.buySeat(gridId, 0, 2 ether, 5 ether, 0);

        uint256 aliceBefore = token.balanceOf(alice);
        uint256 ugmBefore = token.balanceOf(address(ugm));

        vm.prank(alice);
        ugm.abandonSeat(gridId, 0);

        Seat memory s = ugm.seatInfo(gridId, 0);
        assertEq(s.holder, address(0), "seat vacant (in Dutch window)");
        assertEq(s.price, 2 ether, "price preserved to anchor Dutch decay");
        assertEq(s.deposit, 0, "deposit cleared");
        assertEq(s.forfeitedAt, uint64(block.timestamp), "Dutch window opened now");
        assertEq(ugm.forfeitedFrom(gridId, 0), alice, "abandoner recorded as seller");

        assertEq(token.balanceOf(alice) - aliceBefore, 5 ether, "unspent deposit refunded");
        assertEq(ugmBefore - token.balanceOf(address(ugm)), 5 ether, "ugm released the deposit");
    }

    function test_AbandonSeat_RevertNotHolder() public {
        uint256 gridId = _createDefaultGrid();
        vm.prank(bob);
        vm.expectRevert(bytes("not holder"));
        ugm.abandonSeat(gridId, 0);
    }

    // ================================================================== //
    //          Continuous tax -> Dutch forfeiture (core behavior)       //
    // ================================================================== //

    /// @notice A thinly-deposited seat is forfeited into its Dutch window once accrued tax exceeds
    ///         the deposit. The seat goes VACANT with its price preserved; the consumed deposit is
    ///         split (here 100% -> creator, protocolTaxBps == 0). The forfeited holder is recorded
    ///         so a later Dutch reclaim compensates them.
    function test_ContinuousTaxToDutchForfeit() public {
        uint256 gridId = _createDefaultGrid(); // 5% / week

        vm.prank(alice);
        ugm.buySeat(gridId, 0, 10 ether, 0.1 ether, 0);
        uint256 claimFee = (uint256(INIT_PRICE) * PROT_SEAT_BPS) / BPS; // 0.01
        assertEq(ugm.gridTaxRevenue(gridId), claimFee, "claim fee booked");

        vm.warp(block.timestamp + 1 days);
        assertGt(ugm.taxDue(gridId, 0), 0);

        vm.warp(block.timestamp + 1 days); // 2 days total; tax > 0.1 deposit
        uint256 creatorPayoutBefore = ugm.payouts(address(token), creator);
        ugm.pokeTax(gridId, 0);

        Seat memory s = ugm.seatInfo(gridId, 0);
        assertEq(s.holder, address(0), "seat forfeited into Dutch window");
        assertEq(s.price, 10 ether, "price preserved for the Dutch auction");
        assertEq(s.deposit, 0, "deposit consumed");
        assertEq(ugm.forfeitedFrom(gridId, 0), alice, "alice recorded as forfeited holder");

        // Protocol tax cut is 0 here, so the consumed 0.1 deposit is all credited to the creator.
        assertEq(ugm.gridTaxRevenue(gridId), claimFee, "protocol bucket unchanged (protocolTaxBps == 0)");
        assertEq(ugm.payouts(address(token), creator) - creatorPayoutBefore, 0.1 ether, "consumed tax -> creator");

        // Vacant seat is not taxable.
        vm.warp(block.timestamp + 1 days);
        assertEq(ugm.taxDue(gridId, 0), 0, "vacant seat accrues no tax");
    }

    // ================================================================== //
    //               Dutch-auction reclaim of a vacant seat              //
    // ================================================================== //

    /// @notice A forfeited seat is reclaimable at a linearly-decaying clearing price paid to the
    ///         forfeited holder (minus protocol + penalty cuts), reaching a free claim after the
    ///         window. Exercises `forfeiturePenaltyBps` on a tax-underwater forfeit.
    function test_DutchReclaim_PaysForfeitedHolderAndDecays() public {
        ugm.setForfeiturePenaltyBps(1000); // 10% extra protocol cut on tax-underwater reclaims
        uint256 gridId = _createDefaultGrid(); // forfeitureDuration = 10 min
        uint32 window = ugm.DEFAULT_FORFEITURE_DURATION();

        // Alice takes seat 0 thinly, then is forfeited by tax.
        vm.prank(alice);
        ugm.buySeat(gridId, 0, 10 ether, 0.1 ether, 0);
        vm.warp(block.timestamp + 2 days);
        ugm.pokeTax(gridId, 0);
        assertEq(ugm.dutchAuctionPrice(gridId, 0), 10 ether, "clearing price == preserved price at t0");

        // Halfway through the window the clearing price halves.
        vm.warp(block.timestamp + window / 2);
        uint256 clearing = ugm.dutchAuctionPrice(gridId, 0);
        assertEq(clearing, 5 ether, "linear decay to half");

        uint256 revBefore = ugm.gridTaxRevenue(gridId);
        vm.prank(bob);
        ugm.buySeat(gridId, 0, 8 ether, 10 ether, 0); // bob reclaims, paying the clearing price

        Seat memory s = ugm.seatInfo(gridId, 0);
        assertEq(s.holder, bob, "bob reclaimed the seat");
        assertEq(s.price, 8 ether, "bob's new price");
        assertEq(s.deposit, 10 ether, "bob's deposit");
        assertEq(s.forfeitedAt, 0, "Dutch window cleared");

        uint256 protocolFee = (clearing * PROT_SEAT_BPS) / BPS; // 0.05
        uint256 penaltyFee = (clearing * 1000) / BPS; // 0.5 (tax-underwater penalty)
        uint256 sellerReceives = clearing - protocolFee - penaltyFee; // 4.45
        assertEq(ugm.gridTaxRevenue(gridId) - revBefore, protocolFee + penaltyFee, "protocol + penalty -> bucket");
        assertEq(ugm.payouts(address(token), alice), sellerReceives, "forfeited holder compensated");
    }

    /// @notice After the Dutch window fully decays, a vacant seat is a free claim (clearing price 0).
    function test_DutchReclaim_FreeAfterWindow() public {
        uint256 gridId = _createDefaultGrid();
        uint32 window = ugm.DEFAULT_FORFEITURE_DURATION();

        vm.prank(alice);
        ugm.buySeat(gridId, 0, 10 ether, 0.1 ether, 0);
        vm.warp(block.timestamp + 2 days);
        ugm.pokeTax(gridId, 0);

        vm.warp(block.timestamp + window + 1);
        assertEq(ugm.dutchAuctionPrice(gridId, 0), 0, "clearing price decayed to 0");

        uint256 bobBefore = token.balanceOf(bob);
        vm.prank(bob);
        ugm.buySeat(gridId, 0, 3 ether, 1 ether, 0); // only the deposit is paid
        assertEq(ugm.seatInfo(gridId, 0).holder, bob, "free reclaim after window");
        assertEq(bobBefore - token.balanceOf(bob), 1 ether, "bob only paid the deposit");
        assertEq(ugm.payouts(address(token), alice), 0, "nothing owed to the seller after the window");
    }

    // ================================================================== //
    //                        Grid deprecation                           //
    // ================================================================== //

    /// @notice Deprecation blocks new acquisitions but keeps every exit path open.
    function test_DeprecateGrid_BlocksBuyAllowsExits() public {
        uint256 gridId = _createDefaultGrid();
        vm.prank(alice);
        ugm.buySeat(gridId, 0, 2 ether, 5 ether, 0);

        ugm.deprecateGrid(gridId);
        assertTrue(ugm.gridDeprecated(gridId));

        // New acquisition is blocked.
        vm.prank(bob);
        vm.expectRevert(bytes("deprecated"));
        ugm.buySeat(gridId, 1, 2 ether, 5 ether, 0);

        // Exits still work: alice can withdraw part of her deposit and abandon the seat.
        vm.prank(alice);
        ugm.withdrawDeposit(gridId, 0, 1 ether);
        vm.prank(alice);
        ugm.abandonSeat(gridId, 0);
        assertEq(ugm.seatInfo(gridId, 0).holder, address(0), "alice exited the deprecated grid");
    }

    // ================================================================== //
    //          Equal-share yield distribution (core behavior)           //
    // ================================================================== //

    function test_YieldDistributionEqualShare() public {
        uint256 gridId = _createDefaultGrid();

        vm.prank(alice);
        ugm.buySeat(gridId, 0, 1 ether, 10 ether, 0);
        vm.prank(bob);
        ugm.buySeat(gridId, 1, 1 ether, 10 ether, 0);

        ugm.setApprovedAdapter(address(this), true);
        bytes32 assetHash = keccak256("grid-asset-1");
        ugm.registerAsset(gridId, assetHash);

        token.mint(address(this), 4 ether);
        token.approve(address(ugm), type(uint256).max);
        ugm.receiveYieldERC20(assetHash, address(token), 4 ether); // 1e18 per seat

        assertEq(ugm.pendingYieldSeat(gridId, 0), 1 ether, "seat 0 share");
        assertEq(ugm.pendingYield(gridId, creator), 2 ether, "creator holds seats 2 + 3");

        uint256 aliceBefore = token.balanceOf(alice);
        ugm.claimYield(gridId, 0);
        vm.prank(alice);
        ugm.claimPayout(address(token));
        assertEq(token.balanceOf(alice) - aliceBefore, 1 ether, "alice withdrew 1e18 yield");

        uint256[] memory ids = new uint256[](2);
        ids[0] = 2;
        ids[1] = 3;
        ugm.claimYieldBatch(gridId, ids);
        uint256 creatorBefore = token.balanceOf(creator);
        vm.prank(creator);
        ugm.claimPayout(address(token));
        assertEq(token.balanceOf(creator) - creatorBefore, 2 ether, "creator withdrew 2e18 yield");
    }

    // ================================================================== //
    //        Admin: route accrued protocol revenue out of the UGM       //
    // ================================================================== //

    /// @notice The guardian sweeps a grid's protocol bucket to the configured fee receiver.
    function test_WithdrawTaxRevenue() public {
        uint256 gridId = _createDefaultGrid();
        vm.prank(alice);
        ugm.buySeat(gridId, 0, 2 ether, 1 ether, 0);

        uint256 fee = (1 ether * uint256(PROT_SEAT_BPS)) / BPS; // 0.01
        assertEq(ugm.gridTaxRevenue(gridId), fee);

        address treasury = makeAddr("treasury");
        ugm.setProtocolFeeReceiver(treasury);
        uint256 amount = ugm.withdrawTaxRevenue(gridId); // onlyOwner == this

        assertEq(amount, fee, "returned swept amount");
        assertEq(token.balanceOf(treasury), fee, "fee receiver received revenue");
        assertEq(ugm.gridTaxRevenue(gridId), 0, "accounting zeroed");
    }

    // ================================================================== //
    //          Fee splits: protocol tax cut + creator seat-sale cut     //
    // ================================================================== //

    /// @notice Settled Harberger tax is split: protocol cut -> protocol bucket, remainder ->
    ///         the grid creator's claimable payouts.
    function test_ProtocolTaxSplit() public {
        // Fresh UGM with a 20% protocol tax cut and no seat-sale fee (isolate the tax split).
        UnifiedGridManager u = new UnifiedGridManager(address(this), 0, 0, 2000);
        u.setAllowedTaxToken(address(token), true);
        vm.prank(alice);
        token.approve(address(u), type(uint256).max);
        vm.prank(creator);
        uint256 gridId = u.createGrid(_params(SEATS, TAX_BPS, address(token), address(token), INIT_PRICE));

        uint128 price = 100 ether;
        vm.prank(alice);
        u.buySeat(gridId, 0, price, 10 ether, 0);

        uint256 elapsed = 1 days;
        vm.warp(block.timestamp + elapsed);
        uint256 owed = _taxOwed(price, TAX_BPS, elapsed);
        assertGt(owed, 0);

        u.pokeTax(gridId, 0);
        uint256 protocolShare = (owed * 2000) / BPS;
        assertEq(u.gridTaxRevenue(gridId), protocolShare, "protocol tax cut -> protocol bucket");
        assertEq(u.payouts(address(token), creator), owed - protocolShare, "tax remainder -> creator claimable");
    }

    /// @notice On a buyout the creator earns `creatorSeatSaleBps` of the sale price (claimable),
    ///         even though they are neither buyer nor seller.
    function test_CreatorSeatSaleCut() public {
        // 1% protocol + 2% creator seat-sale cut, no protocol tax cut.
        UnifiedGridManager u = new UnifiedGridManager(address(this), 100, 200, 0);
        u.setAllowedTaxToken(address(token), true);
        address[2] memory who = [alice, bob];
        for (uint256 i; i < who.length; ++i) {
            vm.prank(who[i]);
            token.approve(address(u), type(uint256).max);
        }
        vm.prank(creator);
        uint256 gridId = u.createGrid(_params(SEATS, TAX_BPS, address(token), address(token), INIT_PRICE));

        vm.prank(alice);
        u.buySeat(gridId, 0, 2 ether, 5 ether, 0); // buy-from-creator: no creator cut

        uint256 creatorPayoutBefore = u.payouts(address(token), creator);
        vm.prank(bob);
        u.buySeat(gridId, 0, 3 ether, 5 ether, 0); // buyout: creator earns the creator cut

        uint256 creatorFee = (2 ether * 200) / BPS; // 0.04 (2% of alice's price)
        assertEq(u.payouts(address(token), creator) - creatorPayoutBefore, creatorFee, "creator earns on secondary sale");
    }
}
