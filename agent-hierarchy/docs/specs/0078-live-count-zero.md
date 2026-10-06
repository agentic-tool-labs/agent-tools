# 0078 — Live members shown as gone: a session-end record written by a different process

Implementer: implementor
Reviewer: reviewer

Version: the next patch-or-minor above the stack tip when it lands (stacks after 0077). This is a bug in **released
code** (main 0.113.0, `hooks/sessionend-roster.mjs`). No open spec (0073–0077) touches that file or the liveness
path, so it can also land as a patch on main first; the Orchestrator picks. Bump
`agent-hierarchy/.claude-plugin/plugin.json` and the root `.claude-plugin/marketplace.json` together.

**Release split (r3, ruled):**
- **Part A, a hotfix on main, 0.113.1, on a branch off main:** §5.1, the §5.3 doc and tests S1–S7. It touches only
  `sessionend-roster.mjs`, its test, the docs, the CHANGELOG and the manifests. No open spec touches that file.
- **Part B, stacked on the stack tip after 0077:** §5.4 (`member_sessions`) and tests S8–S13, plus (r4) §5.6
  (self-heal) and tests S14–S21. `lib-status.mjs` is
  changed by 0075, 0076 and 0077, so B cannot land on main without conflicting with the stack.
- The stack PRs carry their own bumps above 0.113.1. Only the manifest and CHANGELOG top lines conflict.

Status: r3. The cause is ranked by reading; the deciding evidence (E1–E3) is read-only.

**Generic-text rule (binding).** Nothing written under this spec names a product, service, platform, customer,
ticket or incident.

## 1. Symptom

- At about 19:50Z the status went to `0 live`, with every member `live:false`. The open dispatches went `stalled`
  with `member-gone`.
- Meanwhile the multiplexer listed all three member agents, the client listed them live, and their processes were
  running (`ps`: up for about 6 h).
- At 13:01 the status was correct.

## 2. Facts (read; main = 0.113.0)

- **Liveness path.** `lib-status.mjs:181–183` → `attributedLiveness(roster, name)` (`lib-hier.mjs:963–966`).
  - It takes the member's **latest** roster record; `status === "down"` → not live.
  - Otherwise `recordLiveness` (l.946–957): `up` → `pidAlive(pid)`; `seen`/`briefed` → fresh for 30 min.
  - Status liveness never consults the multiplexer, by design (lib-status.mjs:13).
- **The roster is `<hier>/peers.jsonl`**, append-only. Its last records:
  - `up` records for each member (pids 99134, 90083, 62178; the latest at 18:51–18:55Z);
  - then **`down` for reviewer at 19:50:40.696Z, implementor at 19:50:42.318Z, architect at 19:50:45.846Z**: three
    separate writes, 1.6–3.5 s apart, each with the member's real session id and pid.
  - No `up` follows any of them. (A later `up` belongs to a different role.)
- **The only writer of `down`** is `hooks/sessionend-roster.mjs:29`, the SessionEnd hook. It writes for one session,
  in no loop.
  - It takes `role` from the latest `up` for the session.
  - It writes **`pid: up ? up.pid : process.ppid`**: the *registered* pid, not the ending process's own.
  - It does not check that the ending process is the registered one. There is no test of it in `tests/`.
- **All three registered pids are alive now.** Each session's activity record was written after its `down`
  (19:54–19:58Z). So the sessions never ended.
- **At the same minute,** the Implementor ran a sandboxed multiplexer probe (spec 0077 E3, response joi6).
  - It started an isolated server (its own socket and config paths).
  - Its own safety note: the sandbox server "restored the default session's saved workspaces from the user's saved
    session file". The isolated server was then killed.
- `roster.mjs teams` shows `team.file: null` **by design**: `sourcesField(dir, scope, null)`, and that verb never
  passes a team. It is not part of this bug.

## 3. Hypotheses (ranked)

| # | Hypothesis | For | Against / open |
|---|---|---|---|
| **H1 (most likely)** | The sandbox server restored the saved workspaces, which relaunched **copies** of the member sessions: the same session ids and the same cwd (the main checkout), so the same pool. Killing the sandbox server ended those copies. Each copy's SessionEnd hook wrote `down` for its session id, stamped with the *registered* pid (l.29), into the real `peers.jsonl`. | Three separate writes, seconds apart (one per copy shutting down); the real processes untouched; the timing matches the probe; the probe's own note on the restore; the `pid` field hides the true writer. | Not yet proven that the restore relaunched client sessions with their ids (E1, E2). |
| H2 | The real member sessions each fired SessionEnd without exiting (a client event that ends and continues a session). | It would also write via l.29. | Three sessions in different panes within 5 s, with no user action reported; no `up` after, though a continuing session normally re-registers at its next SessionStart; activity continued uninterrupted (E3 checks the transcripts). |
| H3 | A test or tool ran the hook against the real pool. | — | No test references the hook (gopher grep); the three records are spaced like separate processes. |

