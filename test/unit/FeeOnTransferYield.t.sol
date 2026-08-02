// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import { Test } from "forge-std/Test.sol";

import { UnifiedGridManager } from "../../src/core/UnifiedGridManager.sol";
import { Seat, CreateGridParams } from "../../src/libraries/GridTypes.sol";
import { MockERC20 } from "../mocks/MockERC20.sol";
import { FeeOnTransferERC20 } from "../mocks/FeeOnTransferERC20.sol";

/// @title Fee-on-transfer yield accounting (AUDIT-1 F-01, NON-fork)
/// @notice Proves `receiveYieldERC20` credits the ACTUAL received amount, not the nominal one,
///         when the yield token is fee-on-transfer, and that the yield-solvency invariant
///         (UGM balance >= sum of owed buckets) holds across settlement and withdrawal.
/// @dev The grid uses a PLAIN ERC20 for the tax/deposit side and a 2%-fee FoT ERC20 for the
///      yield side, so the yield token's only buckets are pending yield + settled payouts —
///      isolating the F-01 accounting from deposits/tax revenue. The test contract is the
///      guardian AND the approved yield adapter.
contract FeeOnTransferYieldTest is Test {
    UnifiedGridManager internal ugm;
    MockERC20 internal taxToken; // plain token: prices / deposits / tax
    FeeOnTransferERC20 internal yieldTok; // 2% fee-on-transfer yield token

    uint16 internal constant FEE_BPS = 0; // no tile-sale fee: keep the tax side clean
    uint16 internal constant TAX_BPS = 500; // 5% / week
    uint128 internal constant INIT_PRICE = 1 ether;
    uint32 internal constant SEATS = 4;
    uint256 internal constant FOT_BPS = 200; // 2% withheld on every FoT transfer

    bytes32 internal constant ASSET_HASH = keccak256("fot-yield-asset");

    address internal creator = makeAddr("creator");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal gridId;

    function setUp() public {
        ugm = new UnifiedGridManager(address(this), FEE_BPS, 0, 0); // this == guardian/owner
        taxToken = new MockERC20("Tax", "TAX");
        yieldTok = new FeeOnTransferERC20("FeeOnTransfer", "FOT", FOT_BPS);
        ugm.setAllowedTaxToken(address(taxToken), true);

        // Fund actors with the plain tax token and approve the UGM for buySeat/addDeposit.
        address[3] memory actors = [creator, alice, bob];
        for (uint256 i = 0; i < actors.length; ++i) {
            taxToken.mint(actors[i], 1000 ether);
            vm.prank(actors[i]);
            taxToken.approve(address(ugm), type(uint256).max);
        }

        // Grid: plain tax side, FoT yield side.
        vm.prank(creator);
        gridId = ugm.createGrid(
            CreateGridParams({
                totalSeats: SEATS,
                taxRateBps: TAX_BPS,
                forfeitureDuration: 0,
                taxToken: address(taxToken),
                yieldToken: address(yieldTok),
                initialPrice: INIT_PRICE
            })
        );

        // Register this test as the approved yield adapter for the grid.
        ugm.setApprovedAdapter(address(this), true);
        ugm.registerAsset(gridId, ASSET_HASH);
        yieldTok.approve(address(ugm), type(uint256).max);
    }

    // ------------------------------------------------------------------ //
    //                              Helpers                               //
    // ------------------------------------------------------------------ //

    /// @dev Inject `nominal` FoT yield via the adapter path; returns the amount the UGM actually
    ///      received (= nominal minus the 2% burned on transfer).
    function _injectYield(uint256 nominal) internal returns (uint256 received) {
        yieldTok.mint(address(this), nominal);
        uint256 before = yieldTok.balanceOf(address(ugm));
        ugm.receiveYieldERC20(ASSET_HASH, address(yieldTok), nominal);
        received = yieldTok.balanceOf(address(ugm)) - before;
    }

    /// @dev The yield-solvency check for the FoT token: UGM balance vs. all owed yield buckets.
    function _assertYieldSolvent() internal view {
        uint256 pending;
        for (uint256 i = 0; i < SEATS; ++i) {
            pending += ugm.pendingYieldSeat(gridId, i);
        }
        uint256 payoutsOwed = ugm.payouts(address(yieldTok), creator) + ugm.payouts(address(yieldTok), alice)
            + ugm.payouts(address(yieldTok), bob);
        assertGe(
            yieldTok.balanceOf(address(ugm)), pending + payoutsOwed, "UGM yield balance must cover all owed buckets"
        );
    }

    function _sumPending() internal view returns (uint256 pending) {
        for (uint256 i = 0; i < SEATS; ++i) {
            pending += ugm.pendingYieldSeat(gridId, i);
        }
    }

    // ================================================================== //
    //     (a) Only the received delta is credited, never the nominal      //
    // ================================================================== //

    function test_ReceiveYield_CreditsReceivedDeltaNotNominal() public {
        uint256 nominal = 100 ether;
        uint256 expectedFee = (nominal * FOT_BPS) / 10_000; // 2e18 burned
        uint256 expectedReceived = nominal - expectedFee; // 98e18

        uint256 received = _injectYield(nominal);
        assertEq(received, expectedReceived, "UGM received nominal minus the FoT fee");

        // The accumulator credits ONLY the received delta: sum of per-seat pending == received.
        uint256 pending = _sumPending();
        assertEq(pending, expectedReceived, "credited == received delta (98e18)");
        assertLt(pending, nominal, "did NOT over-credit the nominal 100e18");
        assertEq(yieldTok.balanceOf(address(ugm)), pending, "balance exactly backs credited yield");
    }

    /// @notice Multiple FoT injections keep crediting only the measured receipts (never the
    ///         nominal sum), so the pool is always fully backed.
    function test_ReceiveYield_MultipleInjectionsStayBacked() public {
        uint256 r1 = _injectYield(40 ether);
        uint256 r2 = _injectYield(37 ether);
        uint256 r3 = _injectYield(23 ether);

        assertEq(_sumPending(), r1 + r2 + r3, "credited == sum of received deltas");
        assertLt(_sumPending(), 100 ether, "less than the 100e18 nominal total");
        _assertYieldSolvent();
    }

    // ================================================================== //
    //  (b) Yield-solvency holds through settlement and withdrawal         //
    // ================================================================== //

    /// @notice With a fee-on-transfer yield token, every holder can still fully withdraw their
    ///         equal share and the UGM balance covers all owed buckets at each step. Under the
    ///         pre-fix (nominal) crediting the pool would be over-credited by the burned fee and
    ///         the last claimant's `claimPayout` would revert for insufficient balance.
    function test_YieldSolvency_AllHoldersCanWithdrawUnderFeeOnTransfer() public {
        // alice -> seat 0, bob -> seat 1; seats 2 and 3 remain creator-owned.
        vm.prank(alice);
        ugm.buySeat(gridId, 0, 1 ether, 5 ether, 0);
        vm.prank(bob);
        ugm.buySeat(gridId, 1, 1 ether, 5 ether, 0);

        uint256 received = _injectYield(100 ether); // 98e18 lands in the UGM
        assertEq(_sumPending(), received, "all received yield is pending, nothing lost or invented");
        _assertYieldSolvent();

        // Settle every seat: pending -> payouts. Solvency must still hold.
        uint256[] memory ids = new uint256[](SEATS);
        for (uint256 i = 0; i < SEATS; ++i) {
            ids[i] = i;
        }
        ugm.claimYieldBatch(gridId, ids);
        assertEq(_sumPending(), 0, "all pending settled to payouts");
        _assertYieldSolvent();

        // Each holder withdraws in turn; none may revert and solvency holds after each.
        uint256 totalWithdrawn;
        address[3] memory holders = [alice, bob, creator];
        for (uint256 i = 0; i < holders.length; ++i) {
            uint256 owed = ugm.payouts(address(yieldTok), holders[i]);
            assertGt(owed, 0, "holder is owed yield");
            vm.prank(holders[i]);
            uint256 got = ugm.claimPayout(address(yieldTok));
            assertEq(got, owed, "claimPayout returns the full owed amount (no insolvency)");
            totalWithdrawn += got;
            _assertYieldSolvent();
        }

        // Equal-share split: alice+bob get one seat each, creator gets two -> creator == 2x.
        assertEq(totalWithdrawn, received, "sum of withdrawals equals received yield");
        assertEq(yieldTok.balanceOf(address(ugm)), 0, "no owed yield token dust left stuck");
    }
}
