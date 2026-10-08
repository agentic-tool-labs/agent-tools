#!/bin/bash
# agent-hierarchy — pretooluse-reviewer-write-gate.mjs: the Reviewer may Write/Edit only its own, already
# created response file, with the frontmatter unchanged; every other role (and no role) is not touched.
# HOME-redirected; real state untouched.
# Usage: bash tests/test-reviewer-write-gate.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$PLUGIN/hooks/pretooluse-reviewer-write-gate.mjs"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-reviewer-write-gate-test.XXXXXX")"
[ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
unset AH_TEAM_FILE CLAUDE_PID
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/proj"
MSGS="$PROJ/.claude/hierarchy/msgs"
mkdir -p "$FAKEHOME/.claude" "$MSGS" "$SANDBOX/outside"
(cd "$PROJ" && git init -q)
PASS=0; FAIL=0
check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:300})"; fi
}

FM_OK=$'---\nid: 20260101-000000-abcd\ntype: response\nto: orchestrator\nfrom: reviewer\nslug: s\nparent: p\ncreated: 2026-01-01T00:00:00Z\n---\n'
RESP="$MSGS/20260101-000000-abcd--orchestrator--s--response.md"
printf '%s## [0] tldr\n- [1] status: \n\n## [1] findings\n- none\n' "$FM_OK" > "$RESP"
IMPL="$MSGS/20260101-000000-impl--orchestrator--s--response.md"
printf '%s## [0] tldr\n- none\n' "${FM_OK/from: reviewer/from: implementor}" > "$IMPL"

