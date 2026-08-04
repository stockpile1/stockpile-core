// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";

/// @title MockMintableERC20
/// @notice Minimal, fully SafeERC20-compatible ERC-20 used by the MultiStockVault
///         unit tests as both the 7 "stock" tokens and the shared USDT hop. Extends
///         OpenZeppelin's ERC20 (reverting, bool-returning) so the vault's
///         `SafeERC20.forceApprove` and the UGM/router `transferFrom` calls behave
///         exactly as against a real token. `mint` is intentionally unrestricted so
///         the mock V3 router can conjure swap proceeds without pre-funding.
contract MockMintableERC20 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Test/mock helper: mint `amount` of this token to `to` (no access control).
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
