# 0071 — Hierarchy status view: one status file, two status lines, one mod

Implementer: implementor
Reviewer: reviewer

Status: r3, build-ready for P1. §10 records the user's decisions (Q1–Q6, the
stub bug) and the changes r1→r2→r3. Evidence: `0071-evidence.md` beside this
file. E9 picked Branch A and E10 required the toggle, so P2b has no open
gates left; it starts with two small API checks (E12, E13). P1 has one
measurement left (E1) and the suite run of E11, both inside its own steps.

Repos:

- Phases 1, 2b and 3 are in `agent-tools`, all inside the `ah` plugin
  (§6.1, Branch A).
- Phase 2a is in `claude-tui-line`, which has its own conventions (§7.7).
  It is handed to `claude-tui-line-orchestrator` after P1 lands, with §7 as
  its brief. It is not built in the P1 pipeline run.

UX target: the approved mockup https://claude.ai/artifact/Bs32ATVaYHEYccMSmgSjen.
§6 states the texts that come from it. Where this spec differs from the
mockup, it says so.

## 0. Summary

- `ah` computes a status document in one place, a new `hooks/lib-status.mjs`.
  It writes the document to `<hier>/status.json` every time `ah` changes
  hierarchy state (§3.4), and on demand through `roster.mjs status`.
- Time-driven changes (overdue, stalled, and reports dropping out of view)
  are already in the document as **scheduled transitions** (`at` timestamps).
  So consumers never need a refresh just because time passed. They pick the
  last entry whose `at ≤ now`. That one generic rule is the only logic a
  consumer runs. Eta policy, stall policy, liveness and the status text all
  live in `ah`.
- Members' activity (working, idle or blocked) is recorded when it happens.
  For Claude peers, their own hooks record it (§3.3). For `route: pane`
  members, `deliver` and `answer` record it while they already watch the
  member. **Nothing polls Herdr for this feature.**
- Consumers:
  - a builtin `ah` item and an `ah-short` item in claude-tui-line, which read
    the file on each refresh;
  - a Claude Code mod, bundled into `ah` (E9). It has a status entry, an
    AbovePrompt band, a Pane and toasts. It only reads the file: it never
    sends messages, runs processes or writes hierarchy files.
- P1 also fixes `listExchanges`, which treats a skeleton response stub as a
  report (§3.7). Every exchange consumer, including the status file, then
  uses one open/closed rule. Exchanges addressed to the Orchestrator itself
  (the pipeline's run records) keep closing on any response, so the
  pipeline and the push guard need no change (§3.7.1).

## 1. Facts this design rests on (verified by reading, 2026-10-04)

| Fact | Where |
|---|---|
| Hierarchy dir: `AGENT_HIERARCHY_DIR` → `<git root>/.claude/hierarchy` → `~/.claude/hierarchy/<basename>`. A linked worktree has its own dir. | `hooks/lib-config.mjs:691` (`hierarchyDir`), `:667` (`findGitRoot`) |
| peers.jsonl rows: `type:"peer"`, `status` is one of `up\|down\|seen\|briefed`, latest row per `name\|\|session_id` wins. `up` rows never carry `name`. | `lib-hier.mjs:778` (`appendRosterRecord`), `:787`, `:800` (`attributedRoster`) |
| Liveness: `up` is live iff the pid is alive; `seen`/`briefed` are live iff younger than 1800 s; anything else is not live. | `lib-hier.mjs:866` (`recordLiveness`), `roster.mjs:4060` (`memberIsLive`) |
| Team file: `<hier>/teams/<team>.json`, or `<hier>/team.json` for the default team. Members have `{role,name,route:peer\|pane,kind,model,transport_id,...}`; the orchestrator is `{session_id\|null,pid}`. Stale after 24 h. | `lib-roster.mjs:94`, `:1107`, `:1162` |
| Exchanges pair a request and a response by id. `open = !response`, and that checks **file existence only**: `requestFiles` reads filenames, never contents. P1 changes this (§3.7). Callers: see the full list in §3.7.2. | `lib-hier.mjs:228,407-416` |
| A message filename is `<id>--<to>--<slug>--<request\|response>.md`, so `to` is known without reading the file. `from` is only in the frontmatter. | `lib-hier.mjs:129-133` (`parseMsgFilename`) |
| A response created without `--to`/`--from` takes `to` = the request's `from` and `from` = the request's `to`. `reason` is request-only, and its values are the enum `context\|second-opinion\|parallel`. A second response for the same id throws `response <id> already exists`. `msg.mjs new` has no body flag. | `lib-hier.mjs:31,327-341`; `msg.mjs:62-79,197-230` |
| Pipeline run records (anchor `pipeline-run-anchor`, `<tag>-verdicts`, `<tag>-i<N>`, `<tag>-i<N>-x`, `<tag>-i<N>-done`) are requests the Orchestrator writes to itself (`--to orchestrator --from orchestrator`), never sent, and closed by a bodyless `msg.mjs new --type response`. The skill says "body `closed: …`", but nothing writes it, so every closed record is a pure skeleton. The live pool's only record (this run's anchor) is addressed `to: orchestrator`. Role dispatches (`-plan`, `-fit`, `-s<k>`, `-gate`, `-ok`) go to roles. No response in the live pool has `from: orchestrator`. | autonomous-pipeline `SKILL.md:531-534,762-775,905,1115-1129,1466-1468`; `tests/test-pipeline-decisions.sh:44,51` |
| Two "is this response a real report" predicates exist: `reportStatus` (roster.mjs, a byte compare against `responseSkeleton()`) and `hasAuthoredContent` (lib-hier, line-based: blank lines, `## [n] key` headings and bare `- none` / `- [n] key:` bullets are unauthored). `hasAuthoredContent`'s comment records that a byte compare was rejected as brittle. `responseSkeleton()`'s only caller is `reportStatus`. | `roster.mjs:5124-5139`; `lib-hier.mjs:187-190,643-652,664-678` |
| The Stop hook nudges only open exchanges that have a peer-pending `dispatch` row for **this** session. Rows are written by `posttooluse-peer-resolve.mjs:62` (`appendDispatchRecord`, `lib-peer.mjs:250`) on SendMessage. `roster.mjs deliver` writes **none**, so pane-member work is never nudged. The reason text tells the Orchestrator to use ListAgents/SendMessage, and both fail for a pane member. | `stop-orchestrator-liveness.mjs:62-77,96-106,116-120` |
| `createMessage` writes the response as frontmatter plus a **skeleton body**. `deliver` pre-creates that stub as soon as it dispatches. | `lib-hier.mjs:346`, `roster.mjs:6589` |
| Whether a report is present: missing → `no-report`; bad frontmatter or id mismatch → `malformed-report`; body equal to the skeleton → `no-report`; otherwise `reported`. | `roster.mjs:5124` (`reportStatus`) |
| Eta thresholds are defined once: `{small:300, medium:600, large:1200}` s, and an absent or unknown eta counts as small. The Stop hook nudges once the threshold is reached, then again every full threshold. | `stop-orchestrator-liveness.mjs:48`, `:60-106` |
| Each nudge appends `{type:"liveness-nudge",session_id,request_id,ts}` to `gates.jsonl`. | `stop-orchestrator-liveness.mjs:~116` |
| Pipeline run: live iff an open `pipeline-run-anchor` request exists. `liveRun` needs exactly one open anchor (any team), else `null`, and the push guard's `pinnedMerge` then refuses; `runLiveness` says `live` for one or more. `openRunAnchor` needs exactly one per team. `merge-check` needs `<tag>-i<N>` open, `<tag>-i<N>-ok` closed and `<tag>-i<N>-x` not open. The decision log is `<hier>/pipeline/<anchor id>/decisions.jsonl`. Rounds per item = the number of exchanges, open or closed, whose slug equals the item's slug; no hook computes it, only the skill's prose. `dec-` exchanges never count. The cap is 3. | `lib-hier.mjs:506-515`, `lib-decisions.mjs:31-46,196-203,286-296`, `pretooluse-push-guard.mjs:617-641,754-800`, autonomous-pipeline `SKILL.md:471-509` |
| Pane-member status from Herdr: `idle\|working\|blocked\|done\|unknown`. `deliver` reports `blocked` with `blocked_by`. `answer` relays the user's answer to the prompt. | `roster.mjs:2985`, `:3769-3835`, `:6514-6556`, agent-team `SKILL.md:226-314` |
| stream-label maps UserPromptSubmit→working, Stop→idle and Notification(permission_prompt)→blocked, but only for open streams with a pane. | `hooks/stream-label.mjs:24-33` (`SELF_STATE`) |
| Notification(`permission_prompt`) fires in an `--agent` role session, ~6–8 s after the dialog shows. Its `message` is always `"Claude needs your permission"`; there is no tool name and no `title`. UserPromptSubmit fires on a cross-session SendMessage: within 1 s for an idle peer, at the next tool boundary for a busy one. | evidence E3, E4 |
| A plugin command hook with `"async": true` is honoured (it no longer delays the next tool). A sync no-op node hook costs 32–36 ms per tool call. An async hook still running when a `claude -p` session exits is killed. | evidence E2 |
| The enabled flag comes from `resolveConfig().enabled`. It is written outside hook code, by the `/hierarchy` skill. | `lib-config.mjs:1426,1491` |
| Mod API (Claude Code 2.1.289): `$.fs` has `read/stat/exists/list`. `$.clock.every`. `$.session.cwd()/id()`. `$.ui.status/toast/open`. `$.state` lives for the session and survives reloads; `$.store` survives across sessions. An unasked Pane seats at ≥144 columns, an asked one at any width. AbovePrompt has no width threshold and gives `bodyColumns`. After a hot reload the engine drops the old environment's timers. | plugin-authoring `reference.md:11-71,77,88-90`; `types/claude-code.d.ts:9713-9814`; evidence E8 |
| One plugin can carry its classic command hooks and a `{modules}` hooks file together: with plugin.json `"hooks": "./mod/hooks.json"`, the standard `hooks/hooks.json` still loads on its own and both fire. (The reference says one hooks.json holds only one kind; a single file with both keys also worked, but this spec does not rely on it.) Tested with `--plugin-dir` only, not an installed marketplace copy. | evidence E9 |
| `$.ui.status(text)` renders as `⚠ <plugin name>: <text>` on its own line **above** a configured statusLine; the statusLine does not hide it. `ah`'s plugin name is `ah`, so the mod's entry reads `⚠ ah: <text>`. | evidence E10; `agent-hierarchy/.claude-plugin/plugin.json` |
| `claude plugin test`: nothing sits beneath the plugin. A test must answer `session.start` (return `{cwd}`), `ui.status` (`{value: undefined}`), each `fs.*` call (`{value}`), and the clock through `mock.clock(on,{now})`, which drives `$.clock.every` exactly. There is no `mock.fs`, and real files are never read through `$.fs`. `mock` has only `clock`, `store`, `env`. | evidence E5 |
| `ah`'s plugin.json today has no `hooks`, `types` or `userConfig` key. Version 0.109.0. | `agent-hierarchy/.claude-plugin/plugin.json` |
| claude-tui-line: an AOT exec runs on about every 1 s refresh. It has no daemon. The builtin item model is a registry row plus resolve/build functions. Item settings go in `itemSettings`. File-reading items like `autocompact` and `engram` already exist. | claude-tui-line `ItemRegistry.cs`, `SegmentBuilder.cs:340-390`, `Config.cs:48-78`, `ItemContext.cs:11` |

