#!/bin/bash
# agent-hierarchy — a peer idle while its OWN background subagents run is not a
# peer that finished without reporting. subagent-inflight.mjs records the
# session's in-flight subagents (SubagentStart/SubagentStop); stop-peer-nudge.mjs
# allows silently, spending no nudge, while any is in flight.
# SubagentStart/Stop payloads start from tests/fixtures/subagentstop-payload.json.
# HOME- and AGENT_HIERARCHY_DIR-redirected; real state untouched.
# Usage: bash tests/test-subagent-inflight.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
unset AH_TEAM_FILE  # every session roster.mjs launches carries one; a test must not inherit it
unset CLAUDE_PID  # every Claude session exports one; a test must not inherit it
H="$PLUGIN/hooks"
STOP="$H/stop-peer-nudge.mjs"
INFLIGHT="$H/subagent-inflight.mjs"
MSG="$H/msg.mjs"
FIXTURE="$PLUGIN/tests/fixtures/subagentstop-payload.json"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-inflight-test.XXXXXX")"
trap 'chmod -R u+w "$SANDBOX" 2>/dev/null; rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
HD="$SANDBOX/hier"
PROJ="$SANDBOX/proj"
STATE_FILE="$FAKEHOME/.claude/agent-hierarchy.peer-pending.jsonl"
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:400})"; fi
}

echo '{ "version": 1, "enabled": true, "roles": {} }' > "$PROJ/.claude/agent-hierarchy.json"

