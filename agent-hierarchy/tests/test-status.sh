#!/bin/bash
# agent-hierarchy — the hierarchy status document (`roster.mjs status`, hooks/lib-status.mjs): the
# verb and its atomic write, the eta schedule from the dispatch origin, which dispatches are listed,
# member-driven states, sanitising, a disabled config, and the pipeline block. Every case stages its
# own pool and evaluates with --now.
# HOME- and AGENT_HIERARCHY_DIR-redirected; real state untouched.
# Usage: bash tests/test-status.sh   (exits 0 iff all cases pass)

unset AH_TEAM_FILE  # every session roster.mjs launches carries one; a test must not inherit it
unset CLAUDE_PID  # every Claude session exports one; a test must not inherit it

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
. "$PLUGIN/tests/lib-status-pool.sh"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-status-test.XXXXXX")"
[ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (OUT=${OUT:0:600})"; fi
}

REF="2026-03-01T12:00:00.000Z"
ARCH='{"role":"architect","name":"demo-architect","route":"pane","kind":"codex","transport_id":"w1:p1"}'
REV='{"role":"reviewer","name":"demo-reviewer","route":"pane","kind":"codex","transport_id":"w1:p2"}'
# The current state of dispatch <id>: the last of its states at or before written_at.
state_of() { jq_doc "(d => d ? d.states.filter(s => Date.parse(s.at) <= Date.parse(o.written_at)).pop()?.state ?? d.states[0].state : 'absent')(o.teams.flatMap(t => t.dispatches).find(d => d.id === '$1'))"; }
listed() { [ "$(jq_doc "o.teams.some(t => t.dispatches.some(d => d.id === '$1'))")" = true ]; }

# ---------------------------------------------------------------- AC 1: the verb
pool "$SANDBOX/v"
team - "[$ARCH]"
activity pane-demo-architect working "$REF"
status "$REF"
check "AC1: prints a schema-1 document" '[ "$RC" = 0 ] && [ "$(jq_doc o.schema)" = 1 ] && [ "$(jq_doc "o.written_at")" = "$REF" ] && [ "$(jq_doc "o.expires_at")" = "2026-03-02T12:00:00.000Z" ]'
check "AC1: writes status.json holding the printed document, no temp file left" '[ -f "$HD/status.json" ] && node -e "const fs=require(\"fs\"); process.exit(JSON.stringify(JSON.parse(fs.readFileSync(process.argv[1],\"utf8\"))) === JSON.stringify(JSON.parse(process.argv[2])) ? 0 : 1)" "$HD/status.json" "$OUT" && [ -z "$(ls "$HD" | grep "\.tmp$")" ]'
status "$REF" --plain
check "AC1: --plain prints ah · <text> for a visible entry" '[ "$RC" = 0 ] && [ "$OUT" = "ah · 1 live · 0 out" ]'
OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$SANDBOX/no-hier" node "$H/roster.mjs" status --now "$REF" --cwd "$PROJ" 2>&1); RC=$?
check "AC1: with no hierarchy dir it exits 0, prints teams: [] and writes nothing" '[ "$RC" = 0 ] && [ "$(jq_doc "o.teams.length")" = 0 ] && [ ! -e "$SANDBOX/no-hier" ]'
OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$SANDBOX/no-hier" node "$H/roster.mjs" status --plain --now "$REF" --cwd "$PROJ" 2>&1); RC=$?
check "AC1: --plain prints an empty line when the entry is not visible" '[ "$RC" = 0 ] && [ -z "$OUT" ]'

