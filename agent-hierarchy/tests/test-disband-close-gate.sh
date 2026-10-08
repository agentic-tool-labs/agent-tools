#!/bin/bash
# agent-hierarchy — pretooluse-disband-close-gate.mjs (spec 0016 §4.5.1, 0020 §4.1), re-keyed onto
# the parsed Bash command by spec 0048 §2.4.2/§6 T3: it fires on `roster.mjs dismiss|disband --close`
# and on nothing else, always asks, never caches. HOME-redirected; real state untouched.
# Usage: bash tests/test-disband-close-gate.sh   (exits 0 iff all cases pass)

. "$(dirname "$0")/lib-hermetic.sh"
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
. "$PLUGIN/tests/lib-quiet-deny.sh"
HOOK="$PLUGIN/hooks/pretooluse-disband-close-gate.mjs"
ROSTER="$PLUGIN/hooks/roster.mjs"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-disband-close-gate-test.XXXXXX")"
export AH_TEST_FAKE_BIN="$SANDBOX/nolaunch"
# No test may reach the real herdr or tmux: a stub that fails every call sits first on PATH, and
# the session's pane environment is dropped. A wrapper that sets PATH to its own fakes still wins.
mkdir -p "$SANDBOX/nolaunch"; printf '#!/bin/sh\nexit 1\n' > "$SANDBOX/nolaunch/herdr"; cp "$SANDBOX/nolaunch/herdr" "$SANDBOX/nolaunch/tmux"; chmod +x "$SANDBOX/nolaunch/herdr" "$SANDBOX/nolaunch/tmux"
export PATH="$SANDBOX/nolaunch:$PATH"; unset AH_TEAM_FILE
unset CLAUDE_PID  # every Claude session exports one; a test must not inherit it
hermetic_on_exit 'rm -rf "$SANDBOX"'
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/proj"
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude"
(cd "$PROJ" && git init -q)
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:300})"; fi
}

# hook <bash command string>
hook() {
  OUT=$(node -e '
    process.stdout.write(JSON.stringify({ session_id: "s1", cwd: process.argv[1], tool_name: "Bash", tool_input: { command: process.argv[2] } }));
  ' "$PROJ" "$1" | HOME="$FAKEHOME" node "$HOOK" 2>&1); RC=$?
}

is_ask() { case "$OUT" in *'"permissionDecision":"ask"'*) return 0;; *) return 1;; esac; }

# ---- fires on disband --close, always ask
hook "node $ROSTER disband --close --confirm --plan-token t --cwd $PROJ"
check "fires on roster.mjs disband --close: RC 0, permissionDecision ask" '[ "$RC" -eq 0 ] && is_ask'
check "the ask carries no systemMessage" 'no_system_message'
check "generic message when no team.json exists (readTeam enrichment has nothing)" \
  'echo "$OUT" | grep -q "close the live sessions of this Team"'

# ---- enrichment: names the members when team.json is readable
TEAM_FILE="$PROJ/.claude/hierarchy/team.json"
mkdir -p "$(dirname "$TEAM_FILE")"
cat > "$TEAM_FILE" <<EOF
{"version":1,"team_id":"t1","created":"2026-01-01T00:00:00Z","roster_level":"repo","transport":"herdr","orchestrator":{"session_id":null,"pid":null},"members":[{"role":"architect","name":"proj-architect","route":"peer","transport_id":"P1"}],"partial":false}
EOF
hook "node $ROSTER disband --close --confirm --plan-token t --cwd $PROJ"
check "enrichment: names the live member in the ask message" 'echo "$OUT" | grep -q "proj-architect"'

# ---- asking twice asks twice: never cached, nothing recorded (spec 0048 §2.4.2)
hook "node $ROSTER disband --close --confirm --plan-token t --cwd $PROJ"
check "second identical close command asks again (no caching)" '[ "$RC" -eq 0 ] && is_ask'
check "nothing is recorded in gates.jsonl by this gate" '[ ! -f "$PROJ/.claude/hierarchy/gates.jsonl" ]'

# ---- readTeam enrichment failing (unreadable cwd) still asks, generic message, never skipped
hook "node $ROSTER disband --close --confirm --plan-token t --cwd /nonexistent/definitely-not-a-real-path"
check "enrichment failure: still asks (never skips the prompt)" '[ "$RC" -eq 0 ] && is_ask'

