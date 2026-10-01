#!/bin/bash
# agent-hierarchy — the /pipeline merge guard and auto-merge: the push guard's merge rules while a run
# is open, the pinned merge command's permission prompt and its caller check, merge-check against a
# fake gh, the PostToolUse merge record, pr.merge_method, and the skill text that drives it.
# HOME-redirected; every repo lives in a throwaway sandbox.
# Usage: bash tests/test-pipeline-merge.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
unset AH_TEAM_FILE CLAUDE_PID AGENT_HIERARCHY_DIR
HOOK="$PLUGIN/hooks/pretooluse-push-guard.mjs"
RECORD="$PLUGIN/hooks/posttooluse-merge-record.mjs"
MSG="$PLUGIN/hooks/msg.mjs"
SKILL="$PLUGIN/skills/autonomous-pipeline/SKILL.md"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-merge-test.XXXXXX")"
[ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
export HOME="$SANDBOX/home"
mkdir -p "$HOME/.claude"
export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git config --global init.defaultBranch main
git config --global advice.detachedHead false
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:400})"; fi
}

# <name> <conventions text, or empty for none>: a clone of a fresh bare origin, on main.
mkrepo() {
  git init -q --bare "$SANDBOX/$1-origin.git"
  git clone -q "$SANDBOX/$1-origin.git" "$SANDBOX/$1" 2>/dev/null
  mkdir -p "$SANDBOX/$1/sub"
  echo readme > "$SANDBOX/$1/README"
  [ -n "$2" ] && { mkdir -p "$SANDBOX/$1/.claude"; printf '%s' "$2" > "$SANDBOX/$1/.claude/ah-conventions.json"; }
  git -C "$SANDBOX/$1" add -A && git -C "$SANDBOX/$1" commit -qm init && git -C "$SANDBOX/$1" push -q origin main
  git -C "$SANDBOX/$1" remote set-head origin main
}
mkrepo repo ''
REPO="$SANDBOX/repo"
git -C "$REPO" branch ah/issue-5
SHA=$(git -C "$REPO" rev-parse ah/issue-5)
SHORT=${SHA:0:7}

jout() { node -e 'const o=JSON.parse(process.argv[1]);const v=(new Function("o","return ("+process.argv[2]+")"))(o);process.stdout.write(typeof v==="string"?v:JSON.stringify(v))' "$1" "$2" 2>/dev/null; }

# <slug> [constraint lines…]: an open request in the repo's hierarchy dir; its id lands in ID.
record() {
  local slug=$1; shift
  local made; made=$(node "$MSG" new --to orchestrator --from orchestrator --slug "$slug" --team at --cwd "$REPO")
  ID=$(jout "$made" o.id)
  local path; path=$(jout "$made" o.path)
  local lines=""
  for l in "$@"; do lines="$lines- $l\n"; done
  perl -0pi -e "s{(## \\[3\\] constraints\\n)}{\$1$lines}" "$path"
}
close_record() { # <id> <slug>
  node "$MSG" new --type response --id "$1" --to orchestrator --from orchestrator --slug "$2" --team at --cwd "$REPO" >/dev/null
}

# <merge-opt-in> [merge-method]: a fresh hierarchy dir holding one open run anchor; its id lands in A.
anchor() {
  rm -rf "$REPO/.claude/hierarchy"
  record pipeline-run-anchor "source: issues" "run-tag: ab12" "default-branch: main" "merge-opt-in: $1" "merge-method: ${2:-merge}"
  A=$ID
  LOG="$REPO/.claude/hierarchy/pipeline/$A/decisions.jsonl"
}

