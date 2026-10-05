# 0071 — Hierarchy status view: one status file, two status lines, one mod

Implementer: implementor
Reviewer: reviewer

Status: r3.28. Built and released in `agent-tools`: P1 (`ah` 0.110.0),
P2b (0.111.0) and P3 (0.112.0). The whole-branch review passed. r3.28
(§13, not yet built) hardens every reader and writer of `status.json` and
`activity/*.json` against non-regular files, as `ah` 0.112.1. P2a is not
built here: it is claude-tui-line's SPEC-106, with §7 and §4.4 as its
contract. The user still checks three things by hand:
- P2b AC 2(b), before the merge;
- P3 AC 4, including the person close (K1);
- P2b AC 8, after release, on the installed copy.

§10 records the user's decisions (Q1–Q6, the stub bug) and the changes
r1→r2→r3. Evidence: `0071-evidence.md` beside this file.

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
| The enabled flag comes from `resolveConfig().enabled`. It is written outside hook code: the `/hierarchy` command (`commands/hierarchy.md`, not a skill) has the model write it with the Write tool. | `lib-config.mjs:1426,1491`; `commands/hierarchy.md:144-151,185-195` |
| Mod API (Claude Code 2.1.289): `$.fs` has `read/stat/exists/list`. `$.clock.every`. `$.session.cwd()/id()`. `$.ui.status/toast/open`. `$.state` lives for the session and survives reloads; `$.store` survives across sessions. An unasked Pane seats at ≥144 columns, an asked one at any width. AbovePrompt has no width threshold and gives `bodyColumns`. After a hot reload the engine drops the old environment's timers. | plugin-authoring `reference.md:11-71,77,88-90`; `types/claude-code.d.ts:9713-9814`; evidence E8 |
| One plugin can carry its classic command hooks and a `{modules}` hooks file together: with plugin.json `"hooks": "./mod/hooks.json"`, the standard `hooks/hooks.json` still loads on its own and both fire. (The reference says one hooks.json holds only one kind; a single file with both keys also worked, but this spec does not rely on it.) Tested with `--plugin-dir` only, not an installed marketplace copy. | evidence E9 |
| `$.ui.status(text)` renders as `⚠ <plugin name>: <text>` on its own line **above** a configured statusLine; the statusLine does not hide it. `ah`'s plugin name is `ah`, so the mod's entry reads `⚠ ah: <text>`. | evidence E10; `agent-hierarchy/.claude-plugin/plugin.json` |
| `claude plugin test`: nothing sits beneath the plugin. A test must answer `session.start` (return `{cwd}`), `ui.status` (`{value: undefined}`), each `fs.*` call (`{value}`), and the clock through `mock.clock(on,{now})`, which drives `$.clock.every` exactly. There is no `mock.fs`, and real files are never read through `$.fs`. `mock` has only `clock`, `store`, `env`. | evidence E5 |
| `ah`'s plugin.json today has no `hooks`, `types` or `userConfig` key. Version 0.109.0. | `agent-hierarchy/.claude-plugin/plugin.json` |
| claude-tui-line: an AOT exec runs on about every 1 s refresh. It has no daemon. The builtin item model is a registry row plus resolve/build functions. Item settings go in `itemSettings`. File-reading items like `autocompact` and `engram` already exist. | claude-tui-line `ItemRegistry.cs`, `SegmentBuilder.cs:340-390`, `Config.cs:48-78`, `ItemContext.cs:11` |

## 2. What changes, by repo

