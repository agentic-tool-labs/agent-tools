#!/bin/bash
# agent-hierarchy — the StopFailure hook records an API-error turn end as the session's activity
# `failed` (kind, details, streak), carries the streak through resumes and clears it on a normal end,
# and asks the terminal for a notification only for an Orchestrator whose failure will not be resumed.
# HOME- and hierarchy-redirected; real state untouched.
# Usage: bash tests/test-stopfailure-recovery.sh   (exits 0 iff all cases pass)

. "$(dirname "$0")/lib-hermetic.sh"
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SB="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-stopfailure-test.XXXXXX")"
[ -n "$SB" ] && [ -d "$SB" ] || { echo "mktemp failed"; exit 1; }
SB="$(cd "$SB" && pwd -P)"
sleep 300 & OTHER=$!
trap 'kill "$OTHER" 2>/dev/null; rm -rf "$SB"' EXIT
unset AH_TEAM_FILE CLAUDE_PID CLAUDE_CODE_SESSION_ID AGENT_HIERARCHY_DIR
export HOME="$SB/home" CLAUDE_PID=$$
PROJ="$SB/proj"; HD="$PROJ/.claude/hierarchy"
mkdir -p "$HOME/.claude/projects/p" "$PROJ"
(cd "$PROJ" && git init -q)
mkdir -p "$HD/activity"
PASS=0; FAIL=0
check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (OUT=${OUT:0:300})"; fi
}

