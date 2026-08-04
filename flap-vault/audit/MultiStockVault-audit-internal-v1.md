# Hostile audit — `contracts/vault/src/MultiStockVault.sol`

Target: the WBNB fee-sink vault that skims a commission, splits `net` 7 ways, swaps each slice
WBNB→USDT→stock on PancakeSwap V3, and forwards each stock into its own Stockpile grid via
`UGM.receiveYieldERC20`. Reasoned against the **real** `UnifiedGridManager` (OZ v5, solc 0.8.26),
not the mock. Contract is OZ v4.9.6 `Ownable` + `ReentrancyGuard`, solc `^0.8.13`, non-upgradeable.

## Severity-sorted findings

| # | Sev | Title | Location | Real/Plausible |
|---|-----|-------|----------|----------------|
| F1 | High | Permissionless `distribute` + caller-supplied `minOut` (0 by default) ⇒ MEV sandwich drains value | `distribute` L325-369, `_swapLegAndForward` L385-393 | CONFIRMED (exploitable) |
| F2 | Medium | All-or-nothing batch: any one leg reverting (no liquidity / rug / paused grid) bricks ALL distribution | loop L351-363, `_swapLegAndForward` L385 | CONFIRMED |
| F3 | Medium | Grid `yieldToken != leg.stock` permanently bricks the whole batch — deploy footgun, UNTESTED | `_swapLegAndForward` L398 vs UGM L621 | CONFIRMED |
| F4 | Medium | Duplicate `gridId` across legs ⇒ identical `assetHash` ⇒ `registerAllGrids` reverts / mis-credit; no constructor dedup | ctor L234-252, `registerAllGrids` L425-430 | CONFIRMED |
| F5 | Medium | Fee-on-transfer / rebasing / 100%-fee stock bricks a leg or strands value | `_swapLegAndForward` L395-399 vs UGM L624-627 | CONFIRMED (for such tokens) |
| F6 | Low | `renounceOwnership()` inherited & un-overridden ⇒ can permanently disable emergency withdraw & all guardian knobs | Ownable (inherited) | CONFIRMED |
| F7 | Low | Rogue approved-adapter can front-run `registerAsset` for this vault's `assetHash` and brick a leg | `registerWithGrid` L416-420 vs UGM L593-600 | PLAUSIBLE (needs adapter role) |
| F8 | Low | Guardian can sweep all accrued WBNB / bought stock before distribution (centralization) | `emergencyWithdrawToken` L463-470 | CONFIRMED (by design) |
| F9 | Info | "zero-yield swap is skipped" resilience is largely illusory on the real router (it reverts, not returns 0) | `_swapLegAndForward` L395 | CONFIRMED |
| F10 | Info | No `stock != wbnb/usdt` and no duplicate-stock checks; malformed path config possible | ctor L234-252 | CONFIRMED |
| F11 | Info | `receive()` needs >2300 gas (WBNB.deposit); `.transfer`-style sends revert; forced native BNB bypasses wrap | `receive` L264-268 | CONFIRMED |
| F12 | Info | Third-party stock ERC777-style hook can re-enter the un-guarded `register*` views (no fund impact) | `_swapLegAndForward` L398 | PLAUSIBLE |
| F13 | Info | Redundant `newBps <= MAX` check; first-call time-gate fires immediately (`lastDistribute==0`) | `setCommissionBps` L439, `distribute` L330 | CONFIRMED (benign) |

Accounting core is **sound**: CEI ordering (lastDistribute advanced pre-external, L340), commission/`net`
math cannot under/overflow, the 7-way split provably sums to `net` with dust on the last leg,
`nonReentrant` on all value paths, and both approvals reset to 0. Those are NOT bugs — details below.

---

## F1 — HIGH: permissionless `distribute` with attacker-controlled `minOut` ⇒ MEV value extraction

**Location:** `distribute` is `external` with no caller gate (L325-329); it forwards `minOut[i]` straight
into the router as `amountOutMinimum` (`_swapLegAndForward` L391). The vault has **no on-chain price
reference** (no TWAP/oracle/quoter).

