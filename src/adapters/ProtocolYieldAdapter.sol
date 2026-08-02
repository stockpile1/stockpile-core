// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { BaseYieldAdapter } from "./BaseYieldAdapter.sol";

/// @title ProtocolYieldAdapter
/// @notice The simplest yield adapter: it wraps a protocol-fee ERC20 stream and forwards
///         it into a grid. Unlike the Flap or PancakeV3 adapters there is no external vault,
///         LP position, or claim call to make — the adapter is itself named as the recipient
///         of some protocol's fees (e.g. swap/router fees, a treasury split), so those fees
///         simply accrue to this contract's balance over time.
/// @dev `collectYield` forwards whatever `yieldToken` balance the adapter currently holds into
///      the UGM, splitting it across the grid's seats. It is permissionless (any keeper may call)
///      and a zero balance is a no-op that returns 0. There is nothing to "harvest" from an
///      external source: the yield token arriving here as the fee recipient *is* the stream.
contract ProtocolYieldAdapter is BaseYieldAdapter {
    /// @notice Emitted when a protocol-fee stream is wired to a grid.
    /// @param assetHash Canonical handle assigned to the stream.
    /// @param gridId The grid the fees are distributed to.
    /// @param yieldToken The token the forwarded fees are denominated in.
    event FeeStreamRegistered(bytes32 indexed assetHash, uint256 indexed gridId, address yieldToken);

    /// @notice Emitted when a protocol-fee stream is unwired from its grid.
    /// @param assetHash Canonical handle of the withdrawn stream.
    event FeeStreamWithdrawn(bytes32 indexed assetHash);

    /// @notice Emitted when the adapter's accrued balance is forwarded to the UGM.
    /// @param assetHash Canonical handle of the collected stream.
    /// @param forwarded Amount of yield token forwarded to the UGM.
    event Collected(bytes32 indexed assetHash, uint256 forwarded);

    /// @notice Deploy the adapter, binding it to a UGM and an owner.
    /// @param ugm_ The Unified Grid Manager this adapter forwards yield to.
    /// @param owner_ The owner authorized to register/withdraw fee streams.
    constructor(address ugm_, address owner_) BaseYieldAdapter(ugm_, owner_) {}

    /// @notice Canonical asset hash for a protocol-fee stream of `yieldToken` wired to `gridId`.
    /// @param gridId The grid the stream is wired to.
    /// @param yieldToken The ERC20 the protocol fees are denominated in.
    /// @return The deterministic asset hash for the stream.
    function assetHashFor(uint256 gridId, address yieldToken) public pure returns (bytes32) {
        return keccak256(abi.encode("Protocol", gridId, yieldToken));
    }

    /// @notice Wire a protocol-fee stream (fees routed to this adapter in `yieldToken`) to a grid.
    /// @param gridId The grid that will receive the forwarded fees.
    /// @param yieldToken The ERC20 the protocol fees are denominated in.
    /// @return assetHash Canonical handle for the registered stream.
    function registerFeeStream(uint256 gridId, address yieldToken)
        external
        onlyOwner
        returns (bytes32 assetHash)
    {
        assetHash = assetHashFor(gridId, yieldToken);
        _registerAsset(assetHash, gridId, yieldToken);
        emit FeeStreamRegistered(assetHash, gridId, yieldToken);
    }

    /// @notice Unwire a previously registered protocol-fee stream from its grid.
    /// @param assetHash Canonical handle of the stream to withdraw.
    function withdrawFeeStream(bytes32 assetHash) external onlyOwner {
        _withdrawAsset(assetHash);
        emit FeeStreamWithdrawn(assetHash);
    }

    /// @notice Forward the adapter's entire accrued `yieldToken` balance for `assetHash` to the UGM.
    /// @dev Permissionless and idempotent: returns 0 (no-op) when nothing has accrued since the
    ///      last call. Forwarding uses `forceApprove` (via `_forward`).
    /// @param assetHash Canonical handle of the stream to collect.
    /// @return forwarded Amount of yield token forwarded to the UGM.
    function collectYield(bytes32 assetHash) external returns (uint256 forwarded) {
        require(assets[assetHash].registered, "not registered");
        address y = assets[assetHash].yieldToken;
        forwarded = _forward(assetHash, IERC20(y).balanceOf(address(this)));
        emit Collected(assetHash, forwarded);
    }

    /// @notice Best-effort pending yield: the adapter's current `yieldToken` balance (which is
    ///         exactly what the next `collectYield` would forward).
    /// @dev Never reverts (try/catch -> 0); returns 0 for an unregistered asset.
    /// @param assetHash Canonical handle of the stream to query.
    /// @return The adapter's accrued yield-token balance for the stream.
    function pendingYield(bytes32 assetHash) external view returns (uint256) {
        address y = assets[assetHash].yieldToken;
        if (y == address(0)) return 0;
        try IERC20(y).balanceOf(address(this)) returns (uint256 bal) {
            return bal;
        } catch {
            return 0;
        }
    }
}