## 2. What changes, by repo

| Repo / plugin | Kind | Files |
|---|---|---|
| `agent-tools/agent-hierarchy` (`ah`), P1 | changed + new | new `hooks/lib-status.mjs`, new `hooks/activity.mjs`, `hooks/hooks.json`, `hooks/roster.mjs` (new verb `status`; `deliver`/`answer`/spawn record activity; `reportStatus` moves to lib-hier), `hooks/lib-hier.mjs` (`reportStatus` lands here on `hasAuthoredContent`; `listExchanges` open rule; `sweep`, §3.7), `hooks/lib-roster.mjs`, `hooks/lib-decisions.mjs` (trigger only), `hooks/sessionstart.mjs`, `hooks/sessionend-roster.mjs`, `hooks/stop-orchestrator-liveness.mjs` (constants move to a lib; second check-in at T/2; reason text for pane members, §3.7), `hooks/pretooluse-ah-cli.mjs` (writes a dispatch row for `deliver`, §3.7), `hooks/stream-label.mjs` (imports the shared table), `skills/hierarchy/SKILL.md` (the on/off path refreshes status), `skills/autonomous-pipeline/SKILL.md` (record wording only, §3.7.6), new `docs/status-file.md`, `docs/cli-tools.md`, new `tests/test-status*.sh`, new `tests/test-exchange-open*.sh`, new `tests/fixtures/status/`, existing tests whose assertions encode "a bodyless response closes a member exchange" (§3.7.7), `.claude-plugin/plugin.json` (0.110.0), root `.claude-plugin/marketplace.json`. **Not changed:** `hooks/msg.mjs`, `hooks/pretooluse-push-guard.mjs`. |
| `agent-tools/agent-hierarchy` (`ah`), P2b/P3 | new code | `agent-hierarchy/mod/`, plus `hooks`, `types` and `userConfig` keys in ah's plugin.json (§6.1). |
| `claude-tui-line` | new items | §7 |

## 3. The status source (Phase 1)

### 3.1 Producer

- New module `agent-hierarchy/hooks/lib-status.mjs`. It holds the **only**
  code that turns hierarchy state into the status document, and the only
  code that writes `status.json`.
- It must **reuse**, not copy, each of the following. Where one lives inside
  an entry-point script today, move it into a lib module that both the old
  caller and lib-status import.
  - `hierarchyDir`, `listExchanges`, `attributedRoster`/`recordLiveness`
    (claude-member liveness), the team-file readers and the existing team
    liveness rule (the rule `roster.mjs teams` uses), `pipelineRunLive`,
    `openRunAnchor`, `decisionSummary`, and `resolveConfig().enabled`.
  - `reportStatus` (roster.mjs:5124). Move it into `lib-hier.mjs`, which
    `listExchanges` lives in, so there is no import cycle. Its skeleton test
    becomes `hasAuthoredContent` (lib-hier.mjs:643), so the codebase keeps
    **one** "is this a real report" predicate. Exact behaviour:
    - file missing or unreadable → `no-report`;
    - no frontmatter, or frontmatter `id` ≠ the exchange id →
      `malformed-report`;
    - the body after the frontmatter has no authored content per
      `hasAuthoredContent` → `no-report`;
    - otherwise → `reported`.

    The one behaviour change for `deliver`: a body with no authored content
    that is not byte-identical to the skeleton (lines reordered or deleted,
    indentation changed) was `reported` and is now `no-report`. That is
    intended, since such a body says nothing. `responseSkeleton()` is
    deleted if `reportStatus` was its last caller. (r3: r2 missed
    `hasAuthoredContent`; keeping both predicates would be two definitions
    of one behaviour.)
  - The eta threshold table (stop-orchestrator-liveness.mjs:48), plus the
    check-in cadence (user decision Q4, which follows spec 0028 §5.7.2).
    Move both to one lib, as **one table of constants**:
    - the first check-in falls due `T` after `created`;
    - the second falls due `T/2` after the first;
    - every later one falls due `T` after the previous one.

    The Stop hook applies that table relative to the nudges it actually
    sent; §3.7.4 covers its one behaviour change. The status view applies
    the same table to the ideal schedule, so `overdue_at = created + T` and
    `stalled_at = created + 1.5T` (§4.2). Neither copies a number.
  - stream-label's event→state table (`SELF_STATE`). Move it to a lib, and
    stream-label imports it.
- It must not call `herdr`, spawn any process, or take a lock.
- A write is atomic: write a temp file in `<hier>`, then rename it over
  `status.json`.
- If the `<hier>` dir does not exist, it writes nothing. It never creates the
  dir.
- A failing status write (any exception) is swallowed. It must never change
  the triggering hook's or verb's exit code, stdout or decision.
- Ceiling: when two writers race, the last rename wins and the file may be
  one event behind. The next write fixes it. Put a `ponytail:` comment at the
  write site naming this.
- A writer killed mid-write (E2: an async hook still running when a
  `claude -p` session exits) loses that write and may leave its temp file.
  This does not affect correctness: the lost write is superseded by the
  session's own sync Stop and SessionEnd writes, or by the next write in the
  pool. Temp files are named per process (e.g. `status.json.<pid>.tmp`) so a
  leftover never collides; nothing cleans them up (gitignored, rare).

### 3.2 Document schema (`schema: 1`)

**Location:** `<hier>/status.json`. The `.gitignore` of `*` already covers
it.

**Versioning:** fields may be added without bumping `schema`. Removing or
redefining a field means `schema: 2`. Consumers render nothing for any
`schema` other than 1.

**Strings:** before writing, strip C0/C1 control characters (including ESC)
from every string that came from a file. Cap the lengths: names and labels
at 64, slugs at 32, notes at 80. Cut at the cap; never add an ellipsis
character.

```jsonc
{
  "schema": 1,
  "written_at": "2026-10-05T02:20:00.000Z",   // ISO-8601 UTC, ms precision
  "expires_at": "2026-10-06T02:20:00.000Z",   // written_at + 24 h; consumers treat the doc as absent after it
  "enabled": true,                            // resolveConfig().enabled
  "member_sessions": ["<session id>", "..."], // session ids of live claude members across all live teams
  "teams": [{
    "team": "agent-tools",
    "members": [{
      "name": "agent-tools-architect", "role": "architect", "label": "architect",
      "kind": "claude", "route": "peer",       // from the team file; kind defaults to "claude"
      "session_id": "…" | null,                // claude member attributed through attributedRoster
      "live": true | false | null,             // §4.1
      "activity": "working" | "idle" | "blocked" | "unknown",
      "activity_at": "ISO" | null,
      "blocked_by": "approval" | "trust-dialog" | "login" | "harness-prompt" | "permission" | null,
      "blocked_note": "Allow edits to config.toml? (y/n)" | null  // pane members only (§3.3); always null for claude members
    }],
    "dispatches": [{
      "id": "20261004-221359-mp96", "slug": "hierarchy-status-mod",
      "to": "architect", "to_name": "agent-tools-architect" | null,
      "member": "agent-tools-architect" | null, "label": "architect",
      "eta": "large", "eta_ms": 1200000,
      "created": "ISO", "checkins": 0,          // count of liveness-nudge gate rows for this request id
      "reported_at": "ISO" | null,              // response file mtime once reportStatus says a report is there
      "states": [ {"at": "ISO", "state": "working"},
                  {"at": "ISO", "state": "overdue"},
                  {"at": "ISO", "state": "stalled", "reason": "no-report"} ]
    }],
    "dispatches_truncated": 0,
    "pipeline": null | {
      "anchor_id": "…", "started": "ISO", "round_cap": 3, "waiting_on_user": 0,
      "items": [{"slug": "…", "rounds": 2, "open": true, "to": "reviewer"}]
    }
  }],
  "timeline": [                                  // sorted by at; first at == written_at
    {"at": "ISO", "visible": true, "tone": "work",
     "live": 3, "out": 1, "blocked": 0, "overdue": 0, "stalled": 0,
     "text": "3 live · 1 out", "short": "3/1"}
  ]
}
```

### 3.3 Activity records (new)

**Location:** one file per subject under `<hier>/activity/`:

- `<session_id>.json` for a Claude member session;
- `pane-<member name>.json` for a `route: pane` member.

**Content:** `{activity, at, blocked_by, note}`. Each file is written
atomically, and only by its own subject's events (single writer).

**Claude members.** A new hook script, `hooks/activity.mjs`, records their
activity. It is registered in `hooks/hooks.json` on these events:

| Event (matcher) | Records | Notes |
|---|---|---|
| UserPromptSubmit (`*`) | `working` | |
| Stop (`*`) | `idle` | |
| Notification (`permission_prompt`) | `blocked`, `blocked_by:"permission"`, `note: null` | r3: the input's `message` is the constant `"Claude needs your permission"` (E3), so it is not recorded. The event lands ~6–8 s after the dialog shows. |
| PostToolUse (`*`) | `working`, but **only if** the current record is not `working` | Clears `blocked` after an approved tool, and corrects `idle` when another Stop hook kept the turn going. Registered with `"async": true` (E2 showed it is honoured). |
| SessionEnd (`*`) | deletes its own file | The existing `sessionend-roster.mjs` may do this instead. One place only. |

- The events-to-state mapping for the first three rows is the shared table
  from §3.1. Do not add a second copy.
- Only PostToolUse is async. UserPromptSubmit, Stop, Notification and
  SessionEnd stay sync: Stop's write is what surfaces a report, and it must
  not be lost at session exit (E2).
- Ceiling (`ponytail:` comment in activity.mjs): the async PostToolUse and
  the sync Stop are two writers for one subject. Last rename wins. In
  practice PostToolUse finishes ~35 ms after the tool, long before the model
  ends its turn, so Stop lands last.
- Records only for role sessions (the same test sessionstart uses before it
  writes a peers `up` row), and never for subagents.
