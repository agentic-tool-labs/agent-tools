#!/bin/bash
# agent-hierarchy — an event write of the status document by a process whose own config is disabled keeps the
# `enabled` already published, so a differently configured session cannot hide a live team's view; an explicit
# write (`roster.mjs status`) still uses the writer's own config. Every write lands in a sandbox pool.
# Usage: bash tests/test-status-inherit.sh   (exits 0 iff all cases pass)

. "$(dirname "$0")/lib-hermetic.sh"
unset AH_TEAM_FILE  # every session roster.mjs launches carries one; a test must not inherit it
unset CLAUDE_PID  # every Claude session exports one; a test must not inherit it

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
. "$PLUGIN/tests/lib-status-pool.sh"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-status-inherit-test.XXXXXX")"
[ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (OUT=${OUT:0:400})"; fi
}

ARCH='{"role":"architect","name":"demo-architect","route":"pane","kind":"codex","transport_id":"w1:p1"}'
now_iso() { node -e 'process.stdout.write(new Date().toISOString())'; }

pool "$SANDBOX/p"
ON_HOME="$POOL/on-home"; OFF_HOME="$POOL/off-home"; CFG_HOME="$POOL/cfg-on-home"
mkdir -p "$ON_HOME/.claude" "$OFF_HOME/.claude" "$CFG_HOME/.claude"
echo '{"enabled": false}' > "$OFF_HOME/.claude/agent-hierarchy.json"
echo '{"enabled": true}' > "$CFG_HOME/.claude/agent-hierarchy.json"
team - "[$ARCH]"
activity pane-demo-architect idle "$(now_iso)"

# <home>: the explicit write, as `roster.mjs status` makes it (and `/hierarchy on|off` through it).
explicit() { (cd "$SANDBOX" && HOME="$1" AGENT_HIERARCHY_DIR="$HD" node "$H/roster.mjs" status --cwd "$PROJ" >/dev/null 2>&1); }
# <home>: an event write, as a hook makes it: a Stop of a session that is not a role session.
event() { (cd "$SANDBOX" && printf '{"hook_event_name":"Stop","session_id":"sess-plain-9","cwd":"%s"}' "$PROJ" | HOME="$1" AGENT_HIERARCHY_DIR="$HD" node "$H/activity.mjs" >/dev/null 2>&1); RC=$?; }
# <home>: a session start, whose writeStatus is the other event writer.
sstart() { (cd "$SANDBOX" && printf '{"session_id":"sess-plain-8","cwd":"%s","hook_event_name":"SessionStart","source":"startup"}' "$PROJ" | HOME="$1" AGENT_HIERARCHY_DIR="$HD" node "$H/sessionstart.mjs" >/dev/null 2>&1); RC=$?; }
# <js over the document o>: its value from <hier>/status.json, "none" when there is no file.
doc() { node -e 'try { const o = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); const v = (new Function("o", "return (" + process.argv[2] + ")"))(o); process.stdout.write(typeof v === "string" ? v : JSON.stringify(v)); } catch { process.stdout.write("none"); }' "$HD/status.json" "$1"; }
state_now() { # <dispatch id>: the current state of that dispatch in the document
  doc "(d => d ? d.states.filter(s => Date.parse(s.at) <= Date.now()).pop()?.state ?? 'none-yet' : 'absent')(o.teams.flatMap(t => t.dispatches).find(d => d.id === '$1'))"
}

# ---- W1: an enabled doc on disk survives an event write by a disabled process
explicit "$ON_HOME"
check "setup: the enabled writer publishes enabled:true and a visible entry" '[ "$(doc o.enabled)" = true ] && [ "$(doc "o.timeline[0].visible")" = true ]'
rm -f "$HD/status.json"; explicit "$ON_HOME"; W0=$(doc o.written_at); sleep 1.1
event "$OFF_HOME"
check "W1: an event write under a disabled config rewrites the doc and keeps enabled:true, entry visible:true" '[ "$RC" = 0 ] && [ "$(doc o.written_at)" != "$W0" ] && [ "$(doc o.enabled)" = true ] && [ "$(doc "o.timeline[0].visible")" = true ] && [ "$(doc o.teams.length)" = 1 ]'

# ---- W1b: nothing is stale: a disabled process that changes team state publishes it at once
ID="20260101-000000-w1b0"; NOWT=$(now_iso)
request "$ID" architect w1b "$NOWT" small demo-architect
for hm in "$ON_HOME" "$OFF_HOME" "$CFG_HOME"; do
  printf '{"type":"dispatch","session_id":"orch","request_id":"%s","to":"architect","created":"%s"}\n' "$ID" "$NOWT" >> "$hm/.claude/agent-hierarchy.peer-pending.jsonl"
