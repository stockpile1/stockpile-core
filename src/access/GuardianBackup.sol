// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title GuardianBackup
/// @notice Grants the chain-fixed Flap Guardian a permanent BACKUP authority alongside each
///         contract's local owner (SYS-REQ-GUARDIAN-ACCESS). If the local owner key is ever lost or
///         compromised, the Guardian can still exercise every privileged function — manage shares,
///         flush dividends, unwire LP positions / fee streams, reconfigure the buyback receiver, or
///         rescue stuck tokens — so no operator key is a single point of failure.
/// @dev Additive and non-revocable: the local owner keeps full access, and the Guardian is a
///      bytecode constant (mirrors how `UnifiedGridManager` keeps `guardian() == owner()`). Mixin
///      only — it declares NO storage and NO constructor, so it composes cleanly with `Ownable`
///      (and is safe even under minimal-proxy clones, whose storage starts zero-initialized). A
///      concrete contract implements {_accessOwner} to surface its own owner (a state variable, or
///      `Ownable.owner()`).
abstract contract GuardianBackup {
    /// @notice Flap protocol Guardian — the chain-fixed permanent backup caller (the value the Flap
    ///         spec's `_getGuardian()` resolves to on BSC). Never changes; cannot be revoked.
    address internal constant FLAP_GUARDIAN = 0x9e27098dcD8844bcc6287a557E0b4D09C86B8a4b;

    /// @notice The permanent Guardian backup authority, exposed for parity with `UGM.guardian()`.
    /// @return The chain-fixed Flap Guardian address.
    function guardian() external pure returns (address) {
        return FLAP_GUARDIAN;
    }

    /// @dev The contract's local owner (a state variable or `Ownable.owner()`), supplied by the
    ///      concrete contract so {onlyOwnerOrGuardian} can check it.
    function _accessOwner() internal view virtual returns (address);

    /// @notice Restrict a call to the local owner OR the chain-fixed Flap Guardian.
    modifier onlyOwnerOrGuardian() {
        require(msg.sender == _accessOwner() || msg.sender == FLAP_GUARDIAN, "not owner/guardian");
        _;
    }
}
