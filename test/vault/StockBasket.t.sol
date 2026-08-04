// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {StockBasket} from "../../src/vault/StockBasket.sol";
import {MockMintableERC20} from "./mocks/MockMintableERC20.sol";
import {MockFeeOnTransferERC20} from "./mocks/MockFeeOnTransferERC20.sol";
import {MockPausableStock} from "./mocks/MockPausableStock.sol";

/// @notice A stock token whose `transfer` re-enters `StockBasket.redeem`. Post-S3, {redeem} pays each
///         stock through a self-gated helper inside a try/catch, so the re-entrant call still hits the
///         `nonReentrant` guard and reverts, but that revert is now CAUGHT — the malicious leg is skipped
///         (no double redemption) while the honest legs still deliver (see test #10).
contract MaliciousReentrantStock is ERC20 {
    StockBasket public basket;
    bool public attack;

    constructor() ERC20("Malicious", "MAL") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBasket(StockBasket b) external {
        basket = b;
    }

    function setAttack(bool a) external {
        attack = a;
    }

    /// @dev On the basket's payout transfer, re-enter redeem (hits ReentrancyGuard → reverts → caught).
    function transfer(address to, uint256 amount) public override returns (bool) {
        if (attack) {
            basket.redeem(1, address(this));
        }
        return super.transfer(to, amount);
    }
}

/// @notice A stock whose `transferFrom` re-enters `StockBasket.redeem`, used to prove {deposit}'s
///         `nonReentrant` guard (audit S4). During a deposit's pull of this stock, the hook re-enters
///         `redeem`, which must revert at the guard and bubble up to revert the whole deposit — deposit
///         does NOT try/catch its pulls, so the reentrancy is fatal (not merely skipped).
contract MaliciousDepositReentrantStock is ERC20 {
    StockBasket public basket;
    bool public attack;

    constructor() ERC20("MalDeposit", "MALD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setBasket(StockBasket b) external {
        basket = b;
    }

    function setAttack(bool a) external {
        attack = a;
    }

    /// @dev On the basket's deposit pull, re-enter redeem (must hit ReentrancyGuard and revert deposit).
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (attack) {
            basket.redeem(1, address(this));
        }
        return super.transferFrom(from, to, amount);
    }
}

/// @notice A stock whose `transferFrom` reverts while `blocked` (blacklist / pause parity). Used to prove
///         {StockBasket.deposit}'s best-effort per-stock pull (audit L4): a blacklisting stock is SKIPPED
///         (its reserve stays lighter) while the healthy legs still land and shares still mint.
contract RevertingTransferFromStock is ERC20 {
    bool public blocked;

    constructor() ERC20("BadPull", "BADP") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setRevert(bool b) external {
        blocked = b;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        require(!blocked, "blocked transferFrom");
        return super.transferFrom(from, to, amount);
    }
}

