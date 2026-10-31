# Architecture decision records

An ADR (architecture decision record) is a short file that records one decision: what was decided, why,
and what it changes.

## When to write one

Write one for a choice that is hard to undo, or that changes how steps, panels, tests or releases work.
For example: panel profiles, VMs or containers for tests, a code formatter.

Small fixes do not need one. The decision rules are in [GOVERNANCE.md](../../GOVERNANCE.md#how-decisions-are-made).

## How to write one

1. Copy [0000-template.md](0000-template.md) to `NNNN-short-title.md`, with the next free 4-digit number.
2. Numbers are never reused or changed.
3. Open it in a pull request with the status `proposed`. When the reviewers agree, set it to `accepted` and update
   the Date in the same pull request, before it is merged. An ADR on `main` is never `proposed`.
4. To change a decision, write a new ADR and set the old one to `superseded by NNNN`.
   Do not rewrite old ADRs otherwise.

## Status values

- `proposed`: under review in a pull request.
- `accepted`: agreed in review, then merged. This is how we work now.
- `superseded by NNNN`: replaced by a newer ADR.