# ---------------------------------------------------------------- AC 2: the eta schedule
for row in "small 300" "medium 600" "large 1200"; do
  read -r ETA T_SEC <<< "$row"; T=$(( T_SEC * 1000 ))
  pool "$SANDBOX/eta-$ETA"
  team - "[$ARCH]"
  activity pane-demo-architect working "$REF"
  ID="20260301-115000-e${ETA:0:3}"
  request "$ID" architect "eta-$ETA" "$(at -600000)" "$ETA" demo-architect
  dispatch "$ID" architect "$REF"
  dispatch "$ID" architect "$(at 120000)"
  stub "$ID"
  nudge "$ID" "$(at $(( T + 180000 )))"
  for probe in "0 working 0 0" "$(( T - 1000 )) working 0 0" "$T overdue 1 0" "$(( T * 3 / 2 - 1000 )) overdue 1 0" "$(( T * 3 / 2 )) stalled 0 1"; do
    read -r P_MS P_STATE P_OVERDUE P_STALLED <<< "$probe"
    status "$(at "$P_MS")"
    check "AC2 $ETA: at origin+$P_MS ms the dispatch is $P_STATE (overdue $P_OVERDUE, stalled $P_STALLED)" '[ "$(state_of "$ID")" = "$P_STATE" ] && [ "$(jq_doc "o.timeline[0].out")" = 1 ] && [ "$(jq_doc "o.timeline[0].overdue")" = "$P_OVERDUE" ] && [ "$(jq_doc "o.timeline[0].stalled")" = "$P_STALLED" ]'
  done
  status "$REF"
  check "AC2 $ETA: sent_at is the first dispatch row, not the request or a later row" '[ "$(jq_doc "o.teams[0].dispatches[0].sent_at")" = "$REF" ] && [ "$(jq_doc "o.teams[0].dispatches[0].created")" = "$(at -600000)" ]'
  check "AC2 $ETA: a late nudge is counted but does not move stalled_at" '[ "$(jq_doc "o.teams[0].dispatches[0].checkins")" = 1 ] && [ "$(jq_doc "o.teams[0].dispatches[0].states[2].at")" = "$(at $(( T * 3 / 2 )))" ] && [ "$(jq_doc "o.teams[0].dispatches[0].eta_ms")" = "$T" ]'
done

# ---------------------------------------------------------------- AC 3: report present and the dispatch set
pool "$SANDBOX/set"
team - "[$ARCH,$REV]"
activity pane-demo-architect working "$REF"
activity pane-demo-reviewer working "$REF"
request 20260301-110000-s0a1 architect stub-a "$(at -3600000)" small demo-architect; dispatch 20260301-110000-s0a1 architect "$(at -60000)"; stub 20260301-110000-s0a1
request 20260301-110000-s0b1 architect stub-b "$(at -3600000)" small demo-architect; dispatch 20260301-110000-s0b1 architect "$(at -60000)"; stub 20260301-110000-s0b1
FM_END=$(grep -n '^---$' "$RESP" | sed -n 2p | cut -d: -f1)
{ head -n "$FM_END" "$RESP"; tail -n +"$((FM_END + 1))" "$RESP" | awk '{ l[NR] = $0 } END { for (i = NR; i > 0; i--) print l[i] }'; } > "$RESP.tmp" && mv "$RESP.tmp" "$RESP"
request 20260301-110000-s0c1 reviewer filled-c "$(at -3600000)" small demo-reviewer; dispatch 20260301-110000-s0c1 reviewer "$(at -600000)"; filled 20260301-110000-s0c1 "$(at -60000)"
request 20260301-110000-s0d1 reviewer bad-fm-d "$(at -3600000)" small demo-reviewer; dispatch 20260301-110000-s0d1 reviewer "$(at -600000)"
printf 'no frontmatter here\n' > "$HD/msgs/20260301-110000-s0d1--orchestrator--bad-fm-d--response.md"; mtime "$HD/msgs/20260301-110000-s0d1--orchestrator--bad-fm-d--response.md" "$(at -60000)"
request 20260301-110000-s0e1 orchestrator ab12-i1 "$(at -3600000)" small; dispatch 20260301-110000-s0e1 orchestrator "$(at -60000)"
request 20260301-110000-s0f1 architect gone-team "$(at -3600000)" small demo-architect gone; dispatch 20260301-110000-s0f1 architect "$(at -60000)"
request 20260301-110000-s0g1 architect unsent "$(at -3600000)" small demo-architect
status "$REF"
check "AC3: a member request with a skeleton stub is still out" '[ "$(state_of 20260301-110000-s0a1)" = working ]'
check "AC3: the same with the skeleton reordered is still out" '[ "$(state_of 20260301-110000-s0b1)" = working ]'
check "AC3: a filled response is reported, reported_at = its mtime" '[ "$(state_of 20260301-110000-s0c1)" = reported ] && [ "$(jq_doc "o.teams[0].dispatches.find(d => d.id === \"20260301-110000-s0c1\").reported_at")" = "$(at -60000)" ]'
check "AC3: a response without frontmatter counts as reported" '[ "$(state_of 20260301-110000-s0d1)" = reported ]'
check "AC3: out counts the two stubs only" '[ "$(jq_doc "o.timeline[0].out")" = 2 ]'
check "AC3: an orchestrator-addressed record is not a dispatch" '! listed 20260301-110000-s0e1'
check "AC3: a request whose team is not live is not a dispatch" '! listed 20260301-110000-s0f1'
check "AC3: a request with no dispatch row is not a dispatch" '! listed 20260301-110000-s0g1'
status "$(at 539000)"
check "AC3: a reported dispatch stays listed until 10 min after its report" 'listed 20260301-110000-s0c1 && [ "$(jq_doc "o.timeline[0].out")" = 2 ]'
status "$(at 540000)"
check "AC3: 10 min after its report it is gone from the list and from out" '! listed 20260301-110000-s0c1 && [ "$(jq_doc "o.timeline[0].out")" = 2 ]'

