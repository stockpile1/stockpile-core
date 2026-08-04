// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @title StockConfig — the Stockpile basket stocks + swap parameters (single source of truth)
/// @notice Fixed order used everywhere: **SPCXB, NVDAB, AAPLB, GMEon**.
/// @dev Addresses are the BSC-mainnet stock tokens (verified from the reference StockpileVault deploy).
///      `fees` are the USDT→stock PancakeSwap V3 pool fee tiers (the swap is WBNB→USDT→stock, 2-hop).
///      `weights` are the basket split in bps and sum to exactly 10_000. All three arrays are
///      index-aligned with the stock order above.
///
///      ── WHY FOUR, NOT SEVEN ──────────────────────────────────────────────────────
///
///      The basket was cut from 7 legs to 4 so a distribute fits the Flap Trigger Service's hard
///      2,000,000-gas callback budget (Rule 008 §4). Measured against live PancakeSwap V3 pools a
///      distribute costs ~690k fixed plus ~225k per leg, so 7 legs (~2.27M) overruns the budget and its
///      callback would be recorded FAILED, while 4 legs (~1.59M) leaves ~20% headroom. See
///      `StockpileBasketVaultV2.MAX_TRIGGER_STOCKS`. Keeping the basket inside that budget is what lets
///      the vault schedule itself permissionlessly instead of depending on a Guardian-appointed keeper.
///
///      The four legs are SPCXB (SpaceX), NVDAB (NVIDIA), AAPLB (Apple) and GMEon (GameStop, Ondo
///      tokenized). Dropped from the original seven: QQQB, SPYB, TSLAB and XAUt.
///
///      Every leg's USDT pool was verified live on BSC mainnet at the 2500 (0.25%) tier — the only tier
///      with a deployed pool for all four — with non-trivial liquidity:
///        SPCXB 0x977DaFFC…5b4d (1.82e24) · NVDAB 0x8FB4243b…690C (3.76e24)
///        AAPLB 0xe9b9998B…7365 (8.38e22) · GMEon 0x2a73552F…A089 (4.31e22)
///      This matters more than usual: the Trigger Service path swaps with a ZERO slippage floor, so a
///      missing or thin pool is not caught by a minOut guard. Re-verify before changing any leg.
library StockConfig {
    uint256 internal constant COUNT = 4;

    /// @notice The basket's stock tokens on BSC mainnet, in canonical order.
    function mainnetStocks() internal pure returns (address[4] memory s) {
        s = [
            0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1, // SPCXB
            0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436, // NVDAB
            0x431a3BEE82E2ca41e49895CbECE5bB0F76A89b7A, // AAPLB
            0xdABb9afF4cf02f26D2014e4cA9f94aC6fe6572a3 // GMEon (GameStop, Ondo tokenized)
        ];
    }

    /// @notice USDT→stock V3 fee tiers, index-aligned with {mainnetStocks}.
    function fees() internal pure returns (uint24[4] memory f) {
        f = [uint24(2500), 2500, 2500, 2500];
    }

    /// @notice Basket swap weights in bps (sum 10_000), index-aligned with {mainnetStocks}.
    function weights() internal pure returns (uint16[4] memory w) {
        w = [uint16(2500), 2500, 2500, 2500];
    }
}
