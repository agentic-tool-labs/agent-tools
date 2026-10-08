#!/bin/bash
# agent-hierarchy — one team file per checkout: the team file is the master list for spawn,
# disband, dismiss and teams (spec 0072). Every case runs in a scratch repo with a linked
# worktree, a scratch HOME and a PATH herdr shim; no real herdr, claude or repo is touched.
# Usage: bash tests/test-roster-team-home.sh   (exits 0 iff all cases pass)

. "$(dirname "$0")/lib-hermetic.sh"
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
unset AH_TEAM_FILE CLAUDE_PID AGENT_HIERARCHY_DIR
T="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-team-home-test.XXXXXX")"
[ -n "$T" ] || exit 9
T="$(cd "$T" && pwd -P)"
export AH_TEST_FAKE_BIN="$T/nolaunch:$T/bin"
SLEEPER=""
cleanup() { [ -n "$SLEEPER" ] && kill "$SLEEPER" 2>/dev/null; rm -rf "$T"; }
hermetic_on_exit cleanup
NODE_BIN="$(command -v node)"
NODE_DIR="$(dirname "$NODE_BIN")"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:500})"; fi
}

# A live pid that owns every team the cases create.
sleep 300 & SLEEPER=$!

# ---- herdr shim: stateful, per-case state dir. `agent start` registers an agent (cwd from
# FAKE_AGENT_CWD), `agent list` reports them, `pane close` removes one. FAKE_CLOSE_NOOP=1 makes
# close succeed without removing it; FAKE_LIST_FAIL=1 makes `agent list` fail; FAKE_RENAME_ON_CLOSE
# renames the agent instead ("<pane>=<new name>").
mkdir -p "$T/bin" "$T/home/.claude" "$T/nolaunch"
printf '#!/bin/sh\nexit 1\n' > "$T/nolaunch/tmux"; chmod +x "$T/nolaunch/tmux"
cat > "$T/bin/herdr" <<'EOF'
#!/usr/bin/env node
const fs = require("fs"), path = require("path");
const a = process.argv.slice(2), d = process.env.FAKE_STATE_DIR;
fs.mkdirSync(d, { recursive: true });
fs.appendFileSync(path.join(d, "log"), JSON.stringify(a) + "\n");
const sf = path.join(d, "agents.json"), gf = path.join(d, "geometry.json");
const agents = () => { try { return JSON.parse(fs.readFileSync(sf, "utf8")); } catch { return []; } };
const save = (x) => fs.writeFileSync(sf, JSON.stringify(x));
if (a[0] === "pane" && a[1] === "layout") {
  const s = JSON.parse(fs.readFileSync(gf, "utf8"));
  console.log(JSON.stringify({ result: { layout: { area: s.area, focused_pane_id: s.self, panes: Object.entries(s.panes).map(([pane_id, rect]) => ({ focused: false, pane_id, rect })), splits: [], tab_id: "t1", workspace_id: "w1", zoomed: false } } }));
  process.exit(0);
}
if (a[0] === "pane" && a[1] === "split") {
  const s = JSON.parse(fs.readFileSync(gf, "utf8"));
  const id = "p" + s.nextId++;
  s.panes[id] = { ...s.panes[s.self] };
  fs.writeFileSync(gf, JSON.stringify(s));
  console.log(JSON.stringify({ result: { pane: { pane_id: id } } }));
  process.exit(0);
}
if (a[0] === "agent" && a[1] === "start") {
  const pane = a[a.indexOf("--pane") + 1];
  const ag = agents();
  ag.push({ agent: "claude", agent_status: "idle", name: a[2], pane_id: pane, terminal_title_stripped: a[2], cwd: process.env.FAKE_AGENT_CWD || undefined });
  save(ag);
  console.log(JSON.stringify({ result: { pane: { pane_id: pane }, agent: { name: a[2], ready: true } } }));
  process.exit(0);
}
if (a[0] === "agent" && a[1] === "list") {
  const cf = path.join(d, "listcount");
  let n = 0; try { n = Number(fs.readFileSync(cf, "utf8")); } catch {}
  n += 1; fs.writeFileSync(cf, String(n));
  if (process.env.FAKE_LIST_FAIL === "1" || (process.env.FAKE_LIST_FAIL_FROM && n >= Number(process.env.FAKE_LIST_FAIL_FROM))) { process.stderr.write("fake herdr: daemon unreachable\n"); process.exit(2); }
  const nameless = process.env.FAKE_NAMELESS_FROM && n >= Number(process.env.FAKE_NAMELESS_FROM);
  const list = agents().map((x) => (nameless && x.pane_id === process.env.FAKE_NAMELESS_PANE ? { ...x, name: undefined, terminal_title_stripped: undefined } : x));
  console.log(JSON.stringify({ id: "x", result: { agents: list, type: "agent_list" } }));
  process.exit(0);
}
if (a[0] === "pane" && a[1] === "close") {
  if (process.env.FAKE_RENAME_ON_CLOSE) {
    const [pane, name] = process.env.FAKE_RENAME_ON_CLOSE.split("=");
    if (pane === a[2]) { save(agents().map((x) => (x.pane_id === pane ? { ...x, name } : x))); console.log(JSON.stringify({ result: { ok: true } })); process.exit(0); }
  }
  if (process.env.FAKE_CLOSE_NOOP !== "1") save(agents().filter((x) => x.pane_id !== a[2]));
  console.log(JSON.stringify({ result: { ok: true } }));
  process.exit(0);
}
process.stderr.write("fake herdr: unhandled args " + JSON.stringify(a) + "\n");
process.exit(1);
EOF
chmod +x "$T/bin/herdr"

