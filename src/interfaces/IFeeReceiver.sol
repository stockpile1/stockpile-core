// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IFeeReceiver
/// @notice Sink for protocol fee/tax revenue routed out of the UGM (e.g. toward
///         the buyback keeper). Reconstructed from Takeover's `IFeeReceiver`.
interface IFeeReceiver {
    /// @notice Called when `amount` of `token` has been transferred to this receiver.
    /// @param token The ERC20 fee token that was transferred in.
    /// @param amount Amount of `token` delivered to this receiver.
    function receiveFees(address token, uint256 amount) external;
}