done
explicit "$ON_HOME"
check "W1b setup: the dispatch is listed and working" '[ "$(state_now "$ID")" = working ]'
W0=$(doc o.written_at); sleep 1.1
(cd "$SANDBOX" && HOME="$OFF_HOME" AGENT_HIERARCHY_DIR="$HD" node "$H/msg.mjs" new --type response --id "$ID" --cwd "$PROJ" >/dev/null 2>&1)
check "W1b: the response created under a disabled config rewrites the doc at once, still enabled:true" '[ "$(doc o.written_at)" != "$W0" ] && [ "$(doc o.enabled)" = true ]'
RESP=$(ls "$HD"/msgs/"$ID"--*--response.md 2>/dev/null | head -1)
printf -- '- done: reported\n' >> "$RESP"; sleep 1.1
(cd "$SANDBOX" && HOME="$OFF_HOME" AGENT_HIERARCHY_DIR="$HD" node "$H/msg.mjs" new --to architect --from orchestrator --slug w1b-next --cwd "$PROJ" >/dev/null 2>&1)
check "W1b: a later team-state change by the same disabled process shows that dispatch reported" '[ "$(state_now "$ID")" = reported ] && [ "$(doc o.enabled)" = true ]'

# ---- W2: the session-start writer inherits too
rm -f "$HD/status.json"; explicit "$ON_HOME"; W0=$(doc o.written_at); sleep 1.1
sstart "$OFF_HOME"
check "W2: a session start under a disabled config rewrites the doc and keeps enabled:true, visible:true" '[ "$RC" = 0 ] && [ "$(doc o.written_at)" != "$W0" ] && [ "$(doc o.enabled)" = true ] && [ "$(doc "o.timeline[0].visible")" = true ]'

# ---- W3, W4: an explicit write still hides, and event writes then keep it hidden
explicit "$OFF_HOME"
check "W3: roster.mjs status under a disabled config publishes enabled:false, visible:false" '[ "$(doc o.enabled)" = false ] && [ "$(doc "o.timeline[0].visible")" = false ]'
event "$OFF_HOME"
check "W4: an event write under the same disabled config keeps enabled:false, visible:false" '[ "$RC" = 0 ] && [ "$(doc o.enabled)" = false ] && [ "$(doc "o.timeline[0].visible")" = false ]'

# ---- W5: no doc on disk: the disabled event writer publishes false, the next enabled event restores true
rm -f "$HD/status.json"
event "$OFF_HOME"
check "W5: no doc on disk, event write under a disabled config -> enabled:false" '[ "$(doc o.enabled)" = false ] && [ "$(doc "o.timeline[0].visible")" = false ]'
event "$ON_HOME"
check "W5: the next event write under an enabled config -> enabled:true, visible:true" '[ "$(doc o.enabled)" = true ] && [ "$(doc "o.timeline[0].visible")" = true ]'

# ---- W6, must NOT change: an enabled or config-less writer imposes its own enabled over a doc that says false
explicit "$OFF_HOME"
event "$ON_HOME"
check "W6: event write with no config over a doc that says enabled:false -> enabled:true" '[ "$(doc o.enabled)" = true ]'
explicit "$OFF_HOME"
event "$CFG_HOME"
check "W6: event write under a config with enabled:true over a doc that says enabled:false -> enabled:true" '[ "$(doc o.enabled)" = true ]'

# ---- W7: an unusable doc on disk counts as no doc: the disabled writer publishes false, and nothing throws
unusable() { # <label> <js body that rewrites status.json given its path p and a valid doc d>
  rm -f "$HD/status.json"; explicit "$ON_HOME"
  node -e 'const fs = require("fs"); const p = process.argv[1]; const d = JSON.parse(fs.readFileSync(p, "utf8")); '"$2" "$HD/status.json"
  event "$OFF_HOME"
  check "W7: $1 + a disabled event writer -> exit 0, enabled:false" '[ "$RC" = 0 ] && [ "$(doc o.enabled)" = false ] && [ "$(doc o.schema)" = 1 ]'
}
unusable "a doc that is not JSON" 'fs.writeFileSync(p, "not json {")'
unusable "a symlink to a valid doc" 'fs.writeFileSync(p + ".real", JSON.stringify(d)); fs.unlinkSync(p); fs.symlinkSync(p + ".real", p)'
unusable "an expired doc" 'd.expires_at = "2020-01-01T00:00:00.000Z"; fs.writeFileSync(p, JSON.stringify(d))'
unusable "schema 2" 'd.schema = 2; fs.writeFileSync(p, JSON.stringify(d))'
unusable "a doc over 262,144 bytes" 'd.pad = "x".repeat(262144); fs.writeFileSync(p, JSON.stringify(d))'
unusable "enabled that is not a boolean" 'd.enabled = "yes"; fs.writeFileSync(p, JSON.stringify(d))'
rm -f "$HD/status.json" "$HD/status.json.real"; explicit "$ON_HOME"
node -e 'const fs = require("fs"); const p = process.argv[1]; const d = JSON.parse(fs.readFileSync(p, "utf8")); d.pad = "x".repeat(200000); fs.writeFileSync(p, JSON.stringify(d))' "$HD/status.json"
event "$OFF_HOME"
check "W7, must NOT change: a doc under the size cap is still read, so enabled:true is kept" '[ "$(doc o.enabled)" = true ]'

# ---- W8: the hooks-side cap equals the mod's
HC=$(sed -nE 's/^export const STATUS_SIZE_CAP = ([0-9]+);.*/\1/p' "$H/lib-status.mjs")
MC=$(sed -nE 's/^export const SIZE_CAP = ([0-9]+).*/\1/p' "$PLUGIN/mod/view.ts")
check "W8: the hooks status-size cap ($HC) equals the mod's SIZE_CAP ($MC)" '[ -n "$HC" ] && [ "$HC" = "$MC" ]'

echo "----"
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
