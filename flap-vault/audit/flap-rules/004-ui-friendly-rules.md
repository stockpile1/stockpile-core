# UI Friendly Rules

## UI-01: Use Literal Error Strings, Not Custom Errors

Do **not** use custom errors. All reverts must use `require()` with a literal string message.

The UI renderer cannot decode custom error selectors without ABI parsing — only literal strings are shown as-is.

```solidity
// ❌
error FeeTooHigh();
if (fee > MAX_FEE) revert FeeTooHigh();

// ✅
require(fee <= MAX_FEE, "Fee too high");
```

---

## UI-02: Embed All Supported Languages Inline

If the contract supports multiple languages, every user-facing string must include all languages explicitly, separated by ` / `.

The UI has no translation layer — it displays strings exactly as encoded. Use the `unicode` prefix for non-ASCII characters.

```solidity
// ❌
require(amount > 0, "Amount must be > 0");

// ✅
require(amount > 0, unicode"Amount must be > 0 / 金额必须大于0");
```
