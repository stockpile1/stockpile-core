// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

/// @title MockGridSink
/// @notice Stand-in for the Stockpile UnifiedGridManager (grid sink). On
///         `receiveYieldERC20` it pulls `amount` of `token` from the caller
///         (the vault, which must have approved this contract) and records the
///         `(assetHash, token, amount)` tuple so tests can assert the forward.
/// @dev    Mirrors the real UGM by reverting on a zero amount; the vault's
///         `flush()` is expected to guard against ever calling with zero.
contract MockGridSink {
    bytes32 public lastAssetHash;
    address public lastToken;
    uint256 public lastAmount;
    uint256 public totalReceived;
    uint256 public callCount;

    function receiveYieldERC20(bytes32 assetHash, address token, uint256 amount) external {
        require(amount > 0, "MockGridSink: zero amount");

        // Pull the yield in — the vault must have approved us for `amount`.
        IERC20(token).transferFrom(msg.sender, address(this), amount);

        lastAssetHash = assetHash;
        lastToken = token;
        lastAmount = amount;
        totalReceived += amount;
        callCount += 1;
    }
}