- On UserPromptSubmit and Stop, write status.json in **any** session whose
  `<hier>` dir exists. This is what makes a report show up: a Claude peer
  fills its response with the Write tool, which no `ah` hook sees, and its
  Stop follows.
- On PostToolUse, write status.json only when the activity record changed.

**Pane members.** These code paths write the `pane-<name>.json` record, and
then status.json:

- `roster.mjs deliver`: each time it learns a state from Herdr, and only when
  that state differs from the record. It maps `working`→working,
  `idle|done`→idle, `blocked`→blocked (with `blocked_by`, and `note` = the
  first prompt line it already reads), and `agent_not_found`→`unknown`. At
  exit it writes its final observation.
- `roster.mjs answer`: after a successful relay it records `working`.
- `spawn-one` and `spawn-ad-hoc` of a pane member record `idle`.
- `dismiss` and `disband` remove that member's file.
- `msg.mjs sweep` also deletes activity files older than its 7-day cutoff.

### 3.4 Write triggers

status.json is recomputed and written after each of the following:

1. Every append to peers.jsonl. Put the trigger at the shared append path
   (`appendRosterRecord`), so the SessionStart `up` row, `checkin`, the
   SessionEnd `down` row, and the `seen` and `briefed` rows are all covered.
2. Every message file created through `createMessage`: requests, response
   stubs and pipeline anchors.
3. Every team-file write in `lib-roster.mjs`: create, commit, spawn, dismiss,
   disband, untrack, resync and stream ops.
4. Every decisions.jsonl append: decided and parked rows, and merge rows.
5. Every activity-record change (§3.3).
6. `sessionstart.mjs`, for **every** session start, including non-role
   sessions and a disabled hierarchy, as long as `<hier>` exists. A reboot or
   crash then self-heals at the next session in the repo.
7. `roster.mjs status` (§3.5).
8. The `/hierarchy` skill's on and off steps call `roster.mjs status --cwd …`
   once they have changed the config. This is a prose step in
   `skills/hierarchy/SKILL.md`.
9. Every `liveness-nudge` append to gates.jsonl (at `appendGate`), so
   `checkins` stays current.

Layering is the Implementor's call: put each trigger at the lowest shared
write helper without an import cycle. No call site may be missed in a way
that a new caller of that helper would also miss.

### 3.5 Verb `roster.mjs status`

```
roster.mjs status [--plain] [--now <ISO>] --cwd <abs>
```

- It computes the document, writes `status.json` under §3.1's rules, and
  prints the document as JSON.
- With `--plain`, it prints `ah · <text>` for the timeline entry current at
  `now`, or an empty line when that entry is not visible.
- `--now` makes the computation run as of that instant. It exists for
  tests, as `next-split` does.
- It exits 0 even when `<hier>` is missing: it then prints the document,
  with `teams: []`, and writes nothing.
- Add a row to `docs/cli-tools.md`.

### 3.6 Cost per read

- A consumer's read is one `stat` plus a read of a file that is usually
  under 8 KB, plus a JSON parse. It never spawns anything.
- The producer's cost per write is E1. Target: p95 ≤ 15 ms on the live
  `agent-tools` pool.

### 3.7 Exchange open/closed fix, and Stop-hook liveness for pane work (P1)

This section was added in r2 (user decision: fix the stub bug in P1). The
user wants the Stop hook's liveness check to fire for `deliver`'d pane work.
The stub fix alone does not achieve that: §1 shows the hook also needs a
`dispatch` row, and pane-member wording. So §3.7.3–3.7.4 come with it (user
decision Q6 (a), approved).

r3 resolves the conflict E11 found between r2's rule and the pipeline's run
records (§3.7.1 second bullet, §3.7.6).

**3.7.1 One open rule.**

- An exchange is **open** iff:
  - it has no response file, or
  - its request is **member-addressed** (the filename's `to` field is not
    `orchestrator`) **and** `reportStatus` on its response file returns
    `no-report`.
- So an exchange addressed `to: orchestrator` closes on any response, exactly
  as today. That class is the pipeline's run records (anchor, verdicts,
  item, `-x`, `-done`), which the Orchestrator writes to itself and closes
  with a bodyless response (§1), plus any request a role sends to the
  Orchestrator. Nobody owes the Orchestrator a report on its own record, so
  a skeleton response there is a close marker, not a missing report.
- `reported` and `malformed-report` mean closed. That matches §4.2.
- `listExchanges` applies this rule, and so every caller inherits it.
  `reportStatus` lives in lib-hier (§3.1), and roster.mjs `deliver` calls
  the same function.
- `listExchanges` reads the text of each member-addressed exchange's
  **response** file, once per call. It never reads request files for this
  rule, and never reads the response of an orchestrator-addressed exchange.
- If E1 shows `listExchanges` p95 over 5 ms on the live pool, add a cheap
  pre-check: a response over 4 KB cannot be unauthored, so treat it as
  closed without reading it. Do not add it otherwise.

Why not a `--body` flag on `msg.mjs new` (the other fix E11 suggested): it
would also work going forward, but every record already closed by a stub,
in every pool that has run `/pipeline`, would flip open on upgrade. Stale
anchors would then halt the next run and make `liveRun` return `null` (two
or more) or a finished run (one). It would also need a migration, a SKILL
change before the rule could land, and a commit-ordering constraint for this
live run. The address test needs none of that, and the filename already
carries `to`.

**3.7.2 Effect on each caller.** Rows marked "changes" are intended and each
needs a test. Rows marked "unchanged" need one test proving it (§8 P1 AC 23).

| Caller | Before | After |
|---|---|---|
| `msg.mjs list` (`--open`/`--closed`/`--all`) | stub-only member exchange listed closed | listed open (changes) |
| `openExchanges` (lib-hier:495), and through it the Stop-hook `outstandingDispatches` (stop-orchestrator-liveness:67), the sessionstart open-exchange index (`teamStateLines`, lib-hier:1078), the per-role busy count in `roster()` (lib-hier:942), and `teamOpenExchanges` (roster.mjs:4604) | stub-only member exchange skipped | included (changes). A role with an old unfilled stub now counts as busy until the stub is filled or parked (§3.7.5). |
| `sweep` (lib-hier:534) | archives any pair with a response file older than 7 days | uses `.open`, so a stub-only member pair is **not** archived; a stub-closed record still is (changes) |
| Anchor liveness: `pipelineRunLive` (lib-hier:512), `openRunAnchor` (lib-decisions:31), `liveRun` (:196), `runLiveness` (:286), and all their callers (push guard `pinnedMerge`/`mergeGuard`, `pretooluse-mcp-guard`, `posttooluse-merge-record`, `pretooluse-roster-skill-gate`, roster.mjs trust/spawn refusals, `msg.mjs decision add/list`) | anchor open iff no response | unchanged: the anchor is orchestrator-addressed |
| `merge-check` (pretooluse-push-guard:777-784): `<tag>-i<N>` must be open; `<tag>-i<N>-x` open → `exception` | records | unchanged: both are orchestrator-addressed |
| `merge-check`: `<tag>-i<N>-ok` must be closed, else `not-signed-off` | any response signs off | a skeleton-only `-ok` response (addressed to the Architect) no longer signs off (changes). The pipeline's intended path has the Architect fill it, so a real sign-off is unaffected. |
| `knownRun` (`lib-decisions.mjs:44`) | id and slug only | unchanged |
| `deliver`'s own `evaluate` (roster.mjs:6560) | byte compare | `hasAuthoredContent` (§3.1) |
| status file (§4.2) | — | the same rule. §4.2's "report present" **is** this rule. |

**3.7.3 A dispatch row for `deliver`.**

- `pretooluse-ah-cli.mjs` already inspects every ah CLI Bash command. When
  the command runs `roster.mjs deliver` with `--req <path>` and **without**
  `--wait-only`, it appends the same `dispatch` row that SendMessage
  dispatches get: `appendDispatchRecord(session_id, <request id>, <to>)`.
  The request id and `to` come from the request file.
- No new hook process.
- The row is written before the command runs. If `deliver` then refuses
  (`not-live`, `not-sent`), the exchange is still open and the Orchestrator
  is nudged about it after `T`. That is acceptable: an open exchange is owed
  either way.

**3.7.4 Stop-hook changes.** Exactly two.

1. **Cadence.** The second nudge for a request is due `T/2` after the first,
   instead of `T` after it. All later nudges stay `T` after the previous
   one. The trailing sentence "You will be asked again … after another eta
   interval" becomes: after half an eta interval the first time, then every
   eta interval.
2. **Pane wording.** If the item's member is `route: pane` (looked up in the
   team file by `to_name`, then by role), its line must not say
   ListAgents/SendMessage. Instead it tells the Orchestrator to check the
   member with
   `roster.mjs deliver <name> --req <path> --wait-only --timeout 10 --cwd <abs>`,
   and to act on the returned `status` as agent-team `SKILL.md`
   §"Dispatching to a `route: pane` member" prescribes:
   - `blocked` → relay through AskUserQuestion and `answer`;
   - `not-live` → surface it to the user;
   - `busy` or `timeout` → it is still working.

   Before writing this line, the Implementor confirms by reading `deliver`
   that `--wait-only` sends nothing to the member. If it does send
   something, stop and report a spec gap.

Everything else in the Stop hook stays as it is: its guards, how it records
nudges, and its block decision.

**3.7.5 Existing data.** After the upgrade, older unfilled stubs of
**member-addressed** exchanges in `msgs/` show as open everywhere, including
the status view (as stalled dispatches, if their team is live). That is
correct, because no report was ever written. Stub-closed run records stay
closed (§3.7.1), so no stale anchor appears. A note in the 0.110.0 release
text tells the user to list open exchanges (`msg.mjs list`) and to park any
abandoned ones by writing a line of content into their response, as the
Stop-hook text already says. No automatic migration.

**3.7.6 autonomous-pipeline `SKILL.md` (wording only, no new mechanism).**
The skill's record text must match what the CLI does, and must make the
record address a stated contract, since §3.7.1 now depends on it.

- Where the skill introduces run records (around :905 and the records table
  at :1115-1125), state that every record request is created with
  `--to orchestrator --from orchestrator`, and give the literal
  `msg.mjs new --type request …` command once. Say why in one clause: an
  orchestrator-addressed exchange closes on any response, while a
  member-addressed one closes only on an authored report.
- :531-534 (plan-run anchor close), :1466-1468 (end-of-run close) and
  :771-775 (stale-anchor fix): remove "(body `closed: run complete`)" and
  "with `closed: stale anchor` as the response body". Nothing can write that
  body, and it is not needed. The close command is the bodyless
  `msg.mjs new --type response --id <id> --req <request path> --cwd <root>`
  (to/from default from the request), as today.
