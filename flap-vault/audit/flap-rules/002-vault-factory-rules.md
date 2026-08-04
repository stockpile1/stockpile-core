## Vault Factory Specification


Every new factory **must** inherit from `VaultFactoryBaseV2` (`prelude/VaultFactoryBaseV2.sol`).  

- If the factory or any vault it creates exposes privileged / role-gated functions, the Guardian address returned by `_getGuardian()` **must** be granted every required role at construction time or before any permissioned operation is callable. 
- The Guardian's role **must not** be revocable by any account other than the Guardian itself.  Factories using OpenZeppelin `AccessControl` **must** override `revokeRole()` to revert when the target `account` equals `_getGuardian()`. Failure to do so is a **critical finding**.