**Whichever of H1 or H2 it is, the defect is the same:** a SessionEnd from a process other than the registered one
can declare a live member gone, and the record then misreports the pid. The fix in §5 closes H1. Under H2, the
ending process *is* the registered one, so the fix would not change anything. That is why E3 matters.

## 4. NEEDS-EVIDENCE (Implementor, READ-ONLY; do not modify the main checkout's `.claude/hierarchy`)

- **E1. Did the restore relaunch member sessions?**
  - Read the user's saved-session file for the multiplexer (path from the joi6 note), read-only. For each saved
    pane, report whether it stores a launch command, and whether that command would resume a client session (a
    resume flag or a session id).
  - Redact any secret-looking argument. Report only the command shape (binary, flags, the presence of an id).
  - **Decides:** relaunch commands present → H1 is confirmed in mechanism. Absent → H1 is unlikely; go to E3.
- **E2. Timing.** From the joi6 work (its notes, shell history if captured, or the temp-dir timestamps if any remain),
  give the times the isolated server was started and killed. **Decides:** a kill within 19:50:40–46Z confirms H1.
- **E3. The member transcripts.** In each member session's transcript file under the client's project dir for this
  repo (`<session id>.jsonl`), list the entries timestamped 19:48–19:52Z, with only the type and timestamp.
  - A resume or start entry from a second writer, or an interleaved second conversation head, confirms H1.
  - A SessionEnd-like system entry in the real conversation, with normal turns after it, supports H2.

  Report the counts and the entry types only, never the content.

- (r3) E1 and E3 also report whether the copies fired **SessionStart**. If they did, report why they wrote no `up`
  (for example, no role in their environment). This grounds the §5.1 self-registering-copy ceiling.

If E1–E3 support H2 instead, stop **Part A (§5.1)** and report: the Architect amends §5.1 (an H2 fix keys on the
SessionEnd `reason`, not the pid). **Part B (§5.4) proceeds either way.** It is needed whatever the cause.

## 5. Fix (closes H1; harmless under H2)

### 5.1 `hooks/sessionend-roster.mjs`: only the registered process may mark its member gone

- Let `ender` be the ending client process's pid, derived **exactly as sessionstart.mjs derives the pid it registers**
  (it records `pid == ppid` of the hook). Reuse that derivation; do not invent another.
- Behaviour:
  - **No `up` record for the session:** write `down` as today, with `pid: ender`.
  - **An `up` record exists, and `ender === up.pid`:** write `down` (normal end).
  - **An `up` record exists, `ender !== up.pid`, and `up.pid` is alive** (`pidAlive`, reused from lib-hier): **write
    nothing.** A different process with this session id ended; the registered member is still running.
  - **An `up` record exists, `ender !== up.pid`, and `up.pid` is dead:** write `down` (the member really is gone;
    the record is housekeeping).
- **Every `down` record written records `pid: ender`** (the truth), never the registered pid.
- The hook still never throws, never writes stdout, and exits 0.
- **Ceilings (stated):**
  - pid reuse: if the registered pid died and was reused by an unrelated live process, a later stray SessionEnd is
    skipped. That is the same pid-reuse exposure `recordLiveness` already has for `up`.
  - A copy that runs *hooks* while alive (activity, prompts) still writes activity under the shared session id. That
    is out of scope, and only the activity text is affected.
  - **(r3) A copy that registers itself** (its SessionStart writes its own `up`) cannot be told apart from a restart.
    It becomes the registered pid, so the real member already shows dead once the copy dies, and its own SessionEnd
    then matches `ender === up.pid`.
    - **The fix covers only ending processes that never registered.** The observed incident had no copy `up`, so it
      is covered.
    - The upgrade path, if self-registering copies are ever seen: a SessionEnd skips when **any** earlier `up` for the
      same session id has a different pid that is still alive, and liveness considers every live registered pid for
      the session.

### 5.2 Recovery for the records already written (no code)

- The three wrong `down` records stay in the append-only log. A member stops being shown as gone at its next `up`
  record. That comes from SessionStart (for example its next compaction), or from `roster.mjs checkin` run in that
  member's session (the existing re-registration verb, roster.mjs ~7167).
- The Orchestrator tells the user this in plain words. **No one edits `peers.jsonl` by hand.**
- (r3) There is no self-heal: `live` returns only at a new `up` for each member. Until Part B ships, a falsely-down
  member's pane can still draw the orchestrator UI. A role without a shell (a peer whose tools exclude command
  execution) cannot run `checkin` itself. It recovers at its next compaction or restart, or when the user runs
  `checkin` in that pane.
