# Launch input — filling the Flap "Custom Vault" form

What to type into each field of the auto-generated launch form (it is rendered from the factory's
`vaultDataSchema()`). The last field, `stocksData`, is a raw `bytes` blob the form cannot build for you —
**pre-computed values are at the bottom, ready to paste.**

> The form warns *"This factory has not been verified"*. That is only BscScan source verification, not a
> Flap judgement. See §5.

---

## 1. The six scalar fields

| Field | Type | Allowed | Suggested | What it actually does |
|---|---|---|---|---|
| `gridSize` | uint16 | **4 … 1024** | `100` | Number of seats in this vault's grid. A **flat count**, not a dimension — seats are numbered `0…n-1` and there is no square constraint. `50` or `77` are valid; 36/100/144/256 merely tile neatly in a UI. |
| `gridTaxRateBps` | uint16 | **10 … 1000** | `100` | Weekly Harberger tax, bps. `100` = 1%/week. |
| `gridInitialPrice` | uint128 | **> 0** | `1000000000000000` | Starting self-assessed price **per seat**, in WBNB wei (18 dp). `1e15` = 0.001 WBNB per seat, so a 100-seat grid starts at 0.1 WBNB total. |
| `commissionBps` | uint16 | **≤ 1000** | `600` | Commission cap skimmed to the treasury per distribute. `600` = 6%, matching Flap's recommended fee. The Guardian can only ever LOWER it afterwards. |
| `treasury` | address | non-zero | your address | Receives the commission (in WBNB). |
| `minInterval` | uint256 | **≤ 2592000** | `3600` | Minimum seconds between two successful distributes. `0` means no gate. |

**A note on `gridInitialPrice`.** It is per seat and denominated in WBNB, not in the launched token. Setting
`1e18` with `gridSize` 100 prices the whole grid at 100 WBNB, which is almost certainly not what you want on
a first launch.

---

## 2. `stocksData` — the field the form cannot build

It is `abi.encode(address[] stocks, uint24[] stockFees, uint16[] swapWeights)`: three **equal-length,
positionally-aligned** arrays, one entry per basket leg.

Rules the contract enforces (in `setupMarket()`, **not** at launch — see §4):

- every `stocks[i]` non-zero, all **distinct**, and **not** WBNB or USDT
- `stockFees[i]` is the `USDT → stock` V3 pool fee tier (the second hop)
- `swapWeights` **must sum to exactly 10000**
- at most **20** legs — but see the 4-leg caveat in §3

---

## 3. Pick 4 legs, not more

`MAX_STOCKS` is 20, but `MAX_TRIGGER_STOCKS` is **4**. Beyond four legs `scheduleDistribute()` reverts
`"Too many legs / 腿数过多"`, because the callback no longer fits the Flap Trigger Service's hard
2,000,000-gas budget (measured: ~1.86M for four legs against live pools, ~450k per leg).

A basket with more than four legs still works — but only through the Guardian/keeper path, which means you
lose the permissionless self-scheduling that is the point of the design. **Use 4.**

---

## 4. Where a mistake surfaces

The six scalar fields are validated **at launch** by `initialize()`, so a bad value reverts the whole launch
transaction — loud and immediate.

`stocksData` is **not**. The vault stores it as an opaque blob and only decodes it later, in the
permissionless `setupMarket()`. So a malformed blob still lets the launch succeed, and only `setupMarket()`
reverts — leaving a live token whose vault has no basket and no grid. Double-check the blob before you
launch, or run `setupMarket()` immediately after and confirm it succeeded.

---

## 5. Prerequisites that are not your inputs

Two things must be done by the **UGM owner**, not the launcher:

- `allowedTaxTokens[WBNB] = true` — otherwise `setupMarket()` reverts `"taxToken"`
- `setApprovedAdapter(vault, true)` — otherwise `registerWithGrid()` reverts `"adapter"`, and grid yield
  never reaches seat holders

On testnet the deploy script does both because the deployer *is* the UGM owner. **On mainnet it is not**;
coordinate with whoever holds the UGM for every new vault.

The "factory has not been verified" banner is about BscScan source verification only. Fix it with
`forge verify-contract` (needs a `BSCSCAN_API_KEY`); it does not affect behaviour.

---

## 6. Ready-to-paste `stocksData`

### Generate it (preferred — never goes stale)

```bash
forge script script/PrintLaunchInput.s.sol                    # mainnet basket, from StockConfig
forge script script/PrintLaunchInput.s.sol --sig 'testnet()'  # testnet mocks
```

