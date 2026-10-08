# 0087 — The Pane always finds the viewer's own teams

Implementer: implementor
Reviewer: reviewer

Target: **0.125.0** (0.124.0 merges first). Base: `main` 310c881 (0.123.0). Branch `ah/0087-pane-main-checkout`.

Status: **r2**. Changes from r1: the Pane prefers the pool document when it lists the viewer (§2.2);
the main-checkout lookup mirrors `lib-config` including its no-`commondir` fallback (§2.2); new gap 3,
Codex's idle composer as Codex 0.162 draws it (§2.3).

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
- **Gap 3. A Codex member never receives a brief.** `deliver` (and spawn) check the screen with
  `isComposer` (`hooks/lib-roster.mjs`) before typing. Codex 0.162 draws its idle composer with a
  two-line footer, and sometimes no padding row between the prompt row and the footer, so the check
  fails, the re-read fails too, and `composerOrPrompt` (`hooks/roster.mjs`) reports `harness-prompt`.
  The block is recorded, so the dispatch watcher then raises a false BLOCKED wake.

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
  does: `gitdir: <path>` (relative paths resolve against the worktree root), then `<gitdir>/commondir`
  (relative to the gitdir), and **every fallback that function has**, including the one it takes when
  `commondir` is absent. The mirror gives the answer `mainCheckoutRoot` gives for every input, null
  included; where it gives null (unreadable or malformed `.git`, and whatever else it rejects), today's
  behaviour stands. The mod cannot import `lib-config`, so this is a mirror of one function; the shared
  test vectors (§5), generated by calling `mainCheckoutRoot`, pin the two to the same answers.
- **Content model (r2): the Pane shows the document of the pool the session works in, and uses the
  main checkout's only to find teams the pool does not list it on.** `status.json` content (exchanges,
  dispatches, pipeline) is computed per pool, and a session working in a worktree has its dispatches in
  that pool. For a cwd inside a linked worktree with a main checkout `M`, the Pane shows:
  1. the worktree's own `status.json` when it is readable and the viewer is a member or an owner there
     (its `nullCause` is anything but `no team owned by this session`, `unreadable`, `expired`);
  2. else `M/.claude/hierarchy/status.json` when readable and the viewer is a member or owner there;
  3. else the worktree's own document, exactly as today (today's `nullCause`).
  Prompt registration (§2.1) writes the pool row, so whenever the worktree has a hierarchy dir, step 1
  holds and the Pane shows that pool's exchanges. Step 2 covers a worktree with no hierarchy dir of its
  own, and a team the pool does not list. Main is read only on a pool miss; both reads keep the mtime
  cache, so a pool hit costs what today's read costs.
- **The pool's document must list the teams homed in main.** `computeStatus(cwd, …, dir)` for a
  worktree pool enumerates live teams from the team home (`teamHomeDir(dir)`, the same resolution
  `readTeam` uses), plus any legacy team file in the pool itself, so its `owners` and `teams` cover a team
  spawned from either place. Exchanges, dispatches, pipeline and gates stay the pool's own. If
  `listTeamNames` already resolves the home, no change is needed; the §5 test proves it either way.
- A session's exchanges in a pool other than the one it now works in are not shown; a union of pools
  is out of scope (open question 4).
- Re-locate still happens only on a cwd change; `seenMtime`/`doc` reset as today for every file that
  changes.
- `AGENT_HIERARCHY_DIR` stays unfollowed by the mod (existing `ponytail:` note), and `mainHierarchyDir`
  already returns null when it is set, so writers do not double-write in that mode.

### 2.3 Gap 3: Codex's idle composer, one- or two-line footer

`isComposer(kind, screen)` keeps its signature, its callers, and its first steps: trailing blank lines
dropped, braille cells (U+2800–U+28FF) blanked on every line it inspects. The layout rule becomes:

- **The prompt row** is the last line on screen that is a composer glyph at column 0, one space, then a
  placeholder of the kind and only spaces (the existing row test, unchanged).
- **Below it**, and nothing else: **at most one** blank padding row, then **one or two** non-blank
  footer lines. The screen ends with the last footer line. Footer content is free, except that no footer
  line may be an option row (`optionStart` shape) or match any of the kind's prompt `footer` patterns.
- **Above it** nothing is required. The padding row above the prompt row is no longer checked (one live
  capture shows the prompt row with no padding row below, and blank rows may be lost in a read).
- The prompt row must be within the last four lines, which the bullets above already imply; any screen
  that ends otherwise is not the composer.

What is not changed: `composerOrPrompt`'s re-read and busy logic; the rule that a composer read while
Herdr reports `working` or `blocked` is not the composer (`lib-roster.mjs` ~:524); prompt recognition;
the dispatch watcher. The false BLOCKED wake goes away because `deliver` no longer records a block; the
watcher needs no change. Update the comments at `KIND_HARNESS.codex.composer` and `isComposer` to describe
the new layout.

New fixtures in `tests/fixtures/0062-screens/`, verbatim from the live Codex 0.162.0-alpha.2 captures
(footers as captured, including the `…` truncation):
- `composer-0162-spawn.txt`: `› Ask Codex to do anything` / (blank) / `  GPT-6.1-Sol high · ~/git/r…` /
  `  ? for shortcuts   ⚠ 6 · f2`
