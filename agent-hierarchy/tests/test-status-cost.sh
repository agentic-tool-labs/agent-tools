#!/bin/bash
# agent-hierarchy — what keeps one status write cheap: the dispatch-origin function answers for many
# requests from one read of the dispatch rows, openRunAnchor reuses an exchange list already in hand,
# a large member response is closed from its size alone, and a status write lists the exchanges
# once and reads the dispatch-row file once.
# HOME- and AGENT_HIERARCHY_DIR-redirected; real state untouched.
# Usage: bash tests/test-status-cost.sh   (exits 0 iff all cases pass)

unset AH_TEAM_FILE  # every session roster.mjs launches carries one; a test must not inherit it
unset CLAUDE_PID  # every Claude session exports one; a test must not inherit it

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
. "$PLUGIN/tests/lib-status-pool.sh"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-status-cost-test.XXXXXX")"
[ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] || { echo "mktemp failed"; exit 1; }
trap 'chmod -R u+rw "$SANDBOX" 2>/dev/null; rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (OUT=${OUT:0:400})"; fi
}
# <module js>: run it inside this pool with lib-hier, lib-peer and lib-decisions as H, P and D; stdout in OUT.
js() { OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node --input-type=module -e "const H = await import('$H/lib-hier.mjs'); const P = await import('$H/lib-peer.mjs'); const D = await import('$H/lib-decisions.mjs'); const dir = process.argv[1]; $1" "$HD" 2>&1); RC=$?; }

REF="2026-03-01T12:00:00.000Z"

# ---------------------------------------------------------------- the origin function over a set of ids
pool "$SANDBOX/origins"
dispatch r1 architect "2026-03-01T11:00:00.000Z" s1
dispatch r1 architect "2026-03-01T10:00:00.000Z" s2
dispatch r2 reviewer "not-a-time" s1
dispatch r3 reviewer "2026-03-01T09:30:00.000Z" s1
js "
const reqs = [{ id: 'r1', created: '2026-03-01T08:00:00.000Z' }, { id: 'r2', created: '2026-03-01T07:00:00.000Z' }, { id: 'r3', created: null }, { id: 'none', created: '2026-03-01T06:00:00.000Z' }];
const batch = P.dispatchOrigin(reqs);
const single = reqs.map((r) => P.dispatchOrigin([r]).get(r.id));
console.log(JSON.stringify(reqs.map((r) => batch.get(r.id))) + ' ' + JSON.stringify(single));"
check "origins for several ids in one call equal one call per id: earliest row, corrupt-row fallback, no row → null" '[ "$OUT" = "[\"2026-03-01T10:00:00.000Z\",\"2026-03-01T07:00:00.000Z\",\"2026-03-01T09:30:00.000Z\",null] [\"2026-03-01T10:00:00.000Z\",\"2026-03-01T07:00:00.000Z\",\"2026-03-01T09:30:00.000Z\",null]" ]'

# ---------------------------------------------------------------- openRunAnchor with the list in hand
pool "$SANDBOX/anchors"
same_anchor() { js "const ex = H.listExchanges(dir); console.log(JSON.stringify(D.openRunAnchor(dir, 't', ex)) === JSON.stringify(D.openRunAnchor(dir, 't')) ? 'same ' + JSON.stringify(D.openRunAnchor(dir, 't', ex)) : 'differs');"; }
same_anchor
check "openRunAnchor with a passed list equals the listing one: no anchor" '[[ "$OUT" == "same {\"error\":"* ]]'
request 20260301-110000-a001 orchestrator pipeline-run-anchor "$(at -3600000)" small null t
same_anchor
check "...one open anchor" '[ "$OUT" = "same {\"id\":\"20260301-110000-a001\"}" ]'
request 20260301-110500-a002 orchestrator pipeline-run-anchor "$(at -3000000)" small null t
same_anchor
check "...two open anchors" '[[ "$OUT" == "same {\"error\":\"2 open"* ]]'

# ---------------------------------------------------------------- a response over 4 KB is closed unread
pool "$SANDBOX/big"
request 20260301-110000-b001 architect big "$(at -60000)" small demo-architect
BIG="$HD/msgs/20260301-110000-b001--orchestrator--big--response.md"
node -e 'require("fs").writeFileSync(process.argv[1], "x".repeat(5 * 1024))' "$BIG"
chmod 000 "$BIG"
js "console.log(String(H.listExchanges(dir).find((e) => e.id === '20260301-110000-b001').open));"
check "a 5 KB member response with no frontmatter, unreadable, is closed: listExchanges never read it" '[ "$RC" = 0 ] && [ "$OUT" = false ]'
chmod 644 "$BIG"

# ---------------------------------------------------------------- one listing and one dispatch-row read per write
pool "$SANDBOX/count"
team t '[{"role":"architect","name":"demo-architect","route":"pane","kind":"codex","transport_id":"w1:p1"},{"role":"reviewer","name":"demo-reviewer","route":"pane","kind":"codex","transport_id":"w1:p2"}]'
request 20260301-110000-c000 orchestrator pipeline-run-anchor "$(at -3600000)" small null t
for n in 1 2 3; do
  request "20260301-11000$n-c00$n" architect "c-$n" "$(at -600000)" small demo-architect t
  dispatch "20260301-11000$n-c00$n" architect "$(at -600000)"
  stub "20260301-11000$n-c00$n"
done
OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node --input-type=module -e "
import fs from 'node:fs';
import { syncBuiltinESMExports } from 'node:module';
const [dir, pending, cwd] = process.argv.slice(1);
const msgs = dir + '/msgs';
const count = { list: 0, rows: 0 };
const readdir = fs.readdirSync, read = fs.readFileSync;
fs.readdirSync = function (p, ...a) { if (String(p) === msgs) count.list++; return readdir.call(this, p, ...a); };
fs.readFileSync = function (p, ...a) { if (String(p) === pending) count.rows++; return read.call(this, p, ...a); };
syncBuiltinESMExports();
const S = await import('$H/lib-status.mjs');
count.list = 0; count.rows = 0;
const doc = S.computeStatus(cwd, Date.parse('$REF'), dir);
console.log(JSON.stringify({ ...count, dispatches: doc.teams[0].dispatches.length, pipeline: doc.teams[0].pipeline !== null }));
" "$HD" "$PENDING" "$PROJ" 2>&1); RC=$?
check "a status write with 3 dispatches and a run lists exchanges once and reads the dispatch rows once" '[ "$RC" = 0 ] && [ "$OUT" = "{\"list\":1,\"rows\":1,\"dispatches\":3,\"pipeline\":true}" ]'

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
