#!/bin/bash
# agent-hierarchy — a response written beside its request (msg.mjs new --req) is a valid
# SendMessage pointer even when the responder's cwd pool is a different checkout's pool.
# Real main checkout + linked worktree; HOME-redirected; AGENT_HIERARCHY_DIR unset.
# Usage: bash tests/test-response-pointer-beside-request.sh   (exits 0 iff all cases pass)

. "$(dirname "$0")/lib-hermetic.sh"
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
unset AH_TEAM_FILE CLAUDE_PID AGENT_HIERARCHY_DIR
H="$PLUGIN/hooks"
MSG="$H/msg.mjs"
TRACK="$H/userpromptsubmit-peer-tracking.mjs"
PTU="$H/posttooluse-peer-resolve.mjs"
STOP="$H/stop-peer-nudge.mjs"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-besidereq-test.XXXXXX")"
[ -n "$SANDBOX" ] || exit 1
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
MAIN="$SANDBOX/main"
WT="$SANDBOX/wt"
mkdir -p "$FAKEHOME/.claude" "$MAIN/.claude"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:500})"; fi
}

git -C "$MAIN" init -q
git -C "$MAIN" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
git -C "$MAIN" worktree add -q "$WT" -b wt-branch
echo '{ "version": 1, "enabled": true, "roles": {} }' > "$MAIN/.claude/agent-hierarchy.json"

msg() { OUT=$(HOME="$FAKEHOME" node "$MSG" "$@" 2>"$SANDBOX/err"); RC=$?; }
field() { node -e 'process.stdout.write(String(JSON.parse(process.argv[1])[process.argv[2]]))' "$OUT" "$1"; }

# Chain of PreToolUse hooks on SendMessage, in hooks.json order; first deny wins.
CHAIN=$(node -e 'const h=require(process.argv[1]).hooks.PreToolUse.find(m=>/SendMessage/.test(m.matcher)).hooks;process.stdout.write(h.map(x=>x.command.match(/hooks\/([^"]+)"/)[1]).join(" "))' "$PLUGIN/hooks/hooks.json")
send_chain() { # <session> <message>
  local p; p=$(node -e 'const[s,m]=process.argv.slice(1);process.stdout.write(JSON.stringify({session_id:s,cwd:process.env.MAIN,tool_name:"SendMessage",agent_type:"architect",tool_input:{to:"ct-orchestrator",message:m}}))' "$1" "$2")
  OUT=""; RC=0
  for h in $CHAIN; do
    OUT=$(printf '%s' "$p" | HOME="$FAKEHOME" MAIN="$MAIN" node "$H/$h" 2>&1); RC=$?
    echo "$OUT" | grep -q '"permissionDecision":"deny"' && return
  done
  OUT=""
}
denied() { echo "$OUT" | grep -q '"permissionDecision":"deny"'; }
allowed() { [ -z "$OUT" ]; }

arm() { # <session> <request path>
  node -e 'const[s,l]=process.argv.slice(1);process.stdout.write(JSON.stringify({session_id:s,cwd:process.env.MAIN,prompt:`<cross-session-message from="ct-orchestrator" from-name="ct-orchestrator">\n${l}\ntldr`}))' "$1" "[hierarchy-msg $2]" \
    | HOME="$FAKEHOME" MAIN="$MAIN" node "$TRACK" >/dev/null 2>&1
}

new_pair() { # <slug> -> sets REQ RESP ID (request in worktree pool, response beside it)
  msg new --type request --to architect --from orchestrator --slug "$1" --cwd "$WT"; REQ=$(field path); ID=$(field id)
  msg new --type response --id "$ID" --to orchestrator --from architect --req "$REQ" --cwd "$MAIN"; RESP=$(field path)
  printf '\n- done: PASS\n' >> "$RESP"
}

