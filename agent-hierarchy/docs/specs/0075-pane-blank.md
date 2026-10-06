# 0075 — Hierarchy Pane drawn blank while a team is live

Implementer: implementor
Reviewer: reviewer

Status: r3, final fix design. Fix set: §5.1, §5.2, §5.3 (r3) and §5.4. §0 holds the cause ruling; §4 is the
evidence record (done), not work to do.
Version: patch bump after whatever is last on main when this lands (0.115.1 if 0074 is there; else 0.113.1). Bump
plugin.json and the root marketplace.json together.

## 0. Ruling (r2, after evidence E1–E6; r3 wording)

- **Cause: H2 leads, unverified. H1's render path is fixed by §5.1 regardless.** A status write from a process whose
  own config says the hierarchy is disabled can replace the live pool's `status.json` with `visible:false` (proven,
  E3). The Pane then draws only the dim null-view line.
  - That matches "blank" only if the dim line was missed, which E4 decides.
  - H1 (E2: zero rows, no band) matches "not even the dim line" literally, but no writer for it was found.
  - E3 proved the writer: pool root, HOME config `enabled:false`, live team → `visible:false`, teams=1.
  - `sessionstart.mjs:216` rewrites the file for every non-role session started in the checkout, under *that*
    session's config. So any differently configured session or tool can do this.
  - The 12:34 process itself was not identified, and its file is lost. The fix does not depend on knowing it.
- **H1: the mechanism is real (E2), but no writer was found.** E1 and E6 found nothing; ah's writer cannot produce it.
  It stays a latent reader defect, fixed by §5.1 regardless.
- **H3: undecided.** There is no log (E5). §5.1's render guard covers it.
- **Killed:**
  - E6: a worktree-cwd writer touches only the worktree's own pool. That is the known cross-pool gap, out of scope here.
  - E1: no test writes a real pool.
  - Expiry and a frozen state were already ruled out (§2).
- **Fix set:** §5.1 (the Pane always draws ≥1 row), §5.2 (the null-view row names its cause), and §5.3 (r3: an event write
  by a disabled writer keeps the published `enabled`; nothing is skipped). §5.3a is dropped.

## 1. Symptom

- The orchestrator session had its Pane open while 3 team members were live and idle.
- The Pane was empty. The orchestrator's brief says not even the dim `No hierarchy status here.` line showed; the
  user's words are "It was blank".
- The last write before then was at 12:34, from report and review traffic. Its content is lost, because the next
  write replaced it.
- At 13:01 the orchestrator ran `roster.mjs status`, which rewrote the file, and the user re-ran
  `/hierarchy-pane`. The Pane then listed the agents: one visible timeline entry, "3 live · 0 out".
- The bug is in released code (live 0.113.0), and is independent of 0073 and 0074.

## 2. Facts established by reading (main checkout, bae05d4)

- **Pane render**: `mod/register.tsx:129–137`. It reads `$.state` key `view`, calls `paneRows(value ?? null, bodyColumns)`, and draws
  one `Text` per row inside a column `Box`.
  - Per the host types (`claude-code.d.ts`, ui.render remarks), reading `$.state` while drawing subscribes that render to
    the state, so every write of `view` redraws the Pane.
  - Per the same types, "an invalid tree, or a throw while drawn, draws the engine's".
- **`paneRows`**: `mod/view.ts:271–274`.
  - A null view gives exactly one row, the dim `No hierarchy status here.`
  - A non-null view gives `view.pane.map(...)`, which is **zero rows when `view.pane` is empty**.
- **`viewModel`**: `mod/view.ts:170–236`. It is non-null whenever `current()` picks a visible, well-formed entry for a
  non-member session.
  - `pane` gets three headings per element of `doc.teams` that is a record (Hierarchy, Team, Dispatches) and nothing else.
  - **A visible doc with `teams: []`, or with no record in `teams`, therefore gives a non-null view with an empty pane:
    a blank Pane, and also no band.** This is the only blank-drawing path in the mod's code.
- **Writer**: `hooks/lib-status.mjs:357–398` (`computeStatus`).
  - `teams` gets only teams that pass `teamIsLive`.
  - `allMembers` and `allDispatches` come only from those teams.
  - `visible = enabled && (live>0 || out>0 || anyPipeline)` (l.334), and `anyPipeline` is `teams.some(...)`.
  - So **ah's own writer cannot emit `visible:true` with empty `teams`**: no teams means no members, no dispatches and no
    pipeline, so `visible:false`.
  - It can emit `visible:false`, which is a null view and the dim line, whenever the writing process finds no live team
    or has `enabled` false. Both are judged in the process that triggered the write, under that process's
    cwd and HOME.