**Why it's real, not just "keeper supplies minOut":** the design (D20/D21) assumes an honest keeper computes
`minOut` off-chain. But because `distribute` is fully permissionless, an attacker can **always be the
caller** and pass `minOut = [0,0,0,0,0,0,0]` — exactly what every unit test and both fork tests do
(`_zeros()`, `_zeroMinOut()`). With a 0 floor there is zero slippage protection.

**Failure scenario (concrete):**
1. Vault has accrued, say, 50 WBNB; `block.timestamp >= lastDistribute + minInterval` (gate open).
2. Attacker bundles: (a) push each WBNB→USDT→stock pool to a bad price, (b) call
   `distribute([0×7], deadline)`, (c) restore pools. The vault buys stock at the manipulated price;
   `out` is small but `>= 0` so no revert. Attacker back-runs and pockets the spread.
3. `net` (~45 WBNB after 10% commission) is largely converted to attacker profit + LP fees; seat holders
   receive a fraction of the intended stock. Repeatable **every `minInterval`**.

Bounded per interval, but the slippage parameter provides **no guarantee at all** since the attacker
chooses it. Direct theft of the stock itself is not possible (recipient is hard-coded `address(this)`,
L388) — the loss is purely via pool price manipulation.

**Fix:** gate `distribute` to a trusted keeper (role/allowlist), OR enforce an on-chain minimum via a
Pancake V3 TWAP/quoter so a 0/low `minOut` cannot pass, OR require `minOut[i] > 0` for every non-skipped
leg (weak, but blocks the trivial all-zeros call). At minimum, document that permissionless-caller +
zero-floor is an accepted MEV surface.

---

## F2 — MEDIUM: one bad leg bricks the entire batch (availability DoS)

**Location:** the 7 legs run atomically in a single loop (L351-363); each calls
`IV3SwapRouter.exactInput` (L385). There is **no per-leg `try/catch`**. Any revert in any leg reverts the
whole `distribute` (and rolls back `lastDistribute`).

**Failure scenario:** stock #3's USDT→stock pool is drained/never created, or its token is paused/rugged,
or the grid is paused/deprecated at the UGM, or `minOut[3]` is unreachable. `exactInput` (or the UGM push)
reverts → **all 7 legs revert** → yield stops flowing to the other 6 healthy grids indefinitely. The vault
keeps accruing WBNB that can never be distributed until the guardian calls `emergencyWithdrawToken`
(funds are recoverable, so not a permanent loss — but the product is fully DoS'd, and if the guardian has
renounced (F6) the WBNB is stuck forever).

Because **all 7 first hops share the same `wbnbUsdtFee`** (L383), a single wrong WBNB/USDT fee tier bricks
**every** leg from day one.

**Fix:** wrap each leg in `try/catch` so a failing leg is skipped (bought[i]=0) instead of reverting the
batch; emit a per-leg failure event. Note this changes the WBNB-conservation invariant (a skipped leg
leaves its `amountIn` unspent), which is acceptable and re-distributable next round.

---

## F3 — MEDIUM: `yieldToken != stock` mismatch bricks the batch (untested)

**Location:** the vault pushes `leg.stock` (L398). The **real** UGM requires `token == c.yieldToken`
(UnifiedGridManager L620-621, `require(token == c.yieldToken, "yieldToken")`). The vault can never verify
this at construction — grids are created separately and may not even exist yet; the vault only stores a
`gridId`.

**Failure scenario:** grid 5 was created with `yieldToken = QQQB` but the leg pointing at grid 5 is
configured with `stock = NVDAB`. `registerWithGrid` still succeeds (UGM `registerAsset` never checks the
token). The first `distribute` calls `receiveYieldERC20(hash, NVDAB, out)` → UGM reverts `"yieldToken"` →
by F2, the whole batch bricks. **Silent until the first distribute.**

