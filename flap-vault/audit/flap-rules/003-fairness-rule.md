# Rule 003: Fairness Rule

The vault mechanism must be fair to users. Any privileged path that lets insiders extract value at users' expense is non-compliant.

## Explicit sandwich-risk requirement

Sandwich attack exposure must be treated as a first-class fairness risk.

- If a privileged role can change slippage, timing windows, routing, or execution triggers in a way that increases sandwichability, flag it.
- If the same role (or a colluding role) can then trade around user flow, this is a **High/Critical** fairness failure.
- If user-facing functions are intentionally left permissionless, the design still must not let privileged actors pre-condition state to reliably sandwich users.

## Non-compliant fairness patterns

1. Privileged parameter changes that systematically increase dev profit while reducing user outcomes.
2. Multi-step privileged exploits, including: adjust parameters -> create sandwich-prone conditions -> execute sandwich for insider gain.
3. Game-like vault mechanics where privileged controls make bots/insiders materially more likely to win than normal users.
4. Extreme Matthew-effect designs where insiders retain persistent structural advantage that normal users cannot realistically overcome.

## Scope of "dev"

"Dev" means any account or role with privileged capability, not only `owner`.

Audit all privileged roles (owner, admin, operator, keeper, strategy role, etc.) and verify none can exploit users through unfair parameter or execution control.
