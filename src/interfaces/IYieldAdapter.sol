// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IYieldAdapter
/// @notice Interface every yield source plugs into. An adapter wraps some
///         fee-generating on-chain position (a PancakeSwap V3 LP NFT, a Flap
///         tax-token fee stream, protocol fees, ...) behind a canonical
///         `assetHash`, and realizes pending yield into the UGM on demand.
/// @dev Reconstructed from Takeover's `IYieldAdapter` model (see docs/SUBMIT-FLOW.md).
///      A keeper invokes `collectYield` within `ADAPTER_COLLECT_GAS_CAP` (600k gas) and the
///      adapter forwards realized yield to the UGM via `receiveYieldERC20`/`receiveYieldETH`
///      (push model). `pendingYield` is an advisory keeper hint that MUST never revert.
interface IYieldAdapter {
    /// @notice The Unified Grid Manager this adapter reports yield to.
    /// @return The UGM address.
    function ugm() external view returns (address);

    /// @notice ERC20 token this adapter distributes for `assetHash`
    ///         (address(0) denotes native BNB).
    /// @param assetHash Canonical handle of the wired asset.
    /// @return The yield token distributed for the asset.
    function yieldToken(bytes32 assetHash) external view returns (address);

    /// @notice Whether `assetHash` is currently wired to a grid via this adapter.
    /// @param assetHash Canonical handle of the asset to check.
    /// @return True if the asset is registered with the UGM through this adapter.
    function isAssetRegistered(bytes32 assetHash) external view returns (bool);

    /// @notice Realize any pending yield for `assetHash` and forward it to the UGM.
    /// @dev MUST be safe to call by anyone (permissionless keeper) and bounded in gas (<= 600k).
    ///      MUST be idempotent: a second call with no new activity forwards 0. Uses `forceApprove`
    ///      when granting the UGM its pull allowance (USDT-style tokens). Not `nonReentrant`.
    /// @param assetHash Canonical handle of the asset to harvest.
    /// @return collected Amount of `yieldToken` forwarded to the UGM this call.
    function collectYield(bytes32 assetHash) external returns (uint256 collected);

    /// @notice Best-effort estimate of the yield currently claimable for `assetHash`.
    /// @dev MUST NEVER revert: every external read is wrapped in try/catch and returns 0 on any
    ///      failure or on missing/zero state. Advisory only (a keeper hint) — the authoritative
    ///      amount is whatever `collectYield` actually forwards.
    /// @param assetHash Canonical handle of the asset to query.
    /// @return Estimated amount of `yieldToken` currently claimable for the asset.
    function pendingYield(bytes32 assetHash) external view returns (uint256);
}
