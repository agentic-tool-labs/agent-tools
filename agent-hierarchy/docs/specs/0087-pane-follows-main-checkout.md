# 0087 — The Pane always finds the viewer's own teams

Implementer: implementor
Reviewer: reviewer

Target: **0.125.0** (0.124.0 merges first). Base: `main` 310c881 (0.123.0). Branch `ah/0087-pane-main-checkout`.

## 1. Goal

The hierarchy Pane and band show the teams the viewing session owns. Two cases leave the Pane blank
("no team owned by this session") even though the session owns a live team. Close both:

- **Gap 1. A session that never wrote a session-pid row is never an owner.** `status.json` `owners[].sessions`
  come from `<hier>/session-pids.jsonl` rows whose `pid` equals a live team's `orchestrator.pid`, plus
  `orchestrator.session_id` when set (it usually is not: `roster.mjs` sets it only with `--session`).
  Rows are written only at SessionStart (`hooks/sessionstart.mjs:218`) and by `writeTeamFile`
  (`hooks/lib-roster.mjs:865`). A session started under a release without session-pids, and a team spawned
  by that release, have no row, and after `/reload-plugins` nothing ever writes one.
- **Gap 2. The Pane follows the cwd into a linked worktree.** `mod/register.tsx` `locate()` takes the
  nearest ancestor holding `.git` (file or dir) and re-locates whenever `$.session.cwd()` changes, so in a
  linked worktree it reads that worktree's `.claude/hierarchy/status.json`. Team files live in the main
  checkout's hierarchy dir (`docs/team-file.md`), but session-pids rows and `status.json` stay per pool,
  so the worktree's document has no owner for the viewer.

## 2. Contract

### 2.1 Gap 1: a session registers itself on every prompt

- On **UserPromptSubmit**, in any session that is not a subagent (`isSubagent(input)` false), the hook that
  already refreshes `status.json` on that event (`hooks/activity.mjs`) records the session's pid row through
  the existing `appendSessionPid` in `hooks/lib-status.mjs`, **before** it refreshes the status document,
  so the same prompt's refresh already lists the session as owner.
- Session id and pid come from the same sources SessionStart uses (`input.session_id`; the Claude pid as
  `sessionstart.mjs` takes it, `process.ppid`). If either is missing or invalid, nothing is written (the
  existing guards in `appendSessionPid`).
- Dirs: the pool dir `hierarchyDir(input.cwd)`, **and** `mainHierarchyDir(input.cwd)` when that is
  non-null and differs (§2.2). `appendSessionPid` keeps its rule of never creating a dir.
- SessionStart (`sessionstart.mjs:218`) writes to the same two dirs, by the same rule. `writeTeamFile`
  is unchanged.
- **Dedupe changes** (the file must not grow on every prompt): today a row is skipped only when it repeats
  the file's last row, so two sessions prompting alternately would append on every prompt. New rule: skip
  when the **newest row for this `session_id`** already has this `pid`. A new pid for a known session
  (resume in a new process) and a new session id (`/clear`, fork) still append. Readers are unchanged:
  `computeStatus` already scans rows newest first and dedupes.
- Members are not guarded out, deliberately: SessionStart already writes rows for member sessions today,
  and an owner group only takes rows whose `pid` equals a team's `orchestrator.pid`. A member session's
  pid is its own Claude process, never the Orchestrator's, so its row never joins an owner group. The
  mod also checks `member_sessions` before ownership (`mod/view.ts` `nullCause` order). This invariant is
  tested (§5), not re-implemented.
- Not done: writing `orchestrator.session_id` on team writes. Prompt registration covers the case, and
  that field is not needed for it (open question 1).

### 2.2 Gap 2: one status document per repo for the Pane, the main checkout's

- **Writers.** A session whose cwd is in a linked worktree also writes its session-pid row in the main
  checkout's hierarchy dir (§2.1) and refreshes that dir's `status.json` (`statusChanged(mainDir)`), so
  the main document lists it as owner whichever pool it started or prompts in. Nothing else about
  per-pool data changes: msgs, peers, gates and each pool's own `status.json` stay where they are.