- **NEEDS-EVIDENCE E4 (read-only):** confirm that `checkin` re-registers the *calling* session (how it resolves the
  session id and pid). If it cannot be run on behalf of a member from another session, say so. Recovery is then
  "at the member's next session start".

### 5.3 Probe hygiene (prevention; one paragraph in `docs/` where sandbox probes are described, or in the testing doc if one exists)

A sandboxed multiplexer server must not restore the user's saved session. Before starting it, point **every** state
path it reads at an empty temp dir: the socket, the config, **and the saved-session file**. After it starts, confirm
it lists zero panes, before anything else. Never kill a sandbox server that lists a pane the probe did not create:
stop and report instead. This applies to every future evidence item that starts a multiplexer server.

### 5.4 (r2, addendum) `member_sessions` must not depend on liveness

- **Observed side effect.** With the three members falsely `down`, status.json `member_sessions` held only one
  other session. So the mod treated the members' own sessions as non-member sessions, and drew the orchestrator UI
  (band, toasts, status entry) inside a peer's pane.
- **Ruling: live-only is the wrong rule.** `member_sessions` answers "is this session a team member?", which is an
  identity question, not a liveness one. A member session must never get orchestrator UI, whether it is live, down
  (falsely or not) or stale.
- **New rule** (lib-status, where `computeStatus` builds `member_sessions`): for every member of every team in the
  doc, take the `session_id` of **that member's latest roster record of any status** (`up`, `down`, `seen`,
  `briefed`). Include it if it is a non-empty string. Deduplicate.
  - Reuse the roster lookup `attributedLiveness` already does (`att.rec`), not a second scan. `describeMembers`
    already reads `att.rec.session_id` for every peer member (lib-status.mjs:183), regardless of `live`; use that
    value.
  - Pane-route members keep whatever they contribute today (unchanged).
- Why the latest record only: a restarted member's old session has ended, so it needs no exclusion, and the list
  stays bounded by the member count. A truly ended member's last session id stays listed; that is harmless, because
  that session no longer runs.
- `docs/status-file.md`: the `member_sessions` row says "the session id of each team member's latest roster
  registration, live or not".
- **Ceiling:** a role session that belongs to no team (an ad-hoc role launch) is still not listed, which is
  unchanged. The upgrade path: also include every session that has an activity record (activity.mjs runs only in
  role sessions).
- This change is independent of §5.1 and is needed even after it: any real `down`, or a stale `seen`, would
  otherwise expose a running member's pane to the orchestrator UI.

### 5.6 (r4, Part B; the Ultra-Advisor follow-on from 0079) Self-heal a false `down`

- **Problem.** Only SessionStart writes `up` (sessionstart.mjs:150–167). A running member whose latest row is a false
  `down` stays "gone" until it restarts or compacts, or someone runs `checkin` in its pane, and the member does not
  know it was marked down.
- **Rule.** In `hooks/activity.mjs` (it already runs in role sessions only, never in subagents), on
  **UserPromptSubmit and Stop only** (never PostToolUse), append an `up` row for this session when **all** hold:
  1. this session's latest roster row (by `session_id`) has `status: "down"`;
  2. the hook's client pid (derived exactly as sessionstart.mjs derives the pid it registers) **equals the pid of
     this session's latest `up` row**, so the healer is the registered process itself;
  3. that pid is alive (it trivially is: it is the caller).
- The row is built with the existing exported `upRecordFor` and appended with `appendRosterRecord`. It copies the
  team and pane fields from that latest `up`. There is no new record shape.
- **Relied-on facts (r5):**
  - **only SessionEnd (`sessionend-roster.mjs`) writes `down`**. If another `down` writer is ever added, this rule
    needs review;
  - condition 2 depends on `activity.mjs` running as a plain `node "${CLAUDE_PLUGIN_ROOT}/hooks/activity.mjs"`
    command, like sessionstart, so that the hook's parent is the client process. S22 pins both.
