# flap-vault — Flap-conforming Stockpile basket vault

This is the **Flap-conforming basket vault** for Stockpile: a self-contained Foundry project that
routes a Flap-launched token's BNB tax stream into a per-token basket of "stock" tokens and, in turn,
into a Stockpile Harberger grid (UnifiedGridManager) so seat holders earn the yield.

## Why this is a self-contained subdirectory

It ships as its own subdir, with its **own `lib/`** (git submodules) and **own `remappings.txt`**,
because it is built against **OpenZeppelin v4.9.6** — deliberately different from the OZ **v5** used by
the `stockpile-core` root at the repository root. Mixing the two OZ major versions in one project breaks
compilation, so the vault is kept fully isolated: `cd flap-vault && forge build` compiles it against its
own v4.9.6 dependencies and never touches the root's v5 setup.

- Solidity `0.8.26`, `evm_version = cancun`, optimizer on at **1000 runs** (tuned so the per-token vault
  fits EIP-170 24 KB runtime and the factory fits EIP-3860 49 KB initcode — see `foundry.toml`).
- Dependencies are git submodules under `lib/` (not vendored): `forge-std`,
  `openzeppelin-contracts` @ **v4.9.6**, `openzeppelin-contracts-upgradeable` @ **v4.9.6**.

## Audit scope — the 4 Flap-conforming contracts

The audit target is the per-token vault-backed launch flow, four contracts plus the immutable Flap prelude:

| Contract | File | Role |
|---|---|---|
| `StockpileBasketVaultV2` | `src/StockpileBasketVaultV2.sol` | The `VaultBaseV2` per-token vault. Wraps BNB→WBNB, skims a capped commission, swaps into the basket legs, feeds the grid. |
| `StockpileBasketVaultFactory` | `src/StockpileBasketVaultFactory.sol` | `VaultFactoryBaseV2` + beacon. Portal-gated `newVault`; Guardian-only beacon upgrades. |
| `StockBasket` | `src/StockBasket.sol` | The per-token ERC-20 *index* token backed by a fixed set of `N` underlying stock tokens. |
| `StockBasketDeployer` | `src/StockBasketDeployer.sol` | Tiny helper that deploys a `StockBasket` on behalf of a vault (keeps factory initcode within EIP-3860). |

Plus the **immutable Flap prelude** in `src/flap/*` — canonical Flap interfaces and base contracts
(`VaultBase`, `VaultBaseV2`, `VaultFactoryBaseV2`, `IVault*`, `IPortal`, `IFlap*`, …). These are
Flap-canonical and treated as trusted / out of authorship scope; **do not modify them.**

### Prior design iterations (NOT the audit target)

The other `src/*Vault*.sol` files are earlier design iterations kept in-tree for reference only. They are
**not** part of the audit scope:

- `src/StockpileVault.sol`, `src/StockpileVaultFactory.sol` — single-stock (WBNB→stock) vault iteration.
- `src/MultiStockVault.sol` — multi-stock (WBNB → N stocks → N grids) iteration.
- `src/StockpileBasketVault.sol` — the V1 basket vault, superseded by `StockpileBasketVaultV2.sol`.

## Flap spec-checker result — COMPLIANT

The four conforming contracts passed Flap's official spec-checker across **rules 001–009 → COMPLIANT**.

- Full report: [`audit/FlapSpecAudit-v1.md`](audit/FlapSpecAudit-v1.md). The v1 pass surfaced one Medium
  (M1, a `vaultDataSchema` encoding defect — no fund risk) plus Low/Info hardening items; **all findings
  were resolved** in the post-fix pass (commit F3). The report's final section, *"v2 — POST-FIX VERDICT:
  COMPLIANT ✅"*, records the resolutions and the passing 219/219 non-fork suite. (The section-1 headline
  still shows the pre-fix v1 grade; the post-fix verdict at the bottom is the current status.)
- The Flap rules themselves are vendored under [`audit/flap-rules/`](audit/flap-rules/) (001–009).
- Additional internal reviews: `audit/BasketVault-audit-internal-v1.md`,
  `audit/MultiStockVault-audit-internal-v1.md`.

## Build & test

Run everything from **inside this directory** (`flap-vault/`), never from the repo root:

```bash
cd flap-vault

# one-time: fetch the pinned dependency submodules
git submodule update --init --recursive

forge build                              # compile (clean)
forge test --no-match-path 'test/fork/*' # 219 unit tests, all pass
forge test                               # includes BSC-fork tests (needs BSC_RPC_URL)
forge build --sizes                      # EIP-170 runtime sizes
```

The `test/fork/*` suites hit a BSC mainnet fork; set `BSC_RPC_URL` to run them. The 219 non-fork tests
need no network.

### Contract sizes (runtime, EIP-170 limit = 24,576 B)

| Contract | Runtime bytes |
|---|---|
| `StockpileBasketVaultV2` | 24,312 |
| `StockpileBasketVaultFactory` | 10,584 |
| `StockBasketDeployer` | 10,758 |
| `StockBasket` | 8,186 |

## Deployment

- **BSC Testnet (chainId 97) factory:** `0x909f882aB74b168f9D971f65ccA88E4897a9361D`

Deploy scripts live in `script/` (e.g. `DeployBasketVaultTestnet.s.sol`). Do not run `forge script` from
the repository root — run it from inside `flap-vault/` so the OZ v4.9.6 remappings resolve correctly.
