#!/bin/bash
# agent-hierarchy — the Orchestrator's Stop-hook check-ins under the exchange open rule: a stub
# response leaves a member dispatch owed, `deliver` to a pane member records a dispatch, the
# check-in cadence (T, then T/2, then every T), and the clock that starts at the first dispatch row.
# HOME- and AGENT_HIERARCHY_DIR-redirected; real state untouched.
# Usage: bash tests/test-exchange-open-liveness.sh   (exits 0 iff all cases pass)

unset AH_TEAM_FILE  # every session roster.mjs launches carries one; a test must not inherit it
unset CLAUDE_PID  # every Claude session exports one; a test must not inherit it

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-exchange-open-liveness-test.XXXXXX")"
[ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/proj"
HD="$SANDBOX/hier"
PENDING="$FAKEHOME/.claude/agent-hierarchy.peer-pending.jsonl"
GATES="$HD/gates.jsonl"
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude" "$HD/msgs"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (OUT=${OUT:0:600})"; fi
}
is_block() { case "$OUT" in *'"decision":"block"'*) true;; *) false;; esac; }

ago() { node -e 'process.stdout.write(new Date(Date.now() - Number(process.argv[1]) * 1000).toISOString())' "$1"; }
# <id> <to> <slug> <created-iso> [to_name]: an orchestrator request, eta small (T = 300 s).
write_request() {
  cat > "$HD/msgs/$1--$2--$3--request.md" <<EOF
---
id: $1
type: request
to: $2
from: orchestrator
slug: $3
parent: null
reason: null
eta: small
to_name: ${5:-peer-name}
from_name: null
team: null
created: $4
---

## [0] tldr
- none
EOF
}
# <id>: msg.mjs's skeleton response, so the member exchange stays open under the open rule.
stub() { HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/msg.mjs" new --type response --id "$1" --cwd "$PROJ" >/dev/null; }
# <id> <to> <session> <created-iso>
dispatch_row() { printf '{"type":"dispatch","session_id":"%s","request_id":"%s","to":"%s","created":"%s"}\n' "$3" "$1" "$2" "$4" >> "$PENDING"; }
# <id> <seconds ago>: every dispatch row for that request moved to one time.
age_rows() {
  node -e '
    const fs = require("fs"), [p, id, iso] = process.argv.slice(1);
    const out = fs.readFileSync(p, "utf8").split("\n").filter(Boolean).map((l) => {
      const r = JSON.parse(l);
      if (r.type === "dispatch" && r.request_id === id) r.created = iso;
      return JSON.stringify(r);
    });
    fs.writeFileSync(p, out.join("\n") + "\n");' "$PENDING" "$1" "$(ago "$2")"
}
# <id> <seconds ago>...: the request's liveness-nudge rows, in file order, set to those ages.
set_nudges() {
  local id=$1; shift
  local isos=(); for s in "$@"; do isos+=("$(ago "$s")"); done
  node -e '
    const fs = require("fs"), [p, id, ...isos] = process.argv.slice(1);
    let i = 0;
    const out = fs.readFileSync(p, "utf8").split("\n").filter(Boolean).map((l) => {
      const r = JSON.parse(l);
      if (r.type === "liveness-nudge" && r.request_id === id && i < isos.length) r.ts = isos[i++];
      return JSON.stringify(r);
    });
    fs.writeFileSync(p, out.join("\n") + "\n");' "$GATES" "$id" "${isos[@]}"
}
stop() { OUT=$(printf '{"session_id":"%s","cwd":"%s"}' "$1" "$PROJ" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/stop-orchestrator-liveness.mjs" 2>&1); }
nudges() { [ -f "$GATES" ] && grep -c "\"request_id\":\"$1\"" "$GATES" || echo 0; }

# ---------------------------------------------------------------- AC 19: a Claude peer's stub
ID=20260101-000000-a019
write_request "$ID" architect a19 "$(ago 600)"
stub "$ID"
PAYLOAD=$(node -e 'process.stdout.write(JSON.stringify({session_id:"o19",tool_name:"SendMessage",tool_input:{to:"peer",message:"[hierarchy-msg "+process.argv[1]+"]"}}))' "$HD/msgs/$ID--architect--a19--request.md")
printf '%s' "$PAYLOAD" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/posttooluse-peer-resolve.mjs" >/dev/null 2>&1
check "setup: SendMessage of the request wrote this session's dispatch row" 'grep -q "\"session_id\":\"o19\",\"request_id\":\"$ID\"" "$PENDING"'
age_rows "$ID" 301
stop o19
check "AC19: a SendMessage dispatch whose response is still a stub, past T, blocks" 'is_block && echo "$OUT" | grep -q "$ID"'

# ---------------------------------------------------------------- AC 20: a pane member's deliver
ID=20260101-000000-a020
REQ="$HD/msgs/$ID--architect--a20--request.md"
write_request "$ID" architect a20 "$(ago 60)" proj-architect
printf '{"members":[{"role":"architect","name":"proj-architect","route":"pane","kind":"claude","transport_id":"w1:p1"}]}\n' > "$HD/team.json"
ahcli() { node -e 'process.stdout.write(JSON.stringify({session_id:"o20",cwd:process.argv[1],tool_name:"Bash",tool_input:{command:process.argv[2]}}))' "$PROJ" "$1" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/pretooluse-ah-cli.mjs" 2>&1; }
OUT=$(ahcli "node $H/roster.mjs deliver proj-architect --req $REQ --wait-only --timeout 10 --cwd $PROJ")
check "AC20: deliver --wait-only is allowed and writes no dispatch row" 'echo "$OUT" | grep -q "\"permissionDecision\":\"allow\"" && ! grep -q "\"request_id\":\"$ID\"" "$PENDING"'
OUT=$(ahcli "node $H/roster.mjs deliver proj-architect --req $REQ --cwd $PROJ")
check "AC20: deliver --req writes this session's dispatch row, to the request's role" 'echo "$OUT" | grep -q "\"permissionDecision\":\"allow\"" && grep -q "\"session_id\":\"o20\",\"request_id\":\"$ID\",\"to\":\"architect\"" "$PENDING"'
stub "$ID"
age_rows "$ID" 301
stop o20
REASON=$(node -e 'try { process.stdout.write(JSON.parse(process.argv[1]).reason || "") } catch {}' "$OUT")
check "AC20: past T with a stub response, Stop blocks with the pane wording, paths quoted" 'is_block && echo "$REASON" | grep -qF "node \"$H/roster.mjs\" deliver proj-architect --req \"$REQ\" --wait-only --timeout 10 --cwd \"$PROJ\"" && echo "$REASON" | grep -q "AskUserQuestion" && echo "$REASON" | grep -q "not-live"'
check "AC20: the pane line maps no-report, not-sent and any other status" 'echo "$REASON" | grep -qF "\`no-report\` → the member is idle with no report: re-deliver the brief or ping it" && echo "$REASON" | grep -qF "\`not-sent\` → the brief never arrived: send it with \`deliver\`" && echo "$REASON" | grep -qF "any other status → act as the returned \`message\` says"'
check "AC20: a pane-only check-in names neither ListAgents nor SendMessage" '! echo "$OUT" | grep -qE "ListAgents|SendMessage"'
rm -f "$HD/team.json"

# ---------------------------------------------------------------- AC 21: cadence T, T/2, T
ID=20260101-000000-a021
write_request "$ID" architect a21 "$(ago 280)"
stub "$ID"
dispatch_row "$ID" architect o21 "$(ago 280)"
stop o21
check "AC21: no check-in before T after the origin" '! is_block'
age_rows "$ID" 301
stop o21
check "AC21: the first check-in at T after the origin" 'is_block && [ "$(nudges "$ID")" = 1 ]'
set_nudges "$ID" 130
stop o21
check "AC21: the second is not due before T/2 after the first" '! is_block && [ "$(nudges "$ID")" = 1 ]'
set_nudges "$ID" 151
stop o21
check "AC21: the second is due at T/2 after the first" 'is_block && [ "$(nudges "$ID")" = 2 ]'
set_nudges "$ID" 600 280
stop o21
check "AC21: the third is not due before T after the second" '! is_block && [ "$(nudges "$ID")" = 2 ]'
set_nudges "$ID" 600 301
stop o21
check "AC21: the third is due at T after the second" 'is_block && [ "$(nudges "$ID")" = 3 ]'
check "AC21: the reason states the cadence" 'echo "$OUT" | grep -q "after half an eta interval the first time, then every eta interval"'

# ---------------------------------------------------------------- AC 26: the clock starts at the first dispatch
ID=20260101-000000-a026
write_request "$ID" architect a26 "$(ago 660)"
stub "$ID"
dispatch_row "$ID" architect o26 "$(ago 60)"
stop o26
check "AC26: 1 min after the first dispatch row, a request written 10 min earlier does not block" '! is_block'
age_rows "$ID" 301
dispatch_row "$ID" architect o26 "$(ago 181)"
stop o26
check "AC26: at T after the first row it blocks, and says sent 5m ago" 'is_block && echo "$OUT" | grep -q "sent 5m ago"'
check "AC26: a second, later row did not delay that first check-in" '[ "$(nudges "$ID")" = 1 ]'
dispatch_row 20260101-000000-a027 architect other-session "$(ago 900)"
dispatch_row 20260101-000000-a027 architect o27 "$(ago 100)"
origin() { HOME="$FAKEHOME" node --input-type=module -e "import { dispatchOrigin } from '$H/lib-peer.mjs'; console.log(String(dispatchOrigin(process.argv[1])));" "$1"; }
EARLIEST=$(grep '"request_id":"20260101-000000-a027"' "$PENDING" | grep other-session | sed -E 's/.*"created":"([^"]+)".*/\1/')
check "AC26: the origin is the earliest row's created, across sessions" '[ -n "$EARLIEST" ] && [ "$(origin 20260101-000000-a027)" = "$EARLIEST" ]'
check "AC26: a request with no dispatch row has no origin" '[ "$(origin 20260101-000000-none)" = null ]'
ID=20260101-000000-a028
write_request "$ID" architect a28 "$(ago 400)"
stub "$ID"
dispatch_row "$ID" architect o28 "not-a-time"
stop o28
check "AC26: a dispatch whose only row has an unparseable created falls back to the backdated request, and is nudged" 'is_block && echo "$OUT" | grep -q "$ID"'

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