msg() { OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$MSG" --cwd "$PROJ" "$@" 2>&1); RC=$?; }
field() { node -e 'process.stdout.write(String(JSON.parse(process.argv[1])[process.argv[2]]))' "$OUT" "$1"; }

blocked() { echo "$OUT" | grep -q '"decision":"block"'; }
allowed() { [ $RC -eq 0 ] && [ -z "$OUT" ]; }

seed() { echo "$1" >> "$STATE_FILE"; }
lines() { [ -f "$STATE_FILE" ] && wc -l < "$STATE_FILE" | tr -d ' ' || echo 0; }
iso_ago() { node -e 'process.stdout.write(new Date(Date.now()-Number(process.argv[1])*60000).toISOString())' "$1"; }

stop_run() { # <session_id> [stop_hook_active]
  OUT=$(node -e 'const[s,a]=process.argv.slice(1);process.stdout.write(JSON.stringify({session_id:s,stop_hook_active:a==="true"}))' "$1" "${2:-false}" \
    | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$STOP" 2>&1); RC=$?
}

# Fixture-shaped SubagentStart/SubagentStop payload: <event> <session_id|-> <agent_id|->
sub_payload() {
  node -e '
    const fs=require("fs");
    const [fixture,ev,sid,aid]=process.argv.slice(1);
    const o=JSON.parse(fs.readFileSync(fixture,"utf8"));
    o.hook_event_name=ev; o.agent_type="task-gopher:task-gopher";
    if (sid==="-") delete o.session_id; else o.session_id=sid;
    if (aid==="-") delete o.agent_id; else o.agent_id=aid;
    if (ev==="SubagentStart") { delete o.last_assistant_message; delete o.stop_hook_active; delete o.agent_transcript_path; }
    process.stdout.write(JSON.stringify(o));
  ' "$FIXTURE" "$1" "$2" "$3"
}
inflight() { OUT=$(sub_payload "$1" "$2" "$3" | HOME="${HOME_OVERRIDE:-$FAKEHOME}" AGENT_HIERARCHY_DIR="$HD" node "$INFLIGHT" 2>&1); RC=$?; }

# Latest record of one type for a session (obligation when type is "-"), or "null".
latest() { # <session_id> <type|->
  node -e '
    const fs=require("fs");
    const [sid,type,path]=process.argv.slice(1);
    let last=null;
    if (fs.existsSync(path)) for (const l of fs.readFileSync(path,"utf8").split("\n")) {
      if(!l.trim())continue;
      let r; try{r=JSON.parse(l);}catch{continue;}
      if(!r||r.session_id!==sid)continue;
      if(type==="-"?(r.type==="turn"||r.type==="dispatch"||r.type==="subagent"):r.type!==type)continue;
      last=r;
    }
    process.stdout.write(JSON.stringify(last));
  ' "$1" "$2" "$STATE_FILE"
}
count_sub() { # <session_id> <agent_id> <status>
  [ -f "$STATE_FILE" ] || { echo 0; return; }
  grep -c "\"type\":\"subagent\",\"session_id\":\"$1\",\"agent_id\":\"$2\",\"status\":\"$3\"" "$STATE_FILE"
}

msg new --to architect --from orchestrator --slug inflight-task
REQ=$(field path)
NOW=$(iso_ago 0)

obligation() { # <session_id> [nudges]
  seed "{\"session_id\":\"$1\",\"from\":\"ct-orchestrator\",\"from_name\":\"ct-orchestrator\",\"reply_to\":\"ct-orchestrator\",\"task\":\"inflight-task\",\"msg\":\"$REQ\",\"armed_by\":\"msg-token\",\"ts\":\"$NOW\",\"status\":\"pending\",\"nudges\":${2:-0}}"
}
marker() { seed "{\"type\":\"turn\",\"session_id\":\"$1\",\"status\":\"$2\",\"ts\":\"$NOW\"}"; }
subrec() { # <session_id> <agent_id> <status> [ts]
  seed "{\"type\":\"subagent\",\"session_id\":\"$1\",\"agent_id\":\"$2\",\"status\":\"$3\",\"ts\":\"${4:-$NOW}\"}"
}

# ==== §7.1 stop-peer-nudge.mjs ====

# 1: armed turn, subagent in flight -> silent, free, marker untouched
obligation "s1"; marker "s1" "armed"; subrec "s1" "a1" "started"
L0=$(lines)
ok=1
for i in 1 2 3; do stop_run "s1"; allowed || ok=0; done
check "7.1.1: in flight, armed -> 3 silent allows" '[ $ok -eq 1 ]'
stop_run "s1" true
check "7.1.1: in flight, armed, stop_hook_active -> silent allow" 'allowed'
check "7.1.1: no record appended (no nudge, no waive)" '[ "$(lines)" = "$L0" ]'
check "7.1.1: marker still armed" 'latest "s1" turn | grep -q "\"status\":\"armed\""'

# 2: unarmed turn, subagent in flight -> silent allow, nothing appended
obligation "s2"; marker "s2" "disarmed"; subrec "s2" "a1" "started"
L0=$(lines)
stop_run "s2"
check "7.1.2: in flight, unarmed -> silent allow" 'allowed'
check "7.1.2: nothing appended" '[ "$(lines)" = "$L0" ]'

# 3: subagent stopped -> today's behaviour: nudge 1, nudge 2 (last reminder), waive
obligation "s3"; marker "s3" "armed"; subrec "s3" "a1" "started"; subrec "s3" "a1" "stopped"
stop_run "s3"
check "7.1.3: stopped subagent -> block" 'blocked'
check "7.1.3: nudges 1" 'latest "s3" - | grep -q "\"nudges\":1"'
stop_run "s3"
check "7.1.3: second -> block with the last reminder" 'blocked && echo "$OUT" | grep -q "Last reminder"'
check "7.1.3: nudges 2" 'latest "s3" - | grep -q "\"nudges\":2"'
stop_run "s3"
check "7.1.3: third -> allow" 'allowed'
check "7.1.3: obligation waived" 'latest "s3" - | grep -q "\"status\":\"waived\""'

# 4: TTL — a started record older than the TTL no longer exempts
obligation "s4"; marker "s4" "armed"; subrec "s4" "a1" "started" "$(iso_ago 61)"
stop_run "s4"
check "7.1.4: started 61 min ago, no stopped -> block" 'blocked'

# 4b: unparseable ts fails toward enforcement
obligation "s4b"; marker "s4b" "armed"; subrec "s4b" "a1" "started" "not-a-date"
stop_run "s4b"
check "7.1.4: unparseable ts -> block" 'blocked'

# 5: budget intact after a wait
obligation "s5"; marker "s5" "armed"; subrec "s5" "a1" "started"
for i in 1 2 3; do stop_run "s5"; done
subrec "s5" "a1" "stopped"
stop_run "s5"
check "7.1.5: first block after the wait -> nudges 1" 'blocked && latest "s5" - | grep -q "\"nudges\":1"'
check "7.1.5: ... and no last reminder" '! echo "$OUT" | grep -q "Last reminder"'

# 6: another session's subagent does not exempt this one
obligation "s6"; marker "s6" "armed"; subrec "t6" "a1" "started"
stop_run "s6"
check "7.1.6: other session's in-flight subagent -> block" 'blocked'

# 7: obligation readers ignore subagent records
OUT=$(HOME="$FAKEHOME" node --input-type=module -e "
  const P = await import('$H/lib-peer.mjs');
  const before = P.pendingFor('s7').length;
  P.appendPeerRecord({ session_id: 's7', from: 'x', task: 't', status: 'pending', ts: new Date().toISOString() });
  const one = P.pendingFor('s7').length;
  P.appendPeerRecord({ type: 'subagent', session_id: 's7', agent_id: 'a1', status: 'started', ts: new Date().toISOString() });
  P.appendPeerRecord({ type: 'subagent', session_id: 's7', agent_id: 'a2', status: 'stopped', ts: new Date().toISOString() });
  const after = P.pendingFor('s7').length;
  const lbk = P.latestByKey([
    { session_id: 's7', from: 'x', task: 't', status: 'pending' },
    { type: 'subagent', session_id: 's7', agent_id: 'a1', status: 'started' },
  ]).length;
  process.stdout.write([before, one, after, lbk].join(' '));
" 2>&1); RC=$?
check "7.1.7: pendingFor unchanged by subagent records; latestByKey skips them" '[ "$OUT" = "0 1 1 1" ]'

# ==== §7.2 subagent-inflight.mjs ====

obligation "r1"
L0=$(lines)
inflight SubagentStart "r1" "a1"
check "7.2.1: SubagentStart with an obligation -> exit 0, silent" 'allowed'
check "7.2.1: exactly one started record" '[ "$(count_sub r1 a1 started)" = "1" ] && [ "$(lines)" = "$((L0+1))" ]'

L0=$(lines)
inflight SubagentStart "r2" "a1"
check "7.2.2: SubagentStart with no obligation -> silent" 'allowed'
check "7.2.2: nothing appended" '[ "$(lines)" = "$L0" ]'

L0=$(lines)
inflight SubagentStop "r1" "a1"
check "7.2.3: SubagentStop after start -> silent" 'allowed'
check "7.2.3: exactly one stopped record" '[ "$(count_sub r1 a1 stopped)" = "1" ] && [ "$(lines)" = "$((L0+1))" ]'
L0=$(lines)
inflight SubagentStop "r1" "a9"
check "7.2.3: SubagentStop for an unknown agent -> nothing appended" 'allowed && [ "$(lines)" = "$L0" ]'
L0=$(lines)
inflight SubagentStop "r1" "a1"
check "7.2.3: second SubagentStop for a1 -> nothing appended" 'allowed && [ "$(lines)" = "$L0" ]'

obligation "r4"
L0=$(lines)
inflight SubagentStart "r4" "-"
check "7.2.4: missing agent_id -> exit 0, silent" 'allowed'
inflight SubagentStart "-" "a1"
check "7.2.4: missing session_id -> exit 0, silent" 'allowed'
check "7.2.4: nothing appended" '[ "$(lines)" = "$L0" ]'

touch "$SANDBOX/not-a-dir"
HOME_OVERRIDE="$SANDBOX/not-a-dir" inflight SubagentStart "r1" "a1"
check "7.2.5: HOME is a file -> exit 0, silent" 'allowed'
HOME_OVERRIDE="$SANDBOX/not-a-dir" inflight SubagentStop "r1" "a1"
check "7.2.5: HOME is a file (stop) -> exit 0, silent" 'allowed'
ROHOME="$SANDBOX/rohome"; mkdir -p "$ROHOME/.claude"
cp "$STATE_FILE" "$ROHOME/.claude/agent-hierarchy.peer-pending.jsonl"
chmod 444 "$ROHOME/.claude/agent-hierarchy.peer-pending.jsonl"
HOME_OVERRIDE="$ROHOME" inflight SubagentStart "r1" "a2"
check "7.2.5: unwritable store -> exit 0, silent" 'allowed'

check "7.2.6: hooks.json registers subagent-inflight.mjs on SubagentStart and SubagentStop" 'node -e "
  const h=JSON.parse(require(\"fs\").readFileSync(process.argv[1],\"utf8\")).hooks;
  const has=(ev)=>(h[ev]||[]).some(g=>(g.hooks||[]).some(c=>String(c.command).includes(\"hooks/subagent-inflight.mjs\")));
  process.exit(has(\"SubagentStart\")&&has(\"SubagentStop\")?0:1);
" "$H/hooks.json"'

# End to end: the recording hook feeds the Stop hook.
obligation "e1"; marker "e1" "armed"
inflight SubagentStart "e1" "g1"
stop_run "e1"
check "e2e: recorded start -> Stop allows silently" 'allowed'
inflight SubagentStop "e1" "g1"
stop_run "e1"
check "e2e: recorded stop -> Stop blocks" 'blocked'

# ==== §7.1 8: the TTL window is symmetric around now ====

iso_ahead() { node -e 'process.stdout.write(new Date(Date.now()+Number(process.argv[1])*60000).toISOString())' "$1"; }
obligation "s8"; marker "s8" "armed"; subrec "s8" "a1" "started" "$(iso_ahead 61)"
stop_run "s8"
check "7.1.8: started 61 min in the future -> block" 'blocked'
obligation "s8b"; marker "s8b" "armed"; subrec "s8b" "a1" "started" "$(iso_ahead 5)"
L0=$(lines)
stop_run "s8b"
check "7.1.8: started 5 min in the future -> silent allow, nothing appended" 'allowed && [ "$(lines)" = "$L0" ]'

# ==== §7.2 8-14: TaskStop fires no SubagentStop, so PostToolUse(TaskStop) closes the record ====

# <session_id|-> <tool_input json> <tool_response json> [tool_name]
taskstop_payload() {
  node -e '
    const [sid,ti,tr,tool]=process.argv.slice(1);
    const o={hook_event_name:"PostToolUse",tool_name:tool||"TaskStop",tool_input:JSON.parse(ti),tool_response:JSON.parse(tr)};
    if (sid!=="-") o.session_id=sid;
    process.stdout.write(JSON.stringify(o));
  ' "$1" "$2" "$3" "$4"
}
taskstop_raw() { OUT=$(taskstop_payload "$@" | HOME="${HOME_OVERRIDE:-$FAKEHOME}" AGENT_HIERARCHY_DIR="$HD" node "$INFLIGHT" 2>&1); RC=$?; }
# The live shape (E3): both ids are the agent_id, task_type "local_agent". "-" sends no ids.
taskstop() { # <session_id|-> <task_id|-> [tool_name]
  if [ "$2" = "-" ]; then taskstop_raw "$1" '{}' '{}' "$3"
  else taskstop_raw "$1" "{\"task_id\":\"$2\"}" "{\"task_id\":\"$2\",\"task_type\":\"local_agent\"}" "$3"; fi
}
status_of() { # <session_id> <agent_id> -> latest subagent status, or "none"
  node -e '
  const fs=require("fs"); const [sid,aid,path]=process.argv.slice(1); let s="none";
  for (const l of fs.readFileSync(path,"utf8").split("\n")) { try { const r=JSON.parse(l); if (r.type==="subagent"&&r.session_id===sid&&r.agent_id===aid) s=r.status; } catch {} }
  process.stdout.write(s);
' "$1" "$2" "$STATE_FILE"; }

obligation "k8"; marker "k8" "armed"; subrec "k8" "a1" "started"
L0=$(lines)
taskstop "k8" "a1"
check "7.2.8: TaskStop for an in-flight agent -> exit 0, silent" 'allowed'
check "7.2.8: exactly one stopped record" '[ "$(count_sub k8 a1 stopped)" = "1" ] && [ "$(lines)" = "$((L0+1))" ]'
stop_run "k8"
check "7.2.8: Stop after the kill -> block with nudges 1" 'blocked && latest "k8" - | grep -q "\"nudges\":1"'

obligation "k9"; marker "k9" "armed"; subrec "k9" "a1" "started"; subrec "k9" "a2" "started"
taskstop "k9" "a1"
check "7.2.9: only the stopped agent is closed" '[ "$(count_sub k9 a1 stopped)" = "1" ] && [ "$(count_sub k9 a2 stopped)" = "0" ]'
L0=$(lines)
stop_run "k9"
check "7.2.9: a live helper keeps the stop exempt -> silent allow, nothing appended" 'allowed && [ "$(lines)" = "$L0" ]'

obligation "k10"; marker "k10" "armed"; subrec "k10" "a1" "started"
taskstop "k10" "a1"
stop_run "k10"
check "7.2.10: after the kill, first Stop -> nudges 1" 'blocked && latest "k10" - | grep -q "\"nudges\":1"'
stop_run "k10"
check "7.2.10: second Stop -> nudges 2 with the last reminder" 'blocked && echo "$OUT" | grep -q "Last reminder" && latest "k10" - | grep -q "\"nudges\":2"'
stop_run "k10"
check "7.2.10: third Stop -> waived" 'allowed && latest "k10" - | grep -q "\"status\":\"waived\""'

obligation "k11"; subrec "k11" "a1" "started"
L0=$(lines)
taskstop_raw "k11" '{"task_id":"b9"}' '{"task_id":"b9","task_type":"local_bash"}'
check "7.2.11: background-Bash stop -> nothing appended" 'allowed && [ "$(lines)" = "$L0" ]'
check "7.2.11: ... and a1 stays started" '[ "$(status_of k11 a1)" = "started" ]'

# a2 is live so a wrongly applied F1 would be visible.
obligation "k11b"; subrec "k11b" "a1" "started"; subrec "k11b" "a2" "started"
inflight SubagentStop "k11b" "a1"
L0=$(lines)
taskstop "k11b" "a1"
check "7.2.11: TaskStop for a known, already-stopped agent -> nothing appended" 'allowed && [ "$(lines)" = "$L0" ]'
check "7.2.11: ... and no F1 (a2 stays started)" '[ "$(status_of k11b a2)" = "started" ]'

obligation "k12"; subrec "k12" "a1" "started"
L0=$(lines)
taskstop "k12" "-"
check "7.2.12: missing task_id -> exit 0, silent" 'allowed'
taskstop "-" "a1"
check "7.2.12: missing session_id -> exit 0, silent" 'allowed'
taskstop "k12" "a1" "Bash"
check "7.2.12: PostToolUse for another tool -> exit 0, silent" 'allowed'
check "7.2.12: nothing appended" '[ "$(lines)" = "$L0" ]'

HOME_OVERRIDE="$SANDBOX/not-a-dir" taskstop "k12" "a1"
check "7.2.13: HOME is a file -> exit 0, silent" 'allowed'

# Read-only store holding a live `started`, so SubagentStop and TaskStop reach
# the append and it throws.
subrec "ro" "a1" "started"
RO_STORE="$ROHOME/.claude/agent-hierarchy.peer-pending.jsonl"
chmod u+w "$RO_STORE"; cp "$STATE_FILE" "$RO_STORE"; chmod 444 "$RO_STORE"
RO_ERRLOG="$ROHOME/.claude/hierarchy/hook-errors.jsonl"
errs() { if [ -f "$RO_ERRLOG" ]; then grep -c '"hook":"subagent-inflight.mjs"' "$RO_ERRLOG"; else echo 0; fi; }
E0=$(errs)
HOME_OVERRIDE="$ROHOME" inflight SubagentStop "ro" "a1"
check "7.2.5: unwritable store, SubagentStop -> exit 0, silent" 'allowed'
check "7.2.5: ... the append threw and was logged" '[ "$(errs)" = "$((E0+1))" ]'
HOME_OVERRIDE="$ROHOME" taskstop "ro" "a1"
check "7.2.13: unwritable store, TaskStop -> exit 0, silent" 'allowed'
check "7.2.13: ... the append threw and was logged" '[ "$(errs)" = "$((E0+2))" ]'

posttooluse_groups_ok() {
  node -e '
    const post=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).hooks.PostToolUse||[];
    const scripts=(g)=>(g.hooks||[]).map(c=>(String(c.command).match(/hooks\/([\w.-]+\.mjs)/)||[])[1]).join(",");
    const one=(m,s)=>post.filter(g=>g.matcher===m&&scripts(g)===s).length===1;
    const ok=one("TaskStop|Bash|Monitor","subagent-inflight.mjs")
      &&post.filter(g=>g.matcher==="TaskStop|Bash|Monitor").length===1
      &&one("SendMessage","posttooluse-peer-resolve.mjs")
      &&one("ListAgents|SendMessage","posttooluse-roster.mjs");
    process.exit(ok?0:1);
  ' "$H/hooks.json"
}
check "7.2.14: hooks.json has a PostToolUse TaskStop|Bash|Monitor group running subagent-inflight.mjs; pre-existing groups intact" 'posttooluse_groups_ok'

# ==== §7.2 15-19: name-addressed and unmatched TaskStops ====

obligation "k15"; marker "k15" "armed"; subrec "k15" "a1" "started"; subrec "k15" "a2" "started"
taskstop_raw "k15" '{"task_id":"helper-x"}' '{"task_id":"a1","task_type":"local_agent"}'
check "7.2.15: stopped by name, response resolves the id -> only a1 stopped" '[ "$(status_of k15 a1)" = "stopped" ] && [ "$(status_of k15 a2)" = "started" ]'
L0=$(lines)
stop_run "k15"
check "7.2.15: ... a2 still in flight -> silent allow, nothing appended" 'allowed && [ "$(lines)" = "$L0" ]'

obligation "k16"; marker "k16" "armed"; subrec "k16" "a1" "started"; subrec "k16" "a2" "started"
taskstop_raw "k16" '{"task_id":"helper-x"}' '{"task_type":"local_agent"}'
check "7.2.16: stopped by name, unresolved agent stop -> F1 closes both" '[ "$(status_of k16 a1)" = "stopped" ] && [ "$(status_of k16 a2)" = "stopped" ]'
stop_run "k16"
check "7.2.16: ... Stop blocks with nudges 1" 'blocked && latest "k16" - | grep -q "\"nudges\":1"'

obligation "k17"; subrec "k17" "a1" "started"
taskstop_raw "k17" '{"task_id":"zz"}' '{}'
check "7.2.17: unmatched id, empty response -> F1 closes a1" '[ "$(status_of k17 a1)" = "stopped" ]'
obligation "k17b"; subrec "k17b" "a1" "started"
L0=$(lines)
taskstop_raw "k17b" '{"task_id":"zz"}' '{"task_id":"zz"}'
check "7.2.17: resolved id with no record -> no F1, nothing appended" 'allowed && [ "$(lines)" = "$L0" ] && [ "$(status_of k17b a1)" = "started" ]'

# An agent spawned before the obligation has no record; killing it must not
# close the recorded sibling.
obligation "k20"; marker "k20" "armed"; subrec "k20" "a1" "started"
L0=$(lines)
taskstop "k20" "apre0000000000000"
check "7.2.20: pre-obligation agent stopped -> nothing appended, sibling stays started" 'allowed && [ "$(lines)" = "$L0" ] && [ "$(status_of k20 a1)" = "started" ]'
stop_run "k20"
check "7.2.20: ... sibling still in flight -> silent allow" 'allowed && [ "$(lines)" = "$L0" ]'

# ==== background Bash and Monitor tasks count as in-flight work ====

# <session_id> <tool_name> <tool_input json> <tool_response json> [agent_id]
post_run() {
  OUT=$(node -e '
    const [sid,tool,ti,tr,aid]=process.argv.slice(1);
    const o={hook_event_name:"PostToolUse",session_id:sid,tool_name:tool,tool_input:JSON.parse(ti),tool_response:JSON.parse(tr)};
    if (aid) { o.agent_id=aid; o.agent_type="task-gopher:task-gopher"; }
    process.stdout.write(JSON.stringify(o));
  ' "$@" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$INFLIGHT" 2>&1); RC=$?
}
bash_resp() { echo "{\"stdout\":\"\",\"stderr\":\"\",\"interrupted\":false,\"isImage\":false,\"noOutputExpected\":false,\"backgroundTaskId\":\"$1\"}"; }
bg_bash() { # <session_id> <task_id> [agent_id]
  post_run "$1" Bash '{"command":"sleep 3; echo done","run_in_background":true}' "$(bash_resp "$2")" "${3:-}"
}
monitor() { # <session_id> <task_id>
  post_run "$1" Monitor '{"command":"for i in 1 2; do echo tick $i; sleep 2; done","description":"ticks"}' "{\"taskId\":\"$2\",\"timeoutMs\":300000,\"persistent\":false}"
}
ups() { # <session_id> <prompt>
  OUT=$(node -e 'const[s,p]=process.argv.slice(1);process.stdout.write(JSON.stringify({hook_event_name:"UserPromptSubmit",session_id:s,cwd:"/tmp",prompt:p}))' "$1" "$2" \
    | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$INFLIGHT" 2>&1); RC=$?
}
# Notification blocks as a live session's UserPromptSubmit `prompt` carries them, ids substituted.
bash_note() { # <task_id> <status> <summary tail>
  printf '<task-notification>\n<task-id>%s</task-id>\n<tool-use-id>toolu_01YcAqAMr5SbdXdfK1HcxtQK</tool-use-id>\n<output-file>/private/tmp/claude-501/p/s/tasks/%s.output</output-file>\n<status>%s</status>\n<summary>Background command "Sleep 3s then print done" %s</summary>\n</task-notification>' "$1" "$1" "$2" "$3"
}
monitor_event() { # <task_id> <event text>
  printf '<task-notification>\n<task-id>%s</task-id>\n<summary>Monitor event: "two ticks probe"</summary>\n<event>%s</event>\nIf this event is something the user would act on now, send a PushNotification. Routine or benign output doesn'"'"'t need one.\n</task-notification>' "$1" "$2"
}
monitor_end() { # <task_id>
  printf '<task-notification>\n<task-id>%s</task-id>\n<tool-use-id>toolu_01SbrFsKtnUUiQe4XLRts7jP</tool-use-id>\n<output-file>/private/tmp/claude-501/p/s/tasks/%s.output</output-file>\n<status>completed</status>\n<summary>Monitor "two ticks probe" stream ended</summary>\n</task-notification>' "$1" "$1"
}
agent_note() { # <agent_id>
  printf '<task-notification>\n<task-id>%s</task-id>\n<tool-use-id>toolu_01A</tool-use-id>\n<output-file>/tmp/tasks/%s.output</output-file>\n<status>completed</status>\n<summary>Agent "helper" finished</summary>\n</task-notification>' "$1" "$1"
}

obligation "b1"; marker "b1" "armed"
bg_bash "b1" "bX1"
check "B1: background Bash under an obligation -> started" 'allowed && [ "$(status_of b1 bX1)" = "started" ]'
L0=$(lines)
stop_run "b1"
check "B1: armed Stop -> silent allow, no nudge, nothing appended" 'allowed && [ "$(lines)" = "$L0" ]'
check "B1: marker still armed" 'latest "b1" turn | grep -q "\"status\":\"armed\""'

obligation "b2"; marker "b2" "armed"
post_run "b2" Bash '{"command":"sleep 3; echo done"}' "$(bash_resp bX1)"
post_run "b2" Bash '{"command":"sleep 3; echo done","run_in_background":false}' "$(bash_resp bX1)"
check "B2: foreground Bash -> no record" '[ "$(status_of b2 bX1)" = "none" ]'
stop_run "b2"
check "B2: ... armed Stop blocks" 'blocked'

obligation "b3"; marker "b3" "armed"
bg_bash "b3" "bX1" "agent-sub-1"
check "B3: a subagent's background Bash -> no record" '[ "$(status_of b3 bX1)" = "none" ]'
stop_run "b3"
check "B3: ... armed Stop blocks" 'blocked'

L0=$(lines)
bg_bash "b4" "bX1"
check "B4: no pending obligation -> nothing appended" 'allowed && [ "$(lines)" = "$L0" ]'

for st in completed:"completed (exit code 0)" failed:"failed with exit code 1" killed:"was stopped"; do
  s="b5${st%%:*}"
  obligation "$s"; marker "$s" "armed"; bg_bash "$s" "bX1"
  ups "$s" "$(bash_note bX1 "${st%%:*}" "${st#*:}")"
  check "B5: ${st%%:*} notification -> stopped appended" 'allowed && [ "$(status_of $s bX1)" = "stopped" ]'
  stop_run "$s"
  check "B5: ... next armed Stop blocks" 'blocked'
done

obligation "b6"; marker "b6" "armed"; bg_bash "b6" "bX1"
ups "b6" "$(bash_note bOther completed "completed (exit code 0)")"
check "B6: another id's notification -> bX1 still started" '[ "$(status_of b6 bX1)" = "started" ]'
stop_run "b6"
check "B6: ... Stop silent" 'allowed'

obligation "b7"; marker "b7" "armed"; bg_bash "b7" "bX1"
taskstop_raw "b7" '{"task_id":"bX1"}' '{"message":"Successfully stopped task: bX1 (sleep 120)","task_id":"bX1","task_type":"local_bash"}'
check "B7: TaskStop on a recorded background Bash -> stopped" '[ "$(status_of b7 bX1)" = "stopped" ]'
stop_run "b7"
check "B7: ... armed Stop blocks" 'blocked'

obligation "m1"; marker "m1" "armed"; monitor "m1" "bM1"
check "M1: Monitor under an obligation -> started" 'allowed && [ "$(status_of m1 bM1)" = "started" ]'
stop_run "m1"
check "M1: ... Stop silent" 'allowed'

obligation "m2"; marker "m2" "armed"; monitor "m2" "bM1"
ups "m2" "$(monitor_event bM1 "tick 1")"
check "M2: mid-stream event -> still started" '[ "$(status_of m2 bM1)" = "started" ]'
stop_run "m2"
check "M2: ... Stop silent" 'allowed'

obligation "m3"; marker "m3" "armed"; monitor "m3" "bM1"
ups "m3" "$(monitor_end bM1)"
check "M3: stream ended, completed -> stopped" '[ "$(status_of m3 bM1)" = "stopped" ]'
stop_run "m3"
check "M3: ... armed Stop blocks" 'blocked'

obligation "m4"; marker "m4" "armed"; monitor "m4" "bM1"
ups "m4" "$(monitor_event bM1 "[Monitor timed out — re-arm if needed.]")"
check "M4: Monitor timeout event -> stopped" '[ "$(status_of m4 bM1)" = "stopped" ]'
stop_run "m4"
check "M4: ... armed Stop blocks" 'blocked'

# A Monitor that times out with no output: the live block, id substituted.
obligation "m5"; marker "m5" "armed"; monitor "m5" "bM5"
ups "m5" "$(printf '<task-notification>\n<task-id>bM5</task-id>\n<summary>Monitor event: "sleep 30 timeout probe"</summary>\n<event>[Monitor expired after 2s with no events delivered. Re-arm it if you still need the watch — and widen the filter if silence was unexpected.]</event>\n</task-notification>')"
check "M5: Monitor expired event -> stopped" '[ "$(status_of m5 bM5)" = "stopped" ]'
stop_run "m5"
check "M5: ... armed Stop blocks" 'blocked'

obligation "sn1"; marker "sn1" "armed"
inflight SubagentStart "sn1" "aS1"
ups "sn1" "$(agent_note aS1)"
check "S1: a subagent's completion notification closes it" '[ "$(status_of sn1 aS1)" = "stopped" ]'
stop_run "sn1"
check "S1: ... armed Stop blocks" 'blocked'

obligation "u1"; bg_bash "u1" "bX1"
SUM0=$(cksum < "$STATE_FILE")
ups "u1" "Please carry on with the task."
check "U1: a prompt with no notification -> store byte-identical" 'allowed && [ "$(cksum < "$STATE_FILE")" = "$SUM0" ]'

obligation "u2"; bg_bash "u2" "bX1"; monitor "u2" "bM1"
ups "u2" "$(bash_note bX1 completed "completed (exit code 0)")
$(monitor_event bM1 "tick 1")"
check "U2: two blocks -> only the completed one closes" '[ "$(status_of u2 bX1)" = "stopped" ] && [ "$(status_of u2 bM1)" = "started" ]'

check "R1: hooks.json runs subagent-inflight.mjs on UserPromptSubmit" 'node -e "
  const h=JSON.parse(require(\"fs\").readFileSync(process.argv[1],\"utf8\")).hooks;
  process.exit((h.UserPromptSubmit||[]).some(g=>(g.hooks||[]).some(c=>String(c.command).includes(\"hooks/subagent-inflight.mjs\")))?0:1);
" "$H/hooks.json"'

obligation "k18"; subrec "k18" "a1" "started"; subrec "k18" "a2" "started"
L0=$(lines)
taskstop_raw "k18" '{"task_id":"a2"}' '{"task_id":"a1","task_type":"local_agent"}'
check "7.2.18: both candidates known and started -> exactly two stopped records" '[ "$(lines)" = "$((L0+2))" ] && [ "$(status_of k18 a1)" = "stopped" ] && [ "$(status_of k18 a2)" = "stopped" ]'

obligation "k19"; subrec "k19" "a1" "stopped"
L0=$(lines)
taskstop_raw "k19" '{"task_id":"zz"}' '{"task_id":"zz","task_type":"local_agent"}'
check "7.2.19: nothing in flight -> unmatched agent stop appends nothing" 'allowed && [ "$(lines)" = "$L0" ]'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
