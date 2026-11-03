#!/bin/bash
# task-gopher UserPromptSubmit + SessionStart injection gates.
# HOME is redirected to a throwaway dir so real config is never touched.
# Usage: bash tests/test-userpromptsubmit.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
UPS="$PLUGIN/hooks/userpromptsubmit.mjs"
SS="$PLUGIN/hooks/sessionstart.mjs"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/task-gopher-ups-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
FAKEHOME="$SANDBOX/home"
PASS=0; FAIL=0

mkdir -p "$FAKEHOME/.claude"

run() { OUT=$(printf '%s' "$2" | HOME="$FAKEHOME" node "$1" 2>/dev/null); RC=$?; }

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (OUT=${OUT:0:120} RC=$RC)"; fi
}

is_silent()   { [ $RC -eq 0 ] && [ -z "$OUT" ]; }
is_injected() { [ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q 'additionalContext'; }

PLAIN='{"session_id":"s1","cwd":"/tmp"}'
ROLE='{"session_id":"s1","cwd":"/tmp","agent_type":"ah:architect"}'
GOPHER='{"session_id":"s1","cwd":"/tmp","agent_type":"task-gopher:task-gopher"}'
OTHER='{"session_id":"s1","cwd":"/tmp","agent_type":"general-purpose"}'

# ---- plugin OFF: both hooks silent regardless
run "$UPS" "$PLAIN"; check "off: UPS silent" is_silent
run "$SS" "$PLAIN";  check "off: SessionStart silent" is_silent

touch "$FAKEHOME/.claude/task-gopher.enabled"

# ---- UserPromptSubmit
run "$UPS" "$PLAIN"
check "on: UPS injects the reminder for an ordinary session" is_injected
check "on: UPS reminder carries the sentinel" "printf '%s' \"\$OUT\" | grep -q 'task-gopher: ON'"

run "$UPS" "$GOPHER"
check "on: UPS silent inside the runner" is_silent

run "$UPS" "$ROLE"
check "on: UPS silent in an --agent ah:<role> session" is_silent

run "$UPS" "$OTHER"
check "on: UPS still injects for a non-hierarchy agent_type" is_injected

# ---- SessionStart
run "$SS" "$PLAIN"
check "on: SessionStart injects the full directive for an ordinary session" is_injected

run "$SS" "$GOPHER"
check "on: SessionStart silent inside the runner" is_silent

run "$SS" "$ROLE"
check "on: SessionStart silent in an --agent ah:<role> session" is_silent

run "$SS" "$OTHER"
check "on: SessionStart still injects for a non-hierarchy agent_type" is_injected

# Both hooks — the exemption is the plugin prefix, so a role no list names still matches.
for ROLE_NAME in ah:architect ah:implementor ah:orchestrator ah:reviewer ah:ultra-advisor ah:task-runner \
    ah2:architect ah2:reviewer ah2:backlog-groomer ah2:role-added-later; do
  P="{\"session_id\":\"s1\",\"cwd\":\"/tmp\",\"agent_type\":\"$ROLE_NAME\"}"
  run "$UPS" "$P"; check "on: UPS silent for $ROLE_NAME" is_silent
  run "$SS" "$P";  check "on: SessionStart silent for $ROLE_NAME" is_silent
done

# The nearest names that are not the hierarchy's plugin must still get both.
for NAME in ah2x:foo ahx:foo ah3:foo my-ah2:foo ah2 ah2: ; do
  P="{\"session_id\":\"s1\",\"cwd\":\"/tmp\",\"agent_type\":\"$NAME\"}"
  run "$UPS" "$P"; check "on: UPS injects for $NAME" is_injected
  run "$SS" "$P";  check "on: SessionStart injects for $NAME" is_injected
done

echo "----"
echo "SUMMARY: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
