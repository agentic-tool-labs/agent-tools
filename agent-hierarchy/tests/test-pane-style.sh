#!/bin/bash
# agent-hierarchy — the sectioned Pane's style table stays the one place for icons and colors (I3), and the status
# document carries a member's stream, cleaned and cut (G7). Every write lands in a sandbox pool.
# Usage: bash tests/test-pane-style.sh   (exits 0 iff all cases pass)

. "$(dirname "$0")/lib-hermetic.sh"
unset AH_TEAM_FILE  # every session roster.mjs launches carries one; a test must not inherit it
unset CLAUDE_PID  # every Claude session exports one; a test must not inherit it

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
. "$PLUGIN/tests/lib-status-pool.sh"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-pane-style-test.XXXXXX")"
[ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] || { echo "mktemp failed"; exit 1; }
hermetic_on_exit 'rm -rf "$SANDBOX"'
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

# ---- F10: the mod's name pattern is lib-config's
pat() { grep -o '/^\[a-z\]\[a-z0-9_-\]{0,31}\$/' "$1" | head -1; }
MP=$(pat "$REG"); LP=$(pat "$PLUGIN/hooks/lib-config.mjs")
check "F10: the pattern in the pinned helper is string-equal to validateHerdrName's" '[ -n "$MP" ] && [ "$MP" = "$LP" ]'

# ---- F11: focusable
LONG33=$(node -e 'process.stdout.write("a".repeat(33))')
mem() { printf '{"role":"implementor","name":"%s","route":"peer","kind":"claude"%s}' "$1" "$2"; }
team - "[$(mem demo-ok ',"transport":"herdr","transport_id":"w1:p1"'),$(mem demo-tmux ',"transport":"tmux","transport_id":"%3"'),$(mem demo-term ',"transport":"terminal","transport_id":"x"'),$(mem demo-noid ',"transport":"herdr"'),$(mem demo-emptyid ',"transport":"herdr","transport_id":""'),$(mem Demo-Upper ',"transport":"herdr","transport_id":"w1:p2"'),$(mem "$LONG33" ',"transport":"herdr","transport_id":"w1:p3"'),$(mem demo-none ''),$(mem demo-num ',"transport":"herdr","transport_id":7')]"
(cd "$SANDBOX" && HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/roster.mjs" status --cwd "$PROJ" >/dev/null 2>&1)
foc() { node -e 'try { const o = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); console.log(JSON.stringify(o.teams[0].members.find((m) => m.name === process.argv[2]).focusable)); } catch (e) { console.log("none"); }' "$HD/status.json" "$1"; }
check "F11: a herdr member with a transport id and a valid name is focusable" '[ "$(foc demo-ok)" = true ]'
for n in demo-tmux demo-term demo-noid demo-emptyid Demo-Upper "$LONG33" demo-none demo-num; do
  check "F11: $n is not focusable" '[ "$(foc "$n")" = false ]'
done

# F11: the transport a real team file records is the team's, not each member's
teamT() { # <team transport JSON, or "" for none> <members JSON>
  node -e 'const [p, t, members, pid] = process.argv.slice(1); const o = { team_id: "t-demo", created: new Date().toISOString(), orchestrator: { session_id: null, pid: Number(pid) }, members: JSON.parse(members) }; if (t) o.transport = JSON.parse(t); require("fs").writeFileSync(p, JSON.stringify(o) + "\n")' "$HD/team.json" "$1" "$2" "$$"
  (cd "$SANDBOX" && HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/roster.mjs" status --cwd "$PROJ" >/dev/null 2>&1)
}
MIDS="$(mem demo-a ',"transport_id":"w1:p1"'),$(mem demo-b ',"transport":"tmux","transport_id":"%3"')"
teamT '"herdr"' "[$MIDS]"
check "F11: a member with no transport of its own takes the team's herdr and is focusable" '[ "$(foc demo-a)" = true ]'
check "F11: a member's own transport wins over the team's" '[ "$(foc demo-b)" = false ]'
teamT '"tmux"' "[$MIDS]"
check "F11: a team transport that is not herdr leaves a member with none unfocusable" '[ "$(foc demo-a)" = false ]'
teamT '"terminal"' "[$(mem demo-a ',"transport_id":"w1:p1"'),$(mem demo-c ',"transport":"herdr","transport_id":"w1:p2"')]"
check "F11: a member's own herdr is focusable under a non-herdr team" '[ "$(foc demo-c)" = true ] && [ "$(foc demo-a)" = false ]'
teamT '' "[$(mem demo-a ',"transport_id":"w1:p1"')]"
check "F11: no transport on the team or the member is unfocusable" '[ "$(foc demo-a)" = false ]'

echo "----"
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