# ---- dismiss: the member name comes from argv, not a tool input
hook "node $ROSTER dismiss proj-architect --close --confirm --plan-token t --cwd $PROJ"
check "fires on roster.mjs dismiss <name> --close: RC 0, permissionDecision ask" '[ "$RC" -eq 0 ] && is_ask'
check "dismiss: enrichment names the single member from argv, not the whole team" \
  'echo "$OUT" | grep -q "proj-architect"'

# ---- plan forms and the non-destructive verbs are NOT gated (0048 §2.4.2: --close is the mode)
hook "node $ROSTER disband --cwd $PROJ"
check "does NOT fire on bare disband (the plan form)" '[ -z "$OUT" ]'
hook "node $ROSTER dismiss proj-architect --cwd $PROJ"
check "does NOT fire on bare dismiss <name> (the plan form)" '[ -z "$OUT" ]'
hook "node $ROSTER untrack --all --commit --cwd $PROJ"
check "does NOT fire on untrack (never destructive to a session)" '[ -z "$OUT" ]'
hook "node $ROSTER show --cwd $PROJ"
check "does NOT fire on an unrelated verb (show)" '[ -z "$OUT" ]'
hook "ls"
check "does NOT fire on an unrelated Bash command" '[ -z "$OUT" ]'

# ---- the old key is gone: an MCP tool name must no longer reach this gate (0048 §3)
OUT=$(printf '{"session_id":"s1","cwd":"%s","tool_name":"mcp__ah__team_disband","tool_input":{"cwd":"%s","mode":"close","confirm":true,"plan_token":"t"}}' "$PROJ" "$PROJ" \
  | HOME="$FAKEHOME" node "$HOOK" 2>&1); RC=$?
check "an mcp__ah__team_disband tool call is no longer gated (MCP surface removed)" '[ -z "$OUT" ]'

# ---- a close the parser cannot read must still ask, never run unasked
for verb in "dismiss m" "disband"; do
  hook "cd /x && node $ROSTER $verb --close"
  check "asks on a cd-chained $verb --close" '[ "$RC" -eq 0 ] && is_ask'
  hook "FOO=1 node $ROSTER $verb --close --cwd $PROJ"
  check "asks on an env-prefixed $verb --close" '[ "$RC" -eq 0 ] && is_ask'
  hook "cd $PLUGIN && node hooks/roster.mjs $verb --close"
  check "asks on a relative-path $verb --close" '[ "$RC" -eq 0 ] && is_ask'
  hook "true; node $ROSTER $verb --close"
  check "asks on a ;-chained $verb --close" '[ "$RC" -eq 0 ] && is_ask'
  hook "sh -c \"node $ROSTER $verb --close\""
  check "asks on an sh -c $verb --close" '[ "$RC" -eq 0 ] && is_ask'
  hook "cd /x && node $ROSTER \\
  $verb \\
  --close"
  check "asks on a backslash-continued $verb --close" '[ "$RC" -eq 0 ] && is_ask'
  for rt in "node --no-warnings" "node --trace-warnings" "node -r /dev/null" "bun" "deno run -A" "nodejs --import x" "npx tsx" "node --a --b --c --d --e --f" "deno run --allow-read --allow-write --allow-env --allow-sys --allow-run"; do
    hook "$rt $ROSTER $verb --close"
    check "asks on '$rt' $verb --close" '[ "$RC" -eq 0 ] && is_ask'
  done
  hook "cd /x && node $ROSTER $verb m \"--close\""
  check "asks on a quoted --close ($verb)" '[ "$RC" -eq 0 ] && is_ask'
  hook "cd /x && node $ROSTER \"$verb\" m --close"
  check "asks on a quoted $verb verb" '[ "$RC" -eq 0 ] && is_ask'
  hook "cd /x && node $ROSTER $verb --cwd $PROJ"
  check "stays silent on an unparsed $verb plan form (no --close)" '[ -z "$OUT" ]'
