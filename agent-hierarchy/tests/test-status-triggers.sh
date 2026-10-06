#!/bin/bash
# agent-hierarchy — what keeps <hier>/status.json current: each shared write helper refreshes it
# (peers rows, message files, team files, decision rows, check-in rows), as do every session start,
# `roster.mjs status` and the /hierarchy command's config steps. A status write never changes what
# the triggering operation does: not when the file can't be written, and not when computing the
# document throws. The helpers and lib-status import each other, so every module must still load
# when it is the first one imported.
# HOME- and AGENT_HIERARCHY_DIR-redirected; real state untouched.
# Usage: bash tests/test-status-triggers.sh   (exits 0 iff all cases pass)

unset AH_TEAM_FILE  # every session roster.mjs launches carries one; a test must not inherit it
unset CLAUDE_PID  # every Claude session exports one; a test must not inherit it

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
. "$PLUGIN/tests/lib-status-pool.sh"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-status-triggers-test.XXXXXX")"
[ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] || { echo "mktemp failed"; exit 1; }
trap 'chmod -R u+w "$SANDBOX" 2>/dev/null; rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (OUT=${OUT:0:400})"; fi
}

# A status.json that no real write produces, so a refresh is visible as its replacement.
sentinel() { printf '{"written_at":"sentinel"}\n' > "$HD/status.json"; }
refreshed() { [ -f "$HD/status.json" ] && ! grep -q sentinel "$HD/status.json" && [ "$(node -e 'process.stdout.write(String(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).schema))' "$HD/status.json")" = 1 ]; }
untouched() { grep -q sentinel "$HD/status.json"; }
# <js statements>: run with lib-hier, lib-roster and lib-decisions imported as H, R and D, inside this pool.
js() { OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node --input-type=module -e "const H = await import('$H/lib-hier.mjs'); const R = await import('$H/lib-roster.mjs'); const D = await import('$H/lib-decisions.mjs'); const dir = process.argv[1]; $1" "$HD" 2>&1); RC=$?; }

pool "$SANDBOX/t"
team - '[{"role":"architect","name":"demo-architect","route":"pane","kind":"codex","transport_id":"w1:p1"}]'

# ---------------------------------------------------------------- AC 5: each trigger
sentinel; js "H.appendRosterRecord(dir, { status: 'seen', name: 'demo-architect', role: 'architect' });"
check "item 1: a peers.jsonl append (appendRosterRecord) refreshes status.json" '[ "$RC" = 0 ] && refreshed'
sentinel; OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/msg.mjs" new --to architect --from orchestrator --slug trig --cwd "$PROJ" 2>&1); RC=$?
check "item 2: msg.mjs new (createMessage) refreshes status.json" '[ "$RC" = 0 ] && refreshed'
ID=$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).id)' "$OUT")
sentinel; OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/msg.mjs" new --type response --id "$ID" --cwd "$PROJ" 2>&1); RC=$?
check "item 2: a response stub refreshes status.json" '[ "$RC" = 0 ] && refreshed'
sentinel; js "R.writeTeam(dir, R.readTeam(dir, null), null);"
check "item 3: a team-file write (writeTeam) refreshes status.json" '[ "$RC" = 0 ] && refreshed'
sentinel; js "R.writeTeam(dir, { members: [] }, 'spare'); "
sentinel; js "R.clearTeam(dir, 'spare');"
check "item 3: a team-file removal (clearTeam) refreshes status.json" '[ "$RC" = 0 ] && refreshed && [ ! -e "$HD/teams/spare.json" ]'
sentinel; js "D.appendMergeRecord(D.decisionLogPath(dir, '20260101-000000-zz01'), { pr: 1, sha: 'abc', method: 'merge' });"
check "item 4: a decisions.jsonl append refreshes status.json" '[ "$RC" = 0 ] && refreshed'
check "item 4: decided and parked rows reach the same append as merge rows" '[ "$(grep -cE "^  appendLine\(path, (line|\{ kind: \"merge\")" "$H/lib-decisions.mjs")" = 2 ] && grep -q "statusChanged(dirname(dirname(dirname(path))))" "$H/lib-decisions.mjs"'
sentinel; printf '{"session_id":"s6","cwd":"%s","hook_event_name":"SessionStart","source":"startup"}' "$PROJ" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/sessionstart.mjs" >/dev/null 2>&1; RC=$?
check "item 6: a non-role session start refreshes status.json" '[ "$RC" = 0 ] && refreshed'
disable; sentinel; printf '{"session_id":"s6b","cwd":"%s","hook_event_name":"SessionStart","source":"startup"}' "$PROJ" | HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/sessionstart.mjs" >/dev/null 2>&1; RC=$?
check "item 6: so does one with the hierarchy disabled" '[ "$RC" = 0 ] && refreshed && grep -q "\"enabled\":false" "$HD/status.json"'
rm -f "$FAKEHOME/.claude/agent-hierarchy.json"
sentinel; OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/roster.mjs" status --plain --cwd "$PROJ" 2>&1); RC=$?
check "item 7: roster.mjs status refreshes status.json" '[ "$RC" = 0 ] && refreshed'
check "item 8: /hierarchy runs roster.mjs status after each config write (init step 5, on/off)" '[ "$(grep -c "roster.mjs status --plain --cwd <abs cwd>" "$PLUGIN/commands/hierarchy.md")" = 2 ]'
dispatch "$ID" architect "$(node -e 'process.stdout.write(new Date().toISOString())')"
sentinel; js "H.appendGate(dir, { type: 'liveness-nudge', session_id: 'o', request_id: '$ID' });"
check "item 9: a liveness-nudge gate row refreshes status.json" '[ "$RC" = 0 ] && refreshed && grep -q "\"checkins\":1" "$HD/status.json"'
sentinel; js "H.appendGate(dir, { type: 'route', session_id: 'o' });"
check "item 9: any other gate row does not" '[ "$RC" = 0 ] && untouched'

