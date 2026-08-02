// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Test } from "forge-std/Test.sol";
import { Initializable } from "@openzeppelin/contracts/proxy/utils/Initializable.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { DividendVault } from "../src/vault/DividendVault.sol";
import { VaultFactory } from "../src/vault/VaultFactory.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { FeeOnTransferERC20 } from "./mocks/FeeOnTransferERC20.sol";

/// @notice Unit tests (no fork) for the cloneable {DividendVault} and its {VaultFactory}. Exercises
///         the magnified-dividend-per-share accounting, fee-on-transfer-safe distribution, the
///         clone/re-init guard, owner gating, and the rounding-dust solvency invariant.
contract DividendVaultTest is Test {
    DividendVault internal implementation;
    VaultFactory internal factory;
    DividendVault internal vault;
    MockERC20 internal reward;

    address internal owner = address(this);
    address internal A = makeAddr("A");
    address internal B = makeAddr("B");
    address internal C = makeAddr("C");

    function setUp() public {
        reward = new MockERC20("Reward", "RWD");
        implementation = new DividendVault();
        factory = new VaultFactory(address(implementation));
        vault = DividendVault(factory.createVault(address(reward), owner));
    }

    // ----------------------------- helpers ------------------------------ //

    /// @dev Mint `amount` reward to this owner and distribute it through the vault.
    function _distribute(uint256 amount) internal {
        reward.mint(owner, amount);
        reward.approve(address(vault), amount);
        vault.distribute(amount);
    }

    /// @dev Solvency invariant: the vault must always hold at least the sum of all withdrawables.
    function _assertSolvent() internal view {
        uint256 owed = vault.withdrawableDividendOf(A) + vault.withdrawableDividendOf(B)
            + vault.withdrawableDividendOf(C);
        assertGe(reward.balanceOf(address(vault)), owed, "vault must cover all withdrawable dividends");
    }

    // --------------------------- factory wiring ------------------------- //

    function test_FactoryRecordsVault() public view {
        assertTrue(factory.isVault(address(vault)), "vault flagged");
        assertEq(factory.vaultsCount(), 1, "one vault");
        assertEq(factory.allVaults(0), address(vault), "enumerable");
        assertEq(factory.vaultOf(factory.vaultKey(address(reward), owner)), address(vault), "indexed by key");
        assertEq(vault.owner(), owner, "owner set on init");
        assertEq(address(vault.rewardToken()), address(reward), "reward set on init");
    }

    function test_CreateVaultDeterministic() public {
        bytes32 salt = keccak256("seat-vault-1");
        address predicted = factory.predictVaultAddress(salt);
        address v = factory.createVaultDeterministic(salt, address(reward), owner);
        assertEq(v, predicted, "clone lands at predicted address");
        assertTrue(factory.isVault(v));
        assertEq(factory.vaultsCount(), 2);
    }

    // ------------------------- core distribution ------------------------ //

    /// @dev Shares A=1, B=2, C=1; distribute 400 => 100 / 200 / 100.
    function test_DistributeSplitsProRata() public {
        vault.setShare(A, 1);
        vault.setShare(B, 2);
        vault.setShare(C, 1);
        assertEq(vault.totalShares(), 4);

        _distribute(400);

        assertEq(vault.withdrawableDividendOf(A), 100, "A 1/4");
        assertEq(vault.withdrawableDividendOf(B), 200, "B 2/4");
        assertEq(vault.withdrawableDividendOf(C), 100, "C 1/4");
        assertEq(vault.accumulativeDividendOf(B), 200, "accumulative == withdrawable pre-claim");
        assertEq(vault.totalDividendsDistributed(), 400);
        _assertSolvent();
    }

    /// @dev Each holder's withdrawDividend() transfers exactly their withdrawable and zeroes it.
    function test_WithdrawTransfersExactWithdrawable() public {
        vault.setShare(A, 1);
        vault.setShare(B, 2);
        vault.setShare(C, 1);
        _distribute(400);

        _withdrawAndAssert(A, 100);
        _withdrawAndAssert(B, 200);
        _withdrawAndAssert(C, 100);

        assertEq(reward.balanceOf(address(vault)), 0, "fully drained, no dust for exact division");
        assertEq(vault.totalDividendsWithdrawn(), 400);
    }

    function _withdrawAndAssert(address who, uint256 expected) internal {
        assertEq(vault.withdrawableDividendOf(who), expected);
        uint256 before = reward.balanceOf(who);
        vm.prank(who);
        vault.withdrawDividend();
        assertEq(reward.balanceOf(who) - before, expected, "exact transfer");
        assertEq(vault.withdrawableDividendOf(who), 0, "withdrawable zeroed");
        assertEq(vault.withdrawnDividendOf(who), expected, "withdrawn booked");
    }

    /// @dev A second distribution plus a mid-stream share change accrues correctly and preserves
    ///      already-earned dividends across the reweight.
    function test_RedistributeAndShareChangeAccrues() public {
        vault.setShare(A, 1);
        vault.setShare(B, 2);
        vault.setShare(C, 1); // total 4
        _distribute(400); // A100 B200 C100

        // Reweight C 1 -> 3 (total 4 -> 6). Already-earned dividends must be untouched.
        vault.setShare(C, 3);
        assertEq(vault.totalShares(), 6);
        assertEq(vault.withdrawableDividendOf(C), 100, "reweight preserves C's earned 100");
        assertEq(vault.withdrawableDividendOf(A), 100, "A untouched by C reweight");

        _distribute(600); // +100/share: A+100 B+200 C+300

        assertEq(vault.withdrawableDividendOf(A), 200, "A 100+100");
        assertEq(vault.withdrawableDividendOf(B), 400, "B 200+200");
        assertEq(vault.withdrawableDividendOf(C), 400, "C 100+300");
        assertEq(vault.totalDividendsDistributed(), 1000);
        _assertSolvent();
    }

    /// @dev A brand-new shareholder added AFTER a distribution earns nothing from it.
    function test_LateShareholderMissesPriorDistribution() public {
        vault.setShare(A, 1); // total 1
        _distribute(100); // all to A

        vault.setShare(B, 1); // added after the fact
        assertEq(vault.withdrawableDividendOf(B), 0, "B missed the prior round");
        assertEq(vault.withdrawableDividendOf(A), 100, "A keeps its full round");

        _distribute(100); // now split A/B
        assertEq(vault.withdrawableDividendOf(A), 150, "A 100 + 50");
        assertEq(vault.withdrawableDividendOf(B), 50, "B only the new round");
    }

    // --------------------------- guard rails ---------------------------- //

    /// @dev distribute() with no shares reverts with a clear error and pulls no funds.
    function test_DistributeZeroSharesReverts() public {
        reward.mint(owner, 100);
        reward.approve(address(vault), 100);
        vm.expectRevert(bytes("no shares"));
        vault.distribute(100);
        assertEq(reward.balanceOf(owner), 100, "funds not pulled on revert");
    }

    function test_DistributeZeroAmountReverts() public {
        vault.setShare(A, 1);
        vm.expectRevert(bytes("amount"));
        vault.distribute(0);
    }

    /// @dev Re-initializing an already-initialized clone reverts (OZ Initializable).
    function test_ReInitReverts() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        vault.initialize(address(reward), owner);
    }

    /// @dev The deployed implementation template cannot be initialized directly.
    function test_ImplementationInitializersDisabled() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        implementation.initialize(address(reward), owner);
    }

    function test_OnlyOwnerSetShare() public {
        vm.prank(A);
        vm.expectRevert(bytes("not owner"));
        vault.setShare(A, 1);
    }

    function test_OnlyOwnerWithdrawDividendTo() public {
        vault.setShare(A, 1);
        _distribute(100);
        vm.prank(A);
        vm.expectRevert(bytes("not owner"));
        vault.withdrawDividendTo(A);
    }

    /// @dev Views must never revert, even for unknown accounts / empty vaults.
    function test_ViewsNeverRevert() public {
        address stranger = makeAddr("stranger");
        assertEq(vault.withdrawableDividendOf(stranger), 0);
        assertEq(vault.accumulativeDividendOf(stranger), 0);
        assertEq(vault.withdrawnDividendOf(stranger), 0);
        assertEq(vault.syncableSurplus(), 0);
    }

    // ---------------------- owner-gated pull routing -------------------- //

    /// @dev withdrawDividendTo flushes a holder's dividend to that holder (never to the caller).
    function test_WithdrawDividendToRoutesToHolder() public {
        vault.setShare(A, 1);
        vault.setShare(B, 1);
        _distribute(200); // A100 B100

        uint256 got = vault.withdrawDividendTo(A);
        assertEq(got, 100, "returns amount routed");
        assertEq(reward.balanceOf(A), 100, "funds go to the entitled holder, not the owner");
        assertEq(vault.withdrawableDividendOf(A), 0);
        assertEq(reward.balanceOf(owner), 0, "owner receives nothing");
    }

    function test_BatchSetShare() public {
        address[] memory accs = new address[](3);
        accs[0] = A;
        accs[1] = B;
        accs[2] = C;
        uint256[] memory shares = new uint256[](3);
        shares[0] = 1;
        shares[1] = 2;
        shares[2] = 1;
        vault.batchSetShare(accs, shares);
        assertEq(vault.totalShares(), 4);
        _distribute(400);
        assertEq(vault.withdrawableDividendOf(B), 200);
    }

    function test_BatchSetShareLengthMismatchReverts() public {
        address[] memory accs = new address[](2);
        uint256[] memory shares = new uint256[](1);
        vm.expectRevert(bytes("length"));
        vault.batchSetShare(accs, shares);
    }

    // ------------------- fee-on-transfer-safe crediting ----------------- //

    /// @dev distributeSynced() credits the ACTUAL delta received when reward is transferred in
    ///      directly with a fee-on-transfer token (measures the real balance, not the nominal send).
    function test_DistributeSyncedCreditsFeeOnTransferDelta() public {
        FeeOnTransferERC20 fot = new FeeOnTransferERC20("Fee", "FEE", 100); // 1% burned on transfer
        DividendVault fotVault = DividendVault(factory.createVault(address(fot), owner));
        fotVault.setShare(A, 1);
        fotVault.setShare(B, 1); // total 2

        fot.mint(owner, 200); // mint is untaxed
        fot.transfer(address(fotVault), 200); // 1% burned => vault nets 198
        assertEq(fot.balanceOf(address(fotVault)), 198, "vault received net-of-fee amount");
        assertEq(fotVault.syncableSurplus(), 198, "surplus == real received delta");

        uint256 distributed = fotVault.distributeSynced();
        assertEq(distributed, 198, "credits the delta, not the nominal 200");
        assertEq(fotVault.withdrawableDividendOf(A), 99);
        assertEq(fotVault.withdrawableDividendOf(B), 99);
        assertEq(fotVault.totalDividendsDistributed(), 198);
    }

    /// @dev distribute() itself is fee-on-transfer safe: it credits the received delta.
    function test_DistributePullIsFeeOnTransferSafe() public {
        FeeOnTransferERC20 fot = new FeeOnTransferERC20("Fee", "FEE", 100);
        DividendVault fotVault = DividendVault(factory.createVault(address(fot), owner));
        fotVault.setShare(A, 1);

        fot.mint(owner, 100);
        fot.approve(address(fotVault), 100);
        uint256 distributed = fotVault.distribute(100); // vault nets 99
        assertEq(distributed, 99, "distributed == received delta");
        assertEq(fotVault.withdrawableDividendOf(A), 99);
    }

    function test_DistributeSyncedNoSurplusReverts() public {
        vault.setShare(A, 1);
        _distribute(100);
        // No new funds transferred in.
        vm.expectRevert(bytes("nothing to distribute"));
        vault.distributeSynced();
    }

    // --------------------- rounding dust / solvency --------------------- //

    /// @dev Uneven division leaves sub-unit dust permanently in the vault; the vault stays solvent
    ///      (balance >= sum of withdrawable) and the dust is never withdrawable.
    function test_RoundingDustStaysInVaultAndKeepsSolvency() public {
        vault.setShare(A, 1);
        vault.setShare(B, 1);
        vault.setShare(C, 1); // total 3

        _distribute(400); // 400/3 = 133.33 => 133 each, 1 dust

        assertEq(vault.withdrawableDividendOf(A), 133);
        assertEq(vault.withdrawableDividendOf(B), 133);
        assertEq(vault.withdrawableDividendOf(C), 133);
        _assertSolvent();

        vm.prank(A);
        vault.withdrawDividend();
        vm.prank(B);
        vault.withdrawDividend();
        vm.prank(C);
        vault.withdrawDividend();

        // 400 in, 399 out => exactly 1 dust wei remains, unattributable to any holder.
        assertEq(reward.balanceOf(address(vault)), 1, "dust retained");
        assertEq(vault.withdrawableDividendOf(A), 0);
        _assertSolvent();
    }

    /// @dev Fuzz: distributions and reweights never let total withdrawable exceed the vault balance.
    function testFuzz_SolvencyHoldsUnderDistributions(uint96 d1, uint96 d2, uint8 sa, uint8 sb) public {
        uint256 shareA = uint256(sa) + 1; // 1..256
        uint256 shareB = uint256(sb) + 1;
        vault.setShare(A, shareA);
        vault.setShare(B, shareB);

        if (d1 > 0) _distribute(d1);
        vault.setShare(A, shareA + 1); // reweight mid-stream
        if (d2 > 0) _distribute(d2);

        uint256 owed = vault.withdrawableDividendOf(A) + vault.withdrawableDividendOf(B);
        assertLe(owed, reward.balanceOf(address(vault)), "solvent under any distribution/reweight");
        assertLe(owed, vault.totalDividendsDistributed(), "cannot owe more than distributed");
    }
}
