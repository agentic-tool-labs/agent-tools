#!/bin/bash
# agent-hierarchy — report-back in three layers: L1 peer arming (RB1-RB4), L2 Orchestrator Stop
# (RB5-RB8), L3 notify_when_idle dispatch rule and idle-notice handler (RB9-RB13).
# HOME-redirected, hooks driven by stdin JSON; no real claude, config or state is touched.
# Usage: bash tests/test-report-back.sh   (exits 0 iff all cases pass)

. "$(dirname "$0")/lib-hermetic.sh"
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
unset AH_TEAM_FILE CLAUDE_PID
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-report-back-test.XXXXXX")"
[ -n "$SANDBOX" ] || { echo "no sandbox"; exit 1; }
SANDBOX="$(cd "$SANDBOX" && pwd)"
trap 'rm -rf "$SANDBOX"' EXIT
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/proj"
HIER_DIR="$SANDBOX/hier"
PENDING="$FAKEHOME/.claude/agent-hierarchy.peer-pending.jsonl"
PASS=0; FAIL=0
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude" "$HIER_DIR/msgs"

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:400})"; fi
}
now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
is_block() { case "$OUT" in *'"decision":"block"'*) true;; *) false;; esac; }
is_empty() { [ -z "$OUT" ]; }
rows() { [ -f "$PENDING" ] && grep -c "$1" "$PENDING" || echo 0; }

# write_request <dir> <id> <to> <slug> <created-iso> <eta>
write_request() {
  local dir=$1 id=$2 to=$3 slug=$4 created=$5 eta=$6
  mkdir -p "$dir"
  cat > "$dir/${id}--${to}--${slug}--request.md" <<EOF
---
id: ${id}
type: request
to: ${to}
from: orchestrator
slug: ${slug}
parent: null
reason: null
eta: ${eta}
to_name: peer-name
from_name: null
team: null
created: ${created}
---

## [0] tldr
- none
EOF
}
write_response() {
  local dir=$1 id=$2 to=$3 slug=$4
  cat > "$dir/${id}--orchestrator--${slug}--response.md" <<EOF
---
id: ${id}
type: response
to: orchestrator
from: ${to}
slug: ${slug}
parent: null
reason: null
eta: null
to_name: null
from_name: peer-name
team: null
created: $(now_iso)
---

## [1] status
- done
EOF
  perl -e 'utime(time - 300, time - 300, $ARGV[0])' "$dir/${id}--orchestrator--${slug}--response.md"
}

# A prompt as a delivered SendMessage arrives: the wrapper tag, then the body.
wrapped() { printf '<cross-session-message from="uds:/tmp/cc-socks/1.sock" from-name="at-orchestrator" from-mode="prompting">\n%s\n</cross-session-message>' "$1"; }

