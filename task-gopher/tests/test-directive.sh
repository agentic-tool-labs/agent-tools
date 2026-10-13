#!/bin/bash
# task-gopher directive, tick, category table and checkpoint-reason tests.
# Runs the hooks with HOME redirected to a throwaway dir so real config is never touched.
# Usage: bash tests/test-directive.sh   (exits 0 iff every case passes)
#
# The text checks live in tests/directive-check.mjs, which takes the module to check as an argument. The last
# section feeds it deliberately broken copies and fails if any of them is accepted.

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
CHECK="$PLUGIN/tests/directive-check.mjs"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/task-gopher-directive-test.XXXXXX")"
[ -n "$SANDBOX" ] || exit 1
trap 'rm -rf "$SANDBOX"' EXIT
PASS=0; FAIL=0

check() { # check <name> <condition...>
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name"; fi
}

new_home() { mkdir -p "$1/.claude"; touch "$1/.claude/task-gopher.enabled" "$1/.claude/task-gopher.strict"; }
# run <home> <hook-file> <payload-json>  -> OUT, RC
run() { OUT=$(printf '%s' "$3" | HOME="$1" node "$2" 2>/dev/null); RC=$?; }
# jget <expr over parsed stdin object o>
jget() { node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{let o;try{o=JSON.parse(s)}catch{process.exit(2)}const v=eval(process.argv[1]);process.stdout.write(typeof v==="string"?v:JSON.stringify(v))})' "$1"; }
mod() { node --input-type=module -e "import * as m from '$PLUGIN/hooks/directive.mjs'; const v = (($1)); process.stdout.write(typeof v === 'string' ? v : JSON.stringify(v));"; }

H="$SANDBOX/home"; new_home "$H"
SS="$PLUGIN/hooks/sessionstart.mjs"
UPS="$PLUGIN/hooks/userpromptsubmit.mjs"
HOOK="$PLUGIN/hooks/pretooluse-nudge.mjs"

# ---- the texts and the table, as shipped
OUT=$(node "$CHECK" 2>&1); RC=$?
check "checker accepts the shipped directive, tick and table" "[ $RC -eq 0 ]"
[ $RC -eq 0 ] || echo "$OUT"

# ---- what the hooks put in front of the model is exactly those texts
DIRECTIVE="$(mod 'm.DIRECTIVE')"; TICK="$(mod 'm.TICK')"
run "$H" "$SS" '{"session_id":"s1"}'
check "SessionStart injects exactly the directive" "[ \"\$(printf '%s' \"\$OUT\" | jget 'o.hookSpecificOutput.additionalContext')\" = \"\$DIRECTIVE\" ]"
run "$H" "$UPS" '{"session_id":"s1"}'
check "UserPromptSubmit injects exactly the tick" "[ \"\$(printf '%s' \"\$OUT\" | jget 'o.hookSpecificOutput.additionalContext')\" = \"\$TICK\" ]"
OFF="$SANDBOX/off"; mkdir -p "$OFF/.claude"
run "$OFF" "$SS" '{"session_id":"s1"}'; check "OFF: SessionStart silent" "[ -z \"\$OUT\" ]"
run "$OFF" "$UPS" '{"session_id":"s1"}'; check "OFF: UserPromptSubmit silent" "[ -z \"\$OUT\" ]"
run "$H" "$SS" '{"session_id":"s1","agent_type":"task-gopher:smart-gopher"}'; check "inside smart-gopher: SessionStart silent" "[ -z \"\$OUT\" ]"
run "$H" "$UPS" '{"session_id":"s1","agent_type":"ah:reviewer"}'; check "inside an ah role: tick silent" "[ -z \"\$OUT\" ]"

NOSENT='{"tool_name":"Agent","prompt_id":"d1","session_id":"sD","tool_input":{"subagent_type":"general-purpose","prompt":"do the thing"}}'
run "$H" "$HOOK" "$NOSENT"
WANT_STAMP=$(printf '%s\n\n%s' "$DIRECTIVE" 'do the thing')
GOT_STAMP=$(printf '%s' "$OUT" | jget 'o.hookSpecificOutput.updatedInput.prompt')
check "relay stamps the directive followed by the original prompt" "[ \"\$GOT_STAMP\" = \"\$WANT_STAMP\" ]"
STAMPED=$(printf '%s' "$OUT" | jget 'o.hookSpecificOutput.updatedInput.prompt' | wc -w | tr -d ' ')
check "a stamped dispatch prompt is far smaller than the retired 1,742-word directive" "[ $STAMPED -lt 300 ]"

