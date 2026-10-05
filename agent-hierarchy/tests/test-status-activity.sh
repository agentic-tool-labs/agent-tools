#!/bin/bash
# agent-hierarchy — a Claude role session's own activity record (hooks/activity.mjs), what it does to
# the status file, and how records end: SessionEnd removes the session's own, and msg.mjs sweep drops
# any not written within its cutoff.
# HOME- and AGENT_HIERARCHY_DIR-redirected; real state untouched.
# Usage: bash tests/test-status-activity.sh   (exits 0 iff all cases pass)

unset AH_TEAM_FILE  # every session roster.mjs launches carries one; a test must not inherit it
unset CLAUDE_PID  # every Claude session exports one; a test must not inherit it

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
. "$PLUGIN/tests/lib-status-pool.sh"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-status-activity-test.XXXXXX")"
[ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (OUT=${OUT:0:300})"; fi
}

pool "$SANDBOX/p"
ROLE_SID="sess-role-0001"
OTHER_SID="sess-plain-0001"
HOME="$FAKEHOME" node --input-type=module -e "import { writeSessionRole } from '$H/lib-session-role.mjs'; writeSessionRole(process.argv[1], 'architect');" "$ROLE_SID"

# <event> <session id> [extra json fields]: activity.mjs on that hook event.
hook() { OUT=$(node -e 'const [e, s, cwd, x] = process.argv.slice(1); process.stdout.write(JSON.stringify({ hook_event_name: e, session_id: s, cwd, ...JSON.parse(x || "{}") }))' "$1" "$2" "$PROJ" "${3:-}" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/activity.mjs" 2>&1); RC=$?; }
rec() { node -e 'try { const a = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); console.log(eval(process.argv[2])); } catch { console.log("none"); }' "$HD/activity/$1.json" "$2"; }
mtime_of() { node -e 'console.log(require("fs").statSync(process.argv[1]).mtimeMs)' "$HD/activity/$1.json"; }
sentinel() { printf '{"written_at":"sentinel"}\n' > "$HD/status.json"; }
refreshed() { [ -f "$HD/status.json" ] && ! grep -q sentinel "$HD/status.json"; }
untouched() { grep -q sentinel "$HD/status.json"; }

# ---------------------------------------------------------------- AC 8: a role session's events
sentinel; hook UserPromptSubmit "$ROLE_SID"
check "UserPromptSubmit records working, silently, exit 0" '[ "$RC" = 0 ] && [ -z "$OUT" ] && [ "$(rec "$ROLE_SID" a.activity)" = working ]'
check "AC5 item 5: that activity change refreshes status.json" 'refreshed'
hook Stop "$ROLE_SID"
check "Stop records idle" '[ "$(rec "$ROLE_SID" a.activity)" = idle ]'
sentinel; hook Notification "$ROLE_SID" '{"message":"Claude needs your permission","notification_type":"permission_prompt"}'
check "a permission prompt records blocked, blocked_by permission, note null though the input has a message" '[ "$(rec "$ROLE_SID" "a.activity + \" \" + a.blocked_by + \" \" + a.note")" = "blocked permission null" ]'
check "AC5 item 5: so does that change" 'refreshed'
sentinel; hook PostToolUse "$ROLE_SID" '{"tool_name":"Bash"}'
check "PostToolUse after blocked records working" '[ "$(rec "$ROLE_SID" a.activity)" = working ] && [ "$(rec "$ROLE_SID" a.blocked_by)" = null ]'
check "AC5 item 5: and refreshes status.json" 'refreshed'
node -e 'const t = new Date(Date.now() - 3600 * 1000); require("fs").utimesSync(process.argv[1], t, t)' "$HD/activity/$ROLE_SID.json"
BEFORE=$(mtime_of "$ROLE_SID")
sentinel; hook PostToolUse "$ROLE_SID" '{"tool_name":"Read"}'
check "PostToolUse while already working rewrites nothing: the mtime is unchanged" '[ "$(mtime_of "$ROLE_SID")" = "$BEFORE" ]'
check "AC5 item 5: and leaves status.json alone" 'untouched'

# ---------------------------------------------------------------- AC 8: registration
reg() { node -e 'const h = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).hooks; const out = []; for (const [ev, arr] of Object.entries(h)) for (const e of arr) for (const k of e.hooks) if (k.command.includes("/hooks/activity.mjs")) out.push(ev + ":" + e.matcher + ":" + (k.async === true)); console.log(out.sort().join(" "))' "$PLUGIN/hooks/hooks.json"; }
check "hooks.json: PostToolUse async; UserPromptSubmit, Stop and Notification(permission_prompt) sync" '[ "$(reg)" = "Notification:permission_prompt:false PostToolUse:*:true Stop:*:false UserPromptSubmit:*:false" ]'

# ---------------------------------------------------------------- AC 8: who records
sentinel; hook UserPromptSubmit "$OTHER_SID"
check "a non-role session records nothing" '[ "$RC" = 0 ] && [ ! -e "$HD/activity/$OTHER_SID.json" ]'
check "...but its UserPromptSubmit still refreshes status.json" 'refreshed'
sentinel; hook Stop "$OTHER_SID"
check "...and so does its Stop" 'refreshed'
sentinel; hook PostToolUse "$OTHER_SID" '{"tool_name":"Bash"}'
check "...while its PostToolUse touches nothing" '[ ! -e "$HD/activity/$OTHER_SID.json" ] && untouched'
rm -f "$HD/activity/$ROLE_SID.json"
hook UserPromptSubmit "$ROLE_SID" '{"agent_id":"a1","agent_type":"task-gopher:task-gopher"}'
check "a subagent of a role session records nothing" '[ "$RC" = 0 ] && [ ! -e "$HD/activity/$ROLE_SID.json" ]'

# ---------------------------------------------------------------- AC 8: SessionEnd
hook UserPromptSubmit "$ROLE_SID"
sentinel
printf '{"session_id":"%s","cwd":"%s","hook_event_name":"SessionEnd"}' "$ROLE_SID" "$PROJ" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/sessionend-roster.mjs" >/dev/null 2>&1; RC=$?
check "SessionEnd removes the session's own record" '[ "$RC" = 0 ] && [ ! -e "$HD/activity/$ROLE_SID.json" ]'
check "AC5 item 5: and that removal refreshes status.json" 'refreshed'

# ---------------------------------------------------------------- the sweep
activity sess-old idle "2026-01-01T00:00:00.000Z"
activity sess-new idle "2026-01-01T00:00:00.000Z"
node -e 'const t = new Date(Date.now() - 8 * 86400 * 1000); require("fs").utimesSync(process.argv[1], t, t)' "$HD/activity/sess-old.json"
sentinel
OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/msg.mjs" sweep --cwd "$PROJ" 2>&1); RC=$?
check "msg.mjs sweep deletes an activity record older than its cutoff and keeps a fresh one" '[ "$RC" = 0 ] && [ ! -e "$HD/activity/sess-old.json" ] && [ -e "$HD/activity/sess-new.json" ]'
check "...its output is unchanged, and the deletion refreshes status.json" '[ "$OUT" = "{\"archived\":0}" ] && refreshed'

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
