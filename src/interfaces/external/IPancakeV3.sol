// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title PancakeSwap V3 minimal interfaces
/// @notice Only the surface needed by the Takeover BNB port. PancakeSwap V3 is a
///         Uniswap V3 fork; these signatures match the deployed BSC contracts.

/// @notice NonfungiblePositionManager (ERC721): mints LP positions and collects their fees.
interface INonfungiblePositionManager {
    /// @notice Read the full state of an LP position NFT.
    /// @param tokenId The position NFT id to query.
    /// @return nonce Permit nonce for the position.
    /// @return operator Address approved to manage the position.
    /// @return token0 The pool's token0.
    /// @return token1 The pool's token1.
    /// @return fee The pool fee tier, in hundredths of a bip.
    /// @return tickLower Lower tick bound of the position's range.
    /// @return tickUpper Upper tick bound of the position's range.
    /// @return liquidity Liquidity currently provided by the position.
    /// @return feeGrowthInside0LastX128 token0 fee growth per unit of liquidity as of the last update (Q128).
    /// @return feeGrowthInside1LastX128 token1 fee growth per unit of liquidity as of the last update (Q128).
    /// @return tokensOwed0 Uncollected token0 fees owed to the position.
    /// @return tokensOwed1 Uncollected token1 fees owed to the position.
    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

    /// @notice Parameters for `collect`.
    struct CollectParams {
        uint256 tokenId; // position NFT id to collect from
        address recipient; // address that receives the collected tokens
        uint128 amount0Max; // maximum token0 to collect
        uint128 amount1Max; // maximum token1 to collect
    }

    /// @notice Collect accrued swap fees (and any decreased liquidity) for a position.
    /// @param params Which position to collect from, the recipient, and per-token caps.
    /// @return amount0 token0 amount transferred to the recipient.
    /// @return amount1 token1 amount transferred to the recipient.
    function collect(CollectParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);

    /// @notice Parameters for `mint`.
    struct MintParams {
        address token0; // pool token0
        address token1; // pool token1
        uint24 fee; // pool fee tier
        int24 tickLower; // lower tick bound of the new range
        int24 tickUpper; // upper tick bound of the new range
        uint256 amount0Desired; // desired token0 to deposit
        uint256 amount1Desired; // desired token1 to deposit
        uint256 amount0Min; // minimum token0 to deposit (slippage guard)
        uint256 amount1Min; // minimum token1 to deposit (slippage guard)
        address recipient; // owner of the minted position NFT
        uint256 deadline; // unix timestamp after which the mint reverts
    }

    /// @notice Mint a new liquidity position and its NFT.
    /// @param params Pool, range, desired/minimum amounts, recipient and deadline.
    /// @return tokenId Id of the minted position NFT.
    /// @return liquidity Liquidity added to the position.
    /// @return amount0 token0 actually deposited.
    /// @return amount1 token1 actually deposited.
    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    /// @notice Current owner of a position NFT.
    /// @param tokenId The position NFT id.
    /// @return The address that owns the NFT.
    function ownerOf(uint256 tokenId) external view returns (address);

    /// @notice Safe-transfer a position NFT, checking receiver support.
    /// @param from Current owner of the NFT.
    /// @param to Recipient of the NFT.
    /// @param tokenId The position NFT id to transfer.
    function safeTransferFrom(address from, address to, uint256 tokenId) external;

    /// @notice Transfer a position NFT without a receiver check.
    /// @param from Current owner of the NFT.
    /// @param to Recipient of the NFT.
    /// @param tokenId The position NFT id to transfer.
    function transferFrom(address from, address to, uint256 tokenId) external;

    /// @notice Approve `to` to transfer a specific position NFT.
    /// @param to Address granted transfer approval.
    /// @param tokenId The position NFT id to approve.
    function approve(address to, uint256 tokenId) external;
}

/// @notice PancakeSwap V3 SwapRouter (0x1b81D678...): the classic Uniswap V3 router layout,
///         whose `ExactInputSingleParams` includes a `deadline` field.
interface IPancakeV3SwapRouter {
    /// @notice Parameters for `exactInputSingle`.
    struct ExactInputSingleParams {
        address tokenIn; // token supplied to the swap
        address tokenOut; // token received from the swap
        uint24 fee; // pool fee tier to route through
        address recipient; // address that receives tokenOut
        uint256 deadline; // unix timestamp after which the swap reverts
        uint256 amountIn; // exact amount of tokenIn to spend
        uint256 amountOutMinimum; // minimum tokenOut to accept (slippage guard)
        uint160 sqrtPriceLimitX96; // price limit for the swap (0 = no limit)
    }

    /// @notice Swap an exact amount of one token for another through a single pool.
    /// @param params Token pair, fee tier, recipient, deadline, amounts and price limit.
    /// @return amountOut Amount of `tokenOut` sent to the recipient.
    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);
}

/// @notice PancakeSwap V3 factory: resolves and deploys pools by token pair and fee tier.
interface IPancakeV3Factory {
    /// @notice Address of the pool for a token pair and fee tier, or zero if none exists.
    /// @param tokenA One token of the pair (order-independent).
    /// @param tokenB The other token of the pair.
    /// @param fee The pool fee tier, in hundredths of a bip.
    /// @return pool The pool address, or the zero address if it has not been created.
    function getPool(address tokenA, address tokenB, uint24 fee) external view returns (address pool);

    /// @notice Deploy the pool for a token pair and fee tier.
    /// @param tokenA One token of the pair (order-independent).
    /// @param tokenB The other token of the pair.
    /// @param fee The pool fee tier, in hundredths of a bip.
    /// @return pool The newly created pool address.
    function createPool(address tokenA, address tokenB, uint24 fee) external returns (address pool);
}

/// @notice PancakeSwap V3 pool: minimal view/init surface used by the port.
interface IPancakeV3Pool {
    /// @notice Set the initial price of a freshly created pool.
    /// @param sqrtPriceX96 The starting sqrt price as a Q64.96 fixed-point value.
    function initialize(uint160 sqrtPriceX96) external;

    /// @notice The pool's current price and oracle/lock state (slot0).
    /// @return sqrtPriceX96 Current price as a Q64.96 sqrt value.
    /// @return tick Current tick corresponding to `sqrtPriceX96`.
    /// @return observationIndex Index of the most recent oracle observation.
    /// @return observationCardinality Number of populated oracle observations.
    /// @return observationCardinalityNext Target oracle cardinality after the next grow.
    /// @return feeProtocol Protocol fee portion currently applied.
    /// @return unlocked Whether the pool is currently unlocked (not mid-callback).
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint32 feeProtocol,
            bool unlocked
        );

    /// @notice Tick spacing enforced by the pool's fee tier.
    /// @return The minimum tick separation between initialized ticks.
    function tickSpacing() external view returns (int24);

    /// @notice Total in-range liquidity currently active in the pool.
    /// @return The pool's active liquidity.
    function liquidity() external view returns (uint128);

    /// @notice The pool's token0.
    /// @return The token0 address.
    function token0() external view returns (address);

    /// @notice The pool's token1.
    /// @return The token1 address.
    function token1() external view returns (address);

    /// @notice The pool's fee tier.
    /// @return The fee tier, in hundredths of a bip.
    function fee() external view returns (uint24);
}
