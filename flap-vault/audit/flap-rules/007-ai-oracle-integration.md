# Rule 007: AI Oracle Integration Safety (`IFlapAIProvider`)

## Rule

> If a vault integrates AI reasoning, it **MUST** use `IFlapAIProvider` / `FlapAIConsumerBase` safely and enforce callback authorization.

This is a **High** severity rule. Unauthorized callback execution or unsafe choice handling can be **Critical**.


## Rationale

AI decisions are off-chain-originated and delivered on-chain via callback. If callback auth, request lifecycle, or choice mapping is weak, attackers can forge outcomes, replay stale actions, or force unsafe state transitions.

---

## What to Check

### 1. Provider callback authorization

- `fulfillReasoning(uint256,uint8)` and `onFlapAIRequestRefunded(uint256)` must be callable only by the official provider.
- Preferred pattern: inherit `FlapAIConsumerBase` and keep `onlyFlapAIProvider` intact.
- Custom auth logic is allowed only if equivalent and chain-aware.

### 2. Request lifecycle correctness

- Vault must track pending AI requests and avoid processing stale/unknown `requestId`.
- Replayed or duplicate fulfillment for the same logical action must be rejected.
- Refund callback should cleanly reset pending state for retry paths.

### 3. Choice-to-action safety

- `choice` must map to deterministic, bounded actions.
- High-impact actions (fund movement, role changes, config updates) need explicit safeguards (caps, cooldowns, guardian override, or additional validation).
- AI output must not directly bypass permission checks.

### 4. Callback gas budget ⚠️

The FlapAIProvider applies a **hard 2,000,000 gas cap** to every `fulfillReasoning` and `onFlapAIRequestRefunded` callback.

- `_fulfillReasoning` and `_onFlapAIRequestRefunded` **MUST** complete within 2M gas in all execution paths.
- Unbounded loops, unbounded storage writes, or multiple heavy external calls inside callbacks are violations.
- Exceeding the cap causes the callback to revert with status `UNDELIVERED` — the result is stored but never delivered to the consumer. Recovery requires manual retry logic.
- Audit tip: estimate worst-case gas path. If it can exceed 2M gas, flag as High.

### 5. Failure handling

- If AI request is undelivered/refunded, vault should remain operable and funds-safe.
- No permanent lock due to one failed AI callback.

---

## Non-Compliant Patterns ❌

```solidity
// Missing sender auth on callback
function fulfillReasoning(uint256 requestId, uint8 choice) external {
    _executeChoice(choice);
}

// Using choice without request ownership / status checks
function _fulfillReasoning(uint256 requestId, uint8 choice) internal override {
    executeActions[choice]();
}
```

## Compliant Direction ✅

- Inherit `FlapAIConsumerBase`.
- Validate `requestId` is pending and belongs to expected flow.
- Apply bounded, reviewable action mapping for every `choice`.

---

## Severity Classification

| Scenario | Severity |
|---|---|
| Callback can be called by non-provider | **Critical** |
| Missing requestId lifecycle checks (replay/stale action risk) | **High** |
| Unsafe choice mapping for high-impact actions | **High** |
| Callback logic can exceed 2M gas → UNDELIVERED risk | **High** |
| Weak failure/retry handling causing temporary disruption | **Medium** |