# ---------------------------------------------------------------- AC 4: member-driven rules
pool "$SANDBOX/gone"
team - '[{"role":"reviewer","name":"demo-reviewer","route":"peer","kind":"claude","transport_id":"w1:p2"}]'
request 20260301-110000-g001 reviewer gone "$(at -60000)" small demo-reviewer; dispatch 20260301-110000-g001 reviewer "$(at -60000)"; stub 20260301-110000-g001
status "$REF"
check "AC4: a gone member's dispatch is stalled, reason member-gone" '[ "$(jq_doc "o.teams[0].members[0].live")" = false ] && [ "$(jq_doc "JSON.stringify(o.teams[0].dispatches[0].states)")" = "[{\"at\":\"$REF\",\"state\":\"stalled\",\"reason\":\"member-gone\"}]" ]'
pool "$SANDBOX/blocked"
team - "[$ARCH]"
activity pane-demo-architect blocked "$REF" approval "Allow edits? (y/n)"
request 20260301-110000-b001 architect blocked "$(at -7200000)" small demo-architect; dispatch 20260301-110000-b001 architect "$(at -7200000)"; stub 20260301-110000-b001
status "$REF"
check "AC4: a blocked member's dispatch is blocked, and that wins over time" '[ "$(state_of 20260301-110000-b001)" = blocked ] && [ "$(jq_doc "o.teams[0].dispatches[0].states.length")" = 1 ] && [ "$(jq_doc "o.timeline[0].blocked")" = 1 ] && [ "$(jq_doc "o.timeline[0].tone")" = warn ]'
activity pane-demo-architect working "$REF"
status "$REF"
check "AC4: after unblocking, the next write applies the schedule from the origin" '[ "$(jq_doc "o.teams[0].dispatches[0].states.map(s => s.state).join()")" = "working,overdue,stalled" ] && [ "$(state_of 20260301-110000-b001)" = stalled ]'

# ---------------------------------------------------------------- AC 10: sanitising
pool "$SANDBOX/clean"
LONG=$(printf 'n%.0s' $(seq 70))
team - "[{\"role\":\"architect\",\"name\":\"demo-\\u001b[31march\\u0007itect\",\"route\":\"pane\",\"kind\":\"codex\",\"transport_id\":\"w1:p1\"},{\"role\":\"reviewer\",\"name\":\"$LONG\",\"route\":\"pane\",\"kind\":\"codex\",\"transport_id\":\"w1:p2\"},$(printf '%s' "$ARCH" | sed 's/demo-architect/demo-planner/; s/"architect"/"planner"/; s/w1:p1/w1:p3/')]"
activity pane-demo-planner blocked "$REF" approval "$(printf '\033[2JWipe?\007 %s' "$(printf 'x%.0s' $(seq 100))")"
request 20260301-110000-c001 architect "esc" "$(at -60000)" small "$(printf 'demo-\033]0;title\007arch')"; dispatch 20260301-110000-c001 architect "$(at -60000)"; stub 20260301-110000-c001
status "$REF"
check "AC10: ESC sequences and control characters are stripped from a name" '[ "$(jq_doc "o.teams[0].members[0].name")" = demo-architect ] && [ "$(jq_doc "o.teams[0].dispatches[0].to_name")" = demo-arch ]'
check "AC10: a name is cut at 64, a note at 80, with no ellipsis" '[ "$(jq_doc "o.teams[0].members[1].name.length")" = 64 ] && [ "$(jq_doc "o.teams[0].members[2].blocked_note.length")" = 80 ] && [ "$(jq_doc "o.teams[0].members[2].blocked_note.startsWith(\"Wipe? \")")" = true ]'
check "AC10: no control character survives anywhere in the document" '! node -e "process.exit(/[\u0000-\u001f\u007f-\u009f]/.test(JSON.stringify(JSON.parse(process.argv[1]), (k, v) => v)) ? 0 : 1)" "$OUT" && ! printf "%s" "$OUT" | grep -q "u001b\|u0007"'

