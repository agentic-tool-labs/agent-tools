#!/bin/bash
# agent-hierarchy — the generic review scenario (tests/fixtures/review-scenario/) really contains the defects
# a Reviewer is expected to find, so the fixture cannot rot into one that holds no bug. Deterministic: no model,
# no network, no scratch files; it runs node against the fixture in place.
# Usage: bash tests/test-review-scenario.sh   (exits 0 iff all cases pass)

. "$(dirname "$0")/lib-hermetic.sh"
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
FX="$PLUGIN/tests/fixtures/review-scenario"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (OUT=${OUT:0:300})"; fi
}

# <snapshot> <js expression over the module M>: the expression's JSON.
js() { OUT=$(node --input-type=module -e "const M = await import('$FX/$1/items.mjs'); process.stdout.write(JSON.stringify($2))" 2>&1); }

js v0 'M.emit({ id: "a", expires: 5 })'
check "(c) v0: emit reports only the id, as a baseline" '[ "$OUT" = "{\"id\":\"a\"}" ]'

js v1 '[M.emit({ id: "t", expires: 5 }).kind, M.loadFromList({ id: "t", expires: 5 }).kind]'
check "(a) v1: a temporary item without a kind emits unspecified on the single-item path while the list path says temporary" '[ "$OUT" = "[\"unspecified\",\"temporary\"]" ]'
OUT=$(node "$FX/v1/claim.check.mjs" 2>&1); RC=$?
check "(a) v1: its own claim check fails (the claim is contradicted)" '[ "$RC" -ne 0 ]'

js v2 'M.emit({ id: "t", expires: 5, storedKind: "temporary" })'
check "(b0) v2: the intended case works: a temporary item without a kind emits its stored kind" '[ "$OUT" = "{\"id\":\"t\",\"kind\":\"temporary\"}" ]'
js v2 'M.emit({ id: "u", kind: "bogus", storedKind: "archived" })'
check "(b) v2: an unrecognised kind emits the stored kind and loses its reason" '[ "$OUT" = "{\"id\":\"u\",\"kind\":\"archived\"}" ]'
js v2 'M.emit({ id: "p", storedKind: "archived" })'
check "(b) v2: a non-temporary item without a kind emits the stored kind, where v1 emitted unspecified" '[ "$OUT" = "{\"id\":\"p\",\"kind\":\"archived\"}" ]'
OUT=$(node "$FX/v2/claim.check.mjs" 2>&1); RC=$?
check "(b) v2: its own claim check fails (the condition is wider than intended)" '[ "$RC" -ne 0 ]'

echo "----"
echo "SUMMARY: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
