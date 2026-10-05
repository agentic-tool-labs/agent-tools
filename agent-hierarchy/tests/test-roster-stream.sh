#!/bin/bash
# agent-hierarchy — roster.mjs stream verbs (stream-open / stream-status / stream-done /
# stream-label), `spawn-one|spawn-ad-hoc --stream`, and hooks/stream-label.mjs.
# A stateful fake `herdr` and a logging wrapper over the real `git` sit first on PATH, so no real
# herdr, tmux or ~/.claude is ever touched. HOME-redirected.
# Usage: bash tests/test-roster-stream.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-roster-stream-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
# No test may reach the real herdr or tmux: a stub that fails every call sits first on PATH, and
# the session's pane environment is dropped. A wrapper that sets PATH to its own fakes still wins.
mkdir -p "$SANDBOX/nolaunch"; printf '#!/bin/sh\nexit 1\n' > "$SANDBOX/nolaunch/herdr"; cp "$SANDBOX/nolaunch/herdr" "$SANDBOX/nolaunch/tmux"; chmod +x "$SANDBOX/nolaunch/herdr" "$SANDBOX/nolaunch/tmux"
REAL_GIT="$(command -v git)"
export PATH="$SANDBOX/nolaunch:$PATH"; unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID TMUX_PANE TMUX AH_TEAM_FILE
unset CLAUDE_PID  # every Claude session exports one; a test must not inherit it
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/myrepo"
STATE="$SANDBOX/state"
mkdir -p "$FAKEHOME/.claude" "$SANDBOX/bin" "$STATE"
NODE_DIR="$(dirname "$(command -v node)")"
TEAM_FILE="$PROJ/.claude/hierarchy/teams/myrepo.json"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:600} ERR=$(head -c 400 "$STATE/err" 2>/dev/null))"; fi
}

# ---- fake herdr: state in $STATE/herdr.json, every argv appended to $STATE/herdr.log.
# FAKE_HERDR_FAIL=1 fails every call; FAKE_HERDR_FAIL_CMD="tab create,tab rename" fails those.
cat > "$SANDBOX/bin/herdr" <<EOF
#!$(command -v node)
$(cat <<'FAKEEOF'
const fs = require("fs");
const path = require("path");
const args = process.argv.slice(2);
const dir = process.env.FAKE_STATE_DIR;
fs.appendFileSync(path.join(dir, "herdr.log"), JSON.stringify(args) + "\n");
const stFile = path.join(dir, "herdr.json");
const st = JSON.parse(fs.readFileSync(stFile, "utf8"));
const save = () => fs.writeFileSync(stFile, JSON.stringify(st));
const ok = (result) => { console.log(JSON.stringify({ id: "fake", result })); process.exit(0); };
const err = (code, message) => { process.stderr.write(JSON.stringify({ error: { code, message } }) + "\n"); process.exit(1); };
const cmd = `${args[0]} ${args[1]}`;
if (process.env.FAKE_HERDR_FAIL === "1") err("forced", "forced failure");
if ((process.env.FAKE_HERDR_FAIL_CMD || "").split(",").includes(cmd)) err("forced", `forced ${cmd} failure`);
const flag = (n) => { const i = args.indexOf(`--${n}`); return i < 0 ? undefined : args[i + 1]; };
const tabPanes = (t) => Object.entries(st.panes).filter(([, p]) => p.tab === t);
switch (cmd) {
  case "tab create": {
    const ws = flag("workspace") || "w1";
    const t = `${ws}:t${st.next++}`;
    const p = `${ws}:p${st.next++}`;
    st.tabs[t] = { label: flag("label") || "", ws };
    st.panes[p] = { tab: t, ws, cwd: flag("cwd") || null, rect: { x: 0, y: 0, width: 200, height: 50 } };
    save();
    ok({ type: "tab_created", tab: { tab_id: t, label: st.tabs[t].label, workspace_id: ws, pane_count: 1, focused: false }, root_pane: { pane_id: p, tab_id: t, workspace_id: ws, cwd: st.panes[p].cwd, focused: false } });
  }
  case "tab rename": {
    const t = args[2];
    if (!st.tabs[t]) err("tab_not_found", `tab ${t} not found`);
    st.tabs[t].label = args.slice(3).join(" ");
    save();
    ok({ type: "tab_info", tab: { tab_id: t, label: st.tabs[t].label, workspace_id: st.tabs[t].ws } });
  }
  case "tab list":
    ok({ type: "tab_list", tabs: Object.entries(st.tabs).filter(([, t]) => !flag("workspace") || t.ws === flag("workspace")).map(([id, t]) => ({ tab_id: id, label: t.label, workspace_id: t.ws, pane_count: tabPanes(id).length, focused: false })) });
  case "pane list":
    ok({ type: "pane_list", panes: Object.entries(st.panes).filter(([, p]) => !flag("workspace") || p.ws === flag("workspace")).map(([id, p]) => ({ pane_id: id, tab_id: p.tab, workspace_id: p.ws, cwd: p.cwd, focused: false })) });
  case "pane layout": {
    const pid = args.includes("--current") ? st.self : flag("pane");
    const p = st.panes[pid];
    if (!p) err("pane_not_found", `pane ${pid} not found`);
    ok({ type: "pane_layout", layout: { tab_id: p.tab, workspace_id: p.ws, area: { x: 0, y: 0, width: 200, height: 50 }, focused_pane_id: pid, panes: tabPanes(p.tab).map(([id, q]) => ({ pane_id: id, focused: false, rect: q.rect })), splits: [], zoomed: false } });
  }
  case "pane split": {
    const target = flag("pane");
    const p = st.panes[target];
    if (!p) err("pane_not_found", `pane ${target} not found`);
    const id = `${p.ws}:p${st.next++}`;
    const r = p.rect;
    let a, b;
    if (flag("direction") === "right") { const w = Math.floor(r.width / 2); a = { ...r, width: w }; b = { ...r, width: r.width - w, x: r.x + w }; }
    else { const h = Math.floor(r.height / 2); a = { ...r, height: h }; b = { ...r, height: r.height - h, y: r.y + h }; }
    p.rect = a;
    st.panes[id] = { tab: p.tab, ws: p.ws, cwd: flag("cwd") || null, rect: b };
    save();
    ok({ type: "pane_split", pane: { pane_id: id, tab_id: p.tab, workspace_id: p.ws } });
  }
  case "pane rename":
    ok({ type: "pane_info", pane: { pane_id: args[2] } });
  case "pane close": {
    delete st.panes[args[2]];
    delete st.agents[args[2]];
    save();
    ok({ type: "ok" });
  }
  case "pane move": {
    const p = st.panes[args[2]];
    if (!p) err("pane_not_found", `pane ${args[2]} not found`);
    if (args.includes("--new-tab")) { const t = `${p.ws}:t${st.next++}`; st.tabs[t] = { label: "", ws: p.ws }; p.tab = t; }
    save();
    ok({ type: "pane_moved", move_result: { pane: { pane_id: args[2], tab_id: p.tab, workspace_id: p.ws } } });
  }
  case "agent start": {
    const pid = flag("pane");
    if (!st.panes[pid]) err("pane_not_found", `pane ${pid} not found`);
    st.agents[pid] = { name: args[2], status: "idle" };
    save();
    ok({ pane: { pane_id: pid }, agent: { name: args[2], ready: true } });
  }
  case "agent list":
    ok({ type: "agent_list", agents: Object.entries(st.agents).filter(([id]) => st.panes[id]).map(([id, a]) => ({ name: a.name, pane_id: id, tab_id: st.panes[id].tab, workspace_id: st.panes[id].ws, agent_status: a.status })) });
}
err("unhandled", `fake herdr: unhandled args ${JSON.stringify(args)}`);
FAKEEOF
)
EOF
chmod +x "$SANDBOX/bin/herdr"

