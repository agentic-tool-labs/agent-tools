#!/bin/bash
# agent-hierarchy — the shared status-document fixtures in tests/fixtures/status/. They are what the
# claude-tui-line items and the ah mod test against, so each one must be exactly what
# `roster.mjs status --now` produces today: this stages each case's pool, regenerates its document
# and fails unless it is byte-identical to the committed file. A rule change that alters a fixture
# therefore fails here until the fixture is regenerated and its consumers are checked.
# Regenerate (the fixtures, then mod/tests/fixtures.ts from them): AH_UPDATE_FIXTURES=1 bash tests/test-status-fixtures.sh
# HOME- and AGENT_HIERARCHY_DIR-redirected; real state untouched.
# Usage: bash tests/test-status-fixtures.sh   (exits 0 iff all cases pass)

unset AH_TEAM_FILE  # every session roster.mjs launches carries one; a test must not inherit it
unset CLAUDE_PID  # every Claude session exports one; a test must not inherit it

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
. "$PLUGIN/tests/lib-status-pool.sh"
FIXTURES="$PLUGIN/tests/fixtures/status"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-status-fixtures-test.XXXXXX")"
[ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name"; fi
}

REF="2026-01-01T12:00:00.000Z"
ARCH='{"role":"architect","name":"demo-architect","route":"pane","kind":"codex","transport_id":"w1:p1"}'
REV='{"role":"reviewer","name":"demo-reviewer","route":"pane","kind":"codex","transport_id":"w1:p2"}'
PEER_REV='{"role":"reviewer","name":"demo-reviewer","route":"peer","kind":"claude","transport_id":"w1:p2"}'

# Stagers, one per case: each builds its pool from nothing.
case_idle() {
  team - "[$ARCH,$REV]"
  activity pane-demo-architect idle "$(at -300000)"
  activity pane-demo-reviewer idle "$(at -300000)"
}
case_work() {
  team - "[$ARCH]"
  activity pane-demo-architect working "$(at -60000)"
  request 20260101-115800-w001 architect build-step "$(at -120000)" small demo-architect
  dispatch 20260101-115800-w001 architect "$(at -60000)"
  stub 20260101-115800-w001
}
case_warn() {
  team - "[$ARCH,$REV]"
  activity pane-demo-architect blocked "$(at -30000)" approval "Allow edits to config.toml? (y/n)"
  activity pane-demo-reviewer working "$(at -60000)"
  request 20260101-115800-n001 architect build-step "$(at -120000)" medium demo-architect
  dispatch 20260101-115800-n001 architect "$(at -120000)"
  stub 20260101-115800-n001
}
case_bad() {
  team - "[$ARCH,$REV]"
  activity pane-demo-architect working "$(at -360000)"
  activity pane-demo-reviewer working "$(at -600000)"
  request 20260101-115400-b001 architect build-step "$(at -360000)" small demo-architect
  dispatch 20260101-115400-b001 architect "$(at -360000)"
  stub 20260101-115400-b001
  request 20260101-115000-b002 reviewer review-step "$(at -600000)" small demo-reviewer
  dispatch 20260101-115000-b002 reviewer "$(at -600000)"
  stub 20260101-115000-b002
  nudge 20260101-115000-b002 "$(at -300000)"
}
case_hidden() {
  case_work
  disable
}
case_pipeline() {
  team demo "[$ARCH,$REV]"
  activity pane-demo-architect idle "$(at -900000)"
  activity pane-demo-reviewer working "$(at -600000)"
  request 20260101-113000-p000 orchestrator pipeline-run-anchor "$(at -1800000)" small null demo
  request 20260101-113500-p001 architect ac-1 "$(at -1500000)" small demo-architect demo
  dispatch 20260101-113500-p001 architect "$(at -1500000)"
  filled 20260101-113500-p001 "$(at -1200000)"
  request 20260101-115000-p002 reviewer ac-1 "$(at -600000)" large demo-reviewer demo
  dispatch 20260101-115000-p002 reviewer "$(at -600000)"
  stub 20260101-115000-p002
  decision 20260101-113000-p000 '{"kind":"parked","item":"ac-1","question":"Which schema version?","why_user":"unsure"}'
}
case_member_session() {
  team - "[$PEER_REV]"
  up demo-reviewer reviewer sess-demo-reviewer w1:p2
  activity sess-demo-reviewer working "$(at -60000)"
  request 20260101-115800-m001 reviewer review-step "$(at -120000)" small demo-reviewer
  dispatch 20260101-115800-m001 reviewer "$(at -60000)"
  stub 20260101-115800-m001
}