# ---- scratch repo with a linked worktree
REPO="$T/myrepo"; WT="$REPO/.claude/worktrees/w"; OTHER="$T/otherrepo"
git -C "$T" init -q myrepo
git -C "$REPO" -c user.email=a@b -c user.name=n commit -q --allow-empty -m init
git -C "$REPO" worktree add -q "$WT" 2>/dev/null
git -C "$T" init -q otherrepo
HOME_MAIN="$REPO/.claude/hierarchy"; HOME_WT="$WT/.claude/hierarchy"
STATE="$T/state"

reset_state() {
  rm -rf "$STATE" "$HOME_MAIN" "$HOME_WT" "$OTHER/.claude"
  mkdir -p "$STATE"
  echo '{"self":"p0","nextId":1,"area":{"width":180,"height":42,"x":0,"y":0},"panes":{"p0":{"width":180,"height":42,"x":0,"y":0}}}' > "$STATE/geometry.json"
}

# r <extra env words…> -- <roster.mjs args…>: always shimmed, always the scratch HOME.
r() {
  local -a envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  OUT=$(env HOME="$T/home" HERDR_ENV=1 HERDR_PANE_ID=p0 PATH="$T/bin:$T/nolaunch:$NODE_DIR:/usr/bin:/bin" FAKE_STATE_DIR="$STATE" "${envs[@]}" node "$H/roster.mjs" "$@" 2>&1); RC=$?
}

# A global-level roster: ultra-advisor, architect, reviewer, implementor, implementor-2.
setup_roster() {
  r -- init --level global --route peer --cwd "$REPO"
  for ro in ultra-advisor architect reviewer implementor implementor; do
    r -- add --no-spawn --level global --role $ro --model opus --cwd "$REPO"
  done
}

# spawn <role> <member|-> <cwd> [team]: spawn-one, the agent's cwd reported as the launch cwd.
spawn() {
  local role=$1 member=$2 cwd=$3 team=${4:-demo}
  local -a ma=(); [ "$member" != "-" ] && ma=(--member "$member")
  r FAKE_AGENT_CWD="$cwd" -- spawn-one "$role" "${ma[@]}" --team "$team" --orchestrator-pid "$SLEEPER" --cwd "$cwd"
}

# The five-peer field scenario: two members launched from the worktree, three from main.
field_scenario() {
  reset_state; setup_roster
  spawn ultra-advisor - "$WT"; spawn architect - "$WT"
  spawn reviewer - "$REPO"; spawn implementor - "$REPO"; spawn implementor demo-implementor-2 "$REPO"
}

