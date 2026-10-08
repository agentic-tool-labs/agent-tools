#!/bin/bash
# agent-hierarchy — PreToolUse msg gate: role dispatches must carry a
# `[hierarchy-msg <request path>]` pointer to a valid request file.
# HOME- and AGENT_HIERARCHY_DIR-redirected; real state untouched.
# Usage: bash tests/test-msg-gate.sh   (exits 0 iff all cases pass)

. "$(dirname "$0")/lib-hermetic.sh"
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
. "$PLUGIN/tests/lib-quiet-deny.sh"
. "$PLUGIN/tests/lib-intent.sh"
unset AH_TEAM_FILE  # every session roster.mjs launches carries one; a test must not inherit it
unset CLAUDE_PID  # every Claude session exports one; a test must not inherit it
H="$PLUGIN/hooks"
GATE="$H/pretooluse-msg-gate.mjs"
MSG="$H/msg.mjs"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-msggate-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
HD="$SANDBOX/hier"
PROJ="$SANDBOX/myrepo"
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:400})"; fi
}

# A configured project so the hierarchy is enabled and reviewer has an explicit peer name.
cat > "$PROJ/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "enabled": true, "roles": { "reviewer": { "model": "opus", "dispatch": "peer", "peer": "rev-peer" }, "architect": { "model": "opus", "dispatch": "model" } } }
EOF

msg() { OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$MSG" --cwd "$PROJ" "$@" 2>&1); RC=$?; }

agent_payload() { # <subagent_type> <prompt> [agent_id]
  node -e 'const[t,p,a]=process.argv.slice(1);const o={session_id:"s1",cwd:process.env.PROJ,tool_name:"Agent",tool_input:{subagent_type:t,prompt:p}};if(a)o.agent_id=a;process.stdout.write(JSON.stringify(o));' "$1" "$2" "$3"; }
send_payload() { # <to> <message>
  node -e 'const[t,m]=process.argv.slice(1);process.stdout.write(JSON.stringify({session_id:"s1",cwd:process.env.PROJ,tool_name:"SendMessage",tool_input:{to:t,message:m,notify_when_idle:true}}));' "$1" "$2"; }

gate() { OUT=$(PROJ="$PROJ" HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$GATE" 2>&1); RC=$?; }
agent() { OUT=$(PROJ="$PROJ" agent_payload "$1" "$2" "$3" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$GATE" 2>&1); RC=$?; }
send()  { OUT=$(PROJ="$PROJ" send_payload "$1" "$2" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$GATE" 2>&1); RC=$?; }

denied() { echo "$OUT" | grep -q '"permissionDecision":"deny"'; }
allowed() { [ $RC -eq 0 ] && [ -z "$OUT" ]; }

# ---- fixtures: one implementor request, one closed exchange for reviewer
msg new --to implementor --from orchestrator --slug impl-task
IMPL_REQ=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).path)' "$OUT")
msg new --to reviewer --from orchestrator --slug rev-task
REV_REQ=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).path)' "$OUT")
fill_intent "$REV_REQ"
REV_ID=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).id)' "$OUT")
msg new --type response --id "$REV_ID"
REV_RESP=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).path)' "$OUT")

