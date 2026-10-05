#!/bin/bash
# agent-hierarchy — one definition per shared behaviour in hooks/: the eta threshold table, the
# hook-event→self-state table and the "is this response a report" predicate. reportStatus is
# driven through each of its outcomes against real msg.mjs-created files.
# HOME- and AGENT_HIERARCHY_DIR-redirected; real state untouched.
# Usage: bash tests/test-status-single-source.sh   (exits 0 iff all cases pass)

unset AH_TEAM_FILE  # every session roster.mjs launches carries one; a test must not inherit it
unset CLAUDE_PID  # every Claude session exports one; a test must not inherit it

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
MSG="$H/msg.mjs"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-status-single-source-test.XXXXXX")"
[ -n "$SANDBOX" ] || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
HD="$SANDBOX/hier"
PROJ="$SANDBOX/proj"
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (OUT=${OUT:0:500})"; fi
}

# Lines in hooks/*.mjs matching an extended regex.
defs() { grep -hE "$1" "$H"/*.mjs | wc -l | tr -d ' '; }
# The hooks/*.mjs files with a line matching an extended regex.
where() { grep -lE "$1" "$H"/*.mjs | xargs -n1 basename | tr '\n' ' '; }

ETA_TABLE='\bsmall"?:[[:space:]]*[0-9]'
EVENT_TABLE='UserPromptSubmit:[[:space:]]*"working"'
check "AC7: the eta threshold table is defined once in hooks/, in lib-hier" '[ "$(defs "$ETA_TABLE")" = 1 ] && [ "$(where "$ETA_TABLE")" = "lib-hier.mjs " ]'
check "AC7: the eta fallback (thresholdFor) is defined once in hooks/, in lib-hier" '[ "$(defs "function[[:space:]]+thresholdFor\b")" = 1 ] && [ "$(where "function[[:space:]]+thresholdFor\b")" = "lib-hier.mjs " ]'
# `import … from "./lib-hier.mjs"` or a bare `import "./lib-hier.mjs"`; the dynamic `import("./lib-hier.mjs")` matches neither.
STATIC_LIB_HIER='from[[:space:]]*.\./lib-hier\.mjs|^[[:space:]]*import[[:space:]]+.\./lib-hier\.mjs'
check "AC7: stream-label has no static import from ./lib-hier.mjs" '! grep -qE "$STATIC_LIB_HIER" "$H/stream-label.mjs" && grep -q "import(\"./lib-hier.mjs\")" "$H/stream-label.mjs"'
check "AC7: the hook-event→self-state table is defined once in hooks/, in lib-hier" '[ "$(defs "$EVENT_TABLE")" = 1 ] && [ "$(where "$EVENT_TABLE")" = "lib-hier.mjs " ]'
check "AC7: the check-in cadence is defined once in hooks/, in lib-hier" '[ "$(defs "CHECKIN_CADENCE[[:space:]]*=")" = 1 ] && [ "$(where "CHECKIN_CADENCE[[:space:]]*=")" = "lib-hier.mjs " ]'
# Hooks other than lib-hier with a line that scales the eta threshold by a cadence number of their own.
cadence_leaks() {
  local f
  for f in "$H"/*.mjs; do
    [ "$(basename "$f")" = lib-hier.mjs ] && continue
    grep -E "thresholdFor|ETA_THRESHOLD_SEC" "$f" | grep -qE '0?\.5\b|1\.5\b|/[[:space:]]*2\b' && basename "$f"
  done
}
check "AC7: the cadence numbers exist only in the shared lib" '[ -z "$(cadence_leaks)" ]'
check "AC7: the dispatch-origin function is defined once in hooks/, in lib-peer" '[ "$(defs "function[[:space:]]+dispatchOrigin\b")" = 1 ] && [ "$(where "function[[:space:]]+dispatchOrigin\b")" = "lib-peer.mjs " ]'
check "AC7: only lib-peer selects dispatch rows from the peer records" '[ "$(where "type[[:space:]]*===[[:space:]]*\"dispatch\"")" = "lib-peer.mjs " ]'
check "AC7: no hook restates the self-state values as a list" '[ "$(defs "\"working\",[[:space:]]*\"idle\",[[:space:]]*\"blocked\"")" = 0 ]'
check "AC7/AC24: reportStatus is defined once in hooks/, in lib-hier" '[ "$(defs "function[[:space:]]+reportStatus\b")" = 1 ] && [ "$(where "function[[:space:]]+reportStatus\b")" = "lib-hier.mjs " ]'
check "AC24: no byte comparison against the response skeleton remains in hooks/" '[ "$(defs "responseSkeleton")" = 0 ]'

msg() { OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$MSG" --cwd "$PROJ" "$@" 2>&1); RC=$?; }
status() { OUT=$(node --input-type=module -e "import { reportStatus } from '$H/lib-hier.mjs'; console.log(reportStatus(process.argv[1], process.argv[2]));" "$1" "$2" 2>&1); }

msg new --type request --to architect --from orchestrator --slug single-src
REQ=$(echo "$OUT" | grep -oE '/[^ ]*--request\.md' | head -1)
ID=$(basename "$REQ" | cut -d- -f1-3)
msg new --type response --id "$ID"
RESP=$(echo "$OUT" | grep -oE '/[^ ]*--response\.md' | head -1)
check "setup: msg.mjs created a request and its skeleton response" '[ -f "$REQ" ] && [ -f "$RESP" ]'

status "$SANDBOX/missing--response.md" "$ID"
check "AC24: a missing response file is no-report" '[ "$OUT" = no-report ]'

status "$RESP" "$ID"
check "AC24: the skeleton response as msg.mjs wrote it is no-report" '[ "$OUT" = no-report ]'

# Body lines reversed below the frontmatter: still nothing authored, and no longer byte-identical.
FM_END=$(grep -n '^---$' "$RESP" | sed -n 2p | cut -d: -f1)
{ head -n "$FM_END" "$RESP"; tail -n +"$((FM_END + 1))" "$RESP" | awk '{ l[NR] = $0 } END { for (i = NR; i > 0; i--) print l[i] }'; } > "$SANDBOX/reordered.md"
check "setup: the reordered skeleton differs from the original" '! cmp -s "$RESP" "$SANDBOX/reordered.md"'
status "$SANDBOX/reordered.md" "$ID"
check "AC24: a reordered skeleton is no-report" '[ "$OUT" = no-report ]'

sed "s/^id: .*/id: 20000101-000000-zzzz/" "$RESP" > "$SANDBOX/wrong-id.md"
status "$SANDBOX/wrong-id.md" "$ID"
check "AC24: a frontmatter carrying another id is malformed-report" '[ "$OUT" = malformed-report ]'

tail -n +"$((FM_END + 1))" "$RESP" > "$SANDBOX/no-frontmatter.md"
status "$SANDBOX/no-frontmatter.md" "$ID"
check "AC24: a response with no frontmatter is malformed-report" '[ "$OUT" = malformed-report ]'

printf -- '- done: built and tested\n' >> "$RESP"
status "$RESP" "$ID"
check "AC24: a response with one authored line is reported" '[ "$OUT" = reported ]'

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
