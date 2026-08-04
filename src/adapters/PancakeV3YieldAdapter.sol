// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import { BaseYieldAdapter } from "./BaseYieldAdapter.sol";
import { INonfungiblePositionManager, IPancakeV3SwapRouter } from "../interfaces/external/IPancakeV3.sol";

/// @title PancakeV3YieldAdapter
/// @notice Wraps a PancakeSwap V3 LP position (ERC721) and streams its accrued swap
///         fees into a grid. Port of Takeover's V3YieldAdapter (Uniswap V3 on Base).
/// @dev The LP NFT must be transferred to this adapter before `registerPosition`.
///      Two harvest entry points with different trust models:
///      - `collectYield` (permissionless, IYieldAdapter): collects accrued LP fees and forwards
///        ONLY the already-yield-token side. It performs NO swap, so it is safe to call by
///        anyone and cannot be sandwiched. The non-yield side accumulates in the adapter.
///      - `harvestWithMinOut(assetHash, minOut)`: additionally swaps the accumulated non-yield
///        side into the yield token under a caller-supplied slippage floor, then forwards.
///        This is the slippage-guarded conversion path for keepers (AUDIT-1 F-02).
contract PancakeV3YieldAdapter is BaseYieldAdapter {
    using SafeERC20 for IERC20;

    INonfungiblePositionManager public immutable positionManager;
    IPancakeV3SwapRouter public immutable swapRouter;

    mapping(bytes32 => uint256) public tokenIdOf;
    mapping(bytes32 => uint24) public swapFeeOf; // pool fee used to convert the non-yield side

    /// @notice Whether a yield token is already claimed by a currently-registered position on this
    ///         adapter. Enforces AT MOST ONE registered position per yield token, mirroring
    ///         {FlapYieldAdapter.yieldTokenInUse}.
    /// @dev    `_harvest` forwards the adapter's ENTIRE balance of the registered yield token, so the
    ///         sweep is only attributable to one grid if no second position can claim the same token.
    ///         Without this, two positions with overlapping token sets cross-contaminate: position A's
    ///         uncollected NON-yield side accumulates in the adapter awaiting `harvestWithMinOut`, and a
    ///         later permissionless `collectYield(B)` — where that same token is B's YIELD side — sweeps
    ///         A's residual into grid B, permanently losing it for grid A's seat holders.
    mapping(address => bool) public yieldTokenInUse;

    /// @notice Emitted when a V3 position is wired to a grid.
    /// @param assetHash Canonical handle assigned to the position.
    /// @param gridId The grid the position's fees are distributed to.
    /// @param tokenId The V3 position NFT id.
    /// @param yieldToken The pair side chosen as the distributed yield token.
    event PositionRegistered(bytes32 indexed assetHash, uint256 indexed gridId, uint256 tokenId, address yieldToken);

    /// @notice Emitted when accrued fees are harvested and forwarded to the UGM.
    /// @param assetHash Canonical handle of the harvested position.
    /// @param forwarded Amount of yield token forwarded to the UGM.
    event Harvested(bytes32 indexed assetHash, uint256 forwarded);

    /// @notice Deploy the adapter with its PancakeSwap V3 dependencies.
    /// @param ugm_ The Unified Grid Manager this adapter forwards yield to.
    /// @param positionManager_ The PancakeSwap V3 NonfungiblePositionManager.
    /// @param swapRouter_ The PancakeSwap V3 SwapRouter used to convert the non-yield side.
    /// @param owner_ The owner authorized to register/withdraw positions.
    constructor(address ugm_, address positionManager_, address swapRouter_, address owner_)
        BaseYieldAdapter(ugm_, owner_)
    {
        positionManager = INonfungiblePositionManager(positionManager_);
        swapRouter = IPancakeV3SwapRouter(swapRouter_);
    }

    /// @notice Canonical asset hash for a V3 position managed by this adapter.
    /// @param tokenId The V3 position NFT id.
    /// @return The deterministic asset hash for the position.
    function assetHashFor(uint256 tokenId) public view returns (bytes32) {
        return keccak256(abi.encode("PancakeV3", address(positionManager), tokenId));
    }

    /// @notice Wire a V3 position (already transferred to this adapter) to a grid.
    /// @param gridId         The grid the position's fees are distributed to.
    /// @param tokenId        The V3 position NFT id (must already be held by this adapter).
    /// @param yieldTokenSide Which side of the pair to distribute (must be token0 or token1).
    /// @param swapFee        Pool fee tier used to convert the other side into yieldTokenSide.
    /// @return assetHash     Canonical handle assigned to the registered position.
    function registerPosition(uint256 gridId, uint256 tokenId, address yieldTokenSide, uint24 swapFee)
        external
        onlyOwnerOrGuardian
        returns (bytes32 assetHash)
    {
        require(positionManager.ownerOf(tokenId) == address(this), "NFT not held");
        (,, address token0, address token1,,,,,,,,) = positionManager.positions(tokenId);
        require(yieldTokenSide == token0 || yieldTokenSide == token1, "yield side");
        // One position per yield token: `_harvest` sweeps the WHOLE balance of it, so a second claimant
        // would make that sweep ambiguous and let one grid drain another's residual (see yieldTokenInUse).
        require(!yieldTokenInUse[yieldTokenSide], "yieldToken in use");

        assetHash = assetHashFor(tokenId);
        tokenIdOf[assetHash] = tokenId;
        swapFeeOf[assetHash] = swapFee;
        _registerAsset(assetHash, gridId, yieldTokenSide);
        yieldTokenInUse[yieldTokenSide] = true;
        emit PositionRegistered(assetHash, gridId, tokenId, yieldTokenSide);
    }

    /// @notice Unwire a position from its grid and return the NFT.
    /// @param assetHash Canonical handle of the position to withdraw.
    /// @param to        Recipient of the returned position NFT.
    /// @dev Frees the position's yield token so it can be claimed by a future registration.
    function withdrawPosition(bytes32 assetHash, address to) external onlyOwnerOrGuardian {
        address y = assets[assetHash].yieldToken;
        _withdrawAsset(assetHash);
        yieldTokenInUse[y] = false;
        positionManager.safeTransferFrom(address(this), to, tokenIdOf[assetHash]);
    }

    /// @notice Permissionless keeper entry (IYieldAdapter). Collects accrued LP fees and
    ///         forwards ONLY the already-yield-token side to the UGM. Performs NO swap, so it is
    ///         safe to call by anyone and cannot be sandwiched (AUDIT-1 F-02). The non-yield
    ///         side accumulates in the adapter until a keeper calls `harvestWithMinOut`.
    /// @dev Idempotent: with no newly accrued fees the collected yield-side balance is 0 and
    ///      `_forward` moves nothing. Forwarding uses `forceApprove` (via `_forward`).
    /// @param assetHash Canonical handle of the position to harvest.
    /// @return Amount of yield token forwarded to the UGM.
    function collectYield(bytes32 assetHash) external returns (uint256) {
        return _harvest(assetHash, 0, false);
    }

    /// @notice Best-effort estimate of the yield-side fees currently owed to the position.
    /// @dev Reads the position's checkpointed `tokensOwed0/1` via `positions()` and returns the
    ///      side that matches the registered yield token. This is an ESTIMATE: `tokensOwed` only
    ///      reflects fees checkpointed at the last position update, not fees earned since. Never
    ///      reverts (try/catch -> 0) per the IYieldAdapter contract.
    /// @param assetHash Canonical handle of the position to query.
    /// @return Estimated yield-token amount currently owed to the position (0 if unavailable).
    function pendingYield(bytes32 assetHash) external view returns (uint256) {
        if (!assets[assetHash].registered) return 0;
        address y = assets[assetHash].yieldToken;
        try positionManager.positions(tokenIdOf[assetHash]) returns (
            uint96,
            address,
            address token0,
            address,
            uint24,
            int24,
            int24,
            uint128,
            uint256,
            uint256,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) {
            return y == token0 ? uint256(tokensOwed0) : uint256(tokensOwed1);
        } catch {
            return 0;
        }
    }

    /// @notice Keeper harvest that ALSO converts the accumulated non-yield side into the yield
    ///         token under an explicit slippage guard, then forwards everything. This is the
    ///         only path that swaps; the `minOut` floor is the caller's slippage protection.
    /// @param assetHash Canonical handle of the position to harvest.
    /// @param minOut    Minimum yield token out of the internal non-yield-side swap.
    /// @return Amount of yield token forwarded to the UGM.
    function harvestWithMinOut(bytes32 assetHash, uint256 minOut) external onlyOwnerOrGuardian returns (uint256) {
        return _harvest(assetHash, minOut, true);
    }

    /// @dev Collects position fees, optionally swaps the non-yield side (only when `doSwap`,
    ///      i.e. the guarded `harvestWithMinOut` path), then forwards the yield-token balance.
    function _harvest(bytes32 assetHash, uint256 minOut, bool doSwap) internal returns (uint256 forwarded) {
        require(assets[assetHash].registered, "not registered");
        uint256 tokenId = tokenIdOf[assetHash];
        (,, address token0, address token1,,,,,,,,) = positionManager.positions(tokenId);

        positionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        address y = assets[assetHash].yieldToken;

        if (doSwap) {
            address other = y == token0 ? token1 : token0;
            uint256 otherBal = IERC20(other).balanceOf(address(this));
            if (otherBal > 0) {
                IERC20(other).forceApprove(address(swapRouter), otherBal);
                swapRouter.exactInputSingle(
                    IPancakeV3SwapRouter.ExactInputSingleParams({
                        tokenIn: other,
                        tokenOut: y,
                        fee: swapFeeOf[assetHash],
                        recipient: address(this),
                        deadline: block.timestamp,
                        amountIn: otherBal,
                        amountOutMinimum: minOut,
                        sqrtPriceLimitX96: 0
                    })
                );
            }
        }

        forwarded = _forward(assetHash, IERC20(y).balanceOf(address(this)));
        emit Harvested(assetHash, forwarded);
    }

    /// @notice Accept LP NFTs via safeTransferFrom.
    /// @return The ERC721 receiver magic value acknowledging the transfer.
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
