// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IWBNB
/// @notice Wrapped BNB — BNB-native equivalent of Base's flETH.
interface IWBNB is IERC20 {
    /// @notice Wrap the native BNB sent with the call into an equal amount of WBNB
    ///         credited to the caller.
    function deposit() external payable;

    /// @notice Unwrap WBNB back into native BNB paid to the caller.
    /// @param amount Amount of WBNB to burn and redeem for native BNB, in wei.
    function withdraw(uint256 amount) external;
}