# ---- git: the real binary, every argv logged to $STATE/git.log.
cat > "$SANDBOX/bin/git" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$STATE/git.log"
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$SANDBOX/bin/git"

# ---- tmux: FAKE_TMUX=up answers every call (new-window prints a pane id); anything else fails.
cat > "$SANDBOX/bin/tmux" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >> "$STATE/tmux.log"
[ "\$FAKE_TMUX" = up ] || exit 1
[ "\$1" = new-window ] && echo "%9"
exit 0
EOF
chmod +x "$SANDBOX/bin/tmux"

fresh() { # a new repo on main with one commit, no hierarchy, fresh fake herdr state, empty logs
  rm -rf "$PROJ" "$SANDBOX/other"
  mkdir -p "$PROJ"
  "$REAL_GIT" -C "$PROJ" init -q -b main
  "$REAL_GIT" -C "$PROJ" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
  cat > "$STATE/herdr.json" <<EOF
{"next":10,"self":"w1:p0","tabs":{"w1:t1":{"label":"1","ws":"w1"}},"panes":{"w1:p0":{"tab":"w1:t1","ws":"w1","cwd":"$PROJ","rect":{"x":0,"y":0,"width":200,"height":50}}},"agents":{}}
EOF
  clear_logs
}
clear_logs() { : > "$STATE/herdr.log"; : > "$STATE/git.log"; : > "$STATE/tmux.log"; }

