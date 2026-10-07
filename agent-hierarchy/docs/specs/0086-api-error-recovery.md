# 0086 — Recover from API-error turn ends

Implementer: implementor
Reviewer: reviewer

Revision: r3. It closes review 20261007-194048-9t53: B1, S1, N1 and N2. Changes are marked **r3**.

Target: 0.124.0. Stacks on `ah/0085-peers-never-stuck` (worktree `.claude/worktrees/0085`). It reuses 0085's watcher changes: the watcher checks every live member of owned teams, and it keeps running while any owned team has a live member.

## 1. Goal

A turn that dies on an API error (for example "API Error: Connection lost mid-response") currently leaves the session idle with no report, and nothing wakes anyone until the ETA watcher fires. After this change:

- **Detect:** an API-error turn end is recorded as its own activity state, `failed`, with the error kind. It is distinguished from a normal end (Stop) and from a user interrupt (no hook fires).
- **Recover:** the session is resumed automatically with a "re-check state, then continue" prompt. The backoff (§3.2) is 30 s, 2 min and 8 min, or 2 min, 8 min and 20 min for `rate_limit` (**r3**, N2). There is a cap of 3 resumes per failure streak.
- **Escalate:** when the cap is reached, or the error is not retryable:
  - a member's failure goes to the Orchestrator, which tells the user;
  - the Orchestrator's own failure goes to the user as a desktop or terminal notification.

## 2. Facts (Claude Code 2.1.293)

- **`StopFailure`.**
  - Fires **instead of** Stop when an API error ends the turn.
  - Payload: `BaseHookInput` + `error` (enum), `error_details?` and `last_assistant_message?` (types d.ts:12041).
  - `error` values: `authentication_failed`, `oauth_org_not_allowed`, `account_on_hold`, `verification_required`, `billing_error`, `rate_limit`, `overloaded`, `invalid_request`, `model_not_found`, `server_error`, `unknown`, `max_output_tokens`, `cloud_credential_error` (d.ts:10388). Types say `rate_limit`, `overloaded` and `server_error` "may clear on their own" (d.ts:6045).
  - Output and exit code are ignored, **except `terminalSequence`, which still executes** (hooks docs, code.claude.com/docs/en/hooks).
- **User interrupt (Esc)** fires neither Stop nor StopFailure (hooks docs).
- **agent-hierarchy today** wires no StopFailure hook.
  - `activity.mjs` maps `UserPromptSubmit→working`, `Stop→idle`, `Notification(permission_prompt)→blocked` (lib-hier.mjs:53), and records only sessions with a persisted role.
  - So an API-error end leaves the record at `working`.
- **Dispatch watcher.** `hooks/dispatch-watcher.mjs` is one per Orchestrator session (started with `--session`) and polls every 15 s. It wakes its session by printing and exiting 3; the background-task exit starts a turn in an idle session. It writes typed `watch-event` rows.
- **Claude members are resumed only by SendMessage.** `roster.mjs deliver` is for non-Claude panes (`paneMemberOrFail`, roster.mjs:5366).

## 3. Design

### 3.1 Where it lives (decision)

- **Detection** is a classic hook, so it works with or without the mod.
- **Resume and escalation** go through the dispatch watcher. It is a process that is already alive, already owns "wake the Orchestrator", and already reaches Claude members via the Orchestrator's SendMessage.
- **Not used:**
  - The mod (`$.prompt.submit` / `turn.complete reason:'error'`). Its timers die on a module reload, and every new `$` call needs a mod-guard entry (`tests/test-mod-readonly.sh`).
  - `asyncRewake`. Whether it is honoured on StopFailure, and whether it wakes an idle session, is undocumented. §9 E2 records it as a possible later shortcut, not part of this build.

### 3.2 Detection: a StopFailure hook

