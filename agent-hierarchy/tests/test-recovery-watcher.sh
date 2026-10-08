#!/bin/bash
# agent-hierarchy — the dispatch watcher resumes a session whose turn ended on an API error after a
# backoff (its own session, or a live Claude member of a team it owns), escalates when the error is
# not retryable or the cap is reached, and finds an API-error end the StopFailure hook missed from the
# transcript. Records are written straight into the activity dir with chosen times, so no test waits
# for a backoff. HOME- and hierarchy-redirected; real state untouched.
# Usage: bash tests/test-recovery-watcher.sh   (exits 0 iff all cases pass)

. "$(dirname "$0")/lib-hermetic.sh"
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SB="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-recovery-watcher-test.XXXXXX")"
[ -n "$SB" ] && [ -d "$SB" ] || { echo "mktemp failed"; exit 1; }
SB="$(cd "$SB" && pwd -P)"
# No test may reach the real herdr or tmux: a stub that fails every call sits first on PATH (a failing herdr or tmux is what a
# machine without a running multiplexer gives), and the guard in lib-hermetic.sh is told it is a fake.
mkdir -p "$SB/nolaunch"; printf '#!/bin/sh\nexit 1\n' > "$SB/nolaunch/herdr"; cp "$SB/nolaunch/herdr" "$SB/nolaunch/tmux"; chmod +x "$SB/nolaunch/herdr" "$SB/nolaunch/tmux"
export PATH="$SB/nolaunch:$PATH"; export AH_TEST_FAKE_BIN="$SB/nolaunch"
sleep 300 & OTHER=$!
trap 'kill "$OTHER" 2>/dev/null; rm -rf "$SB"' EXIT
unset AH_TEAM_FILE CLAUDE_PID CLAUDE_CODE_SESSION_ID AGENT_HIERARCHY_DIR
export HOME="$SB/home" CLAUDE_PID=$$
PROJ="$SB/proj"; HD="$PROJ/.claude/hierarchy"; PR="$HOME/.claude/projects/p"
mkdir -p "$PR" "$PROJ"
(cd "$PROJ" && git init -q)
mkdir -p "$HD/activity"
PASS=0; FAIL=0
check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:400})"; fi
}