# run <verb> [args...] — herdr transport (HERDR_ENV=1). Env overrides go before the call:
#   TRANSPORT=tmux|terminal run ...   FAKE_HERDR_FAIL_CMD="tab create" run ...
run() {
  local envs=(HOME="$FAKEHOME" PATH="$SANDBOX/bin:$NODE_DIR" FAKE_STATE_DIR="$STATE" CLAUDE_PID=$$ FAKE_HERDR_FAIL="${FAKE_HERDR_FAIL:-0}" FAKE_HERDR_FAIL_CMD="${FAKE_HERDR_FAIL_CMD:-}")
  case "${TRANSPORT:-herdr}" in
    herdr) envs+=(HERDR_ENV=1 HERDR_PANE_ID=w1:p0 HERDR_WORKSPACE_ID=w1 FAKE_TMUX=down) ;;
    tmux) envs+=(FAKE_TMUX=up) ;;
    terminal) envs+=(FAKE_TMUX=down) ;;
  esac
  OUT=$(env -u HERDR_ENV "${envs[@]}" node "$H/roster.mjs" "$@" --cwd "$PROJ" 2>"$STATE/err"); RC=$?
}
# oj <js boolean over `o`, the parsed stdout>
oj() { printf '%s' "$OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{let o;try{o=JSON.parse(s)}catch{process.exit(1)}process.exit((new Function("o","return ("+process.argv[1]+");"))(o)?0:1)})' "$1"; }
# tj <js boolean over `t`, the parsed team file>
tj() { node -e 'const fs=require("fs");let t;try{t=JSON.parse(fs.readFileSync(process.argv[1],"utf8"))}catch{process.exit(1)}process.exit((new Function("t","return ("+process.argv[2]+");"))(t)?0:1)' "$TEAM_FILE" "$1"; }
# hj <js boolean over `s`, the fake herdr state>
hj() { node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.exit((new Function("s","return ("+process.argv[2]+");"))(s)?0:1)' "$STATE/herdr.json" "$1"; }
hcount() { grep -c -- "$1" "$STATE/herdr.log"; }
set_status() { # <pane> <status>: a live agent's herdr status
  node -e 'const fs=require("fs"),f=process.argv[1];const s=JSON.parse(fs.readFileSync(f,"utf8"));s.agents[process.argv[2]].status=process.argv[3];fs.writeFileSync(f,JSON.stringify(s))' "$STATE/herdr.json" "$1" "$2"
}
kill_agent() { # <pane>: the agent is gone, the pane stays
  node -e 'const fs=require("fs"),f=process.argv[1];const s=JSON.parse(fs.readFileSync(f,"utf8"));delete s.agents[process.argv[2]];fs.writeFileSync(f,JSON.stringify(s))' "$STATE/herdr.json" "$1"
}
member_pane() { node -e 'const t=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const m=t.members.find(m=>m.name===process.argv[2]);console.log(m?m.transport_id:"")' "$TEAM_FILE" "$1"; }
stream_tab() { node -e 'const t=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log((t.streams&&t.streams[process.argv[2]]&&t.streams[process.argv[2]].tab_id)||"")' "$TEAM_FILE" "$1"; }
tab_label() { node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log((s.tabs[process.argv[2]]||{}).label||"")' "$STATE/herdr.json" "$1"; }
request() { # <to role> <to_name> <from_name> -> prints the request path
  HOME="$FAKEHOME" node "$H/msg.mjs" new --to "$1" --from orchestrator --slug s --to-name "$2" --from-name "$3" --team myrepo --cwd "$PROJ" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).path))'
}
respond() { # <request path> <the request's to role>: a filled response, which closes a member's exchange
  local id; id=$(basename "$1" | cut -d- -f1-3)
  local resp; resp=$(HOME="$FAKEHOME" node "$H/msg.mjs" new --type response --id "$id" --to orchestrator --from "$2" --slug s --team myrepo --req "$1" --cwd "$PROJ" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>console.log(JSON.parse(s).path))')
  printf -- '- done: reported\n' >> "$resp"
}
setup_roster() { # repo roster: one architect and one reviewer, both peers
  HOME="$FAKEHOME" node "$H/roster.mjs" init --level repo --route peer --cwd "$PROJ" >/dev/null
  HOME="$FAKEHOME" node "$H/roster.mjs" add --no-spawn --level repo --role architect --model opus --cwd "$PROJ" >/dev/null
  HOME="$FAKEHOME" node "$H/roster.mjs" add --no-spawn --level repo --role reviewer --model opus --cwd "$PROJ" >/dev/null
}

# The herdr argv of `spawn-one architect` with no --stream, captured on main before the stream
# verbs existed. <SB> stands for the sandbox path.
S6_GOLDEN='["pane","layout","--current"]
["pane","split","--pane","w1:p0","--direction","right","--cwd","<SB>/myrepo","--no-focus"]
["agent","start","myrepo-architect","--kind","claude","--pane","w1:p10","--","--agent","ah:architect","--name","myrepo-architect","--model","opus","--settings","{\"env\":{\"AH_TEAM_FILE\":\"<SB>/myrepo/.claude/hierarchy/teams/myrepo.json\"}}"]
["pane","rename","w1:p10","claude","-","myrepo-architect"]'

WT="$PROJ/.claude/worktrees"

# ==== open ====
fresh
run stream-open x
check "O1: exit 0, opened, not existed/reopened" 'oj "o.opened===true && o.existed===false && o.reopened===false && o.transport===\"herdr\""'
check "O1: worktree at .claude/worktrees/x on branch x" '[ "$("$REAL_GIT" -C "$WT/x" rev-parse --abbrev-ref HEAD 2>/dev/null)" = x ]'
check "O1: worktree_created and branch_created" 'oj "o.worktree_created===true && o.branch_created===true"'
check "O1: tab created with label \"· x\", no focus, in the caller workspace" '[ "$(hcount "\"tab\",\"create\"")" -eq 1 ] && grep "\"tab\",\"create\"" "$STATE/herdr.log" | grep -q "\"--label\",\"· x\"" && grep "\"tab\",\"create\"" "$STATE/herdr.log" | grep -q "\"--no-focus\"" && grep "\"tab\",\"create\"" "$STATE/herdr.log" | grep -q "\"--workspace\",\"w1\""'
check "O1: streams.x recorded" 'tj "t.streams.x.state===\"open\" && t.streams.x.branch===\"x\" && t.streams.x.base===\"main\" && t.streams.x.worktree===\"$WT/x\" && t.streams.x.tab_id===\"w1:t10\" && typeof t.streams.x.opened===\"string\" && !(\"closed\" in t.streams.x)"'
check "O1: output stream/label/next shape" 'oj "o.stream.name===\"x\" && o.stream.state===\"open\" && o.stream.tab_id===\"w1:t10\" && o.label===\"· x\" && o.next.length===2 && o.next[0].includes(\"spawn-one <role> --stream x\") && o.next[1].includes(\"spawn-ad-hoc <role> --stream x\") && !(\"degraded\" in o)"'
check "O1: the tab carries the label" '[ "$(tab_label w1:t10)" = "· x" ]'

