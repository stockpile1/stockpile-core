# Rule 005: `receive()` Gas Limit — At Most 1,000,000 Gas

## Rule

> The `receive()` function **MUST** consume at most **1,000,000 gas** across all possible execution paths.

This is a **Critical** rule. Violations must be reported as a Critical finding.

---

## Rationale

The Flap Portal forwards BNB tax revenue to a vault by calling it with a plain BNB transfer (`call{value: ...}("")`). This invokes the vault's `receive()` fallback on every tax event.

If `receive()` is excessively expensive or can revert, the Portal transaction fails and **tax collection is permanently broken** for that token. Depending on the vault's design, this can also lock all accumulated BNB inside the vault with no recovery path.

The 1,000,000-gas cap is generous — a compliant implementation should typically use far less (< 100,000 gas).

---

## What to Check

### 1. Static analysis (always required)

Scan the `receive()` body for any of the following patterns; each is an automatic **violation**:

| Pattern | Finding |
|---|---|
| Unbounded loop (`for`, `while`) over dynamic array | Critical |
| External call inside `receive()` (e.g., another contract call, token transfer) | Critical unless trivially bounded |
| Delegatecall inside `receive()` | Critical |
| Any operation whose gas cost is proportional to unbounded storage | Critical |

### 2. Gas estimation (if body is non-trivial)

If the `receive()` body is non-trivial (beyond a simple accumulator + optional event), estimate its worst-case gas cost. Report the estimated upper bound in the finding.

### 3. Test verification (if test suite is present)

If a Foundry test suite exists, add or verify the presence of a gas-limiting test:

```solidity
function testReceiveGasUnder1M() public {
    vm.deal(address(this), 1 ether);
    uint256 gasBefore = gasleft();
    (bool ok,) = address(vault).call{value: 1 ether}("");
    uint256 gasUsed = gasBefore - gasleft();
    assertTrue(ok, "receive() should not revert");
    assertLe(gasUsed, 1_000_000, "receive() exceeds 1M gas limit");
}
```

---

## Compliant Patterns ✅

```solidity
// Minimal — always compliant
receive() external payable {}

// Simple accumulator — compliant
receive() external payable {
    totalReceived += msg.value;
}

// Accumulator + event — compliant
receive() external payable {
    totalReceived += msg.value;
    emit Received(msg.sender, msg.value);
}

// Per-epoch accumulator (bounded SSTORE) — compliant
receive() external payable {
    epochs[currentEpoch].accumulated += msg.value;
}

// Commission split with a small fixed number of recipients — compliant if
// recipients array is fixed and small (e.g., max 5 entries set at construction)
receive() external payable {
    uint256 fee = (msg.value * feeBps) / 10_000;
    feeAccumulator += fee;
    mainAccumulator += msg.value - fee;
}
```

---

## Non-Compliant Patterns ❌

```solidity
// Unbounded loop inside receive() — Critical violation
receive() external payable {
    for (uint256 i = 0; i < recipients.length; i++) {
        recipients[i].addr.call{value: msg.value * recipients[i].bps / 10_000}("");
    }
}


// Chained external call — Critical violation
receive() external payable {
    IVaultStrategy(strategy).onRevenue{value: msg.value}();
}
```

---

## Remediation

Move heavy logic out of `receive()` into a dedicated processing function:

```solidity
// ✅ Accumulate in receive() — cheap
receive() external payable {
    pendingRevenue += msg.value;
}

// ✅ Heavy logic runs only when explicitly triggered (by keeper / guardian / public)
function processRevenue() external {
    uint256 amount = pendingRevenue;
    pendingRevenue = 0;
    // ... swap, distribute, buyback, etc.
}
```

---

## Severity Classification

| Scenario | Severity |
|---|---|
| Unbounded loop or external call in `receive()` — can cause permanent DoS | **Critical** |
| Bounded complex logic that may exceed 1M gas under adversarial conditions | **High** |
| Complex logic that is within 1M gas but unnecessarily expensive (> 100K) | **Medium** |
| `receive()` missing entirely (vault cannot receive BNB) | **Critical** |

