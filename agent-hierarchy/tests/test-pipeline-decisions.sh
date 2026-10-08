#!/bin/bash
# agent-hierarchy — a /pipeline run's decision log through `msg.mjs decision add|list`: numbering,
# the refusals that keep a line from acting, never re-asking a parked question, the caps, finding
# the run, the reader, and the skill text that drives it.
# HOME- and AGENT_HIERARCHY_DIR-redirected; real state untouched.
# Usage: bash tests/test-pipeline-decisions.sh   (exits 0 iff all cases pass)

. "$(dirname "$0")/lib-hermetic.sh"
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
unset AH_TEAM_FILE CLAUDE_PID AGENT_HIERARCHY_DIR
H="$PLUGIN/hooks"
MSG="$H/msg.mjs"
SKILL="$PLUGIN/skills/autonomous-pipeline/SKILL.md"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-decisions-test.XXXXXX")"
[ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] || { echo "mktemp failed"; exit 1; }
hermetic_on_exit 'rm -rf "$SANDBOX"'
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
HD="$SANDBOX/hier"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:300} ERR=${ERR:0:300})"; fi
}

msg() {
  OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$MSG" "$@" --cwd "$SANDBOX" 2>"$SANDBOX/err"); RC=$?
  ERR=$(cat "$SANDBOX/err")
}

# <js expression over the parsed OUT o>: its value (strings bare, anything else as JSON).
jget() {
  node -e 'const o=JSON.parse(process.argv[1]);const v=(new Function("o","return ("+process.argv[2]+")"))(o);process.stdout.write(typeof v==="string"?v:JSON.stringify(v))' "$OUT" "$1" 2>/dev/null
}

# An empty HOME and hierarchy dir.
fresh() {
  rm -rf "$FAKEHOME" "$HD"
  mkdir -p "$FAKEHOME/.claude"
}

# Opens a run anchor for team `at`; its id lands in A.
open_anchor() {
  msg new --to orchestrator --from orchestrator --slug pipeline-run-anchor --team at
  A=$(jget o.id)
  LOG="$HD/pipeline/$A/decisions.jsonl"
}

# <anchor id>: closes that anchor.
close_anchor() {
  msg new --type response --id "$1" --to orchestrator --from orchestrator --slug pipeline-run-anchor --team at
}

# [js object of overrides]: a decided line's input; a key set to undefined is left out.
decided() {
  node -e '
    const base = { kind: "decided", item: "i1", source: "architect", question: "Use A, B or C?", options: ["opt A", "opt B", "opt C"],
      default: "a", choice: "b", decider: { role: "ultra-advisor", name: "at-ultra-advisor", model: "fable" },
      rationale: "B fits the plan", revert: "revert the commit naming it", review: false, why_user: null, dangerous: false, exchange: null };
    process.stdout.write(JSON.stringify(Object.assign(base, (new Function("return (" + (process.argv[1] || "{}") + ")"))())));
  ' "$1"
}

# [js object of overrides]: a parked line's input, parked before any dispatch.
parked() {
  decided "Object.assign({ kind: \"parked\", choice: null, decider: null, why_user: \"unsure\", rationale: \"\", revert: \"\" }, ${1:-{\}})"
}