clear_logs
run stream-open x
check "O2: re-run is idempotent: existed, no second worktree or tab" 'oj "o.existed===true && o.worktree_created===false" && ! grep -q "worktree add" "$STATE/git.log" && [ "$(hcount "\"tab\",\"create\"")" -eq 0 ]'

run stream-open x --branch other --base deadbeef --no-worktree
check "O2b: re-run with differing --branch/--base/--no-worktree keeps the record and warns per flag" '[ "$RC" -eq 0 ] && oj "o.existed===true && o.warnings.length===3 && o.warnings.some(w=>w.startsWith(\"--branch other\")&&w.includes(\"\\\"x\\\"\")) && o.warnings.some(w=>w.startsWith(\"--base deadbeef\")&&w.includes(\"\\\"main\\\"\")) && o.warnings.some(w=>w.startsWith(\"--no-worktree\")&&w.includes(\"$WT/x\"))" && tj "t.streams.x.branch===\"x\" && t.streams.x.base===\"main\" && t.streams.x.worktree===\"$WT/x\""'
run stream-open x --branch x
check "O2c: a matching --branch on a re-run is not a warning" '[ "$RC" -eq 0 ] && oj "!(\"warnings\" in o)"'

clear_logs
run stream-open y --no-worktree
check "O3: --no-worktree: no git call, branch/base/worktree null" '[ "$RC" -eq 0 ] && [ ! -s "$STATE/git.log" ] && tj "t.streams.y.branch===null && t.streams.y.base===null && t.streams.y.worktree===null"'

BASE_SHA=$("$REAL_GIT" -C "$PROJ" rev-parse HEAD)
"$REAL_GIT" -C "$PROJ" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m second
run stream-open z --branch fix/z --base "$BASE_SHA"
check "O4: --branch/--base honoured" '[ "$("$REAL_GIT" -C "$WT/z" rev-parse --abbrev-ref HEAD)" = fix/z ] && [ "$("$REAL_GIT" -C "$WT/z" rev-parse HEAD)" = "$BASE_SHA" ] && tj "t.streams.z.branch===\"fix/z\" && t.streams.z.base===\"$BASE_SHA\""'

BEFORE=$(cat "$TEAM_FILE")
for bad in X 1x "a b" "$(printf 'a%.0s' $(seq 41))"; do
  clear_logs
  run stream-open "$bad"
  check "O5: bad name \"${bad:0:12}\" refused stream-name-invalid, nothing written or called" '[ "$RC" -eq 2 ] && oj "o.refused===\"stream-name-invalid\"" && [ "$(cat "$TEAM_FILE")" = "$BEFORE" ] && [ ! -s "$STATE/git.log" ] && [ ! -s "$STATE/herdr.log" ]'
done

mkdir -p "$WT/occ"
run stream-open occ
check "O6: occupied path refused worktree-path-occupied, nothing written" '[ "$RC" -eq 2 ] && oj "o.refused===\"worktree-path-occupied\"" && tj "!t.streams.occ"'

"$REAL_GIT" -C "$PROJ" worktree add -q -b bb "$SANDBOX/other" 2>/dev/null
run stream-open bb
check "O7: branch checked out elsewhere refused branch-in-use with detail" '[ "$RC" -eq 2 ] && oj "o.refused===\"branch-in-use\" && typeof o.detail===\"string\" && o.detail.length>0" && tj "!t.streams.bb"'

FAKE_HERDR_FAIL_CMD="tab create" run stream-open t8
check "O8: tab create fails: worktree kept, tab_id null, warning" '[ "$RC" -eq 0 ] && [ -d "$WT/t8" ] && tj "t.streams.t8.tab_id===null" && oj "Array.isArray(o.warnings) && o.warnings.length>0 && o.label===null"'
run stream-open t8
check "O8: re-run creates the tab" '[ "$RC" -eq 0 ] && tj "typeof t.streams.t8.tab_id===\"string\"" && oj "o.existed===true"'

for tr in tmux terminal; do
  fresh
  TRANSPORT=$tr run stream-open nt
  check "O9: $tr: zero herdr calls, degraded no-tabs, tab_id null" '[ "$RC" -eq 0 ] && [ ! -s "$STATE/herdr.log" ] && oj "o.degraded===\"no-tabs\" && o.stream.tab_id===null && o.label===null && o.transport===\"$tr\"" && [ -d "$WT/nt" ]'
done