**Critically UNTESTED:** the `MockUGM.receiveYieldERC20` (test/mocks/MockUGM.sol L141-157) does **not**
track or check `yieldToken` — so neither the unit suite nor the fork suite ever exercises the real UGM's
`"yieldToken"` gate. The fork test uses a MockUGM precisely because the real one needs pre-created grids.

**Fix:** if the UGM exposes `gridConfig(gridId).yieldToken`, assert `== stock` per leg in the constructor
(or in `registerWithGrid`). Otherwise document it as a hard deploy-time precondition and add a fork test
against the real UGM.

---

## F4 — MEDIUM: duplicate `gridId` ⇒ `assetHash` collision ⇒ registration/credit breakage

**Location:** `assetHash = keccak256(abi.encode("MultiStockVault", address(this), gridId))` (L240) depends
**only** on `(vault, gridId)` — not on the stock or leg index. The constructor validates `gridId != 0`
(L238) but does **not** reject duplicate `gridId`s (or duplicate `assetHash`es).

**Failure scenario:** legs 2 and 5 are both configured with `gridId = 3`. Their `assetHash` is identical.
- `registerAllGrids()` (L425-430) loops `registerAsset(3, hash)`; the second occurrence hits UGM
  `require(assetToGrid[hash] == 0, "registered")` → **`registerAllGrids` always reverts**, so the
  convenience path can never bind the basket.
- Falling back to per-leg `registerWithGrid`: the first occurrence binds `hash→grid3`; the second reverts
  `"registered"`. Now `distribute` for BOTH legs pushes to the single grid 3. If the two legs hold
  different stocks, one of them fails the F3 `yieldToken` check → batch brick (F2). If they hold the same
  stock, grid 3 is double-credited while the intended second grid is silently starved.

**Fix:** in the constructor, track seen `gridId`s (or `assetHash`es) and `require` uniqueness across the 7
legs. (Duplicate *stock* across distinct grids — F10 — is only a soft error; duplicate *gridId* is a hard
one.)

---

## F5 — MEDIUM: fee-on-transfer / rebasing / hooked stock bricks a leg or strands value

The 7 stocks are third-party ERC20s. The path assumes a plain, non-FoT token in two places:

1. After the swap the vault holds the router's reported `out`; it approves `out` and the UGM pulls `out`
   via `transferFrom` (L397-398). PancakeSwap V3 does not reliably deliver `amountOut` to the recipient for
   a fee-on-transfer output token — the vault's actual balance can be `out - fee < out`, so the UGM's
   `transferFrom(vault, ugm, out)` reverts **insufficient balance** → leg bricks → batch bricks (F2).
2. Even if the pull succeeds, the **real** UGM credits the balance *delta* it observes
   (`received = balanceOf(after) - balanceOf(before)`, UGM L624-626) and `require(received > 0, "received")`.
   A 100%-fee (or fully-rebasing-away) transfer yields `received == 0` → UGM reverts `"received"` → batch
   brick. The `MockUGM` credits the *requested* `amount` (L155), so this divergence is untested.

**Failure scenario:** any leg configured with a FoT/reflection stock (or a stock that later turns fees on)
permanently bricks `distribute`. Even the "benign" case leaks value: the vault sends `out`, the grid
credits `out - fee`.

**Fix:** restrict the basket to standard non-FoT tokens (document + validate off-chain), or measure the
vault's actual post-swap stock balance and push `min(balance, out)`; accept that FoT tokens are
unsupported.

---

## F6 — LOW: inherited `renounceOwnership()` can brick all guardian controls

**Location:** OZ v4.9.6 `Ownable.renounceOwnership()` is inherited and not overridden. Calling it sets
`owner = address(0)`, after which `setCommissionBps`, `setTreasury`, `setMinInterval`,
`emergencyWithdrawToken`, and `emergencyWithdrawNative` all revert `"Ownable: caller is not the owner"`
forever.