- **Why condition 2 (the interaction with 0078's cause).** A relaunched copy of the session (H1) has a different
  client pid. So a copy can never re-register itself through this path, and the self-registering-copy ceiling of
  §5.1 is not widened. The real member heals at its next prompt or stop.
- **Cost:** one roster read per prompt or stop in role sessions, and a write only in the rare `down` case.
- **Not done:** healing from PostToolUse (per-tool cost); healing a member with no prior `up` (nothing to copy;
  SessionStart owns first registration).
- **Tests** (Part B):

| Case | Expected | Test |
|---|---|---|
| latest row `down`, caller pid == the latest `up` pid, UserPromptSubmit | one `up` appended, with the same team and pane | S14 |
| the same on Stop | one `up` | S15 |
| latest row `down`, caller pid ≠ the latest `up` pid (a copy) | nothing appended | S16 |
| latest row `up` | nothing appended (no duplicate) | S17 |
| no `up` row for the session at all | nothing appended | S18 |
| PostToolUse with a `down` row | nothing appended | S19 |
| a subagent payload | nothing (activity.mjs already skips it) | S20 |
| an unreadable roster | no throw; exit 0; no stdout | S21 |
| (r5) hooks.json | `activity.mjs` is registered for UserPromptSubmit and Stop with exactly the plain `node "${CLAUDE_PLUGIN_ROOT}/hooks/activity.mjs"` shape (no shell wrapper), the same shape as sessionstart's; and a grep of `hooks/` finds `status: "down"` written only in `sessionend-roster.mjs` | S22 |

- Acceptance for Part B extends to S14–S21, with `activity.mjs` in the changed-file list.

### 5.5 Considered and not chosen

- **Read-side override** (treat `down` as live when the registered pid is alive and the activity is newer):
  - It would also hide real ends whose process lingers.
  - It touches the shared `attributedLiveness` used by the watcher and teams.
  - The writer fix removes the cause instead.
  - Upgrade path, if stray `down`s recur from another source: activity-newer-than-down as a read-side override.
- **Consulting the multiplexer for liveness in status:** lib-status is deliberately process-free (no spawning).

## 6. Must NOT change

- `attributedLiveness`, `recordLiveness`, lib-status liveness (`live` itself; only the `member_sessions` rule
  changes, §5.4), `sessionstart.mjs`'s registration, the roster format
  (append-only, same fields), `roster.mjs teams` output.
- SessionEnd for a normally ending member still writes `down` (H2-style real ends are unaffected).

## 7. Tests (new `tests/test-sessionend-roster.sh` or similar; sandboxed pool via the existing test-dir helpers)

| Case | Expected | Test |
|---|---|---|
| no `up` for the session; SessionEnd | one `down`, with `pid` = the ending process | S1 |
| `up.pid` = the ending process | one `down`, with that pid | S2 |
| `up.pid` = another **live** process (for example a sleeping child the test owns); SessionEnd | **no** new record; the member is still live via `attributedLiveness` | S3 |
| `up.pid` = a **dead** pid (a child the test spawned and reaped); SessionEnd from a different pid | one `down`, with `pid` = the ending process | S4 |
| no role resolvable (no `up`, no role env) | nothing written (as today) | S5 |
| an unreadable or empty roster | no throw; exit 0; no stdout | S6 |
| S3 then the status | `computeStatus` counts the member live; no `member-gone` stall | S7 |
| (r2) a member whose latest record is `down`, and its session is running | its session id **is** in `member_sessions` | S8 |
| (r2) a member whose latest record is `seen`/`briefed` older than the fresh window (not live) | its session id is in `member_sessions` | S9 |
| (r2) a member with no roster record, or whose latest record has a missing, empty or non-string `session_id` | contributes nothing; no throw | S10 |
| (r2) an Orchestrator (or any non-member) session with its own roster records, **while it is not a team member** | **not** in `member_sessions` (inherent: the rule is per team member) | S11 |
| (r2) a member restarted (old session `down`, then a new session `up`) | only the new session id; the list length is ≤ the member count | S12 |
| (r2) mod: a view whose `member_sessions` lists this session, while the member is `live:false` | no band, no toast, no status entry in that session (an existing mod path; the test pins the down case) | S13 |

Every test is seen failing at the base where new (S3 and S7 fail today; S4's pid field fails today). Any child process
a test spawns is killed and reaped before the test ends.

## 8. Acceptance

1. E1–E3 are recorded, and support H1, or else Part A stops (§4); Part B is unaffected. E4 is recorded.
2. S1–S13 are present and pass (Part A: S1–S7; Part B: S8–S13); they are seen failing first where new. The full ah suite and `claude plugin test` are
   green.
3. The §5.3 paragraph is added. The CHANGELOG is generic: "Fixed: a session-end from a process other than the
   registered one no longer marks a live member gone." Both manifests are bumped.
4. Only these change: `sessionend-roster.mjs`, `lib-status.mjs` (the `member_sessions` rule only, §5.4), their
   tests (S1–S13; S8 and S9 seen failing at the base), `docs/status-file.md`, the §5.3 doc, the CHANGELOG ("…; member
   sessions stay excluded from the orchestrator view while marked gone"), and the manifests.