# ---- 1: Agent dispatches
agent ah:implementor "Please implement the thing at /tmp/spec.md"
check "Agent implementor, no token -> deny" 'denied'
check "M1: missing-brief deny is quiet" 'quiet_deny "$AH_M1_CALM" "missing token"'
check "deny reason: names msg.mjs new --to implementor" 'echo "$OUT" | grep -q "msg.mjs.* new --to implementor --from orchestrator"'
check "deny reason: says missing token" 'echo "$OUT" | grep -q "missing token"'
check "deny reason: 3 numbered steps" 'echo "$OUT" | grep -q "3\. Re-issue this exact dispatch"'
agent ah:implementor "[hierarchy-msg $HD/msgs/20990101-000000-zzzz--implementor--nope--request.md]
tldr"
check "Agent: token to a missing file -> deny (path not found)" 'denied && echo "$OUT" | grep -q "path not found"'
agent ah:implementor "[hierarchy-msg $REV_REQ]
tldr"
check "Agent implementor with reviewer's request -> deny wrong to:" 'denied && echo "$OUT" | grep -q "wrong to: (file says reviewer, dispatch is implementor)"'
agent ah:reviewer "[hierarchy-msg $REV_RESP]
tldr"
check "Agent: response file used as request -> deny (not a request file)" 'denied && echo "$OUT" | grep -q "not a request file"'
cp "$IMPL_REQ" "$SANDBOX/outside--request.md"
agent ah:implementor "[hierarchy-msg $SANDBOX/outside--request.md]"
check "Agent: request file outside <dir>/msgs -> deny" 'denied'
check "deny reason: names the pool searched, and does not blame the file's content" \
  'echo "$OUT" | grep -qF "message pool ($HD/msgs)" && ! echo "$OUT" | grep -q "not a request file"'
agent ah:implementor "[hierarchy-msg $IMPL_REQ]
- implement impl-task; see file"
check "Agent implementor with valid file -> allow (silent)" 'allowed'
agent implementor "[hierarchy-msg $IMPL_REQ]"
check "bare subagent_type also checked and passes with valid file" 'allowed'
agent implementor "no token here"
check "bare subagent_type without token -> deny" 'denied'
agent task-gopher:task-gopher "run the tests and report"
check "task-gopher exempt" 'allowed'
agent ah:task-runner "run the tests"
check "task-runner exempt" 'allowed'
agent general-purpose "anything"
check "foreign subagent type passes" 'allowed'
agent ah:implementor "no token" "sub1"
check "subagent context (agent_id set) passes" 'allowed'

# ---- 2: SendMessage
send rev-peer "hello, are you there?"
check "SendMessage without sentinel passes" 'allowed'
send rev-peer '[hierarchy-peer-brief reply-to="sender" task="rev-task"]
please review /tmp/spec.md and report back'
check "SendMessage with sentinel + no token -> deny" 'denied && echo "$OUT" | grep -q "missing token"'
check "deny reason: names the resolved role for that peer" 'echo "$OUT" | grep -q "new --to reviewer"'
send "rev-peer [ab12]" "[hierarchy-peer-brief reply-to=\"sender\" task=\"rev-task\"]
[hierarchy-msg $REV_REQ]
- review it"
check "SendMessage brief with valid file (to has [ref]) -> allow" 'allowed'
send "rev-peer" "[hierarchy-peer-brief reply-to=\"sender\" task=\"x\"]
[hierarchy-msg $IMPL_REQ]"
check "SendMessage brief to reviewer peer with implementor's file -> deny wrong to:" 'denied && echo "$OUT" | grep -q "wrong to:"'
send "some-unrelated-session" "[hierarchy-peer-brief reply-to=\"sender\" task=\"x\"]
[hierarchy-msg $IMPL_REQ]"
check "SendMessage brief to a non-configured peer: role check skipped, file valid -> allow" 'allowed'
send "some-unrelated-session" "[hierarchy-peer-brief reply-to=\"sender\" task=\"x\"] no file"
check "SendMessage brief to a non-configured peer without token -> still denied" 'denied'

# ---- 2b: a request names its team file, so a session whose cwd-derived pool is elsewhere still passes
cat > "$HD/team.json" <<EOF
{ "team_id": "t1", "roster_level": null, "members": [ { "role": "reviewer", "name": "rev-peer" } ] }
EOF
msg new --to reviewer --from orchestrator --slug drift-task --to-name rev-peer
DRIFT_REQ=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).path)' "$OUT")
fill_intent "$DRIFT_REQ"
check "request frontmatter names the team file by absolute path" 'grep -qxF "team_file: $HD/team.json" "$DRIFT_REQ"'
check "request frontmatter names the team-file guide, and the guide exists" \
  'G=$(sed -n "s/^team_guide: //p" "$DRIFT_REQ"); [ -n "$G" ] && [ -f "$G" ]'
