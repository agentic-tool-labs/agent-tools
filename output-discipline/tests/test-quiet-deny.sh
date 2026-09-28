#!/bin/bash
# output-discipline deny-shape tests: each deny shows the user one calm line and
# gives the model the full reason.
# Usage: bash tests/test-quiet-deny.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
HOOK="$PLUGIN/hooks/pretooluse-bash.mjs"
PASS=0; FAIL=0
unset OUTPUT_DISCIPLINE_DISABLE OUTPUT_DISCIPLINE_ALLOW

run_hook() { # <command>
  OUT=$(node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:process.argv[1]}}))' "$1" \
    | node "$HOOK" 2>/dev/null); RC=$?
}

check() { # check <name> <condition...>
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (OUT=${OUT:0:160} RC=$RC)"; fi
}

# quiet_deny <calm> <model-phrase>: stdout is one JSON object whose only keys are
# systemMessage (== calm, one line) and a PreToolUse deny whose reason contains
# model-phrase.
quiet_deny() {
  [ "$RC" -eq 0 ] && printf '%s' "$OUT" | node -e '
    const [calm, phrase] = process.argv.slice(1);
    let s = "";
    process.stdin.on("data", (d) => (s += d)).on("end", () => {
      let o;
      try { o = JSON.parse(s); } catch { process.exit(1); }
      const h = (o && o.hookSpecificOutput) || {};
      const r = h.permissionDecisionReason;
      const ok =
        o !== null && typeof o === "object" && !Array.isArray(o) &&
        Object.keys(o).sort().join() === "hookSpecificOutput,systemMessage" &&
        o.systemMessage === calm && !calm.includes("\n") &&
        h.hookEventName === "PreToolUse" && h.permissionDecision === "deny" &&
        typeof r === "string" && r.length > 0 && r.includes(phrase);
      process.exit(ok ? 0 : 1);
    });' "$1" "$2"
}

OD1_CALM="output-discipline: held a command that streams without end; it will be rerun bounded."
OD2_CALM="output-discipline: held a long-running foreground command; it will be rerun in the background."
OD3_CALM="output-discipline: held a noisy command; it will be rerun with its output captured to a file."

run_hook 'tail -f app.log'
check "OD-1: streaming command -> quiet deny" "quiet_deny \"\$OD1_CALM\" 'streams output indefinitely'"

run_hook 'npm run dev'
check "OD-2: long-running foreground command -> quiet deny" "quiet_deny \"\$OD2_CALM\" 'long-running process'"

run_hook 'npm test'
check "OD-3: uncaptured noisy command -> quiet deny" "quiet_deny \"\$OD3_CALM\" 'Capture the output to a file'"

run_hook 'ls'
check "plain command -> allowed silently" '[ $RC -eq 0 ] && [ -z "$OUT" ]'

echo "----"
echo "SUMMARY: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ]
