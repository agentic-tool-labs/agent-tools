#!/bin/bash
# agent-hierarchy — the mod is read-only: no module source under mod/ (its tests and types aside)
# names $.process, $.fs.write, $.session.send, $.tool, $.agent or $.model.
# Usage: bash tests/test-mod-readonly.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-mod-readonly-test.XXXXXX")"
[ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$SANDBOX"' EXIT
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (OUT=${OUT:0:400})"; fi
}

PAT='\$\.(process|fs\.write|session\.send|tool|agent|model)([^A-Za-z0-9_]|$)'
# <mod dir>: every forbidden $ call in the module source under it, as file:line:text.
forbidden() {
  grep -rnE --exclude-dir=tests --exclude-dir=types \
    --include='*.ts' --include='*.tsx' --include='*.jsx' --include='*.js' \
    --include='*.mjs' --include='*.cjs' --include='*.mts' --include='*.cts' "$PAT" "$1"
}

check "the mod's hooks module exists, so the guard has source to read" '[ -f "$PLUGIN/mod/register.tsx" ]'
OUT=$(forbidden "$PLUGIN/mod")
check "no module source under mod/ calls a forbidden \$ noun" '[ -z "$OUT" ]'

# The guard itself: each forbidden call planted in a copy is caught; near names and tests/ are not.
for call in '$.process.run(x)' '$.fs.write(p, t)' '$.session.send(m)' '$.tool.call(t)' '$.agent.spawn(a)' '$.model.ask(q)'; do
  rm -rf "$SANDBOX/mod"; cp -R "$PLUGIN/mod" "$SANDBOX/mod"
  printf '%s\n' "$call" >> "$SANDBOX/mod/register.tsx"
  OUT=$(forbidden "$SANDBOX/mod")
  check "guard catches $call" '[ -n "$OUT" ]'
done
rm -rf "$SANDBOX/mod"; cp -R "$PLUGIN/mod" "$SANDBOX/mod"
printf '%s\n' '$.tools.list()' '$.models.list()' '$.fs.read(p)' >> "$SANDBOX/mod/register.tsx"
mkdir -p "$SANDBOX/mod/tests"; printf '%s\n' "on('fs.write', () => ({ value: undefined }))" '$.fs.write(p, t)' > "$SANDBOX/mod/tests/x.test.ts"
OUT=$(forbidden "$SANDBOX/mod")
check "guard ignores \$.tools, \$.models, \$.fs.read and anything under tests/" '[ -z "$OUT" ]'

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
