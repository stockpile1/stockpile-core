# Stockpile Core — UnifiedGridManager (Harberger engine)

The **core contract the Stockpile vault forwards funds into**, and therefore part of the audit scope:
`flush()` on a [StockpileVault](https://github.com/stockpile1/Stockpile) delivers WBNB to
**`UnifiedGridManager`** (UGM), which runs the Harberger seat market and holds/routes the pooled funds.
This repo is provided so the UGM is auditable alongside the vault.

- **Vault contracts:** https://github.com/stockpile1/Stockpile · **Frontend:** https://github.com/stockpile1/stockpile-vault-ui
- Solidity 0.8.x, OpenZeppelin **v5** (submodule). Build: `forge build` · Test: `forge test` (BSC fork tests need `BSC_RPC_URL`).
- **Audit scope:** [`src/core/UnifiedGridManager.sol`](src/core/UnifiedGridManager.sol) + its
  `src/interfaces/*`, `src/libraries/{GridTypes,HarbergerMath}.sol`. (The token/adapters/hooks are secondary.)

## Deployed (same address on both chains — same deployer + CREATE nonce)
| Chain | UnifiedGridManager | Verified |
|---|---|---|
| BSC mainnet (56) | `0xaA40Da4d2F81207196b16C29A9683ABA9d98Cbd1` | [BscScan](https://bscscan.com/address/0xaA40Da4d2F81207196b16C29A9683ABA9d98Cbd1#code) |
| BSC testnet (97) | `0xaA40Da4d2F81207196b16C29A9683ABA9d98Cbd1` | [testnet BscScan](https://testnet.bscscan.com/address/0xaA40Da4d2F81207196b16C29A9683ABA9d98Cbd1#code) |

Constructor params: `protocolSeatSaleBps=100 (1%)`, `creatorSeatSaleBps=200 (2%)`, `protocolTaxBps=2000 (20%)`.

## Fund-safety model — "funds are safe and cannot be rugged"

**User funds are pull-based and owner-inaccessible.** Every balance a user is owed is withdrawn by the user
themselves; there is **no owner path that can move user principal, deposits, or yield**:
| User exit | Function |
|---|---|
| Unspent tax deposit | `withdrawDeposit(gridId, seatId, amount)` |
| Seat yield | `claimYield` / `claimYieldBatch` |
| Sale / forfeiture proceeds (creator, seller) | `claimPayout(token)` (from `payouts[token][user]`) |
| Give up a seat | `abandonSeat` |

**The owner's only value-moving function is `withdrawTaxRevenue(gridId)`**, which sweeps *only* the **protocol
bucket** (`gridTaxRevenue` = the protocol tax cut + protocol seat-sale cut + forfeiture penalties) to
`protocolFeeReceiver`. It is fully isolated from `payouts` / deposits / seat yield — the owner cannot reach
user money through it.

**Admin powers are capped and non-lock-out:**
- Fee knobs are bounded by constants: `MAX_TAX_BPS = 1000` (10%/week grid tax), `MAX_PROTOCOL_BPS = 5000`
  (each protocol cut ≤ 50%; protocol+creator seat-sale cuts combined < 100%). The owner cannot set 100% fees.
- `pauseGrid` / `deprecateGrid` **keep every user-exit path open** (`withdrawDeposit`, `abandonSeat`,
  `claimYield`, `claimPayout`, `pokeTax`) — a deprecated/paused grid cannot trap user funds.
- `receiveYieldERC20` credits the **measured received balance delta**, so a fee-on-transfer token cannot
  over-credit a grid.

**Reentrancy / accounting:** `nonReentrant` on all value-moving entries; checks-effects-interactions ordering
(seats are reassigned only after payouts settle).

### ⚠️ Known centralization item for the auditor
The UGM `owner` is currently the **deployer EOA** `0x53140D0D4Fa6E7cD15e29df89c5B0b41CF04f1b2` (the NatSpec
describes it as a "guardian multisig"). While the owner **cannot steal user funds** (above), an EOA admin can
still *grief* (pause grids, raise protocol cuts up to the 50% cap, redirect the protocol fee receiver). For a
**low-risk** rating we recommend transferring ownership to a **multisig / timelock** before/at mainnet launch
(`transferOwnership(multisig)`), and optionally renouncing the pause powers once stable.

## Build & test
```bash
forge install            # pulls the OZ v5 + forge-std submodules
forge build
forge test               # unit + BSC-fork tests (set BSC_RPC_URL for the fork tests)
```

_MIT licensed._