rec() { node -e 'const f = require("path").join(process.argv[1], "activity", process.argv[2] + ".json"); let r = null; try { r = JSON.parse(require("fs").readFileSync(f, "utf8")); } catch {} const k = process.argv[3]; const v = r === null ? "(none)" : (r[k] === undefined ? "(absent)" : r[k]); process.stdout.write(String(v))' "$HD" "$1" "$2"; }
# sf <session> <json fields…>: run the StopFailure hook; OUT is what it printed
sf() {
  local sid=$1 extra=$2
  OUT=$(printf '{"hook_event_name":"StopFailure","session_id":"%s","cwd":"%s"%s}' "$sid" "$PROJ" "${extra:+,$extra}" | node "$H/stopfailure-recovery.mjs" 2>&1); RC=$?
}
reset() { rm -f "$HD/activity"/*.json "$HD/peers.jsonl" "$HOME/.claude/hierarchy/peers.jsonl"; }
# set <session> <activity> [extra json]: write a record the way recordActivity does
setrec() { node --input-type=module -e "import { recordActivity } from '$H/lib-status.mjs'; recordActivity(process.argv[1], process.argv[2], { activity: process.argv[3], extra: process.argv[4] ? JSON.parse(process.argv[4]) : null, resetStreak: process.argv[5] === 'reset' });" "$HD" "$1" "$2" "${3:-}" "${4:-}"; }
# hook <event> <session> [extra json]: run activity.mjs for a role session
act() { printf '{"hook_event_name":"%s","session_id":"%s","cwd":"%s"%s}' "$1" "$2" "$PROJ" "${3:+,$3}" | node "$H/activity.mjs" >/dev/null 2>&1; }

# ---- the record
reset
sf s1 '"error":"overloaded","error_details":"busy"'
check "StopFailure overloaded: record failed, error, details, source, streak 1" '[ "$(rec s1 activity)" = failed ] && [ "$(rec s1 error)" = overloaded ] && [ "$(rec s1 error_details)" = busy ] && [ "$(rec s1 source)" = stopfailure ] && [ "$(rec s1 streak)" = 1 ]'
check "the failure time is recorded" 'rec s1 failed_at | grep -qE "^20[0-9]{2}-"'
check "the hook prints nothing for a session that is no Orchestrator" '[ "$RC" -eq 0 ] && [ -z "$OUT" ]'
for kind in billing_error authentication_failed invalid_request model_not_found max_output_tokens rate_limit server_error cloud_credential_error; do
  reset; sf s2 "\"error\":\"$kind\""
  check "StopFailure $kind is recorded as itself" '[ "$(rec s2 error)" = "$kind" ]'
done
reset; sf s3 ''
check "a payload with no error kind: recorded as unknown" '[ "$(rec s3 error)" = unknown ]'
reset; sf s3 '"error":"some_future_kind"'
check "a kind this build does not know is kept as it is, so it is never retried" '[ "$(rec s3 error)" = some_future_kind ]'
reset; sf s3 '"error":"bad kind; $(x)"'
check "a kind is cut to a safe token" '[ "$(rec s3 error)" = badkindx ]'
reset; sf s4 '"error_type":"server_error","error_message":"docs spelling","error_code":"E42"'
check "the docs spelling error_type / error_message is recorded like error / error_details" '[ "$(rec s4 error)" = server_error ] && [ "$(rec s4 error_details)" = "docs spelling" ] && [ "$(rec s4 error_code)" = E42 ]'
reset; sf s5 '"error":"overloaded","error_details":"line one\nline two \u001b[31mred\u001b[0m '"$(printf 'x%.0s' $(seq 1 400))"'"'
check "error_details is one line, escape sequences stripped, capped at 300" '[ "$(rec s5 error_details | wc -c | tr -d " ")" -le 300 ] && ! rec s5 error_details | grep -q "$(printf "\033")" && rec s5 error_details | grep -q "line one line two red"'

# ---- the streak: one plus the resumes already emitted for the session in the 45 minutes before the failure
PEERS="$HOME/.claude/agent-hierarchy.peer-pending.jsonl"
# resumes <session> <count> <minutes ago the first was emitted>: RESUME watch-event rows, as the watcher writes them
resumes() { node -e 'const [file, sid, n, ago] = process.argv.slice(1); const fs = require("fs"); const rows = []; for (let i = 0; i < Number(n); i++) { const t = new Date(Date.now() - (Number(ago) - i) * 60000).toISOString(); rows.push(JSON.stringify({ type: "watch-event", session_id: "w", request_id: null, kind: "RESUME", subject: sid, failed_at: t, ts: t })); } fs.mkdirSync(require("path").dirname(file), { recursive: true }); fs.appendFileSync(file, rows.join("\n") + "\n")' "$PEERS" "$1" "$2" "$3"; }
preset() { rm -f "$PEERS"; reset; }
preset; sf s6 '"error":"overloaded"'
check "no resume emitted yet: streak 1" '[ "$(rec s6 streak)" = 1 ]'
preset; resumes s6 1 10; sf s6 '"error":"server_error"'
check "one resume emitted in the last 45 minutes: streak 2" '[ "$(rec s6 streak)" = 2 ]'
preset; resumes s6 3 20; sf s6 '"error":"server_error"'
check "three resumes: the fourth failure is streak 4" '[ "$(rec s6 streak)" = 4 ]'
preset; resumes other 3 20; sf s6 '"error":"server_error"'
check "another session's resumes do not count" '[ "$(rec s6 streak)" = 1 ]'
preset; resumes s6 3 70; sf s6 '"error":"server_error"'
check "failure outside the 45-minute window of the resumes (they are 68-70 minutes old): streak 1" '[ "$(rec s6 streak)" = 1 ]'
preset; resumes s6 1 10; tail -1 "$PEERS" >> "$PEERS"; sf s6 '"error":"server_error"'
check "two rows for the same (session, failed_at) count once" '[ "$(rec s6 streak)" = 2 ]'

preset; resumes s7 1 10; sf s7 '"error":"overloaded"'
setrec s7 working
check "a resume turn (working) carries the displayed streak" '[ "$(rec s7 activity)" = working ] && [ "$(rec s7 streak)" = 2 ]'
setrec s7 working
setrec s7 idle "" reset
check "a normal end (Stop) clears the displayed streak" '[ "$(rec s7 activity)" = idle ] && [ "$(rec s7 streak)" = "(absent)" ]'
sf s7 '"error":"overloaded"'
check "...but the next failure still counts the resumes already emitted: streak 2" '[ "$(rec s7 streak)" = 2 ]'

# a role session's own hooks: Stop clears, UserPromptSubmit and PostToolUse carry, the transcript path is kept
reset
node --input-type=module -e "import { writeSessionRole } from '$H/lib-session-role.mjs'; writeSessionRole('s8', 'architect');"
printf '{}\n' > "$HOME/.claude/projects/p/s8.jsonl"
sf s8 '"error":"overloaded"'
act UserPromptSubmit s8 "\"transcript_path\":\"$HOME/.claude/projects/p/s8.jsonl\""
check "activity.mjs: a prompt after a failure carries the streak and keeps the transcript path" '[ "$(rec s8 activity)" = working ] && [ "$(rec s8 streak)" = 1 ] && [ "$(rec s8 transcript_path)" = "$HOME/.claude/projects/p/s8.jsonl" ]'
act PostToolUse s8 '"tool_name":"Read"'
check "activity.mjs: PostToolUse leaves the streak alone" '[ "$(rec s8 streak)" = 1 ]'
act Stop s8
check "activity.mjs: Stop clears the streak" '[ "$(rec s8 activity)" = idle ] && [ "$(rec s8 streak)" = "(absent)" ]'
act UserPromptSubmit s8 '"transcript_path":"/etc/passwd"'
check "activity.mjs: a transcript path outside ~/.claude/projects is not kept" '[ "$(rec s8 transcript_path)" = "$HOME/.claude/projects/p/s8.jsonl" ]'

# ---- one failure seen twice
reset
NOW_MS=$(node -e 'process.stdout.write(String(Date.now()))')
TS_AT=$(node -e 'process.stdout.write(new Date(Date.now() - 3000).toISOString())')
setrec s9 failed "{\"error\":\"unknown\",\"source\":\"transcript\",\"failed_at\":\"$TS_AT\",\"streak\":2}"
sf s9 '"error":"server_error"'
check "a StopFailure within 10 s of a transcript-detected failure: same failure, streak kept" '[ "$(rec s9 streak)" = 2 ] && [ "$(rec s9 failed_at)" = "$TS_AT" ]'
check "...with the error and source updated" '[ "$(rec s9 error)" = server_error ] && [ "$(rec s9 source)" = stopfailure ]'
preset
OLD_AT=$(node -e 'process.stdout.write(new Date(Date.now() - 20000).toISOString())')
setrec s9 failed "{\"error\":\"unknown\",\"source\":\"transcript\",\"failed_at\":\"$OLD_AT\",\"streak\":2}"
resumes s9 2 10
sf s9 '"error":"server_error"'
check "20 s later it is a new failure: its streak is one plus the resumes emitted (3)" '[ "$(rec s9 streak)" = 3 ]'
preset
STALE_AT=$(node -e 'process.stdout.write(new Date(Date.now() - 3600000).toISOString())')
setrec s9 failed "{\"error\":\"overloaded\",\"source\":\"stopfailure\",\"failed_at\":\"$STALE_AT\",\"streak\":3}"
sf s9 '"error":"overloaded"'
check "a failure an hour after the last one, with no resumes in the window, starts a new streak" '[ "$(rec s9 streak)" = 1 ]'

# ---- a plain session (no persisted role) is followed once it has a record (r3 B1)
preset
sf s10 '"error":"overloaded"'
act UserPromptSubmit s10
check "role-less StopFailure, then UserPromptSubmit: the record is working again" '[ "$(rec s10 activity)" = working ]'
act Stop s10
check "role-less Stop after a failure: idle, the displayed streak cleared" '[ "$(rec s10 activity)" = idle ] && [ "$(rec s10 streak)" = "(absent)" ]'
preset
act UserPromptSubmit s11
act Stop s11
act PostToolUse s11 '"tool_name":"Read"'
check "a role-less session with no activity record stays unrecorded" '[ "$(rec s11 activity)" = "(none)" ]'
preset
sf s12 '"error":"overloaded"'
printf '{}\n' > "$HOME/.claude/projects/p/s12.jsonl"
act UserPromptSubmit s12 "\"transcript_path\":\"$HOME/.claude/projects/p/s12.jsonl\""
check "role-less: the transcript path is kept from the prompt event" '[ "$(rec s12 transcript_path)" = "$HOME/.claude/projects/p/s12.jsonl" ]'
sf subx '"error":"overloaded"'
OUT=$(printf '{"hook_event_name":"UserPromptSubmit","session_id":"subx","agent_id":"a1","agent_type":"x","cwd":"%s"}' "$PROJ" | node "$H/activity.mjs" 2>&1)
check "a subagent's event does not move its parent's failed record" '[ "$(rec subx activity)" = failed ]'

# ---- not recorded
reset
OUT=$(printf '{"hook_event_name":"StopFailure","session_id":"sub1","agent_id":"a1","agent_type":"x","cwd":"%s","error":"overloaded"}' "$PROJ" | node "$H/stopfailure-recovery.mjs" 2>&1)
check "a subagent's StopFailure records nothing" '[ "$(rec sub1 activity)" = "(none)" ] && [ -z "$OUT" ]'
OUT=$(printf '{"hook_event_name":"Stop","session_id":"sx","cwd":"%s","error":"overloaded"}' "$PROJ" | node "$H/stopfailure-recovery.mjs" 2>&1)
check "another event records nothing" '[ "$(rec sx activity)" = "(none)" ]'
OUT=$(printf '{"hook_event_name":"StopFailure","session_id":"nodir","cwd":"%s","error":"overloaded"}' "$SB/not-a-checkout" | node "$H/stopfailure-recovery.mjs" 2>&1); RC=$?
check "a cwd with no hierarchy dir records nothing and exits 0" '[ "$RC" -eq 0 ] && [ -z "$OUT" ]'
OUT=$(printf 'not json at all' | node "$H/stopfailure-recovery.mjs" 2>&1); RC=$?
check "garbage on stdin: exit 0, no output (fail open)" '[ "$RC" -eq 0 ] && [ -z "$OUT" ]'

# ---- the notification: only an Orchestrator, only when the failure will not be resumed
own() { node -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify({ version: 1, team_id: "t-sf", created: new Date().toISOString(), roster_level: "repo", transport: "herdr", orchestrator: { session_id: null, pid: Number(process.argv[2]) }, members: [] }))' "$HD/team.json" "$1"; }
watcher() { node --input-type=module -e "import { appendPeerRecord } from '$H/lib-peer.mjs'; appendPeerRecord({ type: 'watcher', session_id: process.argv[1], pid: Number(process.argv[2]), started: new Date().toISOString() });" "$1" "$2"; }
reset; own "$$"; watcher so1 "$OTHER"
sf so1 '"error":"billing_error"'
check "an Orchestrator's non-retryable failure: an OSC 9 notification plus BEL" 'printf "%s" "$OUT" | node -e "const o = JSON.parse(require(\"fs\").readFileSync(0, \"utf8\")); const t = o.terminalSequence; process.exit(t.startsWith(\"\\u001b]9;ah: \") && t.endsWith(\"\\u0007\\u0007\") && t.includes(\"(billing_error)\") ? 0 : 1)"'
check "the notification text is ASCII, at most 120 characters, with no semicolon in it" 'printf "%s" "$OUT" | node -e "const t = JSON.parse(require(\"fs\").readFileSync(0, \"utf8\")).terminalSequence.slice(4, -2); process.exit(/^[\\x20-\\x7e]+$/.test(t) && t.length <= 120 && !t.includes(\";\") ? 0 : 1)"'
reset; own "$$"; watcher so1 "$OTHER"
sf so1 '"error":"overloaded"'
check "an Orchestrator's retryable first failure with a watcher alive: no output" '[ -z "$OUT" ]'
reset; own "$$"; watcher so1 "$OTHER"; resumes so1 3 20
sf so1 '"error":"overloaded"'
check "the fourth failure (three resumes already emitted): a notification saying it stopped after 3 retries" 'printf "%s" "$OUT" | grep -q "after 3 retries"'
reset; own "$$"
sf so2 '"error":"overloaded"'
check "an Orchestrator with no watcher alive: a notification on the first failure" 'printf "%s" "$OUT" | grep -q "terminalSequence"'
reset; own "$OTHER"
sf so3 '"error":"billing_error"'
check "a session that owns no team (a member or a plain session): no notification" '[ -z "$OUT" ]'

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