# ---- the classifier's labels against the table, and each label's reason
LOG="$H/.claude/task-gopher.log"
ids_in_table=$(mod 'm.CATEGORIES.map(c => c.id).join(" ")')
seen_ids=" "
probe() { # <label> <tool> <tool_input-json>  (first retrieval of a fresh context)
  local pid="c-$1"
  run "$H" "$HOOK" "{\"tool_name\":\"$2\",\"prompt_id\":\"$pid\",\"session_id\":\"s-$1\",\"tool_input\":$3}"
  local cls; cls=$(tail -1 "$LOG" | jget 'o.cls')
  seen_ids="$seen_ids$cls "
  check "$1: logged with a category from the table" "case ' $ids_in_table ' in *' $cls '*) true;; *) false;; esac"
  if [ "$2" = "Read" ]; then
    check "$1: a first Read passes" "[ -z \"\$OUT\" ]"
  else
    local want; want=$(mod "m.checkpointReason('$cls', false)")
    check "$1: the deny reason is the table text for $cls" \
      "[ \"\$(printf '%s' \"\$OUT\" | jget 'o.hookSpecificOutput.permissionDecisionReason')\" = \"\$want\" ]"
  fi
}
probe grep-tool Grep '{"pattern":"x"}'
probe glob-tool Glob '{"pattern":"**/*.ts"}'
probe read-tool Read '{"file_path":"/x/a.txt"}'
probe grep-cmd Bash '{"command":"grep -rn foo src"}'
probe find-cmd Bash '{"command":"find . -name x"}'
probe git-log Bash '{"command":"git log --oneline -20"}'
probe npm-test Bash '{"command":"npm test"}'
probe make-all Bash '{"command":"make all"}'
probe cat-file Bash '{"command":"cat big.log"}'
probe script-grep Bash '{"command":"python3 gen.py && grep -n x out.txt"}'
for id in $ids_in_table; do
  check "the battery produced category $id" "case '$seen_ids' in *' $id '*) true;; *) false;; esac"
done

# escalated reasons: the lead line, then the category's text
GREP='{"tool_name":"Grep","prompt_id":"esc1","session_id":"sE","tool_input":{"pattern":"x"}}'
run "$H" "$HOOK" "$GREP"; run "$H" "$HOOK" "$GREP"; run "$H" "$HOOK" "$GREP"; run "$H" "$HOOK" "$GREP"
want=$(mod "m.checkpointReason('search', true)")
check "third bypass: the escalated reason is the lead line plus the search text" \
  "[ \"\$(printf '%s' \"\$OUT\" | jget 'o.hookSpecificOutput.permissionDecisionReason')\" = \"\$want\" ]"
check "the escalated reason leads with the bundle line" \
  "printf '%s' \"\$OUT\" | jget 'o.hookSpecificOutput.permissionDecisionReason' | grep -q '^That is 3 direct calls this turn; bundle what you still need into ONE order\.'"

# ---- the explanations that left the directive are still where a model reads them
check "destructive guard's deny reason shows how to pre-authorize" \
  "node --input-type=module -e \"import {denyMessage} from '$PLUGIN/hooks/destructive.mjs'; const t = denyMessage([{kind:'destructive',stage:'rm -rf x',label:'delete'}], null); process.exit(t.includes('ALLOW-DESTRUCTIVE: <the exact command>') ? 0 : 1)\""
SMART='{"tool_name":"Agent","prompt_id":"sm1","session_id":"sSM","tool_input":{"subagent_type":"task-gopher:smart-gopher","prompt":"which of these is the entry point"}}'
run "$H" "$HOOK" "$SMART"
REASON=$(printf '%s' "$OUT" | jget 'o.hookSpecificOutput.permissionDecisionReason')
check "smart-gopher gate reason shows how to pre-authorize" "printf '%s' \"\$REASON\" | grep -q 'ALLOW-DESTRUCTIVE: <the exact command>'"
check "smart-gopher gate reason explains the per-request checkpoint" "printf '%s' \"\$REASON\" | grep -q 'checkpoints per distinct request'"
check "task-gopher's definition says what to do when the order is silent on failure" "grep -q 'WHAT IF' \"$PLUGIN/agents/task-gopher.md\""

# ---- G1 probe: a hook directory under test gets a first Read and a first Bash grep in fresh turns
g1_probe() { # <hooks dir> -> exit 0 iff Read first passes AND Bash grep first is denied
  local d="$1" hh="$SANDBOX/g1home.$RANDOM"
  new_home "$hh"
  local r b
  r=$(printf '%s' '{"tool_name":"Read","prompt_id":"p1","session_id":"sP","tool_input":{"file_path":"/x"}}' | HOME="$hh" node "$d/pretooluse-nudge.mjs" 2>/dev/null)
  b=$(printf '%s' '{"tool_name":"Bash","prompt_id":"p2","session_id":"sP","tool_input":{"command":"grep -rn foo src"}}' | HOME="$hh" node "$d/pretooluse-nudge.mjs" 2>/dev/null)
  [ -z "$r" ] && printf '%s' "$b" | grep -q '"permissionDecision":"deny"'
}
check "G1 probe accepts the shipped hook" "g1_probe '$PLUGIN/hooks'"