fresh
run stream-open base0 --no-worktree
BEFORE=$(cat "$TEAM_FILE"); clear_logs
run stream-open d --dry-run
check "O10: --dry-run prints the git and herdr argv and the record" '[ "$RC" -eq 0 ] && oj "o.dry_run===true && o.would_run.git.some(a=>a.includes(\"worktree\")&&a.includes(\"add\")) && o.would_run.herdr.some(a=>a[0]===\"tab\"&&a[1]===\"create\") && o.stream.state===\"open\""'
check "O10: --dry-run: no herdr call, no mutating git call, team file unchanged, no worktree" '[ ! -s "$STATE/herdr.log" ] && ! grep -q "worktree add" "$STATE/git.log" && [ "$(cat "$TEAM_FILE")" = "$BEFORE" ] && [ ! -e "$WT/d" ]'

fresh
run stream-open x
run stream-done x
clear_logs
run stream-open x
check "O11: reopen after done: open, closed removed, reopened, label re-rendered" 'oj "o.reopened===true && o.existed===true" && tj "t.streams.x.state===\"open\" && !(\"closed\" in t.streams.x)" && grep -q "\"tab\",\"rename\",\"w1:t10\",\"· x\"" "$STATE/herdr.log"'

# O12: a stream-open team has exactly a spawn-created team's keys, plus `streams`.
fresh
run spawn-ad-hoc architect --model opus
SPAWN_KEYS=$(node -e 'console.log(Object.keys(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))).sort().join(","))' "$TEAM_FILE")
fresh
run stream-open x --no-worktree
check "O12: no team file: created with the spawn constructor's keys plus streams" '[ "$RC" -eq 0 ] && [ "$(node -e "console.log(Object.keys(JSON.parse(require(\"fs\").readFileSync(process.argv[1],\"utf8\"))).sort().join(\",\"))" "$TEAM_FILE")" = "$(echo "$SPAWN_KEYS,streams" | tr , "\n" | sort | paste -sd, -)" ] && tj "t.members.length===0 && t.transport===\"herdr\" && t.orchestrator.pid===$$"'

# ==== spawn --stream ====
fresh
run stream-open x --no-worktree
ROOT=$(node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));console.log(Object.keys(s.panes).find(p=>s.panes[p].tab==="w1:t10"))' "$STATE/herdr.json")
clear_logs
run spawn-ad-hoc architect --model opus --stream x
check "S1: first member launches into the tab root pane, no split" '[ "$RC" -eq 0 ] && [ "$(hcount "\"pane\",\"split\"")" -eq 0 ] && grep "\"agent\",\"start\"" "$STATE/herdr.log" | grep -q "\"--pane\",\"$ROOT\""'
check "S1: row carries stream x and the stream tab_id" 'tj "(m=>m && m.stream===\"x\" && m.tab_id===\"w1:t10\" && m.transport_id===\"$ROOT\")(t.members.find(m=>m.name===\"myrepo-architect\"))"'
check "S1: output carries stream {name, worktree, branch}" 'oj "o.spawned===true && o.stream.name===\"x\" && o.stream.worktree===null && o.stream.branch===null"'
check "S1: label re-rendered after launch (idle member -> ○)" '[ "$(tab_label w1:t10)" = "○ x" ]'
clear_logs
run spawn-ad-hoc reviewer --model opus --stream x
check "S2: second member splits a pane in the stream tab, not HERDR_PANE_ID" '[ "$RC" -eq 0 ] && grep "\"pane\",\"split\"" "$STATE/herdr.log" | grep -q "\"--pane\",\"$ROOT\"" && ! grep "\"pane\",\"split\"" "$STATE/herdr.log" | grep -q "\"w1:p0\"" && grep -q "\"pane\",\"layout\",\"--pane\",\"$ROOT\"" "$STATE/herdr.log"'
check "S2: second member tagged and in the stream tab" 'tj "(m=>m && m.stream===\"x\" && m.tab_id===\"w1:t10\")(t.members.find(m=>m.name===\"myrepo-reviewer\"))" && hj "s.panes[\"$(member_pane myrepo-reviewer)\"].tab===\"w1:t10\""'

clear_logs
run spawn-ad-hoc implementor --model opus --stream nope
check "S3: unknown stream refused, no herdr call" '[ "$RC" -eq 2 ] && oj "o.refused===\"unknown-stream\"" && [ ! -s "$STATE/herdr.log" ]'

run stream-done x
clear_logs
run spawn-ad-hoc implementor --model opus --stream x
check "S4: done stream refused stream-done with the re-open command" '[ "$RC" -eq 2 ] && oj "o.refused===\"stream-done\" && o.next.some(n=>n.includes(\"stream-open x\"))" && [ ! -s "$STATE/herdr.log" ]'

fresh
TRANSPORT=tmux run stream-open s5 --no-worktree
TRANSPORT=tmux run spawn-ad-hoc architect --model opus --stream s5
check "S5: tmux: normal placement, stream tagged, no herdr call" '[ "$RC" -eq 0 ] && [ ! -s "$STATE/herdr.log" ] && grep -q new-window "$STATE/tmux.log" && tj "t.members.find(m=>m.name===\"myrepo-architect\").stream===\"s5\""'