# ---------------------------------------------------------------- AC 5: every module loads first
for m in lib-status lib-hier lib-roster lib-decisions lib-peer lib-config; do
  rm -f "$HD/status.json"
  OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node --input-type=module -e "await import('$H/$m.mjs'); const s = await import('$H/lib-status.mjs'); process.stdout.write(s.writeStatus(process.argv[1]) ? 'doc' : 'null');" "$PROJ" 2>&1); RC=$?
  check "load order: $m imported first loads cleanly and a status write succeeds" '[ "$RC" = 0 ] && [ "$OUT" = doc ] && [ -f "$HD/status.json" ]'
done

# ---------------------------------------------------------------- AC 6: write isolation
pool "$SANDBOX/ro"
OUT_W=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/msg.mjs" new --to architect --from orchestrator --slug writable --cwd "$PROJ" 2>"$SANDBOX/err-w"); RC_W=$?
rm -f "$HD/status.json"
chmod 555 "$HD"
OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/msg.mjs" new --to architect --from orchestrator --slug readonly --cwd "$PROJ" 2>"$SANDBOX/err-ro"); RC=$?
keys() { node -e 'process.stdout.write(Object.keys(JSON.parse(process.argv[1])).join())' "$1"; }
check "AC6: with status.json unwritable, msg.mjs new succeeds with the same output and exit code" '[ "$RC" = "$RC_W" ] && [ "$RC" = 0 ] && [ "$(keys "$OUT")" = "$(keys "$OUT_W")" ] && [ ! -s "$SANDBOX/err-ro" ] && [ -f "$(node -e "process.stdout.write(JSON.parse(process.argv[1]).path)" "$OUT")" ]'
check "AC6: and no status file or temp file is left" '[ ! -e "$HD/status.json" ] && [ -z "$(ls -a "$HD" | grep "\.tmp$")" ]'
chmod 755 "$HD"

# ---------------------------------------------------------------- a status computation that throws
pool "$SANDBOX/throw"
cat > "$SANDBOX/throw-hook.mjs" <<'EOF'
// Makes lib-status's computeStatus throw on entry, to prove no trigger lets that escape.
export async function load(url, context, next) {
  const res = await next(url, context);
  if (!url.endsWith("/lib-status.mjs")) return res;
  const source = String(res.source).replace(/export function computeStatus\(.*\) \{/, (m) => `${m} throw new Error("compute probe");`);
  return { ...res, source };
}
EOF
printf 'import { register } from "node:module";\nregister("./throw-hook.mjs", import.meta.url);\n' > "$SANDBOX/throw-register.mjs"
OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node --import "$SANDBOX/throw-register.mjs" "$H/roster.mjs" status --cwd "$PROJ" 2>&1); RC=$?
check "setup: the probe really makes the computation throw" '[ "$RC" != 0 ] && echo "$OUT" | grep -q "compute probe"'
sentinel
OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node --import "$SANDBOX/throw-register.mjs" "$H/msg.mjs" new --to architect --from orchestrator --slug probe --cwd "$PROJ" 2>&1); RC=$?
check "a throwing computation leaves msg.mjs new's own write and output intact" '[ "$RC" = 0 ] && [ -f "$(node -e "process.stdout.write(JSON.parse(process.argv[1]).path)" "$OUT")" ] && untouched'
OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node --import "$SANDBOX/throw-register.mjs" --input-type=module -e "const H = await import('$H/lib-hier.mjs'); H.appendRosterRecord(process.argv[1], { status: 'seen', name: 'probe', role: 'architect' }); H.appendGate(process.argv[1], { type: 'liveness-nudge', session_id: 'o', request_id: 'x' }); console.log('ok');" "$HD" 2>&1); RC=$?
check "and leaves appendRosterRecord's and appendGate's own rows intact" '[ "$RC" = 0 ] && [ "$OUT" = ok ] && grep -q "\"name\":\"probe\"" "$HD/peers.jsonl" && grep -q "\"request_id\":\"x\"" "$HD/gates.jsonl" && untouched'

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
