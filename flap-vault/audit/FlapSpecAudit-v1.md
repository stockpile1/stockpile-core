I have verified every load-bearing claim against source. Here is the synthesized report.

---

# Flap Vault Audit Report — StockpileBasketVaultV2 + StockpileBasketVaultFactory

Auditor: Lead (synthesis of 4 lens reviews, independently re-verified against source)
Targets: `contracts/vault/src/StockpileBasketVaultV2.sol`, `StockpileBasketVaultFactory.sol`, `StockBasketDeployer.sol`, `StockBasket.sol`
Trust model applied: Guardian is the chain-fixed Flap protocol address (not the token dev); keepers are Guardian-allowlisted and trusted to supply `minOut`; each per-token vault exclusively owns its own basket + grid.

## 1. Executive summary — **NON-COMPLIANT** (single, fund-safe blocker)

The suite is architecturally sound and fund-safe. All access-control, upgrade-authority, commission, reentrancy, receive-gas, and fairness rules pass under the stated trust model. There are **no High or Critical security findings**: the vault owns and solely mints its basket, `distribute` is `nonReentrant` + strict-CEI with reset approvals and value-anchored share minting, `setupMarket` is a one-shot with no front-run leverage, and upgrades are Guardian-only.

The suite is graded **NON-COMPLIANT on exactly one item**: **Rule 002's schema-fidelity criterion fails** — `vaultDataSchema()` does not match the `VaultDataV1` tuple that `newVault` decodes, so a generic Flap schema-driven launch reverts (Finding M1). This is a UI/encoding defect with **no fund risk**, fixable in one contract edit. Everything else is PASS with only Low/Info hardening items. Fix M1 and the suite is compliant.

## 2. Scope

In scope: the four target contracts above (per-token vault-backed launch flow). Base/prelude `src/flap/*` (VaultBase/VaultBaseV2/VaultFactoryBaseV2/IVault*) is immutable Flap-canonical code, treated as trusted and out of authorship scope. The downstream UnifiedGridManager and PancakeSwap V3 router are external and assumed to behave per interface. Rules assessed: 001–009.

## 3. Rule-by-rule compliance

| Rule | Verdict | Evidence |
|---|---|---|
| 001 Vault rules / permissions / no-DOS | **PASS** | `is VaultBaseV2` (Vault:115); `description()` override (:673); commission = Flap formula, capped ≤10%, Guardian-only-lowerable (`_commission` :488-493, `setCommissionBps` :628-631); every privileged fn Guardian-reachable via `onlyGuardian`/`onlyKeeper` (:230-242); Guardian chain-fixed, non-revocable; no dev knob. |
| 002 Factory rules | **FAIL** | Inherits `VaultFactoryBaseV2` (:46); `newVault` portal-gated (:118); Guardian-only beacon upgrades (:176-184) — all PASS. But `vaultDataSchema()` (:221-296) does **not** match `abi.decode(vaultData,(VaultDataV1))` (:18-28, :123) → Finding M1. |
| 003 Fairness / sandwich | **PASS** | Token dev has zero post-launch privilege; commission monotonically non-increasing; `distribute` mints shares to `address(this)`, never the keeper (:582); the sandwich-prone swap is keeper+Guardian-gated exactly as VaultBase mandates. |
| 004 UI-friendly errors | **PASS** | No custom errors / no `revert CustomError()` in the 4 target files; every revert is a literal bilingual `require`/`revert` string (e.g. Vault:231,239,296; Basket:75,118). |
| 005 receive() ≤ 1M gas | **PASS** | `receive() external payable {}` — empty no-op (Vault:389); no loop/external-call/delegatecall/SSTORE; all heavy work in `distribute`/`setupMarket`. |
| 006 Integration tests | **PASS** | 82 tests green; every High-severity coverage row present (receive-gas ≤1M, distribute happy+revert, setupMarket one-shot, all schema views, portal-gating, Guardian access, emergency withdraws). Low gaps → I3. |
| 007 AI-oracle integration | **N/A** | No `IFlapAIProvider`/`FlapAIConsumerBase` integration; interface is an unused prelude. |
| 008 Trigger-service integration | **N/A** | No `ITriggerReceiver`/`trigger()` callback; `distribute` is a gated EOA call, not a service callback. |
| 009 Emergency / upgrade authority | **PASS** | BeaconProxy vault → emergency-fn exemption applies; upgrade authority strictly Guardian-only with no bypass (`upgradeVaultImplementation`/`lockVaultUpgrades` Factory:176-184; beacon owned by factory, no `transferOwnership` wrapper); shipped `emergencyWithdraw*` are `onlyGuardian`+`nonReentrant` and rule-shaped (Vault:650-668). |