# run <agent_type or -> <tool> <tool_input json>
run() {
  OUT=$(node -e '
    const [cwd, agent, tool, ti] = process.argv.slice(1);
    const input = { session_id: "s1", cwd, tool_name: tool, tool_input: JSON.parse(ti) };
    if (agent !== "-") input.agent_type = agent;
    process.stdout.write(JSON.stringify(input));
  ' "$PROJ" "$1" "$2" "$3" | HOME="$FAKEHOME" node "$HOOK" 2>&1); RC=$?
}
is_deny() { case "$OUT" in *'"permissionDecision":"deny"'*) return 0;; *) return 1;; esac; }
quiet() { [ "$RC" -eq 0 ] && [ -z "$OUT" ]; }
jstr() { node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' -- "$1"; }

BODY_NEW="${FM_OK}## [0] tldr"$'\n'"- [1] status: DONE"$'\n'
run reviewer Write "{\"file_path\":\"$RESP\",\"content\":$(jstr "$BODY_NEW")}"
check "reviewer Write to its existing response with the frontmatter unchanged: allowed (no output)" 'quiet'
run ah:reviewer Write "{\"file_path\":\"$RESP\",\"content\":$(jstr "$BODY_NEW")}"
check "the ah:reviewer agent type is the reviewer too" 'quiet'
run reviewer Edit "{\"file_path\":\"$RESP\",\"old_string\":\"- none\",\"new_string\":\"- a finding\"}"
check "reviewer Edit of a body line: allowed" 'quiet'
run reviewer MultiEdit "{\"file_path\":\"$RESP\",\"edits\":[{\"old_string\":\"- none\",\"new_string\":\"- x\"},{\"old_string\":\"status: \",\"new_string\":\"status: DONE\"}]}"
check "reviewer MultiEdit of body lines: allowed" 'quiet'

run reviewer Edit "{\"file_path\":\"$RESP\",\"old_string\":\"to: orchestrator\",\"new_string\":\"to: someone\"}"
check "reviewer Edit that alters a frontmatter line: denied" 'is_deny'
run reviewer MultiEdit "{\"file_path\":\"$RESP\",\"edits\":[{\"old_string\":\"- none\",\"new_string\":\"- x\"},{\"old_string\":\"type: response\",\"new_string\":\"type: request\"}]}"
check "reviewer MultiEdit with one edit in the frontmatter: denied" 'is_deny'
run reviewer Write "{\"file_path\":\"$RESP\",\"content\":$(jstr "${FM_OK/slug: s/slug: other}body")}"
check "reviewer Write that changes the frontmatter: denied" 'is_deny'
run reviewer Write "{\"file_path\":\"$RESP\",\"content\":\"no frontmatter at all\"}"
check "reviewer Write that drops the frontmatter: denied" 'is_deny'
run reviewer Edit "{\"file_path\":\"$RESP\",\"old_string\":\"id: 20260101-000000-abcd\",\"new_string\":\"id: x\"}"
check "reviewer Edit of the id line: denied" 'is_deny'
check "the deny names the command that creates the file" 'echo "$OUT" | grep -q "msg.mjs new --type response"'

run reviewer Write "{\"file_path\":\"$PLUGIN/hooks/x.mjs\",\"content\":\"x\"}"
check "reviewer Write to product code: denied" 'is_deny'
run reviewer Write "{\"file_path\":\"$PROJ/notes.md\",\"content\":\"x\"}"
check "reviewer Write to a file outside msgs: denied" 'is_deny'
run reviewer Write "{\"file_path\":\"$IMPL\",\"content\":\"x\"}"
check "reviewer Write to a response whose from: is another role: denied" 'is_deny'
run reviewer Write "{\"file_path\":\"$MSGS/20260101-000000-new--orchestrator--s--response.md\",\"content\":\"x\"}"
check "reviewer Write to a response file that does not exist: denied" 'is_deny'
printf '%s' "$FM_OK" > "$MSGS/20260101-000000-abcd--orchestrator--s--request.md"
run reviewer Write "{\"file_path\":\"$MSGS/20260101-000000-abcd--orchestrator--s--request.md\",\"content\":$(jstr "$FM_OK")}"
check "reviewer Write to a request file: denied" 'is_deny'

run reviewer Write "{\"file_path\":\"$MSGS/../../x--response.md\",\"content\":\"x\"}"
check "reviewer Write through a .. path: denied" 'is_deny'
printf '%s' "$FM_OK" > "$SANDBOX/outside/y--response.md"
ln -s "$SANDBOX/outside/y--response.md" "$MSGS/20260101-000000-link--orchestrator--s--response.md"
run reviewer Write "{\"file_path\":\"$MSGS/20260101-000000-link--orchestrator--s--response.md\",\"content\":$(jstr "$FM_OK")}"
check "reviewer Write through a symlink out of msgs: denied" 'is_deny'
run reviewer Write "{\"file_path\":\"$SANDBOX/outside/y--response.md\",\"content\":$(jstr "$FM_OK")}"
check "reviewer Write to a response file outside any msgs dir: denied" 'is_deny'
run reviewer Write '{"content":"x"}'
check "reviewer Write with no file_path: denied" 'is_deny'

run implementor Write "{\"file_path\":\"$PLUGIN/hooks/x.mjs\",\"content\":\"x\"}"
check "implementor Write anywhere: no output" 'quiet'
run ah:architect Write "{\"file_path\":\"$PROJ/spec.md\",\"content\":\"x\"}"
check "architect Write anywhere: no output" 'quiet'
run - Write "{\"file_path\":\"$PROJ/x.md\",\"content\":\"x\"}"
check "a session with no role Write anywhere: no output" 'quiet'
run reviewer Bash '{"command":"ls"}'
check "a tool other than Write, Edit and MultiEdit: no output" 'quiet'
run reviewer Read "{\"file_path\":\"$RESP\"}"
check "Read by the reviewer: no output" 'quiet'

# an error while judging a reviewer's write denies; the same error for another role says nothing
OUT=$(printf 'not json' | HOME="$FAKEHOME" node "$HOOK" 2>&1); RC=$?
check "unreadable hook input: no output (no role is known)" 'quiet'

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