- **Expiry** is `written_at + 24 h` (`lib-status.mjs:30`), so a write at 12:34 had not expired by 13:00. The brief's
  hypothesis (d) is ruled out.
- **Rewrites** happen only on events (hooks, CLI verbs, team and message writes), never on a timer. An idle team leaves
  the file as it is, which is by design: the timeline carries the future states.
- **The tick** (`register.tsx:38–90`) stats the file every 2 s and re-parses it when `mtimeMs` changes. It recomputes the
  view each tick from the held doc and the clock, and writes `view` when the view changed.
  - The brief's hypothesis (a), a frozen state, is ruled out by reading: nothing caches the view except the
    state itself, and a null-view tick still writes `null` when the view changed.
- **Tests**: `mod/tests/view.test.ts` and `register.test.ts` have no case with a visible entry and empty `teams`. The
  `docText` helper defaults `teams: []`, but every case overrides it.

## 3. Ranked hypotheses

| # | Hypothesis | Fits "truly blank"? | Fits "rewrite + reopen fixed it"? | Standing |
|---|---|---|---|---|
| H1 | The file held a **visible entry with no team records**, so the view was non-null with zero Pane rows. That is a reader defect plus a doc that ah's writer cannot produce, so another writer wrote it: a test or tool run whose cwd resolved to the real pool, or a hand-made file. | **Yes**: the only code path that draws nothing. | Yes: the 13:01 rewrite restored teams. | Most likely if the brief's "not even the dim line" is exact. E1 and E2 decide it. |
| H2 (incl. the worktree-cwd writer, E6) | The file held `visible:false` or an unusable doc, so the view was null and the Pane drew **one dim line**, which read as blank. The 12:34 write came from a process (a member hook, or a test that runs hooks) whose cwd or HOME saw no live team or `enabled:false`. | Only if the dim line was missed (dim text, one line, in a tall pane). | Yes. | Most likely if "blank" means "nothing useful". E3 and E4 decide it. |
| H3 | The render **threw**, or returned a tree the engine rejected, so the engine drew its own fallback. | Yes, if that fallback is empty. | Yes: a new state value re-renders. | Low. No throw path found in `paneRows` for any value `viewModel` produces. The only route is a `view` held in `$.state` with an unexpected shape, e.g. from another module version, since state outlives reloads. E5 decides it. |
| (b) | The timeline entry picked at 13:00 was invisible, or every entry was in the future. | No, it draws the dim line. | — | Folded into H2. `current()` takes the first entry when every one is in the future, so a future-only timeline is not blank either. |
| (d) | The idle team's file expired. | — | — | **Ruled out**: the expiry is 24 h. |
| (a) | The Pane state went stale. | — | — | **Ruled out by reading**, see §2. |

## 4. NEEDS-EVIDENCE (Implementor, read-only or sandboxed; no run touches the real pool)

Every probe uses a `mktemp -d` dir checked non-empty, `HOME` set inside it, and `git -C "$T/…"` for any git write.
Variables are assigned in the script. No probe writes `/Users/…/agent-tools/.claude/hierarchy/`.

- **E1 (decides the source in H1 and H2).** Find every code path in the repo, test or otherwise, that can write a
  `status.json` into a pool other than a fresh sandbox:
  - grep `tests/` and `mod/tests/` for writes of `status.json`, and for runs of hooks or `roster.mjs`/`msg.mjs` whose
    `cwd`, `--cwd` or `AGENT_HIERARCHY_DIR` is not under a `mktemp` dir. List file:line for each.
  - Report every handcrafted status doc (in fixtures and inline) with `visible: true` and `teams: []` or no `teams`.
  - Report whether running hooks with `HOME` sandboxed but cwd inside a real checkout makes `writeStatus` write that
    checkout's real pool with `enabled:false`. Answer this by reading `hierarchyDir` and `resolveConfig`, not by running it.
  - **Decides:**
    - a test writes the real pool → H1/H2 source confirmed; apply §5.3a;
    - no foreign writer → H1 needs a hand-made file (unlikely), and H2 via member hooks becomes the lead; run E3.
