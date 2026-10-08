#!/bin/bash
# agent-hierarchy — the self-care shell gate (hooks/pretooluse-self-care-gate.mjs): which roles it
# covers, which commands it lets through, everything it refuses, and that it never approves anything.
# The hook is driven with crafted PreToolUse payloads; no ah CLI command is ever executed.
# HOME-redirected, throwaway repo; the real config and pool are never touched.
# Usage: bash tests/test-self-care-gate.sh   (exits 0 iff all cases pass)

. "$(dirname "$0")/lib-hermetic.sh"
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="${HOOK:-$PLUGIN/hooks/pretooluse-self-care-gate.mjs}"
R="$PLUGIN/hooks/roster.mjs"; MG="$PLUGIN/hooks/msg.mjs"
unset AH_TEAM_FILE CLAUDE_PID AGENT_HIERARCHY_DIR
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/ah-self-care-test.XXXXXX")"
[ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] || { echo "mktemp failed"; exit 1; }
hermetic_on_exit 'rm -rf "$SANDBOX"'
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"; PROJ="$SANDBOX/proj"; WT="$SANDBOX/wt"
HIER="$PROJ/.claude/hierarchy"; MSGS="$HIER/msgs"
mkdir -p "$FAKEHOME/.claude" "$MSGS" "$SANDBOX/outside"
git -C "$PROJ" init -q
git -C "$PROJ" -c user.email=t@example.test -c user.name=t commit -q --allow-empty -m init
git -C "$PROJ" worktree add -q "$WT" -b wt-branch 2>/dev/null
PASS=0; FAIL=0
check() { local n=$1; shift; if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $n"; else FAIL=$((FAIL+1)); echo "FAIL: $n (RC=$RC OUT=${OUT:0:240})"; fi; }

cat > "$PROJ/.claude/agent-hierarchy.json" <<'EOF'
{"version":1,"roles":{"carer":{"class":"review","shell":"self-care"},"plain":{"class":"review"},"odd":{"class":"review","shell":"yes"}}}
EOF
printf -- '---\nid: x\n---\n' > "$MSGS/x--request.md"
printf -- '---\nid: y\n---\n' > "$SANDBOX/outside/y--request.md"
printf -- '---\nid: z\n---\n' > "$SANDBOX/outside/notreq.md"
ln -s "$MSGS/x--request.md" "$MSGS/link--request.md"
ln -s "$SANDBOX/outside/y--request.md" "$MSGS/outlink--request.md"
mkdir -p "$SANDBOX/outside/msgs-alias"; ln -s "$MSGS/x--request.md" "$SANDBOX/outside/in--request.md"
printf -- '---\nid: w\n---\n' > "$WT/../proj/.claude/hierarchy/msgs/w--request.md"

# gate <session id> <agent_type or -> <agent_id or -> <command> [cwd]: runs the hook; OUT, RC.
gate() {
  local payload
  payload=$(node -e 'const [sid, at, aid, cmd, cwd] = process.argv.slice(1); const o = { session_id: sid, cwd, hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: { command: cmd } }; if (at !== "-") o.agent_type = at; if (aid !== "-") o.agent_id = aid; process.stdout.write(JSON.stringify(o))' "$1" "$2" "$3" "$4" "${5:-$PROJ}")
  OUT=$(printf '%s' "$payload" | HOME="$FAKEHOME" node "$HOOK" 2>&1); RC=$?
}
silent() { [ "$RC" = 0 ] && [ -z "$OUT" ]; }
denied() { [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q '"permissionDecision":"deny"'; }
ARCH() { gate s1 ah:architect - "$1" "${2:-$PROJ}"; }
seed_role() { HOME="$FAKEHOME" node --input-type=module -e "import { writeSessionRole } from '$PLUGIN/hooks/lib-session-role.mjs'; writeSessionRole(process.argv[1], process.argv[2]);" "$1" "$2"; }
row() { printf '%s\n' "$1" >> "$HIER/peers.jsonl"; }

# ---------------------------------------------------------------- ALLOW
ARCH "node $R checkin --cwd $PROJ"
check "A1: checkin allowed (agent_type in the payload)" 'silent'
seed_role sP architect
gate sP - - "node $R checkin --cwd $PROJ"
check "A1: checkin allowed (persisted role, no agent_type)" 'silent'
row '{"type":"peer","status":"up","role":"architect","session_id":"s1","pid":1,"team":"t1","ts":"2026-01-01T00:00:00.000Z"}'
row '{"type":"peer","status":"down","role":"architect","session_id":"s1","pid":1,"ts":"2026-01-01T00:00:01.000Z"}'
ARCH "node $R checkin --team t1 --cwd $PROJ"
check "A2: checkin --team of the latest teamed row, the latest row being a teamless down" 'silent'
ARCH "node $R whoami"; check "A3: whoami" 'silent'
ARCH "node $R whoami --team t1"; check "A3: whoami --team" 'silent'
ARCH "node $R status --cwd $PROJ"; check "A3: status --cwd" 'silent'
ARCH "node $MG new --type response --id x --to orchestrator --from architect --req $WT/../proj/.claude/hierarchy/msgs/w--request.md --cwd $WT" "$WT"
check "A4: msg new from a worktree cwd answering a request in the main checkout's msgs" 'silent'
ARCH "node $MG new --type response --id x --to orchestrator --from architect --req $MSGS/x--request.md --cwd $PROJ"
check "A4: msg new in the main checkout" 'silent'
ARCH "node $MG list --cwd $PROJ"; check "A5: msg list" 'silent'
ARCH "node $MG index --cwd $PROJ"; check "A5: msg index" 'silent'
gate s2 carer - "node $R checkin --cwd $PROJ"
check "A6: a custom role marked self-care is gated-and-allowed the same way" 'silent'
ARCH "node $MG new --type response --id x --to orchestrator --from architect --req $MSGS/../msgs/x--request.md --cwd $PROJ"
check "A7: a request path spelled with .. that resolves into msgs" 'silent'
ARCH "node $MG new --type response --id x --to orchestrator --from architect --req $MSGS/link--request.md --cwd $PROJ"
check "A7: a symlink inside msgs whose real directory is msgs" 'silent'
ARCH "node $MG new --type response --id x --to orchestrator --from architect --req $SANDBOX/outside/in--request.md --cwd $PROJ"
check "A7: a symlink outside msgs whose real file is in msgs" 'silent'

# ---------------------------------------------------------------- DENY (gated role, main thread)
for c in "ls" "npm test" "node -e 1"; do ARCH "$c"; check "D1: refuses $c" 'denied'; done
for c in "node $R status; ls" "node $R status && ls" "node $R status | cat" "node $R status > f" "node \$(echo $R) status" 'node `echo` status'; do
  ARCH "$c"; check "D2: refuses chaining/substitution: ${c:0:30}" 'denied'; done
ARCH "node $R status
ls"; check "D2: refuses a newline" 'denied'
ARCH "node $R whoami --team 'x'"; check "D3: refuses quotes" 'denied'
ARCH "node $R status --cwd ~"; check "D3: refuses ~" 'denied'
ARCH "node $R status --cwd $PROJ/*"; check "D3: refuses a glob" 'denied'
ARCH "node $MG new --type response --id x --from architect --to-name =node --req $MSGS/x--request.md"; check "D3: refuses = in a value" 'denied'
ARCH "node $R status --cwd=$PROJ"; check "D3: refuses --flag=value" 'denied'
ARCH "node $MG new --type response --id -h --from architect --req $MSGS/x--request.md"; check "D3: refuses a value starting with -" 'denied'
for p in "env" "exec" "command" "FOO"; do ARCH "$p node $R status"; check "D4: refuses prefix $p" 'denied'; done
ARCH "node ${R#/} status"; check "D5: refuses a relative CLI path" 'denied'
ARCH "node $PLUGIN/hooks/../hooks/roster.mjs status"; check "D5: refuses a .. CLI path" 'denied'
ARCH "node $R/ status"; check "D5: refuses a trailing slash" 'denied'
ARCH "node /other/plugin/hooks/roster.mjs status"; check "D5: refuses another version's path" 'denied'
for v in create spawn dismiss disband deliver role teams stream "role set"; do ARCH "node $R $v"; check "D6: refuses roster $v" 'denied'; done
for v in sweep route "decision add"; do ARCH "node $MG $v"; check "D6: refuses msg $v" 'denied'; done
ARCH "node $R checkin --orchestrator-pid 1"; check "D7: refuses --orchestrator-pid" 'denied'
ARCH "node $R checkin --team other --cwd $PROJ"; check "D8: refuses checkin --team of another team" 'denied'
gate s9 ah:architect - "node $R checkin --team t1"
check "D8: refuses checkin --team when the session has no teamed row" 'denied'
ARCH "node $MG new --type request --id x --from architect --req $MSGS/x--request.md"; check "D9: refuses --type request" 'denied'
ARCH "node $MG new --id x --from architect --req $MSGS/x--request.md"; check "D9: refuses a missing --type" 'denied'
ARCH "node $MG new --type response --id x --from reviewer --req $MSGS/x--request.md"; check "D9: refuses a foreign --from" 'denied'
ARCH "node $MG new --type response --id x --from architect --req $MSGS/x--response.md"; check "D9: refuses a --req that is not --request.md" 'denied'
ARCH "node $MG new --type response --id x --from architect --req $MSGS/missing--request.md"; check "D9: refuses a --req that does not exist" 'denied'
ARCH "node $MG new --type response --id x --from architect --req $SANDBOX/outside/y--request.md"; check "D9: refuses a --req outside the msgs dirs" 'denied'
ARCH "node $MG new --type response --id x --from architect --req $MSGS/outlink--request.md"; check "D9: refuses a symlink in msgs whose real file is outside" 'denied'
ARCH "node $MG new --type response --id x --from architect --req $MSGS/../../outside/y--request.md"; check "D9: refuses a .. spelling that resolves outside" 'denied'
ARCH "node $MG new --type response --id x --from architect"; check "D9: refuses a missing --req" 'denied'
ARCH "node $R status --cwd $PROJ --cwd $PROJ"; check "D10: refuses a repeated flag" 'denied'
ARCH "node $R status --bogus 1"; check "D10: refuses an unknown flag" 'denied'
ARCH "node $R status --cwd"; check "D10: refuses a valueless flag" 'denied'
ARCH "node $R status --cwd $SANDBOX"; check "D11: refuses a foreign --cwd" 'denied'
ARCH ""; check "D12: refuses an empty command" 'denied'
ARCH "node $R status $(printf 'a%.0s' $(seq 1 1100))"; check "D12: refuses a 1025+ character command" 'denied'
ARCH " node $R status"; check "D12: refuses leading whitespace" 'denied'
ARCH "node $R status "; check "D12: refuses trailing whitespace" 'denied'
ARCH "node $R status --now x"; check "D15: refuses status --now" 'denied'
ARCH "node $R status --plain"; check "D15: refuses status --plain" 'denied'
gate s1 ah:architect sub1 "node $R status --cwd $PROJ"; check "D13: a gated-role subagent is refused even an allowed form" 'denied'
gate s1 ah:architect sub1 "ls"; check "D13: a gated-role subagent is refused ls" 'denied'
OUT=$(printf '{"session_id":"s1","cwd":"%s","tool_name":"Bash","agent_type":"ah:architect","tool_input":null}' "$PROJ" | HOME="$FAKEHOME" node "$HOOK" 2>&1); RC=$?
check "D14: an internal error is a refusal" 'denied'

# ---------------------------------------------------------------- UNTOUCHED
for r in ah:implementor ah:reviewer ah:ultra-advisor ah:orchestrator; do gate s3 "$r" - "ls"; check "U1: $r runs anything" 'silent'; done
gate s4 - - "ls"; check "U2: no role" 'silent'
seed_role sG architect
gate sG task-gopher:task-gopher agent-9 "ls"; check "U3: an architect session's retrieval subagent runs ls" 'silent'
gate s5 plain - "ls"; check "U4: a custom role with no shell field" 'silent'
gate s6 odd - "ls"; check "U4: a custom role with another shell value" 'silent'
gate s7 carer sub2 "node $R status"; check "U5: a custom marked role's own subagent is refused (agent_id, direct role)" 'denied'
cat > "$PROJ/.claude/agent-hierarchy.json" <<'EOF'
{"version":1,"roles":{"orchestrator":{"class":"review","shell":"self-care"}}}
EOF
gate s8 ah:orchestrator - "ls"; check "U5: the orchestrator is never gated, whatever a config row says" 'silent'

# ---------------------------------------------------------------- INVARIANTS
check "I1: the hook source never writes an approving decision" '[ -f "$PLUGIN/hooks/pretooluse-self-care-gate.mjs" ] && ! grep -nE "permissionDecision.{0,20}allow|\"allow\"|'"'"'allow'"'"'" "$PLUGIN/hooks/pretooluse-self-care-gate.mjs"'
ARCH "ls"
check "I2: the refusal names the current ROSTER_CLI and MSG_CLI paths" 'printf "%s" "$OUT" | grep -qF "$R" && printf "%s" "$OUT" | grep -qF "$MG"'
check "I2: the refusal does not echo the command" '! printf "%s" "$OUT" | grep -q "zzzmarker"'
ARCH "zzzmarker"
check "I2: the refusal does not echo the command (marker)" '! printf "%s" "$OUT" | grep -q "zzzmarker"'

cat > "$PROJ/.claude/agent-hierarchy.json" <<'EOF'
{"version":1}
EOF
rs() { OUT=$(HOME="$FAKEHOME" node "$R" role set "$@" --level repo --dry-run --cwd "$PROJ" 2>&1); RC=$?; }
rs gate-test --class review --shell other; check "I3: role set --shell other is rejected" '[ "$RC" != 0 ] && printf "%s" "$OUT" | grep -q "self-care"'
rs architect --shell self-care; check "I3: role set --shell on a built-in is rejected" '[ "$RC" != 0 ]'
rs gate-test --class review --shell self-care; check "I3: role set --shell self-care is accepted and recorded" '[ "$RC" = 0 ] && printf "%s" "$OUT" | grep -q "\"shell\": \"self-care\"\|\"shell\":\"self-care\""'

check "C1: architect.md no longer denies Bash" '! grep -n "^disallowedTools:.*Bash" "$PLUGIN/agents/architect.md"'
check "C1: architect.md keeps NotebookEdit and advisor denied" 'grep -q "^disallowedTools: NotebookEdit, advisor" "$PLUGIN/agents/architect.md"'
check "C1: architect.md has the exception and gate-down sentences" 'grep -q "Exception: self-care ah" "$PLUGIN/agents/architect.md" && tr "\n" " " < "$PLUGIN/agents/architect.md" | grep -q "the gate is down: do not use the shell, and report it"'
check "C2: hooks.json lists the gate first under the PreToolUse Bash matcher" 'node -e "const h=require(process.argv[1]).hooks.PreToolUse.find(e=>e.matcher===\"Bash\"); process.exit(/pretooluse-self-care-gate/.test(h.hooks[0].command)?0:1)" "$PLUGIN/hooks/hooks.json"'

# ---------------------------------------------------------------- one canonical response form
# The form a refused architect is told to use, copied back with only the placeholders filled in.
ARCH "ls"
FORM=$(printf '%s' "$OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const r=JSON.parse(s).hookSpecificOutput.permissionDecisionReason;const m=r.match(/`(node \S+ new --type response[^`]*)`/);process.stdout.write(m?m[1].replace(/ \[--cwd <cwd>\]$/,""):"")})')
FILLED=${FORM//<id>/x}; FILLED=${FILLED//<your request path>/$MSGS/x--request.md}
ARCH "$FILLED"
check "R1: the response form in the deny text, placeholders filled, is allowed (real architect session)" '[ -n "$FORM" ] && silent'
check "R1: ...and it names the role with --from and carries no quotes" 'case "$FORM" in *"--from architect "*) true;; *) false;; esac; [ "${FORM#*\"}" = "$FORM" ]'
ARCH "${FILLED/--from architect/--from orchestrator}"; check "R2: the same form with --from orchestrator is still denied" 'denied'
ARCH "${FILLED/ --from architect/}"; check "R2: the same form without --from is still denied" 'denied'
ARCH "${FILLED/node /node \"}"; check "R2: a quoted-looking CLI token is still denied" 'denied'
ARCH "${FILLED/--type response/--type request}"; check "R2: --type request is still denied" 'denied'
NOTICE=$(node --input-type=module -e "import { buildRoleSessionNotice } from '$PLUGIN/hooks/lib-config.mjs'; process.stdout.write(buildRoleSessionNotice('architect','ah:architect'))")
PFORM=$(printf '%s' "$NOTICE" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const m=s.match(/\((node \S+ new --type response[^)]*)\)/);process.stdout.write(m?m[1]:"")})')
PFILLED=${PFORM//<id>/x}; PFILLED=${PFILLED//<that request path>/$MSGS/x--request.md}
ARCH "$PFILLED"; check "R3: the peer prompt's response form, placeholders filled, is allowed" '[ -n "$PFORM" ] && silent'
for H in pretooluse-sendmessage-response stop-peer-nudge subagentstop-msg-nudge; do
  check "R4: $H builds its response command with the shared renderer" 'grep -q "responseCommand(" "$PLUGIN/hooks/$H.mjs" && ! grep -q "node \"\${MSG_CLI}\" new --type response" "$PLUGIN/hooks/$H.mjs"'
done
GEN=$(node --input-type=module -e "import { responseCommand } from '$PLUGIN/hooks/lib-config.mjs'; process.stdout.write(responseCommand({ id: 'x', role: 'architect', req: process.argv[1] }))" "$MSGS/x--request.md")
ARCH "$GEN"; check "R4: the renderer's output for a real role and request is allowed by the gate" 'silent'
for A in architect implementor reviewer task-runner ultra-advisor; do
  check "R5: agents/$A.md: response line has --from <your role> and --req, and does not take from from the frontmatter" 'L=$(grep "new --type response" "$PLUGIN/agents/$A.md"); case "$L" in *"--from <your role>"*"--req"*) true;; *) false;; esac; tr "\n" " " < "$PLUGIN/agents/$A.md" | tr -s " " | grep -q "\`--id\` is the request.s \`id\`" && ! tr "\n" " " < "$PLUGIN/agents/$A.md" | grep -q "from the request frontmatter"'
done

echo "passed=$PASS failed=$FAIL"; [ "$FAIL" = 0 ]