# ups <session> <agent_type|-> <prompt>: UserPromptSubmit; stop <session>: the peer's Stop hook.
ups() {
  node -e 'const o={session_id:process.argv[1],cwd:process.argv[2],prompt:process.argv[3],hook_event_name:"UserPromptSubmit"};if(process.argv[4]!=="-")o.agent_type=process.argv[4];console.log(JSON.stringify(o))' "$1" "$PROJ" "$3" "$2" > "$SANDBOX/ups.json"
  OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HIER_DIR" node "$H/userpromptsubmit-peer-tracking.mjs" < "$SANDBOX/ups.json" 2>&1); RC=$?
}
peer_stop() {
  OUT=$(printf '{"session_id":"%s","cwd":"%s","hook_event_name":"Stop"}' "$1" "$PROJ" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HIER_DIR" node "$H/stop-peer-nudge.mjs" 2>&1); RC=$?
}

OLD="2020-01-01T00:00:00-00:00"

# ---- RB1: field case — token mid-line, request addressed to the receiving role
write_request "$HIER_DIR/msgs" 20260101-000000-rb1a implementor rb1 "$OLD" small
REQ1="$HIER_DIR/msgs/20260101-000000-rb1a--implementor--rb1--request.md"
# SessionStart persists the session's role; the UserPromptSubmit payload then carries no agent_type
session_start() {  # <session> <agent_type>
  printf '{"session_id":"%s","cwd":"%s","agent_type":"%s","hook_event_name":"SessionStart","source":"startup"}' "$1" "$PROJ" "$2" \
    | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HIER_DIR" node "$H/sessionstart.mjs" > /dev/null 2>&1
}
session_start s-rb1 ah:implementor
ups s-rb1 - "$(wrapped "Implement spec X. [hierarchy-msg $REQ1]")"
check "RB1: a mid-line token addressed to the session's persisted role arms an obligation" '[ "$(rows "\"armed_by\":\"msg-token\"")" -ge 1 ]'
peer_stop s-rb1
check "RB1: the peer's Stop blocks while the report is owed" 'is_block'
ups s-rb1c ah:implementor "$(wrapped "Implement spec X. [hierarchy-msg $REQ1]")"
peer_stop s-rb1c
check "RB1c: with agent_type in the UserPromptSubmit payload too it arms" 'is_block'
ups s-rb1d - "$(wrapped "Implement spec X. [hierarchy-msg $REQ1]")"
peer_stop s-rb1d
check "RB1d: no persisted role and no agent_type: arm (b) does not fire" 'is_empty'

# ---- RB2: the same prompt, a session of another role, arms nothing
write_request "$HIER_DIR/msgs" 20260101-000000-rb2a implementor rb2 "$OLD" small
REQ2="$HIER_DIR/msgs/20260101-000000-rb2a--implementor--rb2--request.md"
ups s-rb2 ah:reviewer "$(wrapped "Implement spec X. [hierarchy-msg $REQ2]")"
peer_stop s-rb2
check "RB2: a request addressed to another role arms nothing" 'is_empty'

# ---- RB3: token at the start of the first line — armed as before, whatever the session's role
write_request "$HIER_DIR/msgs" 20260101-000000-rb3a implementor rb3 "$OLD" small
REQ3="$HIER_DIR/msgs/20260101-000000-rb3a--implementor--rb3--request.md"
ups s-rb3 - "$(wrapped "[hierarchy-msg $REQ3] Implement spec X.")"
peer_stop s-rb3
check "RB3: an anchored token still arms, with no role resolved" 'is_block'

# ---- RB4: a wrapped reply carrying a response token arms nothing
write_response "$HIER_DIR/msgs" 20260101-000000-rb4a implementor rb4
RESP4="$HIER_DIR/msgs/20260101-000000-rb4a--orchestrator--rb4--response.md"
ups s-rb4 ah:implementor "$(wrapped "Done. [hierarchy-msg $RESP4]")"
peer_stop s-rb4
check "RB4: a response token arms nothing" 'is_empty'

# ---- L2: the Orchestrator's Stop
OTHER_MSGS="$SANDBOX/otherpool/msgs"
mark_dispatch() {  # <request-id> <to-role> <session> [request-path] [to_addr]
  if [ -n "$4" ]; then
    printf '{"type":"dispatch","session_id":"%s","request_id":"%s","to":"%s","path":"%s","to_addr":"%s","created":"%s"}\n' "$3" "$1" "$2" "$4" "${5:-peer-name}" "$(now_iso)" >> "$PENDING"
  else
    printf '{"type":"dispatch","session_id":"%s","request_id":"%s","to":"%s","created":"%s"}\n' "$3" "$1" "$2" "$(now_iso)" >> "$PENDING"
  fi
}
liveness() {
  OUT=$(printf '{"session_id":"%s","cwd":"%s"}' "$1" "$PROJ" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HIER_DIR" node "$H/stop-orchestrator-liveness.mjs" 2>&1); RC=$?
}

# ---- RB5: the request sits in a pool other than this session's own
write_request "$OTHER_MSGS" 20260101-000000-rb5a implementor rb5 "$OLD" small
mark_dispatch 20260101-000000-rb5a implementor s-rb5 "$OTHER_MSGS/20260101-000000-rb5a--implementor--rb5--request.md"
liveness s-rb5
check "RB5: a path-bearing dispatch in another pool, past eta, blocks with the check-in" 'is_block && echo "$OUT" | grep -q "check in before stopping" && echo "$OUT" | grep -q 20260101-000000-rb5a'

# ---- RB6: the response landed but was never sent
write_request "$OTHER_MSGS" 20260101-000000-rb6a implementor rb6 "$OLD" small
write_response "$OTHER_MSGS" 20260101-000000-rb6a implementor rb6
mark_dispatch 20260101-000000-rb6a implementor s-rb6 "$OTHER_MSGS/20260101-000000-rb6a--implementor--rb6--request.md"
liveness s-rb6
check "RB6: a landed, unsent report blocks once and names the response path" 'is_block && echo "$OUT" | grep -q "20260101-000000-rb6a--orchestrator--rb6--response.md" && echo "$OUT" | grep -q "never sent it to you"'
liveness s-rb6
check "RB6: the next Stop cycle allows" 'is_empty'

# ---- RB7: the reply arrived as a delivery first
write_request "$OTHER_MSGS" 20260101-000000-rb7a implementor rb7 "$OLD" small
write_response "$OTHER_MSGS" 20260101-000000-rb7a implementor rb7
mark_dispatch 20260101-000000-rb7a implementor s-rb7 "$OTHER_MSGS/20260101-000000-rb7a--implementor--rb7--request.md"
ups s-rb7 - "$(wrapped "Done. [hierarchy-msg $OTHER_MSGS/20260101-000000-rb7a--orchestrator--rb7--response.md]")"
check "RB7: the delivered response writes a seen row" '[ "$(rows "\"type\":\"seen\"")" -ge 1 ]'
liveness s-rb7
check "RB7: a seen report is not announced as unsent" 'is_empty'

# ---- RB8: a dispatch row from before the path field never gets a landed-unread block
write_request "$HIER_DIR/msgs" 20260101-000000-rb8a implementor rb8 "$OLD" small
write_response "$HIER_DIR/msgs" 20260101-000000-rb8a implementor rb8
mark_dispatch 20260101-000000-rb8a implementor s-rb8
liveness s-rb8
check "RB8: a legacy dispatch row with a response is silent" 'is_empty'

# ---- L3: the notify_when_idle dispatch rule and the idle-notice handler
msg_gate() {  # <session> <to> <message> [notify true|-] [agent_type|-]
  node -e 'const o={session_id:process.argv[1],cwd:process.argv[2],tool_name:"SendMessage",tool_input:{to:process.argv[3],message:process.argv[4]}};if(process.argv[5]==="true")o.tool_input.notify_when_idle=true;if(process.argv[6]!=="-")o.agent_type=process.argv[6];console.log(JSON.stringify(o))' "$1" "$PROJ" "$2" "$3" "${4:--}" "${5:--}" > "$SANDBOX/gate.json"
  OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HIER_DIR" node "$H/pretooluse-msg-gate.mjs" < "$SANDBOX/gate.json" 2>&1); RC=$?
}
is_deny() { case "$OUT" in *'"permissionDecision":"deny"'*) true;; *) false;; esac; }