# ---------------------------------------------------------------- AC 11: disabled
pool "$SANDBOX/off"
team - "[$ARCH]"
activity pane-demo-architect working "$REF"
request 20260301-110000-d001 architect off "$(at -60000)" small demo-architect; dispatch 20260301-110000-d001 architect "$(at -60000)"; stub 20260301-110000-d001
disable
status "$REF"
check "AC11: a disabled config gives enabled:false and every entry visible:false" '[ "$(jq_doc o.enabled)" = false ] && [ "$(jq_doc "o.timeline.length")" -gt 1 ] && [ "$(jq_doc "o.timeline.every(e => e.visible === false)")" = true ]'

# ---------------------------------------------------------------- AC 12: the pipeline block
pool "$SANDBOX/pipe"
team t "[$ARCH,$REV]"
A0=20260301-110000-p000
request "$A0" orchestrator pipeline-run-anchor "$(at -1800000)" small null t
request 20260301-110100-p001 architect ac-1 "$(at -1740000)" small demo-architect t; filled 20260301-110100-p001 "$(at -1700000)"
request 20260301-110500-p002 reviewer ac-1 "$(at -1500000)" small demo-reviewer t; stub 20260301-110500-p002
request 20260301-100000-p003 architect ac-1 "$(at -5400000)" small demo-architect t; filled 20260301-100000-p003 "$(at -5300000)"
request 20260301-090000-p004 architect ac-0 "$(at -9000000)" small demo-architect t; filled 20260301-090000-p004 "$(at -8900000)"
request 20260301-111000-p005 architect dec-x-1 "$(at -1200000)" small demo-architect t
request 20260301-111500-p006 orchestrator ab12-i1 "$(at -900000)" small null t
decision "$A0" '{"kind":"parked","item":"ac-1","question":"q","why_user":"unsure"}'
decision "$A0" '{"kind":"decided","item":"ac-1","question":"r"}'
status "$REF"
PARKED=$(node --input-type=module -e "import { decisionSummary, readDecisions } from '$H/lib-decisions.mjs'; const l = readDecisions(process.argv[1]); console.log(decisionSummary(l.decisions, l.skipped).parked);" "$HD/pipeline/$A0/decisions.jsonl")
check "AC12: items are exactly ac-1, with all three rounds, open, newest to the reviewer" '[ "$(jq_doc "JSON.stringify(o.teams[0].pipeline.items)")" = "[{\"slug\":\"ac-1\",\"rounds\":3,\"open\":true,\"to\":\"reviewer\"}]" ]'
check "AC12: waiting_on_user is decisionSummary's parked count" '[ "$PARKED" = 1 ] && [ "$(jq_doc "o.teams[0].pipeline.waiting_on_user")" = 1 ]'
check "AC12: started is the anchor's created, round_cap 3, the team is t" '[ "$(jq_doc "o.teams[0].pipeline.started")" = "$(at -1800000)" ] && [ "$(jq_doc "o.teams[0].pipeline.round_cap")" = 3 ] && [ "$(jq_doc "o.teams[0].pipeline.anchor_id")" = "$A0" ] && [ "$(jq_doc "o.teams[0].team")" = t ]'
request 20260301-111600-p007 orchestrator pipeline-run-anchor "$(at -600000)" small null t
status "$REF"
check "AC12: two open anchors for the team → pipeline null" '[ "$(jq_doc "o.teams[0].pipeline")" = null ]'
rm -f "$HD/msgs/20260301-111600-p007--"*
HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/msg.mjs" new --type response --id "$A0" --to orchestrator --from orchestrator --slug pipeline-run-anchor --team t --cwd "$PROJ" >/dev/null
status "$REF"
check "AC12: the anchor closed by a bodyless response → pipeline null" '[ "$(jq_doc "o.teams[0].pipeline")" = null ]'

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
