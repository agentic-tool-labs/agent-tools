#!/bin/bash
# agent-hierarchy — a hook may name the PreToolUse decision `ask` in one place only: askDecision in
# hooks/lib-config.mjs, which turns it into a deny in a member session. A gate added later that writes
# its own prompt would leave a member waiting at a prompt nobody watches. Comments are not code.
# Usage: bash tests/test-no-bare-ask.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (OUT=${OUT:0:300})"; fi
}

# <dir>: every file:line under it where code (comments blanked) holds a string literal `ask`, other than the one in lib-config.mjs.
bare() {
  node - "$1" <<'JS'
const fs = require("fs"), path = require("path");
const dir = process.argv[2], found = [];
let inLib = 0;
for (const f of fs.readdirSync(dir).filter((n) => n.endsWith(".mjs"))) {
  const src = fs.readFileSync(path.join(dir, f), "utf8");
  // Comments blanked, strings kept: enough for a literal-name test.
  const code = src.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, " ")).replace(/(^|[^:"'`\\])\/\/[^\n]*/g, (m, a) => a + " ".repeat(m.length - a.length));
  code.split("\n").forEach((line, i) => {
    for (const m of line.matchAll(/(["'`])ask\1/g)) {
      if (f === "lib-config.mjs") inLib++; else found.push(`${f}:${i + 1}`);
    }
  });
}
if (inLib !== 1) found.push(`lib-config.mjs: ${inLib} literal ask decisions, expected exactly 1`);
process.stdout.write(found.join("\n"));
JS
}

OUT=$(bare "$PLUGIN/hooks")
check "no hook file names the ask decision except askDecision in lib-config.mjs" '[ -z "$OUT" ]'

T=$(mktemp -d); [ -n "$T" ] && [ -d "$T" ] || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$T"' EXIT
for f in "$PLUGIN"/hooks/*.mjs; do cp "$f" "$T/"; done
printf '%s\n' 'process.stdout.write(JSON.stringify({ hookSpecificOutput: { permissionDecision: "ask" } }))' > "$T/pretooluse-new-gate.mjs"
OUT=$(bare "$T")
check "a new gate with a bare ask decision fails the scan" 'printf "%s" "$OUT" | grep -q "pretooluse-new-gate.mjs:1"'
printf '%s\n' "decide('ask', reason)" > "$T/pretooluse-new-gate.mjs"
OUT=$(bare "$T")
check "a single-quoted ask is caught too" 'printf "%s" "$OUT" | grep -q "pretooluse-new-gate.mjs:1"'
printf '%s\n' '// the gate says "ask" in a comment' '/* and "ask" here */' > "$T/pretooluse-new-gate.mjs"
OUT=$(bare "$T")
check "ask in a comment is not code" '[ -z "$OUT" ]'
rm -f "$T/pretooluse-new-gate.mjs"
printf '\nconst extra = { decision: "ask" }\n' >> "$T/lib-config.mjs"
OUT=$(bare "$T")
check "a second ask literal in lib-config.mjs fails the scan" 'printf "%s" "$OUT" | grep -q "expected exactly 1"'

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
