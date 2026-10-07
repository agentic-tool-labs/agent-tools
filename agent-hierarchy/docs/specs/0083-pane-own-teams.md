# 0083: the Pane, band, status entry and toasts show only the viewing session's own teams

Implementer: implementor
Reviewer: reviewer

Status: r1 · Target: ah **0.121.0** (minor: visible behaviour change, plus an additive status.json key and a new pool file) · Base: main 7b0d813 (0.120.0)

## 1. Goal

When several orchestrators share one hierarchy pool (for example, two worktrees of one repo that fall back to the main checkout's pool), each orchestrator's mod shows **only the teams its own Claude process owns**. That covers:

- the Pane (sections, rows and clickable member names);
- the AbovePrompt band and its counts;
- the status-bar entry text;
- the toasts.

Other orchestrators' teams are **not shown at all**: no row, no count, no toast. This was the user's decision ("Only my teams").

This is a display filter, not an access control. status.json stays readable by every session in the pool.

## 2. Today (facts, with sources)

**What the producer writes** (`hooks/lib-status.mjs`)

- `computeStatus` (:373-416) iterates every live team in the pool (`[null, ...listTeamNames(dir)]`, kept when `teamIsLive(t, null)`, :388). It writes one pool-wide `status.json` (`saveStatus`, :420).
- The top-level `timeline` counts are pool-wide. `buildTimeline` (:358-370) is fed all members and dispatches concatenated across teams (:384-385, :413). `member_sessions` (:408) is pool-wide.
- status.json carries **no owner identity** at any level.
- status.json is written by any session's hooks (SessionStart, activity, roster writes, CLI). The writer is therefore not the viewer, so the filter must key on the viewer.

**Team files and ownership**

- Team files carry `orchestrator: {session_id, pid}`.
  - `pid` is the orchestrator's Claude process: `--orchestrator-pid`, else `CLAUDE_PID` (roster.mjs:5918).
  - `session_id` is null for every `newTeamRecord` team (spawn-one, spawn-ad-hoc, stream-open, roster.mjs:5113) and for `create --commit` without `--session`.
- `pid` is therefore the only owner key that is always present. It is also stable across `/clear` and compaction, which change the session id but not the process.
- A hook's `process.ppid` equals the Claude session pid, which equals `CLAUDE_PID` (established in earlier specs; `resolveTeamScope` relies on it).
- A team whose orchestrator pid is dead, or which is older than 24h, is already left out of status.json (`teamIsLive(t, null)` → `pidAlive && age <= TEAM_STALE_AGE_SEC`, lib-roster.mjs:1227-1232).

**What the mod can see**

- The mod can read only `$.session.id()` and `$.session.cwd()` about the viewer (register.tsx:74, :93). It has no pid and no environment.
- The readonly guard's `ALLOWED_CALLS` (tests/test-mod-readonly.sh) contains no pid or env call.

**What the mod consumes today**

- `current()` (view.ts:72-81) takes the timeline entry at `now`; a viewer listed in `member_sessions` gets null.
- The band (view.ts:216-240) reads that entry plus dispatches and members flattened across all teams.
- The Pane (view.ts:240, :253-260, :435) renders every team; `multi = teams.length > 1`.
- Toasts (view.ts:311-325) are derived from all teams' dispatches and members.

**SessionStart peer rows don't map pid to session id**

- SessionStart writes a peers.jsonl row (sessionstart.mjs:146-167) **only for role sessions** (`if (role)`, :119).
- The ordinary top-level orchestrator usually has no role, so peers.jsonl cannot supply the mapping from orchestrator pid to session id.

## 3. Design

Three parts:

- **(A)** Record which session ids belong to which Claude pid.
- **(B)** The producer groups live teams by owner pid and publishes each group's session ids, team keys and timeline.
- **(C)** The mod uses only the group that lists its own session id.

There is no new `$` call. Old readers keep working because the existing top-level keys are unchanged.

### 3.A Session record: pid → session ids

**Hook writer**

- `hooks/sessionstart.mjs`: for **every non-subagent session**, whether or not it has a role and on every `source` (startup, resume, clear, compact), append one row to a new append-only file `session-pids.jsonl`: `{ ts, session_id, pid: process.ppid }`.
- The file lives in the hierarchy dir that the status producer uses for this cwd. Reuse the producer's own dir resolution, not `ensureHierarchyDir(cwd)` on the worktree, so the row lands next to the status.json the mod reads.
- If that dir does not exist, write nothing, mirroring `saveStatus`. This hook must never create a hierarchy dir.
- Skip the write when `session_id` is missing.
- The write is best-effort: try/catch, and it never costs the SessionStart output.

**CLI writer**

- The team-writing CLI verbs (`create --commit`, and the verbs that call `newTeamRecord`: spawn-one, spawn-ad-hoc, stream-open, plus `adopt`) also append the same row.
- Do this only when `process.env.CLAUDE_CODE_SESSION_ID` is a non-empty string **and** the orchestrator pid they resolved equals `Number(process.env.CLAUDE_PID)`. An explicit `--orchestrator-pid` naming another process must not bind this session to it.
- This covers a session that started before the upgrade and so has no SessionStart row.

**One implementation**

- Exactly one append-row function. Both writers call it, and both use the existing locked or atomic append helper the other `.jsonl` files use.
- Prune `session-pids.jsonl` by the existing `sweep` / `SWEEP_DAYS` machinery in lib-hier.mjs, the same way the other append-only pool logs are pruned. Do not add a new pruning mechanism.

**Refresh**

- After the SessionStart row is written, the published status.json must reflect it before the hook exits. Use the existing `statusChanged` / `writeStatus` path. If `writeStatus` already runs later in the hook, ordering it after the append is enough.

### 3.B Producer: `owners` in status.json (`hooks/lib-status.mjs`)

Add one top-level key, `owners`: an array with one entry per distinct `orchestrator.pid` among the live teams the doc already lists.

Each entry:

| Field | Value |
|---|---|
| `sessions` | `string[]`. The distinct, non-empty `session_id` values of `session-pids.jsonl` rows whose `pid` equals this owner pid, plus each grouped team's `orchestrator.session_id` when it is a non-empty string. Newest first, capped at 32. May be `[]`. |
| `teams` | The `team` values of this owner's team objects, exactly as they appear in `teams[].team` (`null` for the default team, else the name). |
| `timeline` | The output of the **existing** `buildTimeline`, fed only this owner's teams' members and dispatches, with `anyPipeline` computed over only this owner's teams. Same entry shape as the top-level timeline. |

Rules:

- Every team object in `teams` appears in exactly one owner's `teams`.
- Do not write the pid itself. The mod cannot use it, and it is not needed.
- Unchanged: `schema` (stays `1`, because the key is additive and `parseDoc` validates only the keys it reads), the top-level `timeline`, `teams`, `member_sessions`, `enabled` and `expires_at`. Older mods, `roster.mjs status`, and any other reader of the top-level keys see exactly what they see today.
- `teamIsLive(t, null)` stays the live-team rule. Dead-owner (orphaned) and over-24h teams stay out of the doc, so they appear in no owner entry.
- Size: the doc must still respect `STATUS_SIZE_CAP` by whatever mechanism enforces it today. If no such enforcement exists beyond the reader's cap, see NEEDS-EVIDENCE E1.

Illustrative only:

```json
"owners": [
  { "sessions": ["sess-orch", "sess-orch-before-clear"], "teams": [null, "alpha"], "timeline": [ { "at": "...", "visible": true, "tone": "idle", "live": 2, "out": 0, "...": "..." } ] },
  { "sessions": ["sess-other"], "teams": ["beta"], "timeline": [ "..." ] }
]
```

### 3.C Mod: filter by the viewer's session id (`mod/view.ts`, types in `mod/types/index.d.ts` only if needed)

**Parsing**

- `parseDoc` keeps all current validation.
- If `owners` is **absent**, the doc is a legacy doc: behaviour is exactly as today (pool-wide). This is transitional, for status.json written by an older producer before its 24h expiry.
- If `owners` is present but not an array, treat it as an array with no usable entries.
- An entry is usable when:
  - `sessions` is an array of strings;
  - `teams` is an array whose items are strings or null;
  - `timeline` passes the same validation the top-level timeline gets today.
- Skip unusable entries.

**Selecting the viewer's own view.** Precedence, in order:

1. The viewer is in `member_sessions`: null, as today. A member session of any team in the pool never gets an orchestrator view.
2. A legacy doc (no `owners`): as today.
3. Pick the **first** usable owner entry whose `sessions` includes the viewer's session id. If there is none, there is no view:
   - `current()` returns null, so no status-bar entry, band, Pane rows or toasts;
   - `nullCause` reports a distinct cause, if it enumerates causes. The wording is generic, e.g. "no team owned by this session".
4. With an entry selected:
   - the timeline entry at `now` comes from that entry's `timeline`, not the top-level one;
   - the teams are the doc's team objects whose `team` value is in that entry's `teams`, kept in doc order;
   - everything downstream (`viewModel`: band, Pane sections, `multi`, headings, member focus; toasts; `keepSeen`; `statusText`) runs on that filtered team list and that entry, unchanged otherwise.

**Unchanged in the mod:**

- multi-team rendering, which still applies when one owner has more than one team;
- the band and idle-form logic from spec 0082;
- `bandLine`, `register.tsx`, the toast keys, and the auto-open rule (it keys on the view being non-null, so an orchestrator that owns nothing gets no auto-open);
- `ALLOWED_CALLS`, since no new `$` call is added.

## 4. Invariants and negative cases

**Must not change:**

- the top-level status.json keys and their meaning;
- `schema: 1`;
- `teamOwnedBy` / `teamIsLive` / `teamIsOrphaned` semantics;
- the team file shape (no new field in team files);
- peers.jsonl rows (no non-role rows are added there);
- the readonly guard;
- spec 0082's band behaviour for the viewer's own entry;
- byte-budgeted directive text (none is touched).

The rule "the viewer sees an owner entry's teams when its session id is in `sessions`" interacts with these inputs:

| Input | Expected |
|---|---|
| Viewer owns team A; team B is owned by another pid | Pane, band, toasts and status text show A only. B's members, dispatches, stalled/overdue items, reported toasts and blocked toasts are absent. Counts come from A's timeline. |
| Viewer owns nothing; other teams are live (and busy) | `current()` null → no status entry, band, Pane or toasts. |
| Viewer owns teams A and B (same pid) | Both are shown, `multi` headings as today, and counts cover both. |
| Viewer ran `/clear` (new session id, same pid) | Still sees its teams. The SessionStart row for the new id maps it to the same pid. |
| Orchestrator `--resume` in a new process (old session id, new pid) | The team's pid is the dead old process, so the team is already out of the doc (unchanged). |
| Viewer is in `member_sessions` and also listed in an owner's `sessions` | null (member check first, as today). |
| Team whose orchestrator pid is dead (orphaned), or a legacy team with no `orchestrator.pid` | Not in status.json today, so in no owner entry and shown to nobody (unchanged). |
| Live team with no session rows for its pid and no `orchestrator.session_id` (orchestrator predates the upgrade and created the team before it) | It is in an owner entry with `sessions: []`, so it is shown to nobody. See §8 Q1. |
| Default (`null`) team | Grouped by its `orchestrator.pid` like any named team; it appears in `teams` as `null`. |
| `--orchestrator-pid <other>` given to a team-writing CLI | No session row is written for the caller. |
| `session-pids.jsonl` row whose pid matches no live team | Ignored by the producer. |
| A recycled pid: an old row for a dead session, with the same pid as a new live owner | The old session id joins the new owner's `sessions`. This is harmless: the dead session cannot view. |
| Doc without `owners` (older producer) | Pool-wide, exactly as today (pin). |
| `owners` present but not an array, or every entry malformed | No owner match → null view. |
| Subagent SessionStart | No row is written. |
| Repo with no hierarchy dir | SessionStart creates nothing and writes nothing. |
| `owners` timeline entry `visible: false` for the viewer's group | null view (same rule as today's `visible`). |

