#!/bin/bash
# agent-hierarchy — the one open rule for exchanges: a member-addressed exchange is open until its
# response holds a report; an orchestrator-addressed one (the pipeline's run records, a role's
# request to the Orchestrator) closes on any response. Covers msg.mjs list, sweep, anchor liveness
# and the pipeline skill's record wording.
# HOME- and AGENT_HIERARCHY_DIR-redirected; real state untouched.
# Usage: bash tests/test-exchange-open.sh   (exits 0 iff all cases pass)

. "$(dirname "$0")/lib-hermetic.sh"
unset AH_TEAM_FILE  # every session roster.mjs launches carries one; a test must not inherit it
unset CLAUDE_PID  # every Claude session exports one; a test must not inherit it

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
H="$PLUGIN/hooks"
MSG="$H/msg.mjs"
SKILL="$PLUGIN/skills/autonomous-pipeline/SKILL.md"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-exchange-open-test.XXXXXX")"
[ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] || { echo "mktemp failed"; exit 1; }
hermetic_on_exit 'rm -rf "$SANDBOX"'
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/proj"
mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude"
HD="$SANDBOX/hier"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (OUT=${OUT:0:500})"; fi
}

msg() { OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$MSG" --cwd "$PROJ" "$@" 2>&1); RC=$?; }
jget() { node -e 'const o=JSON.parse(process.argv[1]);const v=(new Function("o","return ("+process.argv[2]+")"))(o);process.stdout.write(typeof v==="string"?v:JSON.stringify(v))' "$OUT" "$1" 2>/dev/null; }
# <to> <from> <slug> [--team <t>]: a request; its id lands in ID and its path in REQ.
request() { msg new --to "$1" --from "$2" --slug "$3" "${@:4}"; ID=$(jget o.id); REQ=$(jget o.path); }
# <id> [--team <t>]: msg.mjs's bodyless (skeleton) response; its path lands in RESP.
stub() { msg new --type response --id "$1" "${@:2}"; RESP=$(jget o.path); }
fill() { printf -- '- done: reported\n' >> "$1"; }
# <id> [--open|--closed|--all]: that exchange's state in msg.mjs list, or empty when not listed.
state() { msg list "${2:---all}" --plain; echo "$OUT" | awk -v id="$1" '$1 == id { print $NF }'; }

# ---------------------------------------------------------------- AC 17: msg.mjs list
request architect orchestrator m-stub; M1=$ID; stub "$M1"; M1R=$RESP
check "member-addressed request + skeleton stub → open" '[ "$(state "$M1")" = open ] && [ "$(state "$M1" --open)" = open ]'
fill "$M1R"
check "the same exchange once its response is filled → closed" '[ "$(state "$M1")" = closed ] && [ -z "$(state "$M1" --open)" ]'

request architect orchestrator m-nofm; M2=$ID; stub "$M2"
FM_END=$(grep -n '^---$' "$RESP" | sed -n 2p | cut -d: -f1)
tail -n +"$((FM_END + 1))" "$RESP" > "$RESP.tmp" && mv "$RESP.tmp" "$RESP"
check "a member response without frontmatter → closed" '! head -1 "$RESP" | grep -q "^---$" && [ "$(state "$M2")" = closed ]'

request orchestrator orchestrator rec-x; O1=$ID; stub "$O1"
check "orchestrator-addressed record + bodyless response → closed" '[ "$(state "$O1")" = closed ]'

request orchestrator architect role-ask; R1=$ID; stub "$R1"
check "a role's request to the orchestrator + bodyless response → closed" '[ "$(state "$R1")" = closed ]'

request reviewer orchestrator m-open; M3=$ID; stub "$M3"
ids_in() { msg list "$1" --plain; echo "$OUT" | awk '{ print $1 }' | sort | tr '\n' ' '; }
ids_all_with() { msg list --all --plain; echo "$OUT" | awk -v s="$1" '$NF == s { print $1 }' | sort | tr '\n' ' '; }
check "--closed lists exactly the --all rows marked closed" '[ "$(ids_in --closed)" = "$(ids_all_with closed)" ] && [ -n "$(ids_all_with closed)" ]'
check "--open lists exactly the --all rows marked open" '[ "$(ids_in --open)" = "$(ids_all_with open)" ] && [ "$(ids_all_with open)" = "$M3 " ]'

# ---------------------------------------------------------------- AC 18: sweep
HD="$SANDBOX/hier-sweep"
OLD=$(node -e 'process.stdout.write(new Date(Date.now() - 8 * 86400 * 1000).toISOString())')
age() { perl -pi -e "s/^created: .*/created: $OLD/" "$1"; }
request architect orchestrator s-stub; S1Q=$REQ; stub "$ID"; S1R=$RESP; age "$S1R"
request architect orchestrator s-filled; S2Q=$REQ; stub "$ID"; S2R=$RESP; fill "$S2R"; age "$S2R"
request orchestrator orchestrator s-rec; S3Q=$REQ; stub "$ID"; S3R=$RESP; age "$S3R"
msg sweep
ARCH="$HD/msgs/archive"
archived() { [ ! -e "$1" ] && [ -e "$ARCH/$(basename "$1")" ]; }
check "sweep: an 8-day-old stub-only member pair is not archived" '[ "$RC" = 0 ] && [ -e "$S1Q" ] && [ -e "$S1R" ]'
check "sweep: an 8-day-old filled member pair is archived" 'archived "$S2Q" && archived "$S2R"'
check "sweep: an 8-day-old stub-closed orchestrator record is archived" 'archived "$S3Q" && archived "$S3R"'

# ---------------------------------------------------------------- AC 23: run records unchanged
HD="$SANDBOX/hier-run"
runs() {
  OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node --input-type=module -e "
    import { pipelineRunLive } from '$H/lib-hier.mjs';
    import { liveRun, runLiveness } from '$H/lib-decisions.mjs';
    const r = liveRun(process.argv[1]);
    console.log(JSON.stringify({ live: pipelineRunLive(process.argv[1]), run: r && r.id, liveness: runLiveness(process.argv[1]) }));
  " "$PROJ" 2>&1)
}
request orchestrator orchestrator pipeline-run-anchor --team t; A1=$ID
msg new --type response --id "$A1" --to orchestrator --from orchestrator --slug pipeline-run-anchor --team t
runs
check "an anchor closed by a bodyless response: pipelineRunLive false, liveRun null, runLiveness not" '[ "$(jget o.live)" = false ] && [ "$(jget o.run)" = null ] && [ "$(jget o.liveness)" = not ]'
request orchestrator orchestrator pipeline-run-anchor --team t; A2=$ID
runs
check "the same pool with a second, open anchor: exactly that run is live" '[ "$(jget o.live)" = true ] && [ "$(jget o.run)" = "$A2" ] && [ "$(jget o.liveness)" = live ]'

# ---------------------------------------------------------------- AC 25: the skill's record wording
check "the pipeline skill never asks for a response body on a record close" '! grep -q "body \`closed:" "$SKILL" && ! grep -q "as the response body" "$SKILL"'
check "the pipeline skill gives the orchestrator-addressed record request command once" '[ "$(grep -c "msg.mjs new --type request --to orchestrator --from orchestrator" "$SKILL")" = 1 ]'

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