- **E2 (confirms the H1 mechanism).** With the mod harness (`claude plugin test`, as `tests/test-mod-plugin-test.sh`
  runs it), add a throwaway case: a doc with a visible entry and `teams: []`. Report the rows the Pane render draws,
  expected zero, and the band, expected none.
  - Also report a doc whose `teams` holds only non-records (`[1, "x"]`), expected zero rows.
  - **Decides:** zero rows → the H1 mechanism is confirmed; the case becomes the §5.1 regression test.
- **E3 (H2, member-process writes).** In a sandbox pool with a live team, run `writeStatus` (via any hook entry
  `activity.mjs Stop`) from three places:
  - (i) the pool root;
  - (ii) a linked `git worktree` of it (`git -C "$T/repo" worktree add …`);
  - (iii) the pool root with a `HOME` whose `agent-hierarchy.json` is absent or has `enabled:false`.
  - Report `visible` and `teams.length` for each.
  - **Decides:** any of these gives `visible:false` with a live team → the H2 source is confirmed; apply §5.3b for that case.
- **E6 (worktree-cwd writer; a candidate from the Orchestrator, linked to the known open gap "cross-pool status
  refresh" between the main checkout's and a worktree's hierarchy dirs).**
  - **Ranking by reading:** this writer cannot produce H1's doc. It feeds H2. `refresh(cwd, dir)` passes ONE `dir` to
    both `computeStatus` (teams, members, dispatches) and `saveStatus` (lib-status.mjs:420–426). If the team pool
    read is empty, `visible` is false as well (l.334, l.396).
    - A worktree-cwd process can therefore write main's file with `visible:false`, which is H2's dim line. It can also
      write its own worktree pool with a doc the main session never reads.
    - It can give H1 only if some path computes from one dir and saves into another. Reading lib-status shows none,
      but the paths beyond `writeStatus` and `refresh` (`statusChanged` and `cwdOfDir` at l.442ff) are unverified.
    - **E6 settles it.**
  - **Probe** (sandbox; `T=$(mktemp -d)`, checked non-empty; `HOME="$T/home"` with ah enabled):
    - make `$T/repo` a git repo with a live team in `$T/repo/.claude/hierarchy`;
    - `git -C "$T/repo" worktree add "$T/repo/.claude/worktrees/w1"`;
    - from cwd `$T/repo/.claude/worktrees/w1`, trigger a status write three ways: an `activity.mjs` Stop hook
      payload; `msg.mjs new … --cwd <worktree>`; and `roster.mjs status --cwd <worktree>`.
  - **For each, report:**
    - which `status.json` path(s) changed (stat both pools before and after);
    - in each changed doc, `visible` and `teams.length`;
    - for each `statusChanged` call site, the `dir` it resolves for compute and for save.
  - **Decides:**
    - main's file gets `visible:true` with `teams: []` → H1's source is confirmed. The fix is the cross-pool gap: compute
      and save from the same resolved pool, which goes back to the Architect as 5.3b.
    - main's file gets `visible:false` → H2's source is confirmed: 5.3b.
    - only the worktree's own pool changes → this candidate is ruled out for the incident (the main session never
      reads that file); E1 and E3 stay open.
- **E4 (H2, perception). User, manual, 1 min.**
  - In a checkout with no `.claude/hierarchy/status.json`, open `/hierarchy-pane`. Is `No hierarchy status here.`
    visible at a glance in the user's theme?
  - **Decides:** hard to see → H2 is plausible as observed, and §5.2 matters more.
- **E5 (H3).** Check the host's debug or plugin logs (the Implementor finds where the engine logs a `ui.render` throw
  or invalid tree for a plugin not loaded with `--plugin-dir`) for an `ah` render error between 12:30 and 13:01 today.
  - **Decides:** found → H3 confirmed; §5.1's guard already covers it. None found → H3 drops.

## 5. Fix design

### 5.1 Pane never draws nothing (all hypotheses; land now)

- **Invariant: the Pane always draws at least one row.**
  - `paneRows` returns a non-empty array for every input: a null view, a view with an empty `pane`, and any
    value from `$.state` that is not a well-formed view.
  - A non-null view with an empty `pane` draws one dim row that says the doc lists no team. Suggested wording: `No live
    team in the status file.` The exact text is the Implementor's, within the generic-text rule.
