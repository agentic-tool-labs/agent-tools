#!/bin/bash
# agent-hierarchy — member_sessions answers "is this session a team member" whatever the member's liveness (S8-S12), and a
# running member whose latest roster row is a false `down` re-registers at its next prompt or stop, only from the process
# that registered it (S14-S22). Every write lands in a sandbox pool; the hook runs as a child of a wrapper whose pid is the
# registered pid (or another one).
# Usage: bash tests/test-member-sessions.sh   (exits 0 iff all cases pass)

. "$(dirname "$0")/lib-hermetic.sh"
unset AH_TEAM_FILE  # every session roster.mjs launches carries one; a test must not inherit it
unset CLAUDE_PID  # every Claude session exports one; a test must not inherit it

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
. "$PLUGIN/tests/lib-status-pool.sh"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-member-sessions-test.XXXXXX")"
[ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] || { echo "mktemp failed"; exit 1; }
hermetic_on_exit 'rm -rf "$SANDBOX"'
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (OUT=${OUT:0:300})"; fi
}

# ---- S8-S12: member_sessions
pool "$SANDBOX/p"
OLD="2020-01-01T00:00:00.000Z"
row() { printf '%s\n' "$1" >> "$HD/peers.jsonl"; }
mem() { printf '{"role":"%s","name":"%s","route":"peer","kind":"claude","transport_id":"%s"}' "$1" "$2" "$3"; }
status() { (cd "$SANDBOX" && HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/roster.mjs" status --cwd "$PROJ" >/dev/null 2>&1); }
ms() { node -e 'try { const o = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); console.log(JSON.stringify(o.member_sessions)); } catch { console.log("none"); }' "$HD/status.json"; }
live_of() { node -e 'try { const o = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); console.log(JSON.stringify(o.teams[0].members.find((m) => m.name === process.argv[2]).live)); } catch { console.log("none"); }' "$HD/status.json" "$1"; }

# S8: a member whose latest record is a down
team - "[$(mem implementor demo-down w1:p1)]"
row "{\"type\":\"peer\",\"status\":\"up\",\"role\":\"implementor\",\"session_id\":\"sess-down\",\"pid\":$$,\"pane_id\":\"w1:p1\",\"ts\":\"$OLD\"}"
row "{\"type\":\"peer\",\"status\":\"down\",\"role\":\"implementor\",\"session_id\":\"sess-down\",\"pid\":$$,\"pane_id\":\"w1:p1\",\"ts\":\"2020-01-01T00:00:01.000Z\"}"
status; OUT=$(ms)
check "S8: a member whose latest record is down is not live, and its session id is in member_sessions" '[ "$(live_of demo-down)" = false ] && [ "$OUT" = "[\"sess-down\"]" ]'

# S9: a member whose latest record is a stale seen
rm -f "$HD/peers.jsonl"
team - "[$(mem reviewer demo-seen w1:p2)]"
row "{\"type\":\"peer\",\"status\":\"seen\",\"name\":\"demo-seen\",\"role\":\"reviewer\",\"session_id\":\"sess-seen\",\"ts\":\"$OLD\"}"
status; OUT=$(ms)
check "S9: a member whose latest record is a seen older than the fresh window is not live, and its session id is listed" '[ "$(live_of demo-seen)" = false ] && [ "$OUT" = "[\"sess-seen\"]" ]'
rm -f "$HD/peers.jsonl"
row "{\"type\":\"peer\",\"status\":\"briefed\",\"name\":\"demo-seen\",\"role\":\"reviewer\",\"session_id\":\"sess-brief\",\"ts\":\"$OLD\"}"
status; OUT=$(ms)
check "S9: and so is a stale briefed" '[ "$OUT" = "[\"sess-brief\"]" ]'

# S10: nothing to list
rm -f "$HD/peers.jsonl"
team - "[$(mem reviewer demo-seen w1:p2)]"
status; OUT=$(ms)
check "S10: a member with no roster record contributes nothing" '[ "$OUT" = "[]" ]'
for sid in '""' 'null' '123' '["x"]'; do
  rm -f "$HD/peers.jsonl"
  row "{\"type\":\"peer\",\"status\":\"seen\",\"name\":\"demo-seen\",\"role\":\"reviewer\",\"session_id\":$sid,\"ts\":\"$OLD\"}"
  status; OUT=$(ms)
  check "S10: a latest record whose session_id is $sid contributes nothing, and nothing throws" '[ "$OUT" = "[]" ]'
done
rm -f "$HD/peers.jsonl"
row "{\"type\":\"peer\",\"status\":\"seen\",\"name\":\"demo-seen\",\"role\":\"reviewer\",\"ts\":\"$OLD\"}"
status; OUT=$(ms)
check "S10: a latest record with no session_id contributes nothing" '[ "$OUT" = "[]" ]'

# S11: an orchestrator session that is no member
rm -f "$HD/peers.jsonl"
team - "[$(mem implementor demo-down w1:p1)]"
row "{\"type\":\"peer\",\"status\":\"up\",\"role\":\"orchestrator\",\"session_id\":\"sess-orch\",\"pid\":$$,\"pane_id\":\"w9:p9\",\"ts\":\"$OLD\"}"
row "{\"type\":\"peer\",\"status\":\"down\",\"role\":\"implementor\",\"session_id\":\"sess-down\",\"pid\":$$,\"pane_id\":\"w1:p1\",\"ts\":\"$OLD\"}"
status; OUT=$(ms)
check "S11: a session that is no team member is not in member_sessions, whatever its own records" '[ "$OUT" = "[\"sess-down\"]" ]'

# S12: a restart lists only the new session
rm -f "$HD/peers.jsonl"
row "{\"type\":\"peer\",\"status\":\"up\",\"role\":\"implementor\",\"session_id\":\"sess-old\",\"pid\":$$,\"pane_id\":\"w1:p1\",\"ts\":\"2020-01-01T00:00:00.000Z\"}"
row "{\"type\":\"peer\",\"status\":\"down\",\"role\":\"implementor\",\"session_id\":\"sess-old\",\"pid\":$$,\"pane_id\":\"w1:p1\",\"ts\":\"2020-01-01T00:00:01.000Z\"}"
row "{\"type\":\"peer\",\"status\":\"up\",\"role\":\"implementor\",\"session_id\":\"sess-new\",\"pid\":$$,\"pane_id\":\"w1:p1\",\"ts\":\"2020-01-01T00:00:02.000Z\"}"
status; OUT=$(ms)
check "S12: a restarted member lists only its new session id" '[ "$OUT" = "[\"sess-new\"]" ]'
team - "[$(mem implementor demo-a w1:p1),$(mem reviewer demo-b w1:p2)]"
rm -f "$HD/peers.jsonl"
for n in 1 2 3 4; do row "{\"type\":\"peer\",\"status\":\"up\",\"role\":\"implementor\",\"session_id\":\"sess-r$n\",\"pid\":$$,\"pane_id\":\"w1:p1\",\"ts\":\"2020-01-01T00:00:0$n.000Z\"}"; done
row "{\"type\":\"peer\",\"status\":\"up\",\"role\":\"reviewer\",\"session_id\":\"sess-b\",\"pid\":$$,\"pane_id\":\"w1:p2\",\"ts\":\"2020-01-01T00:00:09.000Z\"}"
status; OUT=$(ms)
check "S12: the list is bounded by the member count, with duplicates removed" '[ "$(node -e "console.log(new Set(JSON.parse(process.argv[1])).size === JSON.parse(process.argv[1]).length && JSON.parse(process.argv[1]).length <= 2)" "$OUT")" = true ]'

# ---- S14-S22: the self-heal
pool "$SANDBOX/h"
SID="sess-heal"
HOME="$FAKEHOME" node --input-type=module -e "import { writeSessionRole } from '$H/lib-session-role.mjs'; writeSessionRole(process.argv[1], 'implementor');" "$SID"
ROSTER="$HD/peers.jsonl"
# <event> <registered pid: me|other> <roster lines, with __PID__ for the registered pid...>: runs activity.mjs as a child of a wrapper whose own
# pid is what "me" means; "other" registers a pid that is not the wrapper's. Prints the hook's stdout; sets RC.
heal() {
  local event=$1 who=$2; shift 2
  rm -rf "$ROSTER"
  RAW=$(printf '%s\n' "$@")
  OUT=$(RAW="$RAW" WHO="$who" EVENT="$event" HOOK="$H/activity.mjs" CWDP="$PROJ" SESS="$SID" EXTRA="${EXTRA:-}" HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" ROSTER_PATH="$ROSTER" node -e '
    const fs = require("fs"), { spawnSync } = require("child_process");
    const pid = process.env.WHO === "me" ? process.pid : process.pid + 7;
    if (process.env.RAW) fs.writeFileSync(process.env.ROSTER_PATH, process.env.RAW.replaceAll("__PID__", String(pid)) + "\n");
    const payload = { hook_event_name: process.env.EVENT, session_id: process.env.SESS, cwd: process.env.CWDP, ...JSON.parse(process.env.EXTRA || "{}") };
    const r = spawnSync("node", [process.env.HOOK], { input: JSON.stringify(payload), encoding: "utf8" });
    process.stdout.write(r.stdout || ""); process.exit(r.status || 0);
  ' 2>&1); RC=$?
}
ups() { [ -f "$ROSTER" ] && { grep -c "\"status\":\"up\"" "$ROSTER" || true; } || echo 0; }
UP="{\"type\":\"peer\",\"status\":\"up\",\"role\":\"implementor\",\"session_id\":\"$SID\",\"pid\":__PID__,\"ppid\":__PID__,\"cwd\":\"/work\",\"pane_id\":\"w1:p1\",\"tab_id\":\"w1:t1\",\"workspace_id\":\"w1\",\"team\":\"demo\",\"ts\":\"2020-01-01T00:00:00.000Z\"}"
DOWN="{\"type\":\"peer\",\"status\":\"down\",\"role\":\"implementor\",\"session_id\":\"$SID\",\"pid\":__PID__,\"pane_id\":\"w1:p1\",\"cwd\":\"/work\",\"ts\":\"2020-01-01T00:00:01.000Z\"}"
last() { tail -1 "$ROSTER"; }
field() { node -e 'console.log(JSON.stringify(JSON.parse(process.argv[1])[process.argv[2]]))' "$(last)" "$1"; }

heal UserPromptSubmit me "$UP" "$DOWN"
check "S14: a down latest, the caller registered the latest up: one up is appended, with the same team and pane" '[ "$RC" = 0 ] && [ "$(ups)" = 2 ] && [ "$(field status)" = "\"up\"" ] && [ "$(field team)" = "\"demo\"" ] && [ "$(field pane_id)" = "\"w1:p1\"" ] && [ "$(field session_id)" = "\"$SID\"" ] && [ "$(field tab_id)" = "\"w1:t1\"" ]'
heal Stop me "$UP" "$DOWN"
check "S15: the same on Stop" '[ "$(ups)" = 2 ] && [ "$(field status)" = "\"up\"" ]'
heal UserPromptSubmit other "$UP" "$DOWN"
check "S16: a down latest, the caller is not the registered pid (a copy): nothing is appended" '[ "$(ups)" = 1 ] && [ "$(field status)" = "\"down\"" ]'
heal Stop other "$UP" "$DOWN"
check "S16: nor on Stop" '[ "$(ups)" = 1 ]'
heal UserPromptSubmit me "$DOWN" "$UP"
check "S17: an up latest: nothing is appended (no duplicate)" '[ "$(ups)" = 1 ] && [ "$(wc -l < "$ROSTER" | tr -d " ")" = 2 ]'
heal UserPromptSubmit me "$DOWN"
check "S18: no up row for the session at all: nothing is appended" '[ "$(ups)" = 0 ] && [ "$(grep -c . "$ROSTER")" = 1 ]'
heal PostToolUse me "$UP" "$DOWN"
check "S19: PostToolUse with a down latest: nothing is appended" '[ "$(ups)" = 1 ] && [ "$(field status)" = "\"down\"" ]'
EXTRA='{"agent_id":"a1","agent_type":"task-gopher:task-gopher"}' heal UserPromptSubmit me "$UP" "$DOWN"
check "S20: a subagent payload: nothing is appended" '[ "$(ups)" = 1 ]'
heal Notification me "$UP" "$DOWN"
check "S19: nor on any other event" '[ "$(ups)" = 1 ]'
# the latest row decides: a later seen row (any status but down) means no heal
SEEN="{\"type\":\"peer\",\"status\":\"seen\",\"role\":\"implementor\",\"session_id\":\"$SID\",\"ts\":\"2020-01-01T00:00:02.000Z\"}"
heal UserPromptSubmit me "$UP" "$DOWN" "$SEEN"
check "S17: a down that a later non-down row followed: nothing is appended" '[ "$(ups)" = 1 ]'
# S21: an unreadable roster
rm -rf "$ROSTER"; mkdir -p "$ROSTER"
OUT=$(printf '{"hook_event_name":"UserPromptSubmit","session_id":"%s","cwd":"%s"}' "$SID" "$PROJ" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/activity.mjs" 2>&1); RC=$?
check "S21: an unreadable roster: no throw, exit 0, no stdout" '[ "$RC" = 0 ] && [ -z "$OUT" ]'
rm -rf "$ROSTER"
printf 'not json\n{"type":"peer"\n' > "$ROSTER"
OUT=$(printf '{"hook_event_name":"Stop","session_id":"%s","cwd":"%s"}' "$SID" "$PROJ" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/activity.mjs" 2>&1); RC=$?
check "S21: a garbled roster: no throw, exit 0, no stdout" '[ "$RC" = 0 ] && [ -z "$OUT" ]'

# S22: how the hook is registered, and who writes down
reg() { node -e 'const h = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).hooks; const out = []; for (const ev of ["UserPromptSubmit", "Stop"]) for (const e of h[ev]) for (const k of e.hooks) if (k.command.includes("hooks/activity.mjs")) out.push(ev + ":" + k.command); console.log(out.sort().join(" | "))' "$PLUGIN/hooks/hooks.json"; }
check "S22: activity.mjs is registered for UserPromptSubmit and Stop as the plain node command, the shape sessionstart's has" '[ "$(reg)" = "Stop:node \"\${CLAUDE_PLUGIN_ROOT}/hooks/activity.mjs\" | UserPromptSubmit:node \"\${CLAUDE_PLUGIN_ROOT}/hooks/activity.mjs\"" ] && grep -q "\"command\": \"node \\\\\"\${CLAUDE_PLUGIN_ROOT}/hooks/sessionstart.mjs\\\\\"\"" "$PLUGIN/hooks/hooks.json"'
check "S22: a status of down is written only in sessionend-roster.mjs" '[ "$(grep -ln "status: \"down\"" "$PLUGIN"/hooks/*.mjs | xargs -n1 basename | tr "\n" " ")" = "sessionend-roster.mjs " ]'

echo "----"
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
