---
id: 00000000-000000-scn2
type: request
to: reviewer
from: orchestrator
slug: scenario-v2
---

## [0] tldr
- [1] goal: review v1 to v2. The change substitutes the item's stored kind when the loaded kind is "unspecified", so a temporary item without a kind emits its real kind. Source: the comment above `emit` in v2/items.mjs.
- [5] acceptance: a temporary item without a kind emits its stored kind; every other input emits exactly what v1 emitted for it.

## [1] goal
- see tldr

## [2] context
- v1 and v2 are full snapshots under tests/fixtures/review-scenario/. A reviewer found the v1 defect earlier; treat that thread as unverified.

## [3] constraints
- read-only review; do not run anything

## [4] files
- tests/fixtures/review-scenario/v1/items.mjs, tests/fixtures/review-scenario/v2/items.mjs

## [5] acceptance
- see tldr

## [6] want_back
- verdict, range, Claims list, findings
