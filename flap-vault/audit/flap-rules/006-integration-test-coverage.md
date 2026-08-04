# Rule 006: Integration Tests Must Cover Main Vault Functionality

## Rule

> The submitted vault (and factory, if included) **MUST** include a Foundry test suite with integration tests that exercise all critical user-facing flows.

This is a **High** severity rule. Missing integration tests for critical flows are **High** findings. Missing tests for secondary flows are **Low/Medium** findings depending on risk.

---

## Rationale

Vault contracts handle user funds and execute in adversarial environments. Unit tests that mock dependencies cannot catch:

- BNB transfer failures in `receive()`
- Gas issues in the hot path
- State corruption across function call sequences
- Access control gaps exploitable via unexpected callers
- Inconsistencies between the declared `vaultUISchema` and the actual ABI

Integration tests run against a fully deployed contract (using Foundry's `forge-std/Test.sol`) and catch the above classes of bugs.

---

## What to Check

### 1. Test file presence

Verify that a `test/` directory exists and contains at least one `.t.sol` file using `forge-std/Test.sol`.

```bash
find test/ -name "*.t.sol" | sort
```

If no test files exist → **High** finding for missing critical-flow coverage (including `receive()` and privileged/value-moving writes).

### 2. Critical-flow coverage

You do **not** need strict 1:1 tests for every `public` or `external` function. Instead, require coverage for the highest-risk flows first, then add selective tests for secondary functions.

Use this checklist:

| Function / path | Minimum required tests |
|---|---|
| `receive()` gas budget | Uses ≤ 1,000,000 gas (see Rule 005) |
| Critical write methods (fund movement, reward distribution, parameter updates, role updates) | (a) Happy-path: call succeeds, correct state delta; (b) Revert-path: call reverts with expected message when precondition fails |
| Key view methods used by UI / integrations | At least one test that calls it and asserts a correct return value |
| `description()` | Returns a non-empty string; ideally returns different values before and after a state change |
| `vaultUISchema()` | Returns a schema with the correct `methods.length` and correct `isWriteMethod` flags |
| `vaultDataSchema()` (factory) | Returns a schema whose `fields` match the expected `newVault()` `vaultData` ABI |
| `newVault()` (factory) | (a) Succeeds when called from VaultPortal; (b) Reverts when called from non-portal address |
| Guardian access | Guardian can call every privileged function |
| Role revocation guard | No account other than Guardian can revoke Guardian's role |

### 3. Test quality

- Tests must use `assertEq`, `assertTrue`, `vm.expectRevert`, `vm.prank`, or equivalent assertions — not just call functions silently.
- Tests must compile and pass: `forge test` exits with code 0.

### 4. Reference integration tests

When assessing whether coverage quality is "good enough", use these as reference-quality examples:

- [FlapVaultExample / test/FreeCoin.mainnet.t.sol](https://github.com/flap-sh/FlapVaultExample/blob/main/test/FreeCoin.mainnet.t.sol)
- [FlapVaultExample / test/FlapBSCFixture.sol](https://github.com/flap-sh/FlapVaultExample/blob/main/test/FlapBSCFixture.sol)

---

## Minimum Required Test Structure

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import "../src/YourVault.sol";
import {VaultUISchema} from "../src/flap/IVaultSchemasV1.sol";

contract YourVaultIntegrationTest is Test {

    YourVault vault;

    function setUp() public {
        // Deploy with test parameters; fund vault if needed
        vault = new YourVault(...);
        vm.deal(address(vault), 1 ether);
    }

    // ── receive() ────────────────────────────────────────────────────────

    function testReceiveGasUnder1M() public {
        vm.deal(address(this), 1 ether);
        uint256 gasBefore = gasleft();
        (bool ok,) = address(vault).call{value: 1 ether}("");
        uint256 gasUsed = gasBefore - gasleft();
        assertTrue(ok);
        assertLe(gasUsed, 1_000_000, "receive() exceeds 1M gas limit");
    }

    // ── write method(s) ───────────────────────────────────────────────────
    function testMainAction_HappyPath() public {
        // arrange → act → assert
    }

    function testMainAction_RevertWhenConditionNotMet() public {
        vm.expectRevert(...);
        vault.mainAction();
    }

    // ── view method(s) ────────────────────────────────────────────────────
    function testViewMethod_CorrectInitialValue() public {
        assertEq(vault.viewMethod(), expectedValue);
    }

    // ── description() ────────────────────────────────────────────────────
    function testDescriptionIsNonEmpty() public {
        assertTrue(bytes(vault.description()).length > 0);
    }

    // ── vaultUISchema() ───────────────────────────────────────────────────
    function testUISchemaMethodCount() public {
        VaultUISchema memory schema = vault.vaultUISchema();
        assertEq(schema.methods.length, EXPECTED_COUNT);
    }

    // ── guardian ─────────────────────────────────────────────────────────
    function testGuardianCanCallPrivilegedFunction() public {
        vm.prank(GUARDIAN_ADDRESS);
        vault.privilegedFunction(); // must not revert
    }

    function testCannotRevokeGuardianRole() public {
        vm.expectRevert();
        vault.revokeRole(SOME_ROLE, GUARDIAN_ADDRESS);
    }
}
```

---

## Running Tests

```bash
# Run all tests
forge test -vv

# Show gas per test
forge test --gas-report

# Coverage report
forge coverage
```

All tests must pass (`forge test` exits code 0).

---

## Severity Classification

| Missing test coverage | Severity |
|---|---|
| No test suite at all | **High** |
| `receive()` gas not tested | **High** |
| Critical write methods have no happy-path test | **High** |
| Critical write methods have no revert-path test | **Medium** |
| Key view methods not tested | **Low/Medium** |
| `description()` not tested | **Low** |
| `vaultUISchema()` / `vaultDataSchema()` not tested | **Low/Medium** |
| Guardian access not tested | **High** |
| Role-revocation guard not tested | **Medium** |