- **Wiring.** Add one `StopFailure` entry (no matcher, all error kinds) to `hooks/hooks.json`. It runs a new `hooks/stopfailure-recovery.mjs`, or a `StopFailure` branch in `hooks/activity.mjs` if that is the smaller diff. Either way, the record is written through `recordActivity` (lib-status.mjs:119): one writer.
- **Which sessions.** It records for every **non-subagent** session (empty `agent_id`) whose cwd resolves to a hierarchy dir, the same resolution activity.mjs uses.
  - Unlike activity.mjs, it does **not** require a persisted role. The Orchestrator is often a plain session, and the watcher must see its own session's failure.
  - **r3 (B1) — activity.mjs follows the record.** Today `hooks/activity.mjs:35` records only sessions with a persisted role (`readSessionRole`). A role-less session's `failed` record would therefore never be updated by UserPromptSubmit, Stop or PostToolUse. The result: a stale RESUME after the user has already typed; the display streak never cleared; and a dead §3.2b backup for the own session, because `transcript_path` and `activity` never move.
    - New gate in activity.mjs: record the event when the session has a persisted role (as today) **or** an activity record already exists for its subject in the resolved hierarchy dir.
    - It applies to non-subagent sessions only.
    - A role-less session with no record stays unrecorded, as today. Only a session that StopFailure has already recorded is followed.
    - `sweepActivity`'s existing staleness rule removes such records, as it removes any other.
  - Subagent API errors surface to their parent as a tool result. They are ignored here.
- **Record fields**, added to the existing activity record:
  - `activity: "failed"`
  - `error`: the enum value, or `unknown` when missing or not a known value.
  - `error_details`: sanitised to one line, control characters stripped, ≤300 chars.
- **r2 — two payload spellings.** The hooks docs name the fields `error_type`, `error_message` and `error_code?`. The 2.1.293 d.ts names them `error` and `error_details?`. Read the kind from `error ?? error_type` and the details from `error_details ?? error_message`, and keep `error_code` in the record when it is present. Test both spellings.
- `source: "stopfailure"`. The §3.2b detector writes `source: "transcript"`.
  - `failed_at`: ISO time.
  - `streak`: **r3 (S1) — derived from the resume history, not carried on the record.** `streak = 1 + the number of RESUME `watch-event` rows for the same subject emitted within `STREAK_WINDOW` before `failed_at``. `STREAK_WINDOW` is 45 min: longer than the longest full backoff (rate_limit 2 + 8 + 20 = 30 min) plus turn time. One function in `hooks/lib-recovery.mjs` computes it, and both the StopFailure hook and the §3.2b detector call it. It counts distinct RESUME emissions, so two rows for the same `(session, failed_at)` count once.
  - Why: when Stop fires instead of StopFailure (§3.2b), a carried counter is reset by that Stop. The next failure is then streak 1 again, giving no cap and a resume loop about every 30 s. No hook path can reset a count of RESUMEs already emitted. The tradeoff is accepted: a session that recovers and then fails again within 45 min starts at a higher streak, with a longer delay and fewer retries.
