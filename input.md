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

Both were produced with `cast abi-encode` and decoded back to confirm they round-trip. Paste as one
continuous string with no line breaks — the newlines below are only so you can read the 32-byte words.

### BSC Testnet (chainId 97) — the mock stocks deployed 2026-08-05

SPCXB-T `0xf202974dE703985bC9cAF8D48311C7B90E584363` · NVDAB-T `0x7cA3F1BA1BD356aaf6399D75A65a94CBd0A18b59`
AAPLB-T `0x750564B2d1107373C325901B4B9351e41ECc467A` · GMEon-T `0xEAAAd5e54C766CA21Efee64FCa27597EF0db2963`
fees `[2500, 2500, 2500, 2500]` · weights `[2500, 2500, 2500, 2500]`

```
0x0000000000000000000000000000000000000000000000000000000000000060
0000000000000000000000000000000000000000000000000000000000000100
00000000000000000000000000000000000000000000000000000000000001a0
0000000000000000000000000000000000000000000000000000000000000004
000000000000000000000000f202974de703985bc9caf8d48311c7b90e584363
0000000000000000000000007ca3f1ba1bd356aaf6399d75a65a94cbd0a18b59
000000000000000000000000750564b2d1107373c325901b4b9351e41ecc467a
000000000000000000000000eaaad5e54c766ca21efee64fca27597ef0db2963
0000000000000000000000000000000000000000000000000000000000000004
00000000000000000000000000000000000000000000000000000000000009c4
00000000000000000000000000000000000000000000000000000000000009c4
00000000000000000000000000000000000000000000000000000000000009c4
00000000000000000000000000000000000000000000000000000000000009c4
0000000000000000000000000000000000000000000000000000000000000004
00000000000000000000000000000000000000000000000000000000000009c4
00000000000000000000000000000000000000000000000000000000000009c4
00000000000000000000000000000000000000000000000000000000000009c4
00000000000000000000000000000000000000000000000000000000000009c4
```

### BSC Mainnet (chainId 56) — the real four stocks

SPCXB `0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1` · NVDAB `0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436`
AAPLB `0x431a3BEE82E2ca41e49895CbECE5bB0F76A89b7A` · GMEon `0xdABb9afF4cf02f26D2014e4cA9f94aC6fe6572a3`
fees `[2500, 2500, 2500, 2500]` · weights `[2500, 2500, 2500, 2500]`

All four USDT pools were verified live at the **2500** tier — the only tier with a deployed pool for all
four. If you change a leg, re-verify its pool exists at the fee tier you supply, because a missing pool is
not caught until the swap silently skips.

```
0x0000000000000000000000000000000000000000000000000000000000000060
0000000000000000000000000000000000000000000000000000000000000100
00000000000000000000000000000000000000000000000000000000000001a0
0000000000000000000000000000000000000000000000000000000000000004
000000000000000000000000be9d156892e55e7154bcd3cb0fea677f9d3103e1
00000000000000000000000002fca66c1d1afb4e2a7884261eb00f63598a7436
000000000000000000000000431a3bee82e2ca41e49895cbece5bb0f76a89b7a
000000000000000000000000dabb9aff4cf02f26d2014e4ca9f94ac6fe6572a3
0000000000000000000000000000000000000000000000000000000000000004
00000000000000000000000000000000000000000000000000000000000009c4
00000000000000000000000000000000000000000000000000000000000009c4
00000000000000000000000000000000000000000000000000000000000009c4
00000000000000000000000000000000000000000000000000000000000009c4
0000000000000000000000000000000000000000000000000000000000000004
00000000000000000000000000000000000000000000000000000000000009c4
00000000000000000000000000000000000000000000000000000000000009c4
00000000000000000000000000000000000000000000000000000000000009c4
00000000000000000000000000000000000000000000000000000000000009c4
```

---

## 7. Rolling your own

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
