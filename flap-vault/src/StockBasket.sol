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
///     and mints `sharesToMint` new shares. The vault sizes `sharesToMint` to the **WBNB value it
///     spent that round**, so one share always represents the same amount of value put in, regardless
///     of which stocks were bought or how their prices move. This is the fairness anchor and it is
///     ORACLE-FREE: the basket never needs to price a stock.
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

    // ── Events ───────────────────────────────────────────────────────────────

    /// @notice Emitted once at construction with the frozen list of underlying stocks.
    event BasketCreated(address[] stocks);
    /// @notice Emitted once when {setVault} binds the sole minter.
    event VaultSet(address indexed vault);
    /// @notice Emitted on each {deposit}: the vault-supplied stock amounts pulled in and the shares minted.
    event Deposited(address indexed from, address indexed to, uint256[] amounts, uint256 sharesMinted);
    /// @notice Emitted on each {redeem}: the shares burned and the pro-rata stock amounts paid out.
    event Redeemed(address indexed from, address indexed to, uint256 shares, uint256[] amounts);

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

    /// @notice Pull `amounts[i]` of each underlying stock from the caller (the {vault}) and mint
    ///         `sharesToMint` new basket shares to `to`.
    /// @dev    The caller MUST have approved this basket to move each `amounts[i]`. Reserves are read
    ///         via `balanceOf` at redeem time, so NO reserves variable is written here — a fee-on-transfer
    ///         stock that delivers less than `amounts[i]` is handled naturally (the basket simply holds,
    ///         and later redeems, whatever actually arrived). `sharesToMint` is the vault's WBNB value
    ///         spent this round; sizing shares to value-in is what keeps redemptions fair (see contract
    ///         NatSpec). Effects (mint) follow the interactions (pull) here because the pulls are from the
    ///         trusted vault and `_mint` touches only this basket's own supply — there is no external
    ///         call after the mint to re-enter.
    /// @param  amounts      Per-stock amount to pull, positionally paired with {stocks} (same length).
    /// @param  sharesToMint Basket shares to mint (the WBNB value spent this round); must be > 0.
    /// @param  to           Recipient of the freshly-minted shares (non-zero).
    /// @return minted       The number of shares minted (== `sharesToMint`).
    function deposit(uint256[] calldata amounts, uint256 sharesToMint, address to)
        external
        onlyVault
        nonReentrant
        returns (uint256 minted)
    {
        require(amounts.length == stocks.length, unicode"Length mismatch / 长度不匹配");
        require(sharesToMint > 0, unicode"Zero shares / 份额为零");
        require(to != address(0), unicode"Zero address / 零地址");

        for (uint256 i = 0; i < amounts.length; i++) {
            // Guard zero-amount pulls (S2): a best-effort-skipped leg (amounts[i]==0) must NOT call
            // transferFrom — some ERC-20s revert on a zero-value transfer, which would brick the whole
            // deposit (and thus the vault's `distribute`) for a single unhealthy pool.
            //
            // BEST-EFFORT PER STOCK (L4): each non-zero pull is isolated in {_pull}'s external self-call
            // inside a try/catch, so a single paused / blacklisting stock is SKIPPED — its reserve simply
            // stays lighter while shares still mint == `sharesToMint` — instead of reverting the whole
            // deposit. This is symmetric with {redeem}'s per-stock payout. `nonReentrant` (S4) still holds:
            // a code-executing stock's transferFrom hook that re-enters {redeem} hits the guard and reverts,
            // and that revert is CAUGHT here — the malicious leg is skipped (never a double redemption).
            if (amounts[i] > 0) {
                try this._pull(stocks[i], msg.sender, amounts[i]) {}
                catch {
                    /* paused / blacklisting / reentrant stock: skip this leg (its reserve stays lighter) */
                }
            }
        }

        _mint(to, sharesToMint);
        emit Deposited(msg.sender, to, amounts, sharesToMint);
        return sharesToMint;
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
    ///         the whole redemption — the other stocks still deliver. TRADEOFF: a skipped stock's slice is
    ///         FORFEITED by this redeemer (the shares are already burned) and stays in the basket,
    ///         benefiting the remaining holders. The returned `amounts` reflect what was ACTUALLY paid (a
    ///         skipped leg is zeroed).
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
            uint256 bal = IERC20(stocks[i]).balanceOf(address(this));
            amounts[i] = (shares * bal) / supply;
        }

        // ── Effects: burn before any external transfer (also enforces caller's balance). ──
        _burn(msg.sender, shares);

        // ── Interactions: pay out each stock BEST-EFFORT (S3). ──
        for (uint256 i = 0; i < n; i++) {
            if (amounts[i] > 0) {
                // Isolate each stock's transfer in its own external self-call so one reverting stock
                // (paused / blacklisting) is caught and SKIPPED — its slice stays in the basket (forfeit)
                // — while the remaining stocks still deliver. `amounts[i]` is zeroed so the return value
                // reflects what was actually paid.
                try this._payout(stocks[i], to, amounts[i]) {}
                catch {
                    amounts[i] = 0;
                }
            }
        }

        emit Redeemed(msg.sender, to, shares, amounts);
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
            amounts[i] = (shares * IERC20(stocks[i]).balanceOf(address(this))) / supply;
        }
    }

    /// @notice The basket's current balance of each underlying stock (the live reserves).
    /// @return bals Per-stock balance, positionally paired with {stocks}.
    function reserves() external view returns (uint256[] memory bals) {
        uint256 n = stocks.length;
        bals = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            bals[i] = IERC20(stocks[i]).balanceOf(address(this));
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