done
hook 'git commit -m "roster.mjs dismiss m --close"'
check "stays silent on a commit message that mentions the close" '[ -z "$OUT" ]'
hook "echo roster.mjs --close"
check "stays silent on an unrelated command that mentions both strings" '[ -z "$OUT" ]'

check "hooks/roster.mjs is not executable, so a bare-path shebang run cannot bypass the gate" '[ ! -x "$ROSTER" ]'

# ---- matcher reachability: the cases above pipe JSON straight to the .mjs and bypass hooks.json,
# so a gate whose matcher no longer selects it would ship ungated while they all pass (0020 §4.1).
HOOKS_JSON="$PLUGIN/hooks/hooks.json"
MATCHER_CHECK=$(node -e '
  const fs = require("fs");
  const cfg = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const rule = (cfg.hooks.PreToolUse || []).find((r) =>
    Array.isArray(r.hooks) && r.hooks.some((h) => typeof h.command === "string" && h.command.includes("pretooluse-disband-close-gate.mjs"))
  );
  console.log(rule && rule.matcher === "Bash" ? "PASS" : "FAIL " + JSON.stringify(rule && rule.matcher));
' "$HOOKS_JSON")
check "hooks.json PreToolUse matcher for pretooluse-disband-close-gate.mjs is Bash" '[ "$MATCHER_CHECK" = "PASS" ]'

# ---- the scan reads command text only: heredoc bodies, quoted text and comments never match
NL=$'\n'
hook_member() {
  OUT=$(node -e '
    process.stdout.write(JSON.stringify({ session_id: "s1", cwd: process.argv[1], tool_name: "Bash", tool_input: { command: process.argv[2] } }));
  ' "$PROJ" "$1" | AH_TEAM_FILE="$PROJ/.claude/hierarchy/team.json" HOME="$FAKEHOME" node "$HOOK" 2>&1); RC=$?
}
silent() { hook "$1"; check "$2 (no decision)" '[ "$RC" -eq 0 ] && [ -z "$OUT" ]'; hook_member "$1"; check "$2 (no decision in a member)" '[ "$RC" -eq 0 ] && [ -z "$OUT" ]'; }
matches() { hook "$1"; check "$2 (asks)" '[ "$RC" -eq 0 ] && is_ask'; hook_member "$1"; check "$2 (denies in a member)" '[ "$RC" -eq 0 ] && is_deny'; }
is_deny() { case "$OUT" in *'"permissionDecision":"deny"'*) return 0;; *) return 1;; esac; }
CLOSE="node $ROSTER disband --close"

silent "cat > /p/x--response.md <<'EOF'${NL}- ran node $ROSTER disband --team x --close --confirm${NL}EOF" "a response file written by heredoc that mentions the close"
silent "cat > /p/x.md <<EOF${NL}$CLOSE${NL}EOF" "an unquoted heredoc body that mentions the close"
silent "cat > /p/x.md <<-EOF${NL}	$CLOSE${NL}	EOF" "a <<- heredoc body that mentions the close"
silent "echo \"$CLOSE\"" "a double-quoted echo of the close"
silent "printf '%s' '$CLOSE'" "a single-quoted printf of the close"
silent "git commit -m \"doc: $CLOSE\"" "a commit message that mentions the close"
silent "ls # $CLOSE" "a comment that mentions the close"
silent "node /a/hooks/msg.mjs new --type response --id x --from y <<EOF${NL}$CLOSE${NL}EOF" "a runtime with a script operand reading a heredoc as data"
silent "echo hi; node x.js $ROSTER${NL}disband --close" "words split over two simple commands"
silent "echo hi && node x.js $ROSTER; echo disband --close" "words split by && and ;"
matches "cd /c && $CLOSE --team x" "a close after cd &&"
matches "bash -c \"$CLOSE\"" "bash -c with the close"
matches "sh -lc '$CLOSE'" "sh -lc with the close"
matches "eval \"$CLOSE\"" "eval with the close"
matches "echo \"\$($CLOSE)\"" "a command substitution inside double quotes"
matches "echo \`$CLOSE\`" "a backtick span"
matches "bash <<EOF${NL}$CLOSE${NL}EOF" "a heredoc into bash"
matches "cat <<EOF | bash${NL}$CLOSE${NL}EOF" "a heredoc piped into bash"
matches "node - <<EOF${NL}$CLOSE${NL}EOF" "a heredoc into node reading stdin"
matches "node <<'EOF'${NL}$CLOSE${NL}EOF" "a quoted heredoc into node with no operands"
matches "echo \"$CLOSE" "an unterminated quote (fail safe)"
matches "cat <<EOF${NL}$CLOSE" "an unterminated heredoc (fail safe)"
matches "echo \"\$(echo \"\$(echo \"\$(echo \"\$(echo $ROSTER --close)\")\")\")\"" "nesting deeper than three levels (fail safe)"