# <input json> [team]: decision add.
add() {
  OUT=$(printf '%s' "$1" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$MSG" decision add --team "${2:-at}" --cwd "$SANDBOX" 2>"$SANDBOX/err"); RC=$?
  ERR=$(cat "$SANDBOX/err")
}

sum() { [ -f "$LOG" ] && cksum < "$LOG" || echo none; }

# <label> <input json> <text the refusal carries>: exit 2, the reason on stdout, and the log untouched.
refused() {
  local before; before=$(sum)
  add "$2"
  AFTER=$(sum) BEFORE=$before WANT=$3
  check "W2 $1 is refused, log unchanged" '[ $RC = 2 ] && [ "$(jget o.refused)" = true ] && [[ "$(jget o.detail)" == *"$WANT"* ]] && [ "$AFTER" = "$BEFORE" ]'
}

# ---------------------------------------------------------------- W1 append
fresh; open_anchor
add "$(decided)"
check "W1 the first decided line is d1" '[ $RC = 0 ] && [ "$(jget o.id)" = d1 ] && [ "$(jget o.path)" = "$LOG" ]'
add "$(decided '{ question: "Name it x or y?", options: ["x", "y"] }')"
check "W1 the second is d2" '[ $RC = 0 ] && [ "$(jget o.id)" = d2 ]'
check "W1 the log is <hier>/pipeline/<anchor id>/decisions.jsonl, one line each" '[ -f "$LOG" ] && [ "$(wc -l < "$LOG" | tr -d " ")" = 2 ]'
check "W1 each line holds every field plus id, time, run, qkey and decision" 'node -e "
  const want = [\"id\",\"time\",\"run\",\"kind\",\"item\",\"source\",\"question\",\"qkey\",\"options\",\"default\",\"choice\",\"decision\",\"decider\",\"rationale\",\"revert\",\"review\",\"why_user\",\"dangerous\",\"exchange\"];
  const lines = require(\"fs\").readFileSync(process.argv[1], \"utf8\").trim().split(\"\n\").map(JSON.parse);
  process.exit(lines.every((l) => JSON.stringify(Object.keys(l)) === JSON.stringify(want) && l.run === process.argv[2] && !isNaN(Date.parse(l.time))) ? 0 : 1);
" "$LOG" "$A"'

# ---------------------------------------------------------------- W1b ids skip other kinds
printf '%s\n' '{"kind":"merge","pr":7,"sha":"0123456789abcdef0123456789abcdef01234567","method":"merge","time":"2026-09-30T00:00:00Z","approval":"permission prompt"}' >> "$LOG"
add "$(decided '{ question: "Third question?" }')"
check "W1b a merge line doesn't shift the next id" '[ $RC = 0 ] && [ "$(jget o.id)" = d3 ]'
msg decision list --team at
check "W1b list shows the merge line" '[ $RC = 0 ] && [ "$(jget "o.decisions.map((d) => d.kind).join()")" = decided,decided,merge,decided ]'
msg decision list --team at --summary
check "W1b the summary counts it nowhere" '[ "$(jget "o.decided + \"/\" + o.parked + \"/\" + Object.keys(o.by_item).join()")" = 3/0/i1 ]'

# ---------------------------------------------------------------- W2 invariants
fresh; open_anchor
add "$(decided)"
refused "a missing field" "$(decided '{ rationale: undefined }')" "missing field(s): rationale"
refused "a mistyped field" "$(decided '{ review: "yes" }')" "review must be a boolean"
refused "decided and dangerous" "$(decided '{ dangerous: true }')" "can't be dangerous"
refused "decided with the user as decider" "$(decided '{ decider: { role: "user", name: null, model: null } }')" "can't be the user"
refused "decided with a why_user" "$(decided '{ why_user: "unsure" }')" "has no why_user"
refused "decided with a choice that is no option" "$(decided '{ choice: "maybe" }')" "choice must be a letter within options"
refused "decided with a letter past the options" "$(decided '{ choice: "d" }')" "choice must be a letter within options"
refused "parked with a choice" "$(parked '{ choice: "a" }')" "has no choice"
refused "parked without a why_user" "$(parked '{ why_user: null }')" "needs why_user"
refused "dangerous with a why_user other than dangerous" "$(parked '{ dangerous: true, why_user: "unsure" }')" "needs why_user dangerous"
refused "kind merge from the CLI" "$(decided '{ kind: "merge" }')" "merge record hook"
add "$(parked '{ dangerous: true, why_user: "dangerous", question: "Force-push?" }')"
check "W2 a dangerous question is logged as parked" '[ $RC = 0 ] && [ "$(jget o.id)" = d2 ]'

# ---------------------------------------------------------------- W2b refusal reasons for parking
add "$(decided '{ review: "yes" }')"
check "W2b a field refusal prints reason invalid on stdout, exit 2" '[ $RC = 2 ] && [ "$(jget o.reason)" = invalid ]'
add "$(decided '{ question: "Force-push?" }')"
check "W2b parked-before prints its reason on stdout, exit 2" '[ $RC = 2 ] && [ "$(jget o.reason)" = parked-before ]'
for q in c1 c2 c3; do add "$(decided "{ item: \"capped\", question: \"$q\" }")"; done
add "$(decided '{ item: "capped", question: "c4" }')"
add "$(decided '{ item: "capped", question: "c5" }')"
check "W2b a cap prints reason cap on stdout, exit 2" '[ $RC = 2 ] && [ "$(jget o.reason)" = cap ]'

# ---------------------------------------------------------------- W2c never re-ask
fresh; open_anchor
add "$(parked '{ question: "Rename the module?" }')"
add "$(decided '{ question: "Rename the module?" }')"
check "W2c a decided line for a parked question is refused parked-before" '[ $RC = 2 ] && [ "$(jget o.reason)" = parked-before ] && [ "$(wc -l < "$LOG" | tr -d " ")" = 1 ]'
add "$(decided '{ question: "  rename   THE module?\n" }')"
check "W2c ... also when it differs only in case and whitespace" '[ $RC = 2 ] && [ "$(jget o.reason)" = parked-before ]'
add "$(decided '{ item: "i2", question: "Rename the module?" }')"
check "W2c the same question on another item is accepted" '[ $RC = 0 ]'
add "$(decided '{ question: "Rename the package?" }')"
check "W2c a different question is accepted" '[ $RC = 0 ]'

# ---------------------------------------------------------------- W2d letters
fresh; open_anchor
add "$(decided '{ choice: "b" }')"
msg decision list --team at
check "W2d choice b stores options[1] as decision" '[ "$(jget "o.decisions[0].decision")" = "opt B" ] && [ "$(jget "o.decisions[0].choice")" = b ]'
add "$(decided '{ question: "Four ways?", options: ["w", "x", "y", "z"], choice: "e" }')"
check "W2d choice e with 4 options is refused" '[ $RC = 2 ]'
add "$(decided '{ question: "Something else?", choice: "other: keep both", review: true }')"
msg decision list --team at
check "W2d other: is stored as its own text" '[ "$(jget "o.decisions[1].decision")" = "other: keep both" ]'

# ---------------------------------------------------------------- W2e fields
fresh; open_anchor
add "$(decided '{ note: "x" }')"
check "W2e an unknown key is refused" '[ $RC = 2 ] && [[ "$(jget o.detail)" == *"unknown field(s): note"* ]]'
for f in id time run decision qkey; do
  add "$(decided "{ $f: \"x\" }")"
  F=$f
  check "W2e a caller-supplied $f is refused" '[ $RC = 2 ] && [[ "$(jget o.detail)" == *"writer-owned field(s) supplied: $F"* ]]'
done
add "$(decided '{ decider: null }')"
check "W2e a null decider on a decided line is refused" '[ $RC = 2 ]'
add "$(parked)"
check "W2e a null decider on a parked line is accepted" '[ $RC = 0 ]'
check "W2e nothing refused was written" '[ "$(wc -l < "$LOG" | tr -d " ")" = 1 ]'

add "$(decided '{ question: "Extra decider key?", decider: { role: "architect", name: null, model: null, via: "x" } }')"
check "W2e a decider with a key beyond role, name and model is refused" '[ $RC = 2 ] && [[ "$(jget o.detail)" == *"decider must be"* ]]'
add "$(decided '{ question: "Capital user?", decider: { role: "User", name: null, model: null } }')"
check "W2e a decider role User is refused" '[ $RC = 2 ] && [[ "$(jget o.detail)" == *"decider must be"* ]]'
add "$(decided '{ question: "Spaced user?", decider: { role: " user", name: null, model: null } }')"
check "W2e a decider role \" user\" is refused" '[ $RC = 2 ] && [[ "$(jget o.detail)" == *"decider must be"* ]]'
add "$(decided '{ question: "Other without review?", choice: "other: keep both", review: false }')"
check "W2e an other: answer with review false is refused" '[ $RC = 2 ] && [[ "$(jget o.detail)" == *"always means review: true"* ]] && [ "$(wc -l < "$LOG" | tr -d " ")" = 1 ]'

# ---------------------------------------------------------------- W2f decided before
fresh; open_anchor
add "$(decided '{ question: "Same answer twice?" }')"
add "$(decided '{ question: "Same answer twice?" }')"
check "W2f the same decided input twice: the second is refused decided-before" '[ $RC = 2 ] && [ "$(jget o.reason)" = decided-before ] && [[ "$(jget o.detail)" == *"as d1"* ]] && [ "$(wc -l < "$LOG" | tr -d " ")" = 1 ]'

# ---------------------------------------------------------------- W3 caps
fresh; open_anchor
for q in a1 a2 a3 a4; do add "$(decided "{ question: \"$q\" }")"; done
check "W3 four decided for one item are accepted" '[ $RC = 0 ] && [ "$(jget o.id)" = d4 ]'
add "$(decided '{ question: "a5" }')"
check "W3 the fifth decided for that item is refused" '[ $RC = 2 ] && [ "$(jget o.reason)" = cap ]'
add "$(parked '{ question: "a5", why_user: "cap" }')"
check "W3 a parked line for that item is still accepted" '[ $RC = 0 ]'
for q in b1 b2 b3; do add "$(decided "{ item: \"i2\", question: \"$q\" }")"; done
add "$(parked '{ item: "i2", question: "b4" }')"
add "$(decided '{ item: "i2", question: "b5" }')"
check "W3 parked lines don't count toward the item cap" '[ $RC = 0 ]'
for i in 3 4 5; do for q in 1 2 3 4; do add "$(decided "{ item: \"i$i\", question: \"q$q\" }")"; done; done
check "W3 twenty decided in the run are accepted" '[ $RC = 0 ] && [ "$(node -e "console.log(require(\"fs\").readFileSync(process.argv[1],\"utf8\").trim().split(\"\n\").filter((l)=>JSON.parse(l).kind===\"decided\").length)" "$LOG")" = 20 ]'
add "$(decided '{ item: "i6", question: "one too many" }')"
check "W3 the 21st decided in the run is refused" '[ $RC = 2 ] && [ "$(jget o.reason)" = cap ] && [[ "$(jget o.detail)" == *"the run already has 20"* ]]'

# ---------------------------------------------------------------- W4 run lookup
fresh
add "$(decided)"
check "W4 no open anchor → refused" '[ $RC = 2 ] && [ "$(jget o.reason)" = no-run ] && [ ! -d "$HD/pipeline" ]'
open_anchor; FIRST=$A
open_anchor
add "$(decided)"
check "W4 two open anchors → refused" '[ $RC = 2 ] && [ "$(jget o.reason)" = no-run ] && [ ! -d "$HD/pipeline" ]'
close_anchor "$A"
add "$(decided)"
check "W4 the closed anchor is ignored: the line goes to the open run" '[ $RC = 0 ] && [ -f "$HD/pipeline/$FIRST/decisions.jsonl" ] && [ ! -e "$HD/pipeline/$A" ]'
close_anchor "$FIRST"
add "$(decided '{ question: "After the run?" }')"
check "W4 with every anchor closed, add is refused" '[ $RC = 2 ] && [ "$(jget o.reason)" = no-run ]'
msg decision list --team at --run "$FIRST"
check "W4 list --run reads a closed run" '[ $RC = 0 ] && [ "$(jget o.run)" = "$FIRST" ] && [ "$(jget o.decisions.length)" = 1 ]'
msg decision list --team at
check "W4 list with no open anchor and no --run is refused" '[ $RC = 2 ]'
msg decision list --team at --run ../../etc
check "W4 list --run refuses a non-id" '[ $RC = 2 ]'

# ---------------------------------------------------------------- W5 reader
fresh; open_anchor
add "$(decided '{ review: true }')"
add "$(decided '{ item: "i2", question: "Other item?" }')"
add "$(parked '{ item: "i2", question: "Parked one?" }')"
printf '%s' '{"id":"d4","kind":"deci' >> "$LOG"
msg decision list --team at
check "W5 a torn last line is skipped and counted" '[ $RC = 0 ] && [ "$(jget o.decisions.length)" = 3 ] && [ "$(jget o.skipped)" = 1 ]'
msg decision list --team at --item i2
check "W5 --item filters" '[ "$(jget "o.decisions.map((d) => d.id).join()")" = d2,d3 ]'
msg decision list --team at --summary
check "W5 --summary counts decided, flagged and parked" '[ "$(jget "[o.decided, o.flagged, o.parked, o.skipped].join()")" = 2,1,1,1 ] && [ "$(jget "JSON.stringify(o.by_item)")" = "{\"i1\":{\"decided\":1,\"parked\":0},\"i2\":{\"decided\":1,\"parked\":1}}" ]'
check "W5 --summary line text" '[ "$(jget o.line)" = "decisions: 2 decided (1 flagged), 1 waiting for you" ]'
add "$(decided '{ item: "i3", question: "After the crash?" }')"
check "W5 an add after a torn last line gets the next id" '[ $RC = 0 ] && [ "$(jget o.id)" = d4 ]'
msg decision list --team at
check "W5 ... and its line parses on its own, the fragment still skipped" '[ "$(jget "o.decisions.map((d) => d.id).join()")" = d1,d2,d3,d4 ] && [ "$(jget o.skipped)" = 1 ]'

# ---------------------------------------------------------------- W6 the input file
fresh; open_anchor
RUN_DIR="$HD/pipeline/$A"
mkdir -p "$RUN_DIR" "$SANDBOX/outside"
INPUT="$RUN_DIR/decision-input.json"
addf() { # <input path>
  OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$MSG" decision add --team at --input "$1" --cwd "$SANDBOX" < /dev/null 2>"$SANDBOX/err"); RC=$?
  ERR=$(cat "$SANDBOX/err")
}
decided '{ question: "From a file?" }' > "$INPUT"
cp "$INPUT" "$SANDBOX/input.before"
addf "$INPUT"
check "W6 --input inside the run dir is appended" '[ $RC = 0 ] && [ "$(jget o.id)" = d1 ]'
check "W6 ... and the input file is left as it was" 'cmp -s "$INPUT" "$SANDBOX/input.before"'
before=$(sum)
decided '{ question: "From outside?" }' > "$SANDBOX/outside/in.json"
addf "$SANDBOX/outside/in.json"
AFTER=$(sum) BEFORE=$before
check "W6 a path outside the run dir is refused, nothing appended" '[ $RC = 2 ] && [[ "$(jget o.detail)" == *"must be inside"* ]] && [ "$AFTER" = "$BEFORE" ]'
ln -s "$SANDBOX/outside/in.json" "$RUN_DIR/link.json"
addf "$RUN_DIR/link.json"
AFTER=$(sum)
check "W6 a symlink in the run dir pointing outside it is refused" '[ $RC = 2 ] && [[ "$(jget o.detail)" == *"must be inside"* ]] && [ "$AFTER" = "$BEFORE" ]'
mkdir -p "$RUN_DIR/adir"
addf "$RUN_DIR/adir"
AFTER=$(sum)
check "W6 a directory is refused" '[ $RC = 2 ] && [[ "$(jget o.detail)" == *"not a regular file"* ]] && [ "$AFTER" = "$BEFORE" ]'
node -e 'const b=JSON.parse(process.argv[1]);b.rationale="x".repeat(70000);process.stdout.write(JSON.stringify(b))' "$(decided '{ question: "Too big?" }')" > "$RUN_DIR/big.json"
addf "$RUN_DIR/big.json"
AFTER=$(sum)
check "W6 a file over 64 KiB is refused" '[ $RC = 2 ] && [[ "$(jget o.detail)" == *"over 65536 bytes"* ]] && [ "$AFTER" = "$BEFORE" ]'
{ decided '{ question: "Two a?" }'; echo; decided '{ question: "Two b?" }'; } > "$RUN_DIR/two.json"
addf "$RUN_DIR/two.json"
AFTER=$(sum)
check "W6 two JSON objects are refused" '[ $RC = 2 ] && [[ "$(jget o.detail)" == *"must hold one JSON object"* ]] && [ "$AFTER" = "$BEFORE" ]'
AHOOK="$H/pretooluse-ah-cli.mjs"
allow_hook() {
  OUT=$(node -e 'process.stdout.write(JSON.stringify({ session_id: "s1", cwd: process.argv[2], tool_name: "Bash", tool_input: { command: process.argv[1] } }))' "$1" "$SANDBOX" \
    | HOME="$FAKEHOME" node "$AHOOK" 2>&1); RC=$?
}
allow_hook "node $H/msg.mjs decision add --team at --input $INPUT --cwd $SANDBOX"
check "W6 the ah-cli hook auto-allows the --input form" '[[ "$OUT" == *"\"permissionDecision\":\"allow\""* ]]'
allow_hook "node $H/msg.mjs decision add --team at --cwd $SANDBOX <<'EOF'
$(decided)
EOF"
check "W6 ... and not the heredoc form" '[[ "$OUT" != *"\"permissionDecision\":\"allow\""* ]]'

# ---------------------------------------------------------------- K skill anchors
# The skill's text with every whitespace run collapsed, so a phrase matches across a line wrap.
FLAT=$(tr -s ' \n\t' '   ' < "$SKILL")
kanchor() {
  P=$1
  check "K skill: $1" '[[ "$FLAT" == *"$P"* ]]'
}
kanchor "## Decisions on the user's behalf"
kanchor "Anything else is dangerous"
kanchor "**S1 Contained.**"
kanchor "**S2 Reversible on the branch.**"
kanchor "**S3 In scope.**"
kanchor "**S4 Not reserved.**"
kanchor "**D1 Destructive or irreversible:**"
kanchor "**D2 Remote and merge:**"
kanchor "**D3 Security and trust:**"
kanchor "**D4 Cost:**"
kanchor "**D5 Scope:**"
kanchor "**D6 The run's own rules:**"
kanchor "q<n> decision: a | b | c | d | other: <one line> | unsure | dangerous"
kanchor "**Never re-ask.**"
kanchor "### Log first, then apply"
kanchor "**Only on exit 0** route the answer"
kanchor '`cap` → add a `parked` line with `why_user: "cap"`'
kanchor '`parked-before` → add nothing'
kanchor 'a field refusal (`invalid`) → add a `parked` line with `why_user: "unsure"` and the refusal text as its `rationale`'
kanchor 'if that `parked` add is refused as well → stop the item'
kanchor "**the Orchestrator never decides in its own context.**"
kanchor '**`other:` in an issue run is always parked as `unsure`:**'
kanchor "**Nothing the run itself will execute changes.**"
kanchor "**No other ref:** no new branch, tag, worktree or stash."
kanchor "**Classification replaces none of them.**"
kanchor '`## Decisions made on your behalf`: this item'"'"'s lines'
kanchor '"guards: prose only (no conventions baseline)"'
kanchor "**Step 3a, decision authority**"
kanchor '"Ultra-Advisor decides (rest of session)"'
kanchor '"No Ultra-Advisor — top team member, else a fresh subagent on my model"'
kanchor "naming all five:"
kanchor "5. Who decides questions on the user's behalf"
kanchor '**"Decisions made on your behalf"**'
kanchor '**"Waiting for you":**'
kanchor '`needs-user` (a question parked for the user'
kanchor '**The `dec-` prefix is reserved:**'
kanchor "| a call that is properly the user's | § Decisions on the user's behalf |"
kanchor "The one exception is the decision log"
kanchor '**A plan run with no `--branch`** runs on `ah/pipeline-<stem>`'
kanchor 'every run of characters outside `[a-z0-9]` becomes one `-`; no `-` at either end; at most 40 characters, with no trailing `-` after the cut'
kanchor '`refs/remotes/origin/ah/pipeline-<stem>` already exists, halt and notify before any work**'
kanchor '`<root>/.claude/hierarchy/specs/acs-<YYYYMMDD-HHMM>.md`'
kanchor '`msg.mjs decision add --team <team> --input <hier>/pipeline/<anchor id>/decision-input.json --cwd <root>`'
kanchor 'write the line'"'"'s JSON with the Write tool'
kanchor 'subagent of type `general-purpose` on your own model'
kanchor '`decided-before` → add nothing'
DECIDER=$(sed -n '/^### The decider$/,/^### The brief$/p' "$SKILL")
check "K skill: the decider section offers no ah:orchestrator subagent" '[ -n "$DECIDER" ] && [[ "$DECIDER" != *"ah:orchestrator"* ]]'

echo
echo "SUMMARY: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