- `composer-0162-nopad.txt`: logo art lines, then `› Ask Codex to do anything` /
  `  GPT-6.1-Sol high · ~/git/repos/agent-tools · h…` / `  ? for shortcuts                       ⚠ 6 · f2`

**NEEDS-EVIDENCE (Implementor, before building gap 3):** on a live Codex 0.162 member sitting at its
idle composer, record what Herdr reports as its `agent_status` (`herdr agent list` / the state
`herdrAgentState` reads). `idle` or `done` → build as written. `blocked` → stop and report: the composer
rule alone cannot make `deliver` send, and the Herdr-status gate needs a ruling.

## 3. Files

- `agent-hierarchy/hooks/lib-status.mjs`: `appendSessionPid` dedupe rule (§2.1).
- `agent-hierarchy/hooks/activity.mjs`: prompt registration, both dirs, before the refresh; main-dir refresh.
- `agent-hierarchy/hooks/sessionstart.mjs`: the main-dir row and refresh.
- `agent-hierarchy/mod/register.tsx`: main-checkout resolution and the document choice (§2.2);
  `mod/view.ts` only if the choice needs `nullCause`/`scope` exported in another shape.
- `agent-hierarchy/hooks/lib-status.mjs` `computeStatus`: a worktree pool lists teams homed in main (§2.2), if not already so.
- `agent-hierarchy/hooks/lib-roster.mjs`: `isComposer` and the `KIND_HARNESS.codex.composer` comment (§2.3).
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
| Cwd in a linked worktree with a hierarchy dir, viewer owns a team homed in main | Worktree document (pool first); team shows with the pool's exchanges |
| Cwd in a linked worktree with **no** hierarchy dir, viewer owns a team homed in main | Main document |
| Cwd moves main → worktree → main | Same teams shown throughout; content is each pool's |
| Worktree whose main has no `status.json` | Worktree document, as today |
| Legacy team file in the worktree's own dir, viewer owns it | Worktree document; that team shows |
| Worktree document expired or unreadable, main lists the viewer | Main document |
| Viewer owned nowhere | Worktree document and its `nullCause`, as today |
| `.git` file of any shape (submodule, no `commondir`, relative/absolute `gitdir`, malformed) | Mod's main root equals `mainCheckoutRoot`'s answer, null included |
| Codex 0.162 spawn screen (pad, two footers) / no-pad screen | Composer → `deliver` sends |
| Older Codex screens `composer-e12a`, `composer-e12b`, `composer-after-turn` | Composer, as today |
| `composer-typed` (non-empty input) | Not composer |
| `approval-e8`, `trust-live`, `login-e8`, every `otherHeadings` screen | Not composer; recognised prompt or `harness-prompt` as today |
| Placeholder row followed by three footer lines, or two blank rows, or a blank between footers | Not composer |
| Placeholder row followed by an option row or a line matching a prompt `footer` | Not composer |
| Composer screen while Herdr reports `working` or `blocked` | Not composer, as today |
| Claude kinds (no `composer` in `KIND_HARNESS`) | `isComposer` false, as today |
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
  - **worktree pool lists main's team**: team homed in main, orchestrator prompts from a linked worktree
    that has a hierarchy dir → the worktree's `status.json` has that team, with the viewer as owner.
  - **worktree owner sees its own exchange**: same setup plus an open exchange in the worktree pool →
    the worktree document's owner timeline shows that dispatch, and main's does not.
- `mod/tests/register.test.ts` (fixtures with a `.git` file, `gitdir`, `commondir`):
  - **pool first**: worktree document lists the viewer → it is shown, not main's (b);
  - **main fallback**: worktree has no `status.json`, or does not list the viewer → main's shown (b);
  - **cwd moves main→worktree** keeps the teams; **legacy worktree team** shows (d);
  - negatives: viewer owned nowhere → worktree document's `nullCause`; main without `status.json`.
- Shared vectors: cases generated by calling `lib-config.mjs` `mainCheckoutRoot` (linked worktree,
  relative and absolute `gitdir`, no `commondir`, submodule, normal checkout, malformed) consumed by the
  mod test, under the existing drift check `tests/test-mod-fixtures-drift.sh`.
- `tests/test-chain-roles-other-harnesses.sh`, new K checks:
  - **0.162 composer**: `isComposer("codex", …)` true for both new fixtures, still true for the three
    older composer fixtures, false for `composer-typed`, `approval-e8`, `trust-live`, `login-e8`, and for
    each synthesized negative in §4 (three footers, two blanks, blank between footers, option row or
    prompt footer under the placeholder row).
  - **deliver sends to 0.162**: a Codex member whose screen is `composer-0162-spawn.txt` and whose Herdr
    status is idle → `deliver` types the brief (`sent: true`), records no block; same for the no-pad
    screen. Fails today with `blocked`/`harness-prompt`.
  - **no false wake**: after that `deliver`, `tests/test-blocked-watcher.sh`-style poll ×2 → no BLOCKED wake.
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
4. Show a session's exchanges from every pool at once (a union of pools)? **Default: no**; the Pane
   shows the pool the session works in, which is where its current dispatches are.
