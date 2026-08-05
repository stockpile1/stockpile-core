// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {Ownable} from "@openzeppelin/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/security/ReentrancyGuard.sol";
import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";

/// @title StockBasket
/// @author The Stockpile Team
/// @notice An ERC-20 *index* token backed by a fixed set of `N` underlying "stock" tokens.
///         It is the single **yield token** every Stockpile grid pays out: rather than each grid
///         earning one stock, all grids earn basket shares, and a share redeems for a pro-rata slice
///         of ALL `N` stocks at once.
///
/// @dev  ── HOW IT WORKS ───────────────────────────────────────────────────────────
///
///   • A vault (the sole minter, set once via {setVault}) periodically swaps a WBNB fee stream into
///     the `N` stocks, then calls {deposit}: it transfers the freshly-bought stocks into the basket
///     and mints new shares sized to the **WBNB value that actually landed** — the per-leg spend of
///     every stock whose transfer into the basket succeeded. One share therefore always represents the
///     same amount of value put in, regardless of which stocks were bought, how their prices move, or
///     whether some leg had to be skipped. This is the fairness anchor and it is ORACLE-FREE: the
///     basket never needs to price a stock.
///
///   • Seat holders across every grid receive these basket shares as yield. To realize them, a holder
///     calls {redeem}: it burns their `shares` and returns `shares / totalSupply` of the basket's
///     CURRENT balance of every stock. Because the claim is a flat fraction of the whole reserve,
///     **equal shares always redeem for equal amounts of each stock** — no holder can extract more of
///     any one stock than another holder with the same share count (see {redeem}).
///
///   ── RESERVES ARE READ VIA balanceOf (FoT-SAFE) ─────────────────────────────────
///
///   The basket stores NO `reserves` variable. Every redemption sizes each payout from the live
///   `IERC20(stock).balanceOf(address(this))`. This makes it correct by construction for
///   fee-on-transfer stocks (the basket only ever pays out what it actually holds, so it can never
///   over-withdraw) and immune to accounting drift from any direct/donated transfer.
///
///   ── SAFETY ─────────────────────────────────────────────────────────────────────
///
///   {redeem} follows strict CEI — it computes every payout from PRE-burn balances, burns the shares
///   (effects), then transfers the stocks out (interactions) — and is `nonReentrant`. All token moves
///   use SafeERC20. Per the Stockpile convention (Flap Rule 004 / UI-01) reverts use literal
///   **bilingual** `require` strings, never custom errors, so a generic UI can render the reason as-is.
contract StockBasket is ERC20, ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;

    // ── Storage ──────────────────────────────────────────────────────────────

    /// @notice The `N` underlying stock tokens backing the index, fixed at construction. Positional
    ///         order is stable and matches the `amounts` / returned-array order of {deposit} / {redeem}.
    ///         The public getter `stocks(uint256)` returns the token at a given index.
    address[] public stocks;

    /// @notice The sole address permitted to {deposit} (mint shares). Set exactly once, after
    ///         construction, via {setVault} — see the deploy-order note there. Zero until set.
    address public vault;

    /// @notice stock => recipient => amount owed from a {redeem} payout leg that reverted.
    /// @dev    A redeemer's shares are burned atomically for the whole basket, so a leg whose transfer
    ///         fails cannot be "un-burned". Instead of forfeiting that slice, it is booked here and the
    ///         recipient pulls it later via {claimUnpaid} once the stock is healthy again.
    mapping(address => mapping(address => uint256)) public unpaid;

    /// @notice stock => total amount booked in {unpaid} across all recipients.
    /// @dev    Deferred slices are already spoken for, so they are EXCLUDED from the pro-rata base used by
    ///         {redeem} / {previewRedeem} / {reserves}. Without this they would be counted as free reserve
    ///         and paid out twice — once to the deferred claimant and again to later redeemers.
    mapping(address => uint256) public totalDeferred;

    // ── Events ───────────────────────────────────────────────────────────────

    /// @notice Emitted once at construction with the frozen list of underlying stocks.
    event BasketCreated(address[] stocks);
    /// @notice Emitted once when {setVault} binds the sole minter.
    event VaultSet(address indexed vault);
    /// @notice Emitted on each {deposit}: the vault-supplied stock amounts pulled in and the shares minted.
    event Deposited(address indexed from, address indexed to, uint256[] amounts, uint256 sharesMinted);
    /// @notice Emitted when a stock pull is skipped in {deposit} (paused / blacklisting / reverting stock).
    ///         Its `legValue` is NOT minted, so the skip cannot dilute existing holders (AUDIT H-02).
    event PullSkipped(uint256 indexed legIndex, address indexed stock, uint256 amount, uint256 legValue);
    /// @notice Emitted on each {redeem}: the shares burned and the pro-rata stock amounts paid out.
    event Redeemed(address indexed from, address indexed to, uint256 shares, uint256[] amounts);
    /// @notice Emitted when a {redeem} payout leg reverts and its slice is booked for later collection.
    event PayoutDeferred(address indexed stock, address indexed to, uint256 amount);
    /// @notice Emitted when a previously deferred slice is collected via {claimUnpaid}.
    event UnpaidClaimed(address indexed stock, address indexed owner, address indexed to, uint256 amount);

    // ── Modifiers ────────────────────────────────────────────────────────────

    /// @notice Restrict a call to the bound {vault} (the sole minter).
    modifier onlyVault() {
        require(msg.sender == vault, unicode"Only vault / 仅限金库");
        _;
    }

    // ── Constructor ──────────────────────────────────────────────────────────

    /// @notice Deploy the index and freeze its underlying stock set. The deployer becomes the {owner}.
    /// @dev    Validates that `_stocks` is non-empty, every entry is non-zero, and there are NO
    ///         duplicates (an O(n²) pairwise scan — the list is short and set once). A duplicate stock
    ///         would let {redeem} pay out the same reserve twice, so it is rejected at construction.
    /// @param  name_   ERC-20 name of the basket share token.
    /// @param  symbol_ ERC-20 symbol of the basket share token.
    /// @param  _stocks The underlying stock tokens (non-empty, each non-zero, all distinct).
    constructor(string memory name_, string memory symbol_, address[] memory _stocks) ERC20(name_, symbol_) {
        require(_stocks.length > 0, unicode"No stocks / 无股票");
        for (uint256 i = 0; i < _stocks.length; i++) {
            require(_stocks[i] != address(0), unicode"Zero stock / 股票地址为零");
            for (uint256 j = i + 1; j < _stocks.length; j++) {
                require(_stocks[i] != _stocks[j], unicode"Duplicate stock / 股票重复");
            }
            stocks.push(_stocks[i]);
        }
        emit BasketCreated(_stocks);
    }

    // ── Vault binding (one-shot, owner-only) ─────────────────────────────────

    /// @notice Bind the sole minter. One-shot: reverts if {vault} is already set, so the minter can
    ///         never be swapped out from under holders.
    /// @dev    Deploy order is: (1) deploy this basket, (2) deploy the vault passing this basket's
    ///         address, (3) call `basket.setVault(vault)` here. Splitting the wiring avoids a
    ///         constructor cycle between the two contracts.
    /// @param  v The vault address (non-zero).
    function setVault(address v) external onlyOwner {
        require(vault == address(0), unicode"Vault already set / 金库已设置");
        require(v != address(0), unicode"Zero address / 零地址");
        vault = v;
        emit VaultSet(v);
    }

    /// @notice Disabled (S7): renouncing ownership BEFORE {setVault} binds the minter would permanently
    ///         strand the basket with no way to ever deposit — so it always reverts (mirrors the vault).
    /// @dev    Uses `require(false, …)` rather than `revert(string)` for the literal bilingual form the
    ///         Stockpile convention (Flap Rule 004 / UI-01) prefers (I4).
    function renounceOwnership() public override onlyOwner {
        require(false, unicode"Renounce disabled / 禁止放弃所有权");
    }

    // ── Mint path (vault-only) ───────────────────────────────────────────────

    /// @notice Pull `amounts[i]` of each underlying stock from the caller (the {vault}) and mint shares to
    ///         `to` sized to the value of the legs that ACTUALLY landed: `sum(legValues[i])` over the
    ///         successful pulls only.
    /// @dev    The caller MUST have approved this basket to move each `amounts[i]`. Reserves are read
    ///         via `balanceOf` at redeem time, so NO reserves variable is written here — a fee-on-transfer
    ///         stock that delivers less than `amounts[i]` is handled naturally (the basket simply holds,
    ///         and later redeems, whatever actually arrived). Effects (mint) follow the interactions (pull)
    ///         here because the pulls are from the trusted vault and `_mint` touches only this basket's own
    ///         supply — there is no external call after the mint to re-enter.
    ///
    ///         SHARES ARE SIZED TO VALUE THAT LANDED (AUDIT H-02). `legValues[i]` is the vault's WBNB spend
    ///         on leg `i` this round, and a leg only contributes to the mint if its pull SUCCEEDED. This
    ///         preserves the contract's fairness anchor — one share always represents the same amount of
    ///         value actually put in — even when a paused / blacklisting stock is skipped. Minting the full
    ///         round value regardless (the previous behaviour) grew supply without growing reserves and so
    ///         diluted every existing holder by the skipped leg's weight.
    ///
    ///         A round where EVERY pull fails mints nothing and returns 0 rather than reverting, so one
    ///         universally-broken stock set cannot brick the vault's `distribute`.
    /// @param  amounts   Per-stock amount to pull, positionally paired with {stocks} (same length).
    /// @param  legValues Per-stock WBNB value backing `amounts[i]`, positionally paired with {stocks}.
    ///                   Only entries whose pull succeeds are minted.
    /// @param  to        Recipient of the freshly-minted shares (non-zero).
    /// @return minted    Shares minted == summed `legValues` of the legs that landed (0 if none did).
    function deposit(uint256[] calldata amounts, uint256[] calldata legValues, address to)
        external
        onlyVault
        nonReentrant
        returns (uint256 minted)
    {
        require(amounts.length == stocks.length, unicode"Length mismatch / 长度不匹配");
        require(legValues.length == stocks.length, unicode"legValues length mismatch / legValues长度不匹配");
        require(to != address(0), unicode"Zero address / 零地址");

        for (uint256 i = 0; i < amounts.length; i++) {
            // Guard zero-amount pulls (S2): a best-effort-skipped leg (amounts[i]==0) must NOT call
            // transferFrom — some ERC-20s revert on a zero-value transfer, which would brick the whole
            // deposit (and thus the vault's `distribute`) for a single unhealthy pool.
            //
            // BEST-EFFORT PER STOCK (L4): each non-zero pull is isolated in {_pull}'s external self-call
            // inside a try/catch, so a single paused / blacklisting stock is SKIPPED instead of reverting
            // the whole deposit. Its `legValues[i]` is then NOT credited, so the skip costs the round its
            // own value rather than diluting existing holders (H-02). This is symmetric with {redeem}'s
            // per-stock payout. `nonReentrant` (S4) still holds: a code-executing stock's transferFrom hook
            // that re-enters {redeem} hits the guard and reverts, and that revert is CAUGHT here — the
            // malicious leg is skipped (never a double redemption).
            if (amounts[i] > 0) {
                try this._pull(stocks[i], msg.sender, amounts[i]) {
                    minted += legValues[i];
                } catch {
                    /* paused / blacklisting / reentrant stock: skip this leg AND its value */
                    emit PullSkipped(i, stocks[i], amounts[i], legValues[i]);
                }
            }
        }

        if (minted > 0) _mint(to, minted);
        emit Deposited(msg.sender, to, amounts, minted);
    }

    /// @notice Self-gated pull helper for {deposit}'s best-effort per-stock intake (L4): pulls `amt` of
    ///         `token` from `from` into the basket. Isolating each pull in an external self-call lets
    ///         {deposit} catch a reverting stock (paused / blacklisting / reentrant) and skip just that leg.
    /// @dev    Callable ONLY by this contract (invoked as `this._pull(...)` from within {deposit}); the
    ///         self-gate makes it a no-op attack surface for anyone else. Not `nonReentrant` — it runs
    ///         inside {deposit}'s guarded frame, so a hostile stock re-entering {redeem} from here is caught
    ///         by that guard and safely skipped.
    function _pull(address token, address from, uint256 amt) external {
        require(msg.sender == address(this), unicode"Only self / 仅限自身");
        IERC20(token).safeTransferFrom(from, address(this), amt);
    }

    // ── Redeem path (permissionless, holders) ────────────────────────────────

    /// @notice Burn `shares` from the caller and send them a pro-rata slice of EVERY underlying stock:
    ///         for each stock `i`, `amounts[i] = shares * balanceOf(stock i) / totalSupply` (pre-burn).
    /// @dev    Strict CEI + `nonReentrant`: all `amounts[i]` are computed from PRE-burn balances, the
    ///         shares are burned (effects), and only then are the stocks transferred out (interactions),
    ///         so a hostile stock's transfer hook can neither re-enter nor observe an inconsistent supply.
    ///         The redeemer necessarily holds `shares > 0`, so `totalSupply() > 0` and the division is
    ///         safe. Payouts of 0 (a stock the basket holds none of, or a slice that rounds to 0) skip
    ///         their transfer. Because slices use `balanceOf`, the basket pays out only what it truly
    ///         holds — fee-on-transfer stocks and donated dust are both handled without over-withdrawing.
    ///
    ///         BEST-EFFORT PER STOCK (S3): each payout is made through the self-gated {_payout} helper in
    ///         its own try/catch, so a SINGLE paused / blacklisting stock is SKIPPED instead of bricking
    ///         the whole redemption — the other stocks still deliver. A deferred stock's slice is NOT
    ///         forfeited (AUDIT v9 Finding 3): the shares are burned atomically for the whole basket and
    ///         cannot be un-burned for one leg, so the slice is credited to `to` in {unpaid} and collected
    ///         later via {claimUnpaid}. It is excluded from the pro-rata base by {totalDeferred} so it is
    ///         never paid out twice. The returned `amounts` reflect what was ACTUALLY paid (a deferred leg
    ///         is zeroed).
    /// @param  shares Amount of basket shares to redeem (must be > 0; caller must hold at least this many,
    ///                enforced by `_burn`).
    /// @param  to     Recipient of the redeemed stocks (non-zero).
    /// @return amounts Per-stock amount transferred out, positionally paired with {stocks}.
    function redeem(uint256 shares, address to) external nonReentrant returns (uint256[] memory amounts) {
        require(shares > 0, unicode"Zero shares / 份额为零");
        require(to != address(0), unicode"Zero address / 零地址");

        uint256 supply = totalSupply(); // redeemer holds `shares` > 0 ⇒ supply > 0
        uint256 n = stocks.length;
        amounts = new uint256[](n);

        // ── Compute every payout from PRE-burn balances (CEI: interactions come last). ──
        for (uint256 i = 0; i < n; i++) {
            amounts[i] = (shares * _available(stocks[i])) / supply;
        }

        // ── Effects: burn before any external transfer (also enforces caller's balance). ──
        _burn(msg.sender, shares);

        // ── Interactions: pay out each stock BEST-EFFORT (S3). ──
        for (uint256 i = 0; i < n; i++) {
            if (amounts[i] > 0) {
                // Isolate each stock's transfer in its own external self-call so one reverting stock
                // (paused / blacklisting) is caught and SKIPPED — the remaining stocks still deliver.
                try this._payout(stocks[i], to, amounts[i]) {}
                catch {
                    // The slice is BOOKED, not forfeited (AUDIT v9 Finding 3). The shares are already
                    // burned and cannot be un-burned for one leg, so instead of letting the slice accrete
                    // to the remaining holders it is credited to `to`, who collects it via {claimUnpaid}
                    // once the stock is healthy. It is also removed from the pro-rata base by
                    // {totalDeferred} so later redeemers cannot be paid the same tokens.
                    unpaid[stocks[i]][to] += amounts[i];
                    totalDeferred[stocks[i]] += amounts[i];
                    emit PayoutDeferred(stocks[i], to, amounts[i]);
                    amounts[i] = 0; // the return value reflects what was ACTUALLY paid
                }
            }
        }

        emit Redeemed(msg.sender, to, shares, amounts);
    }

    /// @notice Collect a slice that a previous {redeem} could not deliver because the stock's transfer
    ///         reverted at the time (paused / blacklisting).
    /// @dev    Permissionless for the credited owner; `to` lets a since-blacklisted holder redirect the
    ///         payout. NOT best-effort: if the stock still refuses the transfer this reverts and the
    ///         credit is preserved for a later attempt.
    /// @param  stock The underlying stock to collect.
    /// @param  to    Recipient of the collected tokens (non-zero).
    /// @return amount The amount transferred.
    function claimUnpaid(address stock, address to) external nonReentrant returns (uint256 amount) {
        require(to != address(0), unicode"Zero address / 零地址");
        amount = unpaid[stock][msg.sender];
        require(amount > 0, unicode"Nothing owed / 无欠款");

        unpaid[stock][msg.sender] = 0;
        totalDeferred[stock] -= amount;

        IERC20(stock).safeTransfer(to, amount);
        emit UnpaidClaimed(stock, msg.sender, to, amount);
    }

    /// @dev The portion of `stock` the basket holds that is NOT already owed to a deferred claimant, i.e.
    ///      the base every pro-rata calculation must use.
    function _available(address stock) internal view returns (uint256) {
        return IERC20(stock).balanceOf(address(this)) - totalDeferred[stock];
    }

    /// @notice Self-gated payout helper for {redeem}'s best-effort per-stock delivery: transfers `amount`
    ///         of `token` to `to`. Isolating each transfer in an external self-call lets {redeem} catch a
    ///         reverting stock (paused / blacklisting) and skip just that leg.
    /// @dev    Callable ONLY by this contract (invoked as `this._payout(...)` from within {redeem}); the
    ///         self-gate makes it a no-op attack surface for anyone else. Not `nonReentrant` — it runs
    ///         inside {redeem}'s guarded frame, and a hostile stock that tries to re-enter {redeem} from
    ///         here is caught by that guard and safely skipped.
    function _payout(address token, address to, uint256 amount) external {
        require(msg.sender == address(this), unicode"Only self / 仅限自身");
        IERC20(token).safeTransfer(to, amount);
    }

    // ── Views ────────────────────────────────────────────────────────────────

    /// @notice Preview {redeem} without mutating state: the per-stock amounts `shares` would return NOW.
    /// @dev    Mirrors {redeem}'s math exactly (pre-burn balances / current supply). Reverts on the same
    ///         `shares == 0` guard so a UI gets a clear reason; otherwise never reverts.
    /// @param  shares Hypothetical shares to redeem (> 0).
    /// @return amounts Per-stock amount that would be paid out, positionally paired with {stocks}.
    function previewRedeem(uint256 shares) external view returns (uint256[] memory amounts) {
        require(shares > 0, unicode"Zero shares / 份额为零");
        uint256 supply = totalSupply();
        uint256 n = stocks.length;
        amounts = new uint256[](n);
        if (supply == 0) return amounts; // no shares exist ⇒ nothing to redeem
        for (uint256 i = 0; i < n; i++) {
            amounts[i] = (shares * _available(stocks[i])) / supply;
        }
    }

    /// @notice The basket's CLAIMABLE reserve of each underlying stock: its balance minus anything already
    ///         booked in {unpaid} for a deferred claimant. Equals the raw balance whenever nothing is
    ///         deferred, which is the normal case.
    /// @return bals Per-stock claimable reserve, positionally paired with {stocks}.
    function reserves() external view returns (uint256[] memory bals) {
        uint256 n = stocks.length;
        bals = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            bals[i] = _available(stocks[i]);
        }
    }

    /// @notice The full ordered list of underlying stock tokens.
    function getStocks() external view returns (address[] memory) {
        return stocks;
    }

    /// @notice The number of underlying stocks (`N`).
    function stocksLength() external view returns (uint256) {
        return stocks.length;
    }
}
