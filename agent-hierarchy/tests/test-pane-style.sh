#!/bin/bash
# agent-hierarchy — the sectioned Pane's style table stays the one place for icons and colors (I3), and the status
# document carries a member's stream, cleaned and cut (G7). Every write lands in a sandbox pool.
# Usage: bash tests/test-pane-style.sh   (exits 0 iff all cases pass)

unset AH_TEAM_FILE  # every session roster.mjs launches carries one; a test must not inherit it
unset CLAUDE_PID  # every Claude session exports one; a test must not inherit it

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
. "$PLUGIN/tests/lib-status-pool.sh"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-pane-style-test.XXXXXX")"
[ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (OUT=${OUT:0:300})"; fi
}

VIEW="$PLUGIN/mod/view.ts"
REG="$PLUGIN/mod/register.tsx"

# ---- I3: the table's glyphs and color keys appear nowhere but the table
# The table is the STYLE block of view.ts; everything outside it is "the rest of mod/".
REST="$SANDBOX/view-without-table.ts"
awk '/^export const STYLE = \{/ { skip = 1 } !skip { print } /^\} as const/ { skip = 0 }' "$VIEW" > "$REST"
check "I3: the table block was found and cut out of view.ts" '[ "$(wc -l < "$REST")" -lt "$(wc -l < "$VIEW")" ] && grep -q "^export const STYLE" "$VIEW"'
quoted() { grep -q "['\"]$1['\"]" "${@:2}"; } # <literal> <files>: some file holds it as a quoted string
in_table() { grep -q "^    [a-zA-Z]*: { glyph: ['\"]$1['\"]" "$VIEW"; }
for g in '●' '○' '■' '×' '?' '↳' '▲'; do
  check "I3a: the glyph '$g' as a quoted literal is in the table and nowhere else in mod/" 'in_table "$g" && ! quoted "$g" "$REST" "$REG"'
done
for k in claude permission suggestion remember ide planMode success error; do
  check "I3b: register.tsx has no quoted literal of the table color key '$k'" '! quoted "$k" "$REG"'
done
for k in claude suggestion remember ide planMode success error; do
  check "I3b: view.ts has none of '$k' outside the table" '! quoted "$k" "$REST"'
done

# ---- G7: a member's stream in the status file
pool "$SANDBOX/p"
STREAM_BAD=$(node -e 'process.stdout.write("api\u001b[31m" + "x".repeat(100))')
team - "[{\"role\":\"implementor\",\"name\":\"demo-impl\",\"route\":\"peer\",\"kind\":\"claude\",\"transport_id\":\"w1:p1\",\"stream\":\"api\"},{\"role\":\"reviewer\",\"name\":\"demo-rev\",\"route\":\"peer\",\"kind\":\"claude\",\"transport_id\":\"w1:p2\",\"stream\":$(node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$STREAM_BAD")},{\"role\":\"architect\",\"name\":\"demo-arch\",\"route\":\"peer\",\"kind\":\"claude\",\"transport_id\":\"w1:p3\",\"stream\":42},{\"role\":\"task-runner\",\"name\":\"demo-run\",\"route\":\"peer\",\"kind\":\"claude\",\"transport_id\":\"w1:p4\"}]"
(cd "$SANDBOX" && HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/roster.mjs" status --cwd "$PROJ" >/dev/null 2>&1)
field() { node -e 'try { const o = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); console.log(JSON.stringify(o.teams[0].members.find((m) => m.name === process.argv[2]).stream)); } catch (e) { console.log("none"); }' "$HD/status.json" "$1"; }
check "G7: a plain stream is emitted as it is" '[ "$(field demo-impl)" = "\"api\"" ]'
check "G7: a stream with an escape sequence is cleaned and cut to 64 characters" 'S=$(field demo-rev); [ "$S" != none ] && [ "$S" != null ] && ! printf "%s" "$S" | grep -q "\\\\u001b" && [ "$(node -e "console.log(JSON.parse(process.argv[1]).length)" "$S")" -le 64 ] && printf "%s" "$S" | grep -q "^\"api"'
check "G6: a stream that is not a string, or absent, is null" '[ "$(field demo-arch)" = null ] && [ "$(field demo-run)" = null ]'

echo "----"
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