# <command> [js object of extra payload fields]: the push guard's answer in OUT.
guard() {
  OUT=$(node -e '
    const [d, c, x] = process.argv.slice(1);
    const p = { session_id: "s", hook_event_name: "PreToolUse", cwd: d, tool_name: "Bash", tool_input: { command: c } };
    process.stdout.write(JSON.stringify(Object.assign(p, (new Function("return (" + (x || "{}") + ")"))())));
  ' "$REPO" "$1" "$2" | node "$HOOK" 2>&1); RC=$?
}
decision() { jout "$OUT" "(o.hookSpecificOutput || {}).permissionDecision"; }
reason() { jout "$OUT" "(o.hookSpecificOutput || {}).permissionDecisionReason"; }
denied() { [ "$RC" -eq 0 ] && [ "$(decision)" = deny ] && [[ "$(reason)" == "ah-push-guard:$1 "* ]]; }
asked() { [ "$RC" -eq 0 ] && [ "$(decision)" = ask ]; }
allowed() { [ "$RC" -eq 0 ] && [ -z "$OUT" ]; }

PIN="gh pr merge 12 --match-head-commit $SHA --merge"
PIN_DRAFT="gh pr ready 12 && gh pr merge 12 --match-head-commit $SHA --merge"

# ---------------------------------------------------------------- G1 denies during a run
anchor yes
G1=(
  "PG-MERGE|gh pr merge 7"
  "PG-AUTOMERGE|gh pr merge 7 --auto"
  "PG-AUTOMERGE|gh pr merge 7 --admin"
  "PG-APPROVE|gh pr review 7 --approve"
  "PG-APPROVE|gh pr review 7 -a"
  "PG-READY|gh pr ready 7"
  "PG-API-MERGE|gh api -X PUT repos/o/r/pulls/7/merge"
  "PG-API-MERGE|gh api repos/o/r/pulls/7/reviews -f event=APPROVE"
  "PG-API-MERGE|gh api graphql -f query='mutation { mergePullRequest(input: {pullRequestId: \"x\"}) { clientMutationId } }'"
  "PG-API-MERGE|gh api graphql -f query='mutation { enablePullRequestAutoMerge(input: {pullRequestId: \"x\"}) { clientMutationId } }'"
  "PG-API-MERGE|gh api graphql -f query='mutation { markPullRequestReadyForReview(input: {pullRequestId: \"x\"}) { clientMutationId } }'"
  "PG-GIT-MERGE|git merge x"
  "PG-GIT-MERGE|git pull"
  "PG-MERGE|env X=1 gh pr merge 7"
  "PG-MERGE|bash -c \"gh pr merge 7\""
  "PG-MERGE|(cd sub && gh pr merge 7)"
)
for row in "${G1[@]}"; do
  RULE=${row%%|*} CMD=${row#*|}
  guard "$CMD"
  check "G1 during a run: deny $RULE — $CMD" 'denied "$RULE"'
done
guard "gh pr view 7"
check "G1 a read-only gh command passes during a run" 'allowed'
git -C "$REPO" checkout -q -b feat
guard "git merge x"
check "G1 git merge on the run's own branch passes" 'allowed'
git -C "$REPO" checkout -q main

# ---------------------------------------------------------------- G2 no run, no effect
rm -rf "$REPO/.claude/hierarchy"
for row in "${G1[@]}" "PG-MERGE|$PIN"; do
  CMD=${row#*|}
  guard "$CMD"
  check "G2 no open run: no deny — $CMD" 'allowed'
done

# ---------------------------------------------------------------- G3 ask
anchor yes
guard "$PIN"
check "G3 the pinned single form asks" 'asked'
check "G3 the reason holds the PR, the full sha and the summary line" '[[ "$(reason)" == *"PR #12"* ]] && [[ "$(reason)" == *"$SHA"* ]] && [[ "$(reason)" == *"decisions: 0 decided (0 flagged), 0 waiting for you"* ]] && [[ "$(reason)" == *"Decisions made on your behalf"* ]] && [[ "$(reason)" == *"Approve only if you want this merged now"* ]]'
guard "$PIN_DRAFT"
check "G3 the pinned compound form asks" 'asked'
guard "$PIN" '{ agent_type: "ah:orchestrator" }'
check "G3 a top-level --agent ah:orchestrator session gets the prompt" 'asked'

# ---------------------------------------------------------------- G4 form refusals
G4=(
  "PG-MERGE|gh pr merge 12 --merge"
  "PG-MERGE|gh pr merge 12 --match-head-commit $SHORT --merge"
  "PG-MERGE|gh pr merge 12 --match-head-commit $SHA --squash"
  "PG-MERGE|gh pr merge 12 --match-head-commit $SHA --merge --repo o/r"
  "PG-MERGE|gh pr merge 12 --match-head-commit $SHA --merge --delete-branch"
  "PG-MERGE|gh pr merge 12 --match-head-commit $SHA --merge --subject x"
  "PG-MERGE|gh pr merge 12 --match-head-commit $SHA --merge --body x"
  "PG-AUTOMERGE|gh pr merge 12 --match-head-commit $SHA --merge --auto"
  "PG-AUTOMERGE|gh pr merge 12 --match-head-commit $SHA --merge --admin"
  "PG-READY|gh pr ready 11 && gh pr merge 12 --match-head-commit $SHA --merge"
)
for row in "${G4[@]}"; do
  RULE=${row%%|*} CMD=${row#*|}
  guard "$CMD"
  check "G4 deny $RULE — $CMD" 'denied "$RULE"'
done
anchor no
guard "$PIN"
check "G4 merge-opt-in: no → deny PG-MERGE" 'denied PG-MERGE'
anchor yes squash
guard "$PIN"
check "G4 a method other than the run's → deny PG-MERGE" 'denied PG-MERGE'

# ---------------------------------------------------------------- G5 callers
anchor yes
guard "$PIN" '{ agent_id: "a1", agent_type: "general-purpose" }'
check "G5 a subagent (agent_id present) → PG-MERGE-ROLE" 'denied PG-MERGE-ROLE'
guard "$PIN" '{ agent_id: "a1" }'
check "G5 agent_id alone → PG-MERGE-ROLE" 'denied PG-MERGE-ROLE'
guard "$PIN" '{ agent_type: "ah:implementor" }'
check "G5 agent_type ah:implementor → PG-MERGE-ROLE" 'denied PG-MERGE-ROLE'
printf '{"version":1,"sessions":{"s":{"role":"implementor","at":"2026-01-01T00:00:00Z"}}}\n' > "$HOME/.claude/agent-hierarchy.session-roles.json"
guard "$PIN"
check "G5 a persisted implementor role with no agent_type → PG-MERGE-ROLE" 'denied PG-MERGE-ROLE'
rm -f "$HOME/.claude/agent-hierarchy.session-roles.json"
guard "$PIN" '{ agent_type: "general-purpose" }'
check "G5 a non-ah agent_type → PG-MERGE-ROLE" 'denied PG-MERGE-ROLE'

# ---------------------------------------------------------------- C1 merge-check
mkdir -p "$SANDBOX/bin" "$SANDBOX/fix"
cat > "$SANDBOX/bin/gh" <<'EOF'
#!/usr/bin/env node
const fs = require("fs");
const a = process.argv.slice(2);
const send = (f) => {
  try { process.stdout.write(fs.readFileSync(`${process.env.FAKE_GH_DIR}/${f}`, "utf8")); } catch { process.stderr.write(`no fixture ${f}\n`); process.exit(1); }
};
if (a[0] === "pr" && a[1] === "view") send(`view-${a[2]}.json`);
else if (a[0] === "pr" && a[1] === "list") send(`list-${a[a.indexOf("--head") + 1].replace(/\//g, "_")}.json`);
else if (a[0] === "api" && a[1] === "graphql") send(`threads-${a.find((x) => x.startsWith("number=")).slice(7)}.json`);
else process.exit(1);
EOF
chmod +x "$SANDBOX/bin/gh"
FIX="$SANDBOX/fix"
BASE_VIEW="{\"state\":\"OPEN\",\"isDraft\":false,\"headRefName\":\"ah/issue-5\",\"headRefOid\":\"$SHA\",\"baseRefName\":\"main\",\"mergeable\":\"MERGEABLE\",\"mergeStateStatus\":\"CLEAN\",\"reviewDecision\":\"APPROVED\",\"statusCheckRollup\":[{\"__typename\":\"CheckRun\",\"status\":\"COMPLETED\",\"conclusion\":\"SUCCESS\"},{\"__typename\":\"StatusContext\",\"state\":\"SUCCESS\"}]}"
BASE_THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":1,"nodes":[{"isResolved":true}]}}}}}'

# A run whose item 5 is planned, signed off and has no exception, with PR #12 open and clean.
item_run() { # [merge-opt-in] [depends-on]
  anchor "${1:-yes}"
  record ab12-i5 "issue: 5" "branch: ah/issue-5" "depends-on: ${2:-none}"
  record ab12-i5-ok; close_record "$ID" ab12-i5-ok
  printf '%s' "$BASE_VIEW" > "$FIX/view-12.json"
  printf '%s' "$BASE_THREADS" > "$FIX/threads-12.json"
}
# [js statement over the view v] [js statement over the threads t]: merge-check --pr 12.
mc() {
  [ -n "$1" ] && node -e 'const f=process.argv[1];const v=JSON.parse(require("fs").readFileSync(f,"utf8"));(new Function("v",process.argv[2]))(v);require("fs").writeFileSync(f,JSON.stringify(v))' "$FIX/view-12.json" "$1"
  [ -n "$2" ] && node -e 'const f=process.argv[1];const t=JSON.parse(require("fs").readFileSync(f,"utf8"));(new Function("t",process.argv[2]))(t.data.repository.pullRequest.reviewThreads);require("fs").writeFileSync(f,JSON.stringify(t))' "$FIX/threads-12.json" "$2"
  OUT=$(PATH="$SANDBOX/bin:$PATH" FAKE_GH_DIR="$FIX" node "$HOOK" merge-check --pr 12 --cwd "$REPO" 2>&1); RC=$?
}
has_reason() { [ "$RC" = 0 ] && [ "$(jout "$OUT" o.ok)" = false ] && jout "$OUT" "o.reasons.join(\" \")" | tr ' ' '\n' | grep -qx "$1"; }

item_run
snap() { (cd "$SANDBOX" && find home repo -type f -print0 | sort -z | xargs -0 shasum); }
BEFORE=$(snap)
mc
check "C1 all good → ok with the exact command" '[ "$RC" = 0 ] && [ "$(jout "$OUT" o.ok)" = true ] && [ "$(jout "$OUT" o.command)" = "$PIN" ] && [ "$(jout "$OUT" o.sha)" = "$SHA" ] && [ "$(jout "$OUT" o.method)" = merge ]'
AFTER=$(snap)
check "C1 merge-check writes no file" '[ "$AFTER" = "$BEFORE" ]'
mc 'v.isDraft = true; v.mergeStateStatus = "DRAFT"'
check "C1 a draft → ok with the compound command" '[ "$(jout "$OUT" o.ok)" = true ] && [ "$(jout "$OUT" o.command)" = "$PIN_DRAFT" ]'

rm -rf "$REPO/.claude/hierarchy"; printf '%s' "$BASE_VIEW" > "$FIX/view-12.json"
mc
check "C1 no open run → no-run" 'has_reason no-run'
item_run no
mc
check "C1 merge-opt-in: no → off" 'has_reason off'
item_run
mc 'v.headRefName = "ah/issue-9"'
check "C1 a head with no item record in this run → not-this-run" 'has_reason not-this-run'
anchor yes; record ab12-i5 "issue: 5" "branch: ah/issue-5" "depends-on: none"; record ab12-i5-ok
printf '%s' "$BASE_VIEW" > "$FIX/view-12.json"
mc
check "C1 no Architect sign-off → not-signed-off" 'has_reason not-signed-off'
item_run; record ab12-i5-x "exception: red-build failing tests"
mc
check "C1 an open exception record → exception" 'has_reason exception'
item_run
mc 'v.state = "CLOSED"'
check "C1 a closed PR → closed" 'has_reason closed'
item_run
mc 'v.headRefOid = "1111111111111111111111111111111111111111"'
check "C1 a head that isn't the local signed-off tip → head-moved" 'has_reason head-moved'
item_run yes 3
printf '[{"number":11,"state":"OPEN"}]' > "$FIX/list-ah_issue-3.json"
mc
check "C1 a dependent whose base PR isn't merged → stacked-base-open" 'has_reason stacked-base-open'
printf '[{"number":11,"state":"MERGED"}]' > "$FIX/list-ah_issue-3.json"
mc
check "C1 ... and not once the base PR merged" '! has_reason stacked-base-open'
item_run
mc 'v.baseRefName = "ah/issue-3"'
check "C1 a base other than the default branch → base-not-default" 'has_reason base-not-default'
item_run
mc 'v.mergeable = "CONFLICTING"'
check "C1 a conflicting PR → not-mergeable:CONFLICTING" 'has_reason not-mergeable:CONFLICTING'
item_run
mc 'v.mergeStateStatus = "BLOCKED"'
check "C1 a blocked PR → not-mergeable:BLOCKED" 'has_reason not-mergeable:BLOCKED'
item_run
mc 'v.statusCheckRollup = []'
check "C1 no checks → no-checks" 'has_reason no-checks'
item_run
mc 'v.statusCheckRollup[0].status = "IN_PROGRESS"; v.statusCheckRollup[0].conclusion = null'
check "C1 a running check → checks-pending" 'has_reason checks-pending'
item_run
mc 'v.statusCheckRollup[1].state = "PENDING"'
check "C1 a pending status → checks-pending" 'has_reason checks-pending'
item_run
mc 'v.statusCheckRollup[0].conclusion = "FAILURE"'
check "C1 a failed check → checks-failed" 'has_reason checks-failed'
item_run
mc 'v.reviewDecision = "CHANGES_REQUESTED"'
check "C1 changes requested → changes-requested" 'has_reason changes-requested'
item_run
mc '' 't.nodes.push({ isResolved: false }); t.totalCount = 2'
check "C1 an unresolved review thread → unresolved-threads" 'has_reason unresolved-threads'
item_run
mc '' 't.totalCount = 101'
check "C1 more than 100 threads → unresolved-threads" 'has_reason unresolved-threads'

# ---------------------------------------------------------------- R1 the merge record
anchor yes
post() { # <command>
  node -e 'const [d,c]=process.argv.slice(1);process.stdout.write(JSON.stringify({session_id:"s",hook_event_name:"PostToolUse",cwd:d,tool_name:"Bash",tool_input:{command:c},tool_response:{stdout:"",stderr:""}}))' "$REPO" "$1" | node "$RECORD"
}
post "$PIN"
check "R1 the pinned merge command appends one merge line" '[ -f "$LOG" ] && [ "$(wc -l < "$LOG" | tr -d " ")" = 1 ] && node -e "const l=JSON.parse(require(\"fs\").readFileSync(process.argv[1],\"utf8\").trim());process.exit(l.kind===\"merge\"&&l.pr===12&&l.sha===process.argv[2]&&l.method===\"merge\"&&l.approval===\"permission prompt\"&&!(\"id\" in l)&&!isNaN(Date.parse(l.time))?0:1)" "$LOG" "$SHA"'
post "gh pr view 12"
post "gh pr merge 12"
post "git status"
check "R1 no line for any other Bash command" '[ "$(wc -l < "$LOG" | tr -d " ")" = 1 ]'
OUT=$(printf '%s' '{"kind":"merge","pr":12,"sha":"x","method":"merge"}' | node "$MSG" decision add --team at --cwd "$REPO" 2>/dev/null); RC=$?
check "R1 msg.mjs decision add refuses kind merge" '[ "$RC" = 2 ] && [[ "$(jout "$OUT" o.detail)" == *"merge record hook"* ]] && [ "$(wc -l < "$LOG" | tr -d " ")" = 1 ]'

# ---------------------------------------------------------------- V1 pr.merge_method
mkrepo v1a '{"version":1,"pr":{"merge_method":"squash"}}'
mkrepo v1b '{"version":1}'
mkrepo v1c '{"version":1,"pr":{"merge_method":"fast"}}'
OUT=$(node "$HOOK" check --branch HEAD --cwd "$SANDBOX/v1a"); RC=$?
check "V1 check prints pr.merge_method" '[ "$(jout "$OUT" o.settings.pr.merge_method)" = squash ]'
OUT=$(node "$HOOK" check --branch HEAD --cwd "$SANDBOX/v1b"); RC=$?
check "V1 pr.merge_method defaults to merge" '[ "$(jout "$OUT" o.settings.pr.merge_method)" = merge ]'
OUT=$(node "$HOOK" check --branch HEAD --cwd "$SANDBOX/v1c"); RC=$?
check "V1 an unknown pr.merge_method makes the conventions invalid" '[[ "$(jout "$OUT" o.conventions)" == "invalid: \`pr.merge_method\` must be"* ]]'

# ---------------------------------------------------------------- K skill anchors
FLAT=$(tr -s ' \n\t' '   ' < "$SKILL")
kanchor() {
  P=$1
  check "K skill: $1" '[[ "$FLAT" == *"$P"* ]]'
}
kanchor '`--auto-merge` on an issue run, or plain language with the same meaning ("auto-merge approved for this run", "with auto-merge", "and merge them once I approve")'
kanchor '"May this run merge a ready PR once you approve that merge in a permission prompt?", with "No" first, as the default, then "Yes, for this run"'
kanchor '"auto-merge needs an issue run — plan runs open no PR"'
kanchor '"Auto-merge APPROVED for this run: at the end of the run the orchestrator asks you to approve each ready PR'"'"'s merge in a permission prompt — one click per merge, pinned to the PR'"'"'s head commit."'
kanchor '"Auto-merge: off — a person merges."'
kanchor '"Opened by an ah /pipeline run (anchor `<id>`). This run may merge it at the end of the run, but only after you approve that merge in a permission prompt; otherwise a person merges."'
kanchor '**"Merge approvals are waiting for you in the session"**, once, before the first merge prompt'
kanchor 'Notify once: "Merge approvals are waiting for you in the session".'
kanchor '**The merge point is once only, at the end of the run:**'
kanchor '`gh pr merge <N> --match-head-commit <sha> --<method>`, or for a draft `gh pr ready <N> && gh pr merge <N> --match-head-commit <sha> --<method>`'
kanchor '**"Merges performed under your authorisation"**'
kanchor '**"Not merged"**'
kanchor 'or edit a PR the run didn'"'"'t open — except § Merge on your approval.'
kanchor '"head moved or merge refused", with gh'"'"'s own message verbatim'
kanchor 'A merge done under the user'"'"'s own per-run merge authorisation (§ Merge on your approval) is not a decision'

echo
echo "SUMMARY: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