## 4. Findings

| ID | Sev | Rule | Title |
|---|---|---|---|
| M1 | **Medium** | 002 | `vaultDataSchema()` cannot express the `VaultDataV1` payload → generic schema-driven launch reverts |
| L1 | Low | 001 | Commission re-charged each round on retained (unswapped) WBNB → breaks the "≤10% per receipt" guarantee |
| L2 | Low | 001 | `distribute`'s `uint256[] minOut` described as scalar `uint256` in `vaultUISchema` → malformed generic-UI call |
| L3 | Low | — | `gridInitialPrice` unbounded/unvalidated with no setter → launcher can permanently brick `setupMarket` |
| L4 | Low | — | `StockBasket.deposit` not best-effort per stock (asymmetric with `redeem`) → one paused/blacklisting stock reverts all of `distribute` |
| L5 | Low | — | No `MAX_STOCKS` bound → launcher can pick a leg count that gas-bricks `setupMarket`/`distribute` |
| I1 | Info | — | Stranded basket shares on a failed grid feed are never swept by later rounds (NatSpec inaccurate) |
| I2 | Info | — | No storage `__gap` in the upgradeable implementation |
| I3 | Info | 006 | `initialize`/`_initStocks` validation reverts + minor guards untested in the V2 suite |
| I4 | Info | 004 | `StockBasket.renounceOwnership` uses `revert(string)` rather than `require(false, …)` |

---

### M1 (Medium, Rule 002) — schema/decode mismatch breaks the generic launch path
`newVault` runs `abi.decode(vaultData, (VaultDataV1))` (Factory:123), and `VaultDataV1` (Factory:18-28) contains **three dynamic arrays** — `address[] stocks`, `uint24[] stockFees`, `uint16[] swapWeights`. But `vaultDataSchema()` (Factory:221-296) declares `schema.isArray = false` (:295) with **nine scalar fields**, describing `stocks/stockFees/swapWeights` as scalar `address`/`uint24`/`uint16` (fields[1..3], :239-259). It also uses out-of-vocabulary field types `uint32` (field 0) and `uint24` (field 2), and types `gridInitialPrice` as `uint256` (:269) while the struct is `uint128` (:24).

**Failure scenario:** A generic Flap UI reads the schema, builds the all-static tuple `(uint32,address,uint24,uint16,uint16,uint256,uint16,address,uint256)`, renders a single address input for `stocks`, and `abi.encode`s a flat 9-word blob. `newVault` then `abi.decode`s it as `VaultDataV1`, reading word #1 (the user's stock address, a ~160-bit value) as the byte-offset of the `stocks[]` array → out-of-bounds → `abi.decode` reverts → **the launch transaction reverts.** The schema fundamentally cannot express a mixed `(scalar, address[], uint24[], uint16[], …scalars)` payload: `VaultDataSchema` supports only a flat scalar tuple (`isArray=false`) or a single tuple-array (`isArray=true`), never both.

