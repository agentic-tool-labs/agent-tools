#!/bin/bash
# agent-hierarchy — named-roster selection: which roster block a command uses (--roster, then
# AH_ROSTER, then the most specific activeRoster, then the default block), the name `default`, a
# selection that names no roster, team files outranking the selection, and the
# `roster list|copy|delete|use` verbs. HOME-redirected; real state untouched.
# Usage: bash tests/test-roster-select.sh   (exits 0 iff all cases pass)

. "$(dirname "$0")/lib-hermetic.sh"
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
# Every Claude session exports some of these; a test must not inherit any of them.
unset AH_TEAM_FILE CLAUDE_PID AH_ROSTER AGENT_HIERARCHY_DIR
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-roster-select-test.XXXXXX")"
[ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] || { echo "mktemp failed"; exit 1; }
hermetic_on_exit 'rm -rf "$SANDBOX"'
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
# No test may reach the real herdr or tmux: a stub that fails every call sits first on PATH (a failing herdr or tmux is what a
# machine without a running multiplexer gives), and the guard in lib-hermetic.sh is told it is a fake.
mkdir -p "$SANDBOX/nolaunch"; printf '#!/bin/sh\nexit 1\n' > "$SANDBOX/nolaunch/herdr"; cp "$SANDBOX/nolaunch/herdr" "$SANDBOX/nolaunch/tmux"; chmod +x "$SANDBOX/nolaunch/herdr" "$SANDBOX/nolaunch/tmux"
export PATH="$SANDBOX/nolaunch:$PATH"; export AH_TEST_FAKE_BIN="$SANDBOX/nolaunch"
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/myrepo"
REPO_CFG="$PROJ/.claude/agent-hierarchy.json"
GLOBAL_CFG="$FAKEHOME/.claude/agent-hierarchy.json"
REPO_USER_CFG="$FAKEHOME/.claude/agent-hierarchy/projects/$(echo "$PROJ" | sed 's,/,-,g')/agent-hierarchy.json"
TEAMS="$PROJ/.claude/hierarchy/teams"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:300} ERR=${ERR:0:300})"; fi
}

# An empty HOME and a fresh repo whose repo-level file holds the default block (architect) and
# named rosters game, alt, r3, r4 and r5 (one reviewer each).
fresh() {
  rm -rf "$FAKEHOME" "$PROJ" "$SANDBOX/wt" "$SANDBOX/norepo"
  mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude"
  git -C "$PROJ" init -q
  local one='{"route":"peer","members":[{"role":"reviewer","model":"sonnet"}]}'
  cat > "$REPO_CFG" <<EOF
{"version":1,"roster":{"route":"peer","members":[{"role":"architect","model":"opus"}]},
 "rosters":{"game":$one,"alt":$one,"r3":$one,"r4":$one,"r5":$one}}
EOF
}

# <file> <js statement over the parsed file d>: edits a JSON file, creating it when missing.
mutate() {
  mkdir -p "$(dirname "$1")"
  node -e 'const fs=require("fs");const f=process.argv[1];const d=fs.existsSync(f)?JSON.parse(fs.readFileSync(f,"utf8")):{};(new Function("d",process.argv[2]))(d);fs.writeFileSync(f,JSON.stringify(d,null,2)+"\n")' "$1" "$2"
}

# <file> <js expression over the parsed file d>: true when the expression is.
filejs() {
  node -e 'const d=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.exit((new Function("d","return ("+process.argv[2]+")"))(d)?0:1)' "$1" "$2" 2>/dev/null
}

# <team name, "" for team.json> <json>: a team file in this repo's hierarchy dir.
team() {
  mkdir -p "$TEAMS"
  if [ -z "$1" ]; then echo "$2" > "$PROJ/.claude/hierarchy/team.json"; else echo "$2" > "$TEAMS/$1.json"; fi
}

# roster.mjs with HOME redirected: stdout in OUT, stderr in ERR.
rm_() {
  OUT=$(HOME="$FAKEHOME" node "$H/roster.mjs" "$@" 2>"$SANDBOX/err"); RC=$?
  ERR=$(cat "$SANDBOX/err")
}

# <js expression over the parsed OUT o>: its value (strings bare, anything else as JSON).
jget() {
  node -e 'const o=JSON.parse(process.argv[1]);const v=(new Function("o","return ("+process.argv[2]+")"))(o);process.stdout.write(typeof v==="string"?v:JSON.stringify(v))' "$OUT" "$1" 2>/dev/null
}

