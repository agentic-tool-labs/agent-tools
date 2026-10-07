#!/bin/bash
# agent-hierarchy — the /pipeline merge guard and auto-merge: the push guard's merge rules while a run
# is open, the GitHub MCP merge rule, the pinned merge command's permission prompt and its caller
# check, merge-check and the branch-protection check against a fake gh, the PostToolUse merge record,
# pr.merge_method, and the skill text that drives it.
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

# <command> [js object of extra payload fields] [session cwd]: the push guard's answer in OUT. The
# payload carries permission_mode auto, as a pipeline run's does; GUARD overrides the hook.
guard() {
  OUT=$(node -e '
    const [d, c, x] = process.argv.slice(1);
    const p = { session_id: "s", hook_event_name: "PreToolUse", cwd: d, permission_mode: "auto", tool_name: "Bash", tool_input: { command: c } };
    process.stdout.write(JSON.stringify(Object.assign(p, (new Function("return (" + (x || "{}") + ")"))())));
  ' "${3:-$REPO}" "$1" "$2" | node "${GUARD:-$HOOK}" 2>&1); RC=$?
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
  "PG-MERGE|env X=1 gh pr merge 7"
  "PG-MERGE|bash -c \"gh pr merge 7\""
  "PG-MERGE|(cd sub && gh pr merge 7)"
  "PG-MERGE|gh pr -R o/r merge 7"
  "PG-MERGE|gh pr --repo o/r merge 7"
  "PG-MERGE|gh -R o/r pr merge 7"
  "PG-APPROVE|gh pr --repo=o/r review 7 --approve"
  "PG-READY|gh pr -R o/r ready 7"
  "PG-READY|gh pr -Ro/r ready 7"
  "PG-API-MERGE|gh api repos/o/r/merges -f base=main -f head=x"
  "PG-API-MERGE|gh api -X PATCH repos/o/r/git/refs/heads/main -f sha=$SHA"
  "PG-API-MERGE|gh api repos/o/r/git/refs -f ref=refs/heads/x -f sha=$SHA"
  "PG-API-MERGE|gh api graphql -f query='mutation { mergeBranch(input: {repositoryId: \"x\", base: \"main\", head: \"x\"}) { clientMutationId } }'"
  "PG-API-MERGE|gh api graphql -F query=@q.graphql"
  "PG-API-MERGE|gh api graphql -Fquery=@q.graphql"
  "PG-API-MERGE|gh api graphql --field=query=@q.graphql"
  "PG-API-MERGE|gh api graphql --raw-field=query=@q.graphql"
  "PG-API-MERGE|gh api graphql --input q.json"
  "PG-API-MERGE|gh api graphql --input=q.json"
  "PG-READY|gh -R o/r pr ready 7"
)
for row in "${G1[@]}"; do
  RULE=${row%%|*} CMD=${row#*|}
  guard "$CMD"
  check "G1 during a run: deny $RULE — $CMD" 'denied "$RULE"'
done
guard "gh pr view 7"
check "G1 a read-only gh command passes during a run" 'allowed'
guard "gh api repos/o/r/git/refs/heads/main"
check "G1 a GET of git/refs passes during a run" 'allowed'
guard "cd $REPO && gh pr merge 7" '{}' "$SANDBOX"
check "G1 from a session outside the repo, cd into the run's repo then merge → PG-MERGE" 'denied PG-MERGE'

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
AH_TEAM_FILE="$SANDBOX/member/.claude/hierarchy/team.json" guard "$PIN"
check "G3 the same pinned merge in a member session is a deny, not a prompt, carrying the member tail" '[ "$RC" -eq 0 ] && [ "$(decision)" = deny ] && [[ "$(reason)" == *"does not ask here"* ]] && [[ "$(reason)" == *"PR #12"* ]]'

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

# ---------------------------------------------------------------- G4b permission mode
anchor yes
for mode in bypassPermissions dontAsk; do
  guard "$PIN" "{ permission_mode: \"$mode\" }"
  check "G4b permission_mode $mode → PG-MERGE" 'denied PG-MERGE'
done
guard "$PIN" '{ permission_mode: undefined }'
check "G4b no permission_mode → PG-MERGE" 'denied PG-MERGE'
guard "$PIN" '{ permission_mode: "auto" }'
check "G4b permission_mode auto → ask" 'asked'

# ---------------------------------------------------------------- G4c no credentials in the prompt
ORIGIN_URL=$(git -C "$REPO" config --get remote.origin.url)
git -C "$REPO" config remote.origin.url "https://u:tok@github.com/o/r.git"
guard "$PIN"
check "G4c the prompt names the repo without the URL's credentials" 'asked && [[ "$(reason)" == *"github.com/o/r"* ]] && [[ "$(reason)" != *"tok"* ]]'
git -C "$REPO" config remote.origin.url "$ORIGIN_URL"

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

# ---------------------------------------------------------------- G6 fail closed on merge forms only
anchor yes
mkdir -p "$LOG"
guard "$PIN"
check "G6 the pinned form with the decision log unreadable → PG-MERGE-ERROR, never ask" 'denied PG-MERGE-ERROR'
rm -rf "$LOG"
# A copy of the hooks whose runLiveness throws.
mkdir -p "$SANDBOX/stub"
cp -R "$PLUGIN/hooks" "$SANDBOX/stub/hooks"
perl -0pi -e 's/(export function runLiveness\(cwd\) \{\n)/$1  throw new Error("stubbed liveness failure");\n/' "$SANDBOX/stub/hooks/lib-decisions.mjs"
grep -q 'stubbed liveness failure' "$SANDBOX/stub/hooks/lib-decisions.mjs" || { echo "G6 stub didn't apply"; exit 1; }
GUARD="$SANDBOX/stub/hooks/pretooluse-push-guard.mjs"
guard "gh pr merge 7"
check "G6 a merge form when liveness throws → PG-MERGE-ERROR" 'denied PG-MERGE-ERROR && [[ "$(reason)" == *"stubbed liveness failure"* ]]'
for CMD in "ls" "git push origin ah/issue-5" "git push origin HEAD:main" "git merge x" "gh pr view 7" "gh pr view 7 --json mergeable" "gh pr list --search merge" "gh pr checks 7" "gh api repos/o/r/pulls/7"; do
  guard "$CMD"
  check "G6 not a merge form, same throw → no output — $CMD" 'allowed'
done
# A second copy whose command parser throws, so every command reaches the error path with a run live.
mkdir -p "$SANDBOX/stub2"
cp -R "$PLUGIN/hooks" "$SANDBOX/stub2/hooks"
perl -0pi -e 's/(\nfunction gitInvocations\(events, state, root, out = \[\], ghOut = \[\]\) \{\n)/$1  throw new Error("stubbed parse failure");\n/' "$SANDBOX/stub2/hooks/pretooluse-push-guard.mjs"
grep -q 'stubbed parse failure' "$SANDBOX/stub2/hooks/pretooluse-push-guard.mjs" || { echo "G6 parser stub didn't apply"; exit 1; }
GUARD="$SANDBOX/stub2/hooks/pretooluse-push-guard.mjs"
for CMD in "gh pr merge 7" "gh pr review 7 --approve" "gh pr ready 7" "gh api -X PUT repos/o/r/pulls/7/merge" "gh api graphql -F query=@q.graphql" "$PIN"; do
  guard "$CMD"
  check "G6 a merge form when the parser throws → PG-MERGE-ERROR — $CMD" 'denied PG-MERGE-ERROR && [[ "$(reason)" == *"stubbed parse failure"* ]]'
done
for CMD in "git merge x" "git pull" "git push origin HEAD:main" "git checkout main && git merge ah/issue-5 && git push" "gh pr view 7" "gh pr view 7 --json mergeable" "gh pr list --search merge" "gh pr checks 7" "gh api repos/o/r/pulls/7"; do
  guard "$CMD"
  check "G6 not a merge form, parser throws → no output — $CMD" 'allowed'
done
unset GUARD
for dir in "$REPO/.claude/hierarchy" "$REPO/.claude"; do
  chmod 000 "$dir"
  guard "gh pr merge 7"
  check "G6 ${dir#$SANDBOX/} unreadable is unknown liveness: a merge → PG-MERGE-ERROR" 'denied PG-MERGE-ERROR'
  guard "gh pr view 7"
  check "G6 ... while a read passes" 'allowed'
  chmod 755 "$dir"
done
rm -rf "$REPO/.claude/hierarchy"
guard "$PIN"
check "G6 no run live → no output" 'allowed'

# ---------------------------------------------------------------- G7 GitHub MCP tools
MCP="$PLUGIN/hooks/pretooluse-mcp-guard.mjs"
mcp() { # <tool name> [js object of tool input]: the MCP guard's answer in OUT; MGUARD overrides the hook.
  OUT=$(node -e '
    const [d, n, x] = process.argv.slice(1);
    process.stdout.write(JSON.stringify({ session_id: "s", hook_event_name: "PreToolUse", cwd: d, permission_mode: "auto", tool_name: n, tool_input: (new Function("return (" + (x || "{}") + ")"))() }));
  ' "$REPO" "$1" "$2" | node "${MGUARD:-$MCP}" 2>&1); RC=$?
}
G7_DENY=(
  'mcp__plugin_github-pr-toolkit_github__merge_pull_request|{ owner: "o", repo: "r", pullNumber: 7 }'
  'mcp__github__merge_pull_request|{ owner: "o", repo: "r", pullNumber: 7, merge_method: "squash" }'
  'mcp__GitHub__merge_pull_request|{ pullNumber: 7 }'
  'mcp__github__pull_request_review_write|{ method: "create", pullNumber: 7, event: "APPROVE" }'
  'mcp__github__submit_pending_pull_request_review|{ review: { event: "approve" } }'
  'mcp__github__update_pull_request|{ pullNumber: 7, draft: false }'
)
G7_PASS=(
  'mcp__github__pull_request_review_write|{ method: "create", pullNumber: 7, event: "COMMENT", body: "approve this?" }'
  'mcp__github__update_pull_request|{ pullNumber: 7, title: "x" }'
  'mcp__github__update_pull_request|{ pullNumber: 7, draft: true }'
  'mcp__github__create_pull_request|{ title: "x", head: "ah/issue-5", base: "main" }'
  'mcp__github__pull_request_read|{ method: "get", pullNumber: 7 }'
  'mcp__blender__get_scene_info|{}'
  'mcp__blender__merge_objects|{ event: "APPROVE" }'
)
anchor yes
for row in "${G7_DENY[@]}"; do
  mcp "${row%%|*}" "${row#*|}"
  check "G7 during a run: deny PG-MCP-MERGE — $row" 'denied PG-MCP-MERGE'
done
for row in "${G7_PASS[@]}"; do
  mcp "${row%%|*}" "${row#*|}"
  check "G7 during a run: no output — $row" 'allowed'
done
MGUARD="$SANDBOX/stub/hooks/pretooluse-mcp-guard.mjs"
mcp mcp__github__merge_pull_request '{ pullNumber: 7 }'
check "G7 a merge tool when liveness throws → PG-MERGE-ERROR" 'denied PG-MERGE-ERROR && [[ "$(reason)" == *"stubbed liveness failure"* ]]'
mcp mcp__github__pull_request_read '{ pullNumber: 7 }'
check "G7 a read, same throw → no output" 'allowed'
unset MGUARD
chmod 000 "$REPO/.claude/hierarchy"
mcp mcp__github__merge_pull_request '{ pullNumber: 7 }'
check "G7 an unreadable hierarchy dir: a merge tool → PG-MERGE-ERROR" 'denied PG-MERGE-ERROR'
chmod 755 "$REPO/.claude/hierarchy"
rm -rf "$REPO/.claude/hierarchy"
for row in "${G7_DENY[@]}"; do
  mcp "${row%%|*}" "${row#*|}"
  check "G7 no open run: no output — $row" 'allowed'
done

# ---------------------------------------------------------------- G8 no git command is denied by a run rule
G8=(
  "git push origin HEAD:main"
  "git push origin ah/issue-5:main"
  "git push --all origin"
  "git checkout main && git merge ah/issue-5 && git push"
  "git merge x"
  "git pull"
)
anchor yes
for CMD in "${G8[@]}"; do
  guard "$CMD"
  check "G8 during a run, repo not opted in: no output — $CMD" 'allowed'
done
git -C "$REPO" remote set-head origin -d
for CMD in "git push origin HEAD:main" "git push origin HEAD:master"; do
  guard "$CMD"
  check "G8 ... and with no origin/HEAD — $CMD" 'allowed'
done
git -C "$REPO" remote set-head origin main
mkrepo g8 '{"version":1}'
G8R="$SANDBOX/g8"
NORUN=()
for CMD in "${G8[@]}" "git push --force origin ah/issue-5" "git push origin ah/issue-5"; do
  guard "$CMD" '{}' "$G8R"; NORUN+=("$RC|$OUT")
done
REPO="$G8R" anchor yes
i=0
for CMD in "${G8[@]}" "git push --force origin ah/issue-5" "git push origin ah/issue-5"; do
  guard "$CMD" '{}' "$G8R"
  check "G8 opted-in repo: the push rules answer the same with a run open — $CMD" '[ "$RC|$OUT" = "${NORUN[$i]}" ]'
  i=$((i+1))
done
check "G8 ... and they do deny a push to the default branch" '[[ "${NORUN[0]}" == *"permissionDecision\":\"deny"* ]]'
chmod 000 "$G8R/.claude/hierarchy"
guard "gh pr view 7 && git push --force origin ah/issue-5" '{}' "$G8R"
check "G8 opted-in repo, liveness unknown: a read plus a force push → PG-FORCE" 'denied PG-FORCE'
guard "gh pr 'merge' 7" '{}' "$G8R"
check "G8 opted-in repo, liveness unknown: a quoted merge verb → PG-MERGE-ERROR" 'denied PG-MERGE-ERROR'
chmod 755 "$G8R/.claude/hierarchy"
GUARD="$SANDBOX/stub/hooks/pretooluse-push-guard.mjs"
guard "gh pr view 7 && git push --force origin ah/issue-5" '{}' "$G8R"
check "G8 opted-in repo, liveness throws: a read plus a force push → PG-FORCE" 'denied PG-FORCE'
unset GUARD
rm -rf "$G8R/.claude/hierarchy"
anchor yes

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
else if (a[0] === "api" && a[1].endsWith("/protection")) send("protection.json");
else if (a[0] === "api" && a[1].includes("/rules/branches/")) send("rules.json");
else if (a[0] === "api" && a[1].includes("/branches/")) send("branch.json");
else process.exit(1);
EOF
chmod +x "$SANDBOX/bin/gh"
FIX="$SANDBOX/fix"
BASE_VIEW="{\"state\":\"OPEN\",\"isDraft\":false,\"headRefName\":\"ah/issue-5\",\"headRefOid\":\"$SHA\",\"baseRefName\":\"main\",\"mergeable\":\"MERGEABLE\",\"mergeStateStatus\":\"CLEAN\",\"reviewDecision\":\"APPROVED\",\"statusCheckRollup\":[{\"__typename\":\"CheckRun\",\"status\":\"COMPLETED\",\"conclusion\":\"SUCCESS\"},{\"__typename\":\"StatusContext\",\"state\":\"SUCCESS\"}]}"
BASE_THREADS='{"data":{"repository":{"pullRequest":{"reviewThreads":{"totalCount":1,"nodes":[{"isResolved":true}]}}}}}'

# The Architect's sign-off on item 5: an -ok request addressed to the Architect, answered with a report.
signoff() {
  local id; id=$(jout "$(node "$MSG" new --to architect --from orchestrator --slug ab12-i5-ok --team at --cwd "$REPO")" o.id)
  local resp; resp=$(jout "$(node "$MSG" new --type response --id "$id" --to orchestrator --from architect --slug ab12-i5-ok --team at --cwd "$REPO")" o.path)
  printf -- '- signed off: review and evidence hold\n' >> "$resp"
}
# A run whose item 5 is planned, signed off and has no exception, with PR #12 open and clean.
item_run() { # [merge-opt-in] [depends-on]
  anchor "${1:-yes}"
  record ab12-i5 "issue: 5" "branch: ah/issue-5" "depends-on: ${2:-none}"
  signoff
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
item_run yes; anchor yes fast; record ab12-i5 "issue: 5" "branch: ah/issue-5" "depends-on: none"; signoff
mc
check "C1 no valid merge-method → no-method" 'has_reason no-method && ! has_reason off'
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
close_record "$ID" ab12-i5-x
mc
check "C1 an exception record closed by a bodyless response → no exception" '[ "$RC" = 0 ] && ! has_reason exception'
# The sign-off as the pipeline dispatches it: a request to the Architect, whose response must hold a report.
anchor yes; record ab12-i5 "issue: 5" "branch: ah/issue-5" "depends-on: none"
OK_ID=$(jout "$(node "$MSG" new --to architect --from orchestrator --slug ab12-i5-ok --team at --cwd "$REPO")" o.id)
OK_RESP=$(jout "$(node "$MSG" new --type response --id "$OK_ID" --to orchestrator --from architect --slug ab12-i5-ok --team at --cwd "$REPO")" o.path)
printf '%s' "$BASE_VIEW" > "$FIX/view-12.json"; printf '%s' "$BASE_THREADS" > "$FIX/threads-12.json"
mc
check "C1 an Architect -ok answered by a skeleton response → not-signed-off" 'has_reason not-signed-off'
printf -- '- signed off: review and evidence hold\n' >> "$OK_RESP"
mc
check "C1 the same -ok once its response holds a report → no not-signed-off" '[ "$RC" = 0 ] && [ -n "$OK_RESP" ] && ! has_reason not-signed-off'
# Only a member-addressed -ok signs off: an -ok the Orchestrator addressed to itself never does.
anchor yes; record ab12-i5 "issue: 5" "branch: ah/issue-5" "depends-on: none"; record ab12-i5-ok; close_record "$ID" ab12-i5-ok
OK_RESP=$(ls "$REPO/.claude/hierarchy/msgs/"*--ab12-i5-ok--response.md 2>/dev/null | head -1)
printf '%s' "$BASE_VIEW" > "$FIX/view-12.json"; printf '%s' "$BASE_THREADS" > "$FIX/threads-12.json"
mc
check "C1 an orchestrator-addressed -ok closed by a bodyless response → not-signed-off" '[ -n "$OK_RESP" ] && has_reason not-signed-off'
printf -- '- signed off\n' >> "$OK_RESP"
mc
check "C1 the same orchestrator-addressed -ok with a filled response → not-signed-off" 'has_reason not-signed-off'
item_run
mc
check "C1 an Architect-addressed -ok with a filled response → no not-signed-off" '[ "$RC" = 0 ] && [ "$(jout "$OUT" o.ok)" = true ]'
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

# ---------------------------------------------------------------- P1 branch-protection check
prot() { # [cwd]
  OUT=$(PATH="$SANDBOX/bin:$PATH" FAKE_GH_DIR="$FIX" node "$HOOK" protection --cwd "${1:-$REPO}" 2>&1); RC=$?
}
OFF_LINE="Branch protection on \`main\`: OFF — GitHub won't stop a push or a merge to it. See the README's /pipeline section."
WEAK_LINE() { echo "Branch protection on \`main\`: on, but $1 — a direct push can still land. See the README's /pipeline section."; }
# <branch.json or -> <rules.json or -> <protection.json or ->: fixtures for the three reads; - makes that read fail.
pfix() {
  rm -f "$FIX/branch.json" "$FIX/rules.json" "$FIX/protection.json"
  [ "$1" != - ] && printf '%s' "$1" > "$FIX/branch.json"
  [ "$2" != - ] && printf '%s' "$2" > "$FIX/rules.json"
  [ "$3" != - ] && printf '%s' "$3" > "$FIX/protection.json"
  prot
}
PROT='{"name":"main","protected":true}'
UNPROT='{"name":"main","protected":false}'
PR_RULE='[{"type":"deletion"},{"type":"pull_request","parameters":{}}]'
BEFORE=$(snap)
pfix "$UNPROT" "$PR_RULE" -
check "P1 not protected, but a ruleset requires a pull request → on" '[ "$RC" = 0 ] && [ "$OUT" = "Branch protection on \`main\`: on." ]'
pfix "$PROT" "$PR_RULE" -
check "P1 protected, a pull_request rule, the protection read failing → on (step 3 not needed)" '[ "$RC" = 0 ] && [ "$OUT" = "Branch protection on \`main\`: on." ]'
pfix "$UNPROT" '[{"type":"deletion"}]' -
check "P1 no pull-request rule → the OFF line, exit 0" '[ "$RC" = 0 ] && [ "$OUT" = "$OFF_LINE" ]'
pfix "$UNPROT" '[]' -
check "P1 no rules at all → the OFF line" '[ "$RC" = 0 ] && [ "$OUT" = "$OFF_LINE" ]'
pfix "$PROT" '[]' '{"required_pull_request_reviews":{"required_approving_review_count":1},"enforce_admins":{"enabled":true}}'
check "P1 classic protection requiring a PR, admins enforced → on" '[ "$RC" = 0 ] && [ "$OUT" = "Branch protection on \`main\`: on." ]'
pfix "$PROT" '[]' '{"required_pull_request_reviews":{"required_approving_review_count":1},"enforce_admins":{"enabled":false}}'
check "P1 ... with admins not enforced → the weak line, admins can bypass it" '[ "$RC" = 0 ] && [ "$OUT" = "$(WEAK_LINE "admins can bypass it, and the run uses your token")" ]'
pfix "$PROT" '[]' '{"required_status_checks":{"strict":true,"contexts":["ci"]},"enforce_admins":{"enabled":true}}'
check "P1 classic protection with only status checks → the weak line, no pull request required" '[ "$RC" = 0 ] && [ "$OUT" = "$(WEAK_LINE "it doesn'"'"'t require a pull request")" ]'
pfix "$PROT" '[]' -
check "P1 protected, no rules, the protection read failing → unknown, classic settings unreadable" '[ "$RC" = 0 ] && [[ "$OUT" == "Branch protection on \`main\`: unknown (classic protection'"'"'s settings aren'"'"'t readable: "*")." ]]'
pfix "$UNPROT" - -
check "P1 gh failing on the rules → unknown, exit 0" '[ "$RC" = 0 ] && [[ "$OUT" == "Branch protection on \`main\`: unknown ("*")." ]] && [[ "$OUT" != *"classic"* ]]'
pfix - - -
check "P1 gh failing on the branch → unknown, exit 0" '[ "$RC" = 0 ] && [[ "$OUT" == "Branch protection on \`main\`: unknown ("*")." ]] && [[ "$OUT" != *"classic"* ]]'
prot "$SANDBOX/home"
check "P1 outside a git repo → unknown, exit 0" '[ "$RC" = 0 ] && [ "$OUT" = "Branch protection on the default branch: unknown (not a git repository)." ]'
AFTER=$(snap)
check "P1 the check writes no file" '[ "$AFTER" = "$BEFORE" ]'

# ---------------------------------------------------------------- R1 the merge record
anchor yes
post() { # <command>
  node -e 'const [d,c]=process.argv.slice(1);process.stdout.write(JSON.stringify({session_id:"s",hook_event_name:"PostToolUse",cwd:d,tool_name:"Bash",tool_input:{command:c},tool_response:{stdout:"",stderr:""}}))' "$REPO" "$1" | node "$RECORD"
}
post "$PIN"
check "R1 the pinned merge command appends one merge line: ran true, no outcome field" '[ -f "$LOG" ] && [ "$(wc -l < "$LOG" | tr -d " ")" = 1 ] && node -e "const l=JSON.parse(require(\"fs\").readFileSync(process.argv[1],\"utf8\").trim());process.exit(l.kind===\"merge\"&&l.pr===12&&l.sha===process.argv[2]&&l.method===\"merge\"&&l.approval===\"permission prompt\"&&l.ran===true&&JSON.stringify(Object.keys(l))===JSON.stringify([\"kind\",\"pr\",\"sha\",\"method\",\"time\",\"approval\",\"ran\"])&&!isNaN(Date.parse(l.time))?0:1)" "$LOG" "$SHA"'
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

kanchor 'listed as "merged outside the run", and never counted as merged under your authorisation'
kanchor 'never from this line or from memory'
kanchor 'A PR with a `merge` line that GitHub shows MERGED at the line'"'"'s sha is listed here'
kanchor 'for a `merge` line GitHub doesn'"'"'t show merged at that sha, "head moved or merge refused"'
kanchor '(`PG-MCP-MERGE`)'
kanchor 'No `git` command is a merge form for it; pushes are GitHub'"'"'s to stop.'
kanchor '(`PG-MERGE-ERROR`)'
kanchor 'commands launched by `xargs` or `find -exec`, which the guard'"'"'s parser doesn'"'"'t unwrap'
kanchor 'They are a speed bump, not a sandbox'
kanchor 'MCP servers without `github` in their name'
kanchor 'Pushes: branch protection or a ruleset on the default branch that requires a pull request, with no bypass for the run'"'"'s token, stops direct pushes'
kanchor 'classic branch protection exempts admins unless "Do not allow bypassing the above settings" is on, and a ruleset applies to the user unless their role is on its bypass list.'
kanchor 'Merges: a hard wall only when the run uses its own bot or GitHub App identity that can'"'"'t merge without the user'"'"'s approving review'
kanchor '`node ${CLAUDE_PLUGIN_ROOT}/hooks/pretooluse-push-guard.mjs protection --cwd <root>`'
kanchor '"Branch protection on `<default>`: on.", or'
kanchor '"Branch protection on `<default>`: on, but <reason> — a direct push can still land. See the README'"'"'s /pipeline section.", or'
kanchor '"Branch protection on `<default>`: OFF — GitHub won'"'"'t stop a push or a merge to it. See the README'"'"'s /pipeline section.", or'
kanchor '"Branch protection on `<default>`: unknown (<reason>).". The run goes on whatever it says.'
for f in "$SKILL" "$PLUGIN/docs/cli-tools.md"; do
  check "K no removed rule named in ${f#$PLUGIN/}" '! grep -qE "PG-RUN-PUSH|PG-GIT-MERGE" "$f"'
done

echo
echo "SUMMARY: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
