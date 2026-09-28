#!/bin/bash
# agent-hierarchy — PreToolUse EnterWorktree gate: a directly attributed hierarchy role never
# moves its root into a worktree; the Orchestrator, unattributed sessions and legwork runners pass;
# a misplaced peer relocating to its team's expected_root passes.
# HOME-redirected; real state untouched.
# Usage: bash tests/test-worktree-gate.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
. "$PLUGIN/tests/lib-quiet-deny.sh"
H="$PLUGIN/hooks"
HOOK="$H/pretooluse-worktree-gate.mjs"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-worktree-gate-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
mkdir -p "$SANDBOX/nolaunch"; printf '#!/bin/sh\nexit 1\n' > "$SANDBOX/nolaunch/herdr"; cp "$SANDBOX/nolaunch/herdr" "$SANDBOX/nolaunch/tmux"; chmod +x "$SANDBOX/nolaunch/herdr" "$SANDBOX/nolaunch/tmux"
export PATH="$SANDBOX/nolaunch:$PATH"; unset HERDR_ENV HERDR_PANE_ID TMUX_PANE TMUX AH_TEAM_FILE
unset CLAUDE_PID
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/proj"
OTHER="$SANDBOX/other"
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude" "$OTHER"
export CLAUDE_PID=$$
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:400})"; fi
}

CALM="ah: kept a role session out of a worktree; it works there by path instead."
REASON='ah: hierarchy roles do not use EnterWorktree. It would move this session'"'"'s root: ah'"'"'s peer tracking would then read the worktree'"'"'s own .claude/hierarchy, and if the worktree is removed later this session is stranded (only the user can ExitWorktree). This call was BLOCKED and did not run. Stay where you are and work in the worktree by absolute path: `cd <abs worktree> || exit 1; <cmd>` inside each Bash call, `git -C <abs worktree> …` for git, and absolute paths for Read, Edit and Write.'

gate() { # <cwd> <agent_type or ""> <tool_input json>
  OUT=$(node -e '
    const [cwd, at, ti] = process.argv.slice(1);
    const o = { session_id: "w1", hook_event_name: "PreToolUse", cwd, tool_name: "EnterWorktree", tool_input: JSON.parse(ti) };
    if (at) o.agent_type = at;
    process.stdout.write(JSON.stringify(o));
  ' "$1" "$2" "$3" | HOME="$FAKEHOME" node "$HOOK" 2>&1); RC=$?
}
denied() { quiet_deny "$CALM" "do not use EnterWorktree"; }
exact() {
  printf '%s' "$OUT" | node -e '
    const [calm, reason] = process.argv.slice(1);
    const o = JSON.parse(require("fs").readFileSync(0, "utf8"));
    const h = o.hookSpecificOutput || {};
    process.exit(Object.keys(o).sort().join() === "hookSpecificOutput,systemMessage" && o.systemMessage === calm && h.permissionDecisionReason === reason ? 0 : 1);
  ' "$CALM" "$REASON"
}
silent() { [ "$RC" -eq 0 ] && [ -z "$OUT" ]; }

gate "$PROJ" "ah:implementor" "{\"path\":\"$OTHER\"}"
check "W1: implementor EnterWorktree(path) -> quiet deny" 'denied'
check "W1: reason and calm line are byte-exact, keys exactly {hookSpecificOutput, systemMessage}" 'exact'
check "W1: calm line is one line of at most 110 chars" '[ ${#CALM} -le 110 ]'

gate "$PROJ" "ah:implementor" '{"name":"x"}'
check "W2: implementor EnterWorktree(name) -> deny" 'denied'
gate "$PROJ" "ah:implementor" '{}'
check "W3: implementor EnterWorktree() -> deny" 'denied'
gate "$PROJ" "ah:reviewer" '{"name":"x"}'
check "W3: reviewer -> deny" 'denied'
gate "$PROJ" "ah:architect" '{"name":"x"}'
check "W3: architect -> deny" 'denied'

gate "$PROJ" "" '{"name":"x"}'
check "W4: no agent_type -> no output" 'silent'
gate "$PROJ" "ah:orchestrator" '{"name":"x"}'
check "W5: orchestrator -> no output" 'silent'
gate "$PROJ" "task-gopher:task-gopher" '{"name":"x"}'
check "W6: task-gopher -> no output" 'silent'

# A committed team whose expected_root is TEAM itself.
TEAM="$SANDBOX/team"
mkdir -p "$TEAM/.claude"
git init -q "$TEAM" || exit 1
HOME="$FAKEHOME" node "$H/roster.mjs" init --level repo --route peer --cwd "$TEAM" >/dev/null
HOME="$FAKEHOME" node "$H/roster.mjs" add --no-spawn --level repo --role implementor --cwd "$TEAM" >/dev/null
HOME="$FAKEHOME" node "$H/roster.mjs" create --commit --transport terminal --roster-level repo \
  --verified '["team-implementor"]' --orchestrator-pid "$$" --cwd "$TEAM" >/dev/null
check "W7: fixture team records expected_root" 'node -e "process.exit(JSON.parse(require(\"fs\").readFileSync(process.argv[1],\"utf8\")).expected_root===process.argv[2]?0:1)" "$TEAM/.claude/hierarchy/teams/team.json" "$TEAM"'

gate "$TEAM" "ah:implementor" "{\"path\":\"$TEAM\"}"
check "W7: relocation to the team's expected_root -> no output" 'silent'
gate "$TEAM" "ah:implementor" "{\"path\":\"$OTHER\"}"
check "W7: a different path -> deny" 'denied'
gate "$TEAM" "ah:implementor" "{\"path\":\"$SANDBOX/missing\"}"
check "W7: a path that does not exist -> deny" 'denied'
mkdir -p "$TEAM/sub"
gate "$TEAM/sub" "ah:implementor" "{\"path\":\"$TEAM\"}"
check "W7: from a subdirectory, relocation to the team's expected_root -> no output" 'silent'
gate "$TEAM/sub" "ah:implementor" "{\"path\":\"$TEAM/sub\"}"
check "W7: from a subdirectory, a path other than expected_root -> deny" 'denied'

check "W8: hooks.json has a PreToolUse EnterWorktree group running this hook" 'node -e "
  const pre=JSON.parse(require(\"fs\").readFileSync(process.argv[1],\"utf8\")).hooks.PreToolUse||[];
  const g=pre.filter(g=>g.matcher===\"EnterWorktree\");
  process.exit(g.length===1&&(g[0].hooks||[]).length===1&&String(g[0].hooks[0].command).includes(\"hooks/pretooluse-worktree-gate.mjs\")?0:1);
" "$H/hooks.json"'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
