I've verified every claim against the actual source (both contracts + the real UGM). Here is the consolidated audit.

---

# Lead-auditor synthesis — StockBasket + StockpileBasketVault

Scope verified against: `contracts/vault/src/StockBasket.sol`, `contracts/vault/src/StockpileBasketVault.sol`, and integration surface `contracts/core/src/core/UnifiedGridManager.sol` + `GridTypes.sol`. Trust model applied: `deposit` is vault-only; the vault is the sole trusted minter; keeper is trusted; grids are guardian-created (`MIN_TOTAL_SEATS=4`, seats immutable) and registration-validated.

## (1) Ranked findings

| ID | Sev | Title | file:line | Status | One-line fix |
|----|-----|-------|-----------|--------|--------------|
| **S1** | **Med** | Commission re-skimmed on retained WBNB every round → breaks "≥90% to grids" | `StockpileBasketVault.sol:450-468` | **CONFIRMED** | Skim after the swap phase, sized to `spentWBNB`; skim nothing when `spentWBNB==0` |
| **S2** | **Med** | Unconditional `safeTransferFrom` on zero-amount legs bricks `distribute` (defeats best-effort) | `StockBasket.sol:140-142` | **CONFIRMED** (token-dep.) | `if (amounts[i] > 0)` guard the pull in `deposit` |
| **S3** | **Med** | One paused/blacklisting stock bricks `redeem` for the whole basket — no escape hatch | `StockBasket.sol:182-186` | **CONFIRMED** (token-dep.) | try/catch per-stock transfer, and/or add a guardian rescue path on the basket |
| **S4** | **Med** | `deposit` not `nonReentrant` + interactions-before-mint → reenter `redeem`, drain in-flight deposit | `StockBasket.sol:131-147` | **PLAUSIBLE** | Add `nonReentrant` to `deposit` |
| **S5** | **Low-Med** | Zero-output swap leg mints unbacked shares and burns the WBNB | `StockpileBasketVault.sol:507-509,544` | **PLAUSIBLE** | `require(out > 0)` in `swapLeg` so a 0-out leg reverts → is caught/skipped |
| **S6** | **Low** | Grid feed is all-or-nothing; a mis-set grid or adapter-hijack permanently bricks `distribute` for ALL grids | `StockpileBasketVault.sol:576-609` | **PLAUSIBLE** | Make the grid push best-effort (retain un-pushable share); salt `assetHash` / register in deploy tx |
| **S7** | **Low/Info** | Basket doesn't override `renounceOwnership`; renounce-before-`setVault` permanently bricks it | `StockBasket.sol:46,108` | **CONFIRMED** | Override `renounceOwnership` to revert (as the vault does at `:662`) |
| — | Info | `minInterval==0` allowed; no on-chain slippage floor; unbounded leg count | `:284,438,332` | hardening | Enforce a nonzero interval floor + require keepers pass nonzero `minOut`; cap N/M |

---

## (2) Real findings — failure scenario + precise fix

**S1 — Commission re-skim on retained WBNB.** `distribute` computes `commission = gross*commissionBps/10000` on the **full** WBNB balance and transfers it to `treasury` at line 457-459, *before* the swap phase; `gross` (line 447) includes any WBNB retained from previously-skipped legs. Failed legs keep their WBNB on the vault (by design, line 511), and the `spentWBNB==0` path returns after the skim (465-468).
- Scenario (no malice, no exotic token): `commissionBps=1000`, one of three pools is dead. Round 1: `gross=1000`, skim 100 to treasury, leg C's 300 WBNB reverts and is retained, `spentWBNB=700`. Round 2 (fees=0): `gross=300` (the carried-over) → skim **another 30**. Leg C's slice is taxed twice; a persistent dead pool compounds to ~65% siphoned over 10 rounds. Fires on any *partial*-failure round, not just total failure. Money lands in `treasury` (trusted) but is misaccounted and permanently diverted from seat holders, contradicting the invariant asserted at `:127-128`.
- Fix: move the skim to *after* `_swapAll` and base it only on what actually distributed, e.g. `commission = spentWBNB * bps / (10_000 - bps)` (or `gross*bps/10_000` only when `spentWBNB>0`); take **no** commission on the `spentWBNB==0` return so retained WBNB is never re-taxed.