check "a request written with no team file says so" 'grep -qx "team_file: null" "$IMPL_REQ"'
DRIFT_BRIEF="[hierarchy-peer-brief reply-to=\"sender\" task=\"drift-task\"]
[hierarchy-msg $DRIFT_REQ]"
OUT=$(PROJ="$PROJ" send_payload rev-peer "$DRIFT_BRIEF" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$SANDBOX/elsewhere" node "$GATE" 2>&1); RC=$?
check "pool resolved elsewhere, request beside its named team file -> allow" 'allowed'
cp "$DRIFT_REQ" "$SANDBOX/20990101-000000-abcd--reviewer--stray--request.md"
send rev-peer "[hierarchy-peer-brief reply-to=\"sender\" task=\"x\"]
[hierarchy-msg $SANDBOX/20990101-000000-abcd--reviewer--stray--request.md]"
check "a request naming a team file it does not sit beside -> still denied" 'denied && echo "$OUT" | grep -qF "message pool ("'
rm -f "$HD/team.json"

# ---- 3: msgs:"off" disables; malformed input fails open; disabled hierarchy passes
cat > "$PROJ/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "enabled": true, "msgs": "off", "roles": {} }
EOF
agent ah:implementor "no token"
check "msgs:off -> gate disabled" 'allowed'
cat > "$PROJ/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "enabled": true, "msgs": "sometimes", "roles": {} }
EOF
agent ah:implementor "no token"
check "msgs invalid value -> falls back to required (denies)" 'denied'
cat > "$PROJ/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "enabled": false, "roles": {} }
EOF
agent ah:implementor "no token"
check "enabled:false -> passes" 'allowed'
cat > "$PROJ/.claude/agent-hierarchy.json" <<EOF
{ "version": 1, "enabled": true, "roles": {} }
EOF
OUT=$(echo "not json" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$GATE" 2>&1); RC=$?
check "malformed stdin fails open" 'allowed'
OUT=$(echo '{"tool_name":"Agent","tool_input":"nope"}' | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$GATE" 2>&1); RC=$?
check "non-object tool_input fails open" 'allowed'
OUT=$(echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$GATE" 2>&1); RC=$?
check "other tools pass" 'allowed'

# ---- 5: the review-class intent check (goal and acceptance must be stated)
mkreq_to() { msg new --to "$1" --from orchestrator --slug "$2"; node -e 'process.stdout.write(JSON.parse(process.argv[1]).path)' "$OUT"; }
fill_sections() { # <path>: puts text in the goal and acceptance sections only
  node -e 'const fs=require("fs");const p=process.argv[1];fs.writeFileSync(p,fs.readFileSync(p,"utf8").replace("## [1] goal\n- none","## [1] goal\n- what it must deliver").replace("## [5] acceptance\n- none","## [5] acceptance\n- the checks pass"))' "$1"; }
send_nosent() { OUT=$(PROJ="$PROJ" node -e 'const[t,m]=process.argv.slice(1);process.stdout.write(JSON.stringify({session_id:"s1",cwd:process.env.PROJ,tool_name:"SendMessage",tool_input:{to:t,message:m,notify_when_idle:true}}));' "$1" "$2" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$GATE" 2>&1); RC=$?; }
missing() { denied && echo "$OUT" | grep -qF "ah: a Reviewer brief needs its intent." && echo "$OUT" | grep -qF "Missing: $1."; }

EMPTY_REV=$(mkreq_to reviewer h-empty)
H1=$(mkreq_to reviewer h1); fill_intent "$H1"
agent ah:reviewer "[hierarchy-msg $H1]"
check "H1: reviewer request, intent on the tldr lines only -> allow" 'allowed'
H2=$(mkreq_to reviewer h2); fill_sections "$H2"
agent ah:reviewer "[hierarchy-msg $H2]"
check "H2: reviewer request, intent in the sections only -> allow" 'allowed'
agent ah:reviewer "[hierarchy-msg $EMPTY_REV]"
check "H3: reviewer request, goal and acceptance blank -> deny, both named" 'missing "goal, acceptance"'
check "H3: the hold message is the quiet one-liner" 'echo "$OUT" | grep -qF "held a Reviewer dispatch until its brief states the intent; it will be re-sent."'
H3=$(mkreq_to reviewer h3); fill_intent "$H3" "" "the checks pass"
agent ah:reviewer "[hierarchy-msg $H3]"
check "H3: goal blank in both places -> deny, Missing: goal" 'missing "goal"'
H4=$(mkreq_to reviewer h4); fill_intent "$H4" "what it must deliver" "n/a"
agent ah:reviewer "[hierarchy-msg $H4]"
check "H4: acceptance n/a -> deny, Missing: acceptance" 'missing "acceptance"'
agent ah:implementor "[hierarchy-msg $IMPL_REQ]"
check "H5: implementor request with an empty goal -> allow (not review-class)" 'allowed'
H11=$(mkreq_to ultra-advisor h11)
agent ah:ultra-advisor "[hierarchy-msg $H11]"
check "H11: ultra-advisor request with an empty goal -> allow (not review-class)" 'allowed'
agent ah:reviewer "[hierarchy-msg $EMPTY_REV]" sub1
check "H8: subagent context, empty goal -> allow (exemption)" 'allowed'
H10=$(mkreq_to reviewer h10); fill_intent "$H10" "see spec"
agent ah:reviewer "[hierarchy-msg $H10]"
check "H10: goal 'see spec', acceptance filled -> allow (thin goal is the Reviewer's NEEDS-INTENT)" 'allowed'
agent ah:reviewer "[hierarchy-msg $HD/msgs/20990101-000000-zzzz--reviewer--gone--request.md]"
check "H12: request file gone -> the existing path-not-found deny, not the intent hold" 'denied && echo "$OUT" | grep -q "path not found" && ! echo "$OUT" | grep -q "needs its intent"'
agent ah:reviewer "[hierarchy-msg $EMPTY_REV]"
check "the intent hold re-checks every attempt (still held)" 'missing "goal, acceptance"'
fill_intent "$EMPTY_REV"
agent ah:reviewer "[hierarchy-msg $EMPTY_REV]"
check "the intent hold lifts at once when the file is filled" 'allowed'

# no-sentinel sends that name a request
H13=$(mkreq_to reviewer h13); fill_intent "$H13" "" "the checks pass"
send_nosent "uds:/tmp/cc-socks/1.sock" "[hierarchy-msg $H13] review it"
check "H13: no-sentinel send to a uds: address naming a reviewer request with an empty goal -> deny" 'missing "goal"'
H14=$(mkreq_to reviewer h14); fill_intent "$H14"
send_nosent "uds:/tmp/cc-socks/1.sock" "[hierarchy-msg $H14] review it"
check "H14: same, goal and acceptance filled -> allow" 'allowed'
H15=$(mkreq_to architect h15)
send_nosent "uds:/tmp/cc-socks/1.sock" "[hierarchy-msg $H15] design it"
check "H15: no-sentinel send naming an architect request with an empty goal -> allow" 'allowed'
RESP_ONLY=$(mkreq_to reviewer h16); msg new --type response --id "$(basename "$RESP_ONLY" | cut -d- -f1-3)"; H16=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).path)' "$OUT")
send_nosent "uds:/tmp/cc-socks/1.sock" "[hierarchy-msg $H16] done"
check "H16: no-sentinel send naming a --response.md -> allow (not a request)" 'allowed'
send_nosent "uds:/tmp/cc-socks/1.sock" "[hierarchy-msg $HD/msgs/20990101-000000-zzzz--reviewer--gone--request.md] go"
check "H17: no-sentinel send naming a missing request path -> allow (as today)" 'allowed'
send_nosent "uds:/tmp/cc-socks/1.sock" "[hierarchy-msg $H15] design it, then [hierarchy-msg $H13]"
check "H22: first token an architect request, a reviewer request with an empty goal later -> allow (first token only)" 'allowed'
send_nosent "rev-peer" "hello, are you there?"
check "H9: ping to a Reviewer peer with no [hierarchy-msg] token -> allow" 'allowed'
H21=$(mkreq_to reviewer h21); fill_intent "$H21" ""; sed -i.bak 's/^to: reviewer$/to: no-such-role/' "$H21"; rm -f "$H21.bak"
send_nosent "uds:/tmp/cc-socks/1.sock" "[hierarchy-msg $H21]"
check "H21: request whose to: is a role the config does not know -> allow (no class, not review)" 'allowed'

# H18: the existing notify hold comes first; the intent hold only after it
H18=$(mkreq_to reviewer h18)
OUT=$(PROJ="$PROJ" node -e 'const[t,m]=process.argv.slice(1);process.stdout.write(JSON.stringify({session_id:"s1",cwd:process.env.PROJ,tool_name:"SendMessage",tool_input:{to:t,message:m}}));' "rev-peer" "[hierarchy-peer-brief reply-to=\"sender\" task=\"h18\"]
[hierarchy-msg $H18]" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$GATE" 2>&1); RC=$?
check "H18: sentinel brief to a Reviewer without notify_when_idle -> the existing notify hold first" 'denied && echo "$OUT" | grep -q "notify_when_idle" && ! echo "$OUT" | grep -q "needs its intent"'
send rev-peer "[hierarchy-peer-brief reply-to=\"sender\" task=\"h18\"]
[hierarchy-msg $H18]"
check "H18: with notify_when_idle, the intent hold" 'missing "goal, acceptance"'

# custom review-class role, and the opt-outs
CPROJ="$SANDBOX/customrepo"; mkdir -p "$CPROJ/.claude"
echo '{ "version": 1, "enabled": true, "roles": { "auditor": { "class": "review", "description": "Audits." } } }' > "$CPROJ/.claude/agent-hierarchy.json"
PROJ0=$PROJ; PROJ=$CPROJ
msg new --to auditor --from orchestrator --slug h6; H6=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).path)' "$OUT")
send_nosent "uds:/tmp/cc-socks/1.sock" "[hierarchy-msg $H6]"
check "H6: custom review-class role request, goal empty -> deny, as for the reviewer" 'missing "goal, acceptance"'
PROJ=$PROJ0
OFFPROJ="$SANDBOX/offrepo"; mkdir -p "$OFFPROJ/.claude"
echo '{ "version": 1, "enabled": true, "msgs": "off", "roles": { "reviewer": { "model": "opus", "dispatch": "peer", "peer": "rev-peer" } } }' > "$OFFPROJ/.claude/agent-hierarchy.json"
PROJ=$OFFPROJ
H7=$(mkreq_to reviewer h7)
agent ah:reviewer "[hierarchy-msg $H7]"
check "H7: msgs off, Reviewer request with an empty goal -> allow (exemption)" 'allowed'
send_nosent "uds:/tmp/cc-socks/1.sock" "[hierarchy-msg $H7]"
check "H7b: msgs off, no-sentinel send naming an empty reviewer request -> allow (exemption)" 'allowed'
DISPROJ="$SANDBOX/disabledrepo"; mkdir -p "$DISPROJ/.claude"
echo '{ "version": 1, "enabled": false, "roles": { "reviewer": { "model": "opus", "dispatch": "peer", "peer": "rev-peer" } } }' > "$DISPROJ/.claude/agent-hierarchy.json"
PROJ=$DISPROJ
send_nosent "uds:/tmp/cc-socks/1.sock" "[hierarchy-msg $H7]"
check "H7c: hierarchy disabled, no-sentinel send naming an empty reviewer request -> allow (exemption)" 'allowed'
PROJ=$PROJ0

# ---- 4: exactly one stdout write site
check "pretooluse-msg-gate.mjs writes to stdout exactly once" '[ "$(grep -c "process.stdout.write" "$GATE")" -eq 1 ]'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