- `-ok` sign-off stays a dispatch to the Architect. Add one sentence: the
  Architect's response must carry content, because a skeleton `-ok` does
  not count as a sign-off (`merge-check` reports `not-signed-off`).
- No other skill text changes. The rounds rule (:479-505) is unaffected:
  it counts with `--all`.

**3.7.7 Existing tests.** Several tests create bodyless responses with
`msg.mjs new --type response` to member-addressed requests and then assert
"closed" (for example `test-msg-cli.sh:74-110`, the `-ok` helper in
`test-pipeline-merge.sh:60`). Where a failure is exactly the intended change
in §3.7.2, update the test by writing a content line into that response.
Never weaken or delete an assertion. List every such update in the P1
report. Any other failure is a defect: stop and report it (that is the E11
suite run). Tests whose bodyless responses answer orchestrator-addressed
records (`test-pipeline-decisions.sh:51`) must pass **unchanged**.

**3.7.8 Landing while a `/pipeline` run is live.** The `ah` CLI root of the
run that builds P1 is the same working tree P1 edits, so every edit is live
for that run's own hooks the moment it hits disk.

- **Implement in a separate git worktree**, never in the live tree. A
  half-edited tree (for example roster.mjs importing a `reportStatus` that
  lib-hier does not export yet) would crash every `ah` hook in every running
  session, and a crashed push-guard hook does not enforce anything.
- Land work on the run branch in the live tree **one whole, green commit at
  a time**, in the order of §8 P1 steps.
- The open-rule commit (P1 step 2) carries the orchestrator-addressed
  exemption in the same commit. It must never land without it.
- Effect on the live run once step 2 lands, all intended: its anchor has no
  response and stays open, and the Orchestrator's end-of-run bodyless close
  still closes it; unfilled member stubs in the live pool become open and
  may draw Stop-hook nudges for exchanges this Orchestrator session
  dispatched.
- Whether the `hooks/hooks.json` registrations added in step 6 reach
  sessions that are already running does not matter: nothing in the run
  depends on them.

## 4. State model (exact rules)

`T` is the dispatch's eta threshold from the shared table.

### 4.1 Members

The document's `teams` list holds exactly the **live** teams in the pool,
and the member set is every member of those teams. Team liveness uses the
existing rule. The orchestrator is excluded.

`live`:

- Claude (`route: peer`): the existing `recordLiveness` result for the
  member's attributed peers row. With no attributed row, `false`.
- Pane (`route: pane`): `false` if its activity record says `unknown` because
  `deliver` saw `agent_not_found`. `true` if it has any other activity
  record. `null` if it has none.

`activity`: from the member's activity record; `unknown` if there is none.
A member with `live === false` shows `activity` as recorded, but consumers
draw it as **gone**.

`label`: the member's `role` if no other live member of that team shares
it; otherwise its `name`.

### 4.2 Dispatches

**Set.**

- Every **member-addressed** request in the pool (filename `to` ≠
  `orchestrator`, §3.7.1) that is open, plus every member-addressed request
  reported within the last **10 min** (reported_at + 600 s > written_at).
  r3: this replaces r2's `slug ≠ pipeline-run-anchor` clause. r2 would have
  shown every open run record (item, `-x`) as a dispatch that goes overdue
  and stalled; records are not member work.
- Request-to-team mapping: the frontmatter `team` tag; untagged requests go
  to the default team. Reading request frontmatter here is fine; only the
  open rule avoids it.
- Only teams in the document's `teams` list (live teams, §4.1) get
  dispatches. A request mapped to a team that is not live is left out; its
  Orchestrator is gone and no consumer would show it. `msg.mjs list` still
  lists it.
- Order: severity first (stalled, blocked, overdue, working, reported), then
  oldest `created`.
- Cap the list at 50 per team, and put the remainder in
  `dispatches_truncated`.

**Report present.** This is `!open` under the §3.7.1 rule. It is the same
rule every exchange consumer uses as of r2. `reported_at` is the response
file's mtime.

**Member.** Look up `to_name` among the team's members. Failing that, use
the single member whose `role == to`. Failing that, `null`.

**`states`** (the first rule that matches decides the whole list):

| # | Condition at write time | `states` |
|---|---|---|
| 1 | reported | `[{written_at, reported}, {reported_at+600s, expired}]` |
| 2 | member exists and `live === false` | `[{written_at, stalled, reason:"member-gone"}]` |
| 3 | member's `activity == blocked` | `[{written_at, blocked}]` |
| 4 | otherwise | `[{created, working}, {created+T, overdue}, {created+1.5T, stalled, reason:"no-report"}]` |

- Rule 4's cut points are the first and second check-ins of the shared
  cadence table (§3.1), applied to `created`. That is spec 0028 §5.7.2
  (user decision Q4).
- They do not move when a real nudge comes late. Otherwise a late first
  nudge would flip a dispatch from `stalled` back to `overdue`.
- What the consumers display uses `checkins`, so it never claims a check-in
  that was not sent (§6.4).
- **Blocked** wins over time. Once the member is unblocked, the next write
  recomputes the dispatch under rule 4.
- `checkins` is the number of `liveness-nudge` rows in `gates.jsonl` whose
  `request_id` equals this id.

### 4.2.1 Pipeline (r3: made exact)

Per team:

- `pipeline` is `null` unless `openRunAnchor(dir, team)` returns an id
  (exactly one open anchor for that team). Reuse that function; do not
  re-derive anchors.
- `anchor_id` is that id; `started` is the anchor request's `created`.
- `round_cap` is 3, the skill's cap. It has no code constant today; define
  it once, in lib-status.
- `waiting_on_user` is `decisionSummary`'s parked count for that run.
- `items`: one per distinct slug among the team's **member-addressed**
  exchanges whose request `created` ≥ `started`, excluding slugs that start
  with `dec-`. For each slug:
  - `rounds` = the number of exchanges in the pool, open or closed, whose
    slug equals it. That is the skill's own rounds rule (§1), applied
    mechanically, with no time bound, just as the skill counts.
  - `open` = any of those exchanges is open (§3.7.1).
  - `to` = the `to` of the newest of them.
- Order items by their newest exchange's `created`, newest first. Cap at 20,
  and drop the rest silently (the Pane shows open items only).
- For an issue run, whose dispatches carry suffixed slugs (`-plan`, `-s<k>`,
  `-gate`, `-ok`), each suffix shows as its own item. That is what the
  skill's rule counts per slug, so the view stays faithful to it.

### 4.3 Timeline (counts, text, tone, visibility)

The producer evaluates the counts at `written_at` and at every distinct
future `at` across all dispatch `states` in the pool. It emits one entry
for each instant at which the counts change, sorted, with the first entry
at `written_at`.

**Counts at instant `t`.** A dispatch's state at `t` is the last of its
`states` with `at ≤ t`. Then:

- `live` = members whose `live !== false`;
- `blocked` = live members whose activity is `blocked`;
- `out` = dispatches whose state is not `reported`/`expired`;
- `overdue` = dispatches whose state is `overdue`;
- `stalled` = dispatches whose state is `stalled`.

**`text`.** Start with `{live} live · {out} out`. Then, for each of
`blocked`, `overdue` and `stalled` in that order, append
` · {n} blocked|overdue|stalled` when n > 0.

> Mockup: `3 live · 1 out · 1 blocked`.

**`short`.** Start with `{live}/{out}`. Then append ` {n}b`, ` {n}o` and
` {n}s` for the non-zero ones.

> Example: `3/1 1b`.

**`tone`.**

- `bad` if overdue + stalled > 0;
- else `warn` if blocked > 0;
- else `work` if out > 0;
- else `idle`.

**`visible`.** True when all of these hold: `enabled`; and live > 0 or
out > 0 or some team has `pipeline ≠ null`.

### 4.4 The one consumer rule

Consumers take these steps:

1. Treat the doc as absent if the file is missing, unreadable, over 256 KB,
   not JSON, `schema ≠ 1`, or `now ≥ expires_at`.
2. Pick the entry that is current at `now`: the last element with
   `at ≤ now`. If `now` is before the first element, use the first.
3. Render nothing if the entry has `visible: false`, or if the viewing
   session's id is in `member_sessions`. The second condition gives the
   Orchestrator-only view (user decision Q3).

Consumers never re-derive eta, stall, liveness, counts or the status text.

### 4.5 Freshness

- **Time-driven states:** exact at every read, because they are already
  scheduled in the document.
- **Claude members' blocked state:**
  - set ~6–8 s after the permission dialog appears, when Notification
    fires (E3);
  - cleared by the first PostToolUse after it (async, ~35 ms), or by Stop;
  - ceiling: if a Notification were delivered after the person already
    answered, `blocked` would show until the next tool call or Stop. It
    self-heals; no guard is added.
- **Claude members' working state:** set by UserPromptSubmit, which fires
  within 1 s of a peer brief for an idle peer (E4). A busy peer is already
  `working`.
- **Pane members' blocked state:**
  - set when `deliver` sees it, at `deliver`'s own polling cadence;
  - cleared by `answer`, or by the next `deliver` observation.
- **Outside a `deliver` run:** a pane member's activity is whatever was last
  seen. The Pane shows that state's age, from `activity_at`.
- **Crashes:**
  - A Claude peer that dies without SessionEnd still counts as live until the
    next write anywhere in the pool. Writes happen on every turn of every
    session in the repo.
  - If every session is gone, `expires_at` hides the stale doc after 24 h,
    and the next session start rewrites it.

## 5. What must NOT change

- `msg.mjs list` output format and flags. Only which exchanges count as
  open changes (§3.7).
- `msg.mjs` code, including `new`'s flags: no `--body` flag is added.
- `pretooluse-push-guard.mjs` code. Its behaviour changes only through
  `listExchanges`, and only for `-ok` (§3.7.2).
- The open/closed state of every orchestrator-addressed exchange, which
  includes every pipeline run record and so every anchor-liveness answer.
- The Stop-hook liveness nudge, except for the two changes in §3.7.4: its
  guards, its gate rows and its block decision stay as they are.
- stream-label behaviour and output.
- The peers.jsonl format: no new `status` values.
- No hook gains a `herdr` call.
- `roster.mjs stream-status`.
- claude-tui-line's default item set. Both new items are opt-in.
- Nothing is written to `~/.claude/dev-mods/` without the user's explicit
  go-ahead. Development and tests run from the repo folder (§6.6).

## 6. The mod (Phase 2b and Phase 3)

### 6.1 Where it ships (user decision Q1; E9 decided: Branch A)

The mod is **bundled in `ah`** (E9). r2's Branch B, a separate `ah-status`
plugin, is dropped.

