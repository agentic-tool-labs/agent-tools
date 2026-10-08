#!/bin/bash
# agent-hierarchy — runs the mod's own tests (mod/tests/*.test.ts) with `claude plugin test` on the plugin
# root, so the suite gates view.ts and register.tsx. A scratch HOME and CLAUDE_CONFIG_DIR keep the run off
# the user's settings and ~/.claude/dev-mods/. It fails closed: a missing `claude`, a non-zero exit, a
# failed test, no test run, or the 300 s timeout each fail, and no process of the run outlives it.
# Usage: bash tests/test-mod-plugin-test.sh   (exits 0 iff all cases pass)

. "$(dirname "$0")/lib-hermetic.sh"
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-mod-plugin-test.XXXXXX")"
[ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] || { echo "mktemp failed"; exit 1; }
hermetic_on_exit 'rm -rf "$SANDBOX"'
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (OUT=${OUT:0:600})"; fi
}

OUT=$(command -v claude)
check "the claude CLI is on PATH" '[ -n "$OUT" ]'
mkdir -p "$SANDBOX/home/.claude"
# The run gets its own process group, and the whole group is killed on the timeout and after the run,
# so a test child cannot outlive it. 124 is the timeout's exit code.
OUT=$(cd "$SANDBOX" && HOME="$SANDBOX/home" CLAUDE_CONFIG_DIR="$SANDBOX/home/.claude" perl -e '
  my ($secs, @cmd) = @ARGV;
  my $pid = fork // die "fork: $!";
  if (!$pid) { setpgrp(0, 0); exec @cmd or exit 127 }
  local $SIG{ALRM} = sub { kill "KILL", -$pid; waitpid($pid, 0); exit 124 };
  alarm $secs;
  waitpid($pid, 0);
  my $st = $?;
  alarm 0;
  kill "KILL", -$pid;
  exit($st & 127 ? 128 + ($st & 127) : $st >> 8);
' 300 claude plugin test "$PLUGIN" 2>&1); RC=$?
check "claude plugin test exits 0 (124 is the 300 s timeout)" '[ "$RC" = 0 ]'
check "no test failed" '! printf "%s\n" "$OUT" | grep -qE "^\(fail\)|^ *[1-9][0-9]* fail"'
check "tests ran and passed" 'printf "%s\n" "$OUT" | grep -qE "^ *[1-9][0-9]* pass"'
LEFT=$(pgrep -f "claude plugin test $PLUGIN" 2>/dev/null)
OUT=$LEFT
check "no claude plugin test process for this plugin is left" '[ -z "$LEFT" ]'

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