## 5. Tests

**Producer** (`tests/`, alongside the existing status tests; use a live pid such as the test shell's own for "alive" owners, as the existing liveness tests do):

- Two live teams with different owner pids, plus session rows for each:
  - `owners` has two entries with the right `sessions`, `teams` and per-owner timeline counts;
  - the top-level `timeline` is still pool-wide and byte-identical to what it was before the change for the same input.
- Two rows for one pid (a `/clear`): both session ids, newest first.
- A default team and a named team with the same pid: one entry with `teams: [null, "name"]`.
- A team with no rows and no `orchestrator.session_id`: `sessions: []`.
- `orchestrator.session_id` set on the team file: it appears in `sessions`.
- SessionStart:
  - in a top-level non-role session, writes a row (session id, `pid` = hook ppid) into the producer's dir;
  - writes nothing for a subagent;
  - writes nothing when the hierarchy dir is absent, and creates no dir.
- CLI verb with `CLAUDE_PID` matching: a row is written. With `--orchestrator-pid` naming another pid: no row.

**Mod** (`mod/tests/view.test.ts`). Each test below must fail against base `view.ts`; say so in the report.

- Foreign team hidden:
  - from the Pane rows (no name, no clickable member);
  - from the band (a foreign stalled dispatch does not appear; counts come from the viewer's entry);
  - from the toasts (a foreign reported dispatch and a foreign blocked member raise no toast);
  - from the status text.
- The viewer owns nothing → `statusText`, `bandLine` and the Pane all null or empty; no toasts.
- The viewer owns two teams → both are rendered with multi headings.
- A member session listed in an owner's `sessions` → null.
- `owners` not an array → null view.
- Pin: a doc without `owners` → unchanged pool-wide output. The existing tests already cover this; keep them as they are.

**Fixtures**

- `tests/fixtures/status/*.json` and the generated `mod/tests/fixtures.ts` (regenerated via `tests/gen-mod-fixtures.mjs`; `tests/test-mod-fixtures-drift.sh` must pass).
- The fixtures must gain `owners` listing their viewer `sess-orch` as owner of the fixture teams, so every existing `mod/tests/vectors.ts` expectation stays identical.
- Add one fixture/vector `foreign`, in which `sess-orch` owns nothing while a busy team is live, with an all-null expectation.
- Any change to an existing vector's expected output is a defect: stop and report.

**Gates:** run the full suite, `tests/test-mod-readonly.sh` (unchanged list) and the fixture drift test. All green.

## 6. Version and docs

- `agent-hierarchy/.claude-plugin/plugin.json` and the repo-root `.claude-plugin/marketplace.json` (agent-hierarchy entry) → `0.121.0`.
- `CHANGELOG.md`: one entry. The Pane, band, status entry and toasts show only the viewing orchestrator's own teams; status.json gains `owners`; a new pool file `session-pids.jsonl`.
- `docs/status-file.md`: document `owners` (its fields, the one-owner-per-team rule, and that the top-level keys are unchanged and pool-wide) and how the mod selects an entry.
- Document `session-pids.jsonl` wherever the pool files are listed. Grep `agent-hierarchy/docs/` and `agent-hierarchy/README.md` for the list of pool files.
- `README.md`, in the Pane/band section: one sentence saying the Pane shows only the teams this session's orchestrator owns.
- Docs stay generic: no ticket, customer or user-report wording. No byte-budgeted directive text changes. If any doc under a size test grows past its budget, raise the budget rather than cutting contract text.

## 7. Decisions made

- **The mod filters; the producer tags.** The file is pool-wide and written by any session, so only the viewer can filter. The mod knows only its session id, so the producer must publish session ids per owner. No new `$` call is needed, so the guard stays as it is.
- **Owner key = orchestrator pid, mapped to session ids through a new SessionStart record.** The pid is always present in team files and survives `/clear`. The team file's `session_id` is usually null and goes stale on `/clear`. peers.jsonl rows exist only for role sessions and carry peer semantics, so they are not reused.
- **Per-owner timelines come from the existing `buildTimeline`**, so there is one implementation of counts, text and tone. The mod does not recount.
- **The top-level keys are unchanged, `schema` stays 1, and a legacy doc keeps pool-wide behaviour.** This means no reader breaks, and the legacy path is transitional only (24h expiry).
- **The member check stays pool-wide and first.** A session that is a member anywhere in the pool is never an orchestrator viewer.
- **Orphaned and stale teams stay hidden from everyone.** This is unchanged: they are already out of the doc.
- **Minor release (0.121.0), not a patch.** The change alters what users see and adds a status.json key and a pool file.

## 8. Open questions (user's call; defaults chosen, buildable as written)

- **Q1.** A live team whose owner has no recorded session id is hidden from everyone (strict). This happens only for an orchestrator started before the upgrade that also created its team before the upgrade. It repairs itself on that orchestrator's next `/clear` or session start, or on a new team-writing CLI call. Alternative: show such a team to every viewer, as today. Default: strict, matching "only my teams".
- **Q2.** An orchestrator that owns no team sees no status-bar entry, even while other orchestrators' teams are busy. Default: as written.

## 9. NEEDS-EVIDENCE

- **E1.** Does anything today keep the written status.json under `STATUS_SIZE_CAP` (`hooks/lib-status.mjs`), and what happens over the cap? The Implementor should grep `STATUS_SIZE_CAP` and report its uses.
  - If the cap is enforced (for example by truncation), the per-owner timelines go under the same enforcement, with no further design needed.
  - If it is not enforced, report back before building: the extra timelines need a decision on what to drop first.
- **E2** (confirm while building, not blocking). Is `writeStatus` in `hooks/sessionstart.mjs` called after the point where the new row is appended? If not, the row append must trigger the existing refresh path (§3.A, Refresh).
