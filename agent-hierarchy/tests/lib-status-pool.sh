# agent-hierarchy — stages a throwaway hierarchy pool for the status-document tests and fixtures.
# Sourced, not run. Every write lands under one sandbox: `pool <dir>` points HD (the hierarchy dir),
# FAKEHOME and PROJ at it, and `status` runs `roster.mjs status` against that pool only.
# Needs PLUGIN set by the sourcing script.

H="$PLUGIN/hooks"

# <dir>: start a fresh pool in <dir> (created; must be empty or absent).
pool() {
  POOL="$1"
  HD="$POOL/hier"; FAKEHOME="$POOL/home"; PROJ="$POOL/proj"
  PENDING="$FAKEHOME/.claude/agent-hierarchy.peer-pending.jsonl"
  mkdir -p "$HD/msgs" "$HD/activity" "$FAKEHOME/.claude" "$PROJ/.claude"
}

# <ms offset> from REF (an ISO instant the caller sets): that instant as ISO.
at() { node -e 'process.stdout.write(new Date(Date.parse(process.argv[1]) + Number(process.argv[2])).toISOString())' "$REF" "$1"; }

# <team name or -> <members json array>: a live team (this shell owns it), created now so the 24 h
# age rule holds; `-` is the default team (team.json).
team() {
  local path="$HD/team.json"
  [ "$1" != - ] && { mkdir -p "$HD/teams"; path="$HD/teams/$1.json"; }
  node -e 'const [p, members, pid] = process.argv.slice(1); require("fs").writeFileSync(p, JSON.stringify({ team_id: "t-demo", created: new Date().toISOString(), orchestrator: { session_id: null, pid: Number(pid) }, members: JSON.parse(members) }) + "\n")' "$path" "$2" "$$"
}

# <member name> <role> <session id> <pane id>: that member's live `up` row, attributed by pane.
up() {
  node --input-type=module -e "import { appendRosterRecord } from '$H/lib-hier.mjs'; appendRosterRecord(process.argv[1], { status: 'up', session_id: process.argv[2], pid: Number(process.argv[3]), role: process.argv[4], pane_id: process.argv[5] });" "$HD" "$3" "$$" "$2" "$4"
}

# <file stem> <activity> <at iso> [blocked_by] [note]: an activity record.
activity() {
  node -e 'const [p, a, at, by, note] = process.argv.slice(1); require("fs").writeFileSync(p, JSON.stringify({ activity: a, at, blocked_by: by || null, note: note || null }) + "\n")' "$HD/activity/$1.json" "$2" "$3" "${4:-}" "${5:-}"
}

# <id> <to> <slug> <created iso> [eta] [to_name] [team] [from]: a request file.
request() {
  cat > "$HD/msgs/$1--$2--$3--request.md" <<EOF
---
id: $1
type: request
to: $2
from: ${8:-orchestrator}
slug: $3
parent: null
reason: null
eta: ${5:-small}
to_name: ${6:-null}
from_name: null
team: ${7:-null}
created: $4
---

## [0] tldr
- none
EOF
}

# <id> [<mtime iso>]: msg.mjs's skeleton response to that request, its mtime set when given; path in RESP.
stub() {
  RESP=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/msg.mjs" new --type response --id "$1" --cwd "$PROJ" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(JSON.parse(s).path))')
  [ -n "${2:-}" ] && mtime "$RESP" "$2"
  return 0
}
# <id> <mtime iso>: a response holding a report, with that mtime.
filled() { stub "$1"; printf -- '- done: reported\n' >> "$RESP"; mtime "$RESP" "$2"; }
mtime() { node -e 'const t = new Date(process.argv[2]); require("fs").utimesSync(process.argv[1], t, t)' "$1" "$2"; }

# <id> <to> <created iso> [session]: a dispatch row for that request.
dispatch() { printf '{"type":"dispatch","session_id":"%s","request_id":"%s","to":"%s","created":"%s"}\n' "${4:-orch}" "$1" "$2" "$3" >> "$PENDING"; }
# <id> <ts iso>: a liveness-nudge gate row for that request.
nudge() { printf '{"type":"liveness-nudge","session_id":"orch","request_id":"%s","ts":"%s"}\n' "$1" "$2" >> "$HD/gates.jsonl"; }
# <anchor id> <json line>: a decision-log row for that run.
decision() { mkdir -p "$HD/pipeline/$1"; printf '%s\n' "$2" >> "$HD/pipeline/$1/decisions.jsonl"; }
disable() { printf '{"enabled": false}\n' > "$FAKEHOME/.claude/agent-hierarchy.json"; }

# <now iso> [--plain]: the status document as of that instant, in OUT; RC its exit code.
status() { OUT=$(HOME="$FAKEHOME" AGENT_HIERARCHY_DIR="$HD" node "$H/roster.mjs" status --now "$1" ${2:+"$2"} --cwd "$PROJ" 2>&1); RC=$?; }
# <js expression over the document o>: its value from OUT, a string as-is, anything else as JSON.
jq_doc() { node -e 'const o = JSON.parse(process.argv[1]); const v = (new Function("o", "return (" + process.argv[2] + ")"))(o); process.stdout.write(typeof v === "string" ? v : JSON.stringify(v))' "$OUT" "$1" 2>/dev/null; }
