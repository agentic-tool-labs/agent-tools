#!/bin/bash
# agent-hierarchy — one session owning several live teams (spec 0066): roster.mjs, msg.mjs and the
# hooks share one owner rule, act on every owned team or refuse with the list, and a member's name
# picks its team. HOME- and AGENT_HIERARCHY_DIR-redirected; the owner pid is this shell's.
# Usage: bash tests/test-multi-owned-teams.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
# Every Claude session exports some of these; a test must not inherit any of them.
unset AH_TEAM_FILE CLAUDE_PID AH_ROSTER HERDR_ENV HERDR_PANE_ID TMUX_PANE AGENT_HIERARCHY_DIR
# AH_TEST_HOOKS points the single-team rows at another build's hooks, and AH_WRITE_GOLDEN=1 makes
# them write their goldens instead of comparing: that is how the goldens were captured from the
# build before one session could own several teams.
H="${AH_TEST_HOOKS:-$PLUGIN/hooks}"
GOLDEN="$PLUGIN/tests/fixtures/0066-single-team"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:400})"; fi
}

SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-multi-owned-test.XXXXXX")"
[ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
HD="$SANDBOX/hier"
PROJ="$SANDBOX/myrepo"
OWNER=$$

# roster.mjs / msg.mjs as this shell's session: CLAUDE_PID is the owner pid, output in OUT.
run_roster() { OUT=$(env -u HERDR_ENV HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" CLAUDE_PID="$OWNER" node "$H/roster.mjs" "$@" --cwd "$PROJ" 2>&1); RC=$?; }
run_msg() { OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" CLAUDE_PID="$OWNER" node "$H/msg.mjs" "$@" --cwd "$PROJ" 2>&1); RC=$?; }
# <js expr over C (lib-config), R (lib-roster)>: its value, in OUT.
eval_lib() {
  OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node --input-type=module -e "
    const C = await import('$H/lib-config.mjs'); const R = await import('$H/lib-roster.mjs');
    process.stdout.write(String($1));
  " 2>&1); RC=$?
}
# <js expr over the parsed OUT o>: its value (strings bare, anything else as JSON).
jget() {
  node -e 'const o=JSON.parse(process.argv[1]);const v=(new Function("o","return ("+process.argv[2]+")"))(o);process.stdout.write(typeof v==="string"?v:JSON.stringify(v))' "$OUT" "$1" 2>/dev/null
}
# A fresh HOME, repo and hierarchy dir.
fresh() {
  rm -rf "$FAKEHOME" "$PROJ" "$HD"
  mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude" "$HD"
}
# <team> [flags…]: commit team <team> (a reviewer and an architect), owned by this shell.
commit() {
  local t=$1; shift
  run_roster create --team "$t" --commit --verified "[{\"name\":\"$t-reviewer\",\"role\":\"reviewer\",\"route\":\"peer\"},{\"name\":\"$t-architect\",\"role\":\"architect\",\"route\":\"peer\"}]" --transport terminal --roster-level repo "$@"
  [ "$RC" = 0 ] || { echo "fixture: commit $t failed: $OUT"; exit 1; }
}
# Every file under the hierarchy dir with its hash: equal before and after means nothing was written.
snapshot() { (cd "$HD" && find . -type f | sort | xargs shasum 2>/dev/null); }
listed() { [[ "$OUT" == *'"foo"'* ]] && [[ "$OUT" == *'"bar"'* ]]; }
msgcount() { find "$HD/msgs" -name '*.md' 2>/dev/null | wc -l | tr -d ' '; }

# The hooks take their caller's pid from their parent, so a hook runs under a shell that first
# records itself as the owner of every team here.
cat > "$SANDBOX/own.js" <<'EOF'
const fs = require("fs"), p = require("path");
const [d, pid] = process.argv.slice(2);
const teams = p.join(d, "teams");
const files = [p.join(d, "team.json"), ...(fs.existsSync(teams) ? fs.readdirSync(teams).map((x) => p.join(teams, x)) : [])];
for (const f of files) {
  if (!fs.existsSync(f)) continue;
  const t = JSON.parse(fs.readFileSync(f, "utf8"));
  t.orchestrator = { ...(t.orchestrator || {}), pid: Number(pid) };
  fs.writeFileSync(f, JSON.stringify(t, null, 2));
}
EOF
hook_as_owner() { # <hook file> <payload json>: output in OUT
  OUT=$(printf '%s' "$2" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" sh -c 'node "$1" "$2" "$$" && node "$3"; exit $?' _ "$SANDBOX/own.js" "$HD" "$H/$1" 2>&1); RC=$?
}
# <name> <members json> <roster json>: a team file owned by this shell, with a fixed id.
team_file() {
  node --input-type=module -e "const R = await import('$H/lib-roster.mjs'); R.writeTeam('$HD', { version: 1, team_id: 'T-$1', created: '2026-09-30T00:00:00Z', roster_level: 'repo', transport: 'terminal', roster: $3, orchestrator: { pid: $OWNER }, members: $2, partial: false }, '$1');"
}
# Rosters X and Y, and the hierarchy switched on.
config() {
  cat > "$PROJ/.claude/agent-hierarchy.json" <<'EOF'
{ "version": 1, "enabled": true,
  "rosters": {
    "X": { "route": "peer", "members": [{ "role": "reviewer", "model": "sonnet" }, { "role": "architect", "model": "opus" }] },
    "Y": { "route": "peer", "members": [{ "role": "reviewer", "model": "sonnet" }, { "role": "task-runner", "model": "haiku", "route": "subagent" }] }
  } }
EOF
}
FOO_MEMBERS='[{"name":"foo-reviewer","role":"reviewer","route":"peer"},{"name":"foo-architect","role":"architect","route":"peer"},{"name":"foo-coder","role":"implementor","route":"pane","kind":"codex","transport_id":"p-foo"}]'
BAR_MEMBERS='[{"name":"bar-reviewer","role":"reviewer","route":"peer"},{"name":"bar-architect","role":"architect","route":"peer"},{"name":"bar-task-runner","role":"task-runner","route":"subagent"}]'
peer_up() { # <name> <team> <role>: a live peer record
  node -e 'const [f,n,t,r,pid]=process.argv.slice(1);require("fs").appendFileSync(f,JSON.stringify({type:"peer",status:"up",role:r,name:n,team:t,pid:Number(pid),session_id:"s-"+n,ts:new Date().toISOString()})+"\n")' "$HD/peers.jsonl" "$1" "$2" "$3" "$OWNER"
}
payload() { # <session> <tool> <tool_input json>
  printf '{"session_id":"%s","cwd":"%s","tool_name":"%s","tool_input":%s}' "$1" "$PROJ" "$2" "$3"
}
SS_PAYLOAD="{\"session_id\":\"ss\",\"cwd\":\"$PROJ\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}"
context() { node -e 'const o=JSON.parse(process.argv[1]);process.stdout.write((o.hookSpecificOutput||{}).additionalContext||o.additionalContext||"")' "$OUT" 2>/dev/null; }
# <text> with this run's paths, pids, ids, times and version replaced, so two builds compare.
normalize() {
  printf '%s\n' "$1" | sed -e "s|$SANDBOX|<SANDBOX>|g" -e "s|$(dirname "$H")|<PLUGIN>|g" \
    -e 's/[0-9]\{8\}-[0-9]\{6\}-[a-z0-9]\{4\}/<ID>/g' -e 's/[0-9]\{4\}-[0-9][0-9]-[0-9][0-9]T[0-9:.]*[-+Z][0-9:]*/<TS>/g' \
    -e 's/(v[0-9][0-9.]*)/(v<VERSION>)/g' -e 's/"pid": *[0-9]\{1,\}/"pid": <PID>/g' -e 's/"orchestrator_pid": *[0-9]\{1,\}/"orchestrator_pid": <PID>/g' \
    -e 's/"plan_token": *"[^"]*"/"plan_token": "<TOKEN>"/g' -e 's/"age": *"[^"]*"/"age": "<AGE>"/g' -e 's/[0-9]\{1,\}[smhd] ago/<AGE> ago/g'
}
golden() { # <name> <text>: true when <text> matches the golden (or, with AH_WRITE_GOLDEN=1, writes it)
  if [ "${AH_WRITE_GOLDEN:-}" = 1 ]; then mkdir -p "$GOLDEN"; normalize "$2" > "$GOLDEN/$1"; return 0; fi
  [ "$(normalize "$2")" = "$(cat "$GOLDEN/$1" 2>/dev/null)" ]
}

# ================================================================ M1 bare verbs refuse
fresh; commit foo; commit bar
S0=$(snapshot)
for c in "disband --plan" "resync" "spawn-one reviewer --dry-run" "stream-status"; do
  run_roster $c
  check "M1 a bare \`$c\` refuses, lists both teams and writes nothing" '[ $RC != 0 ] && [[ "$OUT" == *"owns 2 live teams"* ]] && listed && [ "$(snapshot)" = "$S0" ]'
done

# ================================================================ M2 a member name picks the team
run_roster dismiss bar-reviewer --plan
check "M2 dismiss bar-reviewer --plan with no --team plans against team bar" '[ $RC = 0 ] && [[ "$OUT" == *bar-reviewer* ]] && [[ "$OUT" != *foo-reviewer* ]] && [[ "$OUT" == *"teams/bar.json"* ]]'
run_roster dismiss nobody-reviewer --plan
check "M2 a name in neither team is refused with the list" '[ $RC != 0 ] && listed && [[ "$OUT" == *"none of them"* ]]'

# ================================================================ M3 one owner rule
# <name> <orchestrator json>: a team file with that owner record.
team_orch() {
  node --input-type=module -e "const R = await import('$H/lib-roster.mjs'); R.writeTeam('$HD', { version: 1, team_id: 'T-$1', created: '2026-09-30T00:00:00Z', roster_level: 'repo', transport: 'terminal', orchestrator: $2, members: [], partial: false }, '$1');"
}
DEAD=$(sh -c 'echo $$')
fresh
team_orch a "{ session_id: 'SA', pid: 1 }"
team_orch b "{ session_id: 'SB', pid: $OWNER }"
team_orch c "{ pid: $OWNER }"
team_orch e "{ pid: $DEAD }"
for t in a b c e; do run_msg new --team "$t" --to reviewer --from orchestrator --slug "x$t"; done
# <pid> [session]: each tool's owned set, as roster.mjs's refusal text, resolveTeamScope's list and msg.mjs list's tags.
owned_by() {
  local s=()
  [ -n "${2:-}" ] && s=(--session "$2")
  OUT=$(env -u HERDR_ENV HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/roster.mjs" create --plan --orchestrator-pid "$1" "${s[@]}" --cwd "$PROJ" 2>&1); R_SET=$OUT
  eval_lib "JSON.stringify(C.resolveConfig('$PROJ', {pid: $1${2:+, sessionId: '$2'}}).ownedTeams)"; C_SET=$OUT
  OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/msg.mjs" list --orchestrator-pid "$1" "${s[@]}" --cwd "$PROJ" 2>&1)
  M_SET=$(jget 'o.map(r => r.team).sort().join()')
}
# Same session, different pid (a) is owned; same pid, conflicting session (b) is not; same pid and
# no session on the team (c) is owned.
owned_by "$OWNER" SA
check "M3 cases 1-3, session SA: roster.mjs, resolveTeamScope and msg.mjs all own a and c" \
  '[[ "$R_SET" == *"owns 2 live teams (\"a\", \"c\")"* ]] && [ "$C_SET" = "[\"a\",\"c\"]" ] && [ "$M_SET" = "a,c" ]'
# Same pid, the caller has no session id and the team has one (b): owned; a's pid isn't the caller's.
owned_by "$OWNER"
check "M3 case 4, no session: all three own b and c" \
  '[[ "$R_SET" == *"owns 2 live teams (\"b\", \"c\")"* ]] && [ "$C_SET" = "[\"b\",\"c\"]" ] && [ "$M_SET" = "b,c" ]'
# A dead pid and no session: roster.mjs and msg.mjs own nothing; a hook, which takes its parent's
# pid as live, still matches e by pid.
owned_by "$DEAD"
check "M3 case 5, a dead pid: roster.mjs and msg.mjs own nothing, while a hook caller owns e by pid" \
  '[[ "$R_SET" != *"live teams"* ]] && [[ "$R_SET" != *"already exists"* ]] && [ -z "$M_SET" ] && [ "$C_SET" = "[\"e\"]" ]'

# ================================================================ M7 msg.mjs
fresh; commit foo; commit bar
run_msg new --to reviewer --from orchestrator --slug m7 --to-name bar-reviewer
check "M7 new --to-name bar-reviewer with no --team writes team: bar" '[ $RC = 0 ] && grep -q "^team: bar$" "$(jget o.path)"'
N0=$(msgcount)
run_msg new --to reviewer --from orchestrator --slug m7b --to-name nobody
check "M7 new to a name in neither team refuses and writes nothing" '[ $RC != 0 ] && listed && [ "$(msgcount)" = "$N0" ]'
run_msg new --to reviewer --from orchestrator --slug m7c --to-name foo-reviewer
run_msg list
check "M7 list with no --team returns both teams' rows, each tagged with its team" \
  '[ $RC = 0 ] && [ "$(jget "o.map(r => r.slug + \"=\" + r.team).sort().join()")" = "m7=bar,m7c=foo" ]'

# ================================================================ M4 injection
# <team>: that team's part of the SessionStart text in CTX, from its heading to the next heading.
section() { printf '%s\n' "$CTX" | awk -v h="Team $1 (roster" 'index($0, h) == 1 { on = 1; print; next } on && (/^Team [a-z]+ \(roster/ || /^route:/) { on = 0 } on'; }
fresh; config
team_file foo "$FOO_MEMBERS" '"X"'
team_file bar "$BAR_MEMBERS" '"Y"'
hook_as_owner sessionstart.mjs "$SS_PAYLOAD"
CTX=$(context)
check "M4 SessionStart with two owned teams leads with the owned-teams line" \
  '[[ "$CTX" == *"You own 2 live teams: bar, foo. Pass --team <name> to roster.mjs team verbs and to msg.mjs new; a member name already says its team."* ]]'
check "M4 ... foo's part names its roster and holds its own members only" \
  '[[ "$(section foo)" == "Team foo (roster X):"* ]] && [[ "$(section foo)" == *"reviewer=foo-reviewer"* ]] && [[ "$(section foo)" == *"architect=foo-architect"* ]] && [[ "$(section foo)" != *bar-* ]]'
check "M4 ... bar's part names its roster and holds its own members and routes only" \
  '[[ "$(section bar)" == "Team bar (roster Y):"* ]] && [[ "$(section bar)" == *"reviewer=bar-reviewer"* ]] && [[ "$(section bar)" == *"task-runner=(subagent)"* ]] && [[ "$(section bar)" != *foo-* ]]'
check "M4 the directive's role lines name each team's architect, and each command carries its own --team" \
  '[[ "$CTX" == *"\"foo-architect\" (team foo)"* ]] && [[ "$CTX" == *"\"bar-architect\" (team bar)"* ]] && [[ "$CTX" == *" architect --team foo --cwd "* ]] && [[ "$CTX" == *" architect --team bar --cwd "* ]]'
check "M4 ... roster X has an architect row and Y doesn't: foo's command is spawn-one, bar's spawn-ad-hoc" \
  '[[ "$CTX" == *"team foo: \`node \"$H/roster.mjs\" spawn-one architect --team foo"* ]] && [[ "$CTX" == *"team bar: \`node \"$H/roster.mjs\" spawn-ad-hoc architect --team bar"* ]]'

# ================================================================ M5 route gate
AGENT_ARCH=$(payload m5 Agent '{"subagent_type":"ah:architect","prompt":"design it"}')
fresh; config
team_file foo "$FOO_MEMBERS" '"X"'
team_file bar "$BAR_MEMBERS" '"Y"'
peer_up bar-architect bar architect
hook_as_owner pretooluse-route-gate.mjs "$AGENT_ARCH"
check "M5 a chain-role dispatch with a live bar-architect and none in foo names it with its team" \
  '[[ "$OUT" == *"bar-architect (team bar)"* ]] && [[ "$OUT" == *"SendMessage the one whose team owns this work"* ]] && [[ "$OUT" != *foo-architect* ]]'
rm -f "$HD/peers.jsonl"; peer_up foo-architect foo architect
hook_as_owner pretooluse-route-gate.mjs "$AGENT_ARCH"
check "M5 ... and a live foo-architect with none in bar, the team that sorts last" \
  '[[ "$OUT" == *"foo-architect (team foo)"* ]] && [[ "$OUT" != *bar-architect* ]]'
rm -f "$HD/peers.jsonl"
hook_as_owner pretooluse-route-gate.mjs "$AGENT_ARCH"
check "M5 with no live architect in either team, the no-live-peer outcome" '[[ "$OUT" == *"no live Architect peer"* ]]'

# ================================================================ M6 strictest wins
# bar's scope allows a raw herdr call to foo-coder (not its member); foo's denies it.
HERDR_FOO=$(payload m6 Bash '{"command":"herdr agent send-keys foo-coder hello"}')
fresh; config
team_file foo "$FOO_MEMBERS" '"X"'
team_file bar "$BAR_MEMBERS" '"Y"'
hook_as_owner pretooluse-herdr-name-gate.mjs "$HERDR_FOO"
check "M6 a check that allows for bar and denies for foo denies, naming foo's member" \
  '[[ "$OUT" == *"permissionDecision\":\"deny"* ]] && [[ "$OUT" == *"foo-coder is a codex member"* ]]'

# ================================================================ M9 reads show every team
fresh; config
team_file foo "$FOO_MEMBERS" '"X"'
team_file bar "$BAR_MEMBERS" '"Y"'
# `/hierarchy status` is lib-config.mjs run in the repo; like a hook, it takes its parent's pid.
OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" sh -c 'node "$1" "$2" "$$" && cd "$3" && node "$4"; exit $?' _ "$SANDBOX/own.js" "$HD" "$PROJ" "$H/lib-config.mjs" 2>&1); RC=$?
check "M9 /hierarchy status with two owned teams leads with the owned-teams line and gives each team its part" \
  '[ $RC = 0 ] && [[ "$OUT" == "You own 2 live teams: bar, foo."* ]] && [[ "$OUT" == *"Team bar (roster Y):"*"Team name: bar (team)"*"Team: T-bar"*"Team foo (roster X):"*"Team name: foo (team)"*"Team: T-foo"* ]]'
node "$SANDBOX/own.js" "$HD" "$OWNER"
run_msg roster --plain
check "M9 msg.mjs roster with no --team prints both teams' tables, each named, and exits 0" \
  '[ $RC = 0 ] && [[ "$OUT" == "Team bar (roster Y):"*"Team foo (roster X):"* ]]'
run_roster doctor --json
check "M9 doctor's team row names both teams and their rosters" \
  '[[ "$(jget "o.rows.find(r => r.name === \"team\").detail")" == *"bar (roster Y"*"foo (roster X"* ]]'

# ================================================================ M10 role set checks every prefix
# Teams aa and team-ui: team-ui sorts last, so a check of the first team alone would miss it. A
# review role named ui-reviewer collides with prefix team-ui: the Reviewer's peer name there,
# team-ui-reviewer, would parse as ui-reviewer.
fresh; config
team_file aa '[]' null
team_file team-ui '[]' null
UIQ="team team-ui's prefix \"team-ui\""
run_roster role set ui-reviewer --class review --description "UI review." --scaffold user --level global
check "M10 a custom role name that collides only with team-ui's prefix is refused, naming team-ui" \
  '[ $RC != 0 ] && [[ "$OUT" == *"$UIQ collides"* ]]'
LONG=abcdefghijklmnopqrstuvwxyz # 26 characters: aa-<name> is 29, team-ui-<name> is 34
run_roster role set "$LONG" --class implement --description "a helper" --scaffold user --level global
check "M10 a name too long only under team-ui's prefix gets the Herdr warning naming team-ui, and not aa" \
  '[[ "$OUT" == *"under $UIQ its peer name"* ]] && [[ "$OUT" != *"team aa"* ]]'

# ================================================================ M11 the other gates
# Each check uses foo, the owned team that sorts last, so a check of the first team alone misses it.
BRIEF='[hierarchy-peer-brief reply-to=\"sender\" task=\"x\"]'
fresh; config
team_file foo "$FOO_MEMBERS" '"X"'
team_file bar "$BAR_MEMBERS" '"Y"'
# zed records another session, which conflicts with the caller's, so the caller doesn't own it.
node --input-type=module -e "const R = await import('$H/lib-roster.mjs'); R.writeTeam('$HD', { version: 1, team_id: 'T-zed', created: '2026-09-30T00:00:00Z', roster_level: 'repo', transport: 'terminal', orchestrator: { session_id: 'S-zed', pid: $OWNER }, members: [{ name: 'zed-ultra-advisor', role: 'ultra-advisor', route: 'peer' }], partial: false }, 'zed');"
hook_as_owner pretooluse-ultra-gate.mjs "$(payload m11 SendMessage "{\"to\":\"foo-ultra-advisor\",\"message\":\"$BRIEF\"}")"
check "M11 the ultra-gate gates an owned team's foo-ultra-advisor" '[[ "$OUT" == *"Ultra-Advisor escalation is user-gated"* ]]'
hook_as_owner pretooluse-ultra-gate.mjs "$(payload m11 SendMessage "{\"to\":\"zed-ultra-advisor\",\"message\":\"$BRIEF\"}")"
check "M11 ... and doesn't gate zed's ultra-advisor, a team the caller doesn't own" '[ -z "$OUT" ]'
# A request in foo's pool, old enough to be past its eta, that this session dispatched.
node "$SANDBOX/own.js" "$HD" "$OWNER"
run_msg new --team foo --to architect --from orchestrator --slug owed --to-name foo-architect --eta small
OWED=$(jget o.path); OWED_ID=$(jget o.id)
perl -i -pe 's/^created: .*/created: 2020-01-01T00:00:00Z/' "$OWED"
printf '{"type":"dispatch","session_id":"m11","request_id":"%s","to":"architect","created":"2020-01-01T00:00:00Z"}\n' "$OWED_ID" >> "$FAKEHOME/.claude/agent-hierarchy.peer-pending.jsonl"
hook_as_owner stop-orchestrator-liveness.mjs "{\"session_id\":\"m11\",\"cwd\":\"$PROJ\"}"
check "M11 stop-orchestrator-liveness counts an open exchange that exists only in foo" '[[ "$OUT" == *"\"decision\":\"block\""* ]] && [[ "$OUT" == *"$OWED_ID"* ]]'
# A brief to foo-reviewer whose request is for the architect: resolved against foo, it is the wrong to:.
hook_as_owner pretooluse-msg-gate.mjs "$(payload m11b SendMessage "{\"to\":\"foo-reviewer\",\"notify_when_idle\":true,\"message\":\"$BRIEF\\n[hierarchy-msg $OWED]\"}")"
check "M11 msg-gate resolves a foo- name against foo's config" '[[ "$OUT" == *"wrong to:"* ]]'

# ================================================================ M12 the default team's name
# The session owns the default team (team.json) and foo.
fresh; config
node -e 'const fs=require("fs");const f=process.argv[1];const d=JSON.parse(fs.readFileSync(f,"utf8"));d.roster={route:"peer",members:[{role:"reviewer",model:"sonnet"}]};fs.writeFileSync(f,JSON.stringify(d,null,2))' "$PROJ/.claude/agent-hierarchy.json"
node --input-type=module -e "const R = await import('$H/lib-roster.mjs'); R.writeTeam('$HD', { version: 1, team_id: 'T-default', created: '2026-09-30T00:00:00Z', roster_level: 'repo', transport: 'terminal', roster: null, orchestrator: { pid: $OWNER }, members: [{ name: 'myrepo-reviewer', role: 'reviewer', route: 'peer' }], partial: false }, null);"
team_file foo "$FOO_MEMBERS" '"X"'
run_roster spawn-one reviewer --team @default --dry-run
check "M12 spawn-one reviewer --team @default plans against team.json" '[ $RC = 0 ] && [[ "$OUT" == *"$HD/team.json"* ]] && [[ "$OUT" != *"teams/foo.json"* ]]'
run_roster stream-status
check "M12 the refusal list shows the default team as @default" '[ $RC != 0 ] && [[ "$OUT" == *"(\"@default\", \"foo\")"* ]]'
run_roster stream-status --team @other
check "M12 --team @other is refused" '[ $RC != 0 ] && [[ "$OUT" == *"--team:"* ]]'
hook_as_owner sessionstart.mjs "$SS_PAYLOAD"
CTX=$(context)
check "M12 the lead line and the directive's default-team label and commands show @default" \
  '[[ "$CTX" == *"You own 2 live teams: @default, foo."* ]] && [[ "$CTX" == *"\"myrepo-architect\" (team @default)"* ]] && [[ "$CTX" == *" architect --team @default --cwd "* ]]'
AHCLI_ROSTER="node \"$H/roster.mjs\" spawn-one reviewer --team @default --dry-run --cwd $PROJ"
OUT=$(node -e 'process.stdout.write(JSON.stringify({session_id:"m12",cwd:process.argv[1],tool_name:"Bash",tool_input:{command:process.argv[2]}}))' "$PROJ" "$AHCLI_ROSTER" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/pretooluse-ah-cli.mjs" 2>&1)
check "M12 pretooluse-ah-cli allows a roster.mjs command with --team @default" '[[ "$OUT" == *"\"permissionDecision\":\"allow\""* ]]'
CLOSE_DEFAULT="node \"$H/roster.mjs\" disband --team @default --close --confirm --plan-token t --cwd $PROJ"
OUT=$(node -e 'process.stdout.write(JSON.stringify({session_id:"m12",cwd:process.argv[1],tool_name:"Bash",tool_input:{command:process.argv[2]}}))' "$PROJ" "$CLOSE_DEFAULT" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/pretooluse-disband-close-gate.mjs" 2>&1)
check "M12 the close gate's confirmation for --team @default names the default team's members" \
  '[[ "$OUT" == *"\"permissionDecision\":\"ask\""* ]] && [[ "$OUT" == *"myrepo-reviewer"* ]]'
node "$SANDBOX/own.js" "$HD" "$OWNER"
run_msg new --team @default --to reviewer --from orchestrator --slug d1
D1P=$(jget o.path)
run_msg new --team foo --to reviewer --from orchestrator --slug f1
run_msg list --team @default
check "M12 msg.mjs new and list --team @default reach only the default team, with two owned" \
  'grep -q "^team: null$" "$D1P" && grep -q "^team_file: $HD/team.json$" "$D1P" && [ "$(jget "o.map(r => r.slug).join()")" = d1 ]'
cp "$HD/teams/foo.json" "$HD/teams/@default.json"
eval_lib "R.listTeamNames('$HD').sort().join()"
check "M12 a hand-made teams/@default.json isn't listed as a team" '[ "$OUT" = foo ]'
rm -f "$HD/teams/@default.json"

# ================================================================ M13 route gate, no live peer, several teams
fresh; config
team_file foo "$FOO_MEMBERS" '"X"'
team_file bar "$BAR_MEMBERS" '"Y"'
hook_as_owner pretooluse-route-gate.mjs "$AGENT_ARCH"
check "M13 with two owned teams and no live architect, one spawn command per team: its verb, --team and prefix" \
  '[[ "$OUT" == *"Team bar: node \\\"$H/roster.mjs\\\" spawn-ad-hoc architect --team bar --cwd"*"starts with \`bar-\`"* ]] && [[ "$OUT" == *"Team foo: node \\\"$H/roster.mjs\\\" spawn-one architect --team foo --cwd"*"starts with \`foo-\`"* ]] && [[ "$OUT" == *"Run the one for the team that owns this work."* ]]'

# ================================================================ M14 teams' own flag
fresh
node --input-type=module -e "const R = await import('$H/lib-roster.mjs'); for (const [n, o] of [['s', { session_id: 'S', pid: $DEAD }], ['c2', { session_id: 'S2', pid: $OWNER }]]) R.writeTeam('$HD', { version: 1, team_id: 'T-' + n, created: '2026-09-30T00:00:00Z', roster_level: 'repo', transport: 'terminal', orchestrator: o, members: [], partial: false }, n);"
run_roster teams --json --session S
check "M14 --session S owns a team that recorded S under a dead pid, and not one whose session conflicts" \
  '[ "$(jget "o.teams.map(t => t.name + \"=\" + t.own).join()")" = "c2=false,s=true" ]'
run_roster teams --json
check "M14 without --session, own is the pid match, as before" '[ "$(jget "o.teams.map(t => t.name + \"=\" + t.own).join()")" = "c2=true,s=false" ]'

# ================================================================ M8 one owned team
# Every M-row's command with one owned team gives what the build before this change gave.
fresh; config
team_file foo "$FOO_MEMBERS" '"X"'
hook_as_owner sessionstart.mjs "$SS_PAYLOAD"
check "M4/M8 SessionStart with one owned team is byte-identical to the golden" 'golden sessionstart "$(context)"'
hook_as_owner pretooluse-route-gate.mjs "$AGENT_ARCH"
check "M8/M13 route gate, one owned team with no live architect" 'golden route-gate-no-peer "$OUT"'
peer_up foo-architect foo architect
hook_as_owner pretooluse-route-gate.mjs "$AGENT_ARCH"
check "M8 route gate, one owned team with a live architect" 'golden route-gate "$OUT"'
hook_as_owner pretooluse-herdr-name-gate.mjs "$HERDR_FOO"
check "M8 herdr-name gate, one owned team" 'golden herdr-gate "$OUT"'
node "$SANDBOX/own.js" "$HD" "$OWNER"
for c in "disband --plan" "spawn-one reviewer --dry-run" "stream-status" "dismiss foo-reviewer --plan"; do
  run_roster $c
  check "M8 roster.mjs $c, one owned team" 'golden "roster-${c%% *}" "$RC $OUT"'
done
run_msg new --to reviewer --from orchestrator --slug m8 --to-name foo-reviewer
M8P=$(jget o.path)
check "M8 msg.mjs new, one owned team" 'golden msg-new "$RC $OUT $(grep "^team" "$M8P")"'
run_msg list
check "M8 msg.mjs list, one owned team" 'golden msg-list "$RC $OUT"'

# ================================================================ K skill text
SK="$PLUGIN/skills/agent-team/SKILL.md"
for a in '**Several teams in one request.**' 'a team per roster' 'never ask what the request already says' \
  'one `ListAgents` call for the whole request' 'one question round for every team' 'team by team, never in parallel' \
  '**Owning more than one team.**'; do
  check "K1 anchor present: $a" 'grep -qF -- "$a" "$SK"'
done
for k in 'Team name — one question, every create' 'Run a bare `roster.mjs create --plan`' \
  'Roster — only when the plan lists `named_rosters`' 'same** AskUserQuestion call as the team name' \
  're-run the plan with' 'needs_user_choice: false'; do
  check "K2 still present: $k" 'grep -qF -- "$k" "$SK"'
done
check "K4 the single-team claims hold only while one team is owned" 'grep -qF -- "only while this session owns just that one team" "$SK"'
check "K4 ... and the Owning more than one team paragraph names --team @default" \
  '[[ "$(awk "/^\*\*Owning more than one team\.\*\*/{on=1} on&&/^$/{exit} on" "$SK")" == *"--team @default"* ]]'
check "K3 the several-teams subsection comes before step 0" \
  '[ "$(grep -nF "**Several teams in one request.**" "$SK" | head -1 | cut -d: -f1)" -lt "$(grep -nF "0. **Layout" "$SK" | head -1 | cut -d: -f1)" ]'

echo
echo "SUMMARY: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