Read-only, no `PRIVATE_KEY` needed. It prints the six scalar fields **and** `stocksData` as one continuous
line, and refuses to print a blob that would fail `setupMarket()` — duplicate legs, a zero address, weights
that do not sum to 10000, or a scalar out of range all abort with a clear message. Override anything:

```bash
STOCK0=0x… STOCK1=0x… STOCK2=0x… STOCK3=0x… \
GRID_SIZE=144 COMMISSION_BPS=300 TREASURY=0x… MIN_INTERVAL=0 \
  forge script script/PrintLaunchInput.s.sol --sig 'testnet()'
```

Because it reads the basket from `StockConfig`, it can never disagree with the deploy scripts about which
four tokens the basket holds.

### Or copy from here

Single line each — select the whole thing including `0x`.

**BSC Testnet (chainId 97)** — mocks from the 2026-08-05 redeploy
SPCXB-T `0xF46fa891…6e57` · NVDAB-T `0x338cB579…88AC` · AAPLB-T `0xFC72F4bF…FaE4` · GMEon-T `0x6787167b…188d`

```
0x0000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000001a00000000000000000000000000000000000000000000000000000000000000004000000000000000000000000f46fa89166ee71d9d9704266deee18c958da6e57000000000000000000000000338cb5799b098f14b5375503a2cf7149d59188ac000000000000000000000000fc72f4bfa7ed7735e893704608ebb477034bfae40000000000000000000000006787167b8722f6e86a25af0bc1c7bc77b362188d000000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000009c400000000000000000000000000000000000000000000000000000000000009c400000000000000000000000000000000000000000000000000000000000009c400000000000000000000000000000000000000000000000000000000000009c4000000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000009c400000000000000000000000000000000000000000000000000000000000009c400000000000000000000000000000000000000000000000000000000000009c400000000000000000000000000000000000000000000000000000000000009c4
```

**BSC Mainnet (chainId 56)** — the real four
SPCXB `0xbe9D1568…03E1` · NVDAB `0x02Fca66C…7436` · AAPLB `0x431a3BEE…9b7A` · GMEon `0xdABb9afF…72a3`

All four USDT pools verified live at the **2500** tier — the only tier with a deployed pool for all four.
Change a leg and you must re-verify its pool exists at the fee tier you supply: a missing pool is not
caught at launch, the swap just silently skips.

```
0x0000000000000000000000000000000000000000000000000000000000000060000000000000000000000000000000000000000000000000000000000000010000000000000000000000000000000000000000000000000000000000000001a00000000000000000000000000000000000000000000000000000000000000004000000000000000000000000be9d156892e55e7154bcd3cb0fea677f9d3103e100000000000000000000000002fca66c1d1afb4e2a7884261eb00f63598a7436000000000000000000000000431a3bee82e2ca41e49895cbece5bb0f76a89b7a000000000000000000000000dabb9aff4cf02f26d2014e4ca9f94ac6fe6572a3000000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000009c400000000000000000000000000000000000000000000000000000000000009c400000000000000000000000000000000000000000000000000000000000009c400000000000000000000000000000000000000000000000000000000000009c4000000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000009c400000000000000000000000000000000000000000000000000000000000009c400000000000000000000000000000000000000000000000000000000000009c400000000000000000000000000000000000000000000000000000000000009c4
```

## 7. Rolling your own (by hand)

```bash
cast abi-encode "f(address[],uint24[],uint16[])" \
  "[0xSTOCK0,0xSTOCK1,0xSTOCK2,0xSTOCK3]" \
  "[2500,2500,2500,2500]" \
  "[2500,2500,2500,2500]"
```

```ts
import { encodeAbiParameters } from 'viem';
const stocksData = encodeAbiParameters(
  [{ type: 'address[]' }, { type: 'uint24[]' }, { type: 'uint16[]' }],
  [stocks, stockFees, swapWeights],   // weights must sum to 10000
);
```

Verify before pasting:

```bash
cast abi-decode --input "f(address[],uint24[],uint16[])" 0x<blob>
```

> **Encoding asymmetry.** Only relevant if you launch programmatically rather than through the form: the
> **outer** `vaultData` is `abi.decode(vaultData, (VaultDataV1))` → encode it as a **single tuple**, while
> the **inner** `stocksData` is `abi.decode(blob, (address[],uint24[],uint16[]))` → encode it as **three
> flat params**. Mixing the two up is the most common launch-integration bug.