/// @title StockBasket unit tests
/// @notice The test contract itself plays the role of the vault (`setVault(address(this))`), so it can
///         call the vault-only {StockBasket.deposit}. It funds itself with the underlying stocks and
///         approves the basket to pull them.
contract StockBasketTest is Test {
    StockBasket internal basket;

    MockMintableERC20 internal s0;
    MockMintableERC20 internal s1;
    MockMintableERC20 internal s2;
    MockFeeOnTransferERC20 internal sFee; // 4th stock: fee-on-transfer

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    uint256 internal constant N = 4;

    function setUp() public {
        s0 = new MockMintableERC20("Stock0", "S0", 18);
        s1 = new MockMintableERC20("Stock1", "S1", 18);
        s2 = new MockMintableERC20("Stock2", "S2", 6); // different decimals — pro-rata is unit-agnostic
        sFee = new MockFeeOnTransferERC20("StockFee", "SF", 18, 500); // 5% fee-on-transfer

        address[] memory stx = new address[](N);
        stx[0] = address(s0);
        stx[1] = address(s1);
        stx[2] = address(s2);
        stx[3] = address(sFee);

        basket = new StockBasket("Stockpile Basket", "SPB", stx);
        basket.setVault(address(this)); // this test acts as the vault

        // Fund the vault (this contract) generously and approve the basket to pull.
        s0.mint(address(this), 1e30);
        s1.mint(address(this), 1e30);
        s2.mint(address(this), 1e30);
        sFee.mint(address(this), 1e30);
        s0.approve(address(basket), type(uint256).max);
        s1.approve(address(basket), type(uint256).max);
        s2.approve(address(basket), type(uint256).max);
        sFee.approve(address(basket), type(uint256).max);
    }

    // ── Helpers ──────────────────────────────────────────────────────────────

    /// @dev Deposit `a0..a3` of the four stocks and mint `shares` to `to`, as the vault.
    function _deposit(uint256 a0, uint256 a1, uint256 a2, uint256 a3, uint256 shares, address to)
        internal
        returns (uint256)
    {
        uint256[] memory amts = new uint256[](N);
        amts[0] = a0;
        amts[1] = a1;
        amts[2] = a2;
        amts[3] = a3;
        return basket.deposit(amts, shares, to);
    }

    // ── 1. First deposit ───────────────────────────────────────────────────────

    function test_FirstDeposit_MintsExactShares_AndReserves() public {
        uint256 minted = _deposit(100e18, 200e18, 300e6, 40e18, 1000e18, ALICE);

        assertEq(minted, 1000e18, "returns sharesToMint");
        assertEq(basket.totalSupply(), 1000e18, "supply == shares");
        assertEq(basket.balanceOf(ALICE), 1000e18, "recipient got shares");

        uint256[] memory r = basket.reserves();
        assertEq(r[0], 100e18);
        assertEq(r[1], 200e18);
        assertEq(r[2], 300e6);
        // sFee is fee-on-transfer: basket receives 95% of 40e18.
        assertEq(r[3], 40e18 - (40e18 * 500) / 10_000, "FoT reserve is net-of-fee");
        assertEq(IERC20(address(sFee)).balanceOf(address(basket)), r[3]);
    }

    // ── 2. Second deposit accumulates supply, both holders correct ──────────────

    function test_SecondDeposit_AccumulatesSupply() public {
        _deposit(100e18, 200e18, 300e6, 40e18, 1000e18, ALICE);
        _deposit(50e18, 10e18, 700e6, 60e18, 500e18, BOB);

        assertEq(basket.totalSupply(), 1500e18, "supply accumulates");
        assertEq(basket.balanceOf(ALICE), 1000e18);
        assertEq(basket.balanceOf(BOB), 500e18);

        uint256[] memory r = basket.reserves();
        assertEq(r[0], 150e18);
        assertEq(r[1], 210e18);
        assertEq(r[2], 1000e6);
        // Two FoT deposits, each netting 95%.
        uint256 fee0 = (40e18 * 500) / 10_000;
        uint256 fee1 = (60e18 * 500) / 10_000;
        assertEq(r[3], (40e18 - fee0) + (60e18 - fee1));
    }

    // ── 3. Redeem returns pro-rata of ALL stocks ────────────────────────────────

    function test_Redeem_ProRataOfAllStocks() public {
        _deposit(100e18, 200e18, 300e6, 0, 1000e18, ALICE); // a3=0 keeps FoT out of this one
        _deposit(50e18, 10e18, 700e6, 0, 500e18, ALICE);

        uint256 supplyBefore = basket.totalSupply(); // 1500e18
        uint256[] memory rBefore = basket.reserves();

        uint256 redeemShares = 600e18; // 600/1500 = 2/5 of everything
        uint256[] memory expected = new uint256[](N);
        for (uint256 i = 0; i < N; i++) {
            expected[i] = (redeemShares * rBefore[i]) / supplyBefore;
        }

        vm.prank(ALICE);
        uint256[] memory got = basket.redeem(redeemShares, BOB);

        for (uint256 i = 0; i < N; i++) {
            assertEq(got[i], expected[i], "pro-rata payout");
        }
        // BOB (recipient) receives every stock.
        assertEq(s0.balanceOf(BOB), expected[0]);
        assertEq(s1.balanceOf(BOB), expected[1]);
        assertEq(s2.balanceOf(BOB), expected[2]);
        assertEq(IERC20(address(sFee)).balanceOf(BOB), expected[3]); // 0 here

        // Supply and reserves drop correctly.
        assertEq(basket.totalSupply(), supplyBefore - redeemShares);
        assertEq(basket.balanceOf(ALICE), 1500e18 - redeemShares);
        uint256[] memory rAfter = basket.reserves();
        for (uint256 i = 0; i < N; i++) {
            assertEq(rAfter[i], rBefore[i] - expected[i], "reserves drop by payout");
        }
    }

    // ── 4. Fairness: equal shares → equal claim ─────────────────────────────────

    function test_Fairness_EqualSharesEqualClaim() public {
        // Two holders each get 500 shares — from DIFFERENT deposits, but shares are what matters.
        _deposit(100e18, 200e18, 300e6, 40e18, 500e18, ALICE);
        _deposit(999e18, 1e18, 12345e6, 7e18, 500e18, BOB); // wildly different amounts, same shares

        // Snapshot the reserve ALICE redeems against (supply == 1000).
        uint256[] memory rBefore = basket.reserves();

        vm.prank(ALICE);
        uint256[] memory aOut = basket.redeem(500e18, ALICE); // 500/1000 = exactly half of each reserve
        vm.prank(BOB);
        uint256[] memory bOut = basket.redeem(500e18, BOB); // sweeps the entire remainder

        // ALICE (first, at supply 1000) gets floor(reserve/2); BOB (at supply 500) gets the rest.
        // Equal shares ⇒ equal claim to within 1 unit of integer-division dust per stock.
        for (uint256 i = 0; i < N; i++) {
            assertEq(aOut[i], rBefore[i] / 2, "first redeemer gets exactly half");
            assertEq(bOut[i], rBefore[i] - aOut[i], "second redeemer gets the remainder");
            // Fairness: the two equal-share claims differ by at most 1 (rounding only).
            uint256 diff = aOut[i] > bOut[i] ? aOut[i] - bOut[i] : bOut[i] - aOut[i];
            assertLe(diff, 1, "equal shares claim within 1 unit");
        }
        // After both redeems the basket is fully drained (supply 0).
        assertEq(basket.totalSupply(), 0, "fully redeemed");
    }

    /// @dev Cleaner fairness proof: two holders redeem equal shares against the SAME reserve snapshot.
    ///      Deploy a 2-stock basket, give ALICE and BOB 500 shares each (total 1000), then have each
    ///      preview-redeem 500 against the untouched reserve — the previews must be identical.
    function test_Fairness_EqualSharesEqualPreview() public {
        address[] memory stx = new address[](2);
        stx[0] = address(s0);
        stx[1] = address(s1);
        StockBasket b2 = new StockBasket("B2", "B2", stx);
        b2.setVault(address(this));
        s0.approve(address(b2), type(uint256).max);
        s1.approve(address(b2), type(uint256).max);

        uint256[] memory amts = new uint256[](2);
        amts[0] = 777e18;
        amts[1] = 333e18;
        b2.deposit(amts, 500e18, ALICE);
        amts[0] = 111e18;
        amts[1] = 222e18;
        b2.deposit(amts, 500e18, BOB);

        // Both preview 500 shares against the SAME (untouched) reserve state → identical claims.
        uint256[] memory pA = b2.previewRedeem(500e18);
        uint256[] memory pB = b2.previewRedeem(500e18);
        assertEq(pA[0], pB[0], "equal shares, equal stock0");
        assertEq(pA[1], pB[1], "equal shares, equal stock1");
        // And each is exactly half of the reserve (500/1000).
        uint256[] memory r = b2.reserves();
        assertEq(pA[0], r[0] / 2);
        assertEq(pA[1], r[1] / 2);
    }

    // ── 5. Fee-on-transfer stock handled at deposit AND redeem ───────────────────

    function test_FeeOnTransfer_BalancesViaBalanceOf() public {
        // Deposit only into the FoT stock leg (others 0). Basket receives net-of-fee.
        uint256 depositAmt = 1000e18;
        uint256 fee = (depositAmt * 500) / 10_000; // 5%
        uint256 netIn = depositAmt - fee;
        _deposit(0, 0, 0, depositAmt, 1000e18, ALICE);

        uint256 basketBal = IERC20(address(sFee)).balanceOf(address(basket));
        assertEq(basketBal, netIn, "basket holds net-of-fee");

        // Redeem all shares. Payout is sized from balanceOf (netIn), not the nominal deposit.
        uint256 bobBefore = IERC20(address(sFee)).balanceOf(BOB);
        vm.prank(ALICE);
        uint256[] memory got = basket.redeem(1000e18, BOB);

        // amounts[3] equals the full basket balance (whole supply redeemed).
        assertEq(got[3], netIn, "payout sized from real balance");
        // BOB actually receives net-of-fee AGAIN on the outbound transfer (FoT on the way out too).
        uint256 outFee = (netIn * 500) / 10_000;
        assertEq(IERC20(address(sFee)).balanceOf(BOB) - bobBefore, netIn - outFee, "recipient gets net-of-fee out");
        // No revert, no over-withdraw: basket drained exactly what it held for this stock.
        assertEq(IERC20(address(sFee)).balanceOf(address(basket)), 0, "no FoT dust stuck for this stock");
    }

    // ── 6. onlyVault: non-vault deposit reverts ─────────────────────────────────

    function test_Deposit_OnlyVault() public {
        uint256[] memory amts = new uint256[](N);
        amts[0] = 1e18;
        vm.prank(ALICE);
        vm.expectRevert(bytes(unicode"Only vault / 仅限金库"));
        basket.deposit(amts, 1e18, ALICE);
    }

    function test_Deposit_LengthMismatch() public {
        uint256[] memory amts = new uint256[](N - 1); // wrong length
        vm.expectRevert(bytes(unicode"Length mismatch / 长度不匹配"));
        basket.deposit(amts, 1e18, ALICE);
    }

    function test_Deposit_ZeroSharesReverts() public {
        uint256[] memory amts = new uint256[](N);
        vm.expectRevert(bytes(unicode"Zero shares / 份额为零"));
        basket.deposit(amts, 0, ALICE);
    }

    function test_Deposit_ZeroToReverts() public {
        uint256[] memory amts = new uint256[](N);
        vm.expectRevert(bytes(unicode"Zero address / 零地址"));
        basket.deposit(amts, 1e18, address(0));
    }

    // ── 7. setVault one-shot / onlyOwner ────────────────────────────────────────

    function test_SetVault_OneShot_SecondReverts() public {
        // setUp already set the vault to this contract.
        vm.expectRevert(bytes(unicode"Vault already set / 金库已设置"));
        basket.setVault(address(0xCAFE));
    }

    function test_SetVault_ZeroReverts() public {
        // Fresh basket with no vault yet.
        address[] memory stx = new address[](1);
        stx[0] = address(s0);
        StockBasket fresh = new StockBasket("F", "F", stx);
        vm.expectRevert(bytes(unicode"Zero address / 零地址"));
        fresh.setVault(address(0));
    }

    function test_SetVault_OnlyOwner() public {
        address[] memory stx = new address[](1);
        stx[0] = address(s0);
        StockBasket fresh = new StockBasket("F", "F", stx);
        vm.prank(ALICE);
        vm.expectRevert(bytes("Ownable: caller is not the owner"));
        fresh.setVault(address(0xCAFE));
    }

    // ── 8. Constructor validation ───────────────────────────────────────────────

    function test_Ctor_EmptyStocksReverts() public {
        address[] memory stx = new address[](0);
        vm.expectRevert(bytes(unicode"No stocks / 无股票"));
        new StockBasket("X", "X", stx);
    }

    function test_Ctor_ZeroStockReverts() public {
        address[] memory stx = new address[](2);
        stx[0] = address(s0);
        stx[1] = address(0);
        vm.expectRevert(bytes(unicode"Zero stock / 股票地址为零"));
        new StockBasket("X", "X", stx);
    }

    function test_Ctor_DuplicateStockReverts() public {
        address[] memory stx = new address[](3);
        stx[0] = address(s0);
        stx[1] = address(s1);
        stx[2] = address(s0); // duplicate
        vm.expectRevert(bytes(unicode"Duplicate stock / 股票重复"));
        new StockBasket("X", "X", stx);
    }

    function test_Ctor_StoresStocksAndViews() public {
        assertEq(basket.stocksLength(), N);
        address[] memory got = basket.getStocks();
        assertEq(got.length, N);
        assertEq(got[0], address(s0));
        assertEq(got[3], address(sFee));
        assertEq(basket.stocks(2), address(s2)); // public array getter
    }

    // ── 9. previewRedeem == redeem ──────────────────────────────────────────────

    function test_PreviewRedeem_EqualsRedeem() public {
        _deposit(123e18, 456e18, 789e6, 321e18, 1000e18, ALICE);
        _deposit(7e18, 8e18, 9e6, 10e18, 234e18, ALICE);

        uint256 shares = 815e18; // arbitrary, < holdings
        uint256[] memory preview = basket.previewRedeem(shares);

        vm.prank(ALICE);
        uint256[] memory actual = basket.redeem(shares, ALICE);

        assertEq(preview.length, actual.length);
        for (uint256 i = 0; i < N; i++) {
            assertEq(preview[i], actual[i], "preview matches redeem");
        }
    }

    function test_PreviewRedeem_ZeroSupplyReturnsZeros() public {
        // No deposits yet → supply 0 → preview returns zeros without reverting.
        uint256[] memory p = basket.previewRedeem(1e18);
        assertEq(p.length, N);
        for (uint256 i = 0; i < N; i++) {
            assertEq(p[i], 0);
        }
    }

    // ── 10. Reentrancy + over-redeem ────────────────────────────────────────────

    /// @dev Post-S3, a redeem-reentrant stock is NEUTRALIZED, not fatal: its re-entrant `redeem` still
    ///      hits the `nonReentrant` guard and reverts, but the best-effort try/catch CATCHES that revert
    ///      and SKIPS only the malicious leg — the honest leg still delivers and there is no double
    ///      redemption (supply drops by exactly the redeemed shares, once).
    function test_Redeem_ReentrantStock_NeutralizedAndSkipped() public {
        // Build a basket whose 2nd stock re-enters redeem on transfer.
        MaliciousReentrantStock mal = new MaliciousReentrantStock();
        address[] memory stx = new address[](2);
        stx[0] = address(s0);
        stx[1] = address(mal);
        StockBasket b = new StockBasket("R", "R", stx);
        b.setVault(address(this));
        mal.setBasket(b);

        // Fund + approve, then deposit into both legs so redeem will transfer BOTH stocks.
        s0.approve(address(b), type(uint256).max);
        mal.mint(address(this), 1_000e18);
        mal.approve(address(b), type(uint256).max);

        uint256[] memory amts = new uint256[](2);
        amts[0] = 100e18;
        amts[1] = 100e18;
        b.deposit(amts, 1000e18, ALICE);

        // Sanity: without the attack, redeem works and pays BOTH stocks.
        vm.prank(ALICE);
        uint256[] memory clean = b.redeem(100e18, ALICE);
        assertGt(clean[0], 0, "honest redeem pays stock 0");
        assertGt(clean[1], 0, "honest redeem pays the (unarmed) mal stock");

        // Arm the attack: mal.transfer re-enters redeem → ReentrancyGuard revert → CAUGHT (best-effort).
        mal.setAttack(true);
        uint256 supplyBefore = b.totalSupply();
        uint256 aliceMalBefore = mal.balanceOf(ALICE);
        uint256 basketMalBefore = mal.balanceOf(address(b));
        uint256 aliceS0Before = s0.balanceOf(ALICE);

        vm.prank(ALICE);
        uint256[] memory got = b.redeem(100e18, ALICE); // does NOT revert now

        // Honest leg delivered; malicious leg skipped (amount zeroed); shares burned EXACTLY once.
        assertGt(got[0], 0, "honest leg still delivered");
        assertEq(got[1], 0, "malicious leg skipped (best-effort)");
        assertEq(s0.balanceOf(ALICE) - aliceS0Before, got[0], "ALICE received the honest stock");
        assertEq(mal.balanceOf(ALICE), aliceMalBefore, "ALICE got NO mal (reentrancy blocked)");
        assertEq(mal.balanceOf(address(b)), basketMalBefore, "forfeited mal slice retained in basket");
        assertEq(b.totalSupply(), supplyBefore - 100e18, "shares burned once - no double redemption");
    }

    // ── S3: a paused/blacklisting stock is skipped; the others still deliver ─────

    function test_Redeem_PausedStockSkipped_BestEffort() public {
        MockPausableStock ps = new MockPausableStock("Paused", "PS", 18);
        address[] memory stx = new address[](3);
        stx[0] = address(s0);
        stx[1] = address(ps); // the stock that will be paused
        stx[2] = address(s1);
        StockBasket b = new StockBasket("BE", "BE", stx);
        b.setVault(address(this));

        s0.approve(address(b), type(uint256).max);
        s1.approve(address(b), type(uint256).max);
        ps.mint(address(this), 1e30);
        ps.approve(address(b), type(uint256).max);

        uint256[] memory amts = new uint256[](3);
        amts[0] = 100e18;
        amts[1] = 100e18;
        amts[2] = 100e18;
        b.deposit(amts, 1000e18, ALICE); // transferFrom works (pausable only pauses `transfer`)

        // Pause the middle stock: its redeem payout (transfer) now reverts.
        ps.setPaused(true);
        uint256 psBasketBefore = ps.balanceOf(address(b));

        vm.prank(ALICE);
        uint256[] memory got = b.redeem(1000e18, BOB); // redeem ALL — must NOT revert

        // Paused stock skipped (amounts[1]==0); the other two delivered to BOB.
        assertEq(got[1], 0, "paused stock skipped");
        assertGt(got[0], 0, "stock 0 delivered");
        assertGt(got[2], 0, "stock 2 delivered");
        assertEq(s0.balanceOf(BOB), got[0], "BOB got stock 0");
        assertEq(s1.balanceOf(BOB), got[2], "BOB got stock 2");
        assertEq(ps.balanceOf(BOB), 0, "BOB got NONE of the paused stock");
        // Forfeited slice stays in the basket for remaining holders.
        assertEq(ps.balanceOf(address(b)), psBasketBefore, "paused stock slice retained in basket");
        // Shares still fully burned despite the skip.
        assertEq(b.totalSupply(), 0, "all shares burned, no revert");
    }

    // ── S4 + L4: deposit's nonReentrant still blocks re-entry; the reverting leg is now SKIPPED ──

    /// @dev Post-L4, a deposit-reentrant stock is NEUTRALIZED, not fatal (symmetric with {redeem}'s S3): its
    ///      re-entrant `redeem` still hits the `nonReentrant` guard and reverts (no double redemption), but
    ///      the best-effort per-stock try/catch in {deposit} now CATCHES that revert and SKIPS only the
    ///      malicious leg — the honest leg is still pulled and shares still mint == `sharesToMint`.
    function test_Deposit_ReentrantStock_NeutralizedAndSkipped() public {
        MaliciousDepositReentrantStock mal = new MaliciousDepositReentrantStock();
        address[] memory stx = new address[](2);
        stx[0] = address(s0);
        stx[1] = address(mal);
        StockBasket b = new StockBasket("R", "R", stx);
        b.setVault(address(this));
        mal.setBasket(b);

        s0.approve(address(b), type(uint256).max);
        mal.mint(address(this), 1_000e18);
        mal.approve(address(b), type(uint256).max);

        // Arm: during the deposit pull of `mal`, its transferFrom re-enters redeem → guard reverts → CAUGHT
        // by the best-effort try/catch (L4) → the malicious leg is skipped, deposit does NOT revert.
        mal.setAttack(true);
        uint256[] memory amts = new uint256[](2);
        amts[0] = 100e18;
        amts[1] = 100e18;
        uint256 minted = b.deposit(amts, 1000e18, ALICE); // no revert now

        assertEq(minted, 1000e18, "shares minted == sharesToMint despite the skipped leg");
        assertEq(b.totalSupply(), 1000e18, "supply == shares (no double mint / no double redeem)");
        assertEq(b.balanceOf(ALICE), 1000e18, "recipient got the shares");
        // Honest leg pulled; malicious (reverting) leg skipped => its reserve stays 0.
        assertEq(s0.balanceOf(address(b)), 100e18, "honest stock 0 pulled in");
        assertEq(mal.balanceOf(address(b)), 0, "malicious leg skipped (reserve stays lighter)");
    }

    /// @dev L4 (non-reentrant): a plain paused / blacklisting stock whose `transferFrom` reverts is likewise
    ///      SKIPPED best-effort — deposit still mints and the healthy legs still land.
    function test_Deposit_BlacklistStockSkipped_BestEffort() public {
        RevertingTransferFromStock bad = new RevertingTransferFromStock();
        address[] memory stx = new address[](2);
        stx[0] = address(s0);
        stx[1] = address(bad);
        StockBasket b = new StockBasket("BE", "BE", stx);
        b.setVault(address(this));

        s0.approve(address(b), type(uint256).max);
        bad.mint(address(this), 1_000e18);
        bad.approve(address(b), type(uint256).max);
        bad.setRevert(true); // its transferFrom now reverts (blacklist parity)

        uint256[] memory amts = new uint256[](2);
        amts[0] = 100e18;
        amts[1] = 100e18;
        uint256 minted = b.deposit(amts, 1000e18, ALICE); // must NOT revert

        assertEq(minted, 1000e18, "shares still minted");
        assertEq(s0.balanceOf(address(b)), 100e18, "healthy leg pulled");
        assertEq(bad.balanceOf(address(b)), 0, "blacklisting leg skipped");
    }

    // ── S7: renounceOwnership is disabled ───────────────────────────────────────

    function test_RenounceOwnership_Disabled() public {
        // `basket`'s owner is this test contract (set in setUp), so onlyOwner passes → hits the revert.
        vm.expectRevert(bytes(unicode"Renounce disabled / 禁止放弃所有权"));
        basket.renounceOwnership();
        assertEq(basket.owner(), address(this), "owner unchanged");
    }

    function test_Redeem_MoreThanHeldReverts() public {
        _deposit(10e18, 10e18, 10e6, 10e18, 100e18, ALICE);
        vm.prank(ALICE);
        // OZ v4 ERC20 burn: "ERC20: burn amount exceeds balance"
        vm.expectRevert(bytes("ERC20: burn amount exceeds balance"));
        basket.redeem(101e18, ALICE);
    }

    function test_Redeem_ZeroSharesReverts() public {
        _deposit(10e18, 10e18, 10e6, 10e18, 100e18, ALICE);
        vm.prank(ALICE);
        vm.expectRevert(bytes(unicode"Zero shares / 份额为零"));
        basket.redeem(0, ALICE);
    }

    function test_Redeem_ZeroToReverts() public {
        _deposit(10e18, 10e18, 10e6, 10e18, 100e18, ALICE);
        vm.prank(ALICE);
        vm.expectRevert(bytes(unicode"Zero address / 零地址"));
        basket.redeem(1e18, address(0));
    }

    // ── 11. Dust: redeem entire supply across holders ───────────────────────────

    function test_Dust_FullRedemptionAcrossHolders() public {
        // Use amounts that don't divide evenly by the share splits to exercise integer-division dust.
        _deposit(100e18 + 7, 3, 55e6 + 1, 40e18 + 9, 333e18, ALICE);
        _deposit(1, 200e18 + 3, 1, 1, 667e18, BOB); // total supply 1000e18

        uint256[] memory r0 = basket.reserves();

        vm.prank(ALICE);
        basket.redeem(333e18, ALICE);
        vm.prank(BOB);
        basket.redeem(667e18, BOB); // BOB (last redeemer) sweeps the remainder — no revert

        assertEq(basket.totalSupply(), 0, "fully redeemed, no revert");

        // Leftover reserve dust must be tiny — strictly less than the number of holders (2) per stock,
        // since each integer-division truncation loses < 1 unit and there are 2 redemptions.
        uint256[] memory rEnd = basket.reserves();
        for (uint256 i = 0; i < N; i++) {
            assertLt(rEnd[i], 2, "dust < holders");
            assertLe(rEnd[i], r0[i], "dust never exceeds original reserve");
        }
    }
}
