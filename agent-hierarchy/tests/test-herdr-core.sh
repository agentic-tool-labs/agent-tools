#!/bin/bash
# agent-hierarchy — herdr desktop (herdr core) support, P3 of agent-hierarchy-v2 docs/specs/herdr-desktop.md.
# The flavour detection table (§6), the translator from each TUI call to `hc` / `herdr-app` (§3, §5) against a
# stateful fake of both binaries shaped from their source, the TUI identity (under HERDR_ENV=1 the translator
# runs `herdr` with the same argv and nothing else), the split rule's positions:false / size_known:false
# branch, and a core spawn-one in both spawn paths.
# Usage: bash tests/test-herdr-core.sh   (exits 0 iff all cases pass)

. "$(dirname "$0")/lib-hermetic.sh"
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
NODE_DIR="$(dirname "$(command -v node)")"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-herdr-core-test.XXXXXX")"
export AH_TEST_FAKE_BIN="$SANDBOX/bin"
hermetic_on_exit 'rm -rf "$SANDBOX"'
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
unset CLAUDE_PID HC_TERMINAL_ID HC_TERMINAL_SOCKET HC_SESSION HC_SOCKET
mkdir -p "$SANDBOX/bin" "$SANDBOX/home/.claude"
STATE="$SANDBOX/state.json"
LOG="$SANDBOX/calls.log"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (OUT=${OUT:0:400})"; fi
}

