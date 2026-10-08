#!/bin/bash
# agent-hierarchy — mod/tests/fixtures.ts embeds the status fixtures for the mod's tests, which cannot
# import JSON. It is generated, so this fails unless it is byte-identical to a fresh generation from the
# committed tests/fixtures/status/*.json: a changed, added or removed case, or a hand edit, cannot go unseen.
# Regenerate both: AH_UPDATE_FIXTURES=1 bash tests/test-status-fixtures.sh
# Usage: bash tests/test-mod-fixtures-drift.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-mod-fixtures-drift-test.XXXXXX")"
[ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$SANDBOX"' EXIT
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (OUT=${OUT:0:400})"; fi
}

FIXTURES="$PLUGIN/tests/fixtures/status"
MODULE="$PLUGIN/mod/tests/fixtures.ts"
# <fixtures dir> <module>: true when the module is exactly what the generator makes from that dir.
fresh() { node "$PLUGIN/tests/gen-mod-fixtures.mjs" "$1" > "$SANDBOX/fresh.ts" && cmp -s "$SANDBOX/fresh.ts" "$2"; }

check "mod/tests/fixtures.ts is byte-identical to a fresh generation from the committed fixtures" 'fresh "$FIXTURES" "$MODULE"'
OUT=$(head -n 1 "$MODULE")
check "its first line says it is generated and names the command that regenerates it" 'printf "%s" "$OUT" | grep -q "^// Generated .*AH_UPDATE_FIXTURES=1 bash tests/test-status-fixtures.sh"'
OUT=$(node -e '
  const fs = require("fs"), [mod, dir] = process.argv.slice(1);
  const body = fs.readFileSync(mod, "utf8").replace("export const fixtures: Readonly<Record<string, string>> =", "return");
  const map = new Function(body)();
  const files = fs.readdirSync(dir).filter((f) => f.endsWith(".json")).map((f) => f.slice(0, -5)).sort();
  const keys = Object.keys(map).sort();
  if (JSON.stringify(keys) !== JSON.stringify(files)) console.log("cases " + keys + " vs files " + files);
  for (const k of files) if (map[k] !== fs.readFileSync(dir + "/" + k + ".json", "utf8")) console.log("text differs: " + k);
' "$MODULE" "$FIXTURES" 2>&1)
check "its cases are exactly the fixture files, each mapped to that file's exact text" '[ -z "$OUT" ]'

# The check can fail: each kind of drift, in a temp copy.
reset_copy() { rm -rf "${SANDBOX:?}/fx"; cp -R "$FIXTURES" "$SANDBOX/fx"; cp "$MODULE" "$SANDBOX/fixtures.ts"; }
reset_copy
check "the untouched temp copy is not drift, so each failure below is the planted change" 'fresh "$SANDBOX/fx" "$SANDBOX/fixtures.ts"'
reset_copy; printf ' ' >> "$SANDBOX/fx/work.json"
check "a one-byte change to a fixture is drift" '! fresh "$SANDBOX/fx" "$SANDBOX/fixtures.ts"'
reset_copy; cp "$SANDBOX/fx/idle.json" "$SANDBOX/fx/added.json"
check "an added fixture is drift" '! fresh "$SANDBOX/fx" "$SANDBOX/fixtures.ts"'
reset_copy; rm "$SANDBOX/fx/bad.json"
check "a removed fixture is drift" '! fresh "$SANDBOX/fx" "$SANDBOX/fixtures.ts"'
reset_copy; printf ' ' >> "$SANDBOX/fixtures.ts"
check "a hand edit to fixtures.ts is drift" '! fresh "$SANDBOX/fx" "$SANDBOX/fixtures.ts"'

# mod/tests/main-vectors.ts is the shared cases for the mod's mirror of lib-config's mainCheckoutRoot; it is generated
# from that function, so a change to the function (or a hand edit to the file) cannot go unseen.
VECTORS="$PLUGIN/mod/tests/main-vectors.ts"
check "mod/tests/main-vectors.ts is byte-identical to a fresh generation from lib-config's mainCheckoutRoot" 'node "$PLUGIN/tests/gen-mod-main-vectors.mjs" | cmp -s - "$VECTORS"'
cp "$VECTORS" "$SANDBOX/main-vectors.ts"; printf ' ' >> "$SANDBOX/main-vectors.ts"
check "a hand edit to main-vectors.ts is drift" '! node "$PLUGIN/tests/gen-mod-main-vectors.mjs" | cmp -s - "$SANDBOX/main-vectors.ts"'

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
