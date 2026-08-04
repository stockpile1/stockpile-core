// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @title MockTaxToken
/// @notice Minimal Flap tax token exposing a configurable `taxRate()` in basis
///         points, which the vault probes (best-effort) at init and lazily on
///         the first non-empty `receive()`.
contract MockTaxToken {
    uint16 public taxRate;

    constructor(uint16 _taxRate) {
        taxRate = _taxRate;
    }

    function setTaxRate(uint16 _taxRate) external {
        taxRate = _taxRate;
    }
}