fresh; setup_roster; clear_logs
run spawn-one architect
check "S6: spawn-one without --stream: herdr argv identical to the pre-change golden" '[ "$RC" -eq 0 ] && [ "$(sed "s#$SANDBOX#<SB>#g" "$STATE/herdr.log")" = "$S6_GOLDEN" ]'

# ==== glyph (driven through stream-label with the fake agent list) ====
# Three members in stream g: A, B, C (C's agent then goes away).
fresh
run stream-open g --no-worktree
run spawn-ad-hoc architect --model opus --stream g
run spawn-ad-hoc reviewer --model opus --stream g
run spawn-ad-hoc implementor --model opus --stream g
A=$(member_pane myrepo-architect); B=$(member_pane myrepo-reviewer); C=$(member_pane myrepo-implementor)
GT=$(stream_tab g)
set_status "$A" working; set_status "$B" blocked; set_status "$C" idle
run stream-label g
check "G2: blocked beats working -> ×" '[ "$RC" -eq 0 ] && oj "o.rendered===true && o.label===\"× g\"" && [ "$(tab_label "$GT")" = "× g" ]'
set_status "$B" idle
run stream-label g
check "G4: any working -> ◐" 'oj "o.label===\"◐ g\" && o.previous===\"× g\""'
set_status "$A" idle; set_status "$B" done
run stream-label g
check "G5: idle/done members -> ○" 'oj "o.label===\"○ g\""'
run stream-label g --self-pane "$A" --self-state working
check "G-self: the self override beats herdr's status -> ◐" 'oj "o.label===\"◐ g\""'
kill_agent "$C"
REQ=$(request implementor myrepo-implementor orchestrator-x)
run stream-label g
check "G3: an open request owed by a gone member -> ×" 'oj "o.label===\"× g\""'
respond "$REQ" implementor
run stream-label g
check "G3b: once answered, the gone member no longer blocks -> ○" 'oj "o.label===\"○ g\""'
kill_agent "$A"; kill_agent "$B"
run stream-label g
check "G6: all members gone -> ·" 'oj "o.label===\"· g\""'
run stream-open e --no-worktree
run stream-label e
check "G6b: no members -> ·" 'oj "o.label===\"· e\""'
run stream-done g
run stream-label g
check "G1: done stream: stream-label does not render" '[ "$RC" -eq 0 ] && oj "o.rendered===false && typeof o.reason===\"string\"" && [ "$(tab_label "$GT")" = "✓ g" ]'
clear_logs
run stream-label nope
check "stream-label: unknown stream -> exit 0, rendered false" '[ "$RC" -eq 0 ] && oj "o.rendered===false"'

# ==== status ====
fresh
run stream-open s1
run spawn-ad-hoc architect --model opus --stream s1
run stream-open s2 --no-worktree
run spawn-ad-hoc reviewer --model opus
SA=$(member_pane myrepo-architect)
set_status "$SA" working
REQ1=$(request architect myrepo-architect orchestrator-x)
REQ2=$(request architect myrepo-architect orchestrator-x)
respond "$REQ2" architect
BEFORE=$(cat "$TEAM_FILE"); clear_logs
run stream-status
check "T1: JSON shape" '[ "$RC" -eq 0 ] && oj "o.team===\"myrepo\" && o.transport===\"herdr\" && o.streams.length===2 && (s=>s.name===\"s1\" && s.state===\"open\" && s.label===\"◐ s1\" && s.tab.live===true && s.branch===\"s1\" && s.base===\"main\" && s.worktree.exists===true && s.peers.length===1 && s.peers[0].name===\"myrepo-architect\" && s.peers[0].role===\"architect\" && s.peers[0].status===\"working\" && s.peers[0].in_stream_tab===true && typeof s.opened===\"string\")(o.streams[0])"'
check "T2: only the open exchange is listed; waiting_on names its to_name" 'oj "(s=>s.exchanges.length===1 && s.exchanges[0].to_name===\"myrepo-architect\" && typeof s.exchanges[0].age_sec===\"number\" && s.waiting_on.length===1 && s.waiting_on[0].on===\"myrepo-architect\" && s.waiting_on[0].request===s.exchanges[0].id)(o.streams[0])"'
check "T2b: a non-stream member is not a stream peer" 'oj "o.streams[1].peers.length===0 && o.streams[1].worktree===null"'
check "T3: team file bytes unchanged" '[ "$(cat "$TEAM_FILE")" = "$BEFORE" ]'
check "T6: renders only when the label differs (◐ s1 renamed, · s2 already current)" '[ "$(hcount "\"tab\",\"rename\"")" -eq 1 ] && grep -q "\"tab\",\"rename\",\"$(stream_tab s1)\",\"◐ s1\"" "$STATE/herdr.log"'
clear_logs
run stream-status
check "T6b: a second status renames nothing" '[ "$(hcount "\"tab\",\"rename\"")" -eq 0 ]'
run stream-status s2
check "T5: name filter" 'oj "o.streams.length===1 && o.streams[0].name===\"s2\""'
run stream-status nope
check "T5b: unknown name refused" '[ "$RC" -eq 2 ] && oj "o.refused===\"unknown-stream\""'
run stream-done s2
run stream-status
check "T1b: open streams first, then done" 'oj "o.streams.map(s=>s.name).join()===\"s1,s2\" && o.streams[1].state===\"done\" && typeof o.streams[1].closed===\"string\""'
run stream-status --plain
check "status --plain: one line per stream" '[ "$RC" -eq 0 ] && [ "$(printf "%s\n" "$OUT" | wc -l | tr -d " ")" -eq 2 ] && printf "%s" "$OUT" | head -1 | grep -q "◐ s1" && printf "%s" "$OUT" | head -1 | grep -q "1 peers (1 working)" && printf "%s" "$OUT" | head -1 | grep -q "waiting: myrepo-architect"'
fresh
TRANSPORT=tmux run stream-open nt --no-worktree
clear_logs
TRANSPORT=tmux run stream-status
check "T4: non-herdr: unknown status, no label/tab, no herdr call" '[ "$RC" -eq 0 ] && [ ! -s "$STATE/herdr.log" ] && oj "o.streams[0].label===null && o.streams[0].tab===null && o.degraded===\"no-tabs\""'
fresh
run stream-status
check "status: no team -> streams [] exit 0" '[ "$RC" -eq 0 ] && oj "Array.isArray(o.streams) && o.streams.length===0"'

