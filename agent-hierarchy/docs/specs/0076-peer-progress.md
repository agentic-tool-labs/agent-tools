# 0076 — Peer progress: passive live progress plus push notes for news

Implementer: implementor
Reviewer: reviewer

Version: the next minor above the base's `plugin.json` version (0.116.0 when the base is 0.115.1). Base: the tip of
`ah/0075-pane-blank` after 0075's own version fix has landed. If the base is not a 0.115.x patch, stop and report.
Bump `agent-hierarchy/.claude-plugin/plugin.json` and the root `.claude-plugin/marketplace.json` together.

Status: r2. User rulings applied (§9). r2 changes from the Reviewer's spec review: B1 (blocked and decision news go
out as a report, not a note: §4.4), S1 (watcher text enrichment dropped: §4.5), S2 (tool shown only if from the
current turn: §4.3), S3 (honest label and a stated ceiling: §4.1, §4.3), N1 (§9), N2 (this header). E1 resolved by
the Reviewer's reading: no code change (§4.4).

**Generic-text rule (binding).** Nothing written under this spec names a product, service, platform, customer, ticket
or incident. That covers code, tests, docs, CHANGELOG and commits.

## 1. Goal (user ruling "Both")

The user asked: "peer agents should give check-ins periodically". The ruling has two parts:

- **(a) Passive progress, at no model cost.** For each Claude peer, the status file and the Pane show the last tool it
  finished in its current turn and how long ago, how long it has been working, and its elapsed time against the
  dispatch's eta. No messages are sent. This is the last *finished* tool, refreshed at most every 15 s, not a live
  "doing now" (ceiling in §4.1).
- **(b) News, pushed only when there is news.**
  - News the peer can act on without an answer goes out as a one-line note, and the peer keeps working: a surprise
    that changes the plan, or the midpoint of a long dispatch.
  - News that needs an answer before the peer can go on (it is blocked, or a decision is needed) goes out as a report,
    as role sessions already do for a gap (status BLOCKED or NEEDS-DECISION). It is never a note (§4.4, r2 B1).

The "periodic" part is (a): it updates continuously and costs no tokens. (b) is deliberately not periodic.

## 2. Existing machinery (reuse; do not duplicate)

- `hooks/activity.mjs` runs on UserPromptSubmit, PostToolUse (`*`, `async: true`), Stop and Notification, in role
  sessions only and never in subagents.
  - It calls `recordActivity(dir, sessionId, {activity, blocked_by})`, which writes
    `<hier>/activity/<session>.json` = `{activity, at, blocked_by, note}`.
  - The write happens only when one of those fields changed; each write calls `statusChanged`.
  - **Today the PostToolUse write is a no-op while a peer stays `working`, so `at` is the time it started working,
    and there is no per-tool signal.**
- `hooks/lib-status.mjs`: `describeMembers` emits `activity`, `activity_at`, `blocked_by` and `blocked_note`.
  `describeDispatches` emits `eta`, `eta_ms`, `sent_at`, `checkins` and `states`. `sweepActivity` and `clearActivity`
  remove records.
- `hooks/lib-hier.mjs`: `ETA_THRESHOLD_SEC = {small: 300, medium: 600, large: 1200}`, `thresholdFor`, `etaOf`
  (defaulting to small), and `CHECKIN_CADENCE`.
- `hooks/dispatch-watcher.mjs` runs Orchestrator-side.
  - Its base time is `max(request created, lastHeardMs(peer))`.
  - It fires CHECK-IN at base+T, SILENT at checkin+T/2, and LANDED.
  - `heard` records are written by `hooks/userpromptsubmit-peer-tracking.mjs:135`, in the Orchestrator session, when a
    wrapped peer delivery arrives: the wrapper's sender name matches a `to_addr` of this session's latest dispatch
    rows. There is no message-path test, so any wrapped message from the peer writes `heard` (E1, resolved).
  - It reads no status file today (it reads only message files).
- `hooks/stop-peer-nudge.mjs:115–158` (the 0072 report-back gate): while a report is owed, with no subagent in
  flight, on a peer-driven turn, it blocks the Stop and nudges the peer toward sending its report.
- The mod (`mod/view.ts`): the member row is `{row:'member', name, kind, route, state}`. Its state text is
  `activity`, plus an age suffix for pane-route members only (view.ts:206).