**Failure scenario:** guardian renounces (fat-finger or a mistaken "decentralize" step). Later a leg bricks
(F2/F3/F5). The accrued WBNB — the escape hatch that would recover it (`emergencyWithdrawToken`) — is now
uncallable. Funds are permanently stuck.

**Fix:** override `renounceOwnership()` to revert (the standard OZ hardening), or accept and document.

---

## F7 — LOW: rogue approved-adapter can pre-register this vault's `assetHash`

**Location:** `registerWithGrid`/`registerAllGrids` replay the stored `assetHash` into UGM `registerAsset`
(L419, L428). The UGM binds `assetToGrid[hash]` to the **first** approved adapter that registers it and
rejects any later registration (`"registered"`).

**Failure scenario:** a *different* guardian-approved adapter computes this vault's
`keccak256("MultiStockVault", vaultAddr, gridId)` (all inputs are public) and calls
`registerAsset(wrongGrid, hash)` first. The vault's own `registerWithGrid` then reverts `"registered"`, and
`receiveYieldERC20` checks `msg.sender == assetAdapter[hash]` (the attacker), so the vault can never push →
that leg is permanently dead (batch-brick via F2). Requires the attacker to already hold the guardian-
granted adapter role, so it's a limited/insider vector — but the `assetHash` is not bound to the caller, so
nothing stops a front-run within the approved set. Cross-*vault* collision is impossible (address is in the
hash).

**Fix:** low priority given the trust assumption; could have the guardian register on the vault's behalf is
NOT possible (UGM binds to `msg.sender`), so the realistic mitigation is operational (register immediately
at deploy, keep the approved-adapter set tight).

---

## F8 — LOW/INFO: guardian can drain accrued WBNB and bought stock (centralization, by design)

`emergencyWithdrawToken(token, to)` (L463-470) sweeps the **full** balance of any token — including WBNB
that has accrued but not yet been distributed, and any stock momentarily held. The guardian can therefore
capture users' pending yield at will. This is consistent with the stated TRUST MODEL (L75-81) but should be
called out: seat-holder yield is only as safe as the guardian between distributes. No fix; disclosure.

---

## F9 — INFO: the "zero-yield swap is skipped" safety net is mostly unreachable on mainnet

`_swapLegAndForward` skips the grid push only when the router *returns* `out == 0` without reverting
(L395). On the real PancakeSwap V3 router a 2-hop swap that would net 0 (dust `amountIn`, or an
intermediate hop producing 0 USDT) typically **reverts** inside the pool (`amountSpecified` = 0 / `AS`),
not returns 0. So the mock-tested `test_ZeroSwapOut_LegSkippedBatchContinues` path does not reflect real
behavior — in production such a leg reverts and takes the whole batch with it (reinforces F2). Not a bug in
itself; a false sense of resilience.

---

## F10 — INFO: missing config sanity checks (stock == wbnb/usdt, duplicate stock)

The constructor never checks that `stock != wbnb` and `stock != usdt`. A leg with `stock == usdt` produces
path `WBNB,fee,USDT,stockFee,USDT` (USDT twice) and `stock == wbnb` produces a WBNB→USDT→WBNB round-trip —
both either revert in the router (→ F2 brick) or silently burn value to fees. Duplicate *stock* across
distinct grids is allowed and is legitimate only if every such grid's `yieldToken` equals that stock
(else F3). Recommend rejecting `stock ∈ {wbnb, usdt}` and documenting the duplicate-stock expectation.

---

## F11 — INFO: `receive()` gas + forced-native edge cases

`receive()` calls `IWBNB.deposit{value: msg.value}()` (L266), which costs far more than the 2300-gas
stipend. Any sender using `transfer`/`send` (or a 2300-gas `call`) to move native BNB in will revert. This
only harms the *sender*, never the vault, and the normal fee path is a plain WBNB ERC20 transfer (no hook),
so it's benign. Native BNB force-injected via `selfdestruct`/coinbase bypasses the wrap and sits as raw
balance ignored by `distribute` — recoverable via `emergencyWithdrawNative`. Disclosure only.