# ---- T1: worktree request, main-checkout responder, team_file null
new_pair t1
check "T1 precondition: request has team_file null" 'grep -q "^team_file: null" "$REQ"'
check "T1 precondition: response sits beside the request" '[ "$(cd "$(dirname "$RESP")" && pwd -P)" = "$(cd "$(dirname "$REQ")" && pwd -P)" ]'
arm s1 "$REQ"
pending_n() { HOME="$FAKEHOME" node --input-type=module -e 'const{pendingFor}=await import(process.argv[1]);process.stdout.write(String(pendingFor(process.argv[2]).length))' "$H/lib-peer.mjs" "$1"; }
check "T1 precondition: s1 owes one response" '[ "$(pending_n s1)" = 1 ]'
send_chain s1 "[hierarchy-msg $RESP]
- done: PASS"
check "T1a: whole SendMessage chain allows the beside-request response" 'allowed'
OUT=$(node -e 'process.stdout.write(JSON.stringify({session_id:"s1",cwd:process.env.MAIN,tool_name:"SendMessage",tool_input:{to:"ct-orchestrator",message:process.argv[1]}}))' "[hierarchy-msg $RESP]
- done: PASS" | HOME="$FAKEHOME" MAIN="$MAIN" node "$PTU" 2>&1); RC=$?
check "T1b: peer-resolve recorded s1's obligation resolved" '[ "$(pending_n s1)" = 0 ]'
OUT=$(printf '{"session_id":"s1","cwd":"%s","stop_hook_active":false}' "$MAIN" | HOME="$FAKEHOME" node "$STOP" 2>&1); RC=$?
check "T1c: stop-peer-nudge does not block after the send" '! echo "$OUT" | grep -q "\"decision\":\"block\""'

# ---- T1 control: the obligation really is owed before the send
new_pair t1b
arm s1b "$REQ"
OUT=$(printf '{"session_id":"s1b","cwd":"%s","stop_hook_active":false}' "$MAIN" | HOME="$FAKEHOME" node "$STOP" 2>&1); RC=$?
check "T1 control: stop-peer-nudge blocks before any send" 'echo "$OUT" | grep -q "\"decision\":\"block\""'

# ---- T2: response in a third directory
new_pair t2
mkdir -p "$SANDBOX/elsewhere"; cp "$RESP" "$SANDBOX/elsewhere/"; STRAY="$SANDBOX/elsewhere/$(basename "$RESP")"
arm s2 "$REQ"
send_chain s2 "[hierarchy-msg $STRAY]
- done: PASS"
check "T2: response outside its request's directory is denied" 'denied'
check "T2: reason names the request's directory" 'echo "$OUT" | grep -qF "$(dirname "$REQ")"'
check "T2: reason does not blame the cwd" '! echo "$OUT" | grep -q "the cwd is wrong"'

# ---- T3: symlink alias of the pool directory
new_pair t3
ln -s "$(dirname "$REQ")" "$SANDBOX/alias"
arm s3 "$SANDBOX/alias/$(basename "$REQ")"
send_chain s3 "[hierarchy-msg $RESP]
- done: PASS"
check "T3: aliased request path vs real response path is allowed" 'allowed'

# ---- T4: wrong id beside the request
new_pair t4
REQ4=$REQ
new_pair t4other
arm s4 "$REQ4"
send_chain s4 "[hierarchy-msg $RESP]
- done: PASS"
check "T4: another request's response is denied" 'denied'
check "T4: reason is wrong id" 'echo "$OUT" | grep -q "wrong id"'

# ---- T4b: two open requests in different pools; stray response for the newer one
new_pair t4old
OLDREQ=$REQ
msg new --type request --to architect --from orchestrator --slug t4new --cwd "$MAIN"; NEWREQ=$(field path); NEWID=$(field id)
msg new --type response --id "$NEWID" --to orchestrator --from architect --req "$NEWREQ" --cwd "$MAIN"; NEWRESP=$(field path)
printf '\n- done: PASS\n' >> "$NEWRESP"
cp "$NEWRESP" "$SANDBOX/elsewhere/"
arm s4b "$OLDREQ"; sleep 0.05; arm s4b "$NEWREQ"
send_chain s4b "[hierarchy-msg $SANDBOX/elsewhere/$(basename "$NEWRESP")]
- done: PASS"
check "T4b: stray response for the newer request is denied" 'denied'
check "T4b: reason names the newer request's directory" 'echo "$OUT" | grep -qF "$(dirname "$NEWREQ")"'
check "T4b: reason is not wrong id" '! echo "$OUT" | grep -q "wrong id"'

# ---- T5: suffix is checked before the file is read
new_pair t5
echo hi > "$SANDBOX/plain.txt"
arm s5 "$REQ"
send_chain s5 "[hierarchy-msg $SANDBOX/plain.txt]
- done: PASS"
check "T5: non-message file is denied as not a response file" 'denied && echo "$OUT" | grep -q "not a response file"'
mkfifo "$SANDBOX/x.txt"
OUT=$(node -e 'process.stdout.write(JSON.stringify({session_id:"s5",cwd:process.env.MAIN,tool_name:"SendMessage",agent_type:"architect",tool_input:{to:"ct-orchestrator",message:"[hierarchy-msg "+process.argv[1]+"]\n- x"}}))' "$SANDBOX/x.txt" | HOME="$FAKEHOME" MAIN="$MAIN" perl -e 'alarm 10; exec @ARGV' node "$H/pretooluse-sendmessage-response.mjs" 2>&1); RC=$?
check "T5: FIFO pointer does not hang the hook" '[ $RC -ne 142 ] && denied'

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
