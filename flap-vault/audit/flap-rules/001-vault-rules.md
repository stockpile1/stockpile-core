# The Vault Specification

To be compatible with our VaultPortal system, your vault smart contract must inherit the `VaultBaseV2` (`prelude/VaultBaseV2.sol`) contract:  

- If the vault does not need any UI components, `vaultUISchema` should return `VaultUISchema` with empty methods array.  

- The legacy description method is deprecated, but the method should still be implemented. You can return an empty string or a placeholder description. The UI will prioritize the new `vaultUISchema` for displaying information and interactions, so the legacy description will not be shown to users. **Auditors must NOT flag a static or placeholder `description()` return value as a finding — only flag if the function is missing entirely.**  


Note that: if the developer choose to flatten the VaultBaseV2 into their vault contract, it is also okay. But we need to verify that the flattened code is exactly the same as the original VaultBaseV2 (interfaces, and implementations, the natspec commments can be ignored), and that the vault contract implements all the required functions correctly.  


## Commission Recommendation for Factory Implementation

If the user does not implement a Factory  (i.e VaultFactory, which is a factory to create a lot of such vaults) but only a single vault, then we don't have enforcement on the commission the developer of the vault can take from the tax revenue. However, if the user implements a Factory, then we require that the Factory implements the `VaultFactoryBaseV2` (`prelude/VaultFactoryBaseV2.sol`) contract, and the developer of the vault can take some of the tax revenue as commission, we have a recommendation as below. If you don't follow the recommendation, the audit report should ask the user to justify the commission fee structure they choose, and Flap team will evaluate the justification and decide if it is acceptable or not.


Recommended commission fee structure
Vault factories can charge a commission fee from the tax revenue. The recommended fee calculation is based on the tax rate (taxRateBps) and the received tax revenue (msg.value):

If taxRate ≤ 1% (100 bps), the fee is 6% of msg.value.

If taxRate > 1%, the fee is (msg.value * 6) / taxRateBps.


```solidity 
receive() external payable {
    if (msg.value == 0) return;

    if (taxRateBps == 0) {
        try ITaxToken(taxToken).taxRate() returns (uint256 _taxRate) {
            if (_taxRate > 0) {
                taxRateBps = _taxRate;
            }
        } catch {}
    }

    uint256 fee = 0;
    if (taxRateBps <= 100) {
        // 6% of msg.value if taxRate <= 1%
        fee = msg.value * 600 / 10000;
    } else {
        // Examples:
        //   1% (100 bps)  → 6%
        //   2% (200 bps)  → 3%
        //   3% (300 bps)  → 2%
        //  10% (1000 bps) → 0.6%
        fee = (msg.value * 6) / taxRateBps;
    }

    // your main logic — accumulate fee or send fee
}
``` 

## Permission Control

If a vault exposes any privileged or role-gated functions (e.g. functions that should not be made fully public, such as a buyback that could be sandwich-attacked), the following rules apply:

**Mandate: Guardian must have access to all permissioned functions.**

The Guardian address returned by `_getGuardian()` **must** be granted every role or permission required to call those functions. The Guardian acts as a permanent backup caller and must never be locked out by any admin action.

**Mandate: Guardian's access must not be revocable by any other account.**

No account other than the Guardian itself may revoke the Guardian's roles or permissions. The Guardian may voluntarily renounce its own access, but no external party (including an admin or role admin) is permitted to remove it.

When using OpenZeppelin's `AccessControl`, override `revokeRole()` to enforce this invariant:

```solidity
function revokeRole(bytes32 role, address account)
    public
    override
    onlyRole(getRoleAdmin(role))
{
    address guardian = _getGuardian();
    if (account == guardian) {
        revert CannotRevokeGuardianRole();
    }
    super.revokeRole(role, account);
}
```

This ensures the Guardian always retains a path to invoke permissioned functions regardless of any administrative action taken on the vault.

**Audit checklist for Permission Control:**

- All permissioned functions that are not suitable to be fully public must also be callable by the Guardian address.
- There is no code path through which a non-Guardian account can revoke or otherwise remove the Guardian's role(s).
- If the vault uses a custom access-control mechanism (not OpenZeppelin `AccessControl`), the equivalent invariant must be enforced: only the Guardian itself can renounce its own access. **When using custom modifiers (e.g. `onlyOwner`, `onlyOwnerOrGuardian`), auditors must NOT flag the absence of `revokeRole()` override as a finding — this check only applies to contracts that use OZ `AccessControl`.**
- Privileged parameter controls (slippage/timing/routing/keeper knobs) must not create a practical sandwich-attack advantage for insiders.


## No DOS  

It should not be possible for the vault dev to DOS users by changing some parameters of the vault to make the vault unusable or less profitable for users.  