- **Mod.** `locate()` keeps its walk to the nearest ancestor with `.git`. When that `.git` is a **file**
  of a linked worktree, it resolves the main checkout root exactly as `lib-config.mjs` `mainCheckoutRoot`
  does: read `gitdir: <path>` (relative paths resolve against the worktree root), read `<gitdir>/commondir`
  (relative to the gitdir), and take the parent of the common dir when its basename is `.git`. Anything
  else (no `commondir`, a submodule's `.git/modules/...`, unreadable, malformed) → no main checkout, and
  today's behaviour stands. The mod cannot import `lib-config`, so this is a mirror of one function; the
  shared test vectors (§5) pin the two to the same answers.
- **Which document the Pane shows** for a cwd inside a linked worktree with a main checkout `M`:
  1. `M/.claude/hierarchy/status.json` when it exists and is readable, **and** the viewer is a member
     there or is owned there (anything other than `nullCause` = `no team owned by this session`).
  2. Otherwise the worktree's own `status.json`, as today. This keeps a legacy team recorded in the
     worktree's own dir (still read in place, per `docs/team-file.md`) visible to its owner.
  The worktree document is read only when the main document gives "no team owned by this session" or
  is missing; both reads keep the existing mtime cache, so the common case adds no read per tick.
- Re-locate still happens only on a cwd change; `seenMtime`/`doc` reset as today for every file that
  changes.
- `AGENT_HIERARCHY_DIR` stays unfollowed by the mod (existing `ponytail:` note), and `mainHierarchyDir`
  already returns null when it is set, so writers do not double-write in that mode.

## 3. Files

- `agent-hierarchy/hooks/lib-status.mjs`: `appendSessionPid` dedupe rule (§2.1).
- `agent-hierarchy/hooks/activity.mjs`: prompt registration, both dirs, before the refresh; main-dir refresh.
- `agent-hierarchy/hooks/sessionstart.mjs`: the main-dir row and refresh.
- `agent-hierarchy/mod/register.tsx`: main-checkout resolution and the document choice (§2.2);
  `mod/view.ts` only if the choice needs `nullCause`/`scope` exported in another shape.
- `agent-hierarchy/docs/team-file.md`: session-pids rows are written to the pool **and** to the main
  checkout's dir; the Pane reads the main checkout's status first.
- Tests (§5), `tests/gen-mod-fixtures.mjs` / `mod/tests/vectors.ts` for the shared vectors.
- Version 0.125.0 in every place the plugin version lives today, with the changelog entry if one is kept.

## 4. Invariants and negative cases

Must not change: `status.json` schema and every field other than `owners`; `scope()` matching by session
id; `nullCause` strings and their order; a member session never sees an owner view; per-pool msgs,
peers, gates; `writeTeamFile`; non-worktree checkouts behave exactly as today.

| Input | Expected |
|---|---|
| Normal checkout (`.git` dir), session with an existing row | Unchanged: no new row on prompt (dedupe), same document |
| Same session prompts 100 times | Zero new rows |
| Sessions A and B prompt alternately, same pids | One row each, total; no growth after |
| Session resumed in a new process (same id, new pid) | One new row; owner resolves by the new pid |
| `/clear` (new id, same pid) | One new row |
| Subagent prompt (`agent_id` set) | No row |
| Member session prompts (roster-spawned, own pid) | Row may be written; it is in no `owners[].sessions`; Pane shows `member session` |
| Session with no row, no live team | Row written; `owners` unchanged (no team groups on its pid) |
| Missing/invalid session id or pid | No row, no error, prompt unaffected |
| Pool dir absent | Not created; nothing written there |
| Cwd in a linked worktree, viewer owns a team homed in main | Pane shows that team (main document) |
| Cwd moves main → worktree → main | Same teams shown throughout |
| Worktree whose main has no `status.json` | Worktree document, as today |
| Legacy team file in the worktree's own dir, viewer owns it and nothing in main | Worktree document; that team shows |
| Submodule (`.git` file, no `commondir`) | Nearest dir, as today |
| `.git` file unreadable or malformed | Nearest dir, as today |
| `AGENT_HIERARCHY_DIR` set | Writers: pool only (`mainHierarchyDir` null). Mod: as today |
| Hierarchy disabled (`enabled: false`) | `hierarchy off`, as today |

## 5. Verification (each new case fails on 0.123.0)

- `tests/test-status-owners.sh`:
  - **prompt registers**: live team with `orchestrator.pid` P, no session-pids row, `orchestrator.session_id`
    null; run the UserPromptSubmit hook with session S and Claude pid P → `owners[0].sessions` contains S
    after that single run. (a)
  - **no growth**: two sessions alternate 5 prompts each → exactly two rows.
  - **member never owner**: member session M with its own pid prompts → M in `member_sessions`, not in any
    `owners[].sessions`. (c)
  - **worktree prompt reaches main**: cwd in a linked worktree (real `git worktree add` in a `mktemp -d`
    sandbox) → row in both pools; main `status.json` owners contain S.
- `mod/tests/register.test.ts` (fixtures with a `.git` file, `gitdir`, `commondir`):
  - **worktree cwd shows main's teams** (b); **cwd moves main→worktree** keeps them;
  - **legacy worktree team** shows when main gives no ownership (d);
  - negatives: submodule, malformed `.git`, main without `status.json` → worktree document.
- Shared vectors: cases generated from `lib-config.mjs` `mainCheckoutRoot` (linked worktree, relative
  and absolute `gitdir`, submodule, normal checkout, malformed) consumed by the mod test, under the
  existing drift check `tests/test-mod-fixtures-drift.sh`.
- Full suite green; `bash tests/test-mod-plugin-test.sh` green.

## 6. Assumptions to confirm while building

- **The mod's `$.fs.read` can read a worktree's `.git` file and the main checkout's
  `commondir`/`status.json`** (paths outside the session's tree when a worktree lives elsewhere). The mod
  already reads `status.json` with it, but sandbox limits on other paths are unverified. If the mod test
  shows a refusal, stop and report; do not substitute `$.process.run(git ...)` without a ruling.
- The UserPromptSubmit hook's `process.ppid` is the Claude pid, as at SessionStart.

## 7. Open questions (defaults taken)

1. Also write `orchestrator.session_id` on every team write? **Default: no**; prompt registration covers it.
2. Keep the legacy worktree-team fallback (§2.2 step 2)? **Default: yes**; it costs one read only on a miss.
3. Bound or rotate `session-pids.jsonl`? **Default: out of scope**; the new dedupe stops prompt growth.
