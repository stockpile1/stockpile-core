// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import { Clones } from "@openzeppelin/contracts/proxy/Clones.sol";

import { DividendVault } from "./DividendVault.sol";

/// @title VaultFactory
/// @notice Flap-style factory that deploys {DividendVault} instances as EIP-1167 minimal proxies
///         (clones) of a single deployed implementation, mirroring how each Flap tax token gets its
///         own per-token `dividendContract` clone. Each clone is initialized in the same transaction
///         it is created, so it is never left uninitialized for a third party to hijack.
/// @dev Cloning keeps per-vault deployment cost minimal (a ~45-byte proxy) while all logic lives in
///      the shared `implementation`. Vaults are indexed by `keccak256(rewardToken, owner)` for
///      lookup and appended to `allVaults` for enumeration.
contract VaultFactory {
    /// @notice The deployed {DividendVault} template every vault is cloned from.
    address public immutable implementation;

    /// @notice All vaults ever created by this factory, in creation order.
    address[] public allVaults;

    /// @notice Whether an address is a vault deployed by this factory.
    mapping(address => bool) public isVault;

    /// @notice Latest vault created for a given `(rewardToken, owner)` key (see {vaultKey}).
    mapping(bytes32 => address) public vaultOf;

    /// @notice Emitted when a new vault clone is created and initialized.
    /// @param vault The deployed clone address.
    /// @param rewardToken The reward token the vault distributes.
    /// @param owner The vault's owner (share administrator).
    /// @param key The `(rewardToken, owner)` index key.
    event VaultCreated(address indexed vault, address indexed rewardToken, address indexed owner, bytes32 key);

    /// @notice Deploy the factory bound to a {DividendVault} implementation template.
    /// @param implementation_ A deployed {DividendVault} whose logic every clone delegates to.
    constructor(address implementation_) {
        require(implementation_ != address(0), "implementation");
        implementation = implementation_;
    }

    /// @notice Deterministic index key for a `(rewardToken, owner)` pair.
    /// @param rewardToken The reward token.
    /// @param owner The vault owner.
    /// @return The key used in {vaultOf}.
    function vaultKey(address rewardToken, address owner) public pure returns (bytes32) {
        return keccak256(abi.encode(rewardToken, owner));
    }

    /// @notice Create and initialize a new {DividendVault} clone.
    /// @param rewardToken The reward ERC20 the vault distributes (e.g. the grid's quote token).
    /// @param owner The address authorized to manage the vault's shares.
    /// @return vault The newly deployed, initialized clone.
    function createVault(address rewardToken, address owner) external returns (address vault) {
        vault = Clones.clone(implementation);
        DividendVault(vault).initialize(rewardToken, owner);
        _record(vault, rewardToken, owner);
    }

    /// @notice Create a new {DividendVault} clone at a deterministic address derived from `salt`.
    /// @param salt Caller-chosen salt; the clone address is a pure function of (factory, impl, salt).
    /// @param rewardToken The reward ERC20 the vault distributes.
    /// @param owner The address authorized to manage the vault's shares.
    /// @return vault The newly deployed, initialized clone at the predicted address.
    function createVaultDeterministic(bytes32 salt, address rewardToken, address owner)
        external
        returns (address vault)
    {
        vault = Clones.cloneDeterministic(implementation, salt);
        DividendVault(vault).initialize(rewardToken, owner);
        _record(vault, rewardToken, owner);
    }

    /// @notice Predict the address {createVaultDeterministic} would deploy for `salt`.
    /// @param salt The salt to predict for.
    /// @return The counterfactual clone address.
    function predictVaultAddress(bytes32 salt) external view returns (address) {
        return Clones.predictDeterministicAddress(implementation, salt, address(this));
    }

    /// @notice Number of vaults created by this factory.
    /// @return The length of `allVaults`.
    function vaultsCount() external view returns (uint256) {
        return allVaults.length;
    }

    /// @dev Index and announce a freshly created vault.
    function _record(address vault, address rewardToken, address owner) internal {
        isVault[vault] = true;
        allVaults.push(vault);
        bytes32 key = vaultKey(rewardToken, owner);
        vaultOf[key] = vault;
        emit VaultCreated(vault, rewardToken, owner, key);
    }
}
