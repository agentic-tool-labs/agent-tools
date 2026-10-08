# 0089 — A peer's note counts as hearing from it

Implementer: implementor
Reviewer: reviewer

Target: **0.127.0** (0.126.0 merges first). Base: `main` a4c0607 (0.125.0). Branch `ah/0089-watcher-notes`.

Status: **r3**.
- r3: RESUME matches a dispatch row by its request's `to_name === sub.name` (or by rule 2). With no match, nothing is written. New cases N7, N7b and N7c.
- r2: the RESUME path writes `heard` keyed by the dispatch row's `to_addr` (§3.1); new case N7.

## 1. Goal

A peer working on a long brief sends its Orchestrator `note <request id>: <one line>`. That is the documented progress channel (`hooks/lib-config.mjs:3118`, `agents/orchestrator.md:104-108`, spec 0076 §4.4). Today the dispatch watcher and the Stop liveness hook can both ignore that note, so they flag a busy peer as silent and keep demanding check-ins. This happened several times on builds that ran over an hour and did send notes.

There are three defects:

- **Gap 1.** A note is recorded only when the sender's `from-name` exactly equals the dispatch's `to_addr`.
- **Gap 2.** The Stop hook never reads the record of having heard from a peer.
- **Gap 3.** A second watcher start prints `already running (pid N)` and exits 0, which reads like a landed result.

After this change:

- Any message from a dispatched peer, a note included, restarts that dispatch's liveness clock in both the watcher and the Stop hook.
- A duplicate watcher start says plainly that it did nothing.

## 2. Root cause

**Gap 1: `heard` is written only on an exact name match.**
- `hooks/userpromptsubmit-peer-tracking.mjs:131-136` appends `{type:"heard", session_id, from: wrapper.fromName, ts}` only when `wrapper.fromName` is non-empty and some dispatch row has `to_addr === wrapper.fromName`.
- `to_addr` is the SendMessage `to` exactly as the Orchestrator typed it, after `stripRef` (`hooks/posttooluse-peer-resolve.mjs:64`, `hooks/lib-peer.mjs:263-271`). It is often the socket address (`uds:/tmp/cc-socks/N.sock`), while `from-name` is the peer's name.
- The wrapper also carries `from=` (the socket address). `parseWrapper` returns it (`hooks/lib-peer.mjs:81-90`), but the match ignores it.
- So a note from a peer that was addressed by socket writes no `heard` row. The watcher's base (`dispatch-watcher.mjs:82`, `lastHeardMs` :51-57, matching `r.from === row.to_addr`) never moves, and CHECK-IN and then SILENT fire on schedule, even minutes after a note.

**Gap 2: the Stop hook ignores `heard`.**
- `hooks/stop-orchestrator-liveness.mjs` ages a dispatch from the request's `created` (`exchangeAgeSec`, for path rows, :98-120) or from `dispatchOrigin` (for no-path rows, :62-86, `lib-peer.mjs:334-350`).
- `dueForNudge` (`hooks/lib-liveness.mjs:36-46`) counts every `liveness-nudge` gate row ever written.
- So a note never delays the Stop hook's block. After the first nudge, it re-asks at T/2 and then every T, whatever the peer said.

**Gap 3: a duplicate watcher start looks like a result.**
- `dispatch-watcher.mjs:283-292` prints `already running (pid N)` and exits 0.
- A background Bash completion with exit 0 and one line of output reads as "the watcher finished". Pinned by WA7 (`tests/test-dispatch-watcher.sh:161-166`).

## 3. Contract

### 3.1 Recording that a peer was heard (Gap 1)

In `userpromptsubmit-peer-tracking.mjs`, a wrapped cross-session message counts as heard for a dispatch row of this session when **any** of these hold:

1. `stripRef(wrapper.from) === row.to_addr`;
2. `wrapper.fromName` is non-empty and `wrapper.fromName === row.to_addr`;
3. the message body (after the wrapper tag) begins with `note <id>:` (optional leading whitespace; `<id>` matches `ID_RE` from `lib-hier.mjs:56`), and `<id>` is the request id of that dispatch row.

For every matching row, append one `heard` row:

- `from` is that row's `to_addr`, so that the existing `lastHeardMs` match (`r.from === row.to_addr`) works unchanged.
- It also carries a new field, `request: <id>` when matched by rule 3, and `null` otherwise. The field is informative only.
- At most one `heard` row is written per distinct `to_addr` per message.