```
agent-hierarchy/
  .claude-plugin/plugin.json   + "hooks": "./mod/hooks.json"
                               + "types": "./mod/types/index.d.ts"
                               + "userConfig": { "status_entry": boolean, default true }  (§6.4)
  hooks/hooks.json             unchanged (command hooks; still loads on its own, E9)
  mod/hooks.json               { "modules": ["./register.tsx"] }
  mod/register.tsx             event wiring only (§6.3)
  mod/view.ts                  pure: (doc, nowMs, sessionId, columns) → view model (§6.4–6.5);
                               no $ calls, so it is testable directly
  mod/types/index.d.ts         PluginState contract for every $.state value the module uses
  mod/tests/*.test.ts          §6.6
```

- Use the string form `"hooks": "./mod/hooks.json"`. E9 showed it and the
  array form both work, and the debug log says the standard
  `hooks/hooks.json` loads on its own, so the array form adds nothing. Do
  **not** merge `modules` into `hooks/hooks.json`: that worked in E9 but
  contradicts the reference, so a later client could reject it.
- `claude plugin validate agent-hierarchy` and the existing bash suite must
  both pass. The bash suite proves the command hooks still load and run.
- The minimum Claude Code version for the mod API (2.1.289) now applies to
  the mod half of `ah`. A client that rejects the mod file outright is the
  risk the user accepted with Q1. Note it in the `ah` README through
  docs-writer.
- E9 used `--plugin-dir` only. An installed marketplace copy is checked by
  the user after P2b ships (§8 P2b AC 8).

The rest of §6 calls the mod's folder `<mod>` = `agent-hierarchy/mod`.

### 6.2 Locating the file

1. Start at `$.session.cwd()` and walk up to the first directory that
   contains a `.git` entry (file or dir).
2. The file is `<that dir>/.claude/hierarchy/status.json`.
3. Resolve the path again when `cwd` changes.
4. With no `.git` anywhere up the tree, there is no file.

Ceiling (`ponytail:` comment): this ignores `AGENT_HIERARCHY_DIR` and `ah`'s
non-git fallback dir. claude-tui-line uses the same rule (§7.2).

### 6.3 Events

| Event | Behaviour |
|---|---|
| `session.start` | Register command `hierarchy-pane`. Start `$.clock.every(2000, tick)` and run one tick at once. Return `next(e)`. |
| tick | 1. `stat` the file. 2. Re-read and parse it only if `mtimeMs` changed. 3. Build the view model with `$.clock.now()`. 4. Update state only if the view model changed. 5. Call `$.ui.status(...)` (§6.4). 6. Raise the toasts (§6.5). 7. Auto-open the Pane (below). |
| `command.run` `{command:'hierarchy-pane'}` | `$.ui.open({id:'ah-status', title:'Hierarchy'})`, which places at any width. Clears the "closed by person" flag. Returns `{text}`. |
| `ui.render` `{component:'Pane', requestId:'ah-status'}` | Draws §6.4 Pane at `e.props.bodyColumns`. |
| `ui.render` `{component:'AbovePrompt'}` | Returns `next(e)` when `e.props.hasSurvey`, or when there is no band. Otherwise draws one line (§6.4). |
| `ui.close` on `ah-status` with origin `person` | Sets "closed by person" in `$.state`. No auto-reopen this session. |

**Auto-open:** at most once per session, when a visible doc is first seen in
a non-member session that the person has not closed. Call `$.ui.open`
unasked: it seats at ≥144 columns and waits below that. The "opened" and
"closed" flags live in `$.state`, so a reload does not reopen the Pane.

**Read-only rule:** the module calls no `$.process`, no `$.fs.write`, no
`$.session.send`, no `$.tool`, no `$.agent` and no `$.model`. A test asserts
this (§6.6).

**Timer and reload:** the engine drops the old environment's `every` timer
on a hot reload (E8). The module adds no cancel or guard.

### 6.4 Surfaces and widths

**Status entry.**

- Calls `$.ui.status(entry.text)`, or `$.ui.status(undefined)` when nothing
  should render (§4.4) or when `status_entry` is off.
- r3: no `ah · ` prefix. The engine already renders the entry as
  `⚠ ah: {text}` on its own line above any statusLine (E10), so a prefix
  would print the label twice. The `⚠` glyph is the engine's and cannot be
  changed; it is noted in the README.
- It is one line and survives any width. The engine cuts it.
- Toggle (user decision Q2; E10 showed both lines render): userConfig
  `status_entry` (boolean, default `true`) in ah's plugin.json. `false`
  keeps the entry cleared. A user who places claude-tui-line's `ah` item
  turns this off to see the counts once. How a module reads a userConfig
  value is E12.

**Band.** Shown only while the current entry has `out > 0` or `blocked > 0`.

- It is one line, and its tone colour comes from the subject below.
- The subject is the most severe item, in this order: stalled, then
  overdue, then blocked (member), then working.
- If other non-working items remain, append ` · +{k} more`.
- Cut the line to `bodyColumns` with `…`.

| Subject | Text (tone) | vs mockup |
|---|---|---|
| stalled, reason `no-report` | `{label} stalled on {slug} · {checkin phrase}` (bad). The phrase is `{n} check-in(s) unanswered` when `checkins ≥ 1`, else `no report after {m}m`. | The mockup says "the Orchestrator is asking you what to do", which the mod cannot know. The mod also cannot claim check-ins the Stop hook has not sent. |
| stalled, reason `member-gone` | `{label} stalled on {slug} · {member name} is gone` (bad) | new |
| overdue | `{label} is {over} past its {T}m eta` + (`checkins > 0` ? ` · check-in {checkins} sent` : ``) (bad) | same |
| blocked member, `route: pane` | `{label} is waiting on a prompt · answer it through the Orchestrator` (warn) | same |
| blocked member, `route: peer` | `{label} is waiting on a prompt · answer it in its pane` (warn) | A Claude peer's prompt is answered in its own pane. |
| working | `{out} out · {label} {m:ss} of {T}m`, followed by ` · {label} {m:ss} of {T}m` for each further working dispatch while it fits (work) | same |

**Pane.** Shown in this order:

1. **Hierarchy:** one line per pipeline item with `open`:
   `round {rounds}/{round_cap} · {to}`. When `waiting_on_user > 0`, add
   `{n} decisions waiting for you`.
2. **Team:** one row per member: `{name} · {kind} · {route} · {state}`.
   - `state` is `gone` when `live === false`; otherwise it is `activity`,
     plus ` {age}` from `activity_at` for pane members.
   - The tone classes match the mockup.
3. **Dispatches:**
   `{slug} → {label} | eta {eta} | {bar} {pct}% | {m:ss} | {state}`, where
   `pct = min(100, elapsed/eta_ms)`. Recent `reported` rows stay until they
   expire. When there are none: `None outstanding.`
4. **Width fallback**, on `bodyColumns`:
   - below 60, drop the bar;
   - below 40, drop `eta …`;
   - below 28, a row is just `{slug} {state}`;
   - member rows below 40 are `{name} {state}`;
   - slugs and names are cut first.

### 6.5 Toasts

| Trigger (state at now) | Dedupe key | Text |
|---|---|---|
| dispatch `reported` | `reported:{id}` | `{label} reported · {slug} · {reported_at−created as 6m 40s}` |
| member `blocked` | `blocked:{name}:{activity_at}` | `{label} blocked · {blocked_note}` when it is set (pane members); else `{label} blocked · waiting for permission` when `blocked_by == "permission"` (Claude members, E3); else `{label} blocked · waiting on a prompt` |
| dispatch `stalled` | `stalled:{id}` | `{label} stalled · {slug} · {checkin phrase from §6.4 \| {name} is gone}` |

- **Dedupe.**
  - A key toasts at most once per session.
  - The seen set lives in `$.state`, so it survives reloads.
  - Prune keys whose subject is no longer in the doc.
- **Seeding.** On the first tick of a session where the seen set does not
  exist yet, add every current key **without toasting**. A new session does
  not replay old events, and neither does a mod first loaded mid-session.
- **Where.** Toasts only in non-member sessions (Q3). No chime: the mockup's
  "could join" is not taken (YAGNI).

### 6.6 Tests (`claude plugin test <mod>`)

**view.ts: shared vectors.** For each fixture in
`agent-hierarchy/tests/fixtures/status/`, the vector file gives
`(now, sessionId, columns) → statusText, band text and tone, pane rows,
toast keys`. The tests read the fixtures in place, without a copy, if E13
shows a test can import a JSON file from inside the plugin. If it cannot,
`<mod>/tests/` gets a fixtures module that embeds the fixture JSON verbatim,
and `ah`'s bash suite fails when that module and the fixture files differ.

**view.ts: edge cases.**

- missing doc, `schema: 2`, expired doc, `visible: false`;
- a member session;
- `now` before the first `at`;
- `at == now` picks that entry;
- each band subject;
- each width breakpoint.

**register.tsx, on each surface** (`['terminal','desktop']`):

- the status entry is set and then cleared;
- the AbovePrompt band draws, and passes during a survey;
- `/hierarchy-pane` opens the Pane;
- toast dedupe and silent seeding. If the test harness can simulate a
  reload, cover dedupe across it; if not, cover dedupe within one session
  here and leave the reload case to P3 AC 3 (manual).

**Staging (E5).** Nothing sits beneath the plugin in `claude plugin test`,
so each register.tsx test answers every `$` call the module makes:

- `session.start` returns `{ cwd }` (a fake path; nothing is read from it);
- `fs.stat` returns `{ value: {kind:'file', size, mtimeMs, isLink:false} }`
  and `fs.read` returns `{ value: <fixture text> }`; a "missing file" case
  answers `fs.stat` the way the API reports absence (match `$.fs.stat`'s
  type);
- `ui.status`, `ui.toast` and `ui.open` return `{ value: undefined }`, and
  the test records their arguments to assert on;
- `mock.clock(on, { now })` drives `$.clock.every`; the test advances it.

No real file is read in any mod test.

**Read-only guard.** A test fails if the module source references
`$.process`, `$.fs.write`, `$.session.send`, `$.tool`, `$.agent` or
`$.model`. A grep-style test is fine.

**Toggle.** With `status_entry` off, the entry stays cleared.

**Checks.** `claude plugin validate agent-hierarchy` and `tsc -p <mod>` are
both clean.

## 7. claude-tui-line items (Phase 2a)

claude-tui-line's own conventions govern this phase. It is routed to that
repo's live Orchestrator session (`claude-tui-line-orchestrator`), which
writes `docs/specs/SPEC-<next>-hierarchy-item.md` from this section, in its
house style. This section is the contract that spec must satisfy. The status
file's format belongs to `ah`: `agent-hierarchy/docs/status-file.md`.

