// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";

/// @title MockPausableStock
/// @notice An ERC-20 whose `transfer` reverts while `paused` (mirroring a globally-paused or
///         blacklisting stock), but whose `transferFrom` keeps working. Used to prove
///         {StockBasket.redeem}'s best-effort per-stock payout (audit S3): a paused stock's payout is
///         SKIPPED (its slice stays in the basket, benefiting the remaining holders) while the other
///         stocks are delivered. `transferFrom` still works so the vault/test can DEPOSIT it before pausing.
/// @dev    `mint` is intentionally unrestricted so tests can pre-fund the depositor.
contract MockPausableStock is ERC20 {
    uint8 private immutable _decimals;

    /// @notice When true, `transfer` reverts (redeem payout path). `transferFrom` is unaffected.
    bool public paused;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setPaused(bool p) external {
        paused = p;
    }

    /// @dev The redeem payout uses `transfer`; pausing it makes that stock's leg revert (then be skipped).
    function transfer(address to, uint256 amount) public override returns (bool) {
        require(!paused, "paused");
        return super.transfer(to, amount);
    }
}