**S2 — Zero-amount pull bricks `distribute`.** `StockBasket.deposit` loops **unconditionally**: `IERC20(stocks[i]).safeTransferFrom(msg.sender, this, amounts[i])` for every `i` (140-142), with no `amounts[i] > 0` guard — note the vault's own `_depositToBasket` *does* guard its approvals (`:557`), but the basket doesn't guard the transfer.
- Scenario: a dead pool makes leg `i` skip (`amounts[i]=0`) while others succeed (`spentWBNB>0`). `distribute` calls `basket.deposit([a0, 0, a2], …)`. If `stocks[1]` reverts on zero-value transfers (a known real-token behavior), the whole `deposit` — and thus the whole `distribute` — reverts. One unhealthy pool now bricks every distribute; the per-leg try/catch resilience is nullified. (Funds are recoverable via `emergencyWithdraw*`, so this is liveness, not loss.)
- Fix: `if (amounts[i] > 0) IERC20(stocks[i]).safeTransferFrom(...)` in `StockBasket.deposit`.

**S3 — One reverting stock bricks the entire `redeem`.** `redeem` transfers every non-zero stock with `safeTransfer` and **no** try/catch (182-186). A single basket stock that is globally paused, or that blacklists the `to`/basket (USDC/USDT-class), reverts the whole call — the holder gets *none* of their N stocks, and a global pause blocks *all* holders. The basket has no owner power beyond one-shot `setVault`, and the vault's `emergencyWithdraw*` operates on the vault, not on stocks held **inside** the basket — so value is stranded with no escape hatch.
- Fix: wrap each payout in try/catch (skip the failing stock, deliver the rest) — accepting that the skipped slice is forfeited — and/or add a guardian-gated partial/emergency redeem on the basket so a stuck stock can't strand the others.

