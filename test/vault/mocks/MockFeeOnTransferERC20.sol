// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";

/// @title MockFeeOnTransferERC20
/// @notice A fee-on-transfer ERC-20: every `transfer`/`transferFrom` skims a fixed `feeBps` of the
///         moved amount into a burn sink, so the recipient credits LESS than the sender sends. Used to
///         prove MultiStockVault's FoT-robust push (audit F5): after the swap the vault must forward the
///         ACTUAL balance delta it received, not the router's nominal output — otherwise the UGM
///         `transferFrom(vault, ugm, out)` would over-pull and revert.
/// @dev    `_mint` is intentionally fee-free (the mock V3 router mints its own swap proceeds), matching
///         a real pool that charges the fee only on the delivery transfer, not on inventory it holds.
///         Extends OpenZeppelin's ERC20 so `SafeERC20.forceApprove` and `transferFrom` behave for real.
contract MockFeeOnTransferERC20 is ERC20 {
    uint8 private immutable _decimals;

    /// @notice Fee skimmed on each transfer, in basis points (e.g. 500 == 5%). Immutable per token.
    uint16 public immutable feeBps;

    /// @notice Burn-hole the skimmed fee is routed to (non-zero so OZ's transfer-to-zero guard is happy).
    address public constant FEE_SINK = address(0xdEaD);

    constructor(string memory name_, string memory symbol_, uint8 decimals_, uint16 feeBps_) ERC20(name_, symbol_) {
        require(feeBps_ < 10_000, "fee too high");
        _decimals = decimals_;
        feeBps = feeBps_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Test/mock helper: fee-free mint of `amount` to `to` (no access control).
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @dev Skim `feeBps` of every transfer into {FEE_SINK}; the recipient receives the remainder.
    function _transfer(address from, address to, uint256 amount) internal override {
        uint256 fee = (amount * feeBps) / 10_000;
        if (fee > 0) {
            super._transfer(from, FEE_SINK, fee);
        }
        super._transfer(from, to, amount - fee);
    }
}
