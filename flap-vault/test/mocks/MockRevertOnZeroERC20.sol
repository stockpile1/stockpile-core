// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";

/// @title MockRevertOnZeroERC20
/// @notice An ERC-20 that REVERTS on any zero-value `transfer` / `transferFrom`, mirroring real BEP-20s
///         that reject zero-amount moves. Used to prove {StockBasket.deposit}'s zero-amount pull guard
///         (audit S2): a best-effort-skipped leg (`amounts[i] == 0`) must NOT call `transferFrom`, else a
///         single unhealthy pool would brick the whole deposit — and thus the vault's `distribute`.
/// @dev    `mint` is intentionally unrestricted so tests / the mock router can conjure balances.
contract MockRevertOnZeroERC20 is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(amount > 0, "zero transfer");
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        require(amount > 0, "zero transferFrom");
        return super.transferFrom(from, to, amount);
    }
}