- **Streak field on the record.** A **Stop** still sets the record's `streak` to 0, or drops it. UserPromptSubmit and PostToolUse carry it unchanged. **r3:** that field is now display only. The cap and the delay always use the derived value above.
- **Retryable** = `server_error`, `overloaded`, `rate_limit`, `unknown`. Everything else escalates immediately and is never resumed: `authentication_failed`, `oauth_org_not_allowed`, `account_on_hold`, `verification_required`, `billing_error`, `invalid_request`, `model_not_found`, `max_output_tokens`, `cloud_credential_error`, and any value not on this list other than `unknown` itself (a missing kind is recorded as `unknown`).
- **r2 — backoff by kind.** `rate_limit` waits longer: 120 s, 480 s, 1200 s. The other retryable kinds wait 30 s, 120 s, 480 s. The cap is 3 for every kind. One table holds both rows, and §3.3 reads it.
- **`terminalSequence` notification.** Emitted only when this session is an **Orchestrator** (it owns a team, by main's ownership test, or its persisted role is orchestrator), and either:
  - the error is non-retryable, or
  - `streak` > 3, or
  - no dispatch watcher is alive for this session (the watcher-alive test `stop-orchestrator-liveness` already uses).

  The output is one OSC 9 desktop notification plus BEL, text `ah: <session label> stopped on an API error (<error>)<, after 3 retries>. Open it to continue.` The text is ASCII, ≤120 chars, with no control characters and no `;` injection. In all other cases there is no output.
- The hook never blocks or delays. It fails open: on any error it exits 0 silently.

### 3.2b Second detector: the transcript (r2)

StopFailure may not fire for every API-error end. It may be missed, Stop may fire instead, or a mode may skip it. The watcher therefore also detects from the transcript, so a missed StopFailure still recovers.

- **Transcript path.** The activity record keeps `transcript_path` from any hook payload it records, starting with UserPromptSubmit, Stop and StopFailure. The watcher uses it only if it is absolute, ends `.jsonl`, and its realpath is under `~/.claude/projects/`. Otherwise this detector skips the session.
- **When to look.** Only when all of these hold:
  - the record's `activity` is `working` or `idle`;
  - the record has not changed for ≥45 s;
  - the transcript's (mtime, size) changed since the watcher last looked, or it has never looked. Cache per session, so an idle session is not re-read every poll.
- **What counts.** Read at most the last 64 KB. Take the **last entry whose `type` is `assistant` or `user`**, skipping `system` and attachment rows and side-chain rows (`isSidechain: true`) (**r3**, N1, matching the build). Partial or invalid lines are skipped.
  - It is an API-error end when that entry is an assistant entry flagged as an API-error message: the flag field E4 confirms, e.g. `isApiErrorMessage: true`.
  - Or, only if E4 finds no flag, when its text content starts with the harness prefix `API Error:`.
  - Anything after it (a user entry such as an interrupt or typed text, a tool result, another assistant entry) means it is not the last entry, so it does not count.
- **Effect.** Write the same `failed` record as §3.2, through the same `recordActivity`, with:
  - `source: "transcript"`
  - `error`: parsed from the entry when E4 shows a kind field, else `unknown`
  - `failed_at`: the entry's timestamp
  - `streak`: the same derived rule as §3.2 (**r3**)

  From there §3.3 and §3.4 apply unchanged: one recovery path.
- **Dedupe with StopFailure.** If the record is already `failed` it is not `working`/`idle`, so this detector does nothing. If StopFailure fires later for the same end, its `failed_at` is within a few seconds of the transcript's. Treat a StopFailure whose `failed_at` is within 10 s of a `source: "transcript"` record's as the same failure: update `error` and `source`, keep `streak`, do not increment.
- This detector never sends the `terminalSequence` notification, because it runs in the watcher, not in a hook. For the Orchestrator's own session, a transcript-detected API-FAILED is a watch-event row only. The README notes this limit.

### 3.3 Resume (watcher event `RESUME`)

On each poll the watcher examines its **own session's** record and every owned live **Claude** member's record. Non-Claude kinds fire no Claude hooks and are not covered.

- A record qualifies when all of these hold:
  - `activity === "failed"`
  - the error is retryable
  - `streak ≤ 3`
  - `now ≥ failed_at + delay(error, streak)`, from the §3.2 backoff table (r2)
  - no RESUME has been emitted yet for `(session, failed_at)`. Persist this dedupe like the existing check-in state, so a restarted watcher does not resume twice.
- The record is re-read at fire time. If it is no longer `failed` with the same `failed_at`, nothing happens. Someone typed, or the session recovered.
- **Own session:** print and exit 3. Illustrative:
  ```
  ah watcher: this session's last turn ended on an API error (<error>) at <hh:mm:ss>; automatic resume <n>/3.
  Continue the interrupted task. First re-check state: re-read any file you were changing, and for anything with side effects (push, merge, send, close, delete) confirm whether it already happened before doing it again. If you were mid-report, finish and send the report.
  ```
- **Member:** print and exit 3. The text tells the Orchestrator to SendMessage the member the same resume paragraph, with `n/3`, verbatim.
  - The Orchestrator does nothing else for it: no re-brief, and no ETA reset.
  - The member's SendMessage-started turn is a UserPromptSubmit. **r3:** the cap no longer depends on that, because it counts RESUME rows (§3.2).
- A RESUME for a member also counts as "heard from" for the existing CHECK-IN/SILENT clock, so the ETA watcher does not double-nudge.

### 3.4 Escalate (watcher event `API-FAILED`)

Emitted once per `(session, failed_at)` when the record is `failed` **and** either the error is non-retryable or `streak > 3`.

- **Member:** wake the Orchestrator with `ah watcher: <role> "<name>" stopped on an API error (<error>: <error_details>)<, after 3 automatic resumes>. Not resuming. Tell the user in one line; resume it only when the user says so.`
- **Own session:** **no wake.** Waking a session whose API is failing only fails again. The §3.2 `terminalSequence` notification is the user's signal. The watcher records the `watch-event` row only.

### 3.5 Orchestrator text

Add one short paragraph to `agents/orchestrator.md` and to the agent-team skill's watcher-events section:

- RESUME for a member: relay the resume paragraph verbatim with SendMessage.
- RESUME for itself: follow it.
- API-FAILED: tell the user, and do not resume.

## 4. Never auto-resume when

- **The user interrupted.** No hook fires, so no `failed` record exists.
- **A permission denial** ends the turn normally, with Stop, so there is no `failed` record.
- **A blocked or destructive prompt.** The state is `blocked` (0085), not `failed`.
- **The record changed** after `failed_at`: someone typed, the session worked or idled.
- **The error is non-retryable**, or the cap is reached.
- **A subagent** (`agent_id` set) or a non-Claude member.

## 5. Invariants and negative cases

Must NOT change:
- Stop, UserPromptSubmit and Notification activity semantics, apart from:
  - Stop clearing the display `streak`;
  - **r3** activity.mjs also following a role-less session that already has a record (§3.2 B1).
- The LANDED, CHECK-IN, SILENT and BLOCKED events and their text.
- The watcher's poll interval, exit-3 wake, orphan exit and 12 h exit.
- `deliver` and `answer`.
- The mod. No mod file changes; the mod-guard test is untouched.

| Input | Expected |
|---|---|
| StopFailure `overloaded`, member, streak 0 before | record failed, streak 1; RESUME after ≥30 s, once |
| Same, poll at 20 s | nothing |
| Resume turn fails again (`server_error`) | streak 2; RESUME after ≥120 s |
| Resume turn then ends normally (Stop) | streak cleared; no event |
| 4th consecutive failure | API-FAILED once; no RESUME |
| StopFailure `billing_error` / `authentication_failed` / `invalid_request` / `model_not_found` / `max_output_tokens` | API-FAILED immediately; never RESUME |
| StopFailure with missing `error` | `unknown` → retryable |
| StopFailure with a kind not in §3.2's list (a future value) | escalate, never resume (r2) |
| StopFailure `rate_limit`, streak 1 | RESUME after ≥120 s, not 30 s (r2) |
| Payload uses `error_type`/`error_message` (docs spelling) | recorded the same as `error`/`error_details` (r2) |
| Record `working`, unchanged ≥45 s, last transcript entry is an API-error assistant entry | `failed`, `source: "transcript"`, then the normal RESUME path (r2) |
| Record `idle` (Stop fired), last entry is an API-error entry | same: `failed` via transcript (r2) |
| Last entry is the user's interrupt or typed text after an API-error entry | no detection (r2) |
| Last entry is a normal assistant reply that merely quotes "API Error:" mid-text, with no flag | no detection when E4 finds a flag; with the prefix fallback, only text that *starts* with the prefix counts (r2) |
| Transcript path outside `~/.claude/projects/`, relative, or a symlink escaping it | detector skips the session (r2) |
| Transcript unchanged since the last look | not re-read (r2) |
| Transcript detection, then StopFailure 3 s later for the same end | one failure: streak unchanged, error updated (r2) |
| Record failed, then the user types (UserPromptSubmit → working) before the delay | no RESUME |
| User Esc mid-turn (no hook) | record stays working; no event |
| Normal Stop | idle; no event |
| Subagent StopFailure (`agent_id` set) | nothing recorded |
| Non-owned team's member failed | ignored |
| Watcher restarted after emitting RESUME for the same failed_at | no second RESUME |
| Own session failed, retryable, streak 1 | watcher exit 3 with the own-session text after ≥30 s |
| Own session API-FAILED | no wake; watch-event row only; the hook emitted terminalSequence |
| Orchestrator StopFailure, no watcher alive | terminalSequence notification on the first failure |
| Member StopFailure (not an Orchestrator) | no terminalSequence |
| `error_details` with ANSI, newlines or >300 chars | sanitised and capped in the record and the texts |
| Hook throws internally | exit 0, no output, the session is unaffected |
| **r3 (B1)** Role-less session: StopFailure `overloaded`, then UserPromptSubmit before the delay | record → `working`, `transcript_path` updated; **no RESUME** |
| **r3 (B1)** Role-less session with no activity record: UserPromptSubmit / Stop / PostToolUse | nothing recorded (unchanged) |
| **r3 (B1)** Role-less session after a StopFailure, then Stop | record `idle`; display streak cleared |
| **r3 (S1)** Stop clears the display `streak` on the record | yes; the next failure's streak still counts earlier RESUMEs within 45 min |
| **r3 (S1)** Stop (not StopFailure) + API-error transcript entry, four times in a row with resumes between | streaks 1, 2, 3, 4 → RESUME ×3, then **API-FAILED** once; no fourth RESUME |
| **r3 (S1)** Failure 50 min after the last RESUME | streak 1 (outside the window) |
| **r3 (S1)** Two RESUME rows for one `(session, failed_at)` (watcher restart race) | counted once |
| **r3 (N1)** Last row is a `system` or side-chain entry after an API-error assistant entry | detected (those rows are skipped) |

## 6. Tests

`tests/*.sh`, in the existing style: HOME-redirected sandbox, hooks driven by stdin JSON, and a watcher test with a fake clock/poll override if one exists. Otherwise add a test-only env override, as in 0085.

- `tests/test-stopfailure-recovery.sh`:
  - record fields for each error class;
  - the streak increment, the carry through UserPromptSubmit/PostToolUse, and the reset on Stop;
  - subagent ignored;
  - terminalSequence present or absent per §3.2, plus its sanitising;
  - fail-open.
- Watcher test additions: every §5 watcher row, including the dedupe-after-restart row and "record changed before delay".
- r2: transcript-detector cases use fixture JSONL files under the sandbox HOME's `.claude/projects/`. The API-error entry fixture copies the **shape E4 recorded**. Also cover the interrupt-after-error fixture, the prefix-mid-text fixture, the path-escape symlink, and the StopFailure-after-transcript merge.
- **r3, named regression tests:**
  - `role-less StopFailure, then UserPromptSubmit → working, no RESUME` (B1);
  - `role-less session without a record stays unrecorded` (B1 negative);
  - `Stop clears the display streak` (S1);
  - `Stop + API-error entry ×4 → API-FAILED` (S1, transcript-detected failures with RESUMEs between them; asserts exactly three RESUMEs);
  - `failure outside STREAK_WINDOW → streak 1` (S1 negative);
  - `system/side-chain rows after the error entry are skipped` (N1).
- Full suite green; report the count.

## 7. Release

- Bump `agent-hierarchy/.claude-plugin/plugin.json` and the root `.claude-plugin/marketplace.json` to 0.124.0 together.
- CHANGELOG entry.
- README: one paragraph, "Recovery from API errors": detection, backoff 30 s/2 min/8 min, cap 3, escalation, and that non-Claude members are not covered.
- `docs/status-file.md`: the `failed` activity state and its fields.
- Docs stay generic.

## 8. Decisions

- **Made:**
  - A classic hook detects; the watcher resumes and escalates (§3.1).
  - Retryable set: `rate_limit`, `overloaded`, `server_error`, `unknown`.
  - Backoff 30/120/480 s (`rate_limit`: 120/480/1200 s, r2) and cap 3, all constants with no config key (add one when someone needs to tune them).
  - r2: a transcript detector backs up StopFailure (§3.2b), and both feed one recovery path.
  - The Orchestrator's own cap or non-retryable failure is a terminal notification, not a wake.
- **User's call (default applied):**
  - Resume is automatic with no confirmation.
  - The resume text tells the agent to re-check side effects before repeating them. It cannot guarantee that the agent will.
- **Refused:**
  - The mod path and `asyncRewake` for this build.
  - Resuming non-Claude members.

## 9. NEEDS-EVIDENCE (Implementor, before code; sandbox-safe, read-only where possible)

- **E1 (r2: post-ship, non-blocking).** Which `error` does a real connection drop carry? The §3.2b detector covers a missed StopFailure, so this no longer blocks the build.
  - After ship, at the first real "Connection lost" in any session, read that session's activity record. It shows `source` and `error`.
  - Report the observed kind, and whether StopFailure fired (`source: "stopfailure"`) or only the transcript caught it.
  - If the kind is non-retryable, I amend the retryable set.
  - Before ship, also read any existing debug logs (`~/.claude/debug/`, read-only) for an earlier occurrence, and report what they show, or "none found".
- **E4 (r2, before the §3.2b code; read-only).** Read the transcript JSONL of a session that ended on "API Error: Connection lost mid-response". Today's incident session is a candidate; find it under `~/.claude/projects/` by grepping for that text.
  - Report the exact last entry's shape with content redacted: `type`, the flag field name and value (e.g. `isApiErrorMessage`), any error-kind field, the text prefix, `timestamp`.
  - A flag exists → detect by the flag only.
  - No flag → detect by the text prefix only, as §3.2b says.
  - Also report whether the transcript shows an interrupt entry (`[Request interrupted by user]` or similar) after an Esc. That is the negative fixture's shape.
- **E2 (non-blocking, follow-up only).** Is `asyncRewake` honoured on a StopFailure hook, and does it wake an idle session? Record the answer from docs or source only. If yes, a later spec may move member self-resume off the Orchestrator.
- **E3 (non-blocking).** Is `terminalSequence` accepted from a StopFailure hook command's stdout JSON, and in which field shape? Docs or source. If not accepted, drop the notification and report. The Orchestrator then gets no self-escalation beyond the watcher row, and I will amend.