### 7.1 Items

Two items, both added to `ItemRegistry`. Neither goes in `DefaultIds`.

| Id | ColorKind | ResolveValue | Segment |
|---|---|---|---|
| `ah` | Semantic | `entry.text`, or null when §4.4 says render nothing | label `ah` (LabeledItemSettings) + text, whole text in `stateColors[entry.tone]` |
| `ah-short` | Semantic | `entry.short`, or null | `ah ` + short, in the same colour |

- Both share one resolve path. The short form follows the `model-short`
  precedent: the user places it in a narrow pane.
- Raw values are the plain text, so the existing colour `match` rules work
  on words like `blocked`.

### 7.2 Data

- `ItemContext` gains a **lazy** hierarchy-status probe, following the
  pattern of the lazy `RemoteUrl`. Rendering without either item costs
  nothing.
- The probe finds the file with §6.2's walk-up from `StatusInput.cwd`.
- It reads with a 256 KB cap and parses through a System.Text.Json
  **source-generated** context, which AOT needs.
- It yields null on any failure, and never throws.
- `now` comes from an injectable clock, so tests can pin time.
- `session_id` for the member-session rule comes from `StatusInput`.
- `SyntheticFixture` supplies a canned visible status with tone `warn`, so
  `--items` stays off the filesystem.

### 7.3 Config

Add `itemSettings.ah` with:

- `showLabel` and `labelColor`, both inherited from LabeledItemSettings;
- `stateColors {work, warn, bad, idle}`, following the `engram.stateColors`
  precedent, with defaults `blue`, `yellow`, `red`, `grey`.

Changes to make:

- `Config.cs`: the settings class, and its property on
  `ItemSettingsJsonConfig`;
- `SchemaCommand.cs`: the `structures` entry;
- `ConfigCheck.cs`: colour validation;
- the README items table.

`ah-short` reads the same settings block.

### 7.4 Safety

- Escape all text from the file for Spectre markup before building `Markup`.
- `[red]` in a slug must render literally.

### 7.5 Narrow widths

- `ah` is cut by the pane's normal overflow rules.
- `ah-short` is the narrow form: about 8–12 cells, for example `ah 3/1 1b`.
- There is no new priority mechanism.

### 7.6 Tests (xUnit, temp-dir files as in `ResolveAutocompact` tests)

- **Absent cases:** missing file, malformed JSON, `schema: 2`, expired doc,
  over 256 KB, `visible:false`, member session. Each must yield null.
- **Timeline pick:** before the first entry, at an exact `at`, between
  entries, after the last.
- **Tones:** each tone maps to its colour.
- **Walk-up:** from a nested cwd; it stops at a worktree's `.git` **file**.
- **Markup:** injection is escaped.
- **Short form:** formatting.
- **Shared vectors:** the same fixtures, copied from
  `agent-hierarchy/tests/fixtures/status/` into `tests/ClaudeTuiLine.Tests/fixtures/ah/`.
  This is a cross-repo copy of test data, and it is pinned to `schema: 1`.
- **Assertions to update:** `ItemsCommandTests` (the non-default list) and
  `SchemaCommandTests` (the structures list).
- **Examples check:** `tools/check-examples.sh` passes.

### 7.7 House rules that apply

- `SPEC-V2-FRAMEWORK.md` §1: one registry row plus resolve/build functions.
  No control-flow edits.
- Version 0.5.0 → 0.6.0 in all three `.csproj` files **and**
  `.claude-plugin/plugin.json`.
- An entry in `docs/RELEASE-NOTES.md`.
- `§`-citations pass `tools/check-citations.sh`.
- Never build into `publish/`.

## 8. Phasing and acceptance criteria

**Recommended order:** P1, then P2a and P2b in parallel, then P3.

- P1 must land first, because the schema is the contract. P2a is handed to
  `claude-tui-line-orchestrator` once P1 lands, with §7 as its brief.
- P2b is small, so it can ship with P3 if the user prefers that. P2a does
  not depend on P2b.

### P1: status source (`ah` 0.110.0)

**Step list.** One commit per step, in this order. Every commit passes the
full `ah` bash suite on its own. Work in a separate worktree and land each
commit whole (§3.7.8). The ACs each step must satisfy are in brackets.

1. **Single sources, no semantic change beyond §3.1's predicate.** Move the
   eta threshold table into one shared lib (the Stop hook imports it; its
   cadence is unchanged in this step). Move `SELF_STATE` into a lib
   (stream-label imports it). Move `reportStatus` into lib-hier on
   `hasAuthoredContent`; roster.mjs `deliver` imports it; delete
   `responseSkeleton()` if it has no caller left. [AC 7 for these three;
   AC 24; AC 14]
2. **Open rule.** §3.7.1 in `listExchanges`, with the orchestrator-addressed
   exemption in the same commit; `sweep` uses `.open`; the §3.7.6 SKILL.md
   wording; the §3.7.7 test updates. [AC 17, 18, 22, 23; AC 14]
3. **Stop-hook liveness for pane work.** The cadence constant joins the
   shared table and the Stop hook moves to `T/2` for the second nudge;
   pane-member wording; the `deliver` dispatch row in
   `pretooluse-ah-cli.mjs`. [AC 19, 20, 21; AC 7 for cadence; AC 14]
4. **Producer and verb.** `lib-status.mjs`, `roster.mjs status`,
   `tests/fixtures/status/`, `docs/status-file.md`, the `docs/cli-tools.md`
   row. No write triggers yet; tests stage activity files directly.
   [AC 1, 2, 3, 4, 10, 11, 12, 13]
5. **Write triggers.** §3.4 items 1–9 at the shared helpers, with write
   isolation. From this commit on, the live pool gets a `status.json`.
   [AC 5, 6]
6. **Activity.** `activity.mjs` and its `hooks/hooks.json` registrations
   (PostToolUse async); SessionEnd removal; pane-member recording in
   `deliver`/`answer`/spawn/dismiss/disband; `msg.mjs sweep` deletes
   activity files past its cutoff. [AC 8, 9]
7. **Release.** Version 0.110.0 in plugin.json and the root marketplace.json
   together; release text with the §3.7.5 note; run E1. [AC 15, 16, 14]

If E1 (step 7) breaks a threshold, stop and return to the Architect before
merging: the remedy (write coalescing, the 4 KB pre-check) amends this spec.

Bash tests go in `tests/test-status*.sh` and `tests/test-exchange-open*.sh`,
using `--now` and an `AGENT_HIERARCHY_DIR` temp pool. No test touches the
live pool.

1. **Verb:** `roster.mjs status` prints a valid schema-1 doc and writes
   `status.json` atomically. With no `<hier>`, it writes nothing and exits 0.
   With `--plain`, it prints `ah · …` or an empty line.
2. **Eta schedule:** one dispatch per eta size, evaluated at `created`,
   `+T−1s`, `+T`, `+1.5T−1s` and `+1.5T`. Each gives the correct current
   state and timeline counts. A late `liveness-nudge` row does not move
   `stalled_at`.
3. **Report present and dispatch set:**
   - a member-addressed request with a skeleton response stub → still
     `out`;
   - the same with the skeleton's lines reordered → still `out`;
   - a filled response → `reported`, with `reported_at` = mtime;
   - after 10 min the dispatch is gone from `out` and from the list;
   - a malformed response counts as reported;
   - an open orchestrator-addressed request (e.g. an open `<tag>-i1`
     record) is **not** in `dispatches` and adds nothing to `out`;
   - an open member-addressed request whose team is not live is not in
     `dispatches`.
4. **Member-driven rules:**
   - a gone member → `stalled` with `member-gone`;
   - a blocked member → `blocked` that wins over time;
   - after unblocking, the next write applies rule 4.
5. **Triggers:** each trigger in §3.4 advances `written_at`. Test at least
   items 1–6. A missed trigger fails its test.
6. **Write isolation:** if status.json cannot be written (read-only
   `<hier>`), the triggering `msg.mjs new` still succeeds, with unchanged
   output and exit code.
7. **Single source:** a grep test proves each of these is defined exactly
   once in `hooks/`: the eta threshold table, the check-in cadence,
   `reportStatus`, and the event→state table. The existing liveness-hook
   tests still pass unchanged.