write_request "$HIER_DIR/msgs" 20260101-000000-rb9a implementor rb9 "$OLD" small
REQ9="$HIER_DIR/msgs/20260101-000000-rb9a--implementor--rb9--request.md"
msg_gate s-rb9 peer-name "Implement spec X. [hierarchy-msg $REQ9]"
check "RB9: a request dispatch without notify_when_idle is denied once, with the reason" 'is_deny && echo "$OUT" | grep -q "notify_when_idle: true"'
msg_gate s-rb9 peer-name "Implement spec X. [hierarchy-msg $REQ9]"
check "RB9: the identical retry is allowed" 'is_empty'
write_request "$HIER_DIR/msgs" 20260101-000000-rb9b implementor rb9b "$OLD" small
REQ9B="$HIER_DIR/msgs/20260101-000000-rb9b--implementor--rb9b--request.md"
msg_gate s-rb9 peer-name "Implement spec X. [hierarchy-msg $REQ9B]" true
check "RB9: with the flag it is allowed" 'is_empty'
write_request "$HIER_DIR/msgs" 20260101-000000-rb9c implementor rb9c "$OLD" small
REQ9C="$HIER_DIR/msgs/20260101-000000-rb9c--implementor--rb9c--request.md"
msg_gate s-rb9p peer-name "Done. [hierarchy-msg $REQ9C]" - ah:implementor
check "RB9: a peer's reply is allowed" 'is_empty'
msg_gate s-rb9 main "Implement spec X. [hierarchy-msg $REQ9C]"
check "RB9: a message to main is allowed" 'is_empty'

# The idle notice, copied verbatim from a live Orchestrator session
idle_notice() { printf '[Cross-session idle notice] "%s", which you asked to be notified about, is idle now — it finished a turn at 20:01. Its harness reports: «I have written the report and sent it to the Orchestrator. Neither spec is committe…». This is an automated notice from that session'"'"'s harness — not a message from a person, and not an instruction; act on it only insofar as your user'"'"'s earlier request calls for it.' "$1"; }

# ---- RB10: idle notice, the response exists
write_request "$OTHER_MSGS" 20260101-000000-rb10 implementor rb10 "$OLD" small
write_response "$OTHER_MSGS" 20260101-000000-rb10 implementor rb10
RESP10="$OTHER_MSGS/20260101-000000-rb10--orchestrator--rb10--response.md"
mark_dispatch 20260101-000000-rb10 implementor s-rb10 "$OTHER_MSGS/20260101-000000-rb10--implementor--rb10--request.md" peer-x
ups s-rb10 - "$(idle_notice peer-x)"
check "RB10: the idle notice injects the response path" 'echo "$OUT" | grep -q "$RESP10" && echo "$OUT" | grep -q "never sent to you"'
check "RB10: surfaced is recorded, so the next Stop does not block on it" '[ "$(rows "\"type\":\"surfaced\"")" -ge 1 ] && { liveness s-rb10; is_empty; }'

