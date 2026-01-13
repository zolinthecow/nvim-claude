# Agent guidelines

This guide defines how to work in this repo. Detailed behavior and examples live in colocated doctest docs.

## Source of truth

- Read the colocated docs first; treat doctests as the contract for expected behavior.
- Keep docs and code in sync by updating doctests whenever behavior changes.

## Architecture discipline

- Respect feature boundaries and only cross them through each feature’s public facade.
- Keep facades thin; put logic in feature internals.
- Avoid duplicate sources of truth; centralize state and recompute when needed.

## Implementation style

- Prefer small, focused changes over broad refactors.
- Avoid introducing new globals or hidden side effects.
- Use existing helpers instead of re‑implementing utilities.
- Use single quotes for strings.

## Safety and reliability

- Favor non‑destructive operations and clear error handling.
- Log meaningful failures using the shared logging helper.
- Clean up temporary resources when work is done.

## Validation

- Run doctests for any doc or behavior changes when appropriate.
- Defer long‑running or environment‑dependent checks unless explicitly requested.
