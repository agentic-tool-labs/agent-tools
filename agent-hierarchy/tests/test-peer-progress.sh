#!/bin/bash
# agent-hierarchy — a peer's passive progress (the last finished tool in its activity record and the status
# file: tool name only, throttled) and the push-note rules around it: the notice and orchestrator text, a note
# counted as heard, and the report-back gate treating a note and a BLOCKED report differently.
# HOME- and AGENT_HIERARCHY_DIR-redirected; real state untouched.
# Usage: bash tests/test-peer-progress.sh   (exits 0 iff all cases pass)

unset AH_TEAM_FILE  # every session roster.mjs launches carries one; a test must not inherit it
unset CLAUDE_PID  # every Claude session exports one; a test must not inherit it

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
. "$PLUGIN/tests/lib-status-pool.sh"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-peer-progress-test.XXXXXX")"
[ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (OUT=${OUT:0:300})"; fi
}

pool "$SANDBOX/p"
SID="sess-role-0076"
MEMBER='{"role":"implementor","name":"demo-impl","route":"peer","kind":"claude","transport_id":"w1:p1"}'
HOME="$FAKEHOME" node --input-type=module -e "import { writeSessionRole } from '$H/lib-session-role.mjs'; writeSessionRole(process.argv[1], 'implementor');" "$SID"
team - "[$MEMBER]"
up demo-impl implementor "$SID" w1:p1