**Not fund-risk:** the contract is correct given a properly hand-encoded `VaultDataV1` (as the repo's deploy scripts / bespoke UI produce), and `initialize` fully re-validates the legs (Vault:324-343). Only the generic schema-driven path is broken. This is why the suite is NON-COMPLIANT but not unsafe.

**Fix (pick one):** (a) carry the per-stock config as one opaque `bytes` field (in-vocab) that `newVault` decodes internally; or (b) move the basket config out of `newVault` into the already-permissionless `setupMarket()` so `vaultData` collapses to a flat scalar tuple the schema can express; or (c) restructure to `isArray=true` over a per-stock tuple with the grid scalars carried separately. Independently, replace `uint32`→`uint256` (field 0), `uint24`→`uint256`/`bytes` (field 2), and align field 5 to `uint128`.

### L1 (Low, Rule 001) — commission is re-charged on retained WBNB across rounds
`gross = IERC20(wbnb).balanceOf(address(this))` (Vault:455) is the vault's **entire** WBNB balance, and commission is skimmed to `treasury` every round before swapping (:459,:465). When a swap leg is skipped (dead pool / unreachable `minOut`), its WBNB is retained (`_swapAll` only advances `spentWBNB` for successful legs, :535-540) and re-counted as `gross` next round.

**Failure scenario (honest operation):** Round 1 receives 100 BNB → commission 6 → net 94; leg B's pool is temporarily dead so its 30 WBNB is retained. Round 2: `gross` = 30 (retained, already commissioned in round 1) + new receipts; the same 30 is commissioned **again** at up to `commissionBps`. A chronically dead leg is skimmed ~6%/round indefinitely, so cumulative commission on that stuck receipt can **exceed the documented "commission can never exceed 10% of a receipt" guarantee** (Vault:120-122). Bounded per round (≤`commissionBps`≤10%) and the leak flows to the Guardian-set treasury, so it caps at Low — but it is a genuine correctness deviation, not merely a malicious-keeper grief.

**Fix:** charge commission only on the delta newly wrapped each round (e.g. commission on `nativeBal` wrapped this round, or track a `pendingUncommissioned` credited on fresh wraps and subtract already-commissioned retained WBNB from the base).

### L2 (Low, Rule 001) — `minOut` array described as a scalar in `vaultUISchema`
`distribute(uint256[] calldata minOut, uint256 deadline)` (Vault:437) is schema-described with `inputs[0]=("minOut","uint256",…)` (:752) and no array flag. **Failure scenario:** a keeper on the generic schema-driven UI gets one `uint256` input; the UI encodes selector `distribute(uint256,uint256)`, which does not match `distribute(uint256[],uint256)` → the call reverts. Mitigated by the keeper using bespoke tooling; keeper/Guardian-gated; no fund risk. **Fix:** add a scalar-expressible `distributeUniform(uint256 minOutPerLeg, uint256 deadline)` wrapper for the schema path, or document that `distribute` is invoked only via the bespoke component.

### L3 (Low) — `gridInitialPrice` unbounded, unvalidated, no setter → permanent brick
`initialize` bounds `gridSize` and `gridTaxRateBps` but **not** `gridInitialPrice` (Vault:299-306, stored raw at :313); `setupMarket` passes it straight into `createGrid` (:374). **Failure scenario:** a launcher supplies `gridInitialPrice = 0` (or below a UGM minimum); `setupMarket` reverts on every call, the value is fixed at init with no setter, so the vault can **never** deploy its basket/grid and `distribute` is bricked forever (`require(basket != address(0))`). Tax still accrues, recoverable only via Guardian `emergencyWithdrawNative`. Launcher-self-inflicted, funds-safe → Low. **Fix:** enforce `> 0` (ideally UGM-min-aware) at init, or add a Guardian-only pre-`setupMarket` setter.

### L4 (Low, liveness) — `deposit` is not best-effort per stock (asymmetric with `redeem`)
`redeem` isolates each payout in try/catch (Basket:203-214), but `_depositToBasket` calls `basket.deposit(...)` directly (Vault:582) and `deposit`'s non-zero-amount `safeTransferFrom` (Basket:153-154) reverts uncaught. **Failure scenario:** a bought stock that pauses or blacklists the vault→basket transfer makes `deposit` revert → the whole `distribute` reverts. All swaps in that tx roll back (no fund loss), tax accrues (Guardian-recoverable), but distribution stalls until the stock recovers. Launcher's stock choice drives the risk → Low. **Fix:** wrap `deposit`'s pull best-effort per leg (skip a reverting stock), mirroring `redeem`.

### L5 (Low) — no upper bound on stock legs
`_initStocks` (Vault:324-343) and the basket constructor (Basket:88-98) do O(n²) dedup with no max `n`; `distribute` loops all legs doing swaps. **Failure scenario:** a launcher configuring a very large `stocks` array pushes `setupMarket`/`distribute` over the block gas limit, bricking its own vault (funds Guardian-recoverable, no third-party harm). **Fix:** add a sane `MAX_STOCKS` bound in `initialize`.

### I1 (Info) — stranded basket shares on a failed grid feed are not swept later
`_feedGrid` best-effort-forwards only the current round's `basketMinted` (Vault:593-601). If `receiveYieldERC20` reverts (grid unregistered/paused), those shares stay on the vault; subsequent rounds forward only their own mint and never sweep the backlog — contradicting the NatSpec's "or the next round" (:591). Recoverable via Guardian `emergencyWithdrawToken`. **Fix:** feed `IERC20(basket).balanceOf(address(this))` (whole balance) rather than just `basketMinted`.

### I2 (Info) — no storage `__gap`
`StockpileBasketVaultV2` declares its own storage without a trailing `__gap`. Not a current bug (single impl), but future beacon upgrades must strictly append and cannot insert base-layer storage. Consider a `uint256[N] __gap`.

### I3 (Info, Rule 006) — untested validation branches in the V2 suite
No V2 test exercises the `initialize`/`_initStocks` reverts (weights≠10000, duplicate stock, stock==wbnb/usdt, `gridSize`/`gridTaxRateBps`/`commissionBps`/`minInterval` bounds, zero treasury, empty stocks — Vault:296-343), nor `registerWithGrid` "not set up" (:613), `swapLeg` "Only self" (:551), or non-Guardian `setCommissionBps`/`setMinInterval`. A regression loosening any bound would ship undetected by the V2 suite. **Fix:** add revert tests via `factory.newVault(...)` with malformed `vaultData`, one per branch.

### I4 (Info, Rule 004) — `revert(string)` vs `require`
`StockBasket.renounceOwnership` uses `revert(unicode"Renounce disabled / 禁止放弃所有权")` (Basket:117-119). This is a literal bilingual `Error(string)` (UI-decodable) and satisfies UI-01 in substance; only the literal `require()` form differs. Rewrite as `require(false, unicode"…")` if a linter enforces the letter.

## 5. Single most important fix

**Fix M1** — make `vaultDataSchema()` round-trip with `abi.decode(vaultData,(VaultDataV1))`. The cleanest form is to encode the three parallel per-stock arrays as one opaque `bytes` field (in-vocab) decoded inside `newVault`, or to move the basket config into the permissionless `setupMarket()` so `vaultData` reduces to a flat scalar tuple. This is the only issue standing between the suite and COMPLIANT, and it unblocks the standard Flap schema-driven launch. No fund-safety change is required.

## 6. Cleared / not-a-bug

- **`minOut` has no on-chain slippage floor** (raised as "Medium" by the fairness lens, "Info" by the security lens — **same issue, de-duplicated and refuted as a scored finding**). `distribute` forwards keeper-supplied `minOut[i]` straight to `amountOutMinimum` (Vault:557-563). Under the stated trust model the keeper is trusted for `minOut`, and this is exactly Flap's sanctioned pattern (VaultBase mandates gating sandwich-prone swaps to keeper+Guardian rather than making them public). There is no user-submitted swap for an insider to sandwich; the only "flow" is the vault's own periodic conversion, which end-users cannot trigger. It reduces to the accepted Guardian trust root. **Not scored.** Optional hardening: bound `minOut` with a PancakeSwap V3 TWAP or a Guardian-set `maxSlippageBps`.
- **Guardian can seize funds / rewrite logic** (`emergencyWithdraw*`, beacon `upgradeVaultImplementation`). This IS the Rule 009 proxy trust model — the Guardian is the chain-fixed Flap protocol address, not the token dev. Accepted by design.
- **`setupMarket` front-running / idempotency.** One-shot (`require(basket == address(0))`, :354) + `nonReentrant`; every parameter is vault storage fixed at init; the deployed basket always binds `address(this)` as owner+minter and `createGrid`'s caller is always the vault; `assetHash` is unique per vault/gridId (:378). A front-runner gains no leverage. Cleared.
- **`StockBasketDeployer` is permissionless.** `deployBasket` binds the vault as sole minter and transfers ownership to it (Deployer:31-34); a stray call only mints an orphan basket the real vault never references. Cleared.
- **`initialize` / upgrade / immutables.** Impl `_disableInitializers()` (:268); `initializer` one-shot (:293); factory deploys+initializes atomically in the `BeaconProxy` constructor (Factory:139-156) → no init front-run window; routing addresses are `immutable` (live in impl bytecode, correct under delegatecall). Cleared.
- **`distribute` reentrancy / CEI.** `nonReentrant` + `onlyKeeper`; `lastDistribute` advanced before any external call (:463); approvals reset to 0 (:543,585,601); FoT-robust `out > 0` guard blocks unbacked shares (:566-568); D18 codeless-token guard present only in `distribute`, never init (:500). Cleared.
- **Rules 007 / 008.** No AI-oracle or trigger-service integration; interfaces are unused preludes. N/A.
---

## v2 — POST-FIX VERDICT: COMPLIANT ✅

All findings resolved (commit F3): M1 vaultDataSchema now round-trips the flat `VaultDataV1` tuple (7
in-vocab fields incl. one opaque `bytes stocksData`), proven by `testSchemaRoundTrip`. L1 commission
skimmed after swap ∝ spentWBNB (retained WBNB never re-taxed). L2 `distributeUniform(uint256,uint256)`
is the schema write method (scalar minOut). L3 `gridInitialPrice>0`. L4 best-effort per-stock deposit.
L5 `MAX_STOCKS=20`. I1 grid feed sweeps whole basket balance. I2 `__gap`. I3 validation revert tests.
I4 renounce via `require(false,…)`. Full non-fork suite 219/219; V2 24,312 B (<24576).
