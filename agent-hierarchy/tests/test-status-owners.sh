#!/bin/bash
# agent-hierarchy — the `owners` key of status.json and the session records behind it.
# Each live team belongs to one orchestrator process; `owners` groups the teams by that process and lists the
# session ids recorded for it (session-pids.jsonl, written by SessionStart and by the team-writing CLI verbs).
# HOME- and AGENT_HIERARCHY_DIR-redirected; real state untouched.
# Usage: bash tests/test-status-owners.sh   (exits 0 iff all cases pass)

unset AH_TEAM_FILE  # every session roster.mjs launches carries one; a test must not inherit it
unset CLAUDE_PID CLAUDE_CODE_SESSION_ID  # every Claude session exports these; a test must not inherit them

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
. "$PLUGIN/tests/lib-status-pool.sh"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-status-owners-test.XXXXXX")"
[ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] || { echo "mktemp failed"; exit 1; }
sleep 300 & OTHER=$!
trap 'kill "$OTHER" 2>/dev/null; rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name"; fi
}

REF="2026-01-01T12:00:00.000Z"
ARCH='{"role":"architect","name":"demo-architect","route":"pane","kind":"codex","transport_id":"w1:p1"}'
REV='{"role":"reviewer","name":"demo-reviewer","route":"pane","kind":"codex","transport_id":"w1:p2"}'

# <team name or -> <pid> <session id or null> <members json>: a live team owned by <pid>.
owned() {
  local path="$HD/team.json"
  [ "$1" != - ] && { mkdir -p "$HD/teams"; path="$HD/teams/$1.json"; }
  node -e 'const [p, pid, sid, members] = process.argv.slice(1); require("fs").writeFileSync(p, JSON.stringify({ team_id: "t-demo", created: new Date().toISOString(), orchestrator: { session_id: sid === "null" ? null : sid, pid: Number(pid) }, members: JSON.parse(members) }) + "\n")' "$path" "$2" "$3" "$4"
}
# <session id> <pid>: a session record.
row() { node --input-type=module -e "import { appendSessionPid } from '$H/lib-status.mjs'; appendSessionPid(process.argv[1], process.argv[2], Number(process.argv[3]));" "$HD" "$1" "$2"; }

# ---- producer
pool "$SANDBOX/two"
owned alpha $$ null "[$ARCH]"; owned beta "$OTHER" null "[$REV]"
row sess-a $$; row sess-b "$OTHER"
activity pane-demo-architect working "$(at -60000)"
request 20260101-115800-w001 architect build-step "$(at -120000)" small demo-architect alpha
dispatch 20260101-115800-w001 architect "$(at -60000)"; stub 20260101-115800-w001
status "$REF"
check "two owners: one entry each, with its own sessions and teams" '[ "$(jq_doc "o.owners.map(x => x.sessions.join() + \"/\" + x.teams.join()).sort().join(\" \")")" = "sess-a/alpha sess-b/beta" ]'
check "per-owner timeline counts only that owner's own teams (1 live 1 out vs 1 live 0 out)" '[ "$(jq_doc "o.owners.map(x => x.teams[0] + \":\" + x.timeline[0].live + \"/\" + x.timeline[0].out).sort().join(\" \")")" = "alpha:1/1 beta:1/0" ]'
check "the top-level timeline stays pool-wide (2 live, 1 out) and the other top-level keys are unchanged" '[ "$(jq_doc "o.timeline[0].live + \"/\" + o.timeline[0].out + \" \" + Object.keys(o).join()")" = "2/1 schema,written_at,expires_at,enabled,member_sessions,teams,timeline,owners" ]'
check "every team object is in exactly one owner entry" '[ "$(jq_doc "o.teams.length + \" \" + o.owners.reduce((n, x) => n + x.teams.length, 0)")" = "2 2" ]'

pool "$SANDBOX/clear"
owned - $$ null "[$ARCH]"
row sess-old $$; row sess-new $$
status "$REF"
check "two rows for one pid (a /clear): both session ids, newest first" '[ "$(jq_doc "o.owners[0].sessions.join()")" = "sess-new,sess-old" ]'

pool "$SANDBOX/same"
owned - $$ null "[$ARCH]"; owned named $$ null "[$REV]"
status "$REF"
check "default team and a named team with one pid: one entry, teams [null, name]" '[ "$(jq_doc "o.owners.length + JSON.stringify(o.owners[0].teams)")" = "1[null,\"named\"]" ]'
check "no rows and no orchestrator.session_id: sessions is []" '[ "$(jq_doc "JSON.stringify(o.owners[0].sessions)")" = "[]" ]'

