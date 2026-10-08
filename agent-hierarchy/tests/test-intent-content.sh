#!/bin/bash
# agent-hierarchy — the review and intent rules are in the role definitions, the custom-role contracts and
# the Orchestrator directive: each assertion greps for a token or phrase the rule cannot be stated without.
# Usage: bash tests/test-intent-content.sh   (exits 0 iff all cases pass)

. "$(dirname "$0")/lib-hermetic.sh"
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-intent-content-test.XXXXXX")"
[ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$SANDBOX"' EXIT
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name"; fi
}
has() { grep -qF -- "$2" "$PLUGIN/$1"; } # <file> <text>

for t in 'NEEDS-INTENT' 'unverified' 'contradicted' '<base>..<head>' 'working tree on' 'n/a:' 'caller path' 'Prior verdicts are claims'; do
  check "agents/reviewer.md holds: $t" 'has agents/reviewer.md "$t"'
done
for t in 'must NOT match' 'assumption'; do
  check "agents/implementor.md holds: $t" 'has agents/implementor.md "$t"'
done
check "agents/architect.md holds: Invariants and negative cases" 'has agents/architect.md "Invariants and negative cases"'
check "contracts/review.md holds: NEEDS-INTENT" 'has contracts/review.md "NEEDS-INTENT"'
check "contracts/design.md holds: negative cases" 'has contracts/design.md "negative cases"'
check "contracts/implement.md holds: negative test" 'has contracts/implement.md "negative test"'

mkdir -p "$SANDBOX/home/.claude" "$SANDBOX/proj"
git -C "$SANDBOX/proj" init -q
for mode in auto confirm; do
  printf '{"version":1,"enabled":true,"roles":{},"handoffs":"%s"}\n' "$mode" > "$SANDBOX/home/.claude/agent-hierarchy.json"
  HOME="$SANDBOX/home" node --input-type=module -e "
    const L = await import('$PLUGIN/hooks/lib-config.mjs');
    process.stdout.write(L.buildDirective(L.resolveConfig('$SANDBOX/proj'), 's1', { hierDir: '/tmp/h', model: 'opus', route: null }));
  " > "$SANDBOX/directive-$mode.txt" 2>&1
  for t in 'covers only the range' 'never Determined' 'Invariants and negative cases' 'NEEDS-INTENT'; do
    check "buildDirective($mode) holds: $t" 'grep -qF -- "$t" "$SANDBOX/directive-$mode.txt"'
  done
done

echo "----"
echo "SUMMARY: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