# close shapes the scan must still catch (each asked before the scan read command text only)
matches "node \${CLAUDE_PLUGIN_ROOT}/hooks/roster.mjs disband --close --confirm --plan-token t" "an unquoted \${VAR} script path"
matches "node \"\$R/hooks/roster.mjs\" disband --close --confirm --plan-token t" "a quoted \$VAR script path"
matches "node \"\${CLAUDE_PLUGIN_ROOT}/hooks/roster.mjs\" disband --close --confirm --plan-token t" "the quoted plugin-root script path"
matches "timeout 30 bash -c \"$CLOSE\"" "timeout wrapping bash -c"
matches "env bash -c \"$CLOSE\"" "env wrapping bash -c"
matches "sudo -u root bash <<EOF${NL}$CLOSE${NL}EOF" "sudo wrapping a shell that reads a heredoc"
matches "FOO=1 nohup sh <<EOF${NL}$CLOSE${NL}EOF" "assignments and nohup before a shell reading a heredoc"
matches "cat <<EOF 2>&1 | bash${NL}$CLOSE${NL}EOF" "a heredoc piped through 2>&1 into bash"
matches "bash <<< \"$CLOSE\"" "a here-string into bash"
matches "timeout 5 node $ROSTER disband --close 2>&1 | tee /tmp/x" "a close with a redirection and a pipe after it"
matches "ROOT=\"\$(pwd)\" bash <<EOF${NL}$CLOSE${NL}EOF" "an assignment with a command substitution before a shell reading a heredoc"
matches "timeout \"\$(echo 30)\" bash <<EOF${NL}$CLOSE${NL}EOF" "a wrapper with a command substitution before a shell reading a heredoc"
matches "timeout \"\$(echo 30)\" bash <<< \"$CLOSE\"" "a wrapper with a command substitution before a shell reading a here-string"
matches "cat <<EOF |& bash${NL}$CLOSE${NL}EOF" "a heredoc piped with |& into bash"
silent "cat <<< \"$CLOSE\"" "a here-string into cat"
silent "{ echo \"$CLOSE\"; } > /tmp/x" "a brace group that only echoes the close"

# a parsed close in a member is a deny carrying the original reason and the member tail; outside a member it is the ask it always was
hook_member "node $ROSTER disband --close --confirm --plan-token t --team x --cwd $PROJ"
check "a parsed close in a member: deny with the original reason" '[ "$RC" -eq 0 ] && is_deny && echo "$OUT" | grep -q "close the live session"'
check "the member deny carries the tail" 'echo "$OUT" | grep -q "does not ask here. Do not retry this command. Put what you needed in your report as BLOCKED or NEEDS-DECISION"'
hook "node $ROSTER disband --close --confirm --plan-token t --team x --cwd $PROJ"
check "the same parsed close outside a member is still an ask" '[ "$RC" -eq 0 ] && is_ask'
check "the ask outside a member has no tail" '! echo "$OUT" | grep -q "does not ask here"'
AH_TEAM_FILE="" hook "node $ROSTER disband --close --confirm --plan-token t --team x --cwd $PROJ"
check "an empty AH_TEAM_FILE is no member: still an ask" '[ "$RC" -eq 0 ] && is_ask'

# gate/matcher agreement check (spec 0042 §4 item 4, re-keyed by 0048 §2.4.5)
NAME_AGREEMENT=$(node "$PLUGIN/tests/check-gate-name-agreement.mjs" 2>&1); NA_RC=$?
echo "$NAME_AGREEMENT"
check "gate verb-set/matcher agreement" '[ "$NA_RC" -eq 0 ]'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