- The peer directive is `buildRoleSessionNotice()` in `hooks/lib-config.mjs:3066`. It is injected into every
  `--agent` role session and has no byte ceiling. Tests: `tests/test-route-gate-subordinate.sh:132`,
  `tests/test-peer-reportback.sh:105`.
- Agent-file sizes on `ah/0075-pane-blank`, against their ceilings: implementor 5888/5900, reviewer 7874/7900,
  architect 10150/10200, orchestrator 6588/7350. **So no text goes into implementor, reviewer or architect.md.**

## 3. Decisions

| # | Question (from the brief) | Decision | Why |
|---|---|---|---|
| D1 | What "current action" text is safe to publish? | **The tool name only**, from the hook payload's `tool_name`: control characters stripped, cut to 64 cells (`NAME_CAP`). Never `tool_input`, arguments, paths, commands, file names or output. | Arguments can hold secrets and paths. The tool name is enough to tell reading from editing from running. |
| D2 | PostToolUse write cost | **Throttle.** A PostToolUse that does not change `activity` updates the record only when the record has no `tool_at`, or its `tool_at` is ≥ 15 s old. An activity change writes at once, as today. The hook stays `async`. | Each record write triggers a full status recompute. 15 s bounds that to ≤ 4 per minute per peer, and the Pane's 2 s tick shows it within a tick. |
| D3 | How a peer knows its halfway mark | **By its own judgment of progress, not by a clock**, and only when its request's `eta` is `large`. One note, at about the midpoint of the work: what is done, and what is left. | A model has no reliable clock, and a hook nudge would need a synchronous hook on every tool call. Midpoint by work done is something the peer can judge. The passive view (a) already shows the time. |
| D4 | Hook-nudged or prose-only? | **Prose-only** for every push note (see the §6 enforcement map). | Notes are judgment ("is this news?"). A hook cannot tell news from chatter, and a timer-driven hook would produce exactly the periodic chatter that is ruled out. |
| D5 | Interaction with the watcher | A push note **counts as heard**: it resets the watcher's base time, exactly like any peer delivery (already true; no code change). Passive progress does **not** change the watcher's timing or its text. **(r2, S1)** The watcher findings are not enriched with progress. | The watcher reads no status today, and 0075's reader returns only `enabled`. Enriching the text needs a new member reader plus a dispatch-to-session mapping: new code for a convenience the Pane already gives. Add it when an Orchestrator is seen pinging a visibly busy peer. A stalled peer sends nothing, so a note never hides a stall. |
| D9 | (r2, B1) News that needs an answer | **Blocked and decision news go out as a report** (a response file with status BLOCKED or NEEDS-DECISION and the question), not as a note. The Orchestrator answers with a **new request** (`msg.mjs new --type request --parent <blocked request id>`), never a re-send under the blocked id (r2-1: the watcher stops watching a dispatch once its report is shown, `dispatch-watcher.mjs:56`, `lib-peer.mjs:280`; and `msg.mjs:323/365` refuses a second response to one id). A note never waits for an answer. | A peer that sends a note and then stops to wait still owes its report, so the 0072 Stop gate nudges it to report. A report is already the way a role hands a gap upward; it closes the dispatch, and the re-dispatch opens a new owed report, so the report-back guarantee holds with no gate change. A gate-recognised "waiting" state would be new state in the report-back gate for something the existing protocol already covers. |
| D6 | Pane-route (non-Claude) members | **No change.** They have no tool hooks and send no notes. Their row keeps today's activity and age from `deliver` and the status poll. | There is no signal source. |
| D7 | Subagent-dispatched roles (Agent tool) | **Out of scope.** No notes (they cannot message mid-run), and no activity records (`activity.mjs` skips subagents). | Unchanged. |
| D8 | Where the note rule lives | **One place:** `buildRoleSessionNotice()` (every peer role gets it), at most about 400 B added. The Orchestrator side gets one line in `agents/orchestrator.md` (room: 762 B). | Agent files near their ceilings stay untouched, and there is a single source. |

## 4. Changes

### 4.1 Activity record: last tool (hooks)

- `activity.mjs`, on PostToolUse: pass the tool name (D1) to the activity write. Other events pass none.
- The activity record gains **`tool`** (string or null) and **`tool_at`** (ISO or null).
  - A write that carries a tool sets both.
  - A write that carries none (UserPromptSubmit, Stop, Notification) **keeps** the record's existing `tool`/`tool_at`.
    It does not clear them; a new `working` turn is when they get replaced.
