#!/bin/bash
# agent-hierarchy — SessionEnd roster writer: only the registered process (or any process once the
# registered one is dead) may mark a member down; every down records the ending process's pid.
# HOME-redirected, throwaway repo; real config and pool never touched.
# Usage: bash tests/test-sessionend-roster.sh   (exits 0 iff all cases pass)

. "$(dirname "$0")/lib-hermetic.sh"
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/ah-sessionend-test.XXXXXX")"
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
KIDS=()
cleanup() { for k in "${KIDS[@]}"; do kill "$k" 2>/dev/null; wait "$k" 2>/dev/null; done; rm -rf "$SANDBOX"; }
trap cleanup EXIT
unset AGENT_HIERARCHY_DIR AH_TEAM_FILE CLAUDE_PID
FAKEHOME="$SANDBOX/home"; PROJ="$SANDBOX/repo"; ROSTER="$PROJ/.claude/hierarchy/peers.jsonl"
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude/hierarchy"
git -C "$PROJ" init -q
PASS=0; FAIL=0
check() { local n=$1; shift; if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $n"; else FAIL=$((FAIL+1)); echo "FAIL: $n (OUT=${OUT:0:300} RC=$RC)"; fi; }

# end <session id> [self]: runs the hook under a throwaway parent shell; ENDER is that shell's pid,
# which is the ppid the hook sees. With "self" the shell first registers its own pid as the member's up.
end() {
  printf '{"session_id":"%s","cwd":"%s","hook_event_name":"SessionEnd","reason":"other"%s}' "$1" "$PROJ" "${AT:+,\"agent_type\":\"$AT\"}" > "$SANDBOX/in.json"
  if [ -n "${AHD:-}" ]; then export AGENT_HIERARCHY_DIR="$AHD"; else unset AGENT_HIERARCHY_DIR; fi
  OUT=$(bash -c 'echo $$ > "$1"; if [ "$6" = self ]; then printf "{\"type\":\"peer\",\"ts\":\"2026-01-01T00:00:00.000Z\",\"status\":\"up\",\"role\":\"implementor\",\"session_id\":\"%s\",\"pid\":%s,\"cwd\":\"x\"}\n" "$7" $$ >> "$5"; fi; HOME="$2" node "$3/sessionend-roster.mjs" < "$4"; rc=$?; exit $rc' _ "$SANDBOX/ender" "$FAKEHOME" "$H" "$SANDBOX/in.json" "$ROSTER" "${2:-}" "$1" 2>&1); RC=$?
  ENDER=$(cat "$SANDBOX/ender")
}
reset() { : > "$ROSTER"; }
regup() { printf '{"type":"peer","ts":"2026-01-01T00:00:00.000Z","status":"up","role":"implementor","session_id":"%s","pid":%s,"cwd":"%s"}\n' "$1" "$2" "$PROJ" >> "$ROSTER"; }
downs() { grep -c '"status":"down"' "$ROSTER"; }
lastdown_pid() { grep '"status":"down"' "$ROSTER" | tail -1 | node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(0,"utf8")).pid))'; }
live_child() { sleep 300 & CHILD=$!; KIDS+=("$CHILD"); }
dead_pid() { sleep 0 & local p=$!; wait "$p"; DEAD=$p; }

reset; end s1
check "no registered role -> nothing written, exit 0, no stdout" '[ "$RC" = 0 ] && [ -z "$OUT" ] && [ "$(downs)" = 0 ]'

reset; end s2 self
check "registered process ends -> one down stamped with its pid" '[ "$(downs)" = 1 ] && [ "$(lastdown_pid)" = "$ENDER" ]'

reset; live_child; regup s3 "$CHILD"; end s3
check "foreign end while registered pid is alive -> no record, exit 0, no stdout" '[ "$(downs)" = 0 ] && [ "$RC" = 0 ] && [ -z "$OUT" ]'
check "member's latest record stays up with a live pid after a foreign end" 'tail -1 "$ROSTER" | grep -q "\"status\":\"up\"" && kill -0 "$CHILD"'

reset; dead_pid; regup s4 "$DEAD"; end s4
check "registered pid dead -> one down stamped with the ending pid" '[ "$(downs)" = 1 ] && [ "$(lastdown_pid)" = "$ENDER" ] && [ "$ENDER" != "$DEAD" ]'

reset; live_child; regup s5 "$CHILD"; end s5; end s5
check "repeated foreign ends (same session id relaunch / reused pid) never mark down" '[ "$(downs)" = 0 ]'

reset; rm -f "$ROSTER"; mkdir "$ROSTER"; end s6
check "unreadable roster -> exit 0, no stdout" '[ "$RC" = 0 ] && [ -z "$OUT" ]'
rmdir "$ROSTER"; : > "$ROSTER"; end s6
check "empty roster -> exit 0, no stdout, nothing written" '[ "$RC" = 0 ] && [ -z "$OUT" ] && [ "$(downs)" = 0 ]'

# S1: no up record, role resolved from agent_type -> down stamped with the ending pid
reset; AT=ah:implementor end s1b
check "no up record, role from agent_type -> one down with the ending pid" '[ "$(downs)" = 1 ] && [ "$(lastdown_pid)" = "$ENDER" ]'

# activity record: a foreign end leaves it, a real end clears it
. "$PLUGIN/tests/lib-status-pool.sh"
REF="2026-03-01T12:00:00.000Z"
pool "$SANDBOX/pool"; PROJ="$SANDBOX/pool/proj"; git -C "$PROJ" init -q; AHD="$HD"; ROSTER="$HD/peers.jsonl"; : > "$ROSTER"
live_child; regup sA "$CHILD"; activity sA working "$REF"; end sA
check "foreign end leaves the member's activity record" '[ -f "$HD/activity/sA.json" ] && [ "$(downs)" = 0 ]'
dead_pid; : > "$ROSTER"; regup sB "$DEAD"; activity sB working "$REF"; end sB
check "end once the registered pid is dead clears the activity record" '[ ! -f "$HD/activity/sB.json" ] && [ "$(downs)" = 1 ]'
activity sC working "$REF"; : > "$ROSTER"; end sC
check "a session with no roster record still has its activity cleared" '[ ! -f "$HD/activity/sC.json" ]'

# S7: the member stays live in the status document after a foreign end
pool "$SANDBOX/pool2"; PROJ="$SANDBOX/pool2/proj"; git -C "$PROJ" init -q; AHD="$HD"; ROSTER="$HD/peers.jsonl"
team - '[{"role":"architect","name":"demo-architect","route":"peer","kind":"claude","transport_id":"w1:p1"}]'
up demo-architect architect sD w1:p1
end sD
status "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)" --plain
check "status still counts the member live after a foreign end" '[ "$OUT" = "ah · 1 live · 0 out" ]'

echo "passed=$PASS failed=$FAIL"; [ "$FAIL" = 0 ]
