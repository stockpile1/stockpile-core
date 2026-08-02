// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { GridConfig, Seat } from "../libraries/GridTypes.sol";

/// @title IGrid
/// @notice Stable view + yield-sink surface of the Unified Grid Manager, the part
///         adapters and integrators depend on. Reconstructed from Takeover's
///         `IGrid` view interface (documented as unchanged across v2.2 -> v2.3).
interface IGrid {
    // -------------------- Views --------------------
    /// @notice Human-readable version string of the UGM implementation.
    /// @return The version identifier.
    function ugmVersion() external view returns (string memory);

    /// @notice Immutable configuration of a grid.
    /// @param gridId The grid to read.
    /// @return The grid's configuration struct.
    function gridConfig(uint256 gridId) external view returns (GridConfig memory);

    /// @notice Current Harberger state of a single seat.
    /// @param gridId The grid the seat belongs to.
    /// @param seatId The seat index within the grid.
    /// @return The seat's state struct.
    function seatInfo(uint256 gridId, uint256 seatId) external view returns (Seat memory);

    /// @notice Number of seats configured for a grid.
    /// @param gridId The grid to read.
    /// @return The grid's total seat count.
    function totalSeats(uint256 gridId) external view returns (uint256);

    /// @notice Continuous Harberger tax currently owed on a seat.
    /// @param gridId The grid the seat belongs to.
    /// @param seatId The seat index within the grid.
    /// @return Tax accrued since the seat's last settlement, in the grid's taxToken.
    function taxDue(uint256 gridId, uint256 seatId) external view returns (uint256);

    /// @notice Yield claimable by `holder` across a grid (in the grid's yieldToken).
    /// @param gridId The grid to read.
    /// @param holder The address whose claimable yield is summed.
    /// @return Total yield claimable by `holder` across the seats they hold.
    function pendingYield(uint256 gridId, address holder) external view returns (uint256);

    // -------------------- Yield sink (adapter-facing) --------------------
    /// @notice Wire an adapter-owned asset to a grid. Callable by an approved adapter.
    /// @param gridId The grid the asset's yield will be distributed to.
    /// @param assetHash Canonical handle identifying the adapter's asset.
    function registerAsset(uint256 gridId, bytes32 assetHash) external;

    /// @notice Unwire an asset from a grid. Callable by the owning adapter.
    /// @param gridId The grid the asset is currently wired to.
    /// @param assetHash Canonical handle identifying the adapter's asset.
    function withdrawAsset(uint256 gridId, bytes32 assetHash) external;

    /// @notice Deliver realized ERC20 yield for a registered asset. The adapter
    ///         must have transferred (or approved) `amount` of `token` beforehand.
    /// @param assetHash Canonical handle of the registered asset.
    /// @param token The yield token being delivered (must equal the grid's yieldToken).
    /// @param amount Amount of `token` being delivered.
    function receiveYieldERC20(bytes32 assetHash, address token, uint256 amount) external;

    /// @notice Deliver realized native-BNB yield for a registered asset.
    /// @param assetHash Canonical handle of the registered asset.
    /// @param amount Amount of native BNB being delivered.
    function receiveYieldETH(bytes32 assetHash, uint256 amount) external payable;
}