# ==== done ====
fresh
run stream-open x --no-worktree
run spawn-ad-hoc architect --model opus --stream x
clear_logs
run stream-done x
check "D1: renamed ✓ x, state done, no pane close, next lists dismiss" '[ "$RC" -eq 0 ] && grep -q "\"tab\",\"rename\",\"w1:t10\",\"✓ x\"" "$STATE/herdr.log" && [ "$(hcount "\"pane\",\"close\"")" -eq 0 ] && tj "t.streams.x.state===\"done\" && typeof t.streams.x.closed===\"string\"" && oj "o.done===true && o.already_done===false && o.label===\"✓ x\" && o.members.join()===\"myrepo-architect\" && o.next.length===1 && o.next[0].includes(\"dismiss myrepo-architect\")"'
CLOSED=$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).streams.x.closed)' "$TEAM_FILE")
run stream-done x
check "D2: idempotent: already_done, closed kept" '[ "$RC" -eq 0 ] && oj "o.already_done===true && o.label===\"✓ x\"" && tj "t.streams.x.closed===\"$CLOSED\""'
run stream-open y --no-worktree
node -e 'const fs=require("fs"),f=process.argv[1];const s=JSON.parse(fs.readFileSync(f,"utf8"));delete s.tabs[process.argv[2]];fs.writeFileSync(f,JSON.stringify(s))' "$STATE/herdr.json" "$(stream_tab y)"
run stream-done y
check "D3: tab gone: warning, still done" '[ "$RC" -eq 0 ] && oj "Array.isArray(o.warnings) && o.warnings.length>0" && tj "t.streams.y.state===\"done\""'
run stream-open w --no-worktree
BEFORE=$(cat "$TEAM_FILE"); clear_logs
run stream-done w --dry-run
check "stream-done --dry-run: writes nothing, renames nothing" '[ "$RC" -eq 0 ] && [ "$(cat "$TEAM_FILE")" = "$BEFORE" ] && [ "$(hcount "\"tab\",\"rename\"")" -eq 0 ]'
run stream-done nope
check "stream-done: unknown stream refused" '[ "$RC" -eq 2 ] && oj "o.refused===\"unknown-stream\""'
fresh
TRANSPORT=terminal run stream-open nt --no-worktree
clear_logs
TRANSPORT=terminal run stream-done nt
check "D4: non-herdr: record only" '[ "$RC" -eq 0 ] && [ ! -s "$STATE/herdr.log" ] && tj "t.streams.nt.state===\"done\"" && oj "o.label===null"'