8. **Activity hook:**
   - a role session's UserPromptSubmit, Stop and Notification produce
     `working`, `idle` and `blocked` records; the `blocked` record has
     `blocked_by:"permission"` and `note: null`, even when the input's
     `message` is set;
   - PostToolUse after `blocked` produces `working`; PostToolUse while
     already `working` rewrites nothing (the file's mtime is unchanged);
   - `hooks/hooks.json` registers PostToolUse with `"async": true` and the
     other activity events without it;
   - non-role sessions and subagents write no record;
   - SessionEnd removes the file.
9. **Pane members:**
   - `deliver`, against a stubbed `herdr` on PATH as the existing deliver
     tests do, records `blocked` with `blocked_by`;
   - `answer` records `working`;
   - spawn records `idle`; dismiss removes the record.
10. **Sanitising:** control characters, including ESC sequences, in a slug
    or name are stripped, and lengths are capped.
11. **Disabled:** a disabled config gives `enabled:false` and every timeline
    entry `visible:false`.
12. **Pipeline** (§4.2.1). Fixture: an open anchor for team `t` created at
    `t0`; member-addressed exchanges with slug `ac-1` at `t0+1m` (filled
    response) and `t0+5m` (stub, `to: reviewer`); one `ac-1` exchange
    created before `t0` (filled); one `ac-0` exchange created before `t0`
    only; a `dec-x-1` exchange after `t0`; an orchestrator-addressed
    `<tag>-i1` record after `t0`; one parked decision row. Expect:
    - `items` = exactly `[{slug:"ac-1", rounds:3, open:true, to:"reviewer"}]`;
    - `waiting_on_user` = 1, equal to `decisionSummary`'s parked count;
    - `started` = `t0`, `round_cap` = 3;
    - the same pool after the anchor gets a bodyless response →
      `pipeline: null`;
    - two open anchors for `t` → `pipeline: null`.
13. **Docs:** `docs/status-file.md` documents the schema, §4's rules and the
    fixture vectors. `docs/cli-tools.md` has a `status` row.
14. **Full suite:** every existing test passes.
15. **Version:** bumped in plugin.json and the root marketplace.json
    together.
16. **Evidence:** E1 is measured and reported against the thresholds in
    §11, and E11's suite run is reported (it is AC 14 at step 2). E2–E5 and
    E8–E10 are already in `0071-evidence.md`.
17. **Open rule** (`tests/test-exchange-open*.sh`):
    - member-addressed request (`--to architect`) + skeleton stub →
      `msg.mjs list` shows it open;
    - once filled → closed;
    - a response without frontmatter → closed;
    - orchestrator-addressed request (`--to orchestrator --from
      orchestrator`) + bodyless response → closed;
    - a role's request `--to orchestrator` + bodyless response → closed;
    - `--closed` and `--all` agree.
18. **Sweep:** an 8-day-old stub-only member pair is **not** archived; an
    8-day-old filled pair is; an 8-day-old stub-closed orchestrator record
    is.
19. **Stop hook, Claude peer:** a SendMessage'd dispatch whose response is
    still a stub, past `T`, gets a block decision. Before r2 it got none.
20. **Stop hook, pane member:**
    - an orchestrator Bash `roster.mjs deliver <name> --req <path>` writes a
      `dispatch` row through `pretooluse-ah-cli.mjs`;
    - `--wait-only` writes none;
    - past `T` with a stub response, Stop blocks, and that item's line uses
      the pane wording (no ListAgents or SendMessage).
21. **Cadence:** the first nudge is at `T`. The second is due when
    `now − ts1 ≥ T/2` and not before. The third is due when
    `now − ts2 ≥ T`. A grep test shows the cadence numbers exist only in the
    shared lib.
22. **Push guard** (`merge-check`, in `test-pipeline-merge.sh` or a new
    file): with an open anchor and an open `<tag>-i1` record,
    - a `<tag>-i1-ok` exchange (`--to architect`) with a skeleton response
      → `not-signed-off`; with a filled response → no `not-signed-off`;
    - a `<tag>-i1-x` record closed by a bodyless response → no `exception`;
    - the suite passes with §3.7.1 in place; any other failure goes to the
      Architect (E11).
23. **Records unchanged** (`tests/test-exchange-open*.sh`): a pool whose
    only anchor is closed by a bodyless `msg.mjs new --type response`
    gives `pipelineRunLive` false, `liveRun` null and `runLiveness` "not";
    the same pool with a second, open anchor gives exactly one live run
    (`liveRun` returns it). `tests/test-pipeline-decisions.sh` passes
    without edits.
24. **One report predicate:** a grep test shows no byte comparison against
    the response skeleton remains in `hooks/` (`responseSkeleton` is gone
    or has no caller in `reportStatus`), and `reportStatus` is defined once.
    A unit-level bash test drives `reportStatus` through its four outcomes,
    including a reordered skeleton → `no-report`.
25. **Skill wording:** `skills/autonomous-pipeline/SKILL.md` no longer
    contains "body `closed:" or "as the response body"; it states the
    `--to orchestrator --from orchestrator` record address once, with the
    literal request command.

### P2a: claude-tui-line items

1. All of §7.6 passes.
2. The `check-*` scripts pass.
3. The version and release notes follow the §7.7 rules.
4. E7: bench p95 with a 20 KB status file adds ≤ 1 ms.

### P2b: mod skeleton plus status entry

1. **First, before any mod code:** E12 and E13 are run and their results
   recorded in the P2b report.
2. `ah` loads through `claude --plugin-dir agent-hierarchy`. The user
   launches it.
3. `validate` and `tsc` are clean.
4. The full `ah` bash suite passes with the mod files present, and the
   command hooks are unaffected.
5. The status entry passes its vector tests and the absent cases. It does
   not render in a member session. Its text has no `ah · ` prefix.
6. `status_entry` off suppresses the entry.
7. The read-only guard passes.
8. **After release, by the user:** with `ah` updated from the marketplace
   (an installed copy, not `--plugin-dir`), a classic `ah` hook still fires
   (the SessionStart context line appears) and the status entry shows in a
   non-member session with a live team. If the classic hooks stop firing,
   roll back to 0.110.x and return to the Architect.

### P3: band, pane, toasts

1. All of §6.6 passes.
2. The auto-open rules hold: once per session, never after a person closes
   the Pane, and never in member sessions.
3. Toasts do not repeat across a reload. A fresh session seeds silently.
4. A manual check by the user in a 118-column Herdr split shows:
   - the band visible;
   - the Pane waiting until `/hierarchy-pane`, then opening inline;
   - the counts on exactly one line: with `status_entry` on and no
     claude-tui-line `ah` item placed, the `⚠ ah: …` line; with the item
     placed and `status_entry` off, the claude-tui-line item.

## 9. Decisions made, with rationale

| Decision | Why |
|---|---|
| A summary **file**, written on events. Consumers never spawn the verb. | The status line refreshes about every 1 s with a budget of about 12 ms. A node spawn costs more than that. One file keeps a single implementation. |
| Scheduled transitions in the doc | Eta and stall need time, not events. Scheduling them keeps every eta, stall and count rule in `ah`, and consumers keep one generic "pick by `at`" rule. |
| The producer emits the status `text`, `short` and `tone` | Both status lines then show identical text with no duplicated formatting. Band, Pane and toast wording is presentation, so it stays in the mod. |
| No Herdr polling. Activity is recorded by events. | Claude peers get exact set and clear points from their own hooks. Pane members are already watched by `deliver`. The alternative was a long-lived poller, either a daemon or a mod running processes. That breaks the mod's read-only contract, or adds a process lifecycle to manage. |
| One open rule, `reportStatus`-based, inside `listExchanges` | User decision. A skeleton stub is not a report. Fixing it at the shared function fixes every caller (§3.7.2), and the status file needs no rule of its own. |
| The report test applies only to member-addressed exchanges; orchestrator-addressed ones close on any response (r3) | Pipeline records are skeleton-closed by design, and no one owes the Orchestrator a report on its own record. The filename already carries `to`, so the test costs nothing. A `--body` flag would also work going forward, but would reopen every record already closed in every pool, needing a migration and a landing order (§3.7.1). Push guard and msg.mjs stay untouched. |
| `reportStatus` uses `hasAuthoredContent` (r3) | Two predicates for one behaviour existed. The line-based one was already chosen over a byte compare as less brittle. |
| The status view counts only member-addressed requests of live teams (r3) | Records are not member work and would otherwise go overdue and stalled. A dead team's requests have no Orchestrator to act on them. |
| Pipeline items are the slugs of member-addressed exchanges since the anchor, with the skill's own rounds count (r3) | Plan runs have no item list on disk; the skill's slug rule is the only definition there is, so the view applies it mechanically rather than inventing one. |
| Implement P1 in a worktree and land whole commits (r3) | The run's `ah` CLI root is the tree P1 edits. A half-edited tree crashes every live hook, including the push guard. |
| `stalled` at `created + 1.5T`, and the Stop hook's second nudge at `T/2` after the first | User decision Q4 (spec 0028 §5.7.2). One table of constants feeds both. The schedule stays absolute in the status file so states never flip back, and relative in the hook so nudges never bunch up. |
| A `dispatch` row for `deliver`, and pane wording in the Stop hook | Without both, the stub fix does not make liveness fire for pane work, which the user asked for. The existing wording (ListAgents, SendMessage) fails for pane members. |
| The mod bundled in `ah`, through plugin.json `"hooks": "./mod/hooks.json"` | User decision Q1; E9 proved it. The string form is the smallest that works; merging both keys into one hooks.json worked too but contradicts the reference. |
| The mod's status entry has a `status_entry` toggle, default on, and no `ah · ` prefix | User decision Q2 fallback: E10 showed it renders above the statusLine, so both can show at once. The engine already labels it `⚠ ah:`. |
| Activity hook on PostToolUse(`*`), async | User decision Q5. E2: async is honoured, so the hook costs no tool-call latency. |
| No `blocked_note` for Claude members | E3: the Notification message is a constant with no tool or title. `blocked_by:"permission"` already says all it says. |
| Consumers locate the file by walking up to `.git` | It is the same in both consumers, cheap, and needs no process. Its ceiling is noted. |
| Opt-in claude-tui-line items, with a separate `ah-short` | This follows the `model-short` precedent. A default item would move about 28 whole-line assertions and would show to users without `ah`. |
| Multi-team pools are summed in counts. The Pane groups rows by team. | Multi-team is rare. Per-orchestrator scoping would need the orchestrator's session id, which a plain top-level session never records. |

## 10. User decisions, and what changed (r1 → r2 → r3)

| Q | Decision | Where it lands |
|---|---|---|
| Q1: where the mod ships | Bundle into `ah` if E9 proves a plugin can carry both kinds of hooks file; otherwise the separate `ah-status` plugin. **E9 passed → bundled (Branch A).** | §6.1 |
| Q2: the mod's status entry | Keep it on with no toggle, provided E10 shows that a configured `statusLine` hides it. If both render, add a `status_entry` toggle, default on. **E10: both render → toggle, default on.** | §6.4 |
| Q3: member sessions | Orchestrator-only view: both consumers render nothing in a member session. | §4.4, §6.5 |
| Q4: stall threshold | `1.5T`, per spec 0028 §5.7. The Stop hook moves to the same table, so the second nudge comes `T/2` after the first. | §3.1, §4.2, §3.7.4 |
| Q5: PostToolUse(`*`) activity hook | Accepted. E2 still bounds it. **E2: async honoured.** | §3.3 |
| Stub bug | Fix it in P1. | §3.7 |
| Q6: liveness for pane work | **(a), approved:** the `deliver` dispatch row (§3.7.3) and the pane-member wording in the Stop hook (§3.7.4) are in P1. | §3.7.3, §3.7.4, P1 AC 20 |

Changes from r2 (r3, after the evidence in `0071-evidence.md`):

- **§3.7.1 (NEEDS-ARCHITECT #5):** the report test applies only to
  member-addressed exchanges. Orchestrator-addressed exchanges (every
  pipeline run record) close on any response, as before. So anchors, `-x`
  and item records, `liveRun`, `pinnedMerge` and the stale-anchor fix all
  behave exactly as in 0.109.0; only `-ok` gets stricter. No `msg.mjs` or
  push-guard change; §3.7.6 fixes the SKILL.md wording that promised a body
  nothing wrote. §3.7.2 now lists every caller.
- **§3.1:** `reportStatus` moves into lib-hier on `hasAuthoredContent`, the
  existing second predicate r2 missed.
- **§3.7.7–3.7.8 (new):** existing-test policy, and how P1 lands safely while
  the run that builds it is live (worktree, whole green commits, exemption
  in the open-rule commit).
- **§3.3, §3.2, §6.5 (E3):** Claude members record `note: null`; the toast
  words `blocked_by:"permission"` itself. **§4.5:** the 6–8 s lag.
- **§3.3 (E2):** PostToolUse is async; the other activity events stay sync.
  **§3.1:** a killed async writer loses nothing that matters.
- **§4.2:** the dispatch set is member-addressed requests of live teams.
  **§4.1:** `teams` = live teams. **§4.2.1 (new):** exact pipeline rules.
- **§6.1 (E9):** Branch A only, string-form `hooks` key; Branch B and the
  fixture drift guard are gone.
- **§6.3 (E8):** no timer guard.
- **§6.4 (E10):** `status_entry` toggle, default on; entry text has no
  `ah · ` prefix.
- **§6.6 (E5):** how tests stage `$` calls; fixture import is E13.
- **§8:** a P1 step list in commit order; P1 ACs 3, 8, 12, 16–18, 22 made
  exact; new ACs 23–25; P2b ACs rewritten (E12, E13 first; installed-copy
  check by the user); P3 AC 4 reworded for the toggle.
- **§11:** verdicts recorded; E12 and E13 added.

Changes from r1 (r2):

- **§3.7 is new.** It holds the open rule, the effect on each caller, the
  `deliver` dispatch row and the two Stop-hook changes.
- **§1** gains the dispatch-row fact.
- **§2** lists the extra files.
- **§3.4** gains trigger 9.
- **§4.2** stalls at `1.5T`.
- **§5** no longer freezes `msg.mjs list` semantics or the Stop hook.
- **§6.1** has two branches.
- **§6.4 and §6.5** word stalled items from `checkins`.
- **§8** has new ACs: P1 17–22, and P2b now starts with E9 and E10.
- **§11** adds E10 and E11, and makes E9 a gate.
- **§12** drops the "out of scope" gap.

**Added scope (Q6).** The user approved it. The stub fix alone does not
make liveness fire for `deliver`'d pane work, so P1 also adds:

- a `dispatch` row written by `pretooluse-ah-cli.mjs`;
- the pane-member wording in the Stop hook (§3.7.3–3.7.4).

## 11. NEEDS-EVIDENCE

r3: E2–E5 and E8–E10 are done; results are in `0071-evidence.md` and folded
into the body (§10). Their rows stay for the record, each marked with its
verdict. Open: E1 (P1 step 7), E7 (P2a), E11's suite run (P1 step 2), E12
and E13 (P2b start).

| # | Run or measure | Decides |
|---|---|---|
| E1 | **Open (P1 step 7).** Once P1 is built: time the status write path 50×, and `listExchanges` alone 50×, against a copy of the live `agent-tools` `.claude/hierarchy` (copy into `T=$(mktemp -d)`, check `T` is non-empty, and run with `AGENT_HIERARCHY_DIR=$T/hierarchy`). Report p50 and p95 for each. | Status write p95 ≤ 15 ms → ship as is. Over 15 ms → add write coalescing (skip a write if the last one was under 1 s ago, plus one trailing write), and amend the spec. `listExchanges` p95 over 5 ms → add the size pre-check from §3.7.1. |
| E2 | **Done: async honoured; sync = 32–36 ms per call; async killed at `-p` exit.** Does Claude Code 2.1.289 honour `"async": true` on a command hook in a plugin's hooks.json? Measure the added wall-clock per tool call for PostToolUse(`*`) with and without it. | Async works → register it async. It does not → measure sync cost; over 50 ms per call → escalate Q5 to the user with the number. |
| E3 | **Done: fires ~6–8 s late; `message` is a constant → `note: null`.** In an `--agent` peer session under a test team in a temp git repo, trigger a permission prompt. Does Notification(`permission_prompt`) fire, and what does its `message` field contain? | Fires → design holds, and `blocked_note` = message. Does not fire → Claude-peer blocked detection has no event source; return to the Architect. |
| E4 | **Done: yes (idle ≤ 1 s; busy at next tool boundary).** Does UserPromptSubmit fire in a peer when a cross-session `SendMessage` brief arrives? | Yes → `working` is immediate. No → the first PostToolUse sets it, and docs/status-file.md says so. No design change. |
| E5 | **Done: tests answer every `$` call; `mock.clock` drives `every` (§6.6).** `claude plugin test`: how does a test stage `$.fs.stat/read` content (a `mock`, or a real file under the test's cwd), and does the mocked clock drive `$.clock.every`? | Shapes the register.tsx tests. view.ts tests do not depend on it. |
| E7 | **Open (P2a).** claude-tui-line `bench/bench.sh` with `ah` placed, against a 20 KB status file, before and after. | Added p95 > 1 ms → cache the parsed doc by mtime in-process. Otherwise nothing. |
| E8 | **Done: the engine cancels it.** After a hot reload, is a `$.clock.every` timer started in the old `session.start` cancelled by the engine? | No → the module must cancel it (`session.end`, or a guard). |
| E9 | **Done: Branch A, both forms load both files (§6.1).** Can one plugin carry both a classic command-hooks file and a `{modules:[…]}` hooks file? Steps: (1) In `T=$(mktemp -d)`, checked non-empty, build plugin `$T/p`. `hooks/hooks.json` holds a classic SessionStart command hook that writes `$T/classic.ok`. `mod/hooks.json` is `{"modules":["./register.ts"]}`, and its `session.start` hook does `$.fs.write("$T/mod.ok","1")`, path baked in, then `next(e)`. (2) Try each plugin.json form in turn: `"hooks": "./mod/hooks.json"`, and `"hooks": ["./hooks/hooks.json","./mod/hooks.json"]`. (3) For each form, run `claude plugin validate $T/p`, then `timeout 90 claude --plugin-dir $T/p -p "reply ok"` from `$T/repo` (`git -C "$T/repo" init`). Record which markers appear. (4) Check `pgrep -fl claude` and kill anything this probe started. | Both markers under some form, and validate clean → **Branch A**, using that form. Otherwise → **Branch B**. If `mod.ok` never appears under `-p` even in a lone-module control plugin, repeat the run interactively, as in E10. |
| E10 | **Done: both render (`⚠ <plugin>: …` above the statusLine) → toggle (§6.4).** Note for any rerun: the 2.1.289 folder-trust dialog defaults to "No, exit"; accept with `Down` then `Enter`. Does a configured `statusLine` command hide `$.ui.status` output? Steps: (1) In `T=$(mktemp -d)`, checked non-empty, run `git -C "$T/repo" init`. Write `$T/repo/.claude/settings.json` with `{"statusLine":{"type":"command","command":"echo E10-STATUSLINE"}}`. (2) Build mod plugin `$T/m`. Its `session.start` calls `$.ui.status("E10-PROBE")` and writes `$T/m.ok`. (3) Run `tmux new-session -d -s e10-$$ -x 200 -y 50 -c "$T/repo" "claude --plugin-dir $T/m"`. If the folder-trust dialog shows in `tmux capture-pane -p`, accept it with `send-keys Enter`. Wait ≤ 30 s, until `$T/m.ok` exists. (4) Run `tmux capture-pane -p -t e10-$$ > $T/screen.txt`, then grep it for both strings. (5) Run `tmux kill-session -t e10-$$`, then check `pgrep -fl claude` and kill what this probe started. | STATUSLINE shown and PROBE absent → no toggle (§6.4). Both shown → `status_entry` toggle, default on. STATUSLINE absent, or `m.ok` absent → the probe is invalid; fix it and rerun. Never guess. |
| E11 (P1) | **Read part done** (it found NEEDS-ARCHITECT #5, resolved in §3.7.1). **Suite run open (P1 step 2):** with §3.7.1 in place, run the full `ah` bash suite. | Green after only the §3.7.7 updates → done. Any other failure → return it to the Architect before step 2 lands. |
| E12 (P2b start) | Read the plugin-authoring reference (load the `plugin-authoring` skill) and, if it is not explicit, probe: how does a module read a plugin `userConfig` value, and does adding a `userConfig` key to an installed plugin's plugin.json prompt the user on update or enable? Probe sandbox-safely as in E9 (`T=$(mktemp -d)`, checked non-empty; `--plugin-dir`; `--setting-sources local`; timeout; `pgrep -fl claude` afterwards). | Readable and no prompt, or a prompt with the default pre-filled → userConfig as in §6.4. Not readable by a module → return to the Architect (the fallback is a `$.store` flag set by a mod command). A blocking prompt for every `ah` user → return to the Architect; it becomes a user decision. |
| E13 (P2b start) | Can a `claude plugin test` test file under `<mod>/tests/` import a JSON file under `agent-hierarchy/tests/fixtures/status/` (a static `import … with { type: "json" }`, or a plain import)? One-test probe in a scratch copy of the plugin. | Yes → tests read fixtures in place. No → the embedded fixtures module plus the bash drift check (§6.6). |

All probes must be sandbox-safe:

- variables are assigned in the script;
- `mktemp -d` is checked to be non-empty;
- every git write is `git -C "$T/…"`;
- headless runs get timeouts, and no stray `claude` processes are left
  behind.

## 12. Risks and notes for the Implementor and Orchestrator

- **The open-rule change has a wide blast radius** (§3.7.2). Every caller
  sees stub-only member exchanges as open. Older unfilled stubs reappear
  (§3.7.5), roles holding one count as busy, the status view shows them as
  stalled while their team is live, and `-ok` sign-offs need content.
- **The record exemption rests on an address.** It holds because run
  records are created `--to orchestrator`, which the tests, the stale-anchor
  command and the live anchor all show, and which §3.7.6 now states in the
  skill. A record some past Orchestrator addressed to a role would read
  open after the upgrade if it was stub-closed; the halt and the list make
  it visible, and filling the stub closes it.
- **P1 lands under a live run** (§3.7.8). The worktree rule is what keeps a
  half-edit from disabling the push guard mid-run.
- **Two activity sources.** stream-label and stream-status keep reading
  Herdr for tab glyphs, while the status view reads activity records. They
  can disagree for a moment. A later spec could point stream-status at the
  activity records.
- **Repo-written file.** status.json lives in the repo. A hostile repo could
  commit one with `git add -f`. That is why consumers only display it:
  - text is escaped (§7.4);
  - control characters are stripped by the producer, which a hostile file
    can skip, so consumers must escape anyway;
  - there is a size cap;
  - the mod never runs anything named in the file.
- **Mod API version.** The mod needs Claude Code ≥ 2.1.289. Say so in the
  `ah` README, through docs-writer, together with the `⚠ ah:` rendering and
  the `status_entry` toggle.
- **Installed-copy loading is untested** (E9 used `--plugin-dir`). P2b AC 8
  is the check, and a rollback path is named there.
- **`$.state` writes.** These are refused during `ui.render`. All state
  writes happen in the tick, `command.run` and `ui.close`.
- **Spec 0028.** As of r2, the Stop hook follows §5.7.2's half-threshold
  second check-in. §5.7.3's `/loop` timer prose in `agents/orchestrator.md`
  is not touched.