# ---- the fake: one node script behind `hc`, `herdr-app` and `herdr`, one state file, one call log ----
cat > "$SANDBOX/fake.cjs" <<'EOF'
const fs = require("fs");
const [bin, ...args] = process.argv.slice(2);
const S = JSON.parse(fs.readFileSync(process.env.FAKE_STATE, "utf8"));
fs.appendFileSync(process.env.FAKE_LOG, `${bin} ${JSON.stringify(args)}\n`);
const save = () => fs.writeFileSync(process.env.FAKE_STATE, JSON.stringify(S));
const out = (v) => { save(); console.log(JSON.stringify(v)); process.exit(0); };
const hcFail = (kind, code) => { save(); console.error(JSON.stringify({ error: { kind, message: kind, hint: "" } })); process.exit(code); };
const flag = (f) => (args.indexOf(f) >= 0 ? args[args.indexOf(f) + 1] : undefined);
const term = (a) => S.terminals[a];
const shown = () => S.world.spaces.flatMap((s) => s.tabs.flatMap((t) => t.terminals.map((x) => ({ ...x, tab: t, space: s }))));
let next = Object.keys(S.terminals).length + 10;
const newTerminal = (labels = {}) => { const a = `t${next++}`; S.terminals[a] = { address: a, state: "live", labels, cwd: "/w", cols: 80, rows: 24, status: null, screen: "" }; return a; };
const adopt = (a) => {
  const l = term(a).labels;
  if (S.noAdopt || !l["herdr.space"] || !l["herdr.tab"]) return;
  let sp = S.world.spaces.find((s) => s.id === l["herdr.space"]);
  if (!sp) S.world.spaces.push((sp = { id: l["herdr.space"], tabs: [] }));
  let tb = sp.tabs.find((t) => t.id === l["herdr.tab"]);
  if (!tb) sp.tabs.push((tb = { id: l["herdr.tab"], name: String(sp.tabs.length + 1), terminals: [] }));
  tb.terminals.push({ terminal: a, pane: `p-${a}` });
};
if (bin === "herdr") out({ result: { from: "herdr", argv: args } });
if (bin === "hc") {
  const [verb, t] = args;
  const json = args.includes("--json");
  if (!json) hcFail("usage", 2);
  if (verb === "ls") {
    const want = flag("--label");
    const rows = Object.values(S.terminals).filter((x) => (S.lsShowsFinished || x.state === "live") && (!want || x.labels[want.split("=")[0]] === want.split("=").slice(1).join("=")));
    out({ terminals: rows.map((x) => ({ address: x.address, state: x.state, ...(x.status && x.status.state ? { status: x.status.state } : {}) })) });
  }
  if (!term(t) && verb !== "run") hcFail("not_found", 3);
  if (verb === "get") out(term(t));
  if (verb === "send") {
    if (term(t).status && term(t).status.state === "blocked" && !args.includes("--force")) hcFail("blocked", 9);
    if (S.afterSend) term(t).status = S.afterSend;
    out({ turn: 1, started: true });
  }
  if (verb === "keys" || verb === "wait") out({});
  if (verb === "read") out({ text: term(t).screen, complete: true });
  if (verb === "kill") { term(t).state = "finished"; out(term(t)); }
  if (verb === "label") {
    for (const kv of args.slice(2).filter((x) => x.includes("="))) { const [k, ...v] = kv.split("="); term(t).labels[k] = v.join("="); }
    adopt(t);
    out(term(t));
  }
  if (verb === "run") {
    const labels = {};
    for (let i = 0; i < args.length; i++) if (args[i] === "--label") { const [k, ...v] = args[i + 1].split("="); labels[k] = v.join("="); }
    const a = newTerminal(labels);
    out({ address: a, state: "live" });
  }
}
if (bin === "herdr-app") {
  if (S.noApp) { console.error("herdr-app: no Herdr window"); process.exit(2); }
  const [verb, action, raw] = args;
  if (verb === "status") out(S.status);
  if (verb === "ls") out(S.world);
  const p = raw ? JSON.parse(raw) : {};
  if (action === "pane.split") {
    const at = shown().find((x) => x.pane === p.pane);
    const a = newTerminal({ "herdr.space": at.space.id, "herdr.tab": at.tab.id });
    at.tab.terminals.push({ terminal: a, pane: `p-${a}` });
    S.status.focused_pane = `p-${a}`;
    out({ pane: `p-${a}`, terminal: a });
  }
  if (action === "pane.focus") { S.status.focused_pane = p.pane; out({}); }
  if (action === "terminal.park") {
    for (const s of S.world.spaces) for (const tb of s.tabs) tb.terminals = tb.terminals.filter((x) => x.terminal !== p.terminal);
    if (!S.parkNeverLands) { term(p.terminal).labels["herdr.space"] = ""; term(p.terminal).labels["herdr.tab"] = ""; }
    out({ pending: true });
  }
  if (action === "terminal.keep") out({ pending: true });
  if (action === "tab.new") {
    const sp = S.world.spaces.find((s) => s.id === p.space) || S.world.spaces[0];
    const a = newTerminal({ "herdr.space": sp.id, "herdr.tab": "tbnew" });
    sp.tabs.push({ id: "tbnew", name: p.name, terminals: [{ terminal: a, pane: `p-${a}` }] });
    S.status.space = sp.id; S.status.tab = "tbnew";
    out({ space: sp.id, tab: "tbnew", terminal: a });
  }
  if (action === "space.select") { S.status.space = p.id; out({}); }
  if (action === "tab.select") { S.status.tab = p.id; out({}); }
  if (action === "tab.rename") out({});
  save(); console.log(JSON.stringify({ error: `unknown ${action}` })); process.exit(1);
}
EOF
for b in hc herdr-app herdr; do printf '#!/bin/sh\nexec node "%s" %s "$@"\n' "$SANDBOX/fake.cjs" "$b" > "$SANDBOX/bin/$b"; chmod +x "$SANDBOX/bin/$b"; done

# The world: space sp1, tab tb1 holding the caller t1 (p1) and a member terminal t2 (p2); t3 is 200x120.
reset() {
  : > "$LOG"
  cat > "$STATE" <<'EOF'
{"terminals":{
 "t1":{"address":"t1","state":"live","labels":{"herdr.space":"sp1","herdr.tab":"tb1"},"cwd":"/w","cols":160,"rows":40,"status":{"app":"claude-code","state":"idle"},"screen":"me"},
 "t2":{"address":"t2","state":"live","labels":{"herdr.space":"sp1","herdr.tab":"tb1","ah.name":"a1"},"cwd":"/w","cols":80,"rows":40,"status":{"app":"claude-code","state":"idle"},"screen":"composer"},
 "t3":{"address":"t3","state":"live","labels":{"herdr.space":"sp1","herdr.tab":"tb2","ah.name":"a3"},"cwd":"/w","cols":200,"rows":120,"status":null,"screen":""}},
 "world":{"spaces":[{"id":"sp1","tabs":[{"id":"tb1","name":"1","terminals":[{"terminal":"t1","pane":"p1"},{"terminal":"t2","pane":"p2"}]},{"id":"tb2","name":"2","terminals":[{"terminal":"t3","pane":"p3"}]}]}]},
 "status":{"space":"sp1","tab":"tb1","focused_pane":"p1","zoom":1}}
EOF
}
patch() { node -e 'const fs=require("fs"),f=process.argv[1];const s=JSON.parse(fs.readFileSync(f,"utf8"));(new Function("S",process.argv[2]))(s);fs.writeFileSync(f,JSON.stringify(s))' "$STATE" "$1"; }