hook() { OUT=$(node -e 'const [e, s, cwd, x] = process.argv.slice(1); process.stdout.write(JSON.stringify({ hook_event_name: e, session_id: s, cwd, ...JSON.parse(x || "{}") }))' "$1" "$2" "$PROJ" "${3:-}" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/activity.mjs" 2>&1); RC=$?; }
tool() { hook PostToolUse "$SID" "$(node -e 'process.stdout.write(JSON.stringify({ tool_name: process.argv[1], tool_input: JSON.parse(process.argv[2] || "{}") }))' "$1" "${2:-}")"; }
rec() { node -e 'try { const a = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); console.log(eval(process.argv[2])); } catch { console.log("none"); }' "$HD/activity/$SID.json" "$1"; }
stat() { node -e 'try { const o = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); const m = o.teams[0].members[0]; console.log(eval(process.argv[2])); } catch { console.log("none"); }' "$HD/status.json" "$1"; }
backdate_tool() { node -e 'const fs = require("fs"); const p = process.argv[1]; const a = JSON.parse(fs.readFileSync(p, "utf8")); a.tool_at = new Date(Date.now() - 16000).toISOString(); fs.writeFileSync(p, JSON.stringify(a) + "\n")' "$HD/activity/$SID.json"; }

# an event refreshes status.json only where one exists
(cd "$SANDBOX" && HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/roster.mjs" status --cwd "$PROJ" >/dev/null 2>&1)

# ---- A1: the tool's input never reaches the record or the status file
hook UserPromptSubmit "$SID"
tool Bash '{"command":"cat /home/u/private/key.pem","note":"sk-live-SECRET-9f3a"}'
check "A1: the record holds the tool name" '[ "$(rec a.tool)" = Bash ] && [ "$(rec "typeof a.tool_at")" = string ]'
check "A1: the status file shows it as last_tool / last_tool_at" '[ "$(stat m.last_tool)" = Bash ] && [ "$(stat "m.last_tool_at")" = "$(rec a.tool_at)" ]'
check "A1: neither file holds any of the input text" '! grep -q "key.pem\|SECRET\|/home/u" "$HD/activity/$SID.json" "$HD/status.json"'

# ---- A2: ten events inside the interval write once
T0=$(rec a.tool_at); W0=$(stat "0") ; S0=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).written_at)' "$HD/status.json"); sleep 1.1
for n in 1 2 3 4 5 6 7 8 9 10; do tool "Tool$n"; done
check "A2: ten PostToolUse events within 15 s leave the record as the first wrote it" '[ "$(rec a.tool_at)" = "$T0" ] && [ "$(rec a.tool)" = Bash ]'
check "A2: and do not rewrite the status file" '[ "$(node -e "console.log(JSON.parse(require(\"fs\").readFileSync(process.argv[1], \"utf8\")).written_at)" "$HD/status.json")" = "$S0" ]'

# ---- A7: the throttle drops the trailing edge, and the record says so
check "A7: after tool B was throttled the record and status still show tool A with A's time" '[ "$(rec a.tool)" = Bash ] && [ "$(stat m.last_tool)" = Bash ] && [ "$(stat m.last_tool_at)" = "$T0" ]'

# ---- A3: past the interval one event writes
backdate_tool
tool Edit
check "A3: a PostToolUse 15 s after the last tool_at writes the new tool" '[ "$(rec a.tool)" = Edit ] && [ "$(rec a.tool_at)" != "$T0" ] && [ "$(stat m.last_tool)" = Edit ]'

# ---- A4: Stop keeps the tool
TA=$(rec a.tool_at)
hook Stop "$SID"
check "A4: Stop records idle and preserves tool and tool_at" '[ "$(rec a.activity)" = idle ] && [ "$(rec a.tool)" = Edit ] && [ "$(rec a.tool_at)" = "$TA" ]'
hook UserPromptSubmit "$SID"
check "A4: a new turn's UserPromptSubmit keeps them too, with activity working" '[ "$(rec a.activity)" = working ] && [ "$(rec a.tool)" = Edit ] && [ "$(rec a.tool_at)" = "$TA" ]'

# ---- A5: a subagent writes nothing
BEFORE=$(cat "$HD/activity/$SID.json")
hook PostToolUse "$SID" '{"tool_name":"SubTool","agent_id":"a1","agent_type":"task-gopher:task-gopher"}'
check "A5: a subagent's PostToolUse changes nothing" '[ "$(cat "$HD/activity/$SID.json")" = "$BEFORE" ]'

# ---- A6: control characters and length
backdate_tool
LONG=$(node -e 'process.stdout.write("T" + "x".repeat(120))')
hook PostToolUse "$SID" "$(node -e 'process.stdout.write(JSON.stringify({ tool_name: "A\u001b[31mB\u0007C" + process.argv[1] }))' "$LONG")"
check "A6: the record's tool has no control characters and is at most 64 long" '[ "$(rec "/[\\u0000-\\u001f\\u007f-\\u009f]/.test(a.tool)")" = false ] && [ "$(rec a.tool.length)" -le 64 ] && [ "$(rec a.tool.slice\(0,3\))" = ABC ]'
check "A6: so does the status file's last_tool" '[ "$(stat m.last_tool.length)" -le 64 ] && [ "$(stat m.last_tool.slice\(0,3\))" = ABC ]'
backdate_tool
hook PostToolUse "$SID" '{"tool_name":"","tool_input":{}}'
check "A6: an empty tool name writes no tool, and keeps the previous one" '[ "$(rec "a.tool.slice(0,3)")" = ABC ]'

# ---- P1, P2: the prose
NOTICE=$(HOME="$FAKEHOME" node --input-type=module -e "const L = await import('$H/lib-config.mjs'); process.stdout.write(L.buildRoleSessionNotice('implementor', 'ah:implementor'));")
OUT="$NOTICE"
check "P1: the peer notice has the note format, 'only', both triggers, large, 'not the report', both report statuses, and never-note-then-wait" 'for s in "note:" " only " "surprise that changes the plan" "midpoint" "eta: large" "not the report" "BLOCKED" "NEEDS-DECISION" "never a note then wait" "send nothing until the report"; do printf "%s" "$NOTICE" | grep -q "$s" || { OUT="missing: $s"; false; break; }; done'
ORCH="$PLUGIN/agents/orchestrator.md"
check "P2: orchestrator.md says a note is news that never closes a dispatch" 'grep -q "note:" "$ORCH" && grep -q "never closes" "$ORCH"'
check "P2: and that a BLOCKED report is answered by a new request with --parent" 'grep -q -- "--parent" "$ORCH" && grep -q "new request" "$ORCH"'
check "ceiling: orchestrator.md stays within 7350 bytes" '[ "$(wc -c < "$ORCH")" -le 7350 ]'
for f in implementor reviewer architect; do
  git -C "$PLUGIN" diff --quiet HEAD -- "agents/$f.md" 2>/dev/null; check "no text went into agents/$f.md" '[ $? -eq 0 ]'
done

# ---- P5, P6, P8: the notes and the gates
PENDING="$FAKEHOME/.claude/agent-hierarchy.peer-pending.jsonl"
HIER_DIR="$HD"
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
iso_ago() { node -e 'console.log(new Date(Date.now()-Number(process.argv[1])*1000).toISOString())' "$1"; }
wrapped() { printf '<cross-session-message from="uds:/tmp/cc-socks/1.sock" from-name="%s" from-mode="prompting">\n%s\n</cross-session-message>' "${2:-at-orchestrator}" "$1"; }
ups() {  # <session> <prompt>
  node -e 'console.log(JSON.stringify({session_id:process.argv[1],cwd:process.argv[2],prompt:process.argv[3],hook_event_name:"UserPromptSubmit"}))' "$1" "$PROJ" "$2" > "$SANDBOX/ups.json"
  OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/userpromptsubmit-peer-tracking.mjs" < "$SANDBOX/ups.json" 2>&1); RC=$?
}
send() {  # <session> <to> <message>: the peer's PostToolUse for a SendMessage
  OUT=$(node -e 'console.log(JSON.stringify({session_id:process.argv[1],cwd:process.argv[2],hook_event_name:"PostToolUse",tool_name:"SendMessage",tool_input:{to:process.argv[3],message:process.argv[4]}}))' "$1" "$PROJ" "$2" "$3" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/posttooluse-peer-resolve.mjs" 2>&1); RC=$?
}
peer_stop() { OUT=$(printf '{"session_id":"%s","cwd":"%s","hook_event_name":"Stop"}' "$1" "$PROJ" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/stop-peer-nudge.mjs" 2>&1); RC=$?; }
is_block() { case "$OUT" in *'"decision":"block"'*) true;; *) false;; esac; }
rows() { [ -f "$PENDING" ] && grep -c "$1" "$PENDING" || echo 0; }
session_start() { printf '{"session_id":"%s","cwd":"%s","agent_type":"%s","hook_event_name":"SessionStart","source":"startup"}' "$1" "$PROJ" "$2" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/sessionstart.mjs" >/dev/null 2>&1; }

# P5: a note from the peer, delivered to the Orchestrator's session, is a heard record
ID5=20260101-000000-p5aa
request "$ID5" implementor p5 "$(iso_ago 360)" small demo-impl
printf '{"type":"dispatch","session_id":"s-orch5","request_id":"%s","to":"implementor","path":"%s","to_addr":"peer-heard","created":"%s"}\n' "$ID5" "$HD/msgs/$ID5--implementor--p5--request.md" "$(iso_ago 0)" >> "$PENDING"
ups s-orch5 "$(wrapped "[hierarchy-msg $HD/msgs/$ID5--implementor--p5--request.md] note: halfway, 3 of 6 done" peer-heard)"
check "P5: a peer note delivered to the Orchestrator writes a heard row" '[ "$(rows "\"type\":\"heard\"")" -ge 1 ]'
ups s-orch5b "$(wrapped "[hierarchy-msg $HD/msgs/$ID5--implementor--p5--request.md] note: halfway" someone-else)"
check "P5: a note from a name that is no dispatch's peer writes none more" '[ "$(rows "\"type\":\"heard\"")" -eq 1 ]'

# P6: a note is not a report
ID6=20260101-000000-p6aa
request "$ID6" implementor p6 "2020-01-01T00:00:00-00:00" large demo-impl
REQ6="$HD/msgs/$ID6--implementor--p6--request.md"
session_start s-peer6 ah:implementor
ups s-peer6 "$(wrapped "Implement it. [hierarchy-msg $REQ6]")"
peer_stop s-peer6
check "P6 setup: the peer owes a report, so its Stop blocks" 'is_block'
send s-peer6 at-orchestrator "[hierarchy-msg $REQ6] note: halfway, 3 of 6 done"
peer_stop s-peer6
check "P6: after sending only a note the Stop gate still holds" 'is_block'

# P8: a BLOCKED report is a report
node "$H/msg.mjs" new --type response --id "$ID6" --req "$REQ6" --to orchestrator --from implementor --cwd "$PROJ" >/dev/null 2>&1
RESP6=$(ls "$HD"/msgs/"$ID6"--*--response.md 2>/dev/null | head -1)
[ -n "$RESP6" ] && sed -i '' 's/^## \[1\] status$/## [1] status\n- BLOCKED: need the exact question answered/' "$RESP6"
send s-peer6 at-orchestrator "BLOCKED. [hierarchy-msg $RESP6]"
peer_stop s-peer6
check "P8: after a BLOCKED response file and its message the Stop gate lets the peer stop" '[ -n "$RESP6" ] && [ -z "$OUT" ]'

echo "----"
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