---

## F12 — INFO: stock-hook reentrancy into the un-guarded `register*` functions

`distribute` and both emergency withdrawals are `nonReentrant`, but `registerWithGrid`/`registerAllGrids`
are not. A stock with an ERC777-style transfer hook (fired during the UGM `transferFrom` at L398) could
re-enter `registerWithGrid`, but that only re-calls `UGM.registerAsset` on an already-registered asset
(reverts `"registered"`) or reads views — **no fund impact**, and the outer `distribute` is still locked.
Noted for completeness; the reentrancy posture on the money path is solid.

---

## F13 — INFO: benign redundancies

- `setCommissionBps` checks `newBps <= commissionBps` **and** `newBps <= MAX_COMMISSION_BPS` (L438-439);
  since `commissionBps` starts `<= MAX` and only decreases, the second check can never bind. Harmless.
- First-ever `distribute` passes the gate immediately because `lastDistribute == 0` and
  `block.timestamp (~1.7e9) >= minInterval (<= 30d = 2.6e6)` (L330). No initial cooldown — acceptable and
  matches the tests, but worth knowing there is no "warm-up" delay.

---

## Things I checked that are NOT bugs (adversarial pass, cleared)

- **CEI / time-gate.** `lastDistribute = block.timestamp` (L340) is set before any external call. Gate
  `block.timestamp >= lastDistribute + minInterval` cannot overflow (`lastDistribute` is a timestamp,
  `minInterval <= 30 days`). A reverting leg rolls back the gate advance, so no "gate consumed on failure".
- **Commission / `net` math.** `commission = gross*commissionBps/10_000` with `commissionBps <= 1000`, so
  `commission <= gross/10` and `net = gross - commission > 0` for any `gross >= 1`. No underflow; rounding
  favors `net` (floored commission).
- **7-way split conservation.** For `i<6`, `amountIn = floor(net*w_i/10_000)`, accumulated into
  `allocated`; leg 6 = `net - allocated`. Since `Σ_{i<6} floor(net*w_i/10_000) <= net*(10_000-w_6)/10_000
  <= net`, `allocated <= net` always ⇒ `net - allocated` never underflows, and `Σ amountIn == net`
  exactly. Verified for edge weights (one leg 10_000; a middle leg 0; last leg 10_000). Matches the fuzz
  test.
- **Approvals.** Router approved to exactly `net` (L348) and the loop pulls exactly `net` (Σ amountIn);
  reset to 0 after (L366). Per-leg stock approval granted then reset to 0 (L397-399), and skipped entirely
  when `out == 0`. A mid-loop revert rolls back the approval too — no dangling allowance persists.
- **WBNB fully drained.** `commission + Σ amountIn == gross`, so the vault's WBNB → 0 each successful
  distribute (fuzz-proven). No dust leak. (A zero-*yield* leg still consumes its `amountIn`, so WBNB is not
  stranded — value can be lost to slippage only, which is F1.)
- **Reentrancy on the money path.** `nonReentrant` + trusted WBNB/router/UGM (UGM is itself
  `nonReentrant`). Treasury WBNB transfer has no hook. Solid.
- **Casts / overflow.** `weightBps`/`stockFee` are already `uint16`/`uint24` in `BasketParams`; no unsafe
  downcast. `gross*commissionBps`, `net*weightBps` stay far under `2^256`. solc ^0.8 checked math.

---

## Single most important recommendation

**Fix F1 first.** `distribute` is permissionless and hands the slippage floor (`minOut`) to the caller, who
can always be an attacker passing all-zeros — so the swap has effectively **no on-chain price protection**
and each interval's `net` can be sandwiched away. Either restrict `distribute` to a trusted keeper role or
enforce an on-chain minimum (Pancake V3 TWAP/quoter). It is the only finding that lets an external actor
extract real value on the happy path; F2-F5 are availability/mis-config bricks whose funds remain
recoverable via the emergency hatch (so long as F6/`renounceOwnership` hasn't disabled it).