- **The render must not throw on a held value.**
  - Treat a `$.state` `view` value that lacks a `pane` array as a null view (shape check in `paneRows` or at the render).
  - A throw inside drawing a row draws the null-view row instead of letting the engine draw its fallback.
  - The band (`bandLine`) gets the same shape guard, so a malformed held value draws no band rather than throwing.
- **Unchanged:**
  - `viewModel`'s contract for well-formed docs;
  - the band rules (an empty-teams view still has `band: null`);
  - toasts, seeding and auto-open.

  Auto-open still fires on a non-null view, and that is intended: it now opens onto the new row, not onto nothing.
- **Tests** (mod tests; each seen failing before the edit):
  - visible entry, `teams: []` → exactly one row, the new dim row;
  - visible entry, `teams: [1, "x"]` → the same;
  - held `view` = `{}` and `{ pane: "x" }` → one null-view row, and no throw;
  - existing cases unchanged.
- Docs: in `docs/status-file.md` "Reading it", add one line saying that a reader showing a visible doc with no teams must
  say so rather than draw nothing. Add no other doc change.

### 5.2 Say why there is nothing (r2: in the fix set; H2 is the likely cause, and "not visible" in the row would have named it)

- r2: the causes the row distinguishes include **`hierarchy off`**: a doc with `enabled:false` (the incident's case),
  told apart from a doc that is `visible:false` because nothing is live.

- The null-view row names its cause in a few words: no file, unreadable, expired, not visible, or a member session.
  Example: `No hierarchy status here (not visible).`
  - This needs `viewModel` or `current()` to report the reason for a null view, as a value next to it rather than a
    change to `View`. The Implementor picks the shape.
- Why: this incident's evidence was lost when the file was overwritten. With a cause in the row, the next occurrence
  diagnoses itself from a screenshot.
- Tests: one per cause.

### 5.3 An event write by a disabled writer keeps the published `enabled` (r3, replaces r2's skip)

r3 change: r2 skipped event writes from disabled processes. The Reviewer showed that drops real team-state changes
(F1): no hook or CLI checks `enabled`, so disabled processes still create reports, roster rows, check-ins and
nudges. Skipping their writes leaves the status stale, which is the same bug class with the opposite sign. r3
publishes every write and changes only which `enabled` an event write uses.

§5.3a (sandbox tests) stays dropped: E1 found no test that writes a real pool.

- **Where.** In `refresh` (lib-status.mjs:420), the event-only path: both `writeStatus` (:438) and `statusChanged`
  route through it.
  - The explicit `roster.mjs status` verb (roster.mjs:7040–7041) calls `computeStatus` and `saveStatus` directly, so it
    is untouched.
  - The `/hierarchy` on/off/init refresh calls `roster.mjs status` (commands/hierarchy.md:150, :193; verified by the
    Reviewer).
  - So the explicit writes keep using the writer's own config, as today.
- **Rule: the effective `enabled` of an event write.**
  - The writer's own resolved `enabled` is true → it uses true (as today).
  - The writer's own resolved `enabled` is false → it uses the `enabled` of the doc currently on disk, when that doc is
    readable and unexpired and has a boolean `enabled`. Otherwise it uses false (as today).
  - In short, an event write never turns a published `enabled:true` into false. Only an explicit write, or a doc
    that is absent or expired, lets a disabled writer publish false.
- **`visible` follows the effective value.** Every timeline entry's `visible` is computed with the effective
  `enabled`, using the same formula (l.334), and the doc's `enabled` field is the effective value.
  - How the effective value reaches `computeStatus` is the Implementor's choice. The on-disk doc is read at most once
    per refresh, under the same reader rules as §2: the size cap, no link and regular file only, JSON, `schema` 1, and
    `expires_at` in the future.
  - r4: no hooks-side status reader exists today; the only one, and its cap, live in the mod (`mod/view.ts:6`,
    `SIZE_CAP = 262144`). **Add one reader to `hooks/lib-status.mjs`.** It is the only hooks-side reader. It returns the
    disk doc's `enabled` boolean, or "no disk doc", for a pool dir, and follows `docs/status-file.md` "Reading it"
    step 1:
    - `lstat` the path; it must be a regular file, not a symlink, with a size from 1 to 262,144 bytes. Check the size
      before reading.
    - It must parse as JSON with `schema === 1`.
    - `expires_at` must parse as an ISO-8601 instant later than now.
    - `enabled` must be a boolean.
    - Anything else, or any throw, means "no disk doc".
  - **The cap is a constant in `lib-status.mjs`, equal to 262144.** The mod cannot import hooks code, so the value
    exists twice. Add one test assertion that the two values are equal (grep both files), so they cannot drift.
  - Do not reuse or extend `computeStatus`'s readers for this; the new reader reads only this one field.
  - The read must not throw out of `refresh`, which keeps its "never throws" contract.
- **Proof obligations** (each a §7 row and a test):
  - *Never stale.* No event write is skipped. Every process that changes team state publishes it at once, exactly
    as today. Team facts (teams, members, dispatches, pipeline) always come from the pool, never from the disk doc.
  - *Never hides a live team, beyond a bounded case.* A disabled event writer publishes `enabled:false` only when the
    disk doc is absent, expired or unreadable, or is already false. In the absent, expired or unreadable case, the
    next event write from any enabled process (the Orchestrator's own next prompt or Stop) publishes true again.
    The hiding is bounded by that event: the accepted ceiling.
  - *Off still hides.* `/hierarchy off` writes explicitly with `enabled:false`. Later event writes from the same
    disabled config find the disk value false and keep it.
- **Concurrency.** The read-then-write in `refresh` is not atomic across processes. A lost race costs at most one write
  with the other process's `enabled`, and the next write corrects it, except C4. That matches the existing two-writer note at
  lib-status.mjs:409; no lock is added.
- **Accepted ceilings** (state them in `docs/status-file.md`):
  - C1: hidden until the next enabled event, as above.
  - C2: disabling by hand-editing the config, without `/hierarchy off`, keeps the published view visible for as long
    as event writes refresh it. Hide it with `/hierarchy off` or `roster.mjs status`.
  - C4 (r4): a disabled event write can race an explicit `/hierarchy off`. The event writer reads `enabled:true`, the
    explicit write saves `enabled:false`, and then the event writer's rename lands with `enabled:true`.
    - Later disabled event writes inherit true, so the off is undone until the next explicit write. That is **not**
      corrected by the next write, contrary to the general concurrency note.
    - The window is the event writer's read-to-rename span, milliseconds.
    - It is accepted rather than closed. Closing it needs a durable "off" marker outside the doc, or a lock between
      writers, and either costs more than a rare, visible, self-service failure.
    - Recovery: re-run `/hierarchy off`. Say this in `docs/status-file.md`.
    - Upgrade path, only if it is ever reported: the explicit write also stores the config's off state where event
      writers read it.
  - C3, unchanged from today: after `/hierarchy off`, an event write from a process whose config is enabled (another
    HOME) publishes true. That is not a hiding bug, and this spec does not address it.
- **Unchanged:** the schema; the `visible` formula; `saveStatus`; `computeStatus`'s team-fact logic; the explicit
  writers; the worktree pool behaviour (the cross-pool gap stays its own item).
- **Tests** (sandbox pool via `AGENT_HIERARCHY_DIR` or a mktemp repo; each new case seen failing first):
  - W1: live team, doc on disk `enabled:true`; then an event write (an `activity.mjs` Stop payload) under a HOME with
    `enabled:false` → the doc is rewritten, `enabled:true`, entry `visible:true`.
  - W1b (the F1 row): the same disabled process makes a team-state change (`msg.mjs new --type response …` closing
    an open dispatch) → the doc is rewritten at once, and that dispatch is `reported`. Nothing is stale.
  - W2: the same as W1 via the SessionStart `writeStatus` → `enabled:true`, `visible:true`.
  - W3: `roster.mjs status` under a disabled HOME → `enabled:false`, `visible:false`. An explicit write still hides.
  - W4: after W3, an event write under the same disabled HOME → it stays `enabled:false` and `visible:false`.
  - W5: no doc on disk, event write under a disabled HOME → `enabled:false`. Then an event write under an enabled HOME
    → `enabled:true` and `visible:true`. This is the C1 bound.
  - W6, must NOT change: an event write under an enabled HOME, or with config absent, over a doc that says
    `enabled:false` → `enabled:true`. That is today's behaviour, C3.
  - W7: an unreadable disk doc plus a disabled event writer → `enabled:false`, and no throw. Cases: not JSON; a
    symlink; expired; `schema: 2`; over 262,144 bytes; `enabled` not a boolean.
  - W8: the hooks cap constant equals `mod/view.ts` `SIZE_CAP`.

### 5.4 Version and docs

- `docs/status-file.md`: the §5.1 line, plus a "Who writes it" note. An event write by a process whose config is
  disabled keeps the published `enabled`; explicit refreshes use the writer's own config. Add the §5.3 ceilings C1–C4.
- CHANGELOG: one Fixed entry (the Pane is never blank; a disabled session no longer hides a live team's view), in
  generic words.
- Version bump as in the header, in both manifests.

## 6. Must NOT change

- The status-file schema and the writer's output for well-formed pools.
- The 24 h expiry, the event-only rewrite policy (no timer writer), the tick cadence, `SIZE_CAP`, and the stat/read guard.
- Band, toast and auto-open behaviour for well-formed views.
- Member sessions still see no hierarchy view.

## 7. Invariants and negative cases

| Input | Must draw |
|---|---|
| null view (no file, expired, invisible, member) | 1 dim row (with its cause, if §5.2 lands) |
| visible entry, `teams: []` | 1 dim row (new) |
| visible entry, `teams` holding only non-records | 1 dim row (new) |
| held `view` malformed (`{}`, `{pane:"x"}`, a number) | 1 dim row, no throw |
| visible entry, 1 team, no members or dispatches | headings + `No pipeline run.` + `None outstanding.` (unchanged) |
| well-formed live view | unchanged rows |
| must NOT match: a member session with a visible doc | still the null view; the new row does not leak team data |
| writer: an event write, own config disabled, disk doc `enabled:true` | written; `enabled:true`, live team visible (W1, W2) |
| writer: a disabled process changes team state | published at once, not stale (W1b) |
| writer: an explicit write (`roster.mjs status`, i.e. `/hierarchy` off), config disabled | written; `visible:false` (W3) |
| writer: an event write, own config disabled, disk doc `enabled:false` | stays hidden (W4) |
| writer: an event write, own config disabled, no, expired or unreadable disk doc | `enabled:false`, no throw; the next enabled event restores it (W5, W7) |
| writer, must NOT change: an event write with config enabled or absent | `enabled:true` as today (W6) |

## 8. Acceptance

1. Every §7 row is covered by a test (mod tests for the Pane rows, shell tests W1–W8 and W1b for the writer), and each new
   case is seen failing first.
2. §5.1, §5.2, §5.3 and §5.4 are implemented as written; §5.3a is not.
2b. Manual, by the user (E4, below), once after landing.
3. The full ah suite and `claude plugin test` are green, and the version is bumped in both places.
4. Generic text only: no product, ticket or incident names in code, tests, docs, CHANGELOG or commits.

## 8b. E4 for the user, in plain words

- **The question:** when there is nothing to show, can you actually see the Pane's faint grey line?
- **How to check (about a minute):**
  1. Open Claude Code in a folder that has never used the hierarchy, such as a new empty folder.
  2. Type `/hierarchy-pane`.
  3. Look at the Pane. Can you read the faint line "No hierarchy status here." without leaning in?
- **Why it matters:** your answer tells us which of two explanations fits what you saw. If the line is hard to see
  in your theme, say so, and the fix will draw it in normal colour instead of dimmed. After this fix
  the line also says why there is nothing to show.

## 9. Decisions and open items

- r3 decided: §5.3 lets a disabled event writer inherit the published `enabled`; it no longer skips (the r2 skip left
  status stale, per Reviewer F1). The guard sits in `refresh`. Ceilings C1–C3 are accepted.
  - No Ultra-Advisor is needed: the change reads one field and arbitrates nothing. Team facts always come from the pool.
- r3: H2 leads, unverified (§0). If E4 says the dim line is clearly visible, H1's writer stays unexplained. Next
  recurrence, capture a copy of `<pool>/status.json` before the next write, plus a host debug log. That is an
  operator step; no code.
- r2 decided: §5.2 lands with §5.1.
- Left to the user: E4. If the dim line is hard to see, the null-view row's tone becomes normal (a one-line change in
  `paneRows`); the Orchestrator relays the answer.

- Decided: §5.1 lands regardless. It is the one defect proven by reading: a non-null view can draw nothing.
- Decided: expiry and a frozen state are ruled out by reading (§2).
- (r1 items superseded: §5.2 timing and the 5.3b escalation are both settled.)
- Out of scope: the cross-pool refresh gap between worktree and main pools (E6). It stays its own item.