jq_() { echo "$OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const o=JSON.parse(s);console.log(String(eval(process.argv[1])))})' "$1"; }
members_of() { node -e 'try{console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).members.map(m=>m.name).join(","))}catch{console.log("")}' "$1"; }
log_has() { grep -q -- "$1" "$STATE/log" 2>/dev/null; }

# ==== C1 — spawn-one from a worktree records the team in the main checkout's hierarchy dir ====
reset_state; setup_roster
spawn architect - "$WT"
check "C1: spawn-one --cwd worktree -> exit 0, spawned" '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"spawned\": true"'
check "C1: team file is under the main checkout's hierarchy dir" '[ -f "$HOME_MAIN/teams/demo.json" ]'
check "C1: no team file under the worktree's hierarchy dir" '[ ! -e "$HOME_WT/teams/demo.json" ]'
check "C1: the launch's AH_TEAM_FILE is the home path" 'log_has "AH_TEAM_FILE\\\\\":\\\\\"$HOME_MAIN/teams/demo.json" || log_has "$HOME_MAIN/teams/demo.json"'

# ==== C2 — create --spawn then --commit from a worktree: the same home ====
reset_state; setup_roster
r FAKE_AGENT_CWD="$WT" -- create --spawn --mode auto --team demo --cwd "$WT"
SPAWN_RC=$RC
NAMES=$(jq_ 'o.members.map(m=>m.name).join(",")')
check "C2: create --spawn exits 0" '[ "$SPAWN_RC" -eq 0 ]'
V=$(node -e 'console.log(JSON.stringify(process.argv[1].split(",")))' "$NAMES")
r -- create --commit --verified "$V" --transport herdr --roster-level global --team demo --orchestrator-pid "$SLEEPER" --cwd "$WT"
check "C2: create --commit exits 0" '[ "$RC" -eq 0 ]'
check "C2: committed team file is in the main checkout's hierarchy dir" '[ -f "$HOME_MAIN/teams/demo.json" ] && [ ! -e "$HOME_WT/teams/demo.json" ]'

# ==== C3 — AGENT_HIERARCHY_DIR wins, unchanged ====
reset_state; setup_roster
r AGENT_HIERARCHY_DIR="$T/pinned" FAKE_AGENT_CWD="$WT" -- spawn-one architect --team demo --orchestrator-pid "$SLEEPER" --cwd "$WT"
check "C3: team file is under AGENT_HIERARCHY_DIR" '[ -f "$T/pinned/teams/demo.json" ] && [ ! -e "$HOME_MAIN/teams/demo.json" ] && [ ! -e "$HOME_WT/teams/demo.json" ]'

# ==== C4 — a plain checkout keeps its own dir ====
reset_state; setup_roster
spawn architect - "$OTHER"
check "C4: plain repo -> its own hierarchy dir" '[ -f "$OTHER/.claude/hierarchy/teams/demo.json" ]'

# ==== C5 — a legacy team that lives only in the worktree pool is updated in place ====
reset_state; setup_roster
spawn architect - "$WT"
mkdir -p "$HOME_WT/teams"; mv "$HOME_MAIN/teams/demo.json" "$HOME_WT/teams/demo.json"; rmdir "$HOME_MAIN/teams"
spawn reviewer - "$WT"
check "C5: legacy worktree team gains the member in place" '[ "$(members_of "$HOME_WT/teams/demo.json")" = "demo-architect,demo-reviewer" ]'
check "C5: no team file is created in the main checkout" '[ ! -e "$HOME_MAIN/teams/demo.json" ]'

# ==== A1 — a worktree peer launched with the home's AH_TEAM_FILE still resolves its team ====
reset_state; setup_roster
spawn architect - "$WT"
r HERDR_PANE_ID=p1 AH_TEAM_FILE="$HOME_MAIN/teams/demo.json" -- whoami --cwd "$WT"
check "A1: whoami from the worktree names the member via env" 'echo "$OUT" | grep -q "\"name\": \"demo-architect\"" && echo "$OUT" | grep -q "\"answered_by\": \"env\""'

# ==== M1/M2 — each member records its own root, so a main-checkout member of a worktree-created
# team is not "misplaced" ====
pane_of() { node -e 'const a=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).find(x=>x.name===process.argv[2]);console.log(a?a.pane_id:"")' "$STATE/agents.json" "$1"; }
# ss_run <cwd> <agent_type> <pane> <session>: SessionStart for a launched member, invoked without a
# subshell so its recorded pid is this script's own.
ss_run() {
  echo "{\"session_id\":\"$4\",\"cwd\":\"$1\",\"agent_type\":\"$2\",\"hook_event_name\":\"SessionStart\",\"source\":\"startup\"}" > "$T/ss_in.json"
  env HOME="$T/home" HERDR_PANE_ID="$3" AH_TEAM_FILE="$HOME_MAIN/teams/demo.json" ${SS_ENV:+"$SS_ENV"} PATH="$T/bin:$T/nolaunch:$NODE_DIR:/usr/bin:/bin" FAKE_STATE_DIR="$STATE" node "$H/sessionstart.mjs" < "$T/ss_in.json" > "$T/ss_out.json" 2>&1
  SS_RC=$?; SS_OUT=$(cat "$T/ss_out.json")
}
last_row_misplaced() { node -e 'const L=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n").map(JSON.parse).filter(r=>r.session_id===process.argv[2]);const r=L[L.length-1];console.log(r?String(r.misplaced):"norow")' "$1" "$2"; }

reset_state; setup_roster
spawn architect - "$WT"; spawn reviewer - "$REPO"
RPANE=$(pane_of demo-reviewer)
check "M1: the main-checkout member's row records its own root" '[ "$(node -e "const t=JSON.parse(require(\"fs\").readFileSync(process.argv[1],\"utf8\"));console.log(t.members.find(m=>m.name===\"demo-reviewer\").expected_root)" "$HOME_MAIN/teams/demo.json")" = "$REPO" ]'
ss_run "$REPO" ah:reviewer "$RPANE" m1-sess
check "M1: SessionStart in the member's own checkout is not misplaced" '[ "$SS_RC" -eq 0 ] && [ "$(last_row_misplaced "$HOME_MAIN/peers.jsonl" m1-sess)" = "false" ] && ! echo "$SS_OUT" | grep -q "Misplaced:"'
env HOME="$T/home" HERDR_PANE_ID="$RPANE" CLAUDE_PID=$$ AH_TEAM_FILE="$HOME_MAIN/teams/demo.json" PATH="$T/bin:$T/nolaunch:$NODE_DIR:/usr/bin:/bin" node "$H/roster.mjs" checkin --cwd "$REPO" > "$T/ci.json" 2>&1; RC=$?; OUT=$(cat "$T/ci.json")
check "M1: checkin from the member's own checkout exits 0, misplaced false" '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"misplaced\": false"'
r CLAUDE_PID=$$ -- teams --cwd "$REPO"
check "M1: teams lists no misplaced member" '[ "$(jq_ "o.teams.find(t=>t.name===\"demo\").misplaced_members.length")" = "0" ]'
echo "{\"session_id\":\"m1-sess\",\"cwd\":\"$REPO\",\"agent_type\":\"ah:reviewer\",\"tool_name\":\"EnterWorktree\",\"tool_input\":{\"path\":\"$WT\"}}" > "$T/gate_in.json"
GOUT=$(env HOME="$T/home" HERDR_PANE_ID="$RPANE" AH_TEAM_FILE="$HOME_MAIN/teams/demo.json" node "$H/pretooluse-worktree-gate.mjs" < "$T/gate_in.json" 2>&1)
check "M1: the worktree gate does not offer relocation to the team-level root" 'echo "$GOUT" | grep -q "\"deny\""'

# M2: a member row without expected_root falls back to the team's root, as before
node -e 'const fs=require("fs"),p=process.argv[1];const t=JSON.parse(fs.readFileSync(p));for(const m of t.members)delete m.expected_root;fs.writeFileSync(p,JSON.stringify(t))' "$HOME_MAIN/teams/demo.json"
ss_run "$REPO" ah:reviewer "$RPANE" m2-sess
check "M2: no member root -> the team's root applies (a main-checkout session of a worktree-rooted team is misplaced)" '[ "$(last_row_misplaced "$HOME_MAIN/peers.jsonl" m2-sess)" = "true" ]'

# M3: the launch hands the session its root, so the first SessionStart (no member row for its pane
# yet) is not misplaced; the team-level root is the worktree
SS_ENV="AH_EXPECTED_ROOT=$REPO" ss_run "$REPO" ah:reviewer p99 m3-sess
check "M3: launch-injected root, no member row -> not misplaced" '[ "$(last_row_misplaced "$HOME_MAIN/peers.jsonl" m3-sess)" = "false" ] && ! echo "$SS_OUT" | grep -q "Misplaced:"'
SS_ENV="AH_EXPECTED_ROOT=$WT" ss_run "$REPO" ah:reviewer p99 m3c-sess
check "M3: the injected root is what is compared (a mismatch is still misplaced)" '[ "$(last_row_misplaced "$HOME_MAIN/peers.jsonl" m3c-sess)" = "true" ]'
SS_ENV=
# M3b: spawn-one's launch settings carry the launch cwd as AH_EXPECTED_ROOT
reset_state; setup_roster
spawn architect - "$WT"
check "M3b: the launch settings carry AH_EXPECTED_ROOT = the launch cwd" 'log_has "AH_EXPECTED_ROOT\\\\\":\\\\\"$WT"'

# ==== teardown: L1/L2, V1-V3, W-1, S1-S7, D1, T1, C6, C7 ====
# seed_peers: mimic each launched agent's SessionStart row, in the pool of the checkout it runs in.
seed_peers() {
  node -e '
    const fs=require("fs"),path=require("path");
    for(const a of JSON.parse(fs.readFileSync(process.argv[1],"utf8"))){
      if(!a.cwd)continue;
      const pool=path.join(a.cwd,".claude","hierarchy");fs.mkdirSync(pool,{recursive:true});
      const role=a.name.replace(/^[a-z]+-/,"").replace(/-\d+$/,"");
      fs.appendFileSync(path.join(pool,"peers.jsonl"),JSON.stringify({type:"peer",status:"up",name:a.name,role,pid:Number(process.argv[2]),pane_id:a.pane_id,ts:new Date().toISOString()})+"\n");
    }' "$STATE/agents.json" "$SLEEPER"
}
# put_agent <name> <pane> <cwd>: a herdr agent no team file names.
put_agent() {
  node -e 'const fs=require("fs"),f=process.argv[1];let a=[];try{a=JSON.parse(fs.readFileSync(f))}catch{}a.push({agent:"claude",agent_status:"idle",name:process.argv[2],pane_id:process.argv[3],terminal_title_stripped:process.argv[2],cwd:process.argv[4]});fs.writeFileSync(f,JSON.stringify(a))' "$STATE/agents.json" "$1" "$2" "$3"
}
rename_agent() { node -e 'const fs=require("fs"),f=process.argv[1];fs.writeFileSync(f,JSON.stringify(JSON.parse(fs.readFileSync(f)).map(a=>a.pane_id===process.argv[2]?{...a,name:process.argv[3]}:a)))' "$STATE/agents.json" "$1" "$2"; }
close_names() { jq_ 'o.close.map(c=>c.name).sort().join(",")'; }
plan() { r CLAUDE_PID="$SLEEPER" -- disband --plan "$@"; }
closecmd() { # <team-args…> --cwd X : plan, then close with its token
  plan "$@"; PTOKEN=$(jq_ 'o.close_token')
  r CLAUDE_PID="$SLEEPER" "${CLOSE_ENV[@]}" -- disband --close --confirm --plan-token "$PTOKEN" "$@"
}
CLOSE_ENV=()
FIVE="demo-architect,demo-implementor,demo-implementor-2,demo-reviewer,demo-ultra-advisor"
closed_panes() { grep -c '"pane","close"' "$STATE/log" 2>/dev/null; }

# L1 — the field scenario: the plan from the worktree and from main both hold all five
field_scenario; seed_peers
plan --team demo --cwd "$WT"
check "L1: plan from the worktree closes all five members" '[ "$(close_names)" = "$FIVE" ] && [ "$(jq_ o.expected)" = "5" ]'
plan --team demo --cwd "$REPO"
check "L1: plan from the main checkout closes all five members" '[ "$(close_names)" = "$FIVE" ] && [ "$(jq_ o.expected)" = "5" ]'
check "L1: the plan names the team file it read" '[ "$(jq_ "o.team_files[0]")" = "$HOME_MAIN/teams/demo.json" ]'

# L2 + V1 — close from the worktree: five pane closes, verified
CLOSE_ENV=(); : > "$STATE/log"
closecmd --team demo --cwd "$WT"
check "L2: close from the worktree closes all five, verified" '[ "$RC" -eq 0 ] && [ "$(jq_ o.closed)" = "true" ] && [ "$(jq_ o.closed_count)" = "5" ] && [ "$(jq_ "o.still_live.length")" = "0" ] && [ "$(closed_panes)" = "5" ]'
check "V1: a verified close leaves no warning and removes the team file" '[ "$(jq_ "o.warnings.length")" = "0" ] && [ ! -e "$HOME_MAIN/teams/demo.json" ]'

# V2 — pane close succeeds but the agent stays listed
field_scenario; seed_peers
CLOSE_ENV=(FAKE_CLOSE_NOOP=1)
closecmd --team demo --cwd "$WT"
check "V2: a close that leaves the agents listed is not reported closed" '[ "$RC" -eq 0 ] && [ "$(jq_ o.closed)" = "false" ] && [ "$(jq_ "o.still_live.length")" = "5" ] && echo "$OUT" | grep -q "still live"'
CLOSE_ENV=()

# V3 — the verify query fails
field_scenario; seed_peers
CLOSE_ENV=()
plan --team demo --cwd "$WT"; PTOKEN=$(jq_ 'o.close_token')
r CLAUDE_PID="$SLEEPER" FAKE_LIST_FAIL=1 -- disband --close --confirm --plan-token "$PTOKEN" --team demo --cwd "$WT"
check "V3: an unqueryable transport leaves the close unverified, with a warning" '[ "$(jq_ o.closed)" = "false" ] && echo "$OUT" | grep -q "could not be queried"'

# V4 — a team of terminal-transport members has nothing to close: not closed, not silently ok
field_scenario; seed_peers
node -e 'const fs=require("fs"),p=process.argv[1];const t=JSON.parse(fs.readFileSync(p));t.transport="terminal";fs.writeFileSync(p,JSON.stringify(t))' "$HOME_MAIN/teams/demo.json"
CLOSE_ENV=()
plan --team demo --cwd "$WT"; PTOKEN=$(jq_ 'o.close_token')
check "V4: the plan raises W8 too" 'echo "$OUT" | grep -q "W8: 5 members cannot be closed from here"'
r CLAUDE_PID="$SLEEPER" -- disband --close --confirm --plan-token "$PTOKEN" --team demo --cwd "$WT"
check "V4: terminal-only team -> closed false, members listed in not_closable, W8 raised" '[ "$(jq_ o.closed)" = "false" ] && [ "$(jq_ "o.not_closable.length")" = "5" ] && echo "$OUT" | grep -q "W8: 5 members cannot be closed from here"'

# W-1 — live peers, no team record in either dir
reset_state; setup_roster
mkdir -p "$HOME_WT"
echo "{\"type\":\"peer\",\"status\":\"up\",\"name\":\"demo-architect\",\"role\":\"architect\",\"pid\":$SLEEPER,\"pane_id\":\"p7\",\"ts\":\"2026-01-01T00:00:00Z\"}" > "$HOME_WT/peers.jsonl"
plan --team demo --cwd "$WT"
check "W-1: live peers with no team record are warned about, not reported absent" 'echo "$OUT" | grep -q "No team record for demo" && [ "$(jq_ o.expected)" = "1" ]'

# S1-S5 — strays: herdr agents named for this checkout that no team file names
reset_state; setup_roster
put_agent myrepo-architect p8 "$REPO"
plan --cwd "$WT"
check "S1: a stray named for the checkout is in the close set, flagged, with the residual-risk warning" '[ "$(close_names)" = "myrepo-architect" ] && [ "$(jq_ "o.strays[0]")" = "myrepo-architect" ] && echo "$OUT" | grep -q "matched by name and checkout only"'
reset_state; setup_roster; put_agent myrepo-orchestrator p8 "$REPO"
plan --cwd "$WT"
check "S2: another orchestrator is never a stray" '[ "$(jq_ o.expected)" = "0" ] || echo "$OUT" | grep -q "no active team and no live peers"'
reset_state; setup_roster; put_agent other-architect p8 "$REPO"; put_agent notahierarchyname p9 "$REPO"
plan --cwd "$WT"
check "S3: another prefix or an unparseable name is not matched" 'echo "$OUT" | grep -q "no active team and no live peers"'
reset_state; setup_roster; put_agent myrepo-architect p8 "$OTHER"
plan --cwd "$WT"
check "S4: a same-named agent in another repo is not matched" 'echo "$OUT" | grep -q "no active team and no live peers"'
reset_state; setup_roster; put_agent myrepo-architect p8 "$REPO"
mkdir -p "$HOME_MAIN/teams"
echo "{\"version\":1,\"team_id\":\"t9\",\"created\":\"2026-01-01T00:00:00Z\",\"transport\":\"herdr\",\"orchestrator\":{\"pid\":$$},\"members\":[{\"role\":\"architect\",\"name\":\"myrepo-architect\",\"route\":\"peer\",\"transport_id\":\"p8\"}]}" > "$HOME_MAIN/teams/other.json"
plan --cwd "$WT"
check "S5: an agent that is a member of another team file is not a stray" 'echo "$OUT" | grep -q "no active team and no live peers"'

# S6 — an agent renamed between plan and close is left alone
field_scenario; seed_peers
plan --team demo --cwd "$WT"; PTOKEN=$(jq_ 'o.close_token')
rename_agent p3 other-reviewer
r CLAUDE_PID="$SLEEPER" -- disband --close --confirm --plan-token "$PTOKEN" --team demo --cwd "$WT"
check "S6: a pane that now carries another agent's name is not closed, and says so" '[ "$(jq_ o.closed)" = "false" ] && echo "$OUT" | grep -q "now carries other-reviewer" && [ "$(jq_ o.closed_count)" = "4" ]'

# S8/S9 — a stray is closed only when a fresh query still shows it under the name it was matched by.
# list_calls_before_close <log offset>: how many `agent list` calls precede the first pane close
list_calls_before_close() {
  node -e 'const L=require("fs").readFileSync(process.argv[1],"utf8").trim().split("\n").slice(Number(process.argv[2]));let n=0;for(const l of L){if(l.includes("\"pane\",\"close\""))break;if(l.includes("\"agent\",\"list\""))n++}console.log(n)' "$STATE/log" "$1"
}
stray_close() {  # <env words…>: plan, then close the one stray with those env words
  reset_state; setup_roster; put_agent myrepo-architect p8 "$REPO"
  plan --cwd "$WT"; PTOKEN=$(jq_ 'o.close_token')
  rm -f "$STATE/listcount"; STRAY_OFF=$(wc -l < "$STATE/log")
  r CLAUDE_PID="$SLEEPER" "$@" -- disband --close --confirm --plan-token "$PTOKEN" --cwd "$WT"
}
stray_close; STRAY_K=$(list_calls_before_close "$STRAY_OFF")
check "S8: baseline — an unchanged stray is closed and verified" '[ "$(jq_ o.closed)" = "true" ] && [ "$STRAY_K" -ge 1 ]'
stray_close FAKE_LIST_FAIL_FROM="$STRAY_K"
check "S8: the re-check query fails -> the stray is not closed, with a warning" '[ "$(jq_ o.closed)" = "false" ] && [ "$(sed -n "$((STRAY_OFF+1)),\$p" "$STATE/log" | grep -c "\"pane\",\"close\"")" = "0" ] && echo "$OUT" | grep -q "could not be re-checked"'
stray_close FAKE_NAMELESS_FROM="$STRAY_K" FAKE_NAMELESS_PANE=p8
check "S9: the pane has lost its name -> the stray is not closed, with a warning" '[ "$(jq_ o.closed)" = "false" ] && [ "$(sed -n "$((STRAY_OFF+1)),\$p" "$STATE/log" | grep -c "\"pane\",\"close\"")" = "0" ] && echo "$OUT" | grep -q "now carries (no name)"'

# V5 — no team record: a live peer with no pane keeps the close from reporting success
reset_state; setup_roster
mkdir -p "$HOME_WT"
put_agent demo-architect p7 "$WT"
{ echo "{\"type\":\"peer\",\"status\":\"up\",\"name\":\"demo-architect\",\"role\":\"architect\",\"pid\":$SLEEPER,\"pane_id\":\"p7\",\"ts\":\"2026-01-01T00:00:00Z\"}"
  echo "{\"type\":\"peer\",\"status\":\"up\",\"name\":\"demo-reviewer\",\"role\":\"reviewer\",\"pid\":$SLEEPER,\"ts\":\"2026-01-01T00:00:00Z\"}"; } > "$HOME_WT/peers.jsonl"
plan --team demo --cwd "$WT"; PTOKEN=$(jq_ 'o.close_token')
r CLAUDE_PID="$SLEEPER" -- disband --close --confirm --plan-token "$PTOKEN" --team demo --cwd "$WT"
check "V5: no team record, one pane peer closed and one peer with no pane -> closed false, not_closable listed, W8" '[ "$(jq_ o.closed)" = "false" ] && [ "$(jq_ "o.not_closable.length")" = "1" ] && echo "$OUT" | grep -q "W8"'

# S7 — a pool copy owned by another live orchestrator is read and left alone
field_scenario; seed_peers
mkdir -p "$HOME_WT/teams"
echo "{\"version\":1,\"team_id\":\"old\",\"created\":\"2026-01-01T00:00:00Z\",\"transport\":\"herdr\",\"orchestrator\":{\"pid\":$$},\"members\":[{\"role\":\"architect\",\"name\":\"demo-legacy-architect\",\"route\":\"peer\",\"transport_id\":\"p99\"}]}" > "$HOME_WT/teams/demo.json"
plan --team demo --cwd "$WT"
check "S7: a pool copy owned by another live orchestrator is skipped with a warning" 'echo "$OUT" | grep -q "belongs to another live orchestrator" && echo "$OUT" | grep -q "left by an older release" && ! echo "$OUT" | grep -q "demo-legacy-architect"'

# C6 — a split owned by this session: both copies are read; teardown covers both
field_scenario; seed_peers
mkdir -p "$HOME_WT/teams"
echo "{\"version\":1,\"team_id\":\"old\",\"created\":\"2026-01-01T00:00:00Z\",\"transport\":\"herdr\",\"orchestrator\":{\"pid\":$SLEEPER},\"members\":[{\"role\":\"architect\",\"name\":\"demo-legacy-architect\",\"route\":\"peer\",\"transport_id\":\"p99\"}]}" > "$HOME_WT/teams/demo.json"
plan --team demo --cwd "$WT"
check "C6: a split team's pool copy is read by teardown, with a warning" 'echo "$OUT" | grep -q "left by an older release" && echo "$OUT" | grep -q "demo-legacy-architect" && [ "$(jq_ "o.team_files.length")" = "2" ]'
reset_state; setup_roster; spawn architect - "$WT"
mkdir -p "$HOME_WT/teams"; echo '{"version":1,"team_id":"old","created":"2026-01-01T00:00:00Z","transport":"herdr","orchestrator":{"pid":1},"members":[]}' > "$HOME_WT/teams/demo.json"
spawn reviewer - "$WT"
check "C6: spawn warns when the team is split across two dirs" 'echo "$OUT" | grep -q "has records in"'

# D2 — a dismiss plan for a target with no pane lists it and raises W8; D3 — one with a pane does not
field_scenario; seed_peers
node -e 'const fs=require("fs"),p=process.argv[1];const t=JSON.parse(fs.readFileSync(p));t.transport="terminal";fs.writeFileSync(p,JSON.stringify(t))' "$HOME_MAIN/teams/demo.json"
r CLAUDE_PID="$SLEEPER" -- dismiss demo-architect --cwd "$WT"
check "D2: team member on a terminal transport -> plan lists it in not_closable with W8, no next" '[ "$RC" -eq 0 ] && [ "$(jq_ o.expected)" = "0" ] && [ "$(jq_ "o.next===undefined")" = "true" ] && [ "$(jq_ "o.not_closable.map(m=>m.name).join()")" = "demo-architect" ] && [ "$(jq_ "o.warnings.filter(w=>w.startsWith(\"W8\")&&w.includes(\"demo-architect\")).length")" = "1" ]'
reset_state; setup_roster
mkdir -p "$HOME_WT"
echo "{\"type\":\"peer\",\"status\":\"up\",\"name\":\"demo-reviewer\",\"role\":\"reviewer\",\"pid\":$SLEEPER,\"ts\":\"2026-01-01T00:00:00Z\"}" > "$HOME_WT/peers.jsonl"
r CLAUDE_PID="$SLEEPER" -- dismiss demo-reviewer --cwd "$WT"
check "D2: live peer record with no pane_id -> plan lists it in not_closable with W8, no next" '[ "$RC" -eq 0 ] && [ "$(jq_ o.expected)" = "0" ] && [ "$(jq_ "o.next===undefined")" = "true" ] && [ "$(jq_ "o.not_closable.map(m=>m.name).join()")" = "demo-reviewer" ] && [ "$(jq_ "o.warnings.filter(w=>w.startsWith(\"W8\")&&w.includes(\"demo-reviewer\")).length")" = "1" ]'
field_scenario; seed_peers
r CLAUDE_PID="$SLEEPER" -- dismiss demo-architect --cwd "$WT"
check "D3: a member with a pane -> not_closable empty, no W8" '[ "$RC" -eq 0 ] && [ "$(jq_ "o.not_closable.length")" = "0" ] && ! echo "$OUT" | grep -q "W8"'

# D4 — dismiss --close on a terminal-transport member that has a transport_id still has no pane to close
field_scenario; seed_peers
node -e 'const fs=require("fs"),p=process.argv[1];const t=JSON.parse(fs.readFileSync(p));t.transport="terminal";fs.writeFileSync(p,JSON.stringify(t))' "$HOME_MAIN/teams/demo.json"
: > "$STATE/log"
r CLAUDE_PID="$SLEEPER" -- dismiss demo-architect --close --confirm --plan-token x --cwd "$WT"
check "D4: terminal member with a pane id -> dismiss --close fails with exit 2, no addressable pane, nothing closed" '[ "$RC" -eq 2 ] && echo "$OUT" | grep -q "no addressable pane" && [ "$(grep -c "\"pane\",\"close\"" "$STATE/log")" = "0" ]'

# D1 — dismiss a stray
reset_state; setup_roster; put_agent myrepo-architect p8 "$REPO"
r -- dismiss myrepo-architect --cwd "$WT"
DTOKEN=$(jq_ 'o.close_token')
r -- dismiss myrepo-architect --close --confirm --plan-token "$DTOKEN" --cwd "$WT"
check "D1: dismiss closes a stray and verifies it gone" '[ "$(jq_ o.closed)" = "true" ] && [ "$(jq_ "o.still_live.length")" = "0" ]'

# T1 — teams from the worktree sees the team
field_scenario; seed_peers
r CLAUDE_PID="$SLEEPER" -- teams --cwd "$WT"
check "T1: teams from the worktree lists the team and its five members" '[ "$(jq_ "o.teams.length")" = "1" ] && [ "$(jq_ "o.teams[0].name")" = "demo" ] && [ "$(jq_ "o.teams[0].members")" = "5" ]'

# C7 — spawning into another checkout than the caller's is warned about, never blocked
reset_state; setup_roster
(cd "$REPO" && env HOME="$T/home" HERDR_ENV=1 HERDR_PANE_ID=p0 PATH="$T/bin:$T/nolaunch:$NODE_DIR:/usr/bin:/bin" FAKE_STATE_DIR="$STATE" FAKE_AGENT_CWD="$OTHER" node "$H/roster.mjs" spawn-one architect --team demo --orchestrator-pid "$SLEEPER" --cwd "$OTHER" > "$T/c7.out" 2>&1); RC=$?; OUT=$(cat "$T/c7.out")
check "C7: a spawn into another checkout warns and still spawns" '[ "$RC" -eq 0 ] && echo "$OUT" | grep -q "\"spawned\": true" && echo "$OUT" | grep -q "will not see it"'

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