pool "$SANDBOX/teamsid"
owned - $$ sess-in-team "[$ARCH]"
status "$REF"
check "orchestrator.session_id on the team file appears in sessions" '[ "$(jq_doc "o.owners[0].sessions.join()")" = "sess-in-team" ]'

pool "$SANDBOX/orphan"
owned - $$ null "[$ARCH]"; owned dead 2147483646 null "[$REV]"
row sess-dead 2147483646
status "$REF"
check "a team with a dead orchestrator pid is in no owner entry, and its rows are ignored" '[ "$(jq_doc "o.owners.length + \" \" + JSON.stringify(o.owners[0].teams) + \" \" + o.owners[0].sessions.length")" = "1 [null] 0" ]'

pool "$SANDBOX/cap"
owned - $$ null "[$ARCH]"
for i in $(seq 1 40); do row "sess-$i" $$; done
status "$REF"
check "sessions is capped at 32, newest first" '[ "$(jq_doc "o.owners[0].sessions.length + o.owners[0].sessions[0]")" = "32sess-40" ]'

pool "$SANDBOX/repeat"
owned - $$ null "[$ARCH]"
row sess-r $$; row sess-r $$
check "a row repeating the latest one is not appended" '[ "$(wc -l < "$HD/session-pids.jsonl" | tr -d " ")" = 1 ]'

# ---- SessionStart
# Runs the hook from a driver process whose pid is the hook's parent, and prints that pid. The driver
# owns the default team first, so the status document the hook leaves has a team to list it under.
hook() { # <payload json> -> driver pid
  HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node -e '
    const { spawnSync } = require("child_process");
    const fs = require("fs");
    if (fs.existsSync(process.env.AGENT_HIERARCHY_DIR)) fs.writeFileSync(process.env.AGENT_HIERARCHY_DIR + "/team.json", JSON.stringify({ team_id: "t-drv", created: new Date().toISOString(), orchestrator: { session_id: null, pid: process.pid }, members: [] }));
    spawnSync("node", [process.argv[1]], { input: process.argv[2], env: process.env, stdio: ["pipe", "ignore", "ignore"] });
    process.stdout.write(String(process.pid));' "$H/sessionstart.mjs" "$1"
}

pool "$SANDBOX/ss"
P=$(hook "{\"session_id\":\"sess-top\",\"source\":\"startup\",\"cwd\":\"$PROJ\"}")
check "SessionStart in a top-level session writes {session_id, pid = hook ppid} into the pool" '[ "$(node -e "const r = require(\"fs\").readFileSync(process.argv[1], \"utf8\").trim().split(\"\n\").map(JSON.parse); process.stdout.write(r.length + \" \" + r[0].session_id + \" \" + r[0].pid)" "$HD/session-pids.jsonl")" = "1 sess-top $P" ]'
check "the status.json SessionStart leaves already lists the session under its team" '[ "$(node -e "const o = JSON.parse(require(\"fs\").readFileSync(process.argv[1], \"utf8\")); process.stdout.write(o.owners.map((x) => x.sessions.join()).join())" "$HD/status.json")" = sess-top ]'

pool "$SANDBOX/ss-sub"
hook "{\"session_id\":\"sess-sub\",\"source\":\"startup\",\"cwd\":\"$PROJ\",\"agent_id\":\"a1\",\"agent_type\":\"reviewer\"}" >/dev/null
check "SessionStart in a subagent writes no row" '[ ! -e "$HD/session-pids.jsonl" ]'

pool "$SANDBOX/ss-nodir"
rm -rf "$HD"
hook "{\"session_id\":\"sess-nd\",\"source\":\"startup\",\"cwd\":\"$PROJ\"}" >/dev/null
check "SessionStart with no hierarchy dir writes nothing and creates no dir" '[ ! -e "$HD/session-pids.jsonl" ]'

# ---- CLI
pool "$SANDBOX/cli"
cli() { HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" CLAUDE_CODE_SESSION_ID=sess-cli "$@"; }
owned - 2147483646 null "[$ARCH]"
cli env CLAUDE_PID=$$ node "$H/roster.mjs" adopt --orchestrator-pid $$ --cwd "$PROJ" >/dev/null 2>&1
check "adopt with CLAUDE_PID equal to the pid it records: a row is written" '[ "$(grep -c "\"sess-cli\"" "$HD/session-pids.jsonl" 2>/dev/null)" = 1 ]'
rm -f "$HD/session-pids.jsonl"
owned - 2147483646 null "[$ARCH]"
cli env CLAUDE_PID=$$ node "$H/roster.mjs" adopt --orchestrator-pid "$OTHER" --cwd "$PROJ" >/dev/null 2>&1
check "adopt naming another pid binds nothing: no row" '[ ! -e "$HD/session-pids.jsonl" ]'

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
