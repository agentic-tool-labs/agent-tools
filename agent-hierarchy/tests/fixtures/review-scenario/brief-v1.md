---
id: 00000000-000000-scn1
type: request
to: reviewer
from: orchestrator
slug: scenario-v1
---

## [0] tldr
- [1] goal: review v0 to v1. The change adds each item's kind to the emitted event; its stated claim is "emitted events carry each item's real kind". Source: the comment above `emit` in v1/items.mjs.
- [5] acceptance: every emitted kind equals the kind the list path reports for the same record; no other behaviour changes.

## [1] goal
- see tldr

## [2] context
- v0 and v1 are full snapshots under tests/fixtures/review-scenario/. Nothing else is known about the callers.

## [3] constraints
- read-only review; do not run anything

## [4] files
- tests/fixtures/review-scenario/v0/items.mjs, tests/fixtures/review-scenario/v1/items.mjs

## [5] acceptance
- see tldr

## [6] want_back
- verdict, range, Claims list, findings