# <js expression over r = resolveConfig(PROJ or CFG_CWD, CFG_OPTS)>: its value in OUT.
cfg() {
  OUT=$(HOME="$FAKEHOME" node --input-type=module -e "
    const C = await import('$H/lib-config.mjs');
    const r = C.resolveConfig('${CFG_CWD:-$PROJ}', ${CFG_OPTS:-'{pid: -1}'});
    const v = ($1);
    process.stdout.write(typeof v === 'string' ? v : JSON.stringify(v));
  " 2>&1); RC=$?
}

sel() { jget "o.selection.roster + '/' + o.selection.source + '/' + o.selection.level"; }

# A linked worktree of PROJ at $SANDBOX/wt, with no config file of its own.
worktree() {
  git -C "$PROJ" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init && git -C "$PROJ" worktree add -q "$SANDBOX/wt" -b wtb
}

# ---------------------------------------------------------------- S1 nothing selected
fresh
rm_ show --cwd "$PROJ"
check "S1 show: nothing selected uses the default block" '[ $RC = 0 ] && [ "$(jget "o.members.map(m => m.role).join()")" = architect ] && [ "$(sel)" = default/default/null ] && [ "$(jget o.teamKey)" = null ]'
rm_ create --plan --cwd "$PROJ"
check "S1 create --plan: nothing selected plans the default block, with no selection in the plan" '[ $RC = 0 ] && [ "$(jget "o.members.map(m => m.role).join()")" = architect ] && [ "$(jget "\"selection\" in o")" = false ]'
rm_ add --role implementor --model sonnet --cwd "$PROJ"
check "S1 add: nothing selected writes the default block" '[ $RC = 0 ] && filejs "$REPO_CFG" "d.roster.members.length === 2 && d.rosters.game.members.length === 1"'

# ---------------------------------------------------------------- S2 precedence
fresh
mutate "$REPO_USER_CFG" 'd.activeRoster = "r3"'
mutate "$REPO_CFG" 'd.activeRoster = "r4"'
mutate "$GLOBAL_CFG" 'd.activeRoster = "r5"'
AH_ROSTER=alt rm_ show --roster game --cwd "$PROJ"
check "S2 --roster beats AH_ROSTER and activeRoster" '[ $RC = 0 ] && [ "$(sel)" = game/flag/null ] && [ "$(jget o.teamKey)" = game ]'
AH_ROSTER=alt rm_ show --cwd "$PROJ"
check "S2 AH_ROSTER beats activeRoster" '[ $RC = 0 ] && [ "$(sel)" = alt/env/null ] && [ "$(jget o.teamKey)" = alt ]'
rm_ show --cwd "$PROJ"
check "S2 activeRoster: repo-user beats repo and global" '[ $RC = 0 ] && [ "$(sel)" = r3/activeRoster/repo-user ] && [ "$(jget o.selection.path)" = "$REPO_USER_CFG" ] && [ "$(jget o.teamKey)" = r3 ]'
mutate "$REPO_USER_CFG" 'delete d.activeRoster'
rm_ show --cwd "$PROJ"
check "S2 activeRoster: repo beats global" '[ $RC = 0 ] && [ "$(sel)" = r4/activeRoster/repo ] && [ "$(jget o.teamKey)" = r4 ]'
mutate "$REPO_CFG" 'delete d.activeRoster'
rm_ show --cwd "$PROJ"
check "S2 activeRoster: global when nothing narrower" '[ $RC = 0 ] && [ "$(sel)" = r5/activeRoster/global ] && [ "$(jget o.selection.path)" = "$GLOBAL_CFG" ] && [ "$(jget o.teamKey)" = r5 ]'

# ---------------------------------------------------------------- S3 the name `default`
fresh
mutate "$REPO_CFG" 'd.activeRoster = "game"'
AH_ROSTER=alt rm_ show --roster default --cwd "$PROJ"
check "S3 --roster default selects the unnamed block" '[ $RC = 0 ] && [ "$(sel)" = default/flag/null ] && [ "$(jget o.teamKey)" = null ] && [ "$(jget "o.members[0].role")" = architect ]'
AH_ROSTER=default rm_ show --cwd "$PROJ"
check "S3 AH_ROSTER=default selects the unnamed block over activeRoster" '[ $RC = 0 ] && [ "$(sel)" = default/env/null ] && [ "$(jget o.teamKey)" = null ]'
mutate "$REPO_USER_CFG" 'd.activeRoster = "default"'
rm_ show --cwd "$PROJ"
check "S3 activeRoster default at repo-user undoes the repo selection" '[ $RC = 0 ] && [ "$(sel)" = default/activeRoster/repo-user ] && [ "$(jget o.teamKey)" = null ]'
mutate "$REPO_USER_CFG" 'delete d.activeRoster'
rm_ roster use default --cwd "$PROJ"
check "S3 roster use default writes it and selects the unnamed block" '[ $RC = 0 ] && filejs "$REPO_USER_CFG" "d.activeRoster === \"default\"" && [ "$(sel)" = default/activeRoster/repo-user ]'
rm_ init --level repo --route peer --roster default --cwd "$PROJ"
check "S3 init --roster default is refused" '[ $RC = 2 ] && filejs "$REPO_CFG" "!(\"default\" in d.rosters)"'

# ---------------------------------------------------------------- S4 a selection naming no roster
fresh
AH_ROSTER=nope rm_ show --cwd "$PROJ"
check "S4 show refuses AH_ROSTER naming no roster, naming the source, the defined rosters and the fixes" \
  '[ $RC = 2 ] && [[ "$ERR" == *"AH_ROSTER selects roster \"nope\""* ]] && [[ "$ERR" == *"defined: alt, game, r3, r4, r5"* ]] && [[ "$ERR" == *"roster use default"* ]] && [[ "$ERR" == *"init --roster nope"* ]]'
rm_ add --roster nope --role implementor --model sonnet --cwd "$PROJ"
check "S4 add refuses --roster naming no roster" '[ $RC = 2 ] && [[ "$ERR" == *"--roster selects roster \"nope\""* ]] && filejs "$REPO_CFG" "d.roster.members.length === 1"'
mutate "$REPO_USER_CFG" 'd.activeRoster = "nope"'
rm_ create --plan --cwd "$PROJ"
check "S4 create refuses activeRoster naming no roster, with its level and path" '[ $RC = 2 ] && [[ "$ERR" == *"activeRoster at repo-user in $REPO_USER_CFG selects roster \"nope\""* ]]'
rm_ init --level repo --route peer --cwd "$PROJ"
check "S4 init creates the missing selected roster" '[ $RC = 0 ] && filejs "$REPO_CFG" "Array.isArray(d.rosters.nope.members) && d.rosters.nope.members.length === 0 && d.roster.members.length === 1"'
mutate "$REPO_USER_CFG" 'delete d.activeRoster'
AH_ROSTER=nope2 cfg 'r.roster.teamKey === null && r.roster.members[0].role === "architect" && r.warnings.some((w) => w.includes("AH_ROSTER selects roster \"nope2\""))'
check "S4 resolveConfig warns and uses the default block without throwing" '[ $RC = 0 ] && [ "$OUT" = true ]'
mutate "$REPO_USER_CFG" 'd.activeRoster = ""'
rm_ show --cwd "$PROJ"
check "S4 an empty activeRoster is refused as not a roster name" '[ $RC = 2 ] && [[ "$ERR" == *"activeRoster at repo-user in $REPO_USER_CFG must be a roster name, got \"\""* ]]'
mutate "$REPO_USER_CFG" 'd.activeRoster = 5'
rm_ show --cwd "$PROJ"
check "S4 a non-string activeRoster is refused as not a roster name" '[ $RC = 2 ] && [[ "$ERR" == *"must be a roster name, got 5"* ]]'
mutate "$REPO_USER_CFG" 'delete d.activeRoster'
CLAUDE_PID=$$ rm_ doctor --check --cwd "$PROJ"
check "S4 doctor --check: no roster-selection row while the selection is fine" '[ $RC = 0 ] && [ "$(jget "o.rows.some(r => r.name === \"roster-selection\")")" = false ]'
AH_ROSTER=nope2 CLAUDE_PID=$$ rm_ doctor --check --cwd "$PROJ"
check "S4 doctor --check exits 1 with a red roster-selection row" '[ $RC = 1 ] && [ "$(jget "o.red.includes(\"roster-selection\")")" = true ]'
team tm '{"version":1,"team_id":"tm","members":[],"roster":"game"}'
AH_TEAM_FILE="$TEAMS/tm.json" AH_ROSTER=nope2 CLAUDE_PID=$$ rm_ doctor --check --cwd "$PROJ"
check "S4 doctor, like the hooks, ignores AH_ROSTER while a team file is in scope" '[ $RC = 0 ] && [ "$(jget "o.rows.some(r => r.name === \"roster-selection\")")" = false ]'

# ---------------------------------------------------------------- S5 team files
fresh
mutate "$REPO_USER_CFG" 'd.activeRoster = "r3"'
team t1 '{"version":1,"team_id":"t1","members":[],"roster":"game"}'
AH_ROSTER=alt CFG_OPTS='{team: "t1", pid: -1}' cfg 'r.roster.teamKey'
check "S5 a team file in scope beats AH_ROSTER and activeRoster" '[ $RC = 0 ] && [ "$OUT" = game ]'
team t2 '{"version":1,"team_id":"t2","members":[],"roster":null}'
AH_ROSTER=alt CFG_OPTS='{team: "t2", pid: -1}' cfg 'r.roster.teamKey === null && r.roster.members[0].role === "architect"'
check "S5 a team file recording the default block still wins" '[ $RC = 0 ] && [ "$OUT" = true ]'
team r4 '{"version":1,"team_id":"legacy","members":[]}'
AH_ROSTER=alt CFG_OPTS='{team: "r4", pid: -1}' cfg 'r.roster.teamKey'
check "S5 a legacy team file keys by the team name" '[ $RC = 0 ] && [ "$OUT" = r4 ]'
AH_ROSTER=alt CFG_OPTS='{team: "ghost", pid: -1}' cfg 'r.roster.teamKey'
check "S5 with no team file the selection applies" '[ $RC = 0 ] && [ "$OUT" = alt ]'
CFG_OPTS='{team: "ghost", pid: -1}' cfg 'r.roster.teamKey'
check "S5 with no team file activeRoster applies" '[ $RC = 0 ] && [ "$OUT" = r3 ]'

# ---------------------------------------------------------------- S6 create records the selection
fresh
mutate "$REPO_USER_CFG" 'd.activeRoster = "game"'
rm_ create --plan --team s6a --cwd "$PROJ"
check "S6 create --plan builds from the selection and names it" '[ $RC = 0 ] && [ "$(jget "o.members.map(m => m.role).join()")" = reviewer ] && [ "$(sel)" = game/activeRoster/repo-user ]'
rm_ create --commit --team s6a --verified '["s6a-reviewer"]' --transport terminal --roster-level repo --orchestrator-pid $$ --cwd "$PROJ"
check "S6 create with no --roster records the selected key" '[ $RC = 0 ] && filejs "$TEAMS/s6a.json" "d.roster === \"game\""'
AH_ROSTER=default rm_ create --commit --team s6b --verified '["s6b-architect"]' --transport terminal --roster-level repo --orchestrator-pid $$ --cwd "$PROJ"
check "S6 create with the default selection records null" '[ $RC = 0 ] && filejs "$TEAMS/s6b.json" "d.roster === null"'

# ---------------------------------------------------------------- S7 roster list
fresh
mutate "$GLOBAL_CFG" 'd.rosters = {game: {route: "pane", members: [{role: "reviewer"}, {role: "architect"}]}}'
mutate "$REPO_CFG" 'd.rosters.default = {route: "peer", members: [{role: "architect"}]}'
mutate "$REPO_USER_CFG" 'd.activeRoster = "game"'
team t7 '{"version":1,"team_id":"t7","members":[],"roster":"game"}'
team alt '{"version":1,"team_id":"legacy","members":[]}'
team "" '{"version":1,"team_id":"dflt","members":[],"roster":null}'
rm_ roster list --json --cwd "$PROJ"
check "S7 list: the selection and its source" '[ $RC = 0 ] && [ "$(sel)" = game/activeRoster/repo-user ]'
check "S7 list: winning level, shadowing, count, route, selected, teams" \
  '[ "$(jget "JSON.stringify(o.rosters.find(r => r.block === \"rosters.game\"))")" = "$(node -e "process.stdout.write(JSON.stringify({roster:\"game\",block:\"rosters.game\",level:\"repo\",path:process.argv[1],shadowed:[{level:\"global\",path:process.argv[2]}],members:1,route:\"peer\",selected:true,teams:[{team:\"t7\",file:process.argv[3]}]}))" "$REPO_CFG" "$GLOBAL_CFG" "$TEAMS/t7.json")" ]'
check "S7 list: the default block, and teams using it and a legacy team keyed by its name" \
  '[ "$(jget "o.rosters[0].block + \"/\" + o.rosters[0].members + \"/\" + o.rosters[0].selected + \"/\" + JSON.stringify(o.rosters[0].teams.map(t => t.team))")" = "roster/1/false/[null]" ] && [ "$(jget "o.rosters.find(r => r.block === \"rosters.alt\").teams.map(t => t.team).join()")" = alt ]'
check "S7 list: a legacy rosters.default with its note, never selected" \
  '[ "$(jget "(r => r.roster + \"/\" + r.selected + \"/\" + (r.note || \"\").includes(\"can\x27t be selected or copied\"))(o.rosters.find(r => r.block === \"rosters.default\"))")" = default/false/true ]'
rm_ roster list --cwd "$PROJ"
check "S7 list: human output names the selection, its source and each block" \
  '[ $RC = 0 ] && [[ "$OUT" == *"selection: game (activeRoster at repo-user, $REPO_USER_CFG)"* ]] && [[ "$OUT" == *"* game (rosters.game)"* ]] && [[ "$OUT" == *"default (rosters.default)"* ]] && [[ "$OUT" == *"teams: t7"* ]]'

# ---------------------------------------------------------------- S8 roster copy
fresh
rm_ roster copy default fromdef --cwd "$PROJ"
check "S8 copy default -> named, verbatim, at the level it resolved" '[ $RC = 0 ] && filejs "$REPO_CFG" "JSON.stringify(d.rosters.fromdef) === JSON.stringify(d.roster)"'
mutate "$REPO_CFG" 'd.rosters.game = {route: "pane", members: [{role: "reviewer", model: "sonnet", effort: "high"}, {role: "architect"}]}'
rm_ roster copy game gcopy --level repo-user --cwd "$PROJ"
check "S8 copy named -> named at another level, verbatim" '[ $RC = 0 ] && [ "$(node -e "const f=p=>JSON.parse(require(\"fs\").readFileSync(p,\"utf8\"));process.stdout.write(String(JSON.stringify(f(process.argv[1]).rosters.gcopy)===JSON.stringify(f(process.argv[2]).rosters.game)))" "$REPO_USER_CFG" "$REPO_CFG")" = true ] && [ "$(jget "o.from.roster + \"/\" + o.from.level + \"/\" + o.to.level")" = game/repo/repo-user ]'
rm_ roster copy game gdry --dry-run --cwd "$PROJ"
check "S8 copy --dry-run writes nothing" '[ $RC = 0 ] && filejs "$REPO_CFG" "!(\"gdry\" in d.rosters)"'
rm_ roster copy nope x --cwd "$PROJ"
check "S8 copy refuses a src that is not defined" '[ $RC = 2 ] && [[ "$ERR" == *"not defined"* ]] && filejs "$REPO_CFG" "!(\"x\" in d.rosters)"'
rm_ roster copy game default --cwd "$PROJ"
check "S8 copy refuses dst default" '[ $RC = 2 ] && filejs "$REPO_CFG" "!(\"default\" in d.rosters)"'
rm_ roster copy game bad_name --cwd "$PROJ"
check "S8 copy refuses an invalid dst" '[ $RC = 2 ] && filejs "$REPO_CFG" "!(\"bad_name\" in d.rosters)"'
rm_ roster copy game alt --cwd "$PROJ"
check "S8 copy refuses a dst already defined at that level" '[ $RC = 2 ] && [[ "$ERR" == *"already defined"* ]] && filejs "$REPO_CFG" "d.rosters.alt.members[0].role === \"reviewer\" && d.rosters.alt.members.length === 1"'
fresh
worktree
rm_ roster copy game alt --cwd "$SANDBOX/wt"
check "S8 from a worktree, copy refuses a dst the main checkout's file defines at that level, naming that file" \
  '[ $RC = 2 ] && [[ "$ERR" == *"already defined at level \"repo\" ($REPO_CFG)"* ]] && [[ "$ERR" == *"--cwd $PROJ"* ]] && [ ! -e "$SANDBOX/wt/.claude/agent-hierarchy.json" ]'

# ---------------------------------------------------------------- S9 roster delete
fresh
rm_ roster delete alt --cwd "$PROJ"
check "S9 delete removes the block" '[ $RC = 0 ] && filejs "$REPO_CFG" "!(\"alt\" in d.rosters) && \"game\" in d.rosters"'
rm_ roster delete default --cwd "$PROJ"
check "S9 delete refuses default" '[ $RC = 2 ] && filejs "$REPO_CFG" "d.roster.members.length === 1"'
team t9 '{"version":1,"team_id":"t9","members":[],"roster":"game"}'
rm_ roster delete game --cwd "$PROJ"
check "S9 delete refuses a roster a team uses, naming it and disband/reap" '[ $RC = 2 ] && [[ "$ERR" == *"team \"t9\""* ]] && [[ "$ERR" == *disband* ]] && [[ "$ERR" == *reap* ]] && filejs "$REPO_CFG" "\"game\" in d.rosters"'
team r3 '{"version":1,"team_id":"legacy","members":[]}'
rm_ roster delete r3 --cwd "$PROJ"
check "S9 delete refuses a roster a legacy team keys by its name" '[ $RC = 2 ] && [[ "$ERR" == *"team \"r3\""* ]] && filejs "$REPO_CFG" "\"r3\" in d.rosters"'
mutate "$REPO_CFG" 'd.activeRoster = "r4"'
rm_ roster delete r4 --cwd "$PROJ"
check "S9 delete refuses a roster activeRoster in the same file selects" '[ $RC = 2 ] && [[ "$ERR" == *"activeRoster in $REPO_CFG selects it"* ]] && filejs "$REPO_CFG" "\"r4\" in d.rosters"'
mutate "$REPO_USER_CFG" 'd.activeRoster = "r5"'
rm_ roster delete r5 --cwd "$PROJ"
check "S9 delete warns and goes ahead when another level selects it" '[ $RC = 0 ] && [[ "$ERR" == *"warning"*"$REPO_USER_CFG"* ]] && [ "$(jget "o.warnings.length")" = 1 ] && filejs "$REPO_CFG" "!(\"r5\" in d.rosters)"'
fresh
worktree
for extra in "" "--dry-run" "--level repo"; do
  rm_ roster delete alt $extra --cwd "$SANDBOX/wt"
  check "S9 from a worktree, delete ${extra:-(no flag)} refuses a block only the main checkout's file holds, naming that file and --cwd" \
    '[ $RC = 2 ] && [[ "$ERR" == *"main checkout'"'"'s file ($REPO_CFG)"* ]] && [[ "$ERR" == *"--cwd $PROJ"* ]] && filejs "$REPO_CFG" "\"alt\" in d.rosters" && [ ! -e "$SANDBOX/wt/.claude/agent-hierarchy.json" ]'
done

# ---------------------------------------------------------------- S10 roster use
fresh
rm_ roster use game --cwd "$PROJ"
check "S10 use writes repo-user by default inside a repo" '[ $RC = 0 ] && [ "$(jget o.level)" = repo-user ] && filejs "$REPO_USER_CFG" "d.activeRoster === \"game\"" && ! filejs "$REPO_CFG" "\"activeRoster\" in d" && [ "$(sel)" = game/activeRoster/repo-user ]'
mkdir -p "$SANDBOX/norepo"
mutate "$GLOBAL_CFG" 'd.rosters = {g: {route: "peer", members: [{role: "reviewer"}]}}'
rm_ roster use g --cwd "$SANDBOX/norepo"
check "S10 use writes global by default outside a repo" '[ $RC = 0 ] && [ "$(jget o.level)" = global ] && filejs "$GLOBAL_CFG" "d.activeRoster === \"g\""'
rm_ roster use nope --cwd "$PROJ"
check "S10 use refuses a roster no level defines" '[ $RC = 2 ] && filejs "$REPO_USER_CFG" "d.activeRoster === \"game\""'
mutate "$REPO_USER_CFG" 'd.rosters = {keep: {route: "peer", members: []}}'
rm_ roster use --clear --cwd "$PROJ"
check "S10 use --clear removes the key and keeps the file's other keys" '[ $RC = 0 ] && [ "$(jget o.cleared)" = true ] && [ "$(jget "\"file_removed\" in o")" = false ] && filejs "$REPO_USER_CFG" "!(\"activeRoster\" in d) && \"keep\" in d.rosters"'
rm_ roster use default --cwd "$PROJ"
check "S10 use accepts default" '[ $RC = 0 ] && filejs "$REPO_USER_CFG" "d.activeRoster === \"default\""'
rm_ roster use game --level global --cwd "$PROJ"
check "S10 use --level global warns when only this repo defines the roster" '[ $RC = 0 ] && [[ "$ERR" == *"other repos"* ]] && filejs "$GLOBAL_CFG" "d.activeRoster === \"game\""'

# ---------------------------------------------------------------- S11 writes keep activeRoster; preference-only
fresh
rm_ roster use game --level repo --cwd "$PROJ"
rm_ add --level repo --role implementor --model sonnet --cwd "$PROJ"
check "S11 activeRoster survives a writeLevelFile write" '[ $RC = 0 ] && filejs "$REPO_CFG" "d.activeRoster === \"game\" && d.rosters.game.members.length === 2"'
fresh
rm -f "$REPO_CFG"
mutate "$GLOBAL_CFG" 'd.activeRoster = "game"'
cfg 'r.configured'
check "S11 a global file holding only activeRoster is unconfigured" '[ $RC = 0 ] && [ "$OUT" = false ]'
mutate "$GLOBAL_CFG" 'd.teamLayout = "grid"'
cfg 'r.configured'
check "S11 ... also alongside the other preference-only keys" '[ $RC = 0 ] && [ "$OUT" = false ]'

# ---------------------------------------------------------------- S12 linked worktree
fresh
worktree
mkdir -p "$SANDBOX/wt/.claude"
echo '{"version":1}' > "$SANDBOX/wt/.claude/agent-hierarchy.json"
mutate "$REPO_CFG" 'd.activeRoster = "game"'
rm_ show --cwd "$SANDBOX/wt"
check "S12 the main checkout's repo-level activeRoster applies in a linked worktree" '[ $RC = 0 ] && [ "$(sel)" = game/activeRoster/repo ] && [ "$(jget o.selection.path)" = "$REPO_CFG" ] && [ "$(jget o.teamKey)" = game ]'
CFG_CWD="$SANDBOX/wt" cfg 'r.roster.teamKey'
check "S12 ... and in resolveConfig" '[ $RC = 0 ] && [ "$OUT" = game ]'

# ---------------------------------------------------------------- S13 AH_ROSTER="" is unset
fresh
mutate "$REPO_USER_CFG" 'd.activeRoster = "game"'
AH_ROSTER= rm_ show --cwd "$PROJ"
check "S13 AH_ROSTER=\"\" counts as unset in the verbs" '[ $RC = 0 ] && [ "$(sel)" = game/activeRoster/repo-user ]'
AH_ROSTER= cfg 'r.roster.teamKey'
check "S13 ... and in resolveConfig" '[ $RC = 0 ] && [ "$OUT" = game ]'

# ---------------------------------------------------------------- S14 not gated or guarded
fresh
hook() {
  OUT=$(node -e 'process.stdout.write(JSON.stringify({session_id: "s14", cwd: process.argv[1], tool_name: "Bash", tool_input: {command: process.argv[2]}}))' "$PROJ" "$1" | HOME="$FAKEHOME" node "$H/pretooluse-roster-skill-gate.mjs" 2>&1); RC=$?
}
for sub in "list" "copy game g14" "delete game" "use game"; do
  hook "node $H/roster.mjs roster $sub --cwd $PROJ"
  check "S14 the skill gate lets roster $sub through" '[ $RC = 0 ] && [ -z "$OUT" ]'
done
hook "node $H/roster.mjs create --plan --cwd $PROJ"
check "S14 (harness) the skill gate still holds create" '[[ "$OUT" == *"\"permissionDecision\":\"deny\""* ]]'
rm_ create --commit --team s14 --verified '["s14-architect"]' --transport terminal --roster-level repo --orchestrator-pid $$ --cwd "$PROJ"
check "S14 (setup) this session owns a live team" '[ $RC = 0 ]'
CLAUDE_PID=$$ rm_ roster copy game g14 --cwd "$PROJ"
check "S14 roster copy runs while the session owns a live team" '[ $RC = 0 ] && filejs "$REPO_CFG" "\"g14\" in d.rosters"'
CLAUDE_PID=$$ rm_ roster use g14 --cwd "$PROJ"
check "S14 roster use runs while the session owns a live team" '[ $RC = 0 ] && filejs "$REPO_USER_CFG" "d.activeRoster === \"g14\""'
CLAUDE_PID=$$ rm_ roster delete alt --cwd "$PROJ"
check "S14 roster delete runs while the session owns a live team" '[ $RC = 0 ] && filejs "$REPO_CFG" "!(\"alt\" in d.rosters)"'
CLAUDE_PID=$$ rm_ add --role implementor --model sonnet --cwd "$PROJ"
check "S14 add is still refused while the session owns a live team" '[ $RC = 2 ] && [[ "$ERR" == *"edits the roster TEMPLATE"* ]]'

# ---------------------------------------------------------------- S15 nothing configured
fresh
rm -f "$REPO_CFG"
inject() {
  OUT=$(printf '%s' '{"session_id":"s15","cwd":"'"$PROJ"'","hook_event_name":"SessionStart","source":"startup"}' | HOME="$FAKEHOME" node "$H/sessionstart.mjs" 2>&1); RC=$?
}
inject  # settles anything a first session records
inject; BEFORE_INJECT=$OUT
cfg 'r.configured'
check "S15 (baseline) nothing is configured" '[ $RC = 0 ] && [ "$OUT" = false ]'
rm_ roster use default --cwd "$PROJ"
check "S15 use default writes the repo-user file" '[ $RC = 0 ] && filejs "$REPO_USER_CFG" "d.activeRoster === \"default\""'
check "S15 ... holding activeRoster and no version" 'filejs "$REPO_USER_CFG" "d.activeRoster === \"default\" && !(\"version\" in d)"'
cfg 'r.configured'
check "S15 ... which keeps resolveConfig unconfigured" '[ $RC = 0 ] && [ "$OUT" = false ]'
inject
check "S15 ... and SessionStart's injection byte-identical" '[ $RC = 0 ] && [ "$OUT" = "$BEFORE_INJECT" ]'
rm_ roster use --clear --cwd "$PROJ"
check "S15 use --clear then leaves no repo-user file" '[ $RC = 0 ] && [ "$(jget o.file_removed)" = true ] && [ ! -e "$REPO_USER_CFG" ]'
mutate "$REPO_USER_CFG" 'd.version = 1; d.activeRoster = "default"; d.roster = {route: "peer", members: [{role: "architect"}]}'
cfg 'r.configured'
check "S15 a repo-user file that also holds a roster block is configured" '[ $RC = 0 ] && [ "$OUT" = true ]'

# ---------------------------------------------------------------- S17 a file that existed stays
for L in repo-user repo; do
  if [ $L = repo ]; then F=$REPO_CFG; else F=$REPO_USER_CFG; fi
  fresh
  rm -f "$REPO_CFG"
  mkdir -p "$(dirname "$F")"
  echo '{"version":1}' > "$F"
  cfg 'r.configured'
  check "S17 ($L baseline) a file holding only version is configured" '[ $RC = 0 ] && [ "$OUT" = true ]'
  rm_ roster use default --level $L --cwd "$PROJ"
  check "S17 ($L) use default adds activeRoster beside version" '[ $RC = 0 ] && filejs "$F" "d.version === 1 && d.activeRoster === \"default\""'
  cfg 'r.configured'
  check "S17 ($L) ... and the file stays configured" '[ $RC = 0 ] && [ "$OUT" = true ]'
  rm_ roster use --clear --level $L --cwd "$PROJ"
  check "S17 ($L) use --clear keeps the file, holding exactly version" '[ $RC = 0 ] && [ "$(jget o.cleared)" = true ] && [ "$(jget "\"file_removed\" in o")" = false ] && filejs "$F" "JSON.stringify(d) === JSON.stringify({version: 1})"'
  cfg 'r.configured'
  check "S17 ($L) ... and it stays configured" '[ $RC = 0 ] && [ "$OUT" = true ]'
done
fresh
rm -f "$REPO_CFG"
mkdir -p "$(dirname "$REPO_USER_CFG")"
echo '{}' > "$REPO_USER_CFG"
cfg 'r.configured'
check "S17 (baseline) an empty repo-user file is configured" '[ $RC = 0 ] && [ "$OUT" = true ]'
rm_ roster use default --cwd "$PROJ"
check "S17 use default into an empty file writes version and activeRoster" '[ $RC = 0 ] && filejs "$REPO_USER_CFG" "d.version === 1 && d.activeRoster === \"default\""'
cfg 'r.configured'
check "S17 ... and the file stays configured" '[ $RC = 0 ] && [ "$OUT" = true ]'

# ---------------------------------------------------------------- S16 who can see the selected roster
fresh
mutate "$REPO_USER_CFG" 'd.rosters = {mine: {route: "peer", members: [{role: "reviewer"}]}}'
mutate "$GLOBAL_CFG" 'd.rosters = {wide: {route: "peer", members: [{role: "reviewer"}]}}'
rm_ roster use mine --level repo --cwd "$PROJ"
check "S16 use --level repo warns for a roster only repo-user defines, and still writes" '[ $RC = 0 ] && [[ "$ERR" == *"others working in this repo"* ]] && [ "$(jget "o.warnings.length")" = 1 ] && filejs "$REPO_CFG" "d.activeRoster === \"mine\""'
rm_ roster use wide --level repo --cwd "$PROJ"
check "S16 use --level repo warns for a roster only global defines" '[ $RC = 0 ] && [[ "$ERR" == *"others working in this repo"* ]]'
rm_ roster use game --level repo --cwd "$PROJ"
check "S16 use --level repo doesn't warn for a roster the repo level defines" '[ $RC = 0 ] && [ -z "$ERR" ] && [ "$(jget "\"warnings\" in o")" = false ]'
rm_ roster use game --level global --cwd "$PROJ"
check "S16 use --level global warns for a roster the global file doesn't define" '[ $RC = 0 ] && [[ "$ERR" == *"other repos"* ]]'
rm_ roster use wide --level global --cwd "$PROJ"
check "S16 use --level global doesn't warn for a roster the global file defines" '[ $RC = 0 ] && [ -z "$ERR" ]'
rm_ roster use mine --level repo-user --cwd "$PROJ"
check "S16 use --level repo-user never warns" '[ $RC = 0 ] && [ -z "$ERR" ]'
rm_ roster use wide --level repo-user --cwd "$PROJ"
check "S16 ... even for a roster only global defines" '[ $RC = 0 ] && [ -z "$ERR" ]'

echo
echo "SUMMARY: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