The idle notice (unwrapped) still writes nothing (:131-132).

**The watcher's RESUME path (r2, in scope).**
- Today the API-error RESUME path in `dispatch-watcher.mjs` (~:261-274) writes `heard{from: sub.name}`, but the clock matches `from === to_addr`. A resumed peer addressed by socket therefore never restarts its clock. This is the same defect as Gap 1, through a second writer.
- After this change, the RESUME path writes one `heard` row per open dispatch row of this session that belongs to the resumed peer, with `from` set to that row's `to_addr`.
- **Where "belongs to the peer" comes from (r3).** The resume subject has a name but no address: it is `{id, name, role}` from `describeMembers`, `dispatch-watcher.mjs:223`. So rule 1 cannot apply. A row belongs to the peer when either:
  - the row's request file frontmatter has `to_name === sub.name`. This is the primary source. `evaluate()` already reads that frontmatter (about `:74-79`), so it costs no new read and needs no address;
  - or the row's `to_addr === sub.name` (rule 2).
- **Rejected sources:**
  - deriving a socket from a roster pid: that path is owned by the harness, and the member record has no sourced pid;
  - name-only matching: it misses every peer addressed by socket.
- **No match** (for example a request created without `--to-name`, so `to_name` is `null`, and addressed by socket): nothing is written. The RESUME wake itself proceeds unchanged. That dispatch's clock simply runs on from its last `heard`, as in 0.125.0.

Invariant for every writer of `heard`: `from` is always a dispatch row's `to_addr`.

The parsing reuses `parseWrapper`, `stripRef` and `ID_RE`. No new regex for the wrapper.

### 3.2 One liveness clock for both the watcher and the Stop hook (Gap 2)

The watcher's base rule becomes the single implementation, in `hooks/lib-liveness.mjs`, and both the watcher and the Stop hook call it:

- `base = max(dispatch start, latest heard ts for the row's to_addr)`. The dispatch start is the request's `created` for path rows, and `dispatchOrigin` for no-path rows, exactly as each caller uses today.
- Only `liveness-nudge` gate rows with `ts > base` count as nudges for this dispatch.

The **Stop hook** then:
- includes a dispatch only when `now - base >= T`, where T is today's threshold, `thresholdFor(eta) * CHECKIN_CADENCE[0]`;
- and calls `dueForNudge` with only the post-base nudges.

So after a note, the Stop hook is silent for a full T, and its cadence restarts from the first step.

The **watcher's** behaviour is unchanged, except that it calls the shared function instead of its inline code at :82-86.

The `landed but unread` and `watcher not running` parts of the Stop hook are unchanged.

### 3.3 A duplicate watcher start (Gap 3)

When `watcherAlive(sessionId, pid)` is true:
- it prints exactly `ah watcher: not started — watcher pid <N> is already watching this session. Nothing landed; no action needed.`
- and exits **0**.

The exit code stays 0, because a non-zero exit would read as a failure to investigate. The wording carries the meaning. Detection is unchanged (`lib-peer.mjs:365-381`).

## 4. Files

- `agent-hierarchy/hooks/userpromptsubmit-peer-tracking.mjs` (§3.1).
- `agent-hierarchy/hooks/lib-liveness.mjs`: the shared base and nudge filter (§3.2).
- `agent-hierarchy/hooks/dispatch-watcher.mjs`: use the shared function; the new duplicate-start text; and the RESUME `heard` key (§3.1, §3.2, §3.3).
- `agent-hierarchy/hooks/stop-orchestrator-liveness.mjs` (§3.2).
- Tests: `tests/test-dispatch-watcher.sh`, `tests/test-orchestrator-liveness.sh`, `tests/test-peer-progress.sh` (§6).
- `.claude-plugin/plugin.json` and the root `.claude-plugin/marketplace.json` `ah` entry: both `0.127.0`.
- `CHANGELOG.md`: `## [0.127.0]` with `### Fixed`, in plain prose. It says three things:
  - a peer's note or any message from it now restarts its check-in clock, whether it was addressed by name or by socket;
  - the Stop hook no longer asks for check-ins on a peer heard from within its eta;
  - a duplicate watcher start says it did nothing.

Not touched: the note wording (`lib-config.mjs:3118`), `agents/orchestrator.md`, the CHECK-IN, SILENT and LANDED texts, the thresholds, `WATCH_POLL_MS`, and the gate-row format.

