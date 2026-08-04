// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @title StockConfig — the 7 Stockpile basket stocks + swap parameters (single source of truth)
/// @notice Fixed order used everywhere: **SPCXB, QQQB, NVDAB, SPYB, TSLAB, AAPLB, XAUt**.
/// @dev Addresses are the BSC-mainnet stock tokens (verified from the reference StockpileVault deploy).
///      `fees` are the USDT→stock PancakeSwap V3 pool fee tiers (the swap is WBNB→USDT→stock, 2-hop).
///      `weights` are the basket split in bps and sum to exactly 10_000. All three arrays are
///      index-aligned with the stock order above.
library StockConfig {
    uint256 internal constant COUNT = 7;

    /// @notice The 7 stock tokens on BSC mainnet, in canonical order.
    function mainnetStocks() internal pure returns (address[7] memory s) {
        s = [
            0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1, // SPCXB
            0x205812CdBed920aFf76C6580abD681a46D11efc7, // QQQB
            0x02Fca66C1D1aFB4E2A7884261eB00F63598a7436, // NVDAB
            0x7138b48df7D98D7e3cc221BfE7192D0a178182D8, // SPYB
            0x5b1910eAaD6450E50f816082Aa078C41F10C292f, // TSLAB
            0x431a3BEE82E2ca41e49895CbECE5bB0F76A89b7A, // AAPLB
            0x21cAef8A43163Eea865baeE23b9C2E327696A3bf // XAUt
        ];
    }

    /// @notice USDT→stock V3 fee tiers, index-aligned with {mainnetStocks}.
    function fees() internal pure returns (uint24[7] memory f) {
        f = [uint24(2500), 100, 2500, 100, 2500, 2500, 2500];
    }

    /// @notice Basket swap weights in bps (sum 10_000), index-aligned with {mainnetStocks}.
    function weights() internal pure returns (uint16[7] memory w) {
        w = [uint16(1429), 1429, 1429, 1429, 1429, 1429, 1426];
    }
}
