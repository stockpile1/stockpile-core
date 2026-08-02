// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Test ERC20 that withholds (burns) a fixed basis-point fee on every transfer, so the
///         recipient nets strictly less than the nominal amount. Models a Flap-style tax token /
///         fee-on-transfer yield token used to exercise AUDIT-1 F-01. Mints and burns pass
///         through untaxed so balances stay easy to reason about in tests.
contract FeeOnTransferERC20 is ERC20 {
    uint256 public immutable feeBps; // fee withheld and burned per transfer, in basis points
    uint256 internal constant BPS = 10_000;

    constructor(string memory n, string memory s, uint256 feeBps_) ERC20(n, s) {
        require(feeBps_ < BPS, "feeBps");
        feeBps = feeBps_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /// @dev On a normal transfer, burn `feeBps` of `value` from the sender so the recipient
    ///      receives `value - fee`. Mint (from == 0) and burn (to == 0) are untaxed.
    function _update(address from, address to, uint256 value) internal override {
        if (from == address(0) || to == address(0) || feeBps == 0) {
            super._update(from, to, value);
            return;
        }
        uint256 fee = (value * feeBps) / BPS;
        if (fee > 0) {
            super._update(from, address(0), fee); // burn the withheld fee
        }
        super._update(from, to, value - fee);
    }
}