**S4 — `deposit` reentrancy into `redeem`.** `deposit` has no `nonReentrant` and mints *after* pulling stocks (`_mint` at 144 follows the pull loop 140-142). OZ's `ReentrancyGuard` status is per-contract but only engaged by a `nonReentrant` entry — `redeem` has it, `deposit` doesn't — so a call that enters via `deposit` leaves the guard free for `redeem`.
- Scenario: basket `[A, MAL]`, `MAL` runs code on `transferFrom` and the attacker holds basket shares. `distribute → deposit`: pulling A grows the A reserve; pulling MAL fires a hook that re-enters `redeem(attackerShares)`, which prices payouts against the **already-inflated reserves at the still-old supply** (mint hasn't happened), draining the freshly-deposited stock. Precondition — a code-executing token in the curated set + attacker-held shares — caps this at PLAUSIBLE, but the fix is free and the trust-in-vault does not help (the reentrancy comes from the stock token, not the caller).
- Fix: add `nonReentrant` to `deposit`.

**S5 — Zero-output leg mints unbacked shares.** In `_swapAll`, `spentWBNB += amountIn` is added for **every non-reverting** leg (509), and `swapLeg` never requires `out > 0` (544). With `minOut[i]==0` (`amountOutMinimum=0` — what every test passes), a pool that consumes `amountIn` and returns `out=0` does not revert: `amounts[i]=0` but `spentWBNB` counts the full `amountIn`, so `deposit` mints shares for WBNB that bought nothing → existing holders (all grids) diluted and the WBNB is lost to the pool. The trusted-keeper `minOut` is the *only* thing holding this back (a nonzero `minOut` makes `out<minOut` revert → the leg is safely skipped), which is why it's Low-Med rather than higher — but the code has zero defense and the tests exercise the unsafe path.
- Fix: `require(out > 0, …)` at the end of `swapLeg`, so a 0-output leg reverts, rolls back, is caught, and its WBNB is retained instead of burned. Additionally enforce/document that keepers never pass `minOut=0`.

**S6 — Non-best-effort grid feed can permanently brick.** `_feedGrids` pushes each grid with a bare `receiveYieldERC20` (605), no try/catch; the `require(totalSeats>0)` at 589 is on the **sum**. If any single leg can't be satisfied, the whole `distribute` reverts forever, and grid legs are immutable (no remove/replace). Two real triggers: (a) a deploy leg whose grid `yieldToken != basket` can never register (`registerWithGrid` asserts it at `:626`) → permanent brick, redeploy required; (b) a **hijack** — `assetHash = keccak256("StockpileBasketVault", vault, gridId)` is public, and any *approved adapter* on the shared UGM can `registerAsset` it first (UGM `:593-599`), after which the vault's `registerWithGrid` reverts `"registered"` and `receiveYieldERC20` reverts `"not adapter"`. (b) requires a malicious/buggy entity on the UGM-owner-granted `approvedAdapters` list, so it's privileged cross-tenant griefing on shared infra, not anyone-can-do-it.
- Fix: make the grid push best-effort (try/catch, retain the un-pushable share as basket dust for next round) and/or let the guardian disable a dead leg; salt `assetHash` with a private nonce, or register atomically in the deploy tx, to close the pre-registration race. Add an explicit `if (seats[j]==0) continue;` for hygiene.

**S7 — Basket `renounceOwnership` not disabled.** Unlike the vault (`:662`), `StockBasket` inherits OZ Ownable unchanged. If the owner renounces before the one-shot `setVault` (108), no minter can ever be bound and the basket is permanently dead. Deploy-ordering footgun, not attacker-reachable.
- Fix: override `renounceOwnership()` to revert on the basket too (or fold the vault binding into the constructor).

---

## (3) Cleared — raised but does NOT survive scrutiny

- **Zero-seat grid → div-by-zero in `receiveYieldERC20` (`UGM:629`)** — raised by all four lenses. **Unreachable:** `createGrid` enforces `totalSeats >= MIN_TOTAL_SEATS(4)` (`:227`), seats are immutable (no setter), and a grid can only be registered if `yieldToken==basket` (i.e. it must exist). Keep only as a one-line defensive `seats[j]==0` skip; not a bug.
- **First-deposit inflation / donation attack** — REFUTED. `deposit` is `onlyVault` and mints an explicit `sharesToMint` fully decoupled from reserves; a token donation lifts every holder's `redeem` pro-rata (a gift, never a skew). No vector.
- **Redeem over-withdraw / FoT drift** — safe. `amounts[i] = shares*balanceOf/supply` (floor), CEI + `nonReentrant`, `balanceOf`-based, so it can never pay more than it holds.
- **`GridConfig` ABI-decode mismatch** — REFUTED. Verified byte-identical: vault local struct == `GridTypes.sol` (`creator, uint64 createdAt, uint32 totalSeats, uint16 taxRateBps, uint32 forfeitureDuration, taxToken, yieldToken`). Clean decode of `totalSeats`/`yieldToken`.
- **`assetHash` hijack as an "anyone" attack** — downgraded/folded into S6: `registerAsset` requires `approvedAdapters[msg.sender]`, an `onlyOwner`-granted UGM role. Privileged griefing, not open.
- **Guardian can seize undistributed WBNB via `emergencyWithdraw*`** — by design (documented custodial trust model); no finding.
- **Value-in vs mark-to-market share pricing** — intended oracle-free fairness anchor; economic caveat, not a defect.
- **CEI comment vs WBNB wrap ordering (`:445` before `:454`)** — cosmetic; `distribute` is `nonReentrant` and WBNB is hookless/immutable, so non-exploitable. Fix the comment only.
- **Tiny redeem rounds a slice to 0 / `shares*balanceOf` overflow** — self-inflicted dust (standard ERC4626 round-down) / needs an absurd (~1e50+) reported balance which already implies a hostile stock (covered by S3). Use `Math.mulDiv` if desired; not exploitable against others.
- **Read-only reentrancy on `previewRedeem`/`reserves` mid-redeem** — stocks are trusted/fixed and views aren't used internally; info only.

---

## (4) Single most important fix

**S1 — the commission accounting in `distribute`.** It is the only finding that needs **no** malicious actor and **no** exotic token: a single dead pool plus one ordinary follow-up `distribute` already double-charges the retained WBNB, compounding every round and permanently diverting seat-holder yield to treasury while the contract's own NatSpec promises "≥90% of every receipt into the grids." Move the skim after the swap phase and size it to `spentWBNB` (and skim nothing when `spentWBNB==0`).