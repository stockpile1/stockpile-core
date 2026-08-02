// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { ERC20Votes } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import { Nonces } from "@openzeppelin/contracts/utils/Nonces.sol";

/// @title TakeoverToken (TAKEOVER)
/// @notice Fixed-supply governance token for the BNB port — the buyback sink.
///         Mirrors the Base TAKEOVER token (an ERC20Votes "Memecoin"). Full supply
///         is minted once at deployment; there is no further minting.
contract TakeoverToken is ERC20, ERC20Permit, ERC20Votes {
    /// @notice Deploy TAKEOVER and mint the entire fixed supply to `recipient`.
    /// @param recipient The address that receives the full initial supply.
    /// @param supply The total token supply to mint (no further minting is possible).
    constructor(address recipient, uint256 supply)
        ERC20("Takeover", "TAKEOVER")
        ERC20Permit("Takeover")
    {
        _mint(recipient, supply);
    }

    // ----- Required multiple-inheritance overrides (OZ v5) -----
    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    /// @notice Current permit nonce for `owner`.
    /// @param owner The account whose nonce is returned.
    /// @return The next unused permit nonce for `owner`.
    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