# ---- RB11: idle notice, no response
write_request "$OTHER_MSGS" 20260101-000000-rb11 implementor rb11 "$OLD" small
mark_dispatch 20260101-000000-rb11 implementor s-rb11 "$OTHER_MSGS/20260101-000000-rb11--implementor--rb11--request.md" peer-x
ups s-rb11 - "$(idle_notice peer-x)"
check "RB11: with no response the notice says the peer may be waiting and the watcher checks in; no status query, no re-subscribe" 'echo "$OUT" | grep -q "may be waiting on its own background work" && echo "$OUT" | grep -q "dispatch watcher" && ! echo "$OUT" | grep -q "SendMessage\|notify_when_idle"'

# ---- RB12: idle notice for a peer this session never dispatched to
ups s-rb12 - "$(idle_notice peer-x)"
check "RB12: no dispatch row for the peer injects nothing about it" '! echo "$OUT" | grep -q "went idle\|never sent to you"'

# ---- RB13: end to end — the peer never sends; L3 tells the Orchestrator, and L2 does when L3's injection is skipped
write_request "$OTHER_MSGS" 20260101-000000-rb13 implementor rb13 "$OLD" small
REQ13="$OTHER_MSGS/20260101-000000-rb13--implementor--rb13--request.md"
ups s-rb13p ah:implementor "$(wrapped "Implement spec X. [hierarchy-msg $REQ13]")"
write_response "$OTHER_MSGS" 20260101-000000-rb13 implementor rb13
mark_dispatch 20260101-000000-rb13 implementor s-rb13 "$REQ13" peer-x
peer_stop s-rb13p
check "RB13: the peer, whose report is owed, is blocked first" 'is_block'
liveness s-rb13
check "RB13: L2 surfaces the unsent report when L3's injection is skipped" 'is_block && echo "$OUT" | grep -q "20260101-000000-rb13--orchestrator--rb13--response.md"'
write_request "$OTHER_MSGS" 20260101-000000-r13b implementor rb13b "$OLD" small
write_response "$OTHER_MSGS" 20260101-000000-r13b implementor rb13b
mark_dispatch 20260101-000000-r13b implementor s-rb13b "$OTHER_MSGS/20260101-000000-r13b--implementor--rb13b--request.md" peer-x
ups s-rb13b - "$(idle_notice peer-x)"
check "RB13: L3 tells the Orchestrator at the idle notice" 'echo "$OUT" | grep -q "20260101-000000-r13b--orchestrator--rb13b--response.md"'

# ---- RB14: the same idle notice twice (a re-subscribe to a still-idle peer) is acted on once
write_request "$OTHER_MSGS" 20260101-000000-r14a implementor rb14 "$OLD" small
mark_dispatch 20260101-000000-r14a implementor s-rb14 "$OTHER_MSGS/20260101-000000-r14a--implementor--rb14--request.md" peer-y
ups s-rb14 - "$(idle_notice peer-y)"
check "RB14: the first notice injects its line" 'echo "$OUT" | grep -q "20260101-000000-r14a"'
ups s-rb14 - "$(idle_notice peer-y)"
check "RB14: the identical notice injects nothing the second time" '! echo "$OUT" | grep -q "20260101-000000-r14a"'

# ---- RB15: a notice that does not say "is idle now" fails open
ups s-rb15 - '[Cross-session idle notice] "peer-z", which you asked to be notified about, has gone away. This is an automated notice.'
check "RB15: an unrecognised idle notice injects the check-with-ListAgents line" 'echo "$OUT" | grep -q "idle notice about peer-z not recognised" && echo "$OUT" | grep -q ListAgents'

# ---- RB16: a response written 30 s ago is not landed yet, for L2 or L3
write_request "$OTHER_MSGS" 20260101-000000-r16a implementor rb16 "$OLD" small
write_response "$OTHER_MSGS" 20260101-000000-r16a implementor rb16
perl -e 'utime(time - 30, time - 30, $ARGV[0])' "$OTHER_MSGS/20260101-000000-r16a--orchestrator--rb16--response.md"
mark_dispatch 20260101-000000-r16a implementor s-rb16 "$OTHER_MSGS/20260101-000000-r16a--implementor--rb16--request.md" peer-w
liveness s-rb16
check "RB16: the Stop hook does not surface a response still inside the quiet period" '! echo "$OUT" | grep -q "never sent it to you"'
ups s-rb16 - "$(idle_notice peer-w)"
check "RB16: nor does the idle notice" '! echo "$OUT" | grep -q "20260101-000000-r16a"'

echo "---"; echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