# ---- can-fail: every check above must reject its nearest broken copy
# mutate <name> <file> <from> <to>: copy the plugin's hooks to $SANDBOX/<name> and replace <from> by <to> in <file>
mutate() {
  local name="$1" file="$2" from="$3" to="$4"
  rm -rf "$SANDBOX/$name"; mkdir -p "$SANDBOX/$name"; cp -R "$PLUGIN/hooks" "$SANDBOX/$name/hooks"
  node -e '
    const fs = require("fs"); const [file, from, to] = process.argv.slice(1);
    const s = fs.readFileSync(file, "utf8");
    if (!s.includes(from)) { console.error("mutation target not found: " + from.slice(0, 60)); process.exit(3); }
    fs.writeFileSync(file, s.replace(from, () => to));
  ' "$SANDBOX/$name/hooks/$file" "$from" "$to"
}
# rejects <name> <check-id>: the checker must exit 1 on the copy and print that check id
rejects() {
  local out rc
  out=$(node "$CHECK" "$SANDBOX/$1/hooks/directive.mjs" 2>&1); rc=$?
  [ $rc -eq 1 ] && printf '%s' "$out" | grep -q "FAIL $2 "
}

EXTRA="$(printf 'extra%d ' $(seq 1 30))"
LONG_EXTRA="$(printf 'extra%d ' $(seq 1 45))"
mutate m-words directive.mjs 'Re-run only for an exception.`;' "Re-run only for an exception. ${EXTRA}\`;"
check "can fail: 30 extra words in the directive are rejected" "rejects m-words directive-words"

mutate m-bare directive.mjs '-> task-gopher:smart-gopher (Sonnet)' '-> smart-gopher (Sonnet)'
check "can fail: bare smart-gopher name is rejected" "rejects m-bare directive-bare-name"

mutate m-purpose directive.mjs '[task-gopher: ON] PURPOSE: keep' '[task-gopher: ON] Keep'
check "can fail: no PURPOSE clause first is rejected" "rejects m-purpose directive-purpose-first"

mutate m-counter directive.mjs 'If you have made 2 direct retrieval calls in a row' 'If you have made a few direct retrieval calls in a row'
check "can fail: no '2 direct retrieval calls' in the directive is rejected" "rejects m-counter directive-token"

mutate m-bullet directive.mjs '- The answer needs picking among candidates, reconciling disagreeing evidence, a summary with an editorial cut, or later steps depend on earlier findings -> task-gopher:smart-gopher (Sonnet). E.g. "which of these call sites is the real entry point, and why".
' ''
check "can fail: selector without its smart-gopher bullet is rejected" "rejects m-bullet selector"

mutate m-cat directive.mjs 'export const CATEGORIES = [' 'export const CATEGORIES = [
  { id: "profile", words: "profiler runs", runner: "task-gopher:task-gopher", deny: READ_TEXT, patterns: [/\bperf\b/] },'
check "can fail: a category in the table but not in the directive's list is rejected" "rejects m-cat directive-trigger-list"

mutate m-noname directive.mjs "'task-gopher checkpoint: you are searching code. Order it: task-gopher:task-gopher for a known pattern (\"every caller of f, file:line\"); task-gopher:smart-gopher to decide which of several candidates is the right one. '" "'task-gopher checkpoint: you are searching code. Order it instead of doing it. '"
check "can fail: a deny text naming no gopher is rejected" "rejects m-noname deny-names-no-gopher"

mutate m-long directive.mjs "'task-gopher checkpoint: a test, build or lint run. task-gopher:task-gopher: \"run <cmd>, report failures only, at most 30 lines\". '" "'task-gopher checkpoint: a test, build or lint run. task-gopher:task-gopher: \"run <cmd>, report failures only, at most 30 lines\". ${LONG_EXTRA}'"
check "can fail: a deny text over 60 words is rejected" "rejects m-long deny-words"

mutate m-tick directive.mjs 'After 2 direct retrieval calls, bundle the rest into ONE order."' "After 2 direct retrieval calls, bundle the rest into ONE order. ${EXTRA}\""
check "can fail: a tick over 45 words is rejected" "rejects m-tick tick-words"

mutate m-g1a pretooluse-nudge.mjs 'if (tool === "Read" && (!seen || afterDispatch)) {' 'if (false) {'
check "can fail: a first Read still denied is rejected" "! g1_probe '$SANDBOX/m-g1a/hooks'"

mutate m-g1b pretooluse-nudge.mjs 'if (tool === "Read" && (!seen || afterDispatch)) {' 'if (!seen || afterDispatch) {'
check "can fail: a first Bash grep passed is rejected" "! g1_probe '$SANDBOX/m-g1b/hooks'"

# the probe itself must accept the shipped copy of the same file the mutants came from
check "G1 probe still accepts an unmutated copy" "rm -rf '$SANDBOX/m-ok' && mkdir -p '$SANDBOX/m-ok' && cp -R '$PLUGIN/hooks' '$SANDBOX/m-ok/hooks' && g1_probe '$SANDBOX/m-ok/hooks'"

echo "----"
echo "SUMMARY: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