# ==== preservation (R-S1): every rewrite path keeps `streams` and a member's `stream` ====
preserved() { tj "t.streams && t.streams.x && t.streams.x.state===\"open\" && (t.members.find(m=>m.name===\"myrepo-architect\")||{}).stream===\"x\""; }
fresh; setup_roster
run stream-open x --no-worktree
run spawn-ad-hoc architect --model opus --stream x
run spawn-ad-hoc implementor --model opus
run spawn-ad-hoc ultra-advisor --model opus
check "P1: seeded" 'preserved'
run resync
check "P1: resync preserves streams and member stream" '[ "$RC" -eq 0 ] && preserved'
run move myrepo-implementor --new-tab
check "P1: move preserves streams and member stream" '[ "$RC" -eq 0 ] && preserved'
run dismiss myrepo-ultra-advisor
TOK=$(printf '%s' "$OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).close_token||"")}catch{console.log("")}})')
run dismiss myrepo-ultra-advisor --close --confirm --plan-token "$TOK"
check "P1: dismiss --close (another member) preserves streams and member stream" '[ "$RC" -eq 0 ] && preserved && tj "!t.members.some(m=>m.name===\"myrepo-ultra-advisor\")"'
run spawn-one reviewer
check "P1: spawn-one (another member) preserves streams and member stream" '[ "$RC" -eq 0 ] && preserved'
run untrack myrepo-implementor --commit
check "P1: untrack preserves streams and member stream" '[ "$RC" -eq 0 ] && preserved && tj "!t.members.some(m=>m.name===\"myrepo-implementor\")"'
node -e 'const fs=require("fs"),f=process.argv[1];const t=JSON.parse(fs.readFileSync(f,"utf8"));t.orchestrator.pid=999999;fs.writeFileSync(f,JSON.stringify(t,null,2))' "$TEAM_FILE"
run adopt --orchestrator-pid $$ --team myrepo
check "P1: adopt preserves streams and member stream" '[ "$RC" -eq 0 ] && preserved && tj "t.orchestrator.pid===$$"'
run dismiss myrepo-architect
TOK=$(printf '%s' "$OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{console.log(JSON.parse(s).close_token||"")}catch{console.log("")}})')
run dismiss myrepo-architect --close --confirm --plan-token "$TOK"
check "dismiss of a stream member removes its row, the stream stays" '[ "$RC" -eq 0 ] && tj "t.streams.x.state===\"open\" && !t.members.some(m=>m.name===\"myrepo-architect\")"'

# ==== hook: hooks/stream-label.mjs ====
hook() { # <payload json> [env...]: runs the hook as a stream member's session would
  local payload=$1; shift
  HOUT=$(printf '%s' "$payload" | env -u HERDR_ENV HOME="$FAKEHOME" PATH="$SANDBOX/bin:$NODE_DIR" FAKE_STATE_DIR="$STATE" HERDR_ENV=1 "$@" node "$H/stream-label.mjs" 2>"$STATE/hook-err"); HRC=$?
}
fresh
run stream-open x --no-worktree
run spawn-ad-hoc architect --model opus --stream x
run spawn-ad-hoc reviewer --model opus
HA=$(member_pane myrepo-architect); HB=$(member_pane myrepo-reviewer)
UPS='{"hook_event_name":"UserPromptSubmit","session_id":"s","prompt":"hi"}'
STOP='{"hook_event_name":"Stop","session_id":"s"}'
NOTE='{"hook_event_name":"Notification","session_id":"s","message":"Claude needs your permission","notification_type":"permission_prompt"}'
clear_logs
hook "$UPS" AH_TEAM_FILE="$TEAM_FILE"
check "H1: no HERDR_PANE_ID -> exit 0, nothing run" '[ "$HRC" -eq 0 ] && [ -z "$HOUT" ] && [ ! -s "$STATE/herdr.log" ]'
hook "$UPS" HERDR_PANE_ID="$HA"
check "H1: no AH_TEAM_FILE -> exit 0, nothing run" '[ "$HRC" -eq 0 ] && [ -z "$HOUT" ] && [ ! -s "$STATE/herdr.log" ]'
hook "$UPS" HERDR_PANE_ID="$HB" AH_TEAM_FILE="$TEAM_FILE"
check "H2: member not in a stream -> no call" '[ "$HRC" -eq 0 ] && [ -z "$HOUT" ] && [ ! -s "$STATE/herdr.log" ]'
hook "$UPS" HERDR_PANE_ID="$HA" AH_TEAM_FILE="$TEAM_FILE"
check "H3: UserPromptSubmit -> ◐ x" '[ "$HRC" -eq 0 ] && [ -z "$HOUT" ] && [ "$(tab_label w1:t10)" = "◐ x" ]'
hook "$STOP" HERDR_PANE_ID="$HA" AH_TEAM_FILE="$TEAM_FILE"
check "H3: Stop -> ○ x" '[ "$HRC" -eq 0 ] && [ "$(tab_label w1:t10)" = "○ x" ]'
hook "$NOTE" HERDR_PANE_ID="$HA" AH_TEAM_FILE="$TEAM_FILE"
check "H3: Notification(permission_prompt) -> × x" '[ "$HRC" -eq 0 ] && [ "$(tab_label w1:t10)" = "× x" ]'
clear_logs
hook '{"hook_event_name":"Stop","session_id":"s","agent_id":"a1","agent_type":"task-gopher:task-gopher"}' HERDR_PANE_ID="$HA" AH_TEAM_FILE="$TEAM_FILE"
check "H4: subagent payload -> no call" '[ "$HRC" -eq 0 ] && [ -z "$HOUT" ] && [ ! -s "$STATE/herdr.log" ]'
run stream-done x
clear_logs
hook "$UPS" HERDR_PANE_ID="$HA" AH_TEAM_FILE="$TEAM_FILE"
check "H2: done stream -> no call" '[ "$HRC" -eq 0 ] && [ ! -s "$STATE/herdr.log" ] && [ "$(tab_label w1:t10)" = "✓ x" ]'
printf '{not json' > "$SANDBOX/corrupt.json"
hook "$UPS" HERDR_PANE_ID="$HA" AH_TEAM_FILE="$SANDBOX/corrupt.json"
check "H5: corrupt team file -> exit 0, stdout empty" '[ "$HRC" -eq 0 ] && [ -z "$HOUT" ]'
check "H6: hooks.json registers the hook on UserPromptSubmit, Stop and Notification(permission_prompt)" 'node -e "
  const h=require(process.argv[1]).hooks;
  const has=(ev,m)=>(h[ev]||[]).some(e=>(m===undefined||e.matcher===m)&&e.hooks.some(k=>k.command.includes(\"hooks/stream-label.mjs\")));
  process.exit(has(\"UserPromptSubmit\")&&has(\"Stop\")&&has(\"Notification\",\"permission_prompt\")?0:1)" "$H/hooks.json"'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
