// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { UnifiedGridManager } from "../../src/core/UnifiedGridManager.sol";
import { GridConfig, Seat, CreateGridParams } from "../../src/libraries/GridTypes.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";

/// @title UGM invariant handler
/// @notice Drives `UnifiedGridManager` with bounded random actions over a fixed set of
///         actors. A SINGLE `MockERC20` is used as both the tax token and the yield token,
///         so every value the contract owes (deposits, tax revenue, pending yield and
///         settled payouts) is denominated in one balance -- which is exactly what the
///         solvency invariant checks.
///
/// @dev The handler is the UGM's guardian/owner AND its registered yield adapter, so it can
///      inject yield via `receiveYieldERC20`. The grid's creator is a real actor. Every UGM
///      call is wrapped in try/catch so expected reverts (cooldown, not-holder, own-seat,
///      nothing-to-claim, ...) simply advance the sequence instead of aborting the run.
///      Holder-only actions prank as the seat's current holder to maximise meaningful state
///      churn; `buySeat` uses a random buyer to exercise ownership transfer and forfeiture.
contract Handler is Test {
    // --------------------------------------------------------------------- //
    //                          Deployed system                              //
    // --------------------------------------------------------------------- //
    UnifiedGridManager public ugm;
    MockERC20 public token; // single token: tax == yield
    uint256 public gridId;

    // --------------------------------------------------------------------- //
    //                              Config                                   //
    // --------------------------------------------------------------------- //
    uint16 internal constant FEE_BPS = 100; // 1% tile-sale fee
    uint16 internal constant TAX_BPS = 500; // 5% / week Harberger tax
    uint128 internal constant INIT_PRICE = 1 ether; // uniform creator seat price
    uint32 internal constant SEATS = 5; // > MIN_TOTAL_SEATS, a few stay creator-owned

    uint256 internal constant MAX_PRICE = 100 ether;
    uint256 internal constant MAX_DEPOSIT = 100 ether;
    uint256 internal constant MAX_YIELD = 100 ether;
    uint256 internal constant MAX_WARP = 30 days;
    uint256 internal constant INITIAL_FUNDS = 1e30; // ample per-actor balance

    bytes32 internal constant ASSET_HASH = keccak256("ugm-invariant-asset");

    // --------------------------------------------------------------------- //
    //                              Actors                                   //
    // --------------------------------------------------------------------- //
    address public creator; // == actors[0]
    address[] internal _actors;

    // --------------------------------------------------------------------- //
    //                          Ghost accumulators                           //
    // --------------------------------------------------------------------- //
    /// @notice Sum of every `receiveYieldERC20` amount that succeeded.
    uint256 public totalYieldInjected;
    /// @notice Number of forfeitures observed via `pokeTax`.
    uint256 public forfeits;
    /// @notice Set false if a just-forfeited seat was left in a bad post-state.
    bool public forfeitPostStateOk = true;

    // Coverage counters (read in the invariant test's summary helpers).
    uint256 public callsBuy;
    uint256 public callsInject;
    uint256 public callsClaimYield;
    uint256 public callsClaimPayout;

    constructor() {
        token = new MockERC20("Mock", "MOCK");
        // The handler is the guardian (owner) so it can self-approve as a yield adapter.
        ugm = new UnifiedGridManager(address(this), FEE_BPS, 0, 0);
        ugm.setAllowedTaxToken(address(token), true);

        creator = makeAddr("creator");
        _actors.push(creator);
        _actors.push(makeAddr("alice"));
        _actors.push(makeAddr("bob"));
        _actors.push(makeAddr("carol"));

        for (uint256 i = 0; i < _actors.length; ++i) {
            token.mint(_actors[i], INITIAL_FUNDS);
            vm.prank(_actors[i]);
            token.approve(address(ugm), type(uint256).max);
        }

        // Grid creator is a real actor (actors[0]).
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

        // Register the handler itself as the approved yield adapter for the grid.
        ugm.setApprovedAdapter(address(this), true);
        ugm.registerAsset(gridId, ASSET_HASH);
        // Handler -> UGM allowance, used when injecting yield.
        token.approve(address(ugm), type(uint256).max);
    }

    // --------------------------------------------------------------------- //
    //                          View helpers                                 //
    // --------------------------------------------------------------------- //
    function actorCount() external view returns (uint256) {
        return _actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return _actors[i];
    }

    function seatCount() external pure returns (uint256) {
        return SEATS;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return _actors[bound(seed, 0, _actors.length - 1)];
    }

    function _seatId(uint256 seed) internal pure returns (uint256) {
        return bound(seed, 0, SEATS - 1);
    }

    function _holderOf(uint256 seatId) internal view returns (address) {
        return ugm.seatInfo(gridId, seatId).holder;
    }

    // --------------------------------------------------------------------- //
    //                              Actions                                  //
    // --------------------------------------------------------------------- //

    /// @notice A random actor buys a seat at its current price (or Dutch clearing price if vacant)
    ///         and posts a fresh deposit.
    function buySeat(uint256 actorSeed, uint256 seatSeed, uint256 priceSeed, uint256 depositSeed) external {
        uint256 seatId = _seatId(seatSeed);
        address seller = _holderOf(seatId); // address(0) when the seat is vacant (in a Dutch window)
        address buyer = _actor(actorSeed);
        // Avoid the trivial "own seat" revert by rotating to another actor.
        if (buyer == seller) {
            uint256 idx = bound(actorSeed, 0, _actors.length - 1);
            buyer = _actors[(idx + 1) % _actors.length];
        }
        if (buyer == seller) return;

        uint128 newPrice = uint128(bound(priceSeed, 1, MAX_PRICE));
        uint256 dep = bound(depositSeed, 1, MAX_DEPOSIT); // non-zero: a zero deposit reverts as underwater

        vm.prank(buyer);
        try ugm.buySeat(gridId, seatId, newPrice, dep, 0) {
            callsBuy++;
        } catch { }
    }

    /// @notice The current holder re-assesses a seat's price.
    function setPrice(uint256 seatSeed, uint256 priceSeed) external {
        uint256 seatId = _seatId(seatSeed);
        address holder = _holderOf(seatId);
        if (holder == address(0)) return;
        uint128 newPrice = uint128(bound(priceSeed, 1, MAX_PRICE));

        vm.prank(holder);
        try ugm.setPrice(gridId, seatId, newPrice) { } catch { }
    }

    /// @notice The current holder tops up a seat's tax deposit.
    function addDeposit(uint256 seatSeed, uint256 amountSeed) external {
        uint256 seatId = _seatId(seatSeed);
        address holder = _holderOf(seatId);
        if (holder == address(0)) return;
        uint256 amount = bound(amountSeed, 1, MAX_DEPOSIT);

        vm.prank(holder);
        try ugm.addDeposit(gridId, seatId, amount) { } catch { }
    }

    /// @notice The current holder withdraws part of a seat's unspent deposit.
    function withdrawDeposit(uint256 seatSeed, uint256 amountSeed) external {
        uint256 seatId = _seatId(seatSeed);
        address holder = _holderOf(seatId);
        if (holder == address(0)) return;
        uint256 dep = ugm.seatInfo(gridId, seatId).deposit;
        if (dep == 0) return;
        uint256 amount = bound(amountSeed, 1, dep);

        vm.prank(holder);
        try ugm.withdrawDeposit(gridId, seatId, amount) { } catch { }
    }

    /// @notice The current holder abandons a seat back to the creator.
    function abandonSeat(uint256 seatSeed) external {
        uint256 seatId = _seatId(seatSeed);
        address holder = _holderOf(seatId);
        if (holder == address(0)) return;

        vm.prank(holder);
        try ugm.abandonSeat(gridId, seatId) { } catch { }
    }

    /// @notice Permissionlessly settle a seat's continuous tax (may forfeit it into a Dutch window).
    /// @dev When a forfeiture is observed, assert the post-state directly: a seat that just went
    ///      from a real holder to VACANT (`address(0)`) must have its deposit cleared and its price
    ///      PRESERVED to anchor the Dutch decay. A violation is recorded in a ghost flag (rather
    ///      than reverting, which `fail_on_revert = false` would swallow) and surfaced by
    ///      `invariant_forfeitPostState`.
    function pokeTax(uint256 seatSeed) external {
        uint256 seatId = _seatId(seatSeed);
        Seat memory pre = ugm.seatInfo(gridId, seatId);
        try ugm.pokeTax(gridId, seatId) {
            Seat memory post = ugm.seatInfo(gridId, seatId);
            if (pre.holder != address(0) && post.holder == address(0)) {
                forfeits++;
                if (post.deposit != 0 || post.price != pre.price || post.forfeitedAt == 0) {
                    forfeitPostStateOk = false;
                }
            }
        } catch { }
    }

    /// @notice Settle a seat's accrued yield to its holder's claimable balance.
    function claimYield(uint256 seatSeed) external {
        uint256 seatId = _seatId(seatSeed);
        try ugm.claimYield(gridId, seatId) {
            callsClaimYield++;
        } catch { }
    }

    /// @notice An actor withdraws its accrued token payout (yield/proceeds bucket).
    function claimPayout(uint256 actorSeed) external {
        address actor = _actor(actorSeed);
        vm.prank(actor);
        try ugm.claimPayout(address(token)) returns (uint256) {
            callsClaimPayout++;
        } catch { }
    }

    /// @notice Inject yield: mint to self, then forward via the adapter path.
    function injectYield(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1, MAX_YIELD);
        token.mint(address(this), amount);
        try ugm.receiveYieldERC20(ASSET_HASH, address(token), amount) {
            totalYieldInjected += amount;
            callsInject++;
        } catch { }
    }

    /// @notice Advance the ghost clock by a bounded delta so tax accrues.
    function warpTime(uint256 deltaSeed) external {
        uint256 delta = bound(deltaSeed, 0, MAX_WARP);
        vm.warp(block.timestamp + delta);
    }
}