ago() { node -e 'process.stdout.write(new Date(Date.now() - Number(process.argv[1]) * 1000).toISOString())' "$1"; }
# put <session> <activity> <seconds ago the state began> [extra json]: an activity record with a chosen time
put() { node -e 'const [dir, sid, activity, ago, extra] = process.argv.slice(1); const at = new Date(Date.now() - Number(ago) * 1000).toISOString(); require("fs").writeFileSync(require("path").join(dir, "activity", sid + ".json"), JSON.stringify({ activity, at, blocked_by: null, note: null, tool: null, tool_at: null, ...(extra ? JSON.parse(extra) : {}) }) + "\n")' "$HD" "$1" "$2" "$3" "${4:-}"; }
# failed <session> <error> <streak> <seconds since the failure> [source]
PEERS="$HOME/.claude/agent-hierarchy.peer-pending.jsonl"
# earlier <session> <count> <seconds before now the failure happened>: <count> RESUME rows emitted before that failure (5+ minutes earlier each)
earlier() { node -e 'const [file, sid, n, ago, base] = process.argv.slice(1); const fs = require("fs"); const rows = []; for (let i = 0; i < Number(n); i++) { const t = new Date(Date.now() - Number(ago) * 1000 - (Number(base || 5) + i) * 60000).toISOString(); rows.push(JSON.stringify({ type: "watch-event", session_id: "old", request_id: null, kind: "RESUME", subject: sid, failed_at: t, ts: t })); } if (rows.length) { fs.mkdirSync(require("path").dirname(file), { recursive: true }); fs.appendFileSync(file, rows.join("\n") + "\n"); }' "$PEERS" "$1" "$2" "$3" "${4:-5}"; }
# the streak is one plus the RESUMEs already emitted, so <streak> is made of <streak - 1> earlier rows; the record carries it for display
failed() { put "$1" failed "$4" "{\"error\":\"$2\",\"error_details\":\"details\",\"source\":\"${5:-stopfailure}\",\"failed_at\":\"$(ago "$4")\",\"streak\":$3}"; earlier "$1" $(($3 - 1)) "$4"; }
rec() { node -e 'const f = require("path").join(process.argv[1], "activity", process.argv[2] + ".json"); let r = null; try { r = JSON.parse(require("fs").readFileSync(f, "utf8")); } catch {} const v = r === null ? "(none)" : (r[process.argv[3]] === undefined ? "(absent)" : r[process.argv[3]]); process.stdout.write(String(v))' "$HD" "$1" "$2"; }
reset() { rm -f "$HD/activity"/*.json "$HD/gates.jsonl" "$HD/team.json" "$HD/peers.jsonl" "$PR"/*.jsonl; rm -rf "$HOME/.claude/hierarchy"; mkdir -p "$HOME/.claude/hierarchy"; find "$HOME/.claude" -maxdepth 1 -type f -delete; }
rows() { grep -rh "\"kind\":\"$1\"" "$HOME/.claude" 2>/dev/null | wc -l | tr -d ' '; }
# team <owner pid>: the default team with one Claude member, live in the roster
team() {
  node -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify({ version: 1, team_id: "t-rw", created: new Date().toISOString(), roster_level: "repo", transport: "herdr", orchestrator: { session_id: null, pid: Number(process.argv[2]) }, members: [{ role: "architect", name: "demo-arch", route: "peer", kind: "claude", transport_id: "p1", transport: "herdr" }] }))' "$HD/team.json" "$1"
  node --input-type=module -e "import { appendRosterRecord } from '$H/lib-hier.mjs'; appendRosterRecord(process.argv[1], { status: 'up', role: 'architect', name: 'demo-arch', session_id: 'sess-m', pid: Number(process.argv[2]), ts: new Date().toISOString() });" "$HD" "$OTHER"
}
watch() {
  AH_WATCH_POLL_MS=150 node "$H/dispatch-watcher.mjs" --session sess-w --cwd "$PROJ" > "$SB/watch.out" 2>&1 &
  local pid=$! i
  for i in $(seq 1 $(($1 * 10))); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
  if kill -0 "$pid" 2>/dev/null; then kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; RC=143; else wait "$pid" 2>/dev/null; RC=$?; fi
  OUT=$(cat "$SB/watch.out")
}
quiet() { [ "$RC" -eq 143 ] && [ -z "$OUT" ]; }
RESUME_LINE="Continue the interrupted task. First re-check state: re-read any file you were changing"

# ---- the session's own failure
reset; failed sess-w overloaded 1 40
watch 6
check "own session, overloaded, 40 s after the failure: a RESUME wake (exit 3) with the resume paragraph" '[ "$RC" -eq 3 ] && echo "$OUT" | grep -q "this session.s last turn ended on an API error (overloaded)" && echo "$OUT" | grep -q "automatic resume 1/3" && echo "$OUT" | grep -q "$RESUME_LINE"'
check "the paragraph tells it to re-check side effects before repeating them" 'echo "$OUT" | grep -q "confirm whether it already happened before doing it again"'
check "the wake is recorded as a typed watch-event row" '[ "$(rows RESUME)" -ge 1 ]'
check "the own-session wake carries the watcher restart line" 'echo "$OUT" | grep -q "^Restart the watcher if anything is still open: Bash with run_in_background: true"'
watch 3
check "a restarted watcher does not resume the same failure twice" 'quiet'

reset; failed sess-w overloaded 1 20
watch 3
check "20 s after the failure (under the 30 s backoff): nothing" 'quiet'

reset; failed sess-w server_error 2 60
watch 3
check "streak 2 at 60 s (backoff 120 s): nothing" 'quiet'
reset; failed sess-w server_error 2 130
watch 6
check "streak 2 at 130 s: RESUME 2/3" '[ "$RC" -eq 3 ] && echo "$OUT" | grep -q "automatic resume 2/3"'

reset; failed sess-w rate_limit 1 60
watch 3
check "rate_limit streak 1 at 60 s waits 120 s, not 30 s: nothing" 'quiet'
reset; failed sess-w rate_limit 1 130
watch 6
check "rate_limit streak 1 at 130 s: RESUME" '[ "$RC" -eq 3 ] && echo "$OUT" | grep -q "(rate_limit)"'

reset; failed sess-w unknown 1 40
watch 6
check "an unknown kind is retryable" '[ "$RC" -eq 3 ] && echo "$OUT" | grep -q "automatic resume 1/3"'

# ---- escalation
reset; failed sess-w overloaded 4 600
watch 3
check "own session, 4th consecutive failure: no wake" 'quiet'
check "...only a watch-event row" '[ "$(rows API-FAILED)" -ge 1 ]'
for kind in billing_error authentication_failed invalid_request model_not_found max_output_tokens account_on_hold some_future_kind; do
  reset; failed sess-w "$kind" 1 600
  watch 3
  check "own session, non-retryable $kind: never resumed, no wake, a row" 'quiet && [ "$(rows API-FAILED)" -ge 1 ] && [ "$(rows RESUME)" -eq 0 ]'
done

# ---- a member of an owned team
reset; team "$$"; failed sess-m overloaded 1 40
watch 6
check "member, overloaded, 40 s: a RESUME wake telling the Orchestrator to SendMessage it" '[ "$RC" -eq 3 ] && echo "$OUT" | grep -q "architect \"demo-arch\" ended a turn on an API error (overloaded)" && echo "$OUT" | grep -q "SendMessage demo-arch" && echo "$OUT" | grep -q "automatic resume 1/3" && echo "$OUT" | grep -q "$RESUME_LINE"'
check "the wake says: no re-brief, no ETA reset" 'echo "$OUT" | grep -q "no re-brief, no ETA reset"'
check "the member wake carries the restart line, outside the text to forward" 'echo "$OUT" | grep -q "^Restart the watcher if anything is still open: Bash with run_in_background: true" && [ "$(echo "$OUT" | grep -n "^---$" | tail -1 | cut -d: -f1)" -lt "$(echo "$OUT" | grep -n "^Restart the watcher" | cut -d: -f1)" ]'
check "a resume counts as hearing from the member (the check-in clock restarts)" 'grep -rh "\"type\":\"heard\"" "$HOME/.claude" | grep -q "\"from\":\"demo-arch\""'
reset; team "$$"; failed sess-m overloaded 4 600
watch 6
check "member, 4th failure: an API-FAILED wake, no resume, tell the user" '[ "$RC" -eq 3 ] && echo "$OUT" | grep -q "stopped on an API error (overloaded" && echo "$OUT" | grep -q "after 3 automatic resumes. Not resuming. Tell the user in one line" && ! echo "$OUT" | grep -q "SendMessage demo-arch" && echo "$OUT" | grep -q "^.*Restart the watcher if anything is still open"'
reset; team "$$"; failed sess-m billing_error 1 10
watch 6
check "member, billing_error: escalated at once, even 10 s after" '[ "$RC" -eq 3 ] && echo "$OUT" | grep -q "Not resuming"'
reset; team "$OTHER"; failed sess-m overloaded 1 600
watch 3
check "a member of a team this orchestrator does not own: ignored" 'quiet'
reset; team "$$"; put sess-m idle 600
watch 3
check "a member that ended normally (idle): nothing" 'quiet'

# ---- the record moves on
reset; failed sess-w overloaded 1 20
( sleep 0.3; put sess-w working 0 "{\"streak\":1}" ) &
watch 4
check "the user types before the delay (record working again): no RESUME" 'quiet'
reset; put sess-w working 5
watch 3
check "a working session: nothing" 'quiet'
reset; put sess-w idle 600
watch 3
check "an idle session (normal Stop): nothing" 'quiet'
reset
watch 2
check "no record at all (an Esc leaves the record as it was): nothing" 'quiet'

# ---- the transcript backs up a missed StopFailure
entry_err() { node -e 'process.stdout.write(JSON.stringify({ parentUuid: "a", isSidechain: false, type: "assistant", uuid: "u2", timestamp: new Date(Date.now() - Number(process.argv[1]) * 1000).toISOString(), message: { model: "<synthetic>", role: "assistant", content: [{ type: "text", text: "API Error: Connection lost mid-response. The response above was cut off." }] }, error: "server_error", truncatedAfterOutput: true, isApiErrorMessage: true, sessionId: "sess-w" }) + "\n")' "$1"; }
entry_ok() { printf '%s\n' '{"type":"assistant","uuid":"u1","timestamp":"2026-01-01T00:00:00.000Z","message":{"role":"assistant","content":[{"type":"text","text":"working on it"}]},"sessionId":"sess-w"}'; }
entry_sys() { printf '%s\n' '{"type":"system","subtype":"turn_duration","durationMs":3000,"timestamp":"2026-01-01T00:00:01.000Z","sessionId":"sess-w"}'; }
entry_user() { printf '%s\n' '{"type":"user","uuid":"u3","timestamp":"2026-01-01T00:00:02.000Z","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]},"sessionId":"sess-w"}'; }
T="$PR/sess-w.jsonl"
reset; { entry_ok; entry_err 40; entry_sys; } > "$T"
put sess-w working 100 "{\"transcript_path\":\"$T\"}"
watch 6
check "working, quiet 100 s, the last conversation entry (before a turn_duration row) is the flagged API error: failed via the transcript, then RESUME" '[ "$RC" -eq 3 ] && echo "$OUT" | grep -q "(server_error)" && echo "$OUT" | grep -q "automatic resume 1/3"'
check "the record says source transcript and carries the kind from the entry" '[ "$(rec sess-w source)" = transcript ] && [ "$(rec sess-w error)" = server_error ] && [ "$(rec sess-w streak)" = 1 ]'

reset; { entry_ok; entry_err 40; entry_sys; } > "$T"
put sess-w idle 100 "{\"transcript_path\":\"$T\"}"
watch 6
check "an idle record (Stop fired) with the same last entry: the same recovery" '[ "$RC" -eq 3 ] && [ "$(rec sess-w source)" = transcript ]'

reset; { entry_ok; entry_err 40; entry_user; entry_sys; } > "$T"
put sess-w working 100 "{\"transcript_path\":\"$T\"}"
watch 3
check "an interrupt (a user entry) after the error: no detection" 'quiet && [ "$(rec sess-w activity)" = working ]'

reset; { entry_ok; node -e 'process.stdout.write(JSON.stringify({ type: "assistant", uuid: "u9", timestamp: new Date().toISOString(), message: { role: "assistant", content: [{ type: "text", text: "API Error: this reply merely starts like the harness prefix, with no flag" }] } }) + "\n")'; entry_sys; } > "$T"
put sess-w working 100 "{\"transcript_path\":\"$T\"}"
watch 3
check "text that starts with the harness prefix but carries no API-error flag: no detection (the flag is the signal)" 'quiet && [ "$(rec sess-w activity)" = working ]'

reset; { entry_ok; node -e 'process.stdout.write(JSON.stringify({ type: "assistant", uuid: "u9", timestamp: new Date().toISOString(), message: { role: "assistant", content: [{ type: "text", text: "I read: API Error: Connection lost mid-response in the log" }] } }) + "\n")'; } > "$T"
put sess-w working 100 "{\"transcript_path\":\"$T\"}"
watch 3
check "a normal reply that quotes an API error mid-text: no detection" 'quiet'

reset; { entry_ok; entry_err 40; entry_sys; } > "$T"
put sess-w working 20 "{\"transcript_path\":\"$T\"}"
watch 3
check "a record that changed 20 s ago (under 45 s): not looked at" 'quiet && [ "$(rec sess-w activity)" = working ]'

OUTSIDE="$SB/outside.jsonl"; { entry_ok; entry_err 40; entry_sys; } > "$OUTSIDE"
reset; ln -s "$OUTSIDE" "$PR/link.jsonl"
put sess-w working 100 "{\"transcript_path\":\"$PR/link.jsonl\"}"
watch 3
check "a transcript symlinked out of ~/.claude/projects: the detector skips the session" 'quiet && [ "$(rec sess-w activity)" = working ]'
reset
put sess-w working 100 "{\"transcript_path\":\"$OUTSIDE\"}"
watch 3
check "a transcript path outside ~/.claude/projects: skipped" 'quiet'
reset
put sess-w working 100 '{"transcript_path":"projects/relative.jsonl"}'
watch 2
check "a relative transcript path: skipped" 'quiet'

# ---- r3: a plain session is followed, and the cap holds when Stop (not StopFailure) ends each failed turn
reset; failed sess-w overloaded 1 40
printf '{"hook_event_name":"UserPromptSubmit","session_id":"sess-w","cwd":"%s"}' "$PROJ" | node "$H/activity.mjs" >/dev/null 2>&1
watch 3
check "role-less: a prompt typed after the failure moves the record to working, and no RESUME follows" '[ "$(rec sess-w activity)" = working ] && quiet'

entry_side() { printf '%s\n' '{"type":"assistant","isSidechain":true,"uuid":"sc1","timestamp":"2026-01-01T00:00:03.000Z","message":{"role":"assistant","content":[{"type":"text","text":"side chain work"}]},"sessionId":"sess-w"}'; }
reset; { entry_ok; entry_err 40; entry_sys; entry_side; } > "$T"
put sess-w working 100 "{\"transcript_path\":\"$T\"}"
watch 6
check "system and side-chain rows after the error entry are skipped: the failure is detected" '[ "$RC" -eq 3 ] && [ "$(rec sess-w source)" = transcript ]'

shift_resumes() { node -e 'const fs = require("fs"); const f = process.argv[1]; const out = fs.readFileSync(f, "utf8").split("\n").filter(Boolean).map((l) => { const r = JSON.parse(l); if (r.kind === "RESUME") { r.ts = new Date(Date.parse(r.ts) - 600000).toISOString(); if (r.failed_at) r.failed_at = new Date(Date.parse(r.failed_at) - 600000).toISOString(); } return JSON.stringify(r); }); fs.writeFileSync(f, out.join("\n") + "\n")' "$PEERS"; }
reset
STAMPS=""
for n in 1 2 3; do
  case $n in 1) AGE=40;; 2) AGE=130;; 3) AGE=490;; esac
  { entry_ok; entry_err "$AGE"; entry_sys; } > "$T"
  put sess-w idle 600 "{\"transcript_path\":\"$T\"}"
  watch 6
  check "Stop-ended turn, API-error entry, failure $n: RESUME $n/3" '[ "$RC" -eq 3 ] && echo "$OUT" | grep -q "automatic resume $n/3"'
  shift_resumes
done
{ entry_ok; entry_err 40; entry_sys; } > "$T"
put sess-w idle 600 "{\"transcript_path\":\"$T\"}"
watch 4
check "the fourth failure: no RESUME and no wake for the own session" 'quiet'
check "...exactly three RESUMEs were emitted in all, and the fourth failure is an API-FAILED row" '[ "$(rows RESUME)" -eq 3 ] && [ "$(rows API-FAILED)" -ge 1 ]'

reset; failed sess-w overloaded 1 40
earlier sess-w 3 40 50
watch 6
check "resumes older than the 45-minute window do not count: a failure with three of them behind it is streak 1" '[ "$RC" -eq 3 ] && echo "$OUT" | grep -q "automatic resume 1/3"'

# unchanged transcripts are not read again
reset; { entry_ok; entry_err 40; entry_sys; } > "$T"
OUT=$(node --input-type=module -e "
import { transcriptFailure } from '$H/lib-recovery.mjs';
const seen = new Map();
const a = transcriptFailure(process.argv[1], seen);
const b = transcriptFailure(process.argv[1], seen);
process.stdout.write(JSON.stringify({ first: a && a.error, second: b }));
" "$T" 2>&1)
check "a transcript whose (mtime, size) has not changed since the last look is not read again" 'echo "$OUT" | grep -q "\"first\":\"server_error\"" && echo "$OUT" | grep -q "\"second\":null"'

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
