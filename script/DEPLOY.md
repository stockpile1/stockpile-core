# Deploy scripts — Stockpile vault-backed factory

Re-runnable Foundry scripts to stand up the Flap vault-backed **`StockpileBasketVaultFactory`** (and,
on testnet, launch a real vault-backed token through it) on BSC **testnet (97)** and **mainnet (56)**.

| Script | What it does |
|---|---|
| [`DeployVaultFactory.s.sol`](DeployVaultFactory.s.sol) | Deploys `StockpileBasketVaultFactory`. Its constructor self-deploys the `StockBasketDeployer`, the vault implementation, and the `UpgradeableBeacon`. Chain-aware addresses. |
| [`LaunchVaultTokenTestnet.s.sol`](LaunchVaultTokenTestnet.s.sol) | Testnet only: launches a real `7777`-vanity Flap token through the live testnet `VaultPortal.newTokenV6WithVault`, bound to the factory above (the true vault-backed path). |
| [`Deploy.s.sol`](Deploy.s.sol) | The **core** deploy (UGM, adapters, keeper, hook, token) — unrelated to the vault. |

> ⚠️ **Secret hygiene.** `PRIVATE_KEY` is read from the env — **never commit, echo, or paste it.** The
> testnet deployer key is plaintext/testnet-only; generate a **fresh** key for mainnet and never fund the
> testnet key with mainnet value. `broadcast/` and `cache/` (which include a `dry-run` copy of inputs) are
> gitignored.

## 1. Deploy the factory

Always **dry-run first** (no `--broadcast`); add `--broadcast` to actually send.

### Testnet (chainId 97)
Uses the live, already-allowlisted **tWBNB** + live **UGM**, and deploys **mock USDT + mock V3 router + 3
mock stocks** (no real BSC-USD / PancakeSwap V3 pools exist on testnet; the mock router mints swap proceeds
1:1 so `distribute()` works).

```bash
export PRIVATE_KEY=0x…                     # funded testnet key (never commit)
RPC=https://data-seed-prebsc-1-s1.bnbchain.org:8545

# dry-run
forge script script/DeployVaultFactory.s.sol --rpc-url $RPC
# broadcast
forge script script/DeployVaultFactory.s.sol --rpc-url $RPC --broadcast --legacy
```
Copy the logged `factory` + `STOCK0/1/2` addresses — the launch script (step 2) reads them from env.

### Mainnet (chainId 56)
Uses **real** WBNB, USDT, PancakeSwap V3 SwapRouter, and the live UGM (`0xaA40Da…Cbd1`).

```bash
export PRIVATE_KEY=0x…                     # fresh, funded mainnet key
forge script script/DeployVaultFactory.s.sol --rpc-url $BSC_RPC_URL            # dry-run
forge script script/DeployVaultFactory.s.sol --rpc-url $BSC_RPC_URL --broadcast --verify
```
`--verify` needs `BSCSCAN_API_KEY` in the env (wired in `foundry.toml`'s `[etherscan]`).

### Env overrides (both chains)
Any input can be overridden without editing the script:

| Env | Default (56 / 97) |
|---|---|
| `WBNB` | `0xbb4C…095c` / `0xae13…a7cd` (tWBNB) |
| `USDT` | `0x5559…7955` / a fresh mock |
| `UGM` | `0xaA40…Cbd1` (both) |
| `ROUTER` | PancakeV3 `0x1b81…eB14` / a fresh `MockV3Router` |
| `WBNB_USDT_FEE` | `100` |

## 2. Launch a vault-backed token (testnet)

After step 1, export the addresses it logged, then run the launch. The basket is the **7 stocks**
(`SPCXB, QQQB, NVDAB, SPYB, TSLAB, AAPLB, XAUt` — see [`StockConfig.sol`](StockConfig.sol) for the
mainnet addresses + fee tiers + weights):

```bash
export PRIVATE_KEY=0x…
export FACTORY=0x…      # logged by DeployVaultFactory
export STOCK0=0x… STOCK1=0x… STOCK2=0x… STOCK3=0x… STOCK4=0x… STOCK5=0x… STOCK6=0x…   # the 7 stocks, in order
export FUND_WEI=20000000000000000   # optional: initial BNB to fund the launch (default 0.02)

RPC=https://data-seed-prebsc-1-s1.bnbchain.org:8545
forge script script/LaunchVaultTokenTestnet.s.sol --rpc-url $RPC              # dry-run
forge script script/LaunchVaultTokenTestnet.s.sol --rpc-url $RPC --broadcast --legacy
```
It grinds an unused `7777` vanity salt, launches through the live testnet `VaultPortal`, reads the vault
back via `VaultPortal.getVault(token).vault`, and runs the permissionless `setupMarket()`.

> A mainnet launch goes through the mainnet `FLAP_VAULT_PORTAL` (`0x9049…4C06`) with real stock tokens; the
> vanity/impl constants in the script are testnet-specific, so adapt those before a mainnet launch.

## Verify already-deployed contracts

```bash
forge verify-contract <factory-addr> src/vault/StockpileBasketVaultFactory.sol:StockpileBasketVaultFactory \
  --chain <56|97> --constructor-args $(cast abi-encode \
  "constructor(address,address,address,address,uint24)" <wbnb> <usdt> <ugm> <router> 100) \
  --etherscan-api-key $BSCSCAN_API_KEY
```