## 5. Invariants and negative cases

Must not change:

- A peer that says nothing is still CHECK-IN'd at `created + T` and SILENT'd at `T/2` after that, by both paths, as today.
- A note never closes a dispatch and never suppresses LANDED.
- No `heard` row is written for a session with no matching dispatch.

| Input | Expected |
|---|---|
| A note from a peer addressed by socket (`from=` matches `to_addr`) | `heard` written, and the watcher's and Stop's clocks restart |
| A note from a peer addressed by name (`from-name` matches) | `heard` written, as today |
| `note <id>:` where `<id>` is an open dispatch's request id, but neither address matches (for example a re-spawned peer on a new socket) | `heard` for that dispatch's `to_addr` |
| `note <id>:` where `<id>` matches no dispatch of this session | no `heard` |
| A non-note message from a dispatched peer (for example "ok") | `heard` (any message is proof of life, as today) |
| A message from a session that was never dispatched | no `heard` |
| A message whose body contains `note <id>:` mid-line, not at the start | rule 3 does not apply (rules 1 and 2 still may) |
| `note <malformed id>:` | rule 3 does not apply |
| An idle notice (unwrapped) | no `heard` |
| One message matching two dispatch rows with the same `to_addr` | one `heard` row |
| Stop hook: peer heard 2 min ago, eta small (T = 5 min) | no check-in block for that dispatch |
| Stop hook: peer heard 6 min ago, eta small, no nudge since | block (first step) |
| Stop hook: a nudge before the heard and none after | the old nudge is ignored, and the cadence restarts at step 1 |
| A second watcher start | the new text, exit 0, no second watcher row |
| A first watcher start | unchanged |

## 6. Verification (each new case fails on 0.125.0)

`tests/test-dispatch-watcher.sh`:
- **N1.** The dispatch row's `to_addr` is `uds:/tmp/cc-socks/1.sock`. A wrapped delivery with `from="uds:/tmp/cc-socks/1.sock" from-name="peer-x"` and the body `note <id>: building` writes `heard`, and no CHECK-IN fires at `created + T` (backdate `created` past T, with the heard after it).
- **N2.** Neither address matches, but the body is `note <id>: …` for the open request: `heard` is written with `from` set to the row's `to_addr` and `request` set to `<id>`.
- **N3.** `note <unknown id>:` with no address match: no `heard`.
- **WA7 updated.** The new duplicate-start text, exit 0.
- **N7 (r3).** Set up a dispatch row with `to_addr = uds:/tmp/cc-socks/1.sock`. Its request file's frontmatter has `to_name: peer-x`. A member `peer-x` has an API-error turn end that triggers RESUME.
  - Then: one `heard` row with `from` set to `uds:/tmp/cc-socks/1.sock`, and no CHECK-IN before `resume + T`.
- **N7b.** The same, but the frontmatter has `to_name: null`: no `heard` row. The RESUME wake is still emitted.
- **N7c.** `to_addr = peer-x` (addressed by name) and `to_name: null`: `heard` is written, through rule 2.
- The existing recovery-watcher tests pass (`tests/test-recovery-watcher.sh`).

`tests/test-orchestrator-liveness.sh`:
- **N4.** An outstanding dispatch past T, with a `heard` row for its `to_addr` 1 minute old: no block.
- **N5.** The same with `heard` T+1 minutes old: block.
- **N6.** A nudge gate before `heard`, `heard` older than T, and no nudge after: block (the old nudge does not count toward the T/2 step).
- **T11 and T13** pass unchanged.

`tests/test-peer-progress.sh`: P5 passes unchanged.

The full suite (`run-suite.sh`) passes.

## 7. Assumptions to confirm while building

- **A1.** Dispatch rows carry the request id that the watcher prints as `request ${id}`. Rule 3 matches against that field. If a no-path row has no request id, rule 3 does not apply to it; report this rather than inventing an id.
- **A2.** `stripRef` applied to a `from=` socket address yields the same form that `posttooluse-peer-resolve.mjs` stores in `to_addr`. Check this with the existing helpers. If the forms differ, report it.

## 8. Open questions (defaults taken)

- **Q1.** Should a duplicate watcher start exit non-zero? Default: **no**. It exits 0 with explicit "nothing landed" wording, because a non-zero exit reads as a failure that someone will investigate.