- **Write rule:**
  - an `activity`, `blocked_by` or `note` change → write (as today);
  - else a PostToolUse with a tool name, where the record has no `tool_at` or `tool_at` is ≥ 15 s old → write;
  - else → no write.
  - Only a write calls `statusChanged`, as today.
- The 15 s value is a named constant in `lib-hier.mjs` beside `ETA_THRESHOLD_SEC`.
- **Ceiling (r2, S3; stated, not closed).** PostToolUse fires after a tool finishes, and the throttle drops the
  trailing edge. So the record shows the last finished tool that won a write, up to 15 s plus one tool behind. Example:
  tool A written at t0, tool B finished at t0+10 s (throttled), then a long silent tool runs for 20 min → the Pane shows
  A with an age of about 20 min. The age is always shown, so staleness is visible. The upgrade path: also write when
  the tool name changes (cost bounded by how often the tools alternate). The docs and the CHANGELOG say "last finished
  tool, refreshed at most every 15 s".
- **Race note (existing ponytail, l.12–13):** async PostToolUse and sync Stop both write. Stop's write must preserve the
  `tool` fields it reads, so the last rename never drops them.
- **Unchanged:** sweeping, clearing, role-session-only, never-a-subagent, never stdout, always exit 0.

### 4.2 Status file (schema 1, additive)

- `describeMembers` emits **`last_tool`** (string; `clean()`ed and cut to `NAME_CAP`, or null) and **`last_tool_at`**
  (ISO or null), from the record.
- `schema` stays `1`. These are new optional fields; the `docs/status-file.md` reader rules already read `teams`
  field by field and default unknowns.
  - **Assumption for the Reviewer to verify:** status-file.md allows additive fields under schema 1. If it does not,
    stop and report.
- `docs/status-file.md` members table: two rows. "Tool name only; never arguments."

### 4.3 Pane member row (mod)

- `viewModel` member `state` text, for a member with `activity === 'working'`, a `last_tool`, and
  `last_tool_at >= activity_at` (the tool is from the current turn; r2, S2):
  `working {age(now − activity_at)} · last {last_tool} {age(now − last_tool_at)}`.
  - Example: `working 6m · last Edit 12s`. The word "last" is the honest label (S3).
  - Pane-route members and every other activity keep today's text.
  - Without a `last_tool`, or with a `last_tool_at` earlier than `activity_at` (a tool from the previous turn), or
    with either timestamp unparseable, the text is today's.
  - Ages use the existing `age()`.
- `PaneRow` and `View` types are unchanged; the new text goes in `state`. The width fallback in `drawRow` already
  cuts it.
- Elapsed time against eta is already on the dispatch row (`elapsed`, `eta`, `pct`); no change there.

### 4.4 Push notes (prose) and the heard record

- **Peer rule** (in `buildRoleSessionNotice`; the Implementor writes the wording, at most about 400 B, keeping every
  element):
  - Send the Orchestrator a one-line note, **only** on news that needs no answer, then keep working:
    - (a) a surprise that changes the plan or scope, which the peer can still act on alone;
    - (b) for an `eta: large` brief, once, at about the midpoint of the work: what is done and what is left.
  - Format: `note <request id>: <one line>` (the id from the brief's frontmatter, e.g. `20261006-153217-1fag`), sent
    to the address the brief came from. **A note never contains a `[hierarchy-msg` token, nor a message-file path.**
    (r3, G1: every hook that reads a SendMessage body keys on `[hierarchy-msg <path>]`:
    - `posttooluse-peer-resolve.mjs:60–71` records a dispatch row and injects the "start the dispatch watcher" text
      for any `…--request.md` token;
    - `pretooluse-msg-gate.mjs:114–134` engages on a request token;
    - `pretooluse-sendmessage-response.mjs:139–161` validates any token as a response while a report is owed.

    A token-free note engages none of them, so no hook code changes and no real dispatch can be dropped. The rejected
    alternative, a role-session exemption in the resolver, changes a dispatch-recording path and needs a proof that no
    role session ever dispatches.)
  - **Blocked, or a decision needed** (the peer cannot go on without an answer): send a **report**, not a note — the
    response file with status BLOCKED or NEEDS-DECISION and the exact question, as for any gap. Never send a note and
    then stop to wait. (r2, B1)
  - Otherwise send nothing until the report.
  - A note is not the report and never replaces it.
- **Orchestrator rule** (in `agents/orchestrator.md`, one line): a peer `note:` is news, not a report. It never closes
  a dispatch and needs no reply. Plus one clause (r2-1): answer a BLOCKED or NEEDS-DECISION report with a **new
  request** whose `--parent` is the blocked request's id, never by re-sending under the old id (that one is closed: it
  is no longer watched, and a second response to it is refused). Both fit in the 762 B of room; the ceiling holds.