CORE_ENV="HOME=$SANDBOX/home PATH=$SANDBOX/bin:$NODE_DIR FAKE_STATE=$STATE FAKE_LOG=$LOG HC_TERMINAL_ID=t1 AH_HC_POLL_MS=20"
TUI_ENV="HOME=$SANDBOX/home PATH=$SANDBOX/bin:$NODE_DIR FAKE_STATE=$STATE FAKE_LOG=$LOG HERDR_ENV=1 HERDR_PANE_ID=w1:p1"
# translate <env> <argv json>: prints stdout, or `ERR <stdout of the failure>`, through the real lib-herdr.
translate() {
  OUT=$(env -i $1 node --input-type=module -e '
    import { herdrExec } from "'"$H"'/lib-herdr.mjs";
    try { process.stdout.write(herdrExec(JSON.parse(process.argv[1]), { encoding: "utf8" })); }
    catch (e) { process.stdout.write("ERR " + (e.stdout || e.message)); }' "$2" 2>&1)
}
calls() { cat "$LOG"; }
has() { grep -qF -- "$1" "$LOG"; }
none() { ! grep -q "^$1 " "$LOG"; }

# ---- §6 detection table ----
flav() { env -i PATH="$NODE_DIR" "$@" node --input-type=module -e 'import { herdrFlavourFromEnv } from "'"$H"'/lib-herdr.mjs"; console.log(String(herdrFlavourFromEnv()))'; }
check "detect: HERDR_ENV=1 with HC_TERMINAL_ID set is tui" '[ "$(flav HERDR_ENV=1 HC_TERMINAL_ID=t1)" = tui ]'
check "detect: HERDR_ENV=0 with HC_TERMINAL_ID set is core" '[ "$(flav HERDR_ENV=0 HC_TERMINAL_ID=t1)" = core ]'
check "detect: HERDR_ENV empty with HC_TERMINAL_ID set is core" '[ "$(flav HERDR_ENV= HC_TERMINAL_ID=t1)" = core ]'
check "detect (negative): HC_TERMINAL_ID empty is not herdr" '[ "$(flav HC_TERMINAL_ID=)" = null ]'
check "detect (negative): neither set is not herdr" '[ "$(flav)" = null ]'

# ---- tui identity: the same argv to `herdr`, and nothing else ----
reset; translate "$TUI_ENV" '["agent","get","a1"]'
check "tui: agent get runs herdr with the argv unchanged" 'echo "$OUT" | grep -qF "\"argv\":[\"agent\",\"get\",\"a1\"]" && [ "$(wc -l < "$LOG")" -eq 1 ] && has "herdr [\"agent\",\"get\",\"a1\"]"'
reset; translate "$TUI_ENV" '["pane","close","w1:p2"]'
check "tui (negative): pane close never reaches hc" 'none hc && has "herdr [\"pane\",\"close\",\"w1:p2\"]"'

# ---- §3.1 / §3.3 identity and status ----
reset; translate "$CORE_ENV" '["agent","get","a1"]'
check "core: agent get finds the ah.name label and maps idle + claude-code" 'echo "$OUT" | node -e "const a=JSON.parse(require(\"fs\").readFileSync(0,\"utf8\")).result.agent;process.exit(a.pane_id===\"t2\"&&a.agent_status===\"idle\"&&a.agent_type===\"claude\"?0:1)" && has "hc [\"ls\",\"--label\",\"ah.name=a1\",\"--json\"]" && none herdr'
reset; translate "$CORE_ENV" '["agent","get","a3"]'
check "core: a live terminal that reported no status is unknown, with no agent type" 'echo "$OUT" | grep -q "\"agent_status\":\"unknown\"" && ! echo "$OUT" | grep -q "\"agent_type\":\"[a-z]"'
reset; patch 'S.terminals.t2.status={app:"codex",state:"error"}'; translate "$CORE_ENV" '["agent","get","a1"]'
check "core: status error passes through; another app passes through" 'echo "$OUT" | grep -q "\"agent_status\":\"error\"" && echo "$OUT" | grep -q "\"agent_type\":\"codex\""'
reset; translate "$CORE_ENV" '["agent","get","nobody"]'
check "core: no ah.name match is agent_not_found" 'echo "$OUT" | grep -q "^ERR .*\"code\":\"agent_not_found\""'
reset; patch 'S.terminals.t3.labels["ah.name"]="a1"'; translate "$CORE_ENV" '["agent","get","a1"]'
check "core: two ah.name matches pick neither (agent_name_ambiguous)" 'echo "$OUT" | grep -q "\"code\":\"agent_name_ambiguous\"" && ! has "hc [\"get\""'
reset; patch 'S.terminals.t2.state="finished";S.lsShowsFinished=true'; translate "$CORE_ENV" '["agent","get","a1"]'
check "core: a finished terminal is agent_not_found, never its last status" 'echo "$OUT" | grep -q "\"code\":\"agent_not_found\"" && ! echo "$OUT" | grep -q idle'
reset; translate "$CORE_ENV" '["agent","list"]'
check "core: agent list rows carry name, address, tab, space and the mapped status" 'echo "$OUT" | node -e "const r=JSON.parse(require(\"fs\").readFileSync(0,\"utf8\")).result.agents;const a=r.find(x=>x.name===\"a1\");process.exit(r.length===3&&a.pane_id===\"t2\"&&a.tab_id===\"tb1\"&&a.workspace_id===\"sp1\"&&a.agent_status===\"idle\"?0:1)"'

# ---- §5 rows ----
reset; translate "$CORE_ENV" '["agent","prompt","a1","do it","--wait","--timeout","5000"]'
check "core: agent prompt is hc send with --wait and the timeout in seconds" 'has "hc [\"send\",\"t2\",\"do it\",\"--wait\",\"--timeout\",\"5\",\"--json\"]" && echo "$OUT" | grep -q "\"agent_status\":\"idle\""'
reset; patch 'S.afterSend={app:"claude-code",state:"working"}'; translate "$CORE_ENV" '["agent","prompt","a1","x","--wait","--timeout","1000"]'
check "core: a prompt whose wait ends still working is a timeout" 'echo "$OUT" | grep -q "\"code\":\"timeout\""'
reset; patch 'S.terminals.t2.status={app:"claude-code",state:"blocked"}'; translate "$CORE_ENV" '["agent","prompt","a1","x"]'
check "core: a blocked member refuses the prompt, and it is never forced" 'echo "$OUT" | grep -q "\"code\":\"blocked\"" && ! grep -q -- "--force" "$LOG"'
reset; translate "$CORE_ENV" '["agent","send-keys","a1","Enter"]'
check "core: send-keys maps Enter to enter" 'has "hc [\"keys\",\"t2\",\"enter\",\"--json\"]"'
reset; translate "$CORE_ENV" '["agent","send-keys","a1","C-c"]'
check "core: send-keys maps C-c to ctrl+c" 'has "hc [\"keys\",\"t2\",\"ctrl+c\",\"--json\"]"'
reset; translate "$CORE_ENV" '["agent","send-keys","a1","F13"]'
check "core (negative): an unmapped key fails and presses nothing" 'echo "$OUT" | grep -q "\"code\":\"unsupported\"" && ! has "hc [\"keys\""'
reset; translate "$CORE_ENV" '["agent","read","a1","--source","visible"]'
check "core: a visible read is hc read --lines 0, plain text out" '[ "$OUT" = composer ] && has "hc [\"read\",\"t2\",\"--lines\",\"0\",\"--json\"]"'
reset; translate "$CORE_ENV" '["pane","read","t2","--source","recent-unwrapped","--lines","40"]'
check "core: a history read is hc read --lines N" 'has "hc [\"read\",\"t2\",\"--lines\",\"40\",\"--json\"]"'
reset; translate "$CORE_ENV" '["pane","close","t2"]'
check "core: pane close is hc kill, with no app call" 'has "hc [\"kill\",\"t2\",\"--json\"]" && none herdr-app'
reset; translate "$CORE_ENV" '["pane","rename","t2","claude","-","a1"]'
check "core: pane rename succeeds and runs nothing" '[ "$OUT" = "{\"result\":{}}" ] && [ ! -s "$LOG" ]'
reset; translate "$CORE_ENV" '["pane","zoom","t2","--on"]'
check "core (negative): a verb with no core mapping is one named error, nothing run" 'echo "$OUT" | grep -q "\"code\":\"unsupported\"" && [ ! -s "$LOG" ]'
reset; translate "$CORE_ENV" '["pane","layout","--current"]'
check "core: pane layout lists the caller tab with positions:false and cols x rows" 'echo "$OUT" | node -e "const l=JSON.parse(require(\"fs\").readFileSync(0,\"utf8\")).result.layout;process.exit(l.positions===false&&l.tab_id===\"tb1\"&&l.panes.length===2&&l.panes[0].rect.width===160&&l.panes[0].rect.height===40&&l.focused_pane_id===\"t1\"?0:1)"'
reset; translate "$CORE_ENV" '["pane","layout","--pane","t3"]'
check "core: a 200x120 pane reports size_known:false" 'echo "$OUT" | grep -q "\"size_known\":false"'
reset; translate "$CORE_ENV" '["pane","layout","--current"]'
check "core (negative): a real-size pane carries no size_known" '! echo "$OUT" | grep -q size_known'
reset; translate "$CORE_ENV" '["pane","split","--pane","t1","--direction","right","--cwd","/other","--no-focus"]'
check "core: pane split is pane.split on the target app pane, a cd for another cwd, focus given back" 'echo "$OUT" | grep -q "\"pane_id\":\"t1[0-9]\"" && has "herdr-app [\"do\",\"pane.split\",\"{\\\"pane\\\":\\\"p1\\\",\\\"direction\\\":\\\"right\\\"}\"]" && grep -q "\"cd '"'"'/other'"'"'\"" "$LOG" && has "herdr-app [\"do\",\"pane.focus\",\"{\\\"pane\\\":\\\"p1\\\"}\"]"'
reset; translate "$CORE_ENV" '["pane","split","--pane","t1","--direction","down","--cwd","/w"]'
check "core (negative): a split in the target cwd sends no cd and keeps the new focus" '! grep -q "\"cd " "$LOG" && ! has "pane.focus"'
reset; translate "$CORE_ENV" '["tab","create","--label","s1","--cwd","/w","--no-focus"]'
check "core: tab create is tab.new in the caller space, then the old space and tab selected again" 'echo "$OUT" | grep -q "\"tab_id\":\"tbnew\"" && echo "$OUT" | grep -q "\"root_pane\":{\"pane_id\":\"t" && has "\"space.select\",\"{\\\"id\\\":\\\"sp1\\\"}\"" && has "\"tab.select\",\"{\\\"id\\\":\\\"tb1\\\"}\""'
reset; translate "$CORE_ENV" '["tab","list"]'
check "core: tab list maps the app tabs" 'echo "$OUT" | grep -q "{\"tab_id\":\"tb1\",\"label\":\"1\",\"workspace_id\":\"sp1\"}"'
reset; patch 'S.noApp=true'; translate "$CORE_ENV" '["tab","create","--label","s1","--cwd","/w"]'
check "core: tab create with no app window is a named refusal" 'echo "$OUT" | grep -q "\"code\":\"unsupported\"" && ! has "tab.new"'

# ---- §3.2 spawn through the translator ----
reset; translate "$CORE_ENV" '["agent","start","a9","--pane","t2","--","env PATH=/x claude --agent ah:x"]'
check "core: agent start into a pane types the line, then labels ah.name" 'has "hc [\"send\",\"t2\",\"env PATH=/x claude --agent ah:x\",\"--json\"]" && has "hc [\"label\",\"t2\",\"ah.name=a9\",\"--json\"]" && [ "$(grep -n "\"send\"" "$LOG" | cut -d: -f1)" -lt "$(grep -n "\"label\"" "$LOG" | cut -d: -f1)" ]'
reset; translate "$CORE_ENV" '["agent","start","a9","--cwd","/w","--","claude"]'
check "core: agent start with no pane is a hidden hc run with no parent, labelled ah.name" 'has "hc [\"run\",\"--bg\",\"--no-parent\",\"--label\",\"ah.name=a9\",\"--cwd\",\"/w\",\"--\",\"claude\",\"--json\"]" && echo "$OUT" | grep -q "\"pane_id\":\"t1[0-9]\""'

# ---- §5.2 move ----
reset; translate "$CORE_ENV" '["pane","move","t2","--tab","tb2","--split","down"]'
check "core: move --tab parks, waits for the blank label, relabels into the tab, changed:true" 'echo "$OUT" | grep -q "\"changed\":\"true\"" && has "\"terminal.park\"" && has "hc [\"label\",\"t2\",\"herdr.space=sp1\",\"herdr.tab=tb2\",\"--json\"]" && ! has "terminal.keep"'
check "core: move relabels only after a read that saw the park land" '[ "$(grep -n "terminal.park" "$LOG" | cut -d: -f1)" -lt "$(grep -n "hc \[\"get\",\"t2\"" "$LOG" | tail -1 | cut -d: -f1)" ] && [ "$(grep -n "hc \[\"get\",\"t2\"" "$LOG" | tail -1 | cut -d: -f1)" -lt "$(grep -n "hc \[\"label\"" "$LOG" | cut -d: -f1)" ]'
reset; patch 'S.parkNeverLands=true'; OUT0=$(AH_HC_ADOPT_WAIT_MS=200 true); translate "$CORE_ENV AH_HC_ADOPT_WAIT_MS=200" '["pane","move","t2","--new-tab"]'
check "core (negative): a park that never lands is never relabelled; keep shows it again, changed:false" 'echo "$OUT" | grep -q "\"changed\":\"false\"" && ! has "hc [\"label\"" && has "\"terminal.keep\""'
reset; patch 'S.noAdopt=true'; translate "$CORE_ENV AH_HC_ADOPT_WAIT_MS=200" '["pane","move","t2","--new-tab"]'
check "core: an adoption past the deadline calls terminal.keep and reports changed:false" 'echo "$OUT" | grep -q "\"changed\":\"false\"" && has "\"terminal.keep\""'
reset; translate "$CORE_ENV" '["pane","move","t2","--new-workspace"]'
check "core: move ids are minted in the app format (sp/tb + 32 hex)" 'grep -qE "herdr.space=sp[0-9a-f]{32}\",\"herdr.tab=tb[0-9a-f]{32}\"" "$LOG" && echo "$OUT" | grep -q "\"changed\":\"true\""'

# ---- hc missing under core: the exec failure, never herdr ----
reset; OUT=$(env -i HOME="$SANDBOX/home" PATH="$NODE_DIR" FAKE_STATE="$STATE" FAKE_LOG="$LOG" HC_TERMINAL_ID=t1 node --input-type=module -e '
  import { herdrExec } from "'"$H"'/lib-herdr.mjs";
  import { herdrOnPath } from "'"$H"'/lib-roster.mjs";
  let threw = false; try { herdrExec(["agent","get","a1"], {}); } catch { threw = true; }
  console.log(`${herdrOnPath()} ${threw}`)' 2>&1)
check "core: with no hc on PATH herdrOnPath is false and a call fails without running herdr" '[ "$OUT" = "false true" ] && [ ! -s "$LOG" ]'

# ---- §5.1 the split rule through roster.mjs layout-splits --next ----
PROJ="$SANDBOX/proj"; mkdir -p "$PROJ/.claude"; (cd "$PROJ" && git init -q)
next_split() { OUT=$(env -i $CORE_ENV node "$H/roster.mjs" layout-splits --next --mode grid --pane-count "$1" --self t1 --created "$2" --cwd "$PROJ" 2>&1); }
reset; patch 'S.world.spaces[0].tabs[0].terminals.push({terminal:"t4",pane:"p4"});S.terminals.t4={address:"t4",state:"live",labels:{},cwd:"/w",cols:60,rows:40,status:null}'
next_split 3 '["t2","t4"]'
check "split rule: positions:false takes the aspect rule on the largest pane (160x40, wide: right)" 'echo "$OUT" | grep -q "\"target\": \"t1\"" && echo "$OUT" | grep -q "\"direction\": \"right\""'
reset; patch 'S.terminals.t1.cols=60;S.terminals.t1.rows=40'; next_split 3 '["t2"]'
check "split rule: a tall largest pane under positions:false splits down" 'echo "$OUT" | grep -q "\"target\": \"t2\"" && echo "$OUT" | grep -q "\"direction\": \"down\""'
reset; patch 'S.terminals.t2.cols=200;S.terminals.t2.rows=120;S.terminals.t1.cols=60;S.terminals.t1.rows=40'; next_split 3 '["t2"]'
check "split rule: a 200x120 candidate makes the decision right, into the largest known pane" 'echo "$OUT" | grep -q "\"target\": \"t1\"" && echo "$OUT" | grep -q "\"direction\": \"right\""'
OUT=$(env -i HOME="$SANDBOX/home" PATH="$NODE_DIR" node "$H/roster.mjs" next-split --mode grid --pane-count 3 --self p0 --created '["p1"]' --geometry '[{"pane_id":"p0","rect":{"width":200,"height":120,"x":0,"y":0},"size_known":false},{"pane_id":"p1","rect":{"width":60,"height":40,"x":200,"y":0}}]' 2>&1)
check "split rule (negative): with positions absent, size_known is ignored and the TUI rule stands" 'echo "$OUT" | grep -q "\"target\": \"p0\""'

# ---- a core spawn-one, both spawn paths ----
setup_roster() {
  rm -rf "$PROJ/.claude/hierarchy"
  env -i HOME="$SANDBOX/home" PATH="$NODE_DIR" node "$H/roster.mjs" init --level repo --route peer --cwd "$PROJ" >/dev/null
  env -i HOME="$SANDBOX/home" PATH="$NODE_DIR" node "$H/roster.mjs" add --no-spawn --level repo --role reviewer --model opus --cwd "$PROJ" >/dev/null
}
TEAM_FILE="$PROJ/.claude/hierarchy/teams/proj.json"
reset; setup_roster
OUT=$(env -i $CORE_ENV CLAUDE_PID=$$ node "$H/roster.mjs" spawn-one reviewer --cwd "$PROJ" 2>&1)
check "spawn-one under core with the app: split, launch line typed with the spawner PATH, address stored" 'grep -q "pane.split" "$LOG" && grep -qF "\"send\",\"t1" "$LOG" && grep -F "\"send\"" "$LOG" | grep -qF "env PATH='"'"'$SANDBOX/bin:$NODE_DIR'"'"' claude --agent" && node -e "const t=JSON.parse(require(\"fs\").readFileSync(process.argv[1],\"utf8\"));process.exit(/^t[0-9]+$/.test(t.members[0].transport_id)&&t.transport===\"herdr\"&&!(\"herdr_flavour\" in t)?0:1)" "$TEAM_FILE"'
reset; setup_roster; patch 'S.noApp=true'
OUT=$(env -i $CORE_ENV CLAUDE_PID=$$ node "$H/roster.mjs" spawn-one reviewer --cwd "$PROJ" 2>&1)
check "spawn-one under core with no app: one hidden hc run labelled ah.name, its address stored" 'grep -qF "hc [\"run\",\"--bg\",\"--no-parent\",\"--label\",\"ah.name=" "$LOG" && ! grep -q "pane.split" "$LOG" && node -e "const t=JSON.parse(require(\"fs\").readFileSync(process.argv[1],\"utf8\"));process.exit(/^t[0-9]+$/.test(t.members[0].transport_id)?0:1)" "$TEAM_FILE"'
reset; setup_roster
OUT=$(env -i $TUI_ENV CLAUDE_PID=$$ node "$H/roster.mjs" spawn-one reviewer --dry-run --cwd "$PROJ" 2>&1)
check "spawn-one under tui (negative): the launch line is herdr agent start, with no PATH prefix" 'echo "$OUT" | grep -q "herdr agent start" && ! echo "$OUT" | grep -q "env PATH="'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
