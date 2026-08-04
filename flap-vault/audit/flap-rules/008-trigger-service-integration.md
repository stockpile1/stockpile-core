# Rule 008: Trigger Service Integration Safety (`IFlapTriggerService`)

## Rule

> If a vault uses delayed or automated execution, it **MUST** integrate `IFlapTriggerService` and `ITriggerReceiver` with strict callback authorization and delay-aware logic.

This is a **High** severity rule. Unauthorized trigger callbacks or unsafe trigger execution are **Critical**.

---

## Rationale

Trigger execution is asynchronous and may be delayed. Integrations that assume exact timing or fail to validate caller/request state can be exploited for griefing, replay, or unsafe fund movement.

---

## What to Check

### 1. Callback sender validation (mandatory)

`trigger(uint256 requestId)` in receiver contracts must verify `msg.sender` is the official Flap Trigger Service address.

### 2. Request state tracking

- Vault should bind each `requestId` to an intended action.
- Trigger callback must reject unknown, completed, or canceled requests.
- Callback should delete or mark consumed requests to prevent replay.

### 3. Delay-aware execution

- Do not assume callback happens exactly at `executeAfter`.
- If timing-sensitive (price windows, slippage bounds), re-check conditions at execution time.
- If conditions are stale, fail safely instead of forcing a dangerous action.

### 4. Callback gas budget ⚠️

The FlapTriggerService applies a **hard 2,000,000 gas cap** to every `trigger(uint256 requestId)` callback (via `getMaxCallbackGas()`).

- The `trigger()` callback **MUST** complete within 2M gas in all execution paths.
- Unbounded loops, unbounded storage writes, or multiple heavy external calls are violations.
- Exceeding the cap causes the callback to be recorded as `FAILED`. Anyone can retry via `retryTrigger()` with no gas cap, but relying on this as a normal path is unsafe design.
- Audit tip: estimate worst-case gas path. If it can exceed 2M gas, flag as High.

### 5. Reentrancy and bounded effects

- If callback performs external calls, add reentrancy protection.
- Keep callback logic bounded and deterministic under service gas limits.

---

## Non-Compliant Patterns ❌

```solidity
// No sender validation
function trigger(uint256 requestId) external override {
	_executePendingAction(requestId);
}

// Timing assumption without revalidation
function _executePendingAction(uint256 requestId) internal {
	// assumes price from scheduling time is still valid
	swapExact(...);
}
```

## Compliant Direction ✅

- Validate trigger service sender before any state change.
- Re-validate timing and market-sensitive constraints at callback time.
- Consume request state atomically once executed.

---

## Severity Classification

| Scenario | Severity |
|---|---|
| `trigger()` callback can be called by arbitrary address | **Critical** |
| Missing request replay protection | **High** |
| Unsafe timing assumptions in delayed execution | **High** |
| Callback logic can exceed 2M gas → FAILED status risk | **High** |
| Missing reentrancy or defensive checks on low-risk path | **Medium** |

