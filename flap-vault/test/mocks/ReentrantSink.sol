// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

/// @notice Minimal handle to re-enter the vault under test.
interface IReentered {
    function flush() external returns (uint256);
}

/// @title ReentrantSink
/// @notice Malicious stand-in for the Stockpile grid sink (UGM) used to prove
///         {StockpileVault.flush} is protected by `nonReentrant`. On the yield
///         push it attempts to re-enter `flush()` on the calling vault; the
///         re-entrant call MUST revert (OZ ReentrancyGuard) and is caught here so
///         the test can assert the guard fired without aborting the outer call.
/// @dev    Like the real UGM / {MockGridSink}, it pulls the yield in via
///         `transferFrom` and reverts on a zero amount — so the outer `flush()`
///         still performs a real, complete forward while the inner re-entry is
///         rejected.
contract ReentrantSink {
    /// @notice The vault to re-enter (set by the test before `flush()`).
    address public vault;
    /// @notice True once a re-entrant `flush()` was attempted AND reverted.
    bool public reentrancyBlocked;
    /// @notice True if a re-entrant `flush()` ever unexpectedly succeeded.
    bool public reentrancySucceeded;
    /// @notice Records of the (single) legitimate outer forward.
    uint256 public lastAmount;
    uint256 public callCount;

    function setVault(address v) external {
        vault = v;
    }

    function receiveYieldERC20(bytes32, /*assetHash*/ address token, uint256 amount) external {
        require(amount > 0, "ReentrantSink: zero amount");

        // Attempt the re-entrant call BEFORE pulling funds — this is the window a
        // real attacker would exploit. `nonReentrant` must make it revert.
        try IReentered(vault).flush() returns (uint256) {
            reentrancySucceeded = true; // guard FAILED — should never happen
        } catch {
            reentrancyBlocked = true; // guard fired as required
        }

        // Complete the legitimate forward (the vault approved us for `amount`).
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        lastAmount = amount;
        callCount += 1;
    }
}
