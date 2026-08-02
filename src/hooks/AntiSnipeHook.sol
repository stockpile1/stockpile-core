// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IGridHooksV23 } from "../interfaces/IGridHooksV23.sol";
import { IHookDescriptor, HookCallbacks } from "../interfaces/IHookDescriptor.sol";

/// @title AntiSnipeHook
/// @notice Example UGM v2.3 governance module: gates initial seat claims until a
///         per-grid "open" timestamp, preventing snipers from grabbing seats at launch.
/// @dev Demonstrates the hook lifecycle. Buyouts and price changes are unrestricted;
///      only `beforeClaim` is gated. Must be approved by the guardian and wired to a
///      grid via `UGM.setGridGovernanceModule`. All callbacks stay within the 150k gas cap.
///      Also implements `IHookDescriptor` (submit-flow identity surface) — metadata only, it
///      does not touch the gating logic.
contract AntiSnipeHook is IGridHooksV23, IHookDescriptor, Ownable {
    /// @notice Stable kind tag for this hook (see IHookDescriptor.hookKind).
    bytes32 public constant HOOK_KIND = keccak256("ANTI_SNIPE");
    /// @notice Implementation version of this hook kind (see IHookDescriptor.hookVersion).
    uint16 public constant HOOK_VERSION = 1;
    /// @notice Timestamp at/after which claims are allowed for a grid (0 = always open).
    mapping(uint256 => uint64) public claimOpenAt;

    /// @notice Emitted when a grid's claim-open timestamp is set.
    /// @param gridId The grid whose gate was configured.
    /// @param openAt The timestamp at/after which claims become allowed.
    event ClaimOpenAtSet(uint256 indexed gridId, uint64 openAt);

    /// @notice Deploy the hook under the given owner (guardian).
    /// @param owner_ The owner authorized to set per-grid claim-open timestamps.
    constructor(address owner_) Ownable(owner_) { }

    /// @notice Set the timestamp at/after which seat claims open for a grid.
    /// @param gridId The grid to configure.
    /// @param openAt The unix timestamp when claims become allowed (0 = always open).
    function setClaimOpenAt(uint256 gridId, uint64 openAt) external onlyOwner {
        claimOpenAt[gridId] = openAt;
        emit ClaimOpenAtSet(gridId, openAt);
    }

    /// @inheritdoc IGridHooksV23
    /// @dev Allows the claim only once the grid's `claimOpenAt` timestamp has passed.
    function beforeClaim(uint256 gridId, uint256, address, uint256) external view returns (bool) {
        return block.timestamp >= claimOpenAt[gridId];
    }

    /// @inheritdoc IGridHooksV23
    /// @dev Buyouts are never gated by this hook.
    function beforeBuyout(uint256, uint256, address, address, uint256) external pure returns (bool) {
        return true;
    }

    /// @inheritdoc IGridHooksV23
    /// @dev Price changes are never gated by this hook.
    function beforePriceChange(uint256, uint256, address, uint256, uint256) external pure returns (bool) {
        return true;
    }

    /// @inheritdoc IGridHooksV23
    /// @dev No-op observer.
    function onSeatHolderChange(uint256, uint256, address, address) external { }

    /// @inheritdoc IGridHooksV23
    /// @dev No-op observer.
    function onForfeit(uint256, uint256, address) external { }

    // --------------------------------------------------------------------- //
    //                    IHookDescriptor (submit identity)                  //
    // --------------------------------------------------------------------- //
    /// @inheritdoc IHookDescriptor
    function hookKind() external pure returns (bytes32) {
        return HOOK_KIND;
    }

    /// @inheritdoc IHookDescriptor
    function hookVersion() external pure returns (uint16) {
        return HOOK_VERSION;
    }

    /// @inheritdoc IHookDescriptor
    /// @dev Only `beforeClaim` gates; buyouts, price changes and the observers are pass-through.
    function supportedCallbacks() external pure returns (uint256) {
        return HookCallbacks.BEFORE_CLAIM;
    }

    /// @inheritdoc IHookDescriptor
    function description() external pure returns (string memory) {
        return "Gates initial seat claims until a per-grid open timestamp (anti-snipe).";
    }
}