- **Heard.** A note already writes a `heard` record for that peer (E1, resolved by the Reviewer's reading of
  `userpromptsubmit-peer-tracking.mjs`: the condition is the sender, not the message path). **No code change.** P5
  pins it.
- **The report-back gate is unchanged**, and needs no change:
  - It counts a report only when the body names `[hierarchy-msg <response path>]`. A note carries no token, so it
    never satisfies the gate (P6).
  - A note never waits, so the peer is still working when it sends one; the gate fires only at the peer's Stop, as
    today. A blocked or decision report satisfies the gate like any report (P8).
- **0074 intent gate is unaffected:** a token-free note never engages it, and role sessions are exempt anyway. (r3: P7
  is dropped as moot; P10 and P11 pin the token-free path.)
- **Every hook that reads a SendMessage body is unchanged** (r3): `posttooluse-peer-resolve.mjs`,
  `pretooluse-msg-gate.mjs`, `pretooluse-sendmessage-response.mjs`.

### 4.5 Watcher (r2, S1: no change)

- `dispatch-watcher.mjs` is not touched: no text change, no status read, no timing change. Reason in D5.
- 0075's status reader keeps its "one field" rule; this spec does not widen it.

### 4.6 Docs, CHANGELOG, version

- `docs/status-file.md` (§4.2). Add one line to docs/cli-tools.md or the README's roles section only if one already
  describes peer reporting.
- CHANGELOG (the version from the header), generic: "Added: per-peer progress in the status file and the Pane (the
  last finished tool and its age, refreshed at most every 15 s; tool name only). Peers send one-line notes only for
  news that needs no answer; blocked or decision news goes out as a report."
- `docs/status-file.md` also states the S3 ceiling in one line.
- Version bump (header).

## 5. Must NOT change

- The status schema number, `expires_at`, the timeline, band rules, toasts, and 0075's ≥1-row Pane.
- `dispatch-watcher.mjs` (timing, cadence, text); the report-back gate L1–L4 and `stop-peer-nudge.mjs`; 0074's
  intent gate; `userpromptsubmit-peer-tracking.mjs`; 0075's status reader.
- The implementor, reviewer and architect agent files, and their ceilings.
- Pane-route member behaviour; subagents.
- Nothing publishes tool arguments, paths or output, anywhere.

## 6. Enforcement map

| Rule | Enforced by |
|---|---|
| Tool name only, throttled | code (activity.mjs, lib-status), tests A1–A7 |
| Pane progress text | code (view.ts), mod tests V1–V6 |
| Push note only on news that needs no answer; one midpoint note on a large eta; format | **prose only** (peer notice) + content grep P1; no hook (D4) |
| Blocked or decision news goes out as a report, never a note-then-wait | **prose only** (peer notice) + content grep P1; the existing gate catches a note-then-stop by nudging toward the report |
| A note resets the watcher | existing heard path (E1; sender-based, no token needed), test P5 |
| A note is never taken for a dispatch or a report | token-free format (prose) + P1 grep; body-reading hooks unchanged; tests P10, P11 |
| A note never satisfies report-back; a BLOCKED report does | existing gate, tests P6, P8 |
| A BLOCKED report is answered by a new request with `--parent` | prose (orchestrator.md), content grep P2; the round trip is pinned by P9 |
| The Orchestrator treats a note as news, not a report | prose (orchestrator.md), content grep P2 |

## 7. Invariants and negative cases

**Must NOT happen (each one a test or a grep):**

