#!/bin/bash
# agent-hierarchy — one pane-driven predicate: a Claude member on `route: pane` is a Claude session in
# the status document (session_id, route "peer", activity from its session record, a place in
# member_sessions), a non-Claude pane member is unchanged, and isPaneMember has one definition.
# The launch seed and the Stop-hook wording for the same member are in test-chain-roles-other-harnesses.sh
# and test-exchange-open-liveness.sh. HOME- and AGENT_HIERARCHY_DIR-redirected; real state untouched.
# Usage: bash tests/test-pane-member-predicate.sh   (exits 0 iff all cases pass)

. "$(dirname "$0")/lib-hermetic.sh"
unset AH_TEAM_FILE  # every session roster.mjs launches carries one; a test must not inherit it
unset CLAUDE_PID  # every Claude session exports one; a test must not inherit it

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
. "$PLUGIN/tests/lib-status-pool.sh"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-pane-member-predicate-test.XXXXXX")"
[ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (OUT=${OUT:0:400})"; fi
}
REF="2026-03-01T12:00:00.000Z"
# <member name> <js over the member m>
member() { jq_doc "(m => $2)(o.teams[0].members.find(x => x.name === \"$1\"))"; }

pool "$SANDBOX/pool"
team - '[{"role":"reviewer","name":"demo-reviewer","route":"pane","kind":"claude","transport_id":"w1:p2"},{"role":"architect","name":"demo-architect","route":"pane","kind":"codex","transport_id":"w1:p1"}]'
up demo-reviewer reviewer sess-rev w1:p2
activity sess-rev working "$(at -60000)"
activity pane-demo-reviewer blocked "$(at -30000)" approval "a stale pane record the doc must not read"
activity pane-demo-architect idle "$(at -60000)"
status "$REF"
check "the document is written" '[ "$RC" = 0 ] && [ "$(jq_doc "o.teams.length")" = 1 ]'
check "Claude member on route pane: session_id from its up row, route peer, live" '[ "$(member demo-reviewer "m.session_id + \" \" + m.route + \" \" + m.live")" = "sess-rev peer true" ]'
check "...activity from <session_id>.json, not pane-<name>.json" '[ "$(member demo-reviewer "m.activity + \" \" + m.blocked_note")" = "working null" ]'
check "...and its session is in member_sessions" '[ "$(jq_doc "JSON.stringify(o.member_sessions)")" = "[\"sess-rev\"]" ]'
check "non-Claude pane member unchanged: route pane, no session_id, activity from pane-<name>.json" '[ "$(member demo-architect "m.route + \" \" + m.session_id + \" \" + m.activity")" = "pane null idle" ]'

DEFS=$(grep -nE '(function|const|let|var) isPaneMember\b' "$H"/*.mjs)
check "isPaneMember is defined once, in lib-config.mjs" '[ "$(printf "%s\n" "$DEFS" | grep -c .)" = 1 ] && printf "%s" "$DEFS" | grep -q "/lib-config.mjs:"'

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