| Repo / plugin | Kind | Files |
|---|---|---|
| `agent-tools/agent-hierarchy` (`ah`), P1 | changed + new | new `hooks/lib-status.mjs`, new `hooks/activity.mjs`, `hooks/hooks.json`, `hooks/roster.mjs` (new verb `status`; `deliver`/`answer`/spawn record activity; `reportStatus` moves to lib-hier), `hooks/lib-hier.mjs` (`reportStatus` lands here on `hasAuthoredContent`; `ETA_THRESHOLD_SEC`, `thresholdFor`, `SELF_STATE` and the step-3 cadence constant land here, §3.1; `listExchanges` open rule; `sweep`, §3.7), `hooks/lib-roster.mjs`, `hooks/lib-config.mjs` (r3.8: `MSG_ROLES` moves here beside `ROLES`, re-exported from lib-hier; nothing else), `hooks/lib-peer.mjs` (the dispatch-origin function, §3.1), `hooks/lib-decisions.mjs` (trigger only), `hooks/sessionstart.mjs`, `hooks/sessionend-roster.mjs`, `hooks/stop-orchestrator-liveness.mjs` (constants move to lib-hier; second check-in at T/2; reason text for pane members, §3.7), `hooks/pretooluse-ah-cli.mjs` (writes a dispatch row for `deliver`, §3.7), `hooks/stream-label.mjs` (imports `SELF_STATE` from lib-hier); `hooks/roster.mjs` also derives `STREAM_SELF_STATES` from `SELF_STATE`, `commands/hierarchy.md` (the `on`/`off`/`init` steps refresh status, §3.4 item 8), `skills/autonomous-pipeline/SKILL.md` (record wording only, §3.7.6), new `docs/status-file.md`, `docs/cli-tools.md`, new `tests/test-status*.sh`, new `tests/test-exchange-open*.sh`, new `tests/fixtures/status/`, existing tests whose assertions encode "a bodyless response closes a member exchange" (§3.7.7), `.claude-plugin/plugin.json` (0.110.0), root `.claude-plugin/marketplace.json`. `hooks/pretooluse-push-guard.mjs` (one `merge-check` sign-off condition only, §3.7.9). **Not changed:** `hooks/msg.mjs`. |
| `agent-tools/agent-hierarchy` (`ah`), P2b/P3 | new code | `agent-hierarchy/mod/`, plus `hooks`, `types` and `userConfig` keys in ah's plugin.json (§6.1). r3.11: also the fixture-regeneration command and a drift test under `agent-hierarchy/tests/` (§6.6), the `ah` README, the CHANGELOG, and the root marketplace.json version. |
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
    liveness rule, `pipelineRunLive`, `openRunAnchor`, `decisionSummary`,
    and `resolveConfig().enabled`.
  - r3.6: the team liveness rule is lib-roster's `teamIsLive(t, null)`:
    pid alive and age ≤ 24 h, with **no invoker**. Passing an invoker
    would make the pool-wide document depend on which session wrote it.
    (`roster.mjs teams` computes no live flag, so r3's pointer to it was
    wrong.)
  - r3.6: `memberIsLive` (roster.mjs:4060) is an entry-point function, so
    it moves into lib-hier as one exported function that returns the
    member's attributed peers row together with its liveness; lib-status
    uses both (`session_id`, `live`), and roster.mjs's `memberIsLive`
    calls it with behaviour unchanged.
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
    - the first check-in falls due `T` after the dispatch's **origin**
      (below);
    - the second falls due `T/2` after the first;
    - every later one falls due `T` after the previous one.

    The Stop hook applies that table relative to the nudges it actually
    sent; §3.7.4 covers its behaviour changes. The status view applies the
    same table to the ideal schedule, so `overdue_at = sent_at + T` and
    `stalled_at = sent_at + 1.5T` (§4.2). Neither copies a number.
  - **Dispatch origin (r3.3).** Every liveness and status clock starts at a
    request's **origin**: the earliest `created` among the `type:"dispatch"`
    rows for that request id, from any session. Those rows live in
    `~/.claude/agent-hierarchy.peer-pending.jsonl` (lib-peer.mjs:249,
    `{type, session_id, request_id, to, created}`); SendMessage writes one
    per send (posttooluse-peer-resolve.mjs:62) and §3.7.3 adds one per
    `deliver`. The request file's own `created` is never a clock origin: a
    request written early and sent later (queued rework) would count its
    queue time as work time. Earliest, not latest, so a re-send after a
    nudge cannot reset the clock and hide a stall. A request with no
    dispatch row has no origin and is not "out" (§4.2). One exception
    (r3.5): an id that has dispatch rows, none with a parseable `created`,
    takes the request file's `created` as its origin. A corrupt row must
    not hide a dispatch; this fails toward nudging, as `dueForNudge`
    already does for a bad gate `ts`. One exported
    function in `hooks/lib-peer.mjs` (which owns the rows) computes it
    for a set of request ids, reading the rows once per call (r3.10); the
    Stop hook and lib-status both call it, once per run. Its name
    is the Implementor's choice; AC 7 covers it.
  - stream-label's event→state table (`SELF_STATE`). Move it to a lib, and
    stream-label imports it.
  - **Placement (r3.1).** All three go into `hooks/lib-hier.mjs`, beside the
    existing `ETAS` enum (lib-hier.mjs:33), as exports under their current
    names:
    - `ETA_THRESHOLD_SEC`, keyed by `ETAS`, values unchanged;
    - `thresholdFor(eta)`, moved with the table, behaviour unchanged
      (absent or unrecognised eta → the `small` value);
    - `SELF_STATE`, value unchanged.

    `stop-orchestrator-liveness.mjs` and `stream-label.mjs` import them and
    keep no local copy. `roster.mjs`'s `STREAM_SELF_STATES` (:4539), the
    `--self-state` value list, is derived from `SELF_STATE`'s values rather
    than restated, keeping the `working, idle, blocked` order its error text
    shows. In step 3 the check-in cadence joins them in lib-hier as one
    exported constant; its identifier is the Implementor's choice, defined
    once. Why lib-hier: `ETAS` already lives there and is documented as the
    liveness threshold; the Stop hook, lib-status and activity.mjs import
    lib-hier anyway; and lib-config is not in §2's changed list.
  - **stream-label loads lib-hier lazily (r3.2).** A static import would
    add lib-hier's load to every session on each UserPromptSubmit, Stop and
    Notification, before stream-label's early exit. r3.5: the Implementor
    measured the saving on the inert path at about 0.4 ms (the earlier
    "~6 ms" was a whole-process comparison). The rule stands on the
    contract, not the number: stream-label is "inert in every session that
    is not a stream member", and the lazy import keeps it so for free. The
    same reasoning covers the lazy lib-hier/lib-peer import in
    `pretooluse-ah-cli.mjs`, which runs on every Bash call and needs them
    only for a `deliver`. So stream-label has **no** static lib-hier import: it
    dynamically imports lib-hier for `SELF_STATE` only after the
    `HERDR_PANE_ID`/`AH_TEAM_FILE` check passes. Non-stream sessions load
    nothing new, and `SELF_STATE` is still defined once. A grep test (AC 7)
    asserts stream-label has no static import from `./lib-hier.mjs`.
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
`schema` other than 1. r3.12: adding a value to an enumerated field is
also additive, because consumers fall back on unknown values (§4.4 step 4).

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
  "member_sessions": ["<session id>", "..."], // session ids of live claude members (every member that is not pane-driven, §4.1 r3.13, whatever its route) across all live teams
  "teams": [{
    "team": "agent-tools",                     // null for the default team (team.json), §4.1
    "members": [{
      "name": "agent-tools-architect", "role": "architect", "label": "architect",
      "kind": "claude", "route": "peer",       // kind from the team file, default "claude"; r3.13: route = how ah reaches it: "pane" iff pane-driven (§4.1), else "peer" (a claude+pane member reads "peer")
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
      "created": "ISO",                          // request file's created; informational only
      "sent_at": "ISO",                          // the dispatch origin (§3.1); every elapsed time is measured from it
      "checkins": 0,                             // count of liveness-nudge gate rows for this request id
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

`at` (r3.9) is when the subject entered its current state: the first
observation of that `activity`/`blocked_by`/`note`. An observation that
matches the record never rewrites it, so `at` is never refreshed while the
state holds. The same holds for Claude and pane members. Two things depend
on this: the Pane's age reads as "blocked for 12m", and the toast dedupe
key `blocked:{name}:{activity_at}` (§6.5) fires once per blocked episode
rather than once per `deliver` run.

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
  - r3.9: `note` is the screen line holding the recognised prompt's heading,
    which deliver already reads. An unrecognised prompt gets `note: null`.
  - r3.9: "differs" means a different `activity`, `blocked_by` or `note`.
    The exit write follows the same rule: it writes the last observation
    only if the record does not already equal it, and never just to
    refresh `at` (see `at` above). A run that observed nothing
    (indeterminate, timeout) writes nothing.
- `roster.mjs answer`: after a successful relay it records `working`.
- `spawn-one` and `spawn-ad-hoc` of a pane member record `idle`. r3.9:
  that means **every** path that spawns a `route: pane` member, including
  `create --spawn`. Put the recording at the lowest spawn helper those paths
  share, or in each path if they share none; a new spawn path must not be
  able to miss it.
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
8. The `/hierarchy` command's config-changing steps refresh the file
   (r3.7: the flow is the command file `agent-hierarchy/commands/hierarchy.md`,
   not a skill). That file has the model write `"enabled"` with the Write
   tool: `on`/`off` (:185-195) and `init` step 5 (:144-151). So the trigger
   is one prose step in each, placed after the config write and before the
   resolved-table echo: run
   `node <AH_ROOT>/hooks/roster.mjs status --plain --cwd <abs cwd>`, in the
   same form the file already uses for `roster.mjs doctor` (:94, :152). Its
   one-line output need not be shown. No other step of the command changes,
   and no code writes `enabled`. If the model skips the step, the next
   session start rewrites the file anyway (item 6).
9. Every `liveness-nudge` append to gates.jsonl (at `appendGate`), so
   `checkins` stays current.

Layering is the Implementor's call: put each trigger at the lowest shared
write helper. No call site may be missed in a way that a new caller of that
helper would also miss.

**How the helpers reach lib-status (r3.7).** The helpers (`appendRosterRecord`,
`createMessage`, `appendGate` in lib-hier; `writeTeam`/`clearTeam` in
lib-roster; `appendDecision`/`appendMergeRecord` in lib-decisions) import
lib-status **statically**, which closes an ESM import cycle with it. This
replaces r3's "without an import cycle". The alternatives each fail a
requirement:

- an async `import()` loses the write in any process that exits right after
  the helper (the Stop hook exits straight after `appendGate`);
- `require(esm)` throws on Node older than 20.19/22.12, and the swallowed
  error would silently mean no status file;
- triggers at entry points miss new callers, and item 2 would need msg.mjs
  edits (§5);
- a registration module only works in processes that also import
  lib-status, which is the entry-point problem again.

The cycle is safe under these conditions, and P1 must keep them:

- **No top-level reads across the cycle.** No module in the cycle reads a
  binding imported from another cycle member while it is being evaluated.
  Every use is inside a function that runs after loading. A lib-status
  constant derived from an imported value is computed on first use, not at
  module top level. The codebase already relies on this for lib-config ↔
  lib-roster.
- **No re-entry.** A status write never calls a triggering helper. A
  trigger that arrives while a write is already running in the same
  process is ignored, so a future read helper that writes cannot loop.
- **Load-order test.** One test, part of AC 5, imports each of
  `lib-status`, `lib-hier`, `lib-roster`, `lib-decisions`, `lib-peer` and
  `lib-config` **first**, each in a fresh `node` process. Every one must
  load without error, and a status write from each must succeed.
- **Cost.** Every process that imports lib-hier now also loads lib-status.
  E1 measures that load delta along with the write cost.
- **r3.8: lib-config is in the cycle too** (lib-config → lib-roster →
  lib-status → lib-hier → lib-config), so effectively every `ah` hook now
  loads the whole lib graph. lib-hier's top-level
  `MSG_ROLES = ["orchestrator", ...ROLES]` was a cross read and crashed
  every lib-config-first process. Ratified fix: `MSG_ROLES` is defined in
  lib-config right after `ROLES` (same value), and lib-hier re-exports it,
  so importers are unchanged. Any new top-level cross read is caught by
  the load-order test, which therefore covers all six libs it names. One
  consequence: r3.2's lazy lib-hier import in stream-label no longer
  avoids anything, since lib-config now pulls lib-hier in. It stays
  (harmless, and AC 7 still checks it), and E1 measures the real floor
  (below).

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

**Shared fixtures (r3.6).** `agent-hierarchy/tests/fixtures/status/` holds
status **documents only**. Each consumer adds its own expected-output
vectors next to its own tests (§6.6 for the mod, §7.6 for claude-tui-line).

- One `<case>.json` per case: `idle` (live members, nothing out), `work`
  (one dispatch whose timeline runs working → overdue → stalled), `warn` (a
  blocked member), `bad` (overdue and stalled dispatches), `hidden`
  (disabled config, every entry `visible:false`), `pipeline` (an open run
  with items and a parked decision), and `member-session` (a non-empty
  `member_sessions`).
- Each is the exact output of `roster.mjs status --now <fixed ISO>` against
  a pool staged by a test script. A bash drift test regenerates every case
  and fails unless each is byte-identical to the committed file.
- Fixtures contain no absolute paths, real session ids or real names.
- `docs/status-file.md` lists the cases and what each shows.

### 3.6 Cost per read

- A consumer's read is one `stat` plus a read of a file that is usually
  under 8 KB, plus a JSON parse. It never spawns anything.
- The producer's cost per write is E1. Target on the live `agent-tools`
  pool (r3.10): warm p95 ≤ 15 ms (our code) and cold p95 ≤ 20 ms (our code
  plus the per-process warm-up every short-lived hook pays anyway, about
  5 ms in E1). r2's single 15 ms figure did not separate the two.
- r3.10, the first E1 run (cold 22.4 / warm 17.3 ms) was over because of
  waste, not inherent cost. Each write listed the exchanges twice (once
  more inside `openRunAnchor`) and re-read the 609 KB dispatch-row file
  once per dispatch. Three levers remove it (step 6b):
  1. The dispatch-origin function (§3.1) reads the rows once per call and
     answers for a set of request ids. The Stop hook and lib-status each
     call it once per run with all their ids.
  2. `openRunAnchor` accepts an optional, already-computed exchange list
     and uses it instead of listing again. Its logic is unchanged and
     still the one definition (§4.2.1). lib-status passes its list.
  3. The §3.7.1 4 KB pre-check.
- Write coalescing (r2's remedy) is **dropped**. Hooks are short-lived, so
  there is no process to make the "trailing write", and skipping a write
  would lose the final state (a Stop's report hidden behind a UserPromptSubmit
  written 0.5 s earlier). It trades correctness for latency.

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
- Size pre-check (r3.10: required, since E1 measured `listExchanges` p95 at
  5.8 ms): a member-addressed response file over 4 KB is treated as closed
  from its `stat` size alone, without reading it. Ceiling (`ponytail:`
  comment): a body over 4 KB made only of skeleton lines would read closed;
  nobody writes 4 KB of `- none`. `reportStatus` itself (deliver's use) has
  no pre-check.

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
| `merge-check`: `<tag>-i<N>-ok` must be closed, else `not-signed-off` | any response signs off | a skeleton-only `-ok` response (addressed to the Architect) no longer signs off (changes). The pipeline's intended path has the Architect fill it, so a real sign-off is unaffected. r3.4: an `-ok` addressed to the Orchestrator never signs off, whatever its response holds (§3.7.9). |
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

**3.7.4 Stop-hook changes.** Exactly three (the third added in r3.3).

1. **Cadence.** The second nudge for a request is due `T/2` after the first,
   instead of `T` after it. All later nudges stay `T` after the previous
   one. The trailing sentence "You will be asked again … after another eta
   interval" becomes: after half an eta interval the first time, then every
   eta interval.
2. **Pane wording.** If the item's member is `route: pane` (looked up in the
   team file by `to_name`, then by role), its line must not say
   ListAgents/SendMessage. Instead it tells the Orchestrator to check the
   member with
   `roster.mjs deliver <name> --req <path> --wait-only --timeout 10 --cwd <abs>`
   (r3.5: the command is meant to be pasted, so the script path, `<path>`
   and `<abs>` are double-quoted in it),
   and to act on the returned `status` as agent-team `SKILL.md`
   §"Dispatching to a `route: pane` member" prescribes:
   - `blocked` → relay through AskUserQuestion and `answer`;
   - `not-live` → surface it to the user;
   - `busy` or `timeout` → it is still working;
   - (r3.6) `no-report` → the member is idle with no report: re-deliver
     the brief or ping it;
   - (r3.6) `not-sent` → the brief never arrived: send it with `deliver`;
   - (r3.6) any other status → act as the returned `message` says.

   Before writing this line, the Implementor confirms by reading `deliver`
   that `--wait-only` sends nothing to the member. If it does send
   something, stop and report a spec gap.

3. **Clock origin.** A dispatch's age, the "too young to flag" test and the
   first check-in are measured from its origin (§3.1), not from the request
   file's `created` (today `exchangeAgeSec`, lib-hier.mjs:558). So the
   reason text's "sent {age} ago" becomes true. Which dispatches qualify is
   unchanged: an open exchange with a dispatch row from **this** session.
   If the Stop hook was `exchangeAgeSec`'s last caller, delete it.

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

r3.5, the clock origin (§3.1, §3.7.4 item 3): existing liveness tests build
"a dispatch older than `T`" by backdating the request file's `created` while
writing the dispatch row at now. Under the origin rule that dispatch is 0 s
old. Their intent is the dispatch's age, so the fix is in the fixture: write
the dispatch row at the same backdated instant as the request
(`test-orchestrator-liveness.sh` `mark_dispatch`, `:81-83`;
`test-sendmessage-response-nudge.sh` `dispatch_record`, `:320`). No assertion
changes. The new behaviour, an old request with a fresh row not nudged, is
AC 26's job, not theirs.

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

**3.7.9 merge-check counts only a member-addressed `-ok` (r3.4).** Under
§3.7.1 an `-ok` request addressed to the Orchestrator closes on a bodyless
response, so `merge-check` (pretooluse-push-guard.mjs:781) would accept a
sign-off nobody wrote. That contradicts §3.7.6's "a skeleton `-ok` is not a
sign-off". The rule:

- `not-signed-off` is reported unless the pool has a **closed,
  member-addressed** (`to` ≠ `orchestrator`, the same predicate as §3.7.1)
  exchange with slug `<tag>-i<N>-ok`. An orchestrator-addressed `-ok` never
  counts, whether its response is empty or filled: the Orchestrator writing
  to itself is not an Architect sign-off.
- Nothing else in the push guard changes. `merge-check` is the advisory verb
  (:746-749, :893); the PreToolUse enforcement path, `pinnedMerge`, never
  reads `-ok` and stays untouched. That is why §5's push-guard freeze yields
  for this one condition: the contradiction lives only in that test, and
  leaving it would leave the skill's rule unenforced in the one place that
  checks it.
- This is a tightening against 0.109.0, where any response to any `-ok`
  passed. It is a process check, not authentication: an Orchestrator that
  fills an Architect-addressed `-ok` itself still passes, as before.
- Tests: `test-pipeline-merge.sh`'s `-ok` cases that use `record …-ok;
  close_record` (:380 `item_run`, :408) become Architect-addressed requests
  with a filled response. That changes the fixture's address, not an
  assertion, and §3.7.7 allows it for this case. Add the negative case
  (AC 27).

## 4. State model (exact rules)

`T` is the dispatch's eta threshold from the shared table.

### 4.1 Members

The document's `teams` list holds exactly the **live** teams in the pool,
and the member set is every member of those teams. Team liveness is
`teamIsLive(t, null)` (§3.1). The orchestrator is excluded. The default
team (`<hier>/team.json`) has `team: null`, the same value an untagged
request maps to (r3.6); consumers display a null team as `default`.

**r3.13, the one predicate.** "Pane-driven" means a member that `ah`
reaches through its pane (`deliver`/`answer`), with its activity in
`pane-<name>.json`.

- The predicate is pretooluse-route-gate.mjs's existing `isPaneMember`:
  `resolveKind(m) !== KIND_DEFAULT && m.route === "pane"`.
- It moves, unchanged, into `hooks/lib-config.mjs` beside `resolveKind`,
  `KIND_DEFAULT` and `routeHasPane`, and is exported. The route gate
  imports it. It has exactly one definition.
- Every site that decides "pane-driven" uses it, not `route` alone.
- A `kind: claude` member with `route: pane` is valid (lib-roster.mjs only
  forces non-Claude kinds onto `pane`). It is **not** pane-driven:
  - it is spawned with the same `claude --agent ah:<role>` command as a
    peer;
  - `deliver` refuses Claude kinds;
  - the route gate already treats it as a Claude session.
- "Has a pane" (layout, spawn, `transport_id`) is a different question
  and stays on `routeHasPane`. A claude+pane member does have a pane.
- Rejected alternative: forbidding claude+pane in the validator. That
  would change `add`/`spawn-ad-hoc` behaviour and need a migration for
  existing team files, for no gain.

`live`:

- Claude (every member that is not pane-driven, whatever its `route`):
  the existing `recordLiveness` result for the member's attributed peers
  row. With no attributed row, `false`.
  - r3.13, attribution needs nothing new. A claude+pane session's
    SessionStart writes its `up` row (`session_id`; `pane_id` from
    `HERDR_PANE_ID`; `role` from `--agent`).
  - `attributedRoster` names it by matching `pane_id` to the member's
    `transport_id` plus its role, exactly as for a peer in a pane.
  - So it gets `session_id`, `activity` from `<session_id>.json`, and a
    place in `member_sessions`.
  - Ceiling: one started by hand without `--agent ah:<role>` writes no
    row. It is not attributed and shows the view, the same limit as for
    any Claude member.
- Pane-driven (the predicate): `false` if its activity record says
  `unknown` because `deliver` saw `agent_not_found`. `true` if it has any
  other activity record. `null` if it has none.

`activity`: from the member's activity record; `unknown` if there is none.
A member with `live === false` shows `activity` as recorded, but consumers
draw it as **gone**.

`label`: the member's `role` if no other live member of that team shares
it; otherwise its `name`.

### 4.2 Dispatches

**Set.**

- Every **member-addressed** request in the pool (filename `to` ≠
  `orchestrator`, §3.7.1) that **has a dispatch origin** (§3.1) and is
  open, plus every such request reported within the last **10 min**
  (reported_at + 600 s > written_at). r3.3: a request written but not yet
  sent is not out. A subagent dispatch never gets a dispatch row, so it is
  not shown either; that matches the Stop hook.
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
  oldest `sent_at`.
- Cap the list at 50 per team, and put the remainder in
  `dispatches_truncated`.

**Report present.** This is `!open` under the §3.7.1 rule. It is the same
rule every exchange consumer uses as of r2. `reported_at` is the response
file's mtime.

**Member.** Look up `to_name` among the team's members. Failing that, use
the single member whose `role == to`. Failing that, `null`.

**`label`.** The member's `label` (§4.1). With no member, `to_name`, else
`to` (r3.6).

**`states`** (the first rule that matches decides the whole list):

| # | Condition at write time | `states` |
|---|---|---|
| 1 | reported | `[{written_at, reported}, {reported_at+600s, expired}]` |
| 2 | member exists and `live === false` | `[{written_at, stalled, reason:"member-gone"}]` |
| 3 | member's `activity == blocked` | `[{written_at, blocked}]` |
| 4 | otherwise | `[{sent_at, working}, {sent_at+T, overdue}, {sent_at+1.5T, stalled, reason:"no-report"}]` |

- Rule 4's cut points are the first and second check-ins of the shared
  cadence table (§3.1), applied to `sent_at` (the origin). That is spec 0028 §5.7.2
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
  re-derive anchors. lib-status passes it the exchange list it has already
  computed (§3.6 lever 2), so a write lists exchanges once.
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
   - r3.12: 256 KB means 262,144 bytes. A file whose size is greater than
     that is absent; one of exactly 262,144 bytes is read. The size is
     checked before parsing.
   - r3.12, malformed shape: the doc is also absent when a field the
     consumer reads is missing, has the wrong JSON type, or, for a
     timestamp, does not parse as an ISO-8601 instant. The fields are:
     - `expires_at`;
     - `member_sessions` (an array of strings);
     - `timeline` (a non-empty array, with every entry's `at`
       parseable);
     - in the picked entry: `visible` (a boolean), `tone`, `text` and
       `short` (strings).

     A missing `member_sessions` is therefore absent, not empty, so a
     malformed doc fails toward showing nothing. A consumer does not
     check fields it does not read, and it ignores unknown fields.
   - r3.28, **unreadable** means the path is not a non-empty regular
     file: it is itself a symbolic link (even one that leads to a regular
     file), a directory, a FIFO, a socket or a device, or its size is 0;
     or opening or reading it fails. The check uses a stat that does not
     follow a final symbolic link and is made **before the file is
     opened**; a path that fails it is never opened, because opening a
     FIFO blocks and a link can lead to a terminal. A consumer that holds
     an open handle may check the handle instead (claude-tui-line also
     requires it to be seekable). Only the final path component is
     checked; a symlinked parent directory is followed. §13 names every
     site.
   - r3.28, `schema` is the JSON integer `1`, and `ah` only ever writes
     that spelling. A consumer that sees the number's text treats `1.0`,
     `1e0` and every other spelling as `schema ≠ 1` (claude-tui-line
     does). A JavaScript consumer cannot tell them apart, since
     `JSON.parse` yields the same number, so it accepts them. The two
     disagree only on a hand-made file, and neither runs anything from
     the file, so the gap is accepted, not closed.
2. Pick the entry that is current at `now`: the last element with
   `at ≤ now`. If `now` is before the first element, use the first.
3. Render nothing if the entry has `visible: false`, or if the viewing
   session's id is in `member_sessions`. The second condition gives the
   Orchestrator-only view (user decision Q3).
   - r3.12: precisely, the view is hidden in **member sessions** and shown
     in every other session in the checkout: the Orchestrator's, plain
     sessions, and `--agent` sessions on no team. `ah` has no record of
     which session is "the Orchestrator", and the doc does not name one.
     `member_sessions` is the only signal.
   - Consumers must not add a heuristic of their own, such as hiding on
     the session's agent name. That would also hide an Orchestrator
     launched with `--agent ah:orchestrator`, and it re-derives
     membership.
4. r3.12, enumerated values are open under `schema: 1`. A producer may
   add a value with a doc update. A consumer falls back and never rejects:
   an unknown `tone` string renders in the `idle` colour. A `tone` that is
   not a string is malformed (step 1).

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
- `pretooluse-push-guard.mjs` code, except the one `merge-check` sign-off
  condition in §3.7.9 (r3.4). Otherwise its behaviour changes only through
  `listExchanges`, and only for `-ok` (§3.7.2).
- The open/closed state of every orchestrator-addressed exchange, which
  includes every pipeline run record and so every anchor-liveness answer.
- The Stop-hook liveness nudge, except for the three changes in §3.7.4: its
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
  mod/view.ts                  pure: (doc, nowMs, sessionId, columns, status_entry option)
                               → view model (§6.4–6.5); no $ calls, so it is testable directly
  mod/types/index.d.ts         PluginState contract for every $.state value the module uses
  mod/tests/*.test.ts          §6.6
  mod/tests/fixtures.ts        generated: the §3.5 fixture files embedded (§6.6, E13)
  mod/tests/vectors.ts         hand-written expected outputs per fixture case (§6.6)
```

- r3.11 (E12): the `userConfig` entry has exactly the shape E12 validated:
  `"status_entry": {"type": "boolean", "title": …, "description": …,
  "default": true}`. Suggested description: show the hierarchy line
  (`⚠ ah: …`) above the prompt, and turn it off when claude-tui-line's
  `ah` item already shows it.
- r3.14: a `--plugin-dir` load makes the engine write two files into the
  plugin: `agent-hierarchy/tsconfig.json` (`{"extends":
  "./.claude-plugin/types/tsconfig.json"}`) and
  `agent-hierarchy/.claude-plugin/types/` (the client's API types).
  - Both are client-version-specific output, so they are git-ignored and
    never committed. Rewriting them on each client would churn the repo.
  - The rules go in a new `agent-hierarchy/.gitignore`, anchored to the
    plugin root: `/tsconfig.json` and `/.claude-plugin/types/`. They
    travel with the plugin, and they cannot match
    `mod/types/index.d.ts`, the authored `types` contract, which stays
    tracked. No bare `types/` pattern.
- r3.11: mod code is built and tested only in the worktree, through
  `claude plugin test` and `--plugin-dir`. It is never copied into
  `~/.claude/dev-mods/`, because that hot-loads it into the user's live
  sessions and prompts the user.

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
3. Resolve the path again when `cwd` changes. r3.15: each tick reads
   `$.session.cwd()` and re-walks only when it differs. There is no
   `classic.CwdChanged` hook, because classic events are not on the
   allow-list (§6.3).
4. With no `.git` anywhere up the tree, there is no file.

r3.12: this is exactly the rule `ah`'s writer uses (`hierarchyDir` →
`findGitRoot` in `hooks/lib-config.mjs`). In a linked worktree, both find
the worktree's own `.git` **file**, so a worktree is its own pool and its
`status.json` is `<worktree>/.claude/hierarchy/status.json`. A worktree
with no pool has no file, and the reader shows nothing. The writer never
falls back to the main checkout.

Ceiling (`ponytail:` comment): this ignores `AGENT_HIERARCHY_DIR` and `ah`'s
non-git fallback dir. claude-tui-line uses the same rule (§7.2).

### 6.3 Events

| Event | Behaviour |
|---|---|
| `session.start` | Register command `hierarchy-pane`. Start `$.clock.every(2000, tick)` and run one tick at once. Return `next(e)`. |
| tick | 1. `stat` the file. 2. Re-read and parse it only if `mtimeMs` changed. r3.11: a file over 256 KB (§7.2's cap) is not read, and it, an unreadable file and unparseable text all count as no doc. r3.28: the stat's `isLink` true, a `kind` other than `file`, or a `size` of 0 also count as no doc, and the file is then not read (§13.2). 3. Build the view model with `$.clock.now()`. 4. Update state only if the view model changed. 5. Call `$.ui.status(...)` (§6.4). r3.18, P2b: the "state" in step 4 is the tick closure's last text, and `$.state` is not used until P3's readers need it. Step 5 runs only when the text changed, except that the first tick after `session.start` always calls `$.ui.status`, to set or clear the entry, so an entry left by a module before a reload never stays stale. 6. Raise the toasts (§6.5). 7. Auto-open the Pane (below). |
| `command.run` `{command:'hierarchy-pane'}` | `$.ui.open({id:'ah-status', title:'Hierarchy'})`, which places at any width. Clears the "closed by person" flag. Returns `{text}`. |
| `ui.render` `{component:'Pane', requestId:'ah-status'}` | Draws §6.4 Pane at `e.props.bodyColumns`. |
| `ui.render` `{component:'AbovePrompt'}` | Returns `next(e)` when `e.props.hasSurvey`, or when there is no band. Otherwise draws one line (§6.4). r3.20: the line is drawn above what `next(e)` answers, never in its place (§6.7). |
| `ui.close` on `ah-status` with origin `person` | Sets "closed by person" in `$.state`. No auto-reopen this session. r3.15: `ui.close` is an op event, so the handler always returns `next(e)`. |

**Auto-open:** at most once per session, when a visible doc is first seen in
a non-member session that the person has not closed. Call `$.ui.open`
unasked: it seats at ≥144 columns and waits below that. The "opened" and
"closed" flags live in `$.state`, so a reload does not reopen the Pane.

**Read-only rule:** the module calls no `$.process`, no `$.fs.write`, no
`$.session.send`, no `$.tool`, no `$.agent` and no `$.model`. A test asserts
this (§6.6).

**r3.15: the rule is now an allow-list, with nothing else permitted.**

The six-noun deny-list missed most ways to act. A module acts in two ways,
and both are closed:

- through a `$` call;
- through the value a hook returns. For example, `classic.PermissionRequest`
  returning `{behavior:'allow'}` or `PreToolUse` returning `allow:true`
  answers a prompt, and so does a `tool.check` decision. Hooking an op
  event intercepts other plugins' calls.

The source is the 2.1.289 types file:
`/private/tmp/claude-501/bundled-skills/2.1.289/<hash>/plugin-authoring/types/claude-code.d.ts`.
`$` is the first parameter of every hook (≈:4333, :4642), and each
`$.<noun>.<method>` is also a hookable op event (:6522).

1. **Allowed `$` calls.** No other `$` member may be called. Each entry
   gives its line in the types file and who needs it:

   | Call | Types | Needed by |
   |---|---|---|
   | `$.session.cwd()` | :2673 | §6.2 locating; it is read on every tick, so there is no cwd-change hook |
   | `$.session.id()` | :2694 | the member-session rule |
   | `$.fs.stat()`, `$.fs.read()`, `$.fs.exists()` | :3219, :3140, :3166 | §6.2–6.3 |
   | `$.clock.every()`, `$.clock.now()` | :3362, :3331 | §6.3 |
   | `$.state.get()`, `$.state.set()` | :3298, :3314 | flags and the toast seen-set, the module's own session state (§6.3, §6.5) |
   | `$.ui.status()` | :2375 | P2b |
   | `$.ui.toast()`, `$.ui.open()`, `$.ui.resolve()` | :2363, :2398, :2314 | P3 |
   | `$.command.register()` | :2989 | P3 `/hierarchy-pane`; registers its own command and sends nothing |

   Everything else is out. Notable exclusions:
   - `session.authorize`, `.append`, `.send`, `.compact`;
   - `prompt.*` writes, `turn.abort`, `tool.*`, `agent.*`, `model.*`;
   - `mcp.*`, `http.fetch`, `process.*`, `env.set`;
   - `config.set`, `command.run`, `telemetry.*`;
   - `fs.write`;
   - `store.*`, which is a persistent file under the user's config and
     is not needed, because §6.5 uses `$.state`;
   - `ui.ask`, `ui.copy`, `ui.log`, `audio.*`.

   `process.run` is excluded even for a read-only argv such as
   `herdr agent get`. The guard cannot check an argv, and the doc already
   carries pane activity (§3.3).
2. **Allowed hook registrations, and what each may return.** No classic
   event, no wildcard or negated pattern, and no other op event may be
   registered. r3.16: a return value can act as surely as a `$` call, so
   each registration also fixes its matcher (the second argument to `on`,
   :6470) and its return. "Exactly" means the object literal as written,
   no other keys:

   | Registration | Matcher | May return | Never returns | Types |
   |---|---|---|---|---|
   | `session.start` | none | `next(e)` | its own value | `SessionStartResult` :11145; its own value is ignored anyway (:11143) |
   | `ui.close` (op event) | r3.20: exactly `{ id: 'ah-status' }` | `next(e)`, after noting the "closed by person" flag (§6.3) | `{deny}`, `{value}` | `ValueOrDeny` :13925; `OpValueOf['ui.close']` is `void` (:6927) |
   | P3 `command.run` | exactly `{ command: 'hierarchy-pane' }` | `{ text }` and no other key | `context`, `exitCode`, or a value from `next` | `CommandRunResult` :1755 |
   | P3 `ui.render` | exactly `{ component: 'Pane', requestId: 'ah-status' }`, or exactly `{ component: 'AbovePrompt' }` | `next(e)`, or a tree whose every node is `Box` or `Text`. r3.19: also the `engine` element that `next(e)` answers, which is core drawing its own component with its own props (:9165) | any other element type; any node with a `press`, `client` or `raster` key | `RenderElement` :8851 |

   - `command.run`'s `context` is the send: each entry is "one hidden
     user message recorded after the output row" (:1762). `exitCode`
     sets a headless run's exit status (:1771). Neither is needed.
   - `command.run` is the event the module answers; the `$.command.run`
     call stays banned. With the matcher, no other command reaches the
     hook, so the module never answers another command.
   - `ui.render` is held to `Box` and `Text`, because the other element
     types take input (`Button`, `Input`, `Select`, pressable
     `Markdown`), open things (`Link`) or run plugin code (`Client`,
     `Raster`). The band and the Pane (§6.4) are lines of text. If P3
     needs another element type, that is a spec question, not an
     Implementor call.
3. **No indirection.**
   - The `$` identifier appears only as a hook-handler parameter (`($, e,
     next)`, `($: EngineInterface, …)`) or directly followed by
     `.<noun>.<method>`.
   - Banned: passing `$` as an argument, assigning or destructuring it,
     `$[…]`, and stopping at `$.<noun>` without a method.
   - `globalThis`, `eval`, `Function(`, `Reflect` and `Proxy` are banned
     in module source.
   - `view.ts` contains no `$` at all (it is pure, §6.1).
   - `on` is used only as `on('<literal>', …)` calls on `register`'s
     parameter. r3.17, to be exact: the identifier `on` appears in
     exactly two places, as `register`'s first parameter and as the
     callee of `on('<event>', …)`. Anywhere else is a violation, as an
     argument (`extra(on)`, `f(x, on)`) included.
   - Template `${…}` is not a `$` identifier. r3.18: a `$` inside a
     regex literal does count. Write an end-of-input check another way,
     for example a start-anchored match whose length equals the input's.

   r3.16: those rules held only for the name `$`, so renaming the
   environment hid it from the lexer. The step-1c review found seven such
   bypasses, and only validate caught them. The environment must now be
   reachable under no other name:
   - `register`'s first parameter is named `on`. Its second, if present,
     is the userConfig `options` (§6.4).
   - Every hook given to `on(…)` is an inline arrow or function literal,
     never a name. Its first parameter is exactly `$`, or it declares no
     parameters. A destructuring pattern there is banned.
   - A function given as an argument to a `$` call (the `$.clock.every`
     callback, for one) declares no parameters, so the engine cannot hand
     it an environment under another name. The tick is therefore a
     closure inside the `session.start` hook.
   - `arguments` and `this` join the banned tokens.
   - No `\u` escape anywhere in module source: not in identifiers,
     strings, templates or regexes. Write the character itself, or `\x..`
     (C0, DEL and C1 all fit, so §6.4's stripping regex needs no `\u`).
     This closes a `\u`-escaped `$` (code 0024), a `\u`-escaped `o` in
     `on` (006f), and a `\u`-escaped `t` in `'tool.check'` (0074) used as
     an event name. Event names and matchers are compared as written.
     (r3.17: r3.16's text for these three cases, and for the matching
     planted cases in §6.6, lost its escapes when it was written, so it
     read as `$`, `on` and `'tool.check'`. The cases mean the escaped
     forms. The spec now describes them in words.)
4. **Return values, statically** (r3.16). The lexer also enforces item
   2's table where source shows it:
   - `on('command.run', …)` and `on('ui.render', …)` carry one of the
     exact matchers in item 2;
   - `context`, `exitCode`, `press`, `client` and `raster` do not appear
     as an identifier or property key;
   - no JSX tag and no string literal names an element type other than
     `Box` or `Text`. The guard holds the full list of `RenderElement`
     type names (:8851), next to the other lists.

   r3.17, one rule in place of the two above: there is one list of
   **banned words**, checked by token, whatever the token's role:
   - the tokens checked are every identifier, property name, JSX tag,
     string literal, and template literal without `${…}`;
   - a token fails when it equals a banned word;
   - the banned words are the return keys `context`, `exitCode`,
     `press`, `client` and `raster`, and every `RenderElement` type name
     other than `Box` and `Text` (`Button`, `Input`, `Select`, `Link`,
     `Code`, `Markdown`, `Client`, `Svg`, `Raster`, `Image`, and any
     other name at :8851).
   - r3.19: `deny` is a banned word, because an op-event hook (`ui.close`)
     returning `{deny}` refuses the person's close. `engine` is not a
     banned word: it is core's own drawing, carried from `next(e)`
     (item 2), and the guard's element list records it as allowed.

   So `h(els.Link, …)`, `const { Button } = $.ui.resolve(e)`, `'Link'`
   and a substitution-free template `` `context` `` all fail. A status
   mod has no use for these words as names.
5. **Imports** (r3.17). The scanned module is `register.tsx` and
   `view.ts`: all of `mod/` except `types/` and `tests/`. No code
   outside the scan may run in the module:
   - `register.tsx` imports values only from `./view`;
   - `view.ts` imports no values;
   - anything else is `import type`, from `'claude-code'` or
     `./types/`;
   - nothing in the module imports from `./tests/`.

   JSX needs no import: `h` and `Fragment` are globals of the module's
   environment (types :16-24). `import()` and `require` need no rule
   either. The engine does not load a module holding `import()`, and
   there is no `require` (:22-24).
6. **The guard's stopping point and ceiling** (r3.17; replaces r3.16's
   item 5).

   **Why the rules are complete.** A hooks module runs "in an
   environment of its own, with no DOM and no Node: everything outside
   it is reached through `$`" (plugin-authoring `reference.md`:23). Its
   globals are a fixed list, "these and no others" (types :13988), with
   no `fetch`, no timers, no `console`, no `eval`/`new Function`
   (they throw) and no `WebAssembly`. So the module can act, send or
   answer in only two ways:
   - through a `$` call, closed by items 1 and 3: `$` and `on` stay at
     their names and positions;
   - through a hook's return, closed by items 2 and 4: each
     registration's matcher and return are fixed, and the banned words
     are kept out.

   Item 5 keeps all module code inside the scan.

   **What the guard does not cover.** The lexer cannot see names or
   values computed at run time:
   - a key or element name assembled from pieces (`'con' + 'text'`, or
     a template with `${…}`);
   - a value carried through from `next` (a spread of `next(e)`);
   - r3.19: an op-event hook that answers `{ value }` itself instead of
     calling `next`, which would also refuse the close. `value` is too
     common a word to ban, so the P3 `ui.close` behaviour test covers
     it.

   The behaviour tests (§6.6) catch these on every path the fixtures
   exercise, the validate subsets catch registrations and calls, and
   review covers the rest. The threat is an ordinary edit that acts by
   accident. It is not a hostile author, who could edit the guard
   itself.

   **What a later review may raise.** After step 1e, a guard finding
   is a defect only if it is one of these:
   - (a) an ordinary form that a maintainer could write without
     meaning to evade, which acts, sends or answers, uses no computed
     name, and passes the lexer;
   - (b) legitimate code the guard rejects (as F2 was);
   - (c) the test not matching items 1–5 or §6.6.

   Anything else is inside the ceiling. It is recorded in the review
   and adds no rule. A new rule must close a class, not one instance.
   The class is named in the rule, as items 3–5 do.

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
- r3.11: control characters (C0, DEL and C1) are stripped from every
  string taken from the file before it is displayed. The producer strips
  them too, but a hostile committed file can skip the producer (§12).
- Toggle (user decision Q2; E10 showed both lines render): userConfig
  `status_entry` (boolean, default `true`) in ah's plugin.json. `false`
  keeps the entry cleared. A user who places claude-tui-line's `ah` item
  turns this off to see the counts once.
- r3.11, how the toggle is read (E12):
  - The module reads the option from `register`'s second argument,
    `options`, which arrives with defaults filled in. A change to it
    reloads the plugin and runs `register` again. So the module keeps no
    copy of it in `$.state`, and it does not poll.
  - Only the value `false` turns the entry off. A missing `options` or a
    missing key counts as on, which covers a test harness that passes no
    options.
  - The toggle is an input to view.ts (§6.1). The status-entry part of the
    view model is empty when the toggle is off. That keeps the toggle
    testable without the harness (§6.6). It does not affect the band, the
    Pane or the toasts.
  - Scope: a stored value counts only from user settings (`/config`,
    `claude plugin configure`) or `--settings`. A project or local
    settings file cannot set it, so the toggle is per user, not per
    project.
  - A fresh install prints one informational line ("1 userConfig option
    not yet set …"); the default still applies. An upgrade prints nothing.
    The README says both (§8 P2b step 4).

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
   `elapsed = now − sent_at` and `pct = min(100, elapsed/eta_ms)`. Every
   `{m:ss}` and `{over}` in §6.4 is measured from `sent_at`. Recent `reported` rows stay until they
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
| dispatch `reported` | `reported:{id}` | `{label} reported · {slug} · {reported_at−sent_at as 6m 40s}` |
| member `blocked` | `blocked:{name}:{activity_at}` | `{label} blocked · {blocked_note}` when it is set (pane members); else `{label} blocked · waiting for permission` when `blocked_by == "permission"` (Claude members, E3); else `{label} blocked · waiting on a prompt` |
| dispatch `stalled` | `stalled:{id}` | `{label} stalled · {slug} · {checkin phrase from §6.4 \| {name} is gone}` |

- **Dedupe.**
  - A key toasts at most once per session.
  - The seen set lives in `$.state`, so it survives reloads.
  - Prune keys whose subject is no longer in the doc.
- **Seeding.** On the first tick whose `view` is non-null (§6.7) while
  the seen set has never been written, add every current key **without
  toasting**. r3.26: a tick with a `null` view neither seeds nor prunes
  (§6.7). An early empty seed would make the first real doc replay as
  toasts. A new session does
  not replay old events, and neither does a mod first loaded mid-session.
- **Where.** Toasts only in non-member sessions (Q3). No chime: the mockup's
  "could join" is not taken (YAGNI).

### 6.6 Tests (`claude plugin test <mod>`)

**view.ts: shared vectors.** For each fixture in
`agent-hierarchy/tests/fixtures/status/`, the vector file gives
`(now, sessionId, columns) → statusText, band text and tone, pane rows,
toast keys`.

r3.11 (E13: `claude plugin test` loads only code files, so no test can
import a `.json` file):

- **`<mod>/tests/fixtures.ts`** is generated and never edited by hand.
  - It exports one mapping from case name (the fixture's basename without
    `.json`) to that file's exact text, byte for byte. Its cases are
    exactly the `.json` files in the fixture directory.
  - Its first line says it is generated and names the command that
    regenerates it.
  - The command that regenerates the §3.5 fixture files also regenerates
    this module, so one command refreshes both. If no such command exists
    yet, add one small generator under `agent-hierarchy/tests/` and use it
    for both.
- **Drift test.** A test in `ah`'s bash suite fails unless `fixtures.ts`
  is byte-identical to a fresh generation from the committed fixture
  files. This covers a changed case, an added case and a removed case. A
  one-byte edit made in a temp copy, never committed, shows once that the
  test can fail.
- **`<mod>/tests/vectors.ts`** holds the expected outputs, keyed by case
  name. It is TypeScript for the same reason. A test fails if a fixture
  case has no vector, or if a vector names a case that does not exist. So
  a new fixture case cannot go untested.
- Tests parse `fixtures[case]` for view.ts. For register.tsx they answer
  `fs.read` with the text and `fs.stat` with `size` = its UTF-8 byte
  length.
- P2b fills in `statusText` only. P3 adds the band, the pane rows and the
  toast keys to the same file.

**view.ts: edge cases.**

- missing doc, `schema: 2`, expired doc, `visible: false`;
- r3.11: unparseable text, a file over 256 KB, and a string holding an
  ESC sequence, which displays with the control characters gone (these
  use inline docs, not shared fixtures);
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

r3.15: this deny-list is replaced by §6.3's allow-list.

- `tests/test-mod-readonly.sh` holds the **one** copy of the allowed
  `$` calls and events. It scans all module source under `mod/`, except
  `tests/` and `types/`, and fails on:
  - any `$` call that is not in the list;
  - any `$` occurrence that §6.3 item 3 bans;
  - any `on(` registration whose first argument is not an allowed string
    literal;
  - any banned indirection token.
- **Second net, dynamic:** `claude plugin validate agent-hierarchy` prints
  the module's registered hooks (`hooks: …`), and the test asserts they
  are a subset of the allowed events. If validate also prints a `calls:`
  set, assert that it is a subset of the allowed calls too.
  r3.17: validate prints a registration with a matcher as
  `event{k=v,…}`, for example `ui.render{component=AbovePrompt}`. The
  net parses that form:
  - `event` must be an allowed event;
  - the matcher, as sorted `k=v` pairs, must equal one of that event's
    exact matchers (§6.3 item 2), in the same canonical form the lexer
    builds;
  - `command.run` or `ui.render` printed with no matcher fails.

  This is the net's own matcher check. Without it, the real P3 module,
  which must use matchers, fails the guard.
- **Planted cases**, in a scratch copy, never committed. Each one must
  fail the guard:
  - the reviewer's eight: `$.session.authorize()`, `$.session.append()`,
    `$.prompt.fill()`, `$.turn.abort()`, `$.mcp.call()`,
    `$.command.run()`, `$.config.set()`, `$.http.fetch()`;
  - `$.store.set()`, `$.ui.copy()`, `$.process.run(['herdr','agent','get'])`;
  - the aliases `const { session } = $`, `const s = $.session`,
    `$['session']` and `f($)`;
  - `globalThis`;
  - the registrations `on('classic.PermissionRequest', …)`, `on('*', …)`,
    `on('tool.check', …)`, `on('fs.write', …)`, and `on(name, …)` with a
    non-literal name.

  The allowed forms must pass: `$.fs.read(p)`, `$.ui.status(t)`,
  `($, e, next) =>`, `` `${x}` ``, and the existing `tests/` exclusion.
- **r3.16 planted cases** (§6.3 items 3–4). Each must fail the **lexer
  layer alone**, and the run shows that per case. Validate is not
  counted for these. The same goes for the r3.15 cases above:
  - the step-1c review's bypasses:
    - `(env, e, next) => env.session.authorize()`;
    - `({ session }, e, next) => session.authorize()`;
    - a helper `(x) => x.prompt.fill()` called with a renamed hook
      parameter;
    - `register = r => { r('tool.check', …) }`;
    - `(env.session as any)[k]()`;
    - `env['session']['append']()`;
    - `const s = env.session; s.authorize()`;
    - `$.session.authorize()` with the `$` written as a `\u` escape
      (code 0024);
    - `on('tool.check', …)` with the `o` of `on` written as a `\u`
      escape (006f);
  - `on('tool.check', …)` with the `t` of the event name written as a
    `\u` escape (0074);
  - a named hook: `on('session.start', h)`;
  - `$.clock.every(2000, (env) => env.prompt.fill())`;
  - a `function ($, e, next) { arguments[0].prompt.fill() }` hook, and
    a hook that uses `this`;
  - `on('command.run', ($, e, next) => ({ text: 'ok' }))`, with no
    matcher;
  - the matched `command.run` returning `{ text: 'ok', context: ['x'] }`,
    and returning `{ text: 'ok', exitCode: 0 }`;
  - `on('ui.render', ($, e, next) => next(e))`, with no matcher;
  - the matched Pane `ui.render` returning a `<Link …>`, a `<Button …>`,
    and an object literal with `type: 'Link'`.

  r3.16 allowed forms must pass:
  - `export const register: Register = (on, options) => …`;
  - `on('command.run', { command: 'hierarchy-pane' }, ($, e, next) => ({ text: 'ok' }))`;
  - `on('ui.render', { component: 'Pane', requestId: 'ah-status' }, ($, e, next) => <Box><Text>x</Text></Box>)`;
  - `$.clock.every(2000, () => tick())`;
  - `/[\x00-\x1f\x7f-\x9f]/g`.
- **r3.17 planted cases.** Each must fail the lexer layer alone:
  - `extra(on)`, where `extra` registers `tool.check`;
  - the same helper placed in `mod/types/extra.ts` and imported as a
    value;
  - any import from `./tests/`;
  - `h(els.Link, …)` in a matched Pane `ui.render`;
  - `const { Button } = $.ui.resolve(e)`;
  - the review's b5: a computed key written as a substitution-free
    template literal whose text is `context`;
  - r3.19: a `ui.close` hook returning `{ deny: 'x' }`.

  Each `\u` case must actually contain the escape in the planted file.
  Check its bytes, because a runner that writes the decoded character
  plants the wrong case.

  r3.17 allowed forms, each also run through the **validate** net:
  - a register with both P3 `ui.render` matchers;
  - a register with the `command.run` matcher.

  These prove the matcher parse accepts legitimate code.
- **Behaviour (register tests).** These check returns at run time,
  including forms the lexer cannot see (§6.3 item 6):
  - step 3: `session.start` returns what `next` returned;
  - P3: the own-command `command.run` answer has exactly the key set
    `{text}`. r3.17: the test's `next` returns a value that carries
    `context` and `exitCode`, so a hook that spreads or returns `next`'s
    value fails;
  - P3: a `command.run` for another command is not answered;
  - P3: for every fixture case, each tree the Pane and band `ui.render`
    hooks return has only `Box` and `Text` nodes, and no node has a
    `press`, `client` or `raster` key;
  - P3: a `ui.render` for another component passes through;
  - P3: `ui.close` always returns what `next` returned. r3.19: `next` is
    called exactly once;
  - r3.19, P3: the tree walk above also accepts `engine` nodes, the
    ones that `next(e)` answers.

**Toggle.** With `status_entry` off, the entry stays cleared.

- r3.11: a view.ts test always covers this: off → empty entry; missing or
  `true` → the entry.
- Add a register.tsx test as well if E14(a) shows a test can pass
  `options` to `register`.

**Checks.** `claude plugin validate agent-hierarchy` is clean.

- r3.11: `tsc -p <mod>` is replaced by E14(b). `ah` has no node
  toolchain (no package.json, no `tsc`), and P2b adds none.
- **How the tests run** (E13's command line): `claude plugin test` on the
  plugin root, with `HOME` and `CLAUDE_CONFIG_DIR` pointed at a scratch
  dir, under a timeout. A test run then cannot touch the user's settings
  or `~/.claude/dev-mods/`.
- r3.16: the bash suite needs the `claude` CLI on PATH. The guard's
  validate net fails closed without it, which is correct. Step 4's
  README says so.
- **r3.18: the bash suite runs the mod tests.** A new
  `tests/test-mod-plugin-test.sh` runs `claude plugin test` on the
  plugin root. It uses the command line above: scratch `HOME` and
  `CLAUDE_CONFIG_DIR`, under a timeout (300 s).
  - It fails on a non-zero exit, on any failed test, on a timeout, and
    when `claude` is missing (fail closed, like the guard).
  - It leaves no process behind.

  Without it, AC 4's suite passed while `view.ts` and `register.tsx`
  were never run.
- **r3.18: suite scans skip engine output.** Any suite test that walks
  the plugin's files limits itself to `git ls-files --cached --others
  --exclude-standard`: tracked files plus untracked files that are not
  ignored. That includes test-ah-cli T7's "no `mcp__` reference
  outside docs/specs and tests". Engine output from a `--plugin-dir`
  load (`.claude-plugin/types/`, `tsconfig.json`, ignored since step 1b)
  is then never scanned, and a new file is scanned before it is
  committed. The Implementor checks the other suite tests that walk the
  tree and applies the same file set where one would match the
  generated files.

### 6.7 P3 design (r3.20)

This section settles how P3 builds §6.3–6.5. "F" is the 2.1.289 types file
(§6.3) and "R" is the plugin-authoring `reference.md` beside it.

**State.** The tick is the only writer of what P3 draws, and the render
hooks only read it.
- `mod/types/index.d.ts` declares four values under `PluginState.ah`:
  - `view`: the P3 view model (below). It is `null` whenever §4.4
    renders nothing: absent, expired, invisible, or a member session.
    `$.state` takes JSON and never `undefined` (F:3305).
  - `seen`: the toast keys already shown (§6.5). Never written means not
    yet seeded.
  - `opened`: auto-open has fired this session.
  - `closed`: the person closed the Pane this session. It is cleared by
    `/hierarchy-pane`.
- `$.state` is per session and survives a hot reload (F:3276). Module
  variables do not survive one (R:90), so nothing P3 draws from lives in
  the tick closure. P2b's closure text for the status entry stays,
  because it only gates the `$.ui.status` call.
- The tick writes `view` only when its JSON differs from the last
  written value (tick step 4). A write redraws every instance that read
  the value while drawing (F:3866, R:90). So the module never calls
  `$.ui.invalidate`, which stays off the allow-list.
- `$.state.set` is refused while a render hook draws (F:3303). Writes
  happen only in the tick, the `command.run` hook and the `ui.close`
  hook.
- E15(a) settles how a `StateRef` is written.

**View model, in two layers.** The width is known only while drawing
(`e.props.bodyColumns`), so view.ts splits in two. Both layers are pure
and contain no `$`.
- **Model:** `(doc, nowMs, sessionId) → view | null`. It holds nothing
  that depends on width:
  - the band subject and items, with their tones;
  - the Pane's sections as data;
  - the toast list as `(key, text)` pairs.

  Times (`m:ss`, `over`) are resolved at `nowMs`. So the model changes on
  every tick while work is out, and the band and Pane redraw at the 2 s
  tick rate.
- **Drawing:** `(view, columns) → band line and tone`, and
  `(view, columns) → Pane rows and tones`. These apply §6.4's cuts and
  width fallback.
- The status entry keeps its P2b function.

**Band (AbovePrompt).** The hook is on `{ component: 'AbovePrompt' }`.
- With `e.props.hasSurvey`, it returns `next(e)`: "a hook yields to it"
  (F:9712ff).
- When `view` is `null` or there is no band (§6.4), it returns `next(e)`.
- Otherwise it returns a column `Box`: the band line first, as one `Text`
  in the tone's colour cut to `e.props.bodyColumns`, then what `next(e)`
  answered. The line never replaces that answer. `next(e)` carries core's
  own drawing and other plugins' bands (the `engine` element, r3.19), and
  replacing it would hide them.
- AbovePrompt is raised on terminal and desktop only. A Pane is raised
  on every surface.

**Pane.** The hook is on `{ component: 'Pane', requestId: 'ah-status' }`.
- It reads `view` and draws §6.4's sections at `e.props.bodyColumns`.
- When `view` is `null`, it draws one dim line: `No hierarchy status
  here.`
- `Box` and `Text` come from `$.ui.resolve(e)` (F:2303); they are not
  globals.

**Tone colours.** A `Text` `color` is "a theme key or a raw color"
(F:12013). E15(b) lists the theme keys, the Implementor maps them by name
from that list, and the step report names the mapping:
- bad → the theme's error key;
- warn → its warning key;
- work → its in-progress or suggestion key if one exists, else no colour;
- idle and unknown tones → `dimColor`.

No raw colours, because they ignore the theme.

r3.21 (E15(b): the reference lists no theme keys, and the only key it
names is `warning`, at :8109). Use only documented props, and let bold
carry the difference between bad and warn. This table replaces the
mapping above:

| Tone | `Text` props |
|---|---|
| bad | `color: 'warning'`, `bold: true` |
| warn | `color: 'warning'` |
| work | none (the default text colour) |
| idle, and any unknown tone (§4.4 step 4) | `dimColor: true` |

- No undocumented key such as `error`, and no raw colour. Nothing
  documents how an unknown key draws, and a refused tree would lose the
  band.
- The words themselves carry the severity ("stalled", "past its eta",
  "waiting on a prompt"), so bad stays readable without colour.
- The band and every Pane row use this one table, held once in the
  module. The drawing layer returns tone names, and the table turns them
  into props.
- If a later client documents an error key, `bad` moves to it. That is a
  one-row change.

**Formats and ordering (r3.22).** The Implementor's mockup-derived
defaults G1–G17 (P3 step-2 report) are adopted as pinned, with one
addition (G3). These are what `vectors.ts` freezes.

| # | Item | Pinned |
|---|---|---|
| G1 | `{bar}` | 10 cells, `█` filled and `░` empty; filled = floor(pct / 10) |
| G2 | `{pct}` | elapsed / eta_ms × 100, floored, clamped to 0–100 |
| G3 | `eta {eta}` | `{T}m`, as in the band. Added: when `eta_ms` is not a positive number (the schema always sets it, but the file is untrusted, §12), the row shows `eta —` with no bar or pct, the band's working item drops ` of {T}m`, and nothing is ever `NaN` |
| G4 | `{m:ss}` | minutes unbounded, seconds two digits, floored; a negative elapsed is `0:00` |
| G5 | durations (`{over}`, the toast's reported_at − sent_at) | `{s}s` under a minute, else `{m}m {s}s`; minutes unbounded, no hours |
| G6 | `{age}` (now − activity_at) | `{s}s` under 60 s, `{m}m` under 60 m, else `{h}h`, floored |
| G7 | check-in phrase | `1 check-in unanswered`, `{n} check-ins unanswered` |
| G8 | Pane headings and empty states | heading rows `Hierarchy`, `Team`, `Dispatches`; `No pipeline run.` when no pipeline item is open; `None outstanding.` |
| G9 | several live teams | one Pane whose sections span all teams in doc order. With more than one live team, each heading carries ` {team ?? 'default'}` (`Team agent-tools`, and so on) |
| G10 | row tones | members: working → work, blocked → warn, idle, gone and unknown → idle. Dispatches: working → work, blocked → warn, overdue and stalled → bad, reported and unknown → idle. Headings → idle; pipeline lines → work; `N decisions waiting for you` → warn |
| G11 | band subject ties | dispatches: oldest `sent_at` first. Blocked members: oldest `activity_at`, then team doc order |
| G12 | `+{k} more` | k = the non-working items (stalled or overdue dispatches, blocked members) other than the subject. A dispatch in state `blocked` counts through its member, not again |
| G13 | band working list | working dispatches, oldest `sent_at` first. The first is the subject; each further one is appended only while the whole line fits `bodyColumns` uncut |
| G14 | dispatch rows | every dispatch whose state at now is not `expired`, newest `sent_at` first |
| G15 | "slugs and names are cut first" | after the width fallback, cut the slug (dispatch rows) or the name (member rows) with `…`, down to 8 characters, then cut the whole row with `…` |
| G16 | `{member name}` in "… is gone" | the dispatch's `member`, else `to_name`, else `label` |
| G17 | the band's blocked subject | a member whose activity is `blocked`. The wording follows that member's `route`: `pane` → "through the Orchestrator", anything else → "in its pane" |
| G18 (r3.23) | the overdue band subject when `eta_ms` is not a positive number | `{label} is past its eta`, plus ` · check-in {n} sent` when `checkins > 0` |
| G19 (r3.23) | decisions line | `1 decision waiting for you`, `{n} decisions waiting for you`, the same plural rule as G7 |

None of these is a user question. They follow the approved mockup, and
where it is silent they are display detail, not product behaviour.

**`/hierarchy-pane`.**
- `session.start` calls `$.command.register({ name: 'hierarchy-pane',
  description: … })` before `next(e)` (R:158-163). A reload registers it
  again, which replaces the old one (F:2985).
- The `command.run` hook has the matcher exactly
  `{ command: 'hierarchy-pane' }`.
- In a member session it opens nothing and returns
  `{ text: 'The hierarchy view is hidden in member sessions.' }`. This is
  Q3; user question U-P3a below.
- Otherwise it clears `closed` and calls `$.ui.open({ id: 'ah-status',
  title: 'Hierarchy' })`. An open from a command is asked, so the Pane
  is placed at any width (F:2382). The hook returns a `{text}` saying
  whether the Pane was placed (`isPlaced`, F:13387).
- r3.24, how the hook knows it is in a member session (G-A, option a):
  - Each tick records whether this is a member session in a variable in
    `register`'s scope, which the `command.run` hook reads.
  - It is true only when the last doc read passed §4.4 step 1's shape
    checks and its `member_sessions` holds `$.session.id()`. Expiry and
    `visible` are ignored for this purpose.
  - With no doc (absent, unreadable, malformed), it is false. Nothing
    else is consulted (§4.4: no heuristics), so the command then opens
    the Pane, which draws `No hierarchy status here.`
  - It needs no `$.state` value. Nothing is drawn from it, and a reload
    re-runs `session.start`, whose first tick sets it before `next(e)`
    returns, so before any command can arrive.
- r3.24, the texts:
  - `command.register` description (G-B): `Open the hierarchy status
    Pane`.
  - Reply when `isPlaced` is true (G-C): `Opened the hierarchy Pane.`
  - Reply when `isPlaced` is false (G-C, overridden). An asked open is
    placed at any width, so false means this session's surfaces place no
    panes (F:13387), not that space is short:
    `The hierarchy Pane is open, but this session shows no panes.`

**Auto-open.** This refines §6.3 with F:2382 and F:7061.
- In the tick, it fires when `view` is first non-null in a session and
  neither `opened` nor `closed` is set. It sets `opened`, then calls
  `$.ui.open` with the same arguments.
- An unasked open is placed from 144 columns. The floor drops to 110
  once the person has opened `ah-status` themselves, in this session or
  an earlier one, until they close it by hand.
- Below the floor, the Pane waits undrawn and is placed when the
  terminal widens (F:2384). The module does nothing more: no retry and
  no polling.
- `$.ui.open` on an id that is already open retitles it and never makes
  a second instance (F:7088).

**Close.** The hook is on `ui.close` with the matcher exactly
`{ id: 'ah-status' }`.
- When `e.origin.kind === 'person'`, it sets `closed`.
- It always returns `next(e)`, calling it exactly once (r3.19). A hook
  that answers without `next` keeps the Pane open (F:7024).

**Toasts.** Each one is `$.ui.toast(text)` (F:2363) with the default
timeout. `ToastOptions` has only `timeoutMs`, with no tone.

§6.5 holds, with one addition: `seen` is pruned only on a tick whose
`view` is non-null. A `null` view leaves `seen` untouched. Otherwise an
unreadable or expired file for one tick would empty the set, and the
doc's return would toast everything again.

**Guard.** P3 needs no new `$` call. `ui.toast`, `ui.open`, `ui.resolve`,
`command.register` and `state.get/set` are already allowed, and
`ui.invalidate` is not needed. The changes:
- `ui.close` gets the exact matcher `{ id: 'ah-status' }` (§6.3 item 2
  table).
- If E15(a) finds that a `StateRef` needs a value import from
  `'claude-code'`, §6.3 item 5 allows that one named import and no
  other.

**Tests.** These are additions to §6.6.
- `vectors.ts` gains, for all seven cases: the band line and tone, the
  Pane rows at 120 columns, and the toast `(key, text)` list.
- Register tests on `['terminal', 'desktop']` mount the band and the
  Pane through `$.ui.mount` (F:14321), on the AbovePrompt surfaces it
  supports. They answer `ui.open` with a hook beneath that records the
  arguments and answers `{ value: { isPlaced } }` (F:13401).
- The harness has no reload helper. If a second `session.start` in one
  test keeps `$.state`, use it as the stand-in for a reload, for toast
  dedupe and for auto-open once. Otherwise P3 AC 3's reload clause is
  the user's.
- The harness cannot test paint, placement or the width floors: the kit
  never exercises "a surface's paint" (F:14802). P3 AC 4 covers those,
  and it is the user's check.

**User question U-P3a** (not blocking; it has a default). Should
`/hierarchy-pane` in a member session open the Pane anyway? It is an
explicit ask, but Q3 says member sessions see nothing.
- Default: honour Q3. Reply with text and open nothing.
- The question has reached the user and is parked as d3. P3 builds with
  this default.

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
  r3.12 adds:
  - exactly 262,144 bytes is read, and 262,145 is absent;
  - a malformed shape is null (§4.4 step 1): one case each for
    `expires_at` unparseable, `member_sessions` missing, `timeline`
    empty, an unparseable `at`, and `visible` missing;
  - an unknown `tone` string renders in the `idle` colour.
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

1. **Single sources, no semantic change beyond §3.1's predicate.** Move
   `ETA_THRESHOLD_SEC` and `thresholdFor` into lib-hier, exported (the Stop
   hook imports them; its cadence is unchanged in this step). Move
   `SELF_STATE` into lib-hier, exported (stream-label imports it lazily,
   after its early exit, §3.1 r3.2; roster.mjs derives `STREAM_SELF_STATES`
   from it). Placement and names: §3.1. Move `reportStatus` into lib-hier on
   `hasAuthoredContent`; roster.mjs `deliver` imports it; delete
   `responseSkeleton()` if it has no caller left. [AC 7 for these three;
   AC 24; AC 14]
2. **Open rule.** §3.7.1 in `listExchanges`, with the orchestrator-addressed
   exemption in the same commit; `sweep` uses `.open`; the §3.7.6 SKILL.md
   wording; the §3.7.7 test updates. [AC 17, 18, 22, 23; AC 14]
3. **Stop-hook liveness for pane work.** The cadence constant joins the
   shared table and the Stop hook moves to `T/2` for the second nudge;
   pane-member wording; the `deliver` dispatch row in
   `pretooluse-ah-cli.mjs`; the dispatch-origin function in lib-peer and
   the Stop hook's clock moved onto it (§3.1, §3.7.4 item 3).
   [AC 19, 20, 21, 26; AC 7 for cadence and origin; AC 14]
3a. **merge-check sign-off address (r3.4).** §3.7.9 only: one condition
   in `merge-check`, the `test-pipeline-merge.sh` `-ok` fixture change, and
   the negative case. Its own commit, landed after step 3 and before
   step 4; independent of both. [AC 27, 22; AC 14]
3b. **Pane-line statuses (r3.6).** §3.7.4 item 2's three added status
   mappings in the Stop hook's pane line, plus an AC 20 assertion for
   `no-report`. Its own commit, any time before step 7.
4. **Producer and verb.** `lib-status.mjs`, `roster.mjs status`,
   `tests/fixtures/status/`, `docs/status-file.md`, the `docs/cli-tools.md`
   row. No write triggers yet; tests stage activity files directly.
   [AC 1, 2, 3, 4, 10, 11, 12, 13]
5. **Write triggers.** §3.4 items 1–4 and 6–9 at the shared helpers (the
   static cycle, with its conditions, §3.4 r3.7), with write isolation.
   From this commit on, the live pool gets a `status.json`. [AC 5 for
   those items + the load-order test, 6]
6. **Activity.** `activity.mjs` and its `hooks/hooks.json` registrations
   (PostToolUse async); SessionEnd removal; pane-member recording in
   `deliver`/`answer`/spawn/dismiss/disband; §3.4 item 5 (an
   activity-record change writes status); `msg.mjs sweep` deletes activity
   files past its cutoff, through lib-hier's `sweep`, so msg.mjs itself is
   untouched (§5). [AC 8, 9, and AC 5 for item 5]
6b. **Write-cost levers (r3.10).** The three §3.6 levers: the origin
   function batched over ids, `openRunAnchor` taking an optional exchange
   list, and the §3.7.1 4 KB pre-check. Its own commit, after the r3.9
   step-6 rework and before step 7. [AC 28; AC 26, 12, 17, 23 still pass;
   AC 14]
7. **Release.** Version 0.110.0 in plugin.json and the root marketplace.json
   together; release text with the §3.7.5 note; **re-run E1** on the
   step-6b tree with the same method, and replace the first run's numbers
   in the evidence file (keep the first run as "before"). [AC 15, 16, 14]

If the re-run breaks a bound (status write warm p95 > 15 ms or cold p95 >
20 ms; `listExchanges` p95 > 5 ms; an import delta > 10 ms), stop and return
to the Architect before merging, with the same cost breakdown as the first
run.

Bash tests go in `tests/test-status*.sh` and `tests/test-exchange-open*.sh`,
using `--now` and an `AGENT_HIERARCHY_DIR` temp pool. No test touches the
live pool.

1. **Verb:** `roster.mjs status` prints a valid schema-1 doc and writes
   `status.json` atomically. With no `<hier>`, it writes nothing and exits 0.
   With `--plain`, it prints `ah · …` or an empty line.
2. **Eta schedule:** one dispatch per eta size, each with its request
   `created` 10 min before its first dispatch row, evaluated at `sent_at`,
   `+T−1s`, `+T`, `+1.5T−1s` and `+1.5T`. A second, later dispatch row for
   the same id does not move `sent_at`. Each gives the correct current
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
     `dispatches`;
   - an open member-addressed request with no dispatch row is not in
     `dispatches`.
4. **Member-driven rules:**
   - a gone member → `stalled` with `member-gone`;
   - a blocked member → `blocked` that wins over time;
   - after unblocking, the next write applies rule 4.
5. **Triggers:** each trigger in §3.4 advances `written_at`, and a missed
   trigger fails its test.
   - Step 5 tests items 1, 2, 3, 4, 6, 7 and 9. Item 8 is a prose step,
     checked by a grep of its file.
   - Step 6 tests item 5 (r3.7: activity records have no writer before
     step 6).
   - Step 5 also adds the §3.4 load-order test.
6. **Write isolation:** if status.json cannot be written (read-only
   `<hier>`), the triggering `msg.mjs new` still succeeds, with unchanged
   output and exit code.
7. **Single source:** a grep test proves each of these is defined exactly
   once in `hooks/`: the eta threshold table, the check-in cadence,
   `reportStatus`, the event→state table, and the dispatch-origin function
   (no other hook reads dispatch-row timestamps). The same test fails if
   `stream-label.mjs` has a static import from `./lib-hier.mjs` (§3.1
   r3.2). The existing liveness-hook tests keep every assertion; the only
   change allowed in them is the §3.7.7 r3.5 dispatch-row backdating.
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
   - spawn records `idle`; dismiss removes the record;
   - (r3.9) a second `deliver` run that sees the same blocked prompt
     leaves the record's `at` unchanged; one that sees a different prompt
     rewrites it;
   - (r3.9) `create --spawn` of a pane member records `idle`.
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
13. **Docs and fixtures:** `docs/status-file.md` documents the schema,
    §4's rules and the fixture cases. `docs/cli-tools.md` has a `status`
    row. The §3.5 fixture set exists, and its drift test passes; changing
    any rule that alters a fixture makes that test fail.
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
21. **Cadence:** the first nudge is at `T` after the origin. The second is
    due when `now − ts1 ≥ T/2` and not before. The third is due when
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
26. **Clock origin** (Stop hook; HOME redirected so the dispatch rows go
    to a temp `~/.claude`): a request whose file `created` is 10 min before
    this session's first dispatch row for it, eta small, still open:
    - 1 min after the row: no block (it was blocked before r3.3);
    - `T` after the row: block, and the reason says "sent 5m ago";
    - a second dispatch row for the same id 2 min after the first does not
      delay the first nudge;
    - the origin function returns the earliest row's `created` across
      sessions, and nothing for an id with no row;
    - (r3.5) an id whose only dispatch row has an unparseable `created`,
      with its request backdated past `T`, is nudged.
27. **Sign-off address** (`test-pipeline-merge.sh`), with an open anchor
    and an open `<tag>-i5` record:
    - `<tag>-i5-ok` addressed to the Orchestrator, closed by a bodyless
      response → `not-signed-off`;
    - the same with a filled response → `not-signed-off`;
    - `<tag>-i5-ok` addressed to the Architect with a filled response → no
      `not-signed-off`;
    - every other `merge-check` reason and test is unchanged.
28. **Write-cost levers** (r3.10, step 6b):
    - the origin function, given several ids in one call, returns the
      same origins as one call per id, including the r3.5 corrupt-row
      fallback and "no row → none";
    - `openRunAnchor` with a passed exchange list returns the same result
      as without one, for 0, 1 and 2 open anchors;
    - a member-addressed request whose response is a 5 KB file with no
      frontmatter is closed, and `listExchanges` does not read it (a test
      may assert this with an unreadable 5 KB file, e.g. mode 000, where
      the platform allows);
    - a status write lists exchanges once and reads the dispatch-row file
      once. A grep-style or instrumentation test is fine; pick whichever
      can fail.

### P2a: claude-tui-line items

1. All of §7.6 passes.
2. The `check-*` scripts pass.
3. The version and release notes follow the §7.7 rules.
4. E7: bench p95 with a 20 KB status file adds ≤ 1 ms.

### P2b: mod skeleton plus status entry (`ah` 0.111.0)

**Step list (r3.11).** One commit per step, in this order, in a worktree.
Every commit passes the full `ah` bash suite and
`claude plugin validate agent-hierarchy` on its own. Mod tests run as §6.6
"How the tests run" says. The ACs each step must satisfy are in brackets.

0. **E14, read only, no commit.** Answer E14(a) and (b) from the
   plugin-authoring reference and record the answers in the step-1
   report. Both outcomes are decided in §11, so the answer needs no round
   trip to the Architect. [AC 1]
1. **Skeleton.** The three plugin.json keys (§6.1: the string-form
   `hooks`, `types`, and `userConfig` in E12's exact shape),
   `mod/hooks.json`, `mod/types/index.d.ts`, and a `mod/register.tsx`
   whose `session.start` only returns `next(e)`. Add the read-only guard
   test. This commit isolates the riskiest change, the hooks key, so a
   bisect lands on it alone. [AC 2(a), 3, 4, 7]

1a. **Pane-driven predicate (r3.13).** An `ah` producer fix, with no mod
   code. Its own commit, after step 1 and before step 3.
   - Move `isPaneMember` into lib-config.mjs and export it. The route gate
     imports it.
   - Use it at the three sites that 0071 P1 keyed on `route` alone:
     - `describeMembers` in lib-status.mjs: the branch choice, the `route`
       it reports, and the `member_sessions` filter (now: live, not
       pane-driven, has a `session_id`);
     - the post-launch idle seed in `layoutAndLaunch` (roster.mjs ~:4042);
     - `paneMemberName` in stop-orchestrator-liveness.mjs (~:90), so a
       claude+pane member gets the Claude wording.
   - Also check the other "pane member" sites from 0071 (§3.3's
     deliver/answer/dismiss/disband recording, §3.7.3–3.7.4). Each one that
     decides pane-driven uses the predicate. Sites that decide "has a
     pane" keep `routeHasPane`.
   - List any pre-0071 `route === "pane"` site that decides pane-driven in
     the step report, and do **not** change it. That is a follow-up, not
     this spec.

   [AC 12, 4]

1b. **Ignore engine-generated files (r3.14).** Add the new
   `agent-hierarchy/.gitignore` with the two anchored rules from §6.1. It
   is its own commit, after step 1 and before step 3, so it is in place
   before the user's AC 2(b) launch recreates the files. It is independent
   of 1a. It touches nothing the run executes or loads. [AC 13, 4]

1c. **Allow-list guard (r3.15).** Rewrite `tests/test-mod-readonly.sh`
   from the six-noun deny-list to §6.3's allowed calls and events, the
   indirection ban, the validate `hooks:` net, and the §6.6 planted cases.
   Its own commit, after step 1 and before step 3, so step 3's code is
   written against it. Tests only, so it touches nothing the run executes
   or loads. [AC 7, 4]

1d. **Guard hardening (r3.16).** Extend `tests/test-mod-readonly.sh`
   with §6.3 items 3–4 as of r3.16:
   - the parameter-name rules (`on`, `$`), inline hooks, and
     parameterless callbacks to `$` calls;
   - the `arguments`/`this` bans and the no-`\u` rule;
   - the exact matchers for `command.run` and `ui.render`;
   - the banned return keys and the element-name rule.

   Add §6.6's r3.16 planted cases and allowed forms, and make the
   planted-case run show each case, r3.15's included, failing the lexer
   layer alone. Its own commit, after 1c and before step 3. Tests only.
   The current skeleton must still pass. [AC 7, 4]

1e. **Guard, final round (r3.17).** Rework `tests/test-mod-readonly.sh`:
   - F1: `on` passes only in its two positions (§6.3 item 3);
   - F2: the validate net parses `event{k=v,…}` (§6.6);
   - F3/F4: the one banned-words list, checked by token, with
     substitution-free templates recorded as strings (§6.3 item 4);
   - F5: the import rules (§6.3 item 5);
   - §6.6's r3.17 planted cases and allowed forms.

   Also check that 1d's three `\u` cases contain real escape bytes, and
   re-plant any that were written decoded.

   Its own commit, tests only. Step 3 need not wait for it. It lands
   before step 5, and the real module as it stands then must pass it.
   This round closes the guard: §6.3 item 6 sets what a later review
   may still raise. [AC 7, 4]

1f. **Guard list touch-up (r3.19).** In `tests/test-mod-readonly.sh`:
   - add `deny` to the banned words;
   - record `engine` in the element list as allowed, not banned;
   - add the `{ deny: 'x' }` planted case.

   The current module must still pass. Tests only. It rides in step
   3a's commit if 3a has not committed yet; otherwise it is its own
   commit, before step 5. [AC 7, 4]
2. **Embedded fixtures and drift test.** Generate `mod/tests/fixtures.ts`,
   extend the fixture-regeneration command to cover it, and add the bash
   drift test with its one-time failure demonstration (§6.6 r3.11).
   [AC 9, 4]
3. **Status entry.** In view.ts, the status-entry part: §4.4's render
   rule, §4.5 freshness, the timeline pick, the member-session rule, the
   toggle input, control-character stripping and the absent cases. In
   register.tsx: §6.2 locating (including a `cwd` change), `session.start`
   (start the 2 s clock and run one tick at once), tick steps 1–5 with the
   256 KB cap, `$.ui.status`, and the toggle read from `options` (§6.4
   r3.11). Add `vectors.ts` with `statusText` for all seven cases, the
   §6.6 edge cases that concern the entry, and the register tests on both
   surfaces (the entry set, then cleared; the missing-file staging).
   Leave out the `hierarchy-pane` command, the band, the Pane, the
   toasts, auto-open, and tick steps 6–7: they are P3.

   r3.16, from the guard:
   - the tick is a closure inside the `session.start` hook;
   - the `$.clock.every` callback takes no parameters;
   - the control-character regex uses `\x` escapes;
   - a register test shows `session.start` returns what `next` returned.

   [AC 5, 6, 7, 3, 4]

3a. **Step-3 follow-ups (r3.18).** One commit, after step 3 and before
   step 4. It is independent of 1e.
   - Add `tests/test-mod-plugin-test.sh` (§6.6 r3.18).
   - T7, and any other suite test that walks the plugin's files, uses
     the `git ls-files --cached --others --exclude-standard` set (§6.6
     r3.18).
   - register.tsx: the first tick after `session.start` always calls
     `$.ui.status` (§6.3 tick row, r3.18). Add a register test: the
     first tick with no doc still calls it, with the clear form. Skip
     this if the code already does it, and say so.

   [AC 4, 13]
4. **README** (Implementer for this step: `docs-writer`). In the `ah`
   README:
   - the mod half needs Claude Code ≥ 2.1.289, and an older client is the
     risk the user accepted with Q1;
   - the `⚠ ah: …` line, whose glyph comes from the engine;
   - `status_entry`: on by default; turn it off with `/config` or
     `claude plugin configure`, at user scope only, because project and
     local settings cannot set it;
   - the fresh-install "not yet set" line is informational;
   - r3.16: running the bash suite needs the `claude` CLI on PATH,
     because the mod guard's validate net fails without it.

   r3.12: in the same commit, `docs/status-file.md` catches up with §4.4:
   - "Reading it": the exact byte cap, the malformed-shape rule, and the
     unknown-`tone` fallback;
   - "Reading it": who sees the view. Replace line 25's "Only the
     Orchestrator's sessions see the view" with "member sessions see
     nothing; every other session in the checkout sees the view";
   - "Schema": enumerated values may be added under `schema: 1`;
   - one line on location: a linked worktree is its own pool (§6.2
     r3.12);
   - r3.13: the member `route` field means how `ah` reaches the member
     (`pane` only when it is pane-driven), and `member_sessions` holds
     every live Claude member, whatever its route.

   [AC 10, 4]
5. **Release.** Bump to 0.111.0 in plugin.json and in the root
   marketplace.json, so the two agree. Add a CHANGELOG [0.111.0] entry
   (Added: the mod's status entry and the `status_entry` option; the
   minimum client version). [AC 11, 4]

r3.12, decision d1: P2b ships alone as 0.111.0. This was decided for the
user by the Reviewer and is flagged for the user's review at the end of the
run. Step 5 stays at the end of P2b.

**ACs.**

1. E12 and E13 are run and recorded in `0071-evidence.md` (done). E14's
   answers are in the step-1 report.
2. (a) **Implementor, step 1:** `ah` from the worktree loads under
   `--plugin-dir`. Use E9's method: a scratch git repo,
   `--setting-sources local`, a timeout, and `pgrep -fl claude`
   afterwards. The debug log shows both `hooks/hooks.json` and
   `mod/hooks.json` loading for `ah`, with no plugin load error.
   (b) **User, after step 3 and before the merge:** in `agent-tools`,
   while a dispatch is out, run
   `claude --plugin-dir <worktree>/agent-hierarchy --setting-sources project,local`.
   That flag keeps the installed `ah` and the user's other plugins out
   of the session. Check that the classic SessionStart context line
   appears and that `⚠ ah: …` shows.
3. `claude plugin validate agent-hierarchy` is clean. Run E14(b)'s type
   check if E14 found one; otherwise the report says none was run.
4. The full `ah` bash suite passes with the mod files present, including
   the drift test, and the command hooks are unaffected. r3.18: the
   suite includes `test-mod-plugin-test.sh`, so `claude plugin test`
   gates it. It also passes with a `--plugin-dir` load's generated files
   present in the checkout.
5. The status entry:
   - matches `vectors.ts` for all seven cases;
   - every case has a vector and every vector names a case;
   - the absent cases clear it: missing, unparseable, over 256 KB,
     `schema: 2`, expired, `visible: false`, and r3.12's malformed shapes
     (§4.4 step 1, the same five cases as §7.6);
   - it does not render in a member session;
   - its text has no `ah · ` prefix;
   - control characters are stripped.
6. `status_entry` set to `false` suppresses the entry; a missing value or
   `true` does not. This is a view.ts test, plus a register test if
   E14(a) allows one.
7. The read-only guard passes. As of r3.16, that means:
   - every planted case in §6.6 fails the lexer layer on its own, and
     fails the full guard; every allowed form passes. Shown in a scratch
     copy;
   - validate's `hooks:` set is a subset of the allowed events (and its
     `calls:` set of the allowed calls, if printed);
   - from step 3 on, the real module passes it, and the step-3 register
     test shows `session.start` returns what `next` returned;
   - r3.17: the matcher allowed forms pass through validate, and a
     review of the guard finds nothing outside §6.3 item 6's ceiling.
8. **After release, by the user:** update `ah` from the marketplace, so
   the copy is installed, not `--plugin-dir`, and use a logged-in session.
   Check that:
   - no config dialog appears during the update or in the first session
     afterwards (E12 did not observe a logged-in session or a
     git-sourced marketplace);
   - a classic `ah` hook still fires: the SessionStart context line
     appears;
   - the status entry shows in a non-member session with a live team.

   If the classic hooks stop firing, roll back to 0.110.x and return to
   the Architect.
9. The drift test fails unless `fixtures.ts` is byte-identical to a fresh
   generation, and it has been seen to fail once, on a one-byte edit in a
   temp copy.
10. The README carries the five step-4 points (r3.20: r3.16 added the
    `claude`-on-PATH point), and `docs/status-file.md`
    carries the four r3.12 points and the r3.13 point.
11. plugin.json and the root marketplace.json both say 0.111.0, and the
    CHANGELOG has the [0.111.0] entry. r3.13: the entry includes a Fixed
    line for step 1a: a Claude member with `route: pane` is treated as a
    Claude session.
12. r3.13 (step 1a), in `ah`'s bash suite:
    - Claude+pane: a team with a `kind: claude, route: pane` member whose
      `up` row's `pane_id` and role match its `transport_id` and role. The
      doc gives it `session_id`, `route: "peer"`, activity from
      `<session_id>.json`, and a place in `member_sessions`. The launch
      seeds no `pane-<name>.json` for it. A stalled request addressed to
      it gets the Claude nudge wording, not the `deliver` wording.
    - Non-Claude pane member: unchanged. It has `pane-<name>.json`, no
      `session_id`, is not in `member_sessions`, and keeps the pane
      wording.
    - A grep check: `isPaneMember` is defined once, in lib-config.mjs.
    - The §3.5 fixtures do not change.
13. r3.14 (step 1b): after the AC 2(a) `--plugin-dir` run, with the two
    generated files present:
    - `git status --porcelain -- agent-hierarchy` shows nothing untracked;
    - `git check-ignore` matches `agent-hierarchy/tsconfig.json` and a
      file under `agent-hierarchy/.claude-plugin/types/`;
    - `git check-ignore agent-hierarchy/mod/types/index.d.ts` does not
      match, and `git ls-files` still lists it.

### P3: band, pane, toasts

r3.11: E12 and E13 change P3 only through §6.6. Its vectors go into
`vectors.ts`, and it reads fixtures from `fixtures.ts`. P3 gets its step
list when it starts. Its version is 0.112.0, or 0.111.0 if P2b ships
with it.

r3.20: the step list. P3 starts after P2b's step 5 has released 0.111.0
(d1). Each step is one commit unless it says otherwise. The design is in
§6.7.

0. **E15, read only, no commit.** Answer from the plugin-authoring
   reference only, and run nothing:
   - (a) How is a `StateRef` written for `$.state.get/set`: as a literal
     at the call, or through a value import from `'claude-code'`? Name
     the import if there is one.
   - (b) Which theme keys does a `Text` `color` accept?

   Both outcomes are decided in §6.7. [AC 1]
1. **Guard for P3.** Tests only. In `tests/test-mod-readonly.sh`:
   - give `ui.close` the exact matcher `{ id: 'ah-status' }` in the lexer
     and in the validate canon (`ui.close{id=ah-status}`);
   - if E15(a) needs it, allow its one named value import from
     `'claude-code'` (§6.3 item 5).

   Planted cases, each failing the lexer alone:
   - `ui.close` with no matcher;
   - `ui.close` with `{ id: 'other' }`;
   - a value import from `'claude-code'` of any other name (`update`);
   - a Pane `ui.render` with `requestId` other than `'ah-status'`.

   Allowed forms, each also through validate:
   - the `ui.close` matcher;
   - both `ui.render` matchers;
   - the `command.run` matcher.

   The P2b module still passes. [AC 5]
2. **State contract and view model.** In `mod/types/index.d.ts`, the four
   `PluginState.ah` values (§6.7). In view.ts, the model layer and the
   drawing layer (§6.7), covering §6.4's band rules and Pane width
   fallback and §6.5's toast keys and texts. In `vectors.ts`, the band,
   Pane rows and toasts for all seven cases. Add the view.ts edge cases
   from §6.6 that concern the band and the Pane. register.tsx is not
   changed. [AC 1]
3. **Band and Pane drawing.** In register.tsx:
   - the tick writes `view` only on change;
   - the AbovePrompt hook and the Pane hook (§6.7).

   Register tests on both surfaces, through `$.ui.mount`:
   - the band draws above `next(e)`'s answer;
   - the band yields to `next(e)` during a survey and when there is no
     band;
   - a `view` change redraws a mounted band;
   - the Pane draws its rows, and draws the `null` line;
   - another component passes through;
   - r3.21: the band `Text` for a stalled case has `color: 'warning'`
     and `bold`, for a blocked case `color: 'warning'` without `bold`,
     and for a working case no `color`. An unknown tone draws with
     `dimColor`.

   Also the §6.6 tree walk: only `Box`, `Text` and `engine` nodes.
   [AC 1, 5]
4. **`/hierarchy-pane`, auto-open and close.**
   - `command.register` in `session.start`.
   - The `command.run` hook, including the member-session reply.
   - Auto-open in the tick.
   - The `ui.close` hook with its flags.

   Register tests:
   - the command opens the Pane (`ui.open` arguments recorded) and
     returns exactly `{text}`, with `next` staged to carry `context` and
     `exitCode`;
   - another command is not answered;
   - r3.24: in a member session (by the last doc) the command opens
     nothing and returns the member text. With no status file, it opens
     the Pane;
   - auto-open fires once, never after a person close, never in a member
     session, and with `isPlaced: false` it still counts as opened;
   - a person close sets `closed`; `/hierarchy-pane` clears it.
     r3.25 (K1): the kit cannot raise a close by a person. The engine
     stamps `origin`, a test plugin's close arrives as `plugin`, and a
     rewrite is refused. So the automated tests are: a plugin close does
     not set `closed`; with `closed` set, auto-open does not fire; and
     `/hierarchy-pane` clears it. The person-origin write itself is
     checked only by AC 4;
   - `ui.close` calls `next` exactly once and returns its value.

   [AC 1, 2, 5]
5. **Toasts.** In the tick, the `seen` set, silent seeding, and pruning
   only on a non-null `view` (§6.5, §6.7).

   Register tests:
   - seeding toasts nothing;
   - a new key toasts once, with the §6.5 text;
   - the same key does not toast again;
   - a `null` view for one tick does not re-toast;
   - a member session toasts nothing;
   - dedupe across a reload, through the stand-in if it holds (§6.7).

   [AC 1, 3]
6. **README** (Implementer for this step: `docs-writer`). Cover:
   - the band;
   - the Pane and `/hierarchy-pane`;
   - when the Pane opens unasked (144 columns, or 110 once asked) and
     that closing it keeps it closed for the session;
   - toasts and their three triggers;
   - member sessions see none of it.

   [AC 7]
7. **Release.** Bump to 0.112.0 in plugin.json and the root
   marketplace.json. Add a CHANGELOG [0.112.0] entry. [AC 7]

**ACs.**

1. All of §6.6 passes through `tests/test-mod-plugin-test.sh` in the full
   bash suite. Every fixture case has band, Pane and toast vectors. The
   E15 answers are in the step-0 report.
2. The auto-open rules hold, shown by register tests:
   - once per session;
   - never after a person closes the Pane;
   - never in member sessions.
3. Toasts:
   - a fresh session seeds silently;
   - each key toasts at most once per session;
   - a `null` view does not cause a replay;
   - none appear in a member session.

   Across a reload: a register test through the stand-in, or else the
   user checks it in a live session.
4. A manual check by the user. Start from a state where `ah-status` has
   never been opened by hand.
   - In a 118-column Herdr split:
     - the band is visible;
     - the Pane waits until `/hierarchy-pane`, then opens inline;
     - the counts are on exactly one line. With `status_entry` on and no
       claude-tui-line `ah` item placed, that is the `⚠ ah: …` line.
       With the item placed and `status_entry` off, it is the
       claude-tui-line item.
   - In a terminal of 144 columns or more, the Pane opens once, unasked.
     Closing it by hand keeps it closed for the session. r3.25: this is
     the only check that a close by a person sets `closed` (K1, step 4).
     Close it with the engine's close mark, or with ctrl+x x, then wait
     past several ticks: it must not reopen. Then `/hierarchy-pane`
     reopens it.
5. The read-only guard holds for the P3 module:
   - every §6.6 and P3 step-1 planted case fails the lexer alone;
   - validate's `hooks:` are within the allowed registrations, matchers
     included;
   - the r3.16–r3.19 behaviour tests pass.
6. The full `ah` bash suite passes, and the command hooks are unaffected.
7. 0.112.0 agrees in plugin.json and marketplace.json, with a CHANGELOG
   entry and the README. After release, the user updates from the
   marketplace and repeats AC 4's 118-column check on the installed
   copy.

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

r3.26 (step-5 review, non-blocking): §6.5's seeding now says what the
code does and what §6.7 implies. It seeds on the first tick with a
non-null `view`, and a `null` view neither seeds nor prunes.

r3.27 (completion gate, nit): the Status header now gives the built state.
P1, P2b and P3 are released. P2a is claude-tui-line's SPEC-106. It also
lists the user's three manual checks: P2b AC 2(b), P3 AC 4 and P2b AC 8.
No contract changed.

r3.25 (K1 from P3 step 4): `claude plugin test` cannot raise a close
by a person, because the engine stamps `origin` and refuses a rewrite.
The person-origin `closed` write moves to P3 AC 4's manual check, as
paint and placement already did. Automated tests cover a plugin close
not setting `closed`, `closed` blocking auto-open, and the command
clearing it. No automated alternative exists: the hook must be inline
(§6.3 item 3), so a test cannot call it directly. Moving the decision
into view.ts would still leave the write itself untested.

r3.24 (P3 step 4, G-A to G-C):

- **G-A, option (a):** the tick records membership in a variable in
  `register`'s scope, and the command hook reads it.
  - It is true only for a doc that passed §4.4 step 1 and lists this
    session. No doc means false, and the command opens the Pane, which
    draws `No hierarchy status here.`
  - It survives reloads because `session.start`'s first tick runs before
    any command can arrive.
  - (b) was rejected: a state value for something never drawn. (c) was
    rejected: a second read path.
- **G-B** is confirmed.
- **G-C:** "placed" is confirmed. "Not placed" is overridden to the
  no-panes wording, because an asked open is never refused for lack of
  width.

r3.23 (P3 step 2 follow-ups): G18 pins the overdue band subject when
`eta_ms` is invalid to the Implementor's default, and G19 gives the
decisions line a singular.

r3.22 (P3 step 2 was blocked on 17 unpinned display formats): the
Implementor's mockup-derived defaults G1–G17 are adopted and pinned in
the §6.7 table. G3 adds one guard: an `eta_ms` that is not a positive
number shows `eta —`, with no bar or pct and no `NaN`.

r3.21 (E15 at P3 step 0):

- **E15(a):** a literal `StateRef` (`{ plugin, key }`), so the guard
  does not change.
- **E15(b):** no theme keys are documented, and `warning` is the only
  one named. So tones use only documented props: bad = `warning` plus
  bold, warn = `warning`, work = none, idle or unknown = `dimColor`
  (§6.7 table). No undocumented `error` key and no raw colour.
- Step 3 gains a tone-props test.
- AC 10's "four" step-4 points is corrected to five, folded in from
  r3.20.

r3.20 (the Orchestrator asked for P3 to be made build-ready):

- **New §6.7** settles P3 against the 2.1.289 types:
  - `view`, `seen`, `opened` and `closed` live in `$.state`, which
    survives reloads, and a write redraws the readers, so no
    `ui.invalidate` is needed;
  - view.ts splits into a model layer that is free of width and a
    drawing layer that takes width;
  - the band draws above `next(e)`'s answer, never in its place;
  - auto-open's floor is 144 columns, or 110 once asked (F:2382);
  - `/hierarchy-pane` is registered in `session.start`;
  - `seen` is pruned only on a non-null `view`.
- **Guard:** no new `$` call. `ui.close` gets the exact matcher
  `{ id: 'ah-status' }`. A `StateRef` value import is allowed only if
  E15(a) needs one.
- **§8 P3:** step list 0–7, ACs 1–7, and E15 in §11.
- **User question U-P3a:** whether `/hierarchy-pane` works in a member
  session. The default is no, following Q3.

r3.19 (two in-ceiling nits from the step-1e review, which passed):

- **`engine`** (:9165) is core's own drawing, answered by `next(e)`. It
  is allowed in `ui.render` returns and is not a banned word.
- **`ui.close` returning `{deny}`** refuses the person's close, an
  ordinary form that acts (item 6(a)). `deny` joins the banned words.
- **`{value}` answered without `next`** has the same effect, but
  `value` is too common to ban. It is a named ceiling item, and the P3
  test asserts `next` is called exactly once.
- New step 1f.

r3.18 (step-3 follow-ups from the Implementor):

- **T7** failed in any checkout after a `--plugin-dir` load, because
  the engine's generated `.claude-plugin/types/` contains `mcp__` text.
  Suite tests that walk files now use git's tracked plus
  untracked-but-not-ignored set (§6.6).
- **The bash suite never ran `claude plugin test`.** The new
  `test-mod-plugin-test.sh` makes the mod tests part of AC 4.
- **Tick step 4 interpretation confirmed:** P2b keeps the last text in
  the closure and uses no `$.state` until P3. Added: the first tick
  always calls `$.ui.status`, so a stale entry cannot outlive a reload.
- **Lexer note:** a `$` inside a regex literal counts as `$` (§6.3 item
  3).
- New step 3a; AC 4 extended.

r3.17 (step-1d review, third guard round; the Orchestrator asked for a
stopping point):

- **F3** (spec): element names reached as identifiers (`h(els.Link)`)
  passed both nets. §6.3 item 4 is now one banned-words list, checked
  per token whatever the token's role. **F4** (substitution-free
  templates) is closed by the same rule.
- **F5** (spec): the module may not value-import unscanned code (item
  5). JSX needs no import, because `h` is a global.
- **F1** (impl): the spec already said where `on` may appear. Item 3
  now names its two positions.
- **F2** (impl): validate's `event{k=v}` form is now specified, with
  its own matcher check (§6.6).
- **Stopping point** (item 6): the module's environment has no
  ambient I/O (types :13988, `reference.md`:23), so `$` and hook
  returns are the only ways to act, and items 1–5 close both. The
  ceiling is run-time-computed names and `next`-carried values, which
  the behaviour tests cover. After step 1e, a review raises only (a)
  an ordinary accidental form, (b) a false rejection, or (c) a mismatch
  between the test and the spec.
- The `\u` cases in r3.16's text had lost their escapes when written.
  They are now described in words.
- New step 1e; AC 7 extended; the `command.run` behaviour test's `next`
  carries `context`.

r3.16 (two Reviewer should-fix spec-defects at P2b step 1c):

- **Defect 1.** The lexer knew the environment only by the name `$`.
  Renamed or destructured parameters, a helper, a renamed `register`
  parameter and `\u` escapes got past it seven ways, and only validate
  caught them.
  - §6.3 item 3: `on` and `$` are required names; hooks are inline;
    callbacks to `$` calls take no parameters; `arguments` and `this`
    are banned; no `\u` anywhere.
  - Planted cases must fail the lexer alone.
- **Defect 2.** A `command.run` hook returning `context`, a hidden user
  message to the model, passed both nets.
  - Generalised: §6.3 item 2 is now a per-registration table of matcher
    and allowed return, from the 2.1.289 result types.
  - Item 4 adds the static return checks. Item 5 states the guard's
    ceiling.
  - §6.6 adds behaviour tests for returns.
- **Steps.** New P2b step 1d (tests only, before step 3). Step 3 carries
  the closure/`\x`/`session.start` points; step 4's README notes the
  `claude`-on-PATH need; AC 7 is updated. P3 gets the return tests
  through §6.6.
- `session.start`'s own return is ignored by the engine (:11143), so the
  review's c7 probe is harmless. It is held to `next(e)` anyway.

r3.15 (Reviewer should-fix spec-defect at P2b step 1): the read-only
guard was a six-noun deny-list. Against the 2.1.289 types, it missed most
`$` writes and acts, and missed hook returns entirely. Hook returns are
the real way a module answers a prompt: `classic.PermissionRequest`,
`PreToolUse` `allow`, `tool.check`, and op-event interception.

- §6.3 is now an allow-list of 14 `$` calls, each grounded in the types
  file, and of 4 hook registrations. It also bans indirection.
- §6.2 reads the cwd on every tick instead of hooking `CwdChanged`.
- §6.6's guard has a dynamic net, validate's `hooks:` set, plus planted
  cases.
- New P2b step 1c; AC 7 is rewritten.

r3.14 (Implementor FYI at P2b step 1): a `--plugin-dir` load writes
`agent-hierarchy/tsconfig.json` and `agent-hierarchy/.claude-plugin/types/`.
Both are ignored through a new plugin-local `.gitignore` with anchored
rules (§6.1), carried by the new step 1b with AC 13. The authored
`mod/types/index.d.ts` stays tracked.

r3.13 (Reviewer spec-defect, from r3.12's NEEDS-CHECK): §4.1 and §3.2
equated "pane member" with `route: pane`. A valid claude+pane member
therefore took the pane branch. It got no `session_id`, missed
`member_sessions` (so its own session would show the view, against Q3),
got a stale idle `pane-<name>.json` seed, and got `deliver` wording in
nudges that `deliver` refuses.

- Fix: one predicate, the route gate's `isPaneMember`, moves to
  lib-config.mjs and is used at every pane-driven decision.
- Attribution needs nothing new: the SessionStart `up` row plus
  `attributedRoster`'s pane-id match already name the session.
- The doc's `route` now means how `ah` reaches the member.
- New P2b step 1a and AC 12.
- Both sites the Reviewer named (roster.mjs ~:4042 and the Stop hook
  ~:90) came from 0071 P1, in steps 6 and 3, so they are in scope.
  Pre-0071 sites are listed, not changed.
- No claude-tui-line impact: P2a reads neither `route` nor members, and
  `member_sessions` keeps its documented meaning.

r3.12 (claude-tui-line's P2a contract questions CQ1–CQ6, answered from the
contract as built at 64ad0f4; no producer change):

- §4.4 now states:
  - 256 KB = 262,144 bytes, checked before parsing;
  - the malformed-shape rule; a missing `member_sessions` is absent, not
    empty;
  - who sees the view: member sessions are hidden and every other session
    is shown;
  - no consumer heuristics;
  - enumerated values are open (an unknown `tone` uses the `idle`
    colour).
- §3.2 matches §4.4. §6.2 confirms the writer and reader share the walk-up
  rule, so a worktree is its own pool.
- §7.6 and P2b AC 5 gain the new absent cases.
- E7's method is now direct `hyperfine` with an A/A check and a live,
  visible 20 KB doc. Over the bound returns to the Architect, because an
  in-process cache may not apply to a per-render process.
- P2b step 4 brings `docs/status-file.md` up to date.
- Decision d1 (Reviewer, for the user, flagged for review): P2b ships
  alone as 0.111.0.

r3.11 (E12, E13 in; P2b made build-ready):

- §6.4 states how the toggle is read: from `register`'s `options`, with
  only `false` turning it off, as an input to view.ts, at user scope only.
  It also requires control-character stripping.
- §6.3 gives the mod the 256 KB read cap.
- §6.6 replaces the in-place fixture reads with a generated `fixtures.ts`,
  a bash drift test, and a TypeScript `vectors.ts` whose cases must match
  the fixtures. `tsc -p` is replaced by E14(b), because `ah` has no node
  toolchain. The section also states how the tests run.
- §6.1 lists the new files, the exact `userConfig` shape and the
  dev-mods rule.
- §8 P2b has a step list (0–5) and ACs 1–11. AC 2 is split into an
  Implementor load check and a user launch; AC 8 also covers the cases
  E12 did not observe. P3 gets a version note.
- §11 records E1, E11, E12 and E13 as done and adds E14. §12 gains three
  notes.

r3.10 (E1 over bounds at step 7): the first run was over because of waste:
a second exchange listing inside `openRunAnchor`, and a 609 KB dispatch-row
re-read per dispatch. New step 6b removes it with three levers (the batched
origin function, `openRunAnchor` taking an optional list, the 4 KB
pre-check), plus AC 28. The bound is split: warm p95 ≤ 15 ms, cold
≤ 20 ms. r2's 15 ms did not separate out the per-process warm-up. Write
coalescing is dropped, because no process lives to make the trailing write
and skipping a write loses the final state. Step 7 re-runs E1; over again →
Architect.

r3.9 (step-6 interpretations): (a) the pane `note` is the recognised
prompt's heading line, else null: confirmed. (b) Changed: `at` is when the
current state began; an unchanged observation, including deliver's exit
write, never rewrites the record, so blocked toasts fire once per episode,
and a changed `note` counts as a change. (c) Changed: every pane-spawn path,
including `create --spawn`, records `idle`. AC 9 gains two bullets.
§3.4's "eight libs" is now "six".

r3.8 (ratification at P1 step 5): lib-config joined the r3.7 cycle, and
lib-hier's top-level `MSG_ROLES` read crashed every lib-config-first
process. The Implementor's fix is ratified: `MSG_ROLES` moves to lib-config
and is re-exported from lib-hier (§2 lists lib-config for this alone). §3.4
records that every hook now loads the full graph and that r3.2's lazy
import is moot; E1 also measures the lib-config import.

r3.7 (two step-5 questions):
- §3.4 item 8 targets `commands/hierarchy.md` (`on`/`off` and `init`
  step 5) with one prose step running `roster.mjs status --plain`. r1 named
  a `skills/hierarchy/SKILL.md` that does not exist; §1 and §2 are
  corrected.
- §3.4 layering: the trigger helpers import lib-status statically, an
  allowed ESM cycle. The conditions are: no top-level reads across the
  cycle, no re-entry, a load-order test, and E1 measuring the load delta.
  An async import loses Stop-hook writes, `require(esm)` depends on the
  Node version, and entry-point triggers miss new callers.
- Item 5's trigger and test move to step 6. AC 5 and §8 steps 5–6 are
  updated, and step 6's activity-file sweep goes through lib-hier's
  `sweep`, so msg.mjs stays frozen.

r3.6 (four gaps at P1 step 4, plus a step-3 review nit). The Implementor's
default was accepted for each, with additions:
- G1: §3.5 "Shared fixtures": status documents only, seven named cases,
  generated by `roster.mjs status --now`, guarded by a regenerate-and-compare
  drift test. AC 13 is updated.
- G2: team liveness is `teamIsLive(t, null)` (§3.1, §4.1).
- G3: the default team's `team` is `null`; consumers show `default`.
- G4: a dispatch with no member is labelled `to_name`, else `to` (§4.2).
- `memberIsLive` moving into lib-hier is acknowledged (§3.1).
- The pane line maps `no-report` and `not-sent` and falls back to
  `message` (§3.7.4); it lands as step 3b.

r3.5 (spec conflict at P1 step 3): AC 7's "existing liveness tests pass
unchanged" contradicted the r3.3 origin, because those tests backdate the
request, not the dispatch row. §3.7.7 now allows exactly one fixture change,
backdating the dispatch row to the request's instant, with no assertion
changed; AC 7 says so. Also: a dispatch whose rows all have an unparseable
`created` falls back to the request's `created` (§3.1; AC 26 gains a
bullet); the pane command's paths are quoted (§3.7.4); r3.2's "~6 ms" is
corrected to ~0.4 ms, and the lazy-import rule now rests on the inert
contract, covering pretooluse-ah-cli's lazy imports too.

r3.4 (Reviewer spec-defect at P1 step 2): `merge-check` accepted an
orchestrator-addressed `-ok` closed by a bodyless response as a sign-off,
which contradicts §3.7.6. New §3.7.9: only a closed, member-addressed `-ok`
signs off. This is one condition in the advisory `merge-check`, and §5's
push-guard freeze yields for it alone (`pinnedMerge` is untouched). It lands
as P1 step 3a with AC 27, and §2/§3.7.2/§5 match.

r3.3 (live false nudge on a queued request): every liveness and status
clock now starts at the dispatch **origin**, the earliest dispatch row for
the request id (§3.1), instead of the request file's `created`. The Stop hook
gains a third change (§3.7.4 item 3); the doc gains `sent_at`; unsent
requests are not out (§4.2); §6.4/§6.5 measure from `sent_at`. P1 step 3
gains the origin function and AC 26; step 4's AC 2 and 3 change; E1 includes
the dispatch-row file.

r3.2 (Reviewer spec-defect at P1 step 1): §3.1's "stream-label pays nothing
extra" was false: a static lib-hier import costs every session about 6 ms per
UserPromptSubmit/Stop/Notification. stream-label now imports lib-hier lazily
after its early exit, and AC 7 guards against a static import. §8 step 1
matches.

r3.1 (spec gap at P1 step 1): §3.1 names the destination, `hooks/lib-hier.mjs`
beside `ETAS`, and the exports, `ETA_THRESHOLD_SEC`, `thresholdFor` (it moves
with the table) and `SELF_STATE`; roster.mjs's `STREAM_SELF_STATES` derives
from `SELF_STATE`; the step-3 cadence constant goes to the same place. §2 and
§8 step 1 match.

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
verdict. r3.11: E1, E11, E12 and E13 are done too. The step-7 re-run of E1
was within every bound: write p95 warm 5.63 ms and cold 13.40 ms;
`listExchanges` p95 1.48 ms warm and 3.39 ms cold. Open: E7 (P2a) and E14
(P2b step 0, read only).

| # | Run or measure | Decides |
|---|---|---|
| E1 | **Done: within bounds after step 6b (r3.11; numbers in the §11 intro).** Once P1 is built: time the status write path 50×, and `listExchanges` alone 50×, against a copy of the live `agent-tools` `.claude/hierarchy` (copy into `T=$(mktemp -d)`, check `T` is non-empty, and run with `AGENT_HIERARCHY_DIR=$T/hierarchy`). r3.3: also copy `~/.claude/agent-hierarchy.peer-pending.jsonl` to `$T/home/.claude/` and run with `HOME=$T/home`, because the status write now reads dispatch rows from that global, append-only file; report its size. r3.7: also report `node -e 'await import("<hooks>/lib-hier.mjs")'` wall time (p50/p95, 20 runs) on the pre-step-5 commit and on the final P1 commit, since every lib-hier importer now loads lib-status; a delta over 10 ms returns to the Architect. r3.8: measure `lib-config.mjs` the same way, because it is the floor every `ah` hook pays now that lib-config is in the cycle; the same 10 ms bound applies. Report p50 and p95 for each. | r3.10: status write warm p95 ≤ 15 ms and cold p95 ≤ 20 ms → ship. First run over (22.4 / 17.3 ms): fixed by the §3.6 levers (step 6b), then re-run at step 7; over again → Architect. Write coalescing is no longer a remedy (§3.6). `listExchanges` p95 over 5 ms → add the size pre-check from §3.7.1. |
| E2 | **Done: async honoured; sync = 32–36 ms per call; async killed at `-p` exit.** Does Claude Code 2.1.289 honour `"async": true` on a command hook in a plugin's hooks.json? Measure the added wall-clock per tool call for PostToolUse(`*`) with and without it. | Async works → register it async. It does not → measure sync cost; over 50 ms per call → escalate Q5 to the user with the number. |
| E3 | **Done: fires ~6–8 s late; `message` is a constant → `note: null`.** In an `--agent` peer session under a test team in a temp git repo, trigger a permission prompt. Does Notification(`permission_prompt`) fire, and what does its `message` field contain? | Fires → design holds, and `blocked_note` = message. Does not fire → Claude-peer blocked detection has no event source; return to the Architect. |
| E4 | **Done: yes (idle ≤ 1 s; busy at next tool boundary).** Does UserPromptSubmit fire in a peer when a cross-session `SendMessage` brief arrives? | Yes → `working` is immediate. No → the first PostToolUse sets it, and docs/status-file.md says so. No design change. |
| E5 | **Done: tests answer every `$` call; `mock.clock` drives `every` (§6.6).** `claude plugin test`: how does a test stage `$.fs.stat/read` content (a `mock`, or a real file under the test's cwd), and does the mocked clock drive `$.clock.every`? | Shapes the register.tsx tests. view.ts tests do not depend on it. |
| E7 | **Open (P2a).** claude-tui-line `bench/bench.sh` with `ah` placed, against a 20 KB status file, before and after. **r3.12, method replaced (CQ6).** `bench.sh` is publish/-only and reports medians only, so run `hyperfine` directly on a Release build made outside `publish/`. (1) A/A: the baseline config twice. Its |Δp95| must be < 0.5 ms, or add runs until it is, or report the run as inconclusive. (2) Baseline vs. the same config with `ah` and `ah-short` placed. Use ≥ 200 runs per arm with warm-up. The status file is ~20 KB, schema 1, and generated for the run so that `expires_at` is in the future, the current entry is `visible: true`, and the bench session id is not in `member_sessions`. The stdin `cwd` must walk up to it. Otherwise the run only times the early-absent path. Report p50 and p95 per arm, and the A/A. | Added p95 ≤ 1 ms → nothing. Over → **return to the Architect** with the split between read, parse and render, before adding anything. r3.12: the r2 remedy (an in-process mtime cache) helps only if one process serves more than one render, so it is not applied blind. |
| E8 | **Done: the engine cancels it.** After a hot reload, is a `$.clock.every` timer started in the old `session.start` cancelled by the engine? | No → the module must cancel it (`session.end`, or a guard). |
| E9 | **Done: Branch A, both forms load both files (§6.1).** Can one plugin carry both a classic command-hooks file and a `{modules:[…]}` hooks file? Steps: (1) In `T=$(mktemp -d)`, checked non-empty, build plugin `$T/p`. `hooks/hooks.json` holds a classic SessionStart command hook that writes `$T/classic.ok`. `mod/hooks.json` is `{"modules":["./register.ts"]}`, and its `session.start` hook does `$.fs.write("$T/mod.ok","1")`, path baked in, then `next(e)`. (2) Try each plugin.json form in turn: `"hooks": "./mod/hooks.json"`, and `"hooks": ["./hooks/hooks.json","./mod/hooks.json"]`. (3) For each form, run `claude plugin validate $T/p`, then `timeout 90 claude --plugin-dir $T/p -p "reply ok"` from `$T/repo` (`git -C "$T/repo" init`). Record which markers appear. (4) Check `pgrep -fl claude` and kill anything this probe started. | Both markers under some form, and validate clean → **Branch A**, using that form. Otherwise → **Branch B**. If `mod.ok` never appears under `-p` even in a lone-module control plugin, repeat the run interactively, as in E10. |
| E10 | **Done: both render (`⚠ <plugin>: …` above the statusLine) → toggle (§6.4).** Note for any rerun: the 2.1.289 folder-trust dialog defaults to "No, exit"; accept with `Down` then `Enter`. Does a configured `statusLine` command hide `$.ui.status` output? Steps: (1) In `T=$(mktemp -d)`, checked non-empty, run `git -C "$T/repo" init`. Write `$T/repo/.claude/settings.json` with `{"statusLine":{"type":"command","command":"echo E10-STATUSLINE"}}`. (2) Build mod plugin `$T/m`. Its `session.start` calls `$.ui.status("E10-PROBE")` and writes `$T/m.ok`. (3) Run `tmux new-session -d -s e10-$$ -x 200 -y 50 -c "$T/repo" "claude --plugin-dir $T/m"`. If the folder-trust dialog shows in `tmux capture-pane -p`, accept it with `send-keys Enter`. Wait ≤ 30 s, until `$T/m.ok` exists. (4) Run `tmux capture-pane -p -t e10-$$ > $T/screen.txt`, then grep it for both strings. (5) Run `tmux kill-session -t e10-$$`, then check `pgrep -fl claude` and kill what this probe started. | STATUSLINE shown and PROBE absent → no toggle (§6.4). Both shown → `status_entry` toggle, default on. STATUSLINE absent, or `m.ok` absent → the probe is invalid; fix it and rerun. Never guess. |
| E11 (P1) | **Done.** The read part found NEEDS-ARCHITECT #5, resolved in §3.7.1. The suite run at P1 step 2 showed only the intended failures. **Suite run (P1 step 2):** with §3.7.1 in place, run the full `ah` bash suite. | Green after only the §3.7.7 updates → done. Any other failure → return it to the Architect before step 2 lands. |
| E12 (P2b start) | **Done: readable from `register`'s `options` (defaults filled in), no blocking prompt on update, enable or start → userConfig as in §6.4 (r3.11 read path and scope there).** Read the plugin-authoring reference (load the `plugin-authoring` skill) and, if it is not explicit, probe: how does a module read a plugin `userConfig` value, and does adding a `userConfig` key to an installed plugin's plugin.json prompt the user on update or enable? Probe sandbox-safely as in E9 (`T=$(mktemp -d)`, checked non-empty; `--plugin-dir`; `--setting-sources local`; timeout; `pgrep -fl claude` afterwards). | Readable and no prompt, or a prompt with the default pre-filled → userConfig as in §6.4. Not readable by a module → return to the Architect (the fallback is a `$.store` flag set by a mod command). A blocking prompt for every `ah` user → return to the Architect; it becomes a user decision. |
| E13 (P2b start) | **Done: no; any `.json` import is refused, and a `.ts` module that embeds the JSON loads → `fixtures.ts` plus the drift test (§6.6 r3.11).** Can a `claude plugin test` test file under `<mod>/tests/` import a JSON file under `agent-hierarchy/tests/fixtures/status/` (a static `import … with { type: "json" }`, or a plain import)? One-test probe in a scratch copy of the plugin. | Yes → tests read fixtures in place. No → the embedded fixtures module plus the bash drift check (§6.6). |
| E15 (P3 step 0, read only, r3.20) | **Done (r3.21): (a) a literal `{ plugin, key }`, so no guard change; (b) no theme keys are documented and only `warning` is named, so tones follow the §6.7 r3.21 table.** Answer from the plugin-authoring reference only; run nothing. (a) How is a `StateRef` for `$.state.get/set` written: a literal at the call, or a value import from `'claude-code'` (which name)? (b) Which theme keys does a `Text` `color` accept? | (a) Literal: no guard change. Import: §6.3 item 5 allows exactly that name, done in P3 step 1. (b) The Implementor maps bad, warn and work by name to the error key, the warning key and an in-progress or suggestion key (else no colour), and idle to `dimColor` (§6.7). |
| E14 (P2b step 0, read only, r3.11) | Answer from the plugin-authoring reference only; run nothing. (a) Can a `claude plugin test` test supply `options` (userConfig values) to `register`? (b) Does the reference name a type check for module code that runs with no new dependency in the repo? `ah` has no package.json, and `tsc` is not installed. | (a) Yes → add a register-level toggle test. No → the view.ts toggle test alone carries P2b AC 6. (b) Yes → AC 3 runs it. No → AC 3 is `validate` only, and `ah` gains no node toolchain. Ceiling: type errors that the tests do not exercise go unseen. |

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
  - the mod never runs anything named in the file;
  - r3.28: a path that is not a non-empty regular file is absent and
    never opened, and the writers never write through a link (§13).
- **Mod API version.** The mod needs Claude Code ≥ 2.1.289. Say so in the
  `ah` README, through docs-writer, together with the `⚠ ah:` rendering and
  the `status_entry` toggle.
- **Installed-copy loading is untested** (E9 used `--plugin-dir`). P2b AC 8
  is the check, and a rollback path is named there. r3.11: E12 also left
  two cases unobserved, a logged-in session and a git-sourced
  marketplace, and AC 8 covers both.
- **No type check (r3.11, unless E14(b) finds one).** `claude plugin test`
  exercises the module, but type errors on paths no test reaches go
  unseen. Add a toolchain only if one of those ever ships.
- **Hot reload (r3.11).** Mod code never goes into `~/.claude/dev-mods/`
  (§6.1). The user's AC 2(b) launch uses `--setting-sources project,local`,
  so the installed `ah` does not load beside the worktree copy, and the
  user's verb-themes plugin does not rewrite `~/.claude/settings.json`
  (the E9 side effect).
- **`$.state` writes.** These are refused during `ui.render`. All state
  writes happen in the tick, `command.run` and `ui.close`.
- **Spec 0028.** As of r2, the Stop hook follows §5.7.2's half-threshold
  second check-in. §5.7.3's `/loop` timer prose in `agents/orchestrator.md`
  is not touched.

## 13. r3.28 — non-regular files (reader hazard)

Found by claude-tui-line SPEC-106 §J. A repo can commit
`.claude/hierarchy/status.json` or `.claude/hierarchy/activity/<x>.json`
with `git add -f` as a symbolic link (to `/dev/tty`, say), a FIFO, a
directory or a device. A reader that opens such a path can hang (a FIFO
with no writer) or read the person's keystrokes (a link to a terminal). The
rule (§4.4 step 1, r3.28): **only a non-empty regular file, not itself a
symbolic link, is read; anything else counts as absent and is never
opened.**

Worktree `/Users/jimcline/git/repos/agent-tools-0071`, branch
`ah/pipeline-0071-hierarchy-status-view`, from HEAD `5d00b1f`. Never touch
the main checkout `/Users/jimcline/git/repos/agent-tools` (the live `ah`
root). Do not push.

### 13.1 Every site that touches these paths

From a full grep of `hooks/`, `mod/` and `scripts/` for `status.json`,
`activity/` and their readers:

| Site | Today | r3.28 |
|---|---|---|
| `mod/register.tsx:44-46`, the tick | `$.fs.stat`, rejects `kind ≠ file` and size > cap, then `$.fs.read`. A FIFO, device, dir or dangling link is already rejected (`kind` `other`/`dir`). Gaps: a link to a regular file is read; size 0 is read. | §13.2 |
| `hooks/lib-status.mjs:55-63`, `readActivity` (called by `recordActivity` at :79 and the status compute at :135, :141) | `readFileSync` with no check. A FIFO hangs the hook process; a link to a terminal reads it. | §13.3 |
| `hooks/lib-status.mjs:76-89`, `recordActivity` write | temp file, then rename. | §13.4 |
| `hooks/lib-status.mjs:107-128`, `sweepActivity` | `readdirSync` of `activity/`, then `statSync` + `unlinkSync` of each old `*.json`. `statSync` opens nothing, so no hang. Hazard: if `activity` is itself a link to another directory, the sweep **deletes old `*.json` files in that directory**. | §13.3 |
| `hooks/lib-status.mjs:361-372`, `saveStatus` | temp file, then rename. | §13.4 |
| `hooks/roster.mjs`, `hooks/activity.mjs` | No read of either path; they call `computeStatus`, `saveStatus` and `recordActivity` only. | none |

Nothing in `hooks/` reads `status.json`; only the mod and claude-tui-line
(P2a, which already applies the rule) do.

### 13.2 Mod reader (`mod/register.tsx`)

What `$.fs` in Claude Code 2.1.289 can check (from the plugin-authoring
`claude-code.d.ts`, `FsStat`): `kind` (`file` | `dir` | `other`) of what
the path leads to, with a link followed and a dangling one `other`;
`isLink`, true when the path itself is a symbolic link; `size`; `mtimeMs`.
There is no handle API and no way to open without following, so the
"seekable handle" check is not available.

Required:

- The tick treats the doc as absent, and does not call `$.fs.read`, when
  `isLink` is true, `kind` is not `file`, `size` is 0, or `size` is over
  `SIZE_CAP`. The absent branch is the existing one: `doc = null`,
  `seenMtime` cleared.
- A regular, non-empty file within the cap is read exactly as today.
  `parseDoc` and `view.ts` do not change.

Known limit, stated in a `ponytail:` comment at the check: the stat and the
read are two calls by path, so a live local process could swap the path
between them. A committed file cannot race, and a live process with write
access to the checkout already has the person's privileges. `$.fs.read`'s
own 4 MiB cap still bounds a swapped regular file. Close it if `$.fs` ever
gains a handle or no-follow read.

### 13.3 Hooks readers (`hooks/lib-status.mjs`)

**Activity records.** Before `readActivity` opens a record, it checks the
path with a stat that does not follow a final link (`lstatSync`). The
record is absent (the function's existing `null`) unless the path is a
regular file whose size is greater than 0 and at most 4,096 bytes. Records
are under 300 bytes; the cap only bounds a hostile file. Absent here means
exactly what a missing record means today, at all three callers.
`recordActivity` then writes a fresh record, whose rename replaces the
link or FIFO (§13.4).

Decision: check-before-open with `lstatSync`, not
`openSync(O_NOFOLLOW | O_NONBLOCK)` + `fstatSync`. The threat is committed
content, which cannot race the check; `lstatSync` is portable, and it
matches the mod's stat-then-read shape. The same race as §13.2 is the
ceiling; say so in a `ponytail:` comment.

**The activity directory.** `<dir>/activity` is used only when a stat that
does not follow it says it is a real directory. Otherwise:
- `sweepActivity` removes nothing and returns 0;
- `recordActivity` writes nothing and returns false;
- `readActivity` returns `null`.

The check never removes or replaces what is there. One check serves all
three, not three copies of it. If a `hooks/lib-*.mjs` already exports an
equivalent no-follow regular-file or directory check, reuse it; otherwise
it lives in `lib-status.mjs`.

### 13.4 Writers

**The rename is safe.** `renameSync(tmp, <final>)` replaces the final name's
directory entry and never follows it. A link, FIFO or device at
`status.json` or `activity/<x>.json` is replaced by the new regular file,
and its target is untouched. A directory at the final name makes the
rename fail; the existing catch already makes that a skipped write, and
the reader treats the directory as absent. No change.

**The temp write is not safe today: fix it.** `writeFileSync(tmp, …)` (both
`saveStatus` and `recordActivity`) opens with create + truncate and
**follows a link at the temp path**. The temp names are predictable
(`status.json.<pid>.tmp`, `<file>.<pid>.tmp`), and pids top out under
100,000. A repo that commits a link at every such name pointing at a file
of the person's makes `ah` truncate that file and overwrite it with JSON.
That is data loss, not just a hang.

Required, for both temp writes:
- Any existing entry at the temp path is first removed, never followed
  (unlinking a link removes the link). "Not there" is not an error.
- The temp file is then created exclusively: creation fails if anything
  exists at the path (Node's `flag: "wx"`, that is `O_CREAT | O_EXCL`,
  which POSIX says fails on a link whatever it points at).
- If either step fails, the write is skipped through the existing catch.
  Both functions still never throw, and nothing else about them changes.

Removing first also clears a temp left by a crashed process whose pid has
come round again, so exclusive creation never wedges a pid.

### 13.5 Out of scope, with the gap named

- **A symlinked parent.** If `.claude` or `.claude/hierarchy` is itself a
  link, every `ah` read and write, including `msgs/`, `teams/` and
  `peers.jsonl`, lands in the target. `activity/` is guarded (§13.3)
  because its sweep deletes; the hierarchy dir is not.
- **Other files under `<hier>`.** A FIFO committed at `peers.jsonl`,
  `teams/*.json` or a `msgs/*.md` would hang the hook that reads it, which
  is the same hazard.

Both need a hierarchy-wide rule, which is a separate spec. It is
NEEDS-ARCHITECT for the Orchestrator to schedule; the user decides whether
to schedule it.

### 13.6 Docs: `docs/status-file.md`

The Implementor makes these changes; the wording below is the contract and
must not be weakened.

1. **"Reading it", step 1.** Change "has a `schema` other than `1`" to
   "has a `schema` that is not the integer `1` (see Schema)". Add this
   sub-bullet after the 256 KB bullet:

   > - "Unreadable" means the path is not a non-empty regular file: it is
   >   itself a symbolic link (even one leading to a regular file), a
   >   directory, a FIFO, a socket or a device, or it is empty; or opening
   >   or reading it fails. Check with a stat that does not follow a final
   >   symbolic link, before opening the file, and never open a path that
   >   fails: opening a FIFO blocks, and a link can lead to a terminal. A
   >   reader that holds an open handle may check the handle instead. Only
   >   the last path component is checked.

2. **Schema table, the `schema` row.** Replace its meaning `1` with:

   > the JSON integer `1`, the only spelling `ah` writes. A reader that
   > sees the number's text treats `1.0`, `1e0` or any other spelling as
   > a different schema, so the document is absent. A JavaScript reader
   > cannot tell them apart (`JSON.parse` gives the same number) and
   > accepts them. The two differ only on a hand-made file.

3. **The "Who writes it" bullet.** After "a per-process temp file, then a
   rename", add: "the temp file is created exclusively, after anything
   already at its name is removed, so a write never goes through a
   link".

### 13.7 Tests

Each new test must be shown to **fail against `5d00b1f`** before the fix
makes it pass; report each red→green. A case that would hang on the old
code (any FIFO case) runs with a bound, such as a child process under a
timeout, so a regression fails instead of hanging the suite. No test opens
`/dev/tty`. Put hooks tests in the existing `ah` suite next to whatever
covers `lib-status.mjs` (find it by grep), each case in its own
`mktemp -d` that is checked to be non-empty.

Hooks (`lib-status.mjs`, through its exported functions):

| # | Setup in the temp hierarchy dir | Expect | Red on `5d00b1f`? |
|---|---|---|---|
| H1 | `activity/<sid>.json` is a link to a valid record elsewhere | the member's activity reads as if no record existed | yes (the link is read) |
| H2 | `activity/<sid>.json` is a FIFO | same as H1, and the call returns | yes (it hangs, so the bound fails it) |
| H3 | `activity/<sid>.json` is a directory | same as H1 | no (regression guard) |
| H4 | `activity/<sid>.json` is empty | same as H1 | no (regression guard) |
| H5 | `activity/<sid>.json` is a 4,097-byte regular file | same as H1 | yes |
| H6 | `activity/<sid>.json` is a valid regular record | read as today (control) | no |
| H7 | `activity` is a link to another dir holding an old `x.json` | `sweepActivity` returns 0, `x.json` still exists; `recordActivity` returns false and writes nothing there | yes (the file is deleted) |
| W1 | a link at `status.json.<pid>.tmp` (`pid` = the process that calls `saveStatus`) to a file with known bytes | that file's bytes unchanged; `status.json` is a regular file holding the doc | yes (the file is overwritten) |
| W2 | the same at `activity/<sid>.json.<pid>.tmp`, for `recordActivity` | target unchanged; the record written | yes |
| W3 | `status.json` is a link to a file with known bytes | after `saveStatus`, `status.json` is a regular file (by `lstat`); the old target is unchanged | no (rename is already safe; guards it) |
| W4 | `status.json` is a FIFO | after `saveStatus` (bounded), `status.json` is a regular file | no (guard) |
| W5 | a stale regular file at `status.json.<pid>.tmp` | `saveStatus` still writes `status.json` | no (guards the remove-first step) |

Mod (`mod/tests/register.test.ts`). The fake `fs.stat` handler at :35-38
always answers `kind: 'file'`, `isLink: false`. Let a staged file override
`kind`, `isLink` and `size`. For each case, assert the doc is absent, as
the existing no-file tests do, **and** that `w.reads` did not grow:

| # | Stat answers | Red on `5d00b1f`? |
|---|---|---|
| M1 | `kind: 'file'`, `isLink: true`, valid text | yes (it is read and shown) |
| M2 | `kind: 'other'` (a FIFO or device) | no (guard) |
| M3 | `kind: 'dir'` | no (guard) |
| M4 | `kind: 'file'`, `size: 0` | yes (`w.reads` grows) |
| M5 | `kind: 'file'`, `isLink: false`, valid text | shown as today (control) |

### 13.8 Implementor order

1. `hooks/lib-status.mjs`: §13.3 and §13.4, with H1–H7 and W1–W5 red
   first.
2. `mod/register.tsx`: §13.2, with M1–M5 red first.
3. `docs/status-file.md`: §13.6, exactly.
4. Release `ah` **0.112.1**. Bump every place that declares `ah`'s version
   (`agent-hierarchy/.claude-plugin/plugin.json`, the `ah` entry of the
   root `.claude-plugin/marketplace.json` if it carries a version; grep
   for `0.112.0`), and add a `[0.112.1]` CHANGELOG entry. It is a patch,
   not folded into 0.112.0: 0.112.0 is committed as its own release
   (`40e332f`), and a plugin cache keyed by version would keep a stale
   0.112.0 for anyone who installed it from this branch.
5. Run the full `ah` suite and `claude plugin test` for the mod. Capture
   output to a file, give every headless run a timeout, and afterwards
   check `pgrep -fl claude` and `pgrep -fl node` for anything left
   running. Report the exit codes and the red→green list.

Must not change: `parseDoc`, `view.ts`, the doc schema, `computeStatus`'s
output for regular files, the never-throw contracts, and anything in
§13.5.
