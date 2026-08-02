// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title BscAddresses
/// @notice Canonical BNB Smart Chain (chainId 56) addresses used by the Takeover
///         BNB port for deployment and fork testing.
/// @dev All addresses are EIP-55 checksummed. Sources: PancakeSwap developer docs,
///      Flap developer docs (docs.flap.sh), BscScan.
library BscAddresses {
    uint256 internal constant CHAIN_ID = 56;

    // ---------------------------------------------------------------------
    // Core tokens
    // ---------------------------------------------------------------------
    /// @notice Wrapped BNB — the BNB-native equivalent of Base's flETH.
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    /// @notice Binance-Peg USDT (18 decimals on BSC) — common tax token.
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    /// @notice Binance-Peg USDC (18 decimals on BSC).
    address internal constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;

    /// @notice STOCK — the quote/fee token a Flap launch is paired against, and the token
    ///         seat holders earn as yield. Live token: "SpaceX" (SPCXB), 18 decimals.
    ///         The canonical product flow: Flap launch paired with STOCK → fees in STOCK →
    ///         Takeover Harberger seats over the STOCK fee stream. See docs/DECISIONS.md D9.
    address internal constant STOCK = 0xbe9D156892E55e7154BcD3cB0FEA677F9D3103E1;

    // ---------------------------------------------------------------------
    // PancakeSwap V3 (replaces Uniswap V3 on Base)
    // ---------------------------------------------------------------------
    /// @notice PancakeSwap V3 NonfungiblePositionManager (LP NFTs + fee collection).
    address internal constant PANCAKE_V3_POSITION_MANAGER = 0x46A15B0b27311cedF172AB29E4f4766fbE7F4364;
    /// @notice PancakeSwap V3 factory (pool resolution and deployment).
    address internal constant PANCAKE_V3_FACTORY = 0x0BFbCF9fa4f9C56B0F40a671Ad40E0805A091865;
    /// @notice PancakeSwap V3 SwapRouter (single-pool exact-input swaps used by adapters).
    address internal constant PANCAKE_V3_SWAP_ROUTER = 0x1b81D678ffb9C0263b24A97847620C99d213eB14;
    /// @notice Aggregating SmartRouter (V2+V3+stable) — used by the buyback keeper.
    address internal constant PANCAKE_SMART_ROUTER = 0x13f4EA83D0bd40E75C8222255bc855a974568Dd4;
    /// @notice PancakeSwap MasterChef V3 (staking for V3 LP positions).
    address internal constant PANCAKE_MASTERCHEF_V3 = 0x556B9306565093C855AEA9AE92A594704c2Cd59e;

    // ---------------------------------------------------------------------
    // Flap launchpad (replaces Flaunch on Base)
    // ---------------------------------------------------------------------
    /// @notice Main Flap entry point (bonding curve + token management), v5.14.16.
    address internal constant FLAP_PORTAL = 0xe2cE6ab80874Fa9Fa2aAE65D277Dd6B8e65C9De0;
    /// @notice Flap launchpad (token creation).
    address internal constant FLAP_LAUNCHPAD = 0x1de460f363AF910f51726DEf188F9004276Bf4bc;
    /// @notice Flap VaultPortal — manages fee/revenue vaults for launched tokens.
    address internal constant FLAP_VAULT_PORTAL = 0x90497450f2a706f1951b5bdda52B4E5d16f34C06;

    // Flap token implementation templates (minimal-proxy targets)
    address internal constant FLAP_STANDARD_TOKEN_IMPL = 0x8B4329947e34B6d56D71A3385caC122BaDe7d78D;
    address internal constant FLAP_TAX_TOKEN_V1_IMPL = 0x29e6383F0ce68507b5A72a53c2B118a118332aA8;
    address internal constant FLAP_TAX_TOKEN_V2_IMPL = 0xae562c6A05b798499507c6276C6Ed796027807BA;
    address internal constant FLAP_TAX_TOKEN_V3_IMPL = 0x024f18294970B5c76c0691b87f138A0317156422;
    address internal constant FLAP_STANDARD_TOKEN_V3_IMPL = 0x88881b6f03090462a969eC7f48385744Eeb63333;
    address internal constant FLAP_TAX_TOKEN_HELPER = 0x53841c73217735F37BC1775538b03b23feFD8346;
}