# A busy team live in the pool that the viewing session does not own.
case_foreign() {
  case_work
}

mkdir -p "$FIXTURES"
for c in idle work warn bad hidden pipeline member-session foreign; do
  pool "$SANDBOX/$c"
  "case_${c//-/_}"
  [ "$c" = foreign ] || session sess-orch
  status "$REF"
  if [ -n "${AH_UPDATE_FIXTURES:-}" ]; then printf '%s\n' "$OUT" > "$FIXTURES/$c.json"; fi
  check "fixture $c: roster.mjs status --now $REF reproduces it byte for byte" '[ "$RC" = 0 ] && [ -f "$FIXTURES/$c.json" ] && [ "$(cat "$FIXTURES/$c.json")" = "$OUT" ]'
  check "fixture $c: holds no sandbox path" '! grep -q "$SANDBOX" "$FIXTURES/$c.json"'
done
check "the fixture set is exactly the eight cases" '[ "$(ls "$FIXTURES" | tr "\n" " ")" = "bad.json foreign.json hidden.json idle.json member-session.json pipeline.json warn.json work.json " ]'
if [ -n "${AH_UPDATE_FIXTURES:-}" ]; then mkdir -p "$PLUGIN/mod/tests" && node "$PLUGIN/tests/gen-mod-fixtures.mjs" "$FIXTURES" > "$PLUGIN/mod/tests/fixtures.ts"; fi

# What each case is for: a fixture that drifted into showing something else fails here, not in a consumer.
f() { node -e 'const o = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); process.stdout.write(String((new Function("o", "return (" + process.argv[2] + ")"))(o)))' "$FIXTURES/$1.json" "$2"; }
check "idle: live members, nothing out, tone idle" '[ "$(f idle "o.timeline.length + \" \" + o.timeline[0].tone + \" \" + o.timeline[0].live + \" \" + o.timeline[0].out")" = "1 idle 2 0" ]'
check "work: one dispatch running working → overdue → stalled" '[ "$(f work "o.timeline.map(e => e.tone).join()")" = "work,bad,bad" ] && [ "$(f work "o.teams[0].dispatches[0].states.map(s => s.state).join()")" = "working,overdue,stalled" ]'
check "warn: a blocked member" '[ "$(f warn "o.timeline[0].tone + \" \" + o.timeline[0].blocked")" = "warn 1" ]'
check "bad: an overdue and a stalled dispatch" '[ "$(f bad "o.timeline[0].tone + \" \" + o.timeline[0].overdue + \" \" + o.timeline[0].stalled")" = "bad 1 1" ]'
check "hidden: disabled, every entry visible:false" '[ "$(f hidden "o.enabled + \" \" + o.timeline.every(e => !e.visible)")" = "false true" ]'
check "pipeline: an open run with an item and a parked decision" '[ "$(f pipeline "o.teams[0].team + \" \" + o.teams[0].pipeline.items.length + \" \" + o.teams[0].pipeline.waiting_on_user")" = "demo 1 1" ]'
check "member-session: member_sessions is not empty; no other case has one" '[ "$(f member-session "o.member_sessions.join()")" = sess-demo-reviewer ] && for c in idle work warn bad hidden pipeline; do [ "$(f $c "o.member_sessions.length")" = 0 ] || exit 1; done'
check "owners: sess-orch owns the team in every case but foreign, where the entry lists no session" '[ "$(f idle "o.owners.length + \" \" + o.owners[0].sessions.join()")" = "1 sess-orch" ] && [ "$(f foreign "o.owners.length + \" \" + o.owners[0].sessions.length")" = "1 0" ]'

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
