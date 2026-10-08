#!/bin/bash
# agent-hierarchy — the files Claude Code writes into the plugin on a --plugin-dir load (tsconfig.json
# and .claude-plugin/types/) are ignored by the plugin's own .gitignore, and the authored types contract
# mod/types/index.d.ts is not. Skips outside a git work tree; reads only, writes nothing.
# Usage: bash tests/test-generated-ignored.sh   (exits 0 iff all cases pass)

. "$(dirname "$0")/lib-hermetic.sh"
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
if [ "$(git -C "$PLUGIN" rev-parse --is-inside-work-tree 2>/dev/null)" != true ]; then
  echo "SKIP: $PLUGIN is not inside a git work tree (a git archive copy), so there are no ignore rules to check"
  exit 0
fi
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (OUT=${OUT:0:400})"; fi
}
# <path relative to the plugin>: the ignore source file that matches it, or empty.
ignored_by() { git -C "$PLUGIN" check-ignore -v --no-index -- "$1" 2>/dev/null | cut -d: -f1; }
# the plugin .gitignore as check-ignore -v names it: relative to the repo root
OWN="$(git -C "$PLUGIN" rev-parse --show-prefix 2>/dev/null).gitignore"

check "the plugin is inside a git work tree" '[ "$(git -C "$PLUGIN" rev-parse --is-inside-work-tree 2>/dev/null)" = true ]'
OUT=$(ignored_by tsconfig.json)
check "tsconfig.json at the plugin root is ignored by the plugin's .gitignore" '[ "$OUT" = "$OWN" ]'
OUT=$(ignored_by .claude-plugin/types/claude-code/index.d.ts)
check "a file under .claude-plugin/types/ is ignored by the plugin's .gitignore" '[ "$OUT" = "$OWN" ]'
OUT=$(git -C "$PLUGIN" check-ignore -v --no-index -- mod/types/index.d.ts 2>&1)
check "mod/types/index.d.ts is not ignored" '[ -z "$OUT" ]'
OUT=$(git -C "$PLUGIN" ls-files -- mod/types/index.d.ts)
check "mod/types/index.d.ts is tracked" '[ "$OUT" = mod/types/index.d.ts ]'
OUT=$(ignored_by mod/tsconfig.json)
check "the rules are anchored: a tsconfig.json below the root is not ignored by them" '[ "$OUT" != "$OWN" ]'

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
