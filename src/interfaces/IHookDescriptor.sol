// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title HookCallbacks
/// @notice Canonical bit positions for the `IHookDescriptor.supportedCallbacks()` bitmask.
/// @dev One bit per `IGridHooksV23` callback. A hook sets the bit for every callback it
///      meaningfully acts on (gates or observes); unset bits advertise a pass-through/no-op
///      so integrators and the guardian can reason about a module without reading its code.
library HookCallbacks {
    /// @notice `beforeClaim` — gates initial seat claims / acquisitions.
    uint256 internal constant BEFORE_CLAIM = 1 << 0;
    /// @notice `beforeBuyout` — gates seat buyouts.
    uint256 internal constant BEFORE_BUYOUT = 1 << 1;
    /// @notice `beforePriceChange` — gates self-assessed price changes.
    uint256 internal constant BEFORE_PRICE_CHANGE = 1 << 2;
    /// @notice `onSeatHolderChange` — observes seat holder changes (non-vetoing).
    uint256 internal constant ON_SEAT_HOLDER_CHANGE = 1 << 3;
    /// @notice `onForfeit` — observes tax-driven forfeitures (non-vetoing).
    uint256 internal constant ON_FORFEIT = 1 << 4;
}

/// @title IHookDescriptor
/// @notice Self-describing metadata a governance hook module exposes so the guardian, the
///         submit checklist tooling, and grid creators can identify what a module is and which
///         callbacks it acts on WITHOUT reading its bytecode.
/// @dev Part of the Takeover submit surface for hook modules (see docs/SUBMIT-FLOW.md): a
///      submitted module implements `IGridHooksV23` (the behaviour) PLUS `IHookDescriptor` (the
///      identity). All four getters are pure/view and MUST NOT revert.
interface IHookDescriptor {
    /// @notice Stable identifier for the KIND of hook (not the instance), e.g.
    ///         `keccak256("ANTI_SNIPE")`. Lets tooling group and recognise modules across deploys.
    /// @return A domain-separated kind tag.
    function hookKind() external view returns (bytes32);

    /// @notice Monotonic version of this hook kind's implementation (starts at 1).
    /// @return The implementation version.
    function hookVersion() external view returns (uint16);

    /// @notice Bitmask of the `IGridHooksV23` callbacks this module meaningfully acts on.
    /// @dev Built from `HookCallbacks` bit constants; a set bit means the module gates/observes
    ///      that callback, an unset bit means it is a pass-through/no-op.
    /// @return The supported-callbacks bitmask.
    function supportedCallbacks() external view returns (uint256);

    /// @notice Short human-readable, one-line description of what the module does.
    /// @return The description string.
    function description() external view returns (string memory);
}