| Case | Expected | Test |
|---|---|---|
| PostToolUse with `tool_input` holding a secret-looking string or a path | the record and status.json contain the tool name only; a grep of both for the input text finds nothing | A1 |
| 10 PostToolUse events within 15 s, activity unchanged | ≤1 record write and ≤1 status write (check the mtime count) | A2 |
| PostToolUse 15 s after the last `tool_at` | one write; the `tool` is updated | A3 |
| Stop after a tool write | `activity` is idle; `tool` and `tool_at` are preserved | A4 |
| a subagent PostToolUse | nothing written (unchanged) | A5 |
| a tool name with control characters or over 64 cells | cleaned and cut | A6 |
| a working member with a last tool from the current turn | `working 6m · last Edit 12s` | V1 |
| a working member, no last tool | today's text | V2 |
| a working member whose `last_tool_at` is earlier than `activity_at` (previous turn's tool) | today's text (S2) | V5 |
| a working member with an unparseable `activity_at` or `last_tool_at` | today's text, no throw | V6 |
| tool A written; tool B 10 s later (throttled); no further PostToolUse | the record and the status still show A with A's `tool_at`; the Pane shows `last A` with A's age (S3 ceiling pinned, so a change to it is deliberate) | A7 |
| an idle member with a last tool | today's text (the tool is not shown) | V3 |
| a pane-route member | today's text | V4 |
| the peer notice | contains `note:`, "only", both note triggers, `large`, "not the report", `BLOCKED`, `NEEDS-DECISION`, and the "never a note then wait" element | P1 |
| orchestrator.md | contains "note:", "never closes", "--parent" and "new request" | P2 |
| a note `note <request id>: …` from a peer to the Orchestrator | a `heard` record is written; the watcher's base moves | P5 |
| a note body as the peer's final SendMessage | the report-back Stop gate still holds (the note is not a report) | P6 |
| (r3) a peer session sends a note `note <request id>: …` (run through `posttooluse-peer-resolve.mjs` with the peer's session and a real request file for that id on disk) | no dispatch row is appended for the peer's session; no "start the dispatch watcher" text is output | P10 |
| (r3) an implementor peer with a report owed sends a note (run through `pretooluse-sendmessage-response.mjs`) | allowed (no deny, no hold) | P11 |
| (r3) the peer notice | contains `note <`, and contains no `[hierarchy-msg <request` in the note format (P1 widened) | P1 |
| a peer with a report owed sends a response file whose status is BLOCKED (or NEEDS-DECISION) and its `[hierarchy-msg <response path>]` message, then stops | the Stop gate lets it stop (the report counts like any report); no nudge | P8 |
| after a BLOCKED report, the Orchestrator answers with `msg.mjs new --type request --parent <blocked id>` to the same peer | (r3, slimmed to the msg.mjs facts the rule rests on; the watcher and the gate on a new request are the generic dispatch path, already covered) (a) `msg.mjs new --type response` a second time for the blocked id is refused; (b) `msg.mjs new --type request --parent <blocked id>` makes a new id whose frontmatter `parent` is the blocked id, and a response to the new id is accepted | P9 |

**Must NOT trigger a push note (prose; P1 greps for the "only" and "otherwise send nothing" elements):**

- a time passing ("every N minutes"), with no news;
- "still working", or restating the brief;
- tool-by-tool narration;
- blocked, or a question that needs an answer (that is a report, never a note);
- a second midpoint note, or a midpoint note on a small or medium eta;
- any note after the report;
- a note to anyone other than the briefing Orchestrator;
- a note from a subagent-dispatched role.

## 8. Acceptance

1. Every §7 test is present and seen failing first where new. Content greps P1/P2 are seen failing at the base.
2. `dispatch-watcher.mjs`, `stop-peer-nudge.mjs`, `userpromptsubmit-peer-tracking.mjs`, `posttooluse-peer-resolve.mjs`,
   `pretooluse-msg-gate.mjs` and `pretooluse-sendmessage-response.mjs` are unchanged in the diff. (r3) The peer
   notice's note sentence may be up to about 520 B (r3, G3 accepted: the elements are kept).
3. The full ah suite and `claude plugin test` are green. `orchestrator.md` stays ≤ 7350 B; no other ceiling moves.
4. The version is bumped in both manifests. The text is generic.
5. Manual M1 (the Orchestrator, once, live): dispatch a large-eta peer task. Watch the Pane member row update while
   it works. Confirm that at most one midpoint note and no chatter arrive.

## 9. User rulings and open question

**Ruled (relayed by the Orchestrator):** tool name only; 15 s; a midpoint note on `large` only.

**Open, one FYI (r2, N1; default applies if unanswered):** tool names from add-on tool servers include the server's
name (for example `mcp__<server>__<tool>`), so "tool name only" still shows which add-on services a peer uses. The
status file is local to the machine (git-ignored), and the Pane is on your own screen. Default: show the name as it
is. The alternative: show those tools as just `mcp:<server>` or `mcp`.
