# 0072 — One team file per checkout: the master list for disband, dismiss and teams

Implementer: implementor
Reviewer: reviewer

Status: r6.
- r6 rules on W8 for `dismiss` (§19): W8 on the dismiss plan;
  `dismiss --close` keeps its exit-2 failure. One delta after §9 step
  14e.
- r5 rules on the Implementor's three gaps at `55af506` (§18). The
  deltas are listed after §9 step 14e.
- r4, by user ruling, adds L4: a background dispatch watcher that wakes
  an idle Orchestrator on a timer (§14.9). r4 also folds in E3's result,
  amending §14.4–§14.5. The work is §9 steps 14a–14e, run before
  step 15. Changes are in §17.
- r2 is built: `6eb8913`..`e654823`.
- r3 adds the headline, §14 report-back enforcement, by user ruling, so
  that finished work is never left unseen. r3 also rules on the
  Implementor's gaps 1–4 (§15).
- r3 work is §9 steps 9–15. The docs step goes to docs-writer after
  step 15.
- Changes: r1→r2 in §13, r2→r3 in §16.

Where the work happens:
- worktree `/Users/jimcline/git/repos/agent-tools/.claude/worktrees/0072`;
- branch `ah/0072-worktree-scope`, off main `581d3ba` (`ah` 0.109.0);
- independent of the 0071 branch;
- never edit the main checkout `/Users/jimcline/git/repos/agent-tools`
  (the live `ah` root).

Naming rule (user): never write the field report's team name anywhere —
spec, tests, fixtures, commits. Use `<t>`, `demo`, `myrepo`.

All paths are under `agent-hierarchy/`. Line numbers are at `581d3ba`.
Some `roster.mjs` numbers are approximate (±5).

## 0. Summary

User direction: *"an orchestrator should have a ledger of all peer agents
it spawned and that's the master list of what gets checked when being
dismissed"*. Then R1: no new tracking files — **the existing team file is
that ledger.**

- **r3 headline: report-back (§14).** A peer cannot go idle holding an
  unsent report (L1). The Orchestrator's Stop surfaces reports that
  landed but were never sent, from any pool (L2). Dispatches carry
  `notify_when_idle`, so an idle peer wakes an idle Orchestrator (L3).
  r4: a background watcher wakes an idle Orchestrator when a dispatch
  hits its eta, or when a report lands unsent. That covers a peer that is
  hung, or busy for ever (L4).
- **One home.** A team file has one home, the main checkout's hierarchy
  dir, whatever `--cwd` a spawn or create is given. The mapping lives
  inside the team-file primitives, so every reader and writer agrees.
- **Members keep their own root.** Each member row records its own
  `expected_root`. A team can then have members in the main checkout and
  in worktrees without any of them being flagged misplaced.
- **Teardown reads the home, falls back to legacy.** Teardown reads the
  team file from its home, plus any legacy copy in a worktree pool. It
  reads `peers.jsonl` from every pool the team touches. Herdr panes that
  carry the team's name are closed as `stray` (R3).
- **Verified close.** `closed: true` means every target is gone on a
  fresh re-query. Every shortfall is a warning; none passes as silent
  success.

## 1. The field bug (generic names)

**What happened:**
- The Orchestrator ran in linked worktree `<repo>/.claude/worktrees/<w>`.
- It spawned two peers with `--cwd <worktree>` and three with
  `--cwd <main checkout>`.
- `disband --plan --team <t> --cwd <worktree>` returned: team file null,
  members 0, peers.live 2, herdr matched 0.
- `--close` returned `closed:true, kept:[], team_removed:false`, and three
  sessions stayed alive.
- `teams` returned `teams:[], untracked_live:[]`.

**Root cause, traced at `581d3ba`:**

1. **Records follow `--cwd`.** Team records are written to
   `hierarchyDir(--cwd)` (`spawnOneCore` `roster.mjs:4841`, `create
   --commit` `:5651-5676`). Each peer's `peers.jsonl` row goes to
   `hierarchyDir(<peer cwd>)` (`sessionstart.mjs:131-165`).
   `hierarchyDir` is `findGitRoot(cwd)/.claude/hierarchy`
   (`lib-config.mjs:691`), and a linked worktree is its own root, so the
   team's records ended up split across two dirs.
2. **Teardown reads one dir.** `disband` (`:5713`, dir at `:5734`),
   `dismiss` (`:5825`), `untrack` (`:5984`) and `teams` (`:6724`) read
   `hierarchyDir(cwd)` only.
3. **The herdr arm drops the rest.** Its cwd filter (`:4210`) compares
   `findGitRoot`, and its default prefix is the worktree's basename.
4. **"Closed" is unverified.** It means only that "no close command threw"
   (`closeOne` `:4363`).

## 2. The team file is the master list (R1)

### 2.1 One home

The **team home** of a hierarchy pool dir P is the hierarchy dir of P's
main checkout. That is `mainHierarchyDir` of P's checkout when it is a
linked worktree (`lib-config.mjs:705`, which follows git's `commondir`),
and P itself otherwise. As a consequence:

- with `AGENT_HIERARCHY_DIR` set, the home is that dir, as today
  (`mainHierarchyDir` returns null under it);
- for a non-git cwd, the home is the `~/.claude/hierarchy/<basename>`
  fallback, as today;
- for a normal checkout, the home is its own dir, so nothing changes.

The rule holds whatever `--cwd` a `spawn-one`, `spawn-ad-hoc`,
`create --spawn` or `create --commit` is given. `--cwd <worktree>` and
`--cwd <main>` both resolve to `<main>/.claude/hierarchy/teams/<t>.json`.

### 2.2 Where the mapping lives — inside the team-file primitives

There are about 99 team-file call sites across 9 hook files. They pass a
pool `dir` (usually `hierarchyDir(cwd)`) to the primitives in
`lib-roster.mjs`: `teamPath` (`:94`), `readTeam` (`:779`), `writeTeam`
(`:813`), team-name listing (`:856-859`), and the team-history path
(`historyPath`, ~`:1183`).

**The pool-dir → home mapping is applied inside those primitives, in one
function.** No call site applies it itself, so no call site can bypass it,
and the 99 sites need no edit.

The mapping's contract:

- It is the identity unless P is exactly `<root>/.claude/hierarchy` for a
  `root` that is a linked worktree. In that case it returns
  `mainHierarchyDir(root)`.
- It is idempotent: a home maps to itself. Callers that already hold a
  home, such as `env.home` from `envTeamFile`, stay correct.
- After the change, grep for `"team.json"` and `"teams"` path literals
  outside the primitives. Any that build a team-file path directly must
  be routed through `teamPath`.

### 2.3 Legacy team files in a worktree pool (no migration writes)

For pool P with home H ≠ P, and a team name n:

| n's file exists in | Read from | Written to |
|---|---|---|
| H | H | H |
| P only (legacy) | P | P, in place: no move, and no new split |
| neither (a new team) | — | H |
| both (a split left by an older release) | H for every ordinary verb | H; teardown and `teams` also read P's (§4.1) |

Team-name listing returns the union of H's and P's names. Names are
deduped, and H wins.

**Decision (refines R1, confirm in §10).** A legacy team that lives only
in a worktree pool is updated **in place**, not moved to H. Writing a new
member to H while the rest of the team sits in P would *create* a split,
which is the bug this spec removes. In-flight teams converge on H as they
are recreated. Teams expire after 24 h.

### 2.4 What lives where after r2

| Record | Location | Change |
|---|---|---|
| team file `teams/<n>.json`, `team.json` | team home (§2.1), legacy in place (§2.3) | **moved home** |
| team history | team home | **moved home** |
| `AH_TEAM_FILE` injected at launch (`:2661-2673`) | the home path, as computed by `teamPath` | follows |
| `peers.jsonl` | unchanged: each peer's own cwd pool. It stays the liveness record, and teardown reads it across pools (§4.1) | none |
| `msgs/`, gates, decisions, status | unchanged, per pool | none |

### 2.5 Attribution follows the home

`envTeamFile(homes)` (`lib-roster.mjs:1056`) accepts an `AH_TEAM_FILE`
only under one of `homes`. Every caller's `homes` must include the team
home of its cwd. Known callers: `lib-roster.mjs:1027`, `:1082`, and
`roster.mjs:6870` (`whoami`, which already passes
`[dir, mainHierarchyDir(cwd)]`). Grep for others.

Otherwise a worktree peer whose `AH_TEAM_FILE` points into the home is
rejected and falls out of its team, both in `peers.jsonl` scope
(`inScope`, `lib-hier.mjs:903`) and in `whoami`.

### 2.6 Each member records its own root

Today `expected_root` is team-level: `realCwd(--cwd)` of the call that
created the team (`:4829`, `:5672`). With one team file, a member spawned
with `--cwd <main>` into a team created from a worktree would be flagged
misplaced by:

- `sessionstart.mjs:141-143`;
- `checkin` (`roster.mjs:6821-6823`), which exits 1;
- the misplaced pass in `teams` (`:6758`).

`pretooluse-worktree-gate.mjs:50` would then let it `EnterWorktree` into
the wrong root.

Required:

- **Written.** Every member row written by the launch funnel's callers
  (`spawnOneCore`, and `create --commit` from `create --spawn`'s
  `launch_cwd`) gets `expected_root: realCwd(<that member's launch cwd>)`.
- **Read.** Wherever a session's member row is resolved, the four sites
  above use the member's `expected_root` when present, and the team's
  otherwise. A member row without the field (legacy) behaves exactly as
  today.
- **Unchanged.** The team-level `expected_root` stays as written. Its
  other uses keep it: `stream-label.mjs:34` and `roster.mjs:4781`,
  `:6271`.
- **r3 (§15.2).** SessionStart can fire before the member row exists. So
  the launch also injects `AH_EXPECTED_ROOT`, and the session's own
  resolution order is: member row, then that env value, then the team.

### 2.7 Consequence: one team namespace per repo

Worktrees of one repo now share the home's team names, including the
default `team.json`. Suppose a second live Orchestrator in a sibling
worktree uses a name that is already live. It meets the existing
same-checkout handling: the spec 0011 Second-Team collision for a bare
`create` (`skills/agent-team/SKILL.md` ~:502), and the ownership refusals
for `spawn-one` into another live owner's team. It no longer silently gets
a private team.

No current flow depends on per-worktree teams:
- stream peers already "run from the repo root, not the worktree" (agent-team
  skill ~:98);
- `/pipeline` creates no worktree (autonomous-pipeline skill ~:267).

This is a user-visible change, raised in §10.

## 3. Ownership (R2)

Unchanged. `teamOwnedBy` (`lib-roster.mjs:1116`) and the existing guards
(`guardLiveTeamAtScope` `roster.mjs:3428`, the rival check at `:5029-5036`)
apply per team file, to whichever file §2.3 resolves. There is no new
identity.

## 4. Teardown

### 4.1 Sources

For `disband [--plan|--close] --team <t>`, `dismiss <name>` and `teams`,
invoked with `--cwd C` (pool P = `hierarchyDir(C)`, home H):

1. **Team file(s).** `<t>` as §2.3 resolves it. When both H and P hold
   `<t>` (a split), **also** read P's file and union the members, deduped
   by `transport_id`. Raise W3. Each file's own ownership guard applies:
   - owned by the invoker, or orphaned → its members are `close`
     candidates;
   - live and owned by another → its members are skipped, with W4.
2. **`peers.jsonl`.** Union the live slots (`livePeerSlots`,
   `lib-hier.mjs:908`) from these pools, skipping duplicates and pools
   that do not exist:
   - P;
   - H;
   - `hierarchyDir(m.expected_root)` for every member `m` that has one.
   Attribution is by the existing rules, with §2.5 in place.
3. **Herdr arm**, with the §4.6 widening.

Merge and dedupe as today (`dedupPeers` `:4141`, by `transport_id ||
session_id`). The team file's row wins over a peers or herdr row for the
same pane.

### 4.2 Classification

| Candidate | Class |
|---|---|
| member of an owned or orphaned team file (§4.1 step 1) | `close` |
| live peers slot in scope, not a team member | `close`, as today (`source: "peers"`) |
| herdr agent admitted by today's filter and prefix | `close`, as today |
| herdr agent admitted only by the §4.6 widening and passing every §4.6 check | `close` with `stray: true` (R3) |
| `terminal` transport, or no `transport_id` | `not_closable: [{name, reason: "no pane"}]` |

`close_token` (`closeToken` `:4013`) and the `--confirm` gate
(`gateClose` `:4383`) are unchanged in mechanism and cover the whole
`close` set, strays included. A stray is therefore in the plan the person
sees before confirming.

### 4.3 Plan output (additive keys only)

Every existing key keeps its meaning. Added:

- `expected`: the size of `close`;
- `strays: [names]`;
- `not_closable`;
- `team_files: [paths read]`;
- `warnings: [string]`.

`{disbanded:false, reason:"no active team and no live peers"}` is returned
only when `close`, `not_closable` and every source are empty.

### 4.4 Close and verify

1. **Reuse check (herdr), just before each close.** Re-query `herdr agent
   list`, bypassing `queryHerdrTopology`'s per-process cache (`:3061`). If
   the pane now carries a name that parses (`hierarchyNameParts`) to a
   different prefix or role than the target, skip it. A stray must still
   carry exactly the name it was matched by. Each skip raises W5. An
   absent or unparseable name proceeds, as today.
2. Close with the existing `closeOne` / `closeMemberPane`.
3. **Verify.** Re-query fresh (herdr `agent list`; tmux `list-panes -a -F
   '#{pane_id}'`). Poll every 250 ms for up to 3 s until each target is
   gone. Use named constants, with a `ponytail:` comment that the deadline
   is a guess at herdr's close latency. If the query itself fails,
   nothing is verified: W6, and those targets count as not closed.
4. A result's `closed` means **verified gone**. The top-level `closed` is
   true only when all targets are gone **and `not_closable` is empty**
   (r3, §15.3: an empty close set over un-closable members is not
   success). Added keys: `expected`, `closed_count`, `still_live:
   [names]`, `strays`, `warnings`.
5. `reconcileAfterClose` runs per team file read (H and, on a split, P).
   It prunes and removes as today, each in its own file.
6. When `still_live` is non-empty, the exit status is the same as an
   existing `--close` whose close command throws. Read it and match it; do
   not invent a new code. **r3 (§15.4): checked, that status is 0. Exit 0
   stays;** the JSON carries the failure.

### 4.5 Warnings (loud failure)

Each warning is a full sentence that names counts and sources:

- **W1.** No team record for `<t>` in `<H>` (or `<P>`), but N live members
  were found via `<sources>`.
- **W2 (R3 residual risk), whenever `strays` is non-empty:**
  "Closing N herdr agents named `<t>-<role>` that are not in the team
  record: `<names>`. They are matched by name and checkout only. A live
  agent from another orchestrator in this repo or one of its worktrees,
  with the same name prefix, would be closed too."
- **W3.** Team `<t>` has records in both `<H>` and `<P>` (left by an older
  release). Both were read.
- **W4.** Team `<t>` in `<file>` belongs to another live orchestrator (pid
  P). Its N members were left alone.
- **W5.** Pane `<id>` now carries `<name>`, not `<target>`. It was not
  closed.
- **W6.** `<transport>` could not be queried. N targets are unverified.
- **W7.** After close, N are still live: `<names>`.
- **W8 (r5).** N members cannot be closed from here, because they have
  no pane: `<names>`. Close them by hand. Raised whenever `not_closable`
  is non-empty, on `disband` plan and close, and on the `dismiss` plan
  (r6). Without W8, this shortfall was a JSON key that the skill rule
  below does not mention.
  - **r6, `dismiss --close`:** no W8. A no-pane target keeps today's
    `fail()`: exit 2, "no addressable pane", no JSON, no gate (T9b). No
    caller can read exit 2 as success, which is all W8 exists to
    prevent, and keeping it avoids a CLI contract change.
  - **r6, `dismiss` plan:** today a no-pane target gives exit 0 JSON with
    `expected: 0`, no `next` and no warning. The skill stops there and the
    user hears nothing about a live session they must close by hand. That
    is the silent shortfall W8 removes, so the plan raises it.

**The agent-team skill** has disband and dismiss steps; find them with
`grep -n 'disband --plan\|dismiss' skills/agent-team/SKILL.md`. Those steps
must:

- show every warning and every `still_live` and `strays` entry to the
  user;
- never report success unless `closed: true` and `still_live` is empty.

This keeps the existing rule that "no live peers" is never a final answer
while live sessions exist.

### 4.6 The herdr arm: widened, with the stray safety checks (R3)

- **cwd filter (`:4210`).** Compare `checkoutRoot(realCwd(a.cwd))` with
  `checkoutRoot(realCwd(C))` (`lib-config.mjs:717`) instead of
  `findGitRoot`. A pane with no cwd is kept, as today. A pane in another
  repo is still excluded.
- **Prefix.** With `--team <t>`, only `<t>`, as today. With the default
  scope, today's `scopePrefix` **or** `basename(checkoutRoot(C))`.
- **A stray** is a herdr agent that today's filter and prefix would not
  have admitted. It is `close`d (R3) only if **all** of these hold:
  1. its `name || title` parses with `hierarchyNameParts` (`lib-config.mjs:476-485`, custom roles included) to the scope prefix and a role;
  2. that role is **not** `orchestrator` (`HIERARCHY_NAME_ROLES`
     includes it, `:468`; another orchestrator must never be a stray);
  3. it is not the invoking pane (`HERDR_PANE_ID`, as today);
  4. it is not a member, by pane id or name, of **any other** team file
     readable in H or P;
  5. the checkout matches (above).
- A match today's filter and prefix would admit keeps its current class.
  `test-roster-disband-herdr-only.sh` T1 and T3 still hold.
- **Spawn naming does not change** (`teamPrefix`, member names).

### 4.7 `dismiss`

`dismiss <name>` resolves through §4.1 and §4.6, with the same
classification, reuse check, verification and added keys (§4.4).

**r6, `not_closable` on dismiss.** It is on the plan output only, for both
the team-member path and the live-peer fallback path, and it is computed
as `disband` computes it for that source. Reuse `notClosableOf` and
`notClosableWarnings` (`roster.mjs` ~4657–4665) on the one resolved
target, passing the team's transport on the team path and `null` on the
peer path, as `disband` does (`roster.mjs` ~6002, ~6053). So dismiss
lists a target exactly when `disband` would list that member.
- **Plan, target in `not_closable`:** add the `not_closable` key, and
  add W8 to `warnings`. Everything else is unchanged: exit 0, `expected:
  0`, no `next`, `command: null`.
- **Plan, otherwise:** `not_closable: []`, and no W8.
- **`--close`:** unchanged. The no-pane `fail()`s (~6155 peer path,
  ~6178 team path) keep their text and exit 2, and the close output gets
  no `not_closable` key. A single-target close that got past those
  `fail()`s has nothing left unclosable.

### 4.8 `teams`

Rows come from the §2.3 team-name union. A row read from a legacy P file
carries `legacy_dir: P`; a split carries W3. `untracked_live` is computed
as today over the §4.1 sources (pools and widened herdr). The misplaced
pass uses member-level roots (§2.6). The field case now shows a row for
`<t>` and not `teams: []`.

## 5. Spawn-time warning (R4: warn, never block)

The spawn output gains `warnings` entries when:

- **(a)** the team's file exists in both H and P (a split): "team `<t>`
  has records in `<H>` and `<P>`";
- **(b)** `checkoutRoot(--cwd)` and `checkoutRoot(process.cwd())` are both
  non-null and differ: "team `<t>` is recorded in `<other checkout>`;
  teardown run from `<this checkout>` will not see it".

  `process.cwd()` is the calling shell's cwd, normally the
  Orchestrator's. A `ponytail:` comment names that as a heuristic.

Nothing is blocked. Spawning a main-checkout peer from a worktree
Orchestrator is legitimate, and no longer splits the team (§2.1).

## 6. Migration

No writes. A team recorded before r2:

- in a worktree pool only: found there (§2.3) and updated in place;
- split across H and P: unioned by teardown and `teams` (W3).

In the field case, the three main-checkout peers' record lives in H,
which a worktree invocation now reads.

Known limit: invoked from the **main** checkout (P = H), a legacy team
recorded **only** in a worktree pool is not seen. Covering it would mean
scanning `git worktree list`; every team written after r2 is in H.
`docs/cli-tools.md` states this limit.

## 7. Tests

**Ground rules:**
- Every case runs in its own `mktemp -d` that is checked to be non-empty.
- Git writes are `git -C "$T/…"`.
- `HOME` is sandboxed as the suite already does.
- Herdr is the PATH shim from `tests/test-roster-disband-herdr-only.sh`
  (`:36-57`, `run()` `:60`, `agent` helper `:68-77`), extended with the
  `pane split` and `agent start` support that `tests/test-roster-spawn-one.sh`
  uses.
- `pane close` removes the agent from `$FAKE_HERDR_STATE`; one mode
  leaves it listed (V2), and one renames it (S6).
- No real herdr, no real `claude`.

**Step 0, the repro gate (NEEDS-EVIDENCE E1, run first, on `581d3ba`).**

Setup:
- `git -C "$T/repo" init` with one commit;
- `git -C "$T/repo" worktree add "$T/repo/.claude/worktrees/w"`;
- a live owned pid via `--orchestrator-pid` (`sleep 300 &`, killed by a
  trap).

Steps:
1. `spawn-one` twice with `--cwd <worktree>` and three times with
   `--cwd <main>`, all `--team demo`.
2. Mimic each peer's SessionStart row in its own pool.
3. Run `disband --plan --team demo --cwd <worktree>`.

Expected: fewer than 5 in `close`, and the record split across two dirs.
Report which dir held each record. If it is **not** red, stop and return
to the Architect, because §1 is then wrong.

| # | Case | Expect | Red on `581d3ba`? |
|---|---|---|---|
| C1 | `spawn-one --cwd <worktree> --team demo` | `teams/demo.json` under `<main>/.claude/hierarchy/`, none under the worktree's; the launch's `AH_TEAM_FILE` is that path | yes |
| C2 | `create --spawn` then `--commit`, `--cwd <worktree>` | the same home | yes |
| C3 | `AGENT_HIERARCHY_DIR` set | the team file under it (unchanged) | guard |
| C4 | a plain checkout, no worktree | its own dir (unchanged) | guard |
| C5 | legacy `demo.json` only in the worktree pool; `spawn-one --cwd <worktree> --team demo` | member appended to the worktree file; no file created in main | guard (in place) |
| C6 | `demo.json` in both dirs; spawn | warning (a); teardown reads both, W3 | yes |
| C7 | `--cwd` in another scratch repo, process cwd in this one | warning (b) | yes |
| A1 | a worktree peer with `AH_TEAM_FILE=<main>/…/teams/demo.json` | `whoami` and attribution resolve `demo`; its peers row (worktree pool) is in scope | yes |
| M1 | member spawned `--cwd <main>` into a team created from the worktree | SessionStart `misplaced:false`; `checkin` exit 0; `teams` lists no misplaced member; the worktree gate does not offer relocation | yes |
| M2 | a member row without `expected_root` | team-level behaviour as today | guard |
| L1 | step 0 scenario after the fix; plan from the worktree **and** from main | `close` has all 5, `expected: 5` | yes |
| L2 | L1, then `--close --confirm --plan-token` | 5 `pane close`s logged; `closed: true`, `closed_count: 5`, `still_live: []` | yes |
| V1 | close succeeds | verified | guard |
| V2 | `pane close` ok but the agent stays listed | `closed: false`, `still_live: [name]`, W7, exit status as §4.4 | yes |
| V3 | `agent list` fails at verify | W6; `closed: false` | yes |
| W-1 | no team file in either dir; live peers rows | W1 | yes |
| S1 | no team row; herdr `myrepo-architect` with cwd = main; default scope from the worktree | in `close`, `stray: true`, W2 with the residual-risk sentence | yes |
| S2 | herdr `myrepo-orchestrator` | not matched | guard |
| S3 | herdr `other-architect`, or an unparseable name | not matched | guard |
| S4 | stray cwd in another repo | not matched (T3 still holds) | guard |
| S5 | stray name is a member of another team file in H | not matched | yes |
| S6 | agent renamed between plan and close | not closed; W5 | yes |
| S7 | legacy P team file owned by another live pid | its members skipped; W4 | guard |
| H2 | existing `test-roster-disband-herdr-only.sh` | passes unchanged | guard |
| D1 | `dismiss <stray> --close` | closed and verified | yes |
| D2 (r6) | `dismiss <m>` plan, where `<m>` has no pane: (i) a team member on `terminal` transport or with null `transport_id`; (ii) a live peer record with no `pane_id` | exit 0; `expected: 0`; no `next`; `not_closable: [{name: <m>, reason: "no pane"}]`; one W8 naming `<m>` | yes, red on `55af506` or later |
| D3 (r6) | `dismiss <m>` plan, where `<m>` has a pane | `not_closable: []`; no W8 | guard |
| T9b | `dismiss <no-pane> --close` (existing test) | still exit 2, "no addressable pane", zero closes | guard, unchanged |
| T1 | `teams` from the worktree after step 0 | a `demo` row; not `teams: []` | yes |

Every "red" case must be shown failing on `581d3ba` before it passes.
Report the red→green list.

**Expected fallout.** List every existing test whose expectation changes
because of R1, such as a test asserting that a worktree gets its own team
file. For each, say why the new expectation is R1's intent. Do not bend
any other test to pass.

Run the full `ah` suite with output to a file and a timeout on every
headless run. Afterwards, check `pgrep -fl herdr`, `pgrep -fl claude` and
`pgrep -fl sleep` for anything this suite started.

## 8. What must not change

- The team-file **schema**, except the additive member `expected_root`.
- Team ownership and every existing guard.
- Spawn naming and prefixes.
- `peers.jsonl` location, rows and writers.
- `msgs/`, gates, decisions and status locations. One exception, from
  r3: `msg new --to-name` picks its pool per §15.1.
- `close_token` and the `--confirm` gate mechanism.
- Every existing output key's meaning, except that `closed` now means
  verified.
- The class of any herdr match today's filter admits.
- `whoami`'s answers for a normal checkout.

## 9. Implementor order

0. Step 0 repro (E1). It is red on `581d3ba`, or stop.
1. The pool → home mapping inside the `lib-roster.mjs` primitives (§2.2),
   the legacy rule (§2.3), and team history. Then the path-literal sweep
   and the `envTeamFile` homes (§2.5). Tests C1–C5, A1.
2. Member `expected_root` (§2.6). Tests M1, M2.
3. Teardown sources and classification (§4.1, §4.2), the herdr widening
   and stray checks (§4.6), and `dismiss` and `teams` (§4.7, §4.8). Tests
   L1, W-1, S1–S5, S7, H2, D1, T1.
4. Reuse check, close-verify and warnings (§4.4, §4.5). Tests L2, V1–V3,
   S6.
5. Spawn warnings (§5). Tests C6, C7.
6. The agent-team skill's disband and dismiss steps (§4.5), done by the
   implementor. Then **docs-writer**, which r3 moves to after step 15
   and widens (see step 15):
   - `docs/cli-tools.md`: the team home, the added keys, `closed`, the
     stray rule and its residual risk, and the §6 limit;
   - `docs/team-file.md`: the home, legacy-in-place, and member
     `expected_root`;
   - `docs/troubleshooting.md`: the repo-wide team names of §2.7;
   - CHANGELOG.
7. Release `ah` **0.113.0** (minor). 0.110.0–0.112.1 are held by the
   unmerged 0071 branch. **Whichever of 0071 and 0072 merges to main second
   re-bumps to the next minor above main at merge time.** Bump every
   declaration of `ah`'s version: `agent-hierarchy/.claude-plugin/plugin.json`,
   and the `ah` entry of the root `.claude-plugin/marketplace.json` if it
   carries one.
8. Full suite and process check (§7). No push. The Orchestrator routes
   commits.

**r3, on top of `e654823`.** The version stays 0.113.0, already bumped.
Commit each step separately. Red first throughout.

9. **E3, which only the Orchestrator can supply (§11).** Fold its fixture
   in before step 14's UserPromptSubmit handler. Steps 10–13 do not wait
   for it.
10. **Gap 2 (§15.2).** `AH_EXPECTED_ROOT` in the launch settings env, and
    the resolution order. Tests M3, M3b, with M2 as the guard.
11. **Gap 3 (§15.3).** No code. Add test V4 if it is missing. Gaps 1 and 4
    need no code (§15.1, §15.4).
12. **L1 (§14.3).** Arming on the shared token grammar plus the role
    match. Tests RB1–RB4.
13. **L2 (§14.4).** Dispatch row `path` / `to_addr`, liveness by path,
    `seen` / `surfaced`, landed-unread. Tests RB5–RB8.
14. **L3 (§14.5).**
    - the `notify_when_idle` rule in `pretooluse-msg-gate.mjs` (RB9);
    - the idle-notice handler, built against the E3 fixture
      (RB10–RB12);
    - the two lines in `agents/orchestrator.md`;
    - then RB13.

**r4 steps, before step 15.** They land on top of steps 10–14 without
rework, except for the two deltas marked below.

14a. **L3 rewritten against E3 (§14.5).** Covers dedupe, the
     unknown-shape fail-open, the "may be waiting" line, and removal of
     the status-query and re-subscribe lines. Tests RB11 (revised), RB14,
     RB15. *Delta if step 14 is already built:* only the no-response
     branch and the dedupe change.
14b. **The landed definition (§14.4 item 3):** authored content and
     `LANDED_QUIET`, one shared definition for L2 and L3. Test RB16.
     *Delta if step 13 is already built:* the landed predicate only.
14c. **Move `thresholdFor` / `dueForNudge` and their gate helpers into a
     shared lib.** This is a pure refactor; every existing liveness test
     stays green.
14d. **The watcher script (§14.9.1–§14.9.3),** with the `heard`,
     `watcher`, `watch-event` and `watch-consumed` rows, the
     UserPromptSubmit injection, and the in-flight exclusion. Tests
     WA1–WA8, WA11–WA13. Fold in E5's result first (§11).
14e. **Start and enforcement (§14.9.4):** the PostToolUse hint, the Stop
     block, and the `agents/orchestrator.md` line, which replaces the
     `ScheduleWakeup` prose. Tests WA9, WA10.

Step 15's docs-writer list gains the watcher: what it is, how to start
it, and the wake text.

**r5 deltas, on top of `55af506`, in any order before step 15:**

- **G1.** W8 on disband plan and close (§4.5); V4 asserts it. r6
  narrows dismiss to the plan only (next bullet).
- **r6, dismiss W8 (§4.5, §4.7).** On the dismiss plan, add
  `not_closable` and W8 on both paths. Leave `--close` and T9b
  untouched. Tests D2 (red first) and D3. At step 15, docs-writer
  describes W8 as raised on disband plan and close and on the dismiss
  plan, not disband-only, and says `dismiss --close` on a no-pane target
  fails with exit 2.
- **G2.** L1 arm (b) uses the persisted role as well (§14.3). Tests
  RB1 (revised), RB1c, RB1d. Use the same role resolution in the
  UserPromptSubmit hook's Orchestrator branch: a session is an
  Orchestrator when its role is null or `orchestrator`, never a
  subordinate role.
- **G3.** If 14a is built, change only the fail-open line's text
  (§14.5 step 2).
15. **Full suite and the `pgrep` check (§7).** Then **docs-writer**:
    - step 6's list;
    - the doc that describes the peer report-back contract (find it with
      `grep -rln 'hierarchy-peer-brief\|report-back' docs/`): the three
      layers, the `notify_when_idle` dispatch rule, landed-unread, the
      token grammar, and `AH_EXPECTED_ROOT`;
    - the 0.113.0 CHANGELOG entry covers r2 and r3.

    No push.

## 10. Decisions

**User rulings (decided):**

- **R1.** No ledger. The team file is the master list, with one home in
  the main checkout's hierarchy dir (§2).
- **R2.** Ownership is unchanged: `teamOwnedBy` (§3).
- **R3.** Herdr name-matched panes outside the team file are
  auto-closed, under the §4.6 checks, with the residual risk stated in W2.
- **R4.** Warn at spawn on a split; never block (§5).

**Raised by r2 (for the Orchestrator to put to the user; defaults
apply):**

- **D1, legacy teams updated in place** (§2.3). This refines R1's "every
  spawn records its member there". **Default: in place.** Writing a new
  member to the home would split a team that predates r2.
- **D2, one team namespace per repo** (§2.7). Two Orchestrators in
  different worktrees can no longer both use the default team or the same
  `--team`; the second meets the existing collision and ownership
  handling. **Default: accept**, since it follows from R1 and no current
  flow depends on per-worktree teams. The alternative, keeping the
  default `team.json` per worktree, would reintroduce a split for the
  default team.

**r3, user ruling:** report-back enforcement is folded into 0072 (§14),
with layers L1–L3.

**r3, decided by the Architect, none needing the user:**
- **gap 1:** keep (§15.1);
- **gap 2:** change, inject `AH_EXPECTED_ROOT` (§15.2);
- **gap 3:** keep (§15.3);
- **gap 4:** keep exit 0 (§15.4).

Gap 4 is the only one the user might want otherwise. A non-zero exit on
`closed: false` is a separate CLI contract change. Say so if it is
wanted.

## 11. NEEDS-EVIDENCE

| # | Run | Decides |
|---|---|---|
| E1 | §7 step 0 on `581d3ba`, sandboxed, with the herdr shim | Red with fewer than 5 in `close` and the record split → build on. Not red → return to the Architect with where each record landed. |
| E3 | Done live by the **Orchestrator**, no sandbox needed. Its next real peer dispatch carries `notify_when_idle: true`; it waits for the idle notice. Then a task-runner greps that Orchestrator's transcript (`~/.claude/projects/<slug>/<session>.jsonl`) for `idle notice` and reports: (1) the exact notice text, verbatim; (2) whether it is a `"type":"user"` entry with a `promptId` and is followed by userpromptsubmit `hook_additional_context`, which shows that UserPromptSubmit fired; (3) the name form X takes in it, compared with the `to` used. If possible, also capture an expiry notice and an exit notice. | (2) yes → build §14.5's handler against (1) as a test fixture, matching X to `to_addr` per (3). (2) no → apply §14.5's fallback paragraph and add its gap to §12. **r4: answered**, in `.claude/hierarchy/msgs/0072-E3-idle-notice-evidence.md`. (2) is yes; X is exactly `to`; re-subscribing re-fires a stale notice; no expiry or exit notice was seen. Applied in §14.5. |
| E5 (r4) | The **Orchestrator**, live. (a) Start `Bash` with `run_in_background:true`, `sleep 1500; echo ok`; end the turn. Report whether it completes at about 25 min with exit 0, or is killed earlier, and when. (b) Optional: after the session exits, `pgrep -fl 'sleep 1500'`. | (a) It survives → §14.9 as written. Killed at N min with N < 60 → set `WATCH_MAX` to N − 1 min, and accept one wake per N − 1 min while anything is watchable; state it in §12. (b) It survives the session → §14.9's orphan exit is load-bearing (it is required anyway). |

## 12. Risks

- **R3's residual risk.** A stray is matched by name and checkout. A live
  agent from another orchestrator in the same repo, carrying the scope's
  prefix and not in any readable team file, is closed. This now needs a
  legacy team recorded only in a sibling worktree, or an untracked
  hand-launched agent, because §2.7 makes live team names unique per
  repo. W2 states it in every plan that has strays, before the
  confirm.
- **Primitive-level mapping.** It covers all 99 sites at once, which is
  the point. It also means any site that assumed "team file is in my
  pool" now sees the home. The expected-fallout list (§7) is how the
  Reviewer checks that.
- **`closed` now means verified.** A caller that read `closed: true` as
  "commands ran" sees `false` when panes linger. That is intended; the
  skill is updated in step 6.
- **Cross-spec: 0071.** `lib-status.mjs` (0071 branch) computes a
  pool's status from its teams. Through the primitives it will see the
  home's teams once both branches are on main, so a worktree's status file
  then lists the repo's teams. Whichever branch merges second: its
  Reviewer checks that the 0071 status tests still hold, or routes it to
  the Architect.
- **r3 report-back residual.** Finished work stays unseen only if all of
  these fail together:
  - L1 (the peer's obligation was not armed, or its 2-nudge budget was
    spent);
  - L3 (no idle notice reached the Orchestrator, or it arrived early,
    while the peer was waiting on background work, and was not renewed);
  - L2 (the Orchestrator never ends another turn).

  One more case: an orphaned in-flight record makes `stop-peer-nudge`
  defer for up to `SUBAGENT_INFLIGHT_TTL_MS` (1 h). If the peer then
  sits idle, L1 never re-runs, and L3 is what covers it.

  r4 adds L4, so an idle Orchestrator is woken on a timer whatever the
  peer does. The residual then needs L4 to fail as well: the watcher was
  never started (one Stop block asks for it), or it died without a wake.
- **r4 L4 cost.** A wake costs one Orchestrator turn. The per-request cap
  (§14.9.2) bounds this at 3 wakes per silence window. An Orchestrator
  with many slow dispatches is still woken once per dispatch per window;
  that is the point of the timer.
- **r4 L4 depends on the harness.** If a future Claude Code inlines
  stdout, or stops re-invoking idle sessions on background exit, the
  watcher stops waking anyone. The store-based injection keeps working
  on the next prompt, and L2 and L3 remain.
- **r3 L1 widening.** Arming without anchoring trades the
  anchoring-based guard for a role match. A session with a resolvable
  role, receiving a quoted request addressed to its **own** role, now
  arms an obligation it may not owe. The worst case is two nudges, and
  one "cancelled" reply resolves it (`stop-peer-nudge.mjs:57-61`).

## 13. Changes r1 → r2

- Dropped the spawn ledger (old §2, §2.5, ledger tests L3–L9, P1, U1, and
  the home-dir audit), per R1.
- New §2: the team home, primitive-level mapping, legacy in place, and
  member `expected_root`. The member root is new: r1 had no shared team
  file, so it had no misplaced problem.
- §3: `teamOwnedBy` only. The orphan rule and other-spawner rule for
  ledger rows are gone (R2).
- §4.6: strays are closed, not `unconfirmed` (R3). Checks were added:
  role ≠ orchestrator, not another team's member, and a reuse check at
  close.
- §10: rulings recorded; D1 and D2 raised.
- Ultra-Advisor: r1 advised a second opinion because a ledger would have
  been a new authority over which panes close. r2 adds no new authority.
  R3 widens the close set by the user's informed ruling, under the §4.6
  checks, and is visible in the plan before the confirm. The Reviewer
  covers it; no Ultra-Advisor is needed.

## 14. Report-back: finished work is never left unseen (r3 headline)

User priority: *"I can't have agents not responding when their work is
done."* Folded into 0072 and released with it as 0.113.0.

### 14.1 The field incident and its root causes (traced, no run needed)

Two Implementors each wrote their response file, ended the turn without
`SendMessage`, and sat idle for 2–4 h. The Orchestrator never woke.

**Peer side: the obligation was never armed.**
- The Orchestrator's dispatch text was `Implement spec … . [hierarchy-msg
  <request path>]`, with the token at the **end** of the first line
  (the Orchestrator transcript shows both `SendMessage` inputs this way).
- The receiver arms a report-back obligation only when the token is at
  **index 0** of the first non-blank line (`extractPendingRecord`,
  `hooks/lib-peer.mjs:150-151`, `MSG_TOKEN_LINE_RE` `:94`).
- The sender records the dispatch with the **unanchored** parser
  (`extractMsgToken`, `MSG_TOKEN_RE` `hooks/lib-hier.mjs:42`, called by
  `posttooluse-peer-resolve.mjs:59-63`).
- So the two ends disagree on the token grammar. Evidence:
  - `~/.claude/agent-hierarchy.peer-pending.jsonl` holds the
    Orchestrator's `dispatch` rows for both request ids, and **no**
    obligation row for either.
  - Neither Implementor transcript contains the `stop-peer-nudge` text.
  - In one Architect session, three briefs with the token at line end
    armed nothing, and two that opened with the token armed normally.
- With nothing owed, `stop-peer-nudge.mjs:118-119` allowed every Stop.

**Orchestrator side: three gaps in the spec-0028 §5 liveness hook
(`hooks/stop-orchestrator-liveness.mjs`):**
1. **It runs only at the Orchestrator's own Stop.** An idle Orchestrator
   never stops, so nothing ever runs. Spec 0028 §5.7's timer layer depends
   on `ScheduleWakeup`, which exists only in `/loop`; no hook can wake a
   session.
2. **A response file closes the exchange silently.** The hook defines
   "open" as "no response file with the same id" (`lib-hier.mjs:415`), so
   a reply that was written but never sent looks exactly like one that
   was answered.
3. **It scans one pool.** `dir = hierarchyDir(cwd)` (`:147`). After gap 1
   (§15.1), a request to a main-checkout member lands in the main pool,
   which a worktree Orchestrator's liveness hook never scans.

### 14.2 Design: three independent layers

Each layer alone surfaces the field case. Finished work stays unseen
only if all three fail.

| Layer | Where | What it guarantees |
|---|---|---|
| L1 peer Stop | the peer session | it cannot go idle with an unsent report (bounded) |
| L2 Orchestrator Stop | the Orchestrator session, whenever it ends a turn | a report that landed but was never sent is surfaced; liveness sees every dispatch, whatever pool it is in |
| L3 idle wake | Claude Code's `notify_when_idle` plus the Orchestrator's UserPromptSubmit | an idle Orchestrator is woken when the peer goes idle, even if the peer never reports |
| L4 timer wake (r4, §14.9) | a background Bash watcher the Orchestrator starts; its exit wakes the session | an idle Orchestrator is woken at a dispatch's eta, even when the peer never goes idle (hung, or busy for ever) or is idle-waiting on its own background work |

The Orchestrator is any session that is not positively a subordinate
role, the same test the liveness hook uses (`resolveHierarchyRole`,
`stop-orchestrator-liveness.mjs:129-130`). Subagents are exempt
everywhere (`isSubagent`).

### 14.3 L1: one token grammar on both ends

File: `hooks/lib-peer.mjs` (`extractPendingRecord`).

An obligation is armed, with `armed_by: "msg-token"`, when the delivered
prompt has a parseable `<cross-session-message>` wrapper and either of
these holds:

- **(a) As today.** The first non-blank line after the wrapper tag
  **starts** with a request token. Unchanged.
- **(b) New.** The wrapped body contains a request token, found with the
  same parser the sender uses (`extractMsgToken`; reuse it, do not write a
  second regex). The path must:
  - end `--request.md`;
  - exist, and parse with `parseMsgFilename` as type `request`;
  - have frontmatter `to` equal to the receiving session's role. That
    role is `resolveHierarchyRole(input).role`, **whether `direct` or
    persisted** (r5).
    - Why the persisted role is exact here: the UserPromptSubmit hook
      already skips subagents (`isSubagent`,
      `userpromptsubmit-peer-tracking.mjs:55`), so the caller at
      UserPromptSubmit is always the session itself.
    - `resolveHierarchyRole`'s warning, that a subagent shares its
      parent's `session_id` (`lib-config.mjs:618-622`), therefore does not
      arise.
    - The persisted role is written at SessionStart, whose payload does
      carry `agent_type` for `--agent` sessions. So arm (b) does not
      depend on whether the UserPromptSubmit payload carries `agent_type`,
      and no evidence run is needed.
    - Do not add a second role source such as `peers.jsonl`; the
      session-role map is the existing one.

The role match replaces anchoring as the guard against phantom
obligations. Anchoring exists so that a reply quoting a brief arms
nothing. With (b), a quoted request addressed to another role still
arms nothing, and a session with no resolvable role arms only via (a).

The obligation record's shape, the sentinel path, `MAX_NUDGES`,
`stop-peer-nudge.mjs` and `posttooluse-peer-resolve.mjs` resolution are
all **unchanged**. Once armed, the existing Stop block applies, and it
already says "Writing the response file is not delivery"
(`stop-peer-nudge.mjs:89`).

### 14.4 L2: the Orchestrator's Stop sees every dispatch and every landed report

Files: `hooks/posttooluse-peer-resolve.mjs`, `hooks/lib-peer.mjs`,
`hooks/stop-orchestrator-liveness.mjs`,
`hooks/userpromptsubmit-peer-tracking.mjs`.

1. **Dispatch rows carry where the request is.** A new `dispatch` row
   gains two additive fields:
   - `path`, the request path exactly as parsed from the message;
   - `to_addr`, the `SendMessage` `to` with `stripRef` applied.

   Existing rows stay as they are.
2. **Liveness by path.** For this session's dispatch rows that carry
   `path`, latest row per `request_id`:
   - Look up the exchange in the request's **own** msgs dir, the
     dirname of `path`, with the existing exchange listing
     (`listExchanges` / `openExchanges`). Do not use `hierarchyDir(cwd)`.
   - The team filter is skipped, because the dispatch row already proves
     this session sent it. The `fm.from === "orchestrator"` check stays.
   - An open exchange then goes through the **unchanged** eta /
     `dueForNudge` / check-in logic.
   - Rows without `path` (from before this change) keep today's pool
     scan exactly.
3. **Landed but unread.** For those path-bearing rows, an exchange is
   *landed-unread* when all of these hold:
   - its response file has **authored content**;
   - the file's mtime is at least **`LANDED_QUIET` = 120 s** old;
   - there is no `seen` or `surfaced` row for (session, request).

   Why r4 adds the content and age conditions:
   - `msg new` creates the response stub well before the peer finishes,
     so "exists" is not "written".
   - The quiet period gives a peer that is about to `SendMessage` the
     chance to do so before anyone else surfaces the file.
   - Reuse the existing authored-content check behind
     `validateResponseToken` / `hasResponseToken` (`lib-hier.mjs:591-611`,
     `:664-677`).
   - This single definition serves L2, L3 and L4; there are no per-layer
     copies.

   A landed-unread item is handled as follows:
   - It is reported at once, with no eta gate.
   - All landed-unread items go into one block, together with any
     check-in items. The block names role, `to_name`, request id and the
     **response path**, and says: "the peer wrote this report but never
     sent it to you; read it now".
   - On blocking, append a `surfaced` row per item, so each report is
     surfaced by this hook at most once.
   - `stop_hook_active` still allows (`:132`), so one Stop cycle costs
     at most one block.
4. **`seen`.** In UserPromptSubmit, a wrapped delivery whose
   `extractMsgToken` path ends `--response.md` gets a `seen` row when its
   id matches one of this session's dispatch rows. Mid-turn deliveries
   count: UserPromptSubmit fires for them too, because an obligation in
   this Architect session was armed by a brief that arrived mid-turn.
5. **Migration.** Landed-unread applies only to rows that carry `path`.
   An existing session's hundreds of old dispatch rows therefore never
   flood a block.
6. **The new row types.** `seen` and `surfaced` live in the same
   append-only store as `dispatch`, `~/.claude/agent-hierarchy.peer-pending.jsonl`;
   no new file. Like `dispatch` rows, they must never appear in
   `pendingFor` or `latestByKey` results for obligations.

### 14.5 L3: dispatch with `notify_when_idle`, and handle the idle notice

Built into Claude Code: `SendMessage` with `notify_when_idle: true` is
one-shot and main-conversation only. Exactly one `[Cross-session idle
notice]` arrives when the target next goes idle or exits, or an expiry
notice if it never does. A notice is delivered like any cross-session
message, so it wakes an idle session.

**Enforcement: `hooks/pretooluse-msg-gate.mjs`**, which already gates role
dispatches on `SendMessage`. Its rule:

- **Applies to** a `SendMessage` sent from an Orchestrator session (not
  a subagent). Its `to` is non-empty and not `main`, and its message
  carries a request token (`extractMsgToken`, path ending
  `--request.md`).
- **Trigger:** `notify_when_idle !== true`.
- **Action:** deny with this reason: "ah: dispatch with
  `notify_when_idle: true`, so that a peer going idle wakes you even if it
  never reports. Re-send this exact SendMessage with `notify_when_idle:
  true` added. If the tool rejects that field for this target, re-send
  without it; request <id> will not be asked about again."
- **Bound:** at most one deny per (session, request id). Record it as a
  `notify-deny` row in the same store. The next send for that id passes
  either way.
- **Exempt:** a peer's reply (positively a subordinate role), and a
  message with no request token.

**Directive:** in `agents/orchestrator.md`, add one dispatch line and one
idle-notice line to the dispatch guidance. Locate it with `grep -n
'hierarchy-msg' agents/orchestrator.md`. The dispatch line: dispatch
`SendMessage` carries `notify_when_idle: true`. The idle-notice line: act
on the lines ah injects when an idle notice arrives. The hook enforces;
the text keeps the first attempt right.

**Idle-notice handling: `hooks/userpromptsubmit-peer-tracking.mjs`**,
for Orchestrator sessions.

**r4: rewritten against E3's result (§11).** UserPromptSubmit fires for
idle notices. The notice format is:

`[Cross-session idle notice] "<name>", which you asked to be notified
about, is idle now — it finished a turn at HH:MM. Its harness reports:
«<about 100 chars of the peer's last text>…». This is an automated
notice …`

`<name>` is exactly the `to` that was passed to `SendMessage`, so it
compares directly with `to_addr`. E3 also found two things the handler
must respect:
- **A stale fire.** Re-subscribing to a peer that is *already* idle
  fires at once, with the **same** notice.
- **An idle peer may not be done.** It may be waiting on its own
  background work.

Expiry and exit notices were never seen in about 54 idle events.

**The handler.** When the prompt carries a `[Cross-session idle notice]`
naming X:

1. **Dedupe.** If (X, HH:MM, excerpt) equals the last notice recorded for
   this session and X, inject nothing. Otherwise record it as an
   `idle-seen` row in the same store.
2. **Unknown shape.** If the body lacks "is idle now", fail open. Inject
   "ah: idle notice about X not recognised: «`<first 200 chars>`». Call
   ListAgents. If X is gone and has open requests (`<ids>`), tell the
   user. If X is alive, there is nothing to do; the dispatch watcher
   keeps time." There is no other action.

   An exit notice and an expiry notice cannot be told apart, since
   neither has been seen. Both land here, and this line is right for
   both. r5 accepts this; do not try to distinguish them.
3. Otherwise, take this session's path-bearing dispatch rows with
   `to_addr` = X, latest per request, that have no `seen` or `surfaced`
   row. Inject one line per request:

| Request state | Injected line |
|---|---|
| landed-unread (§14.4 item 3) | "X is idle; its report for `<id>` landed but was never sent to you: `<response path>`. Read it now." Append `surfaced`. |
| a response was authored but is younger than `LANDED_QUIET` | nothing; L4 reports it once it is quiet |
| no response | "X is idle with no report for `<id>` yet. It may be waiting on its own background work. Nothing to do now; the dispatch watcher (§14.9) checks in at `<eta time>`." |

- **No matching row:** inject nothing.
- **The handler never sends or asks for a status query, and never asks
  for a re-subscribe.** A re-subscribe to a still-idle peer re-fires at
  once (E3), which is a loop. Timed follow-up belongs to L4 (§14.9).
- **Never blocks.** It only injects.

The idle-notice line in `agents/orchestrator.md` says: act on ah's
injected lines; do not re-subscribe to an idle peer.

### 14.6 Bounds: nothing here can wedge a session

| Mechanism | Bound |
|---|---|
| L1 peer block | unchanged: `MAX_NUDGES` = 2 per obligation on peer-driven turns, then `waived`; one block per user-driven turn |
| L2 landed-unread | one block per (session, request), ever; `stop_hook_active` allows |
| L2 check-in | unchanged eta cadence |
| L3 deny | one per (session, request id) |
| L3 injection | never blocks; one injection per distinct notice (dedupe) |
| L4 watcher (r4) | one process per session; at most 3 wakes per request per silence window (landed, check-in, silent); a 15 s poll; exits when orphaned; a 12 h lifetime cap |
| L4 start nudge (r4) | one Stop block per (session, latest dispatch id) |
| any hook error | allows, as today |

### 14.7 What must not change

- The sentinel path and the anchored msg-token path of
  `extractPendingRecord`.
- The obligation record shape and `MAX_NUDGES`.
- `stop-peer-nudge.mjs`, `pretooluse-sendmessage-response.mjs`, and
  resolution in `posttooluse-peer-resolve.mjs`.
- The liveness eta thresholds, `dueForNudge`, the check-in wording, and
  pool-scan behaviour for rows without `path`. In r4, `thresholdFor` and
  `dueForNudge` move into a shared lib for L4 (§14.9.2), with their
  behaviour unchanged.
- `msg.mjs` verbs and the message file format.

### 14.8 Tests

Ground rules:
- Each case sandboxes `HOME`, since the store is
  `~/.claude/agent-hierarchy.peer-pending.jsonl`, and uses its own
  `mktemp -d`, checked non-empty.
- Hooks are driven with stdin JSON, the way the existing
  `stop-peer-nudge` and liveness tests do. No real `claude`.

Every "red" case fails on `e654823` first.

| # | Case | Expect | Red on `e654823`? |
|---|---|---|---|
| RB1 (r5) | field case. Run SessionStart with `agent_type: ah:implementor` for session S, in the sandboxed `HOME`, which persists the role. Then UserPromptSubmit for S **with no `agent_type`**: wrapper plus `Implement spec X. [hierarchy-msg <req>]`, token mid-line; req `to: implementor`. Then Stop | obligation armed; Stop blocks with the owed text | yes |
| RB1c (r5) | as RB1, with `agent_type` present in the UserPromptSubmit payload too | armed | yes |
| RB1d (r5) | as RB1, but no SessionStart was run (no persisted role, no `agent_type`) | nothing armed by (b) | guard |
| RB2 | as RB1, session role `reviewer` | nothing armed | guard |
| RB3 | token at the start of the first line | armed, as today | guard |
| RB4 | wrapped reply carrying `[hierarchy-msg …--response.md]` | nothing armed | guard |
| RB5 | Orchestrator dispatch row with `path` in a pool other than `hierarchyDir(cwd)`, past eta, no response | Stop blocks with the check-in | yes |
| RB6 | path-bearing dispatch row; response exists; no `seen` | Stop blocks once, naming the response path; the next Stop cycle allows | yes |
| RB7 | as RB6, but a wrapped reply carrying the response token arrived first | `seen` written; Stop allows | guard |
| RB8 | legacy dispatch row with no `path`; response exists | no landed-unread block | guard |
| RB9 | Orchestrator `SendMessage` with a request token and no `notify_when_idle` | denied once with the reason; identical retry allowed; with the flag, allowed; a peer's reply allowed | yes |
| RB10 | idle notice (E3 fixture) for X; X's response exists | `additionalContext` names the response path; `surfaced` written; the next Stop does not block on it | yes |
| RB11 (r4) | idle notice for X; no response | the "may be waiting … watcher checks in at `<time>`" line; no status query, no re-subscribe | yes |
| RB12 | idle notice for an X with no dispatch row | no injection | guard |
| RB13 | end to end: RB1's peer never sends (budget waived), then RB10 | the Orchestrator learns of the report through L3, and through L2 if L3's injection is skipped | yes |
| RB14 (r4) | the same notice (X, HH:MM, excerpt) delivered twice | second delivery: no injection | yes |
| RB15 (r4) | a `[Cross-session idle notice]` without "is idle now" | the fail-open line | yes |
| RB16 (r4) | response authored, mtime 30 s ago; Stop, then an idle notice | neither surfaces it yet (`LANDED_QUIET`) | yes |

The RB10, RB11 and RB14 fixtures are E3's verbatim notice, with the name
replaced by a generic one such as `demo-implementor`.

### 14.9 L4: the background dispatch watcher (r4, user ruling)

**Why.** Spec 0028 §5.7's timer used `ScheduleWakeup`, which exists only
in `/loop`, so ordinary sessions have no timer. L3 wakes the Orchestrator
only when a peer goes idle. It cannot help with:
- a peer that is hung, or busy for ever, which never goes idle;
- a peer idle-waiting on its own background work, which looks idle but
  is not done (E3).

**Mechanism, shown live by the Orchestrator in CC 2.1.289:**
- A `Bash` call with `run_in_background: true`, started by the
  Orchestrator, wakes the Orchestrator when it exits, even if the
  Orchestrator is idle.
- The wake is a `<task-notification>` naming the Bash `description` and
  the exit code. Stdout is **not** inlined; only the output-file path is.
- UserPromptSubmit fires on that wake.

So the watcher speaks through its exit, and its findings reach the
Orchestrator by way of the report-back store and UserPromptSubmit.

#### 14.9.1 What it is

One new node script under `hooks/`. The Implementor picks the name. It
takes the Orchestrator's session id and cwd as arguments, and it is
**one process per Orchestrator session**, not one per request. It is
**not** a hook registration.

- **Singleton.** At start, it appends `{type:"watcher", session_id, pid,
  started}` to the store. If the latest `watcher` row for the session
  names a pid that is alive (`process.kill(pid, 0)`), it exits at once
  with code 0 and the line "already running (pid N)". A `ponytail:`
  comment says that pid reuse can fake liveness, which is acceptable
  because L2 and L3 remain.
- **Poll.** Every `WATCH_POLL` = 15 s (a named constant), it reads the
  store, and for each of the session's watchable dispatches evaluates
  §14.9.2. The poll period may be overridden by an environment variable,
  **for tests only**.
- **Watchable** means a path-bearing dispatch row of this session,
  latest per request, with no `seen` or `surfaced` row, that has not used
  up its wakes (§14.9.2).
- **When nothing is watchable,** it keeps polling and does **not** exit,
  because an exit is a wake. A later dispatch is picked up by the running
  process.
- **It exits only:**
  - with events, exit code **3**;
  - when orphaned, i.e. its parent is gone or `process.ppid` is 1, with
    code 0;
  - at the lifetime cap `WATCH_MAX` = 12 h, with code 0 (a `ponytail:`
    comment);
  - on a signal.
- **Never throws.** Any error is logged with `logHookError` and the
  process exits 0.

#### 14.9.2 The schedule (spec 0028 §5.7.2, made concrete)

For each watchable request, T = `thresholdFor(eta)`: small 5 min,
medium 10 min, large 20 min. The base is the latest of:
- the request's `created`;
- the latest `heard` row from X.

A **check-in** is any `liveness-nudge` gate row for (session, request),
in `gates.jsonl` of `hierarchyDir(--cwd)`. Those are the same rows the
Stop hook writes (`stop-orchestrator-liveness.mjs:152-156`), so L2 and
L4 share one record of check-ins. Let k be the number of check-ins after
the base.

| Condition, checked in this order | Event | Store writes |
|---|---|---|
| landed-unread (§14.4 item 3) | **LANDED** | `surfaced` |
| k = 0 and now ≥ base + T | **CHECK-IN** | a `liveness-nudge` gate row |
| k = 1 and now ≥ (that check-in) + T/2 | **SILENT** | a `liveness-nudge` gate row |
| k ≥ 2 | none; the request has used its wakes until the base moves | — |

- **`heard` (new row type, written by UserPromptSubmit).** When a
  wrapped delivery's `from-name` equals the `to_addr` of one of this
  session's dispatch rows, append `{type:"heard", session_id, from, ts}`.
  A peer that answers a status query with "still working" therefore
  restarts the schedule, and is never reported SILENT while it is
  talking. Idle notices are **not** `heard`.
- **One cadence implementation.** The T and T/2 arithmetic, and the
  reading and writing of gate rows, are shared with the Stop hook.
  Move `thresholdFor` / `dueForNudge` and their gate helpers into a
  `lib-*.mjs` that both use. The Stop hook's behaviour is unchanged, and
  its existing tests must stay green.
- All events found in one poll are written together, then the process
  exits 3.

#### 14.9.3 How the events reach the Orchestrator

1. Before exiting, the watcher appends one `{type:"watch-event",
   session_id, request_id, kind, text, ts}` row per event. It also prints
   the same text to stdout, as a fallback the Orchestrator can read from
   the output file.
2. The exit wakes the Orchestrator, and UserPromptSubmit fires.
   `userpromptsubmit-peer-tracking.mjs`, for an Orchestrator session,
   injects every unconsumed `watch-event` row for the session, then
   appends a `watch-consumed` row up to the last `ts` injected.
   - This keys on the store, **never on paths named in the prompt**. A
     forged notification that names an arbitrary output file must not get
     a file read into context.
   - It runs on every Orchestrator prompt, so a missed wake is caught on
     the next one.
3. The event text:
   - **LANDED:** "ah watcher: `<role>` "`<to_name>`" wrote its report
     for `<id>` but never sent it: `<response path>`. Read it now."
   - **CHECK-IN:** "ah watcher: `<role>` "`<to_name>`", request `<id>`,
     `<age>` old (eta `<eta>`), no report. Call ListAgents, then
     SendMessage it once, with notify_when_idle:true and the message
     "Status of request `<id>`? If finished, SendMessage me
     [hierarchy-msg `<response path>`]; if not, one line on where you
     are." If it is gone, tell the user."
     - The query carries no request token, so §14.3 and the §14.5 deny
       are not triggered.
     - A status query wakes the peer, which then goes idle again with a
       new HH:MM, so the subscription is not stale.
   - **SILENT:** "ah watcher: `<role>` "`<to_name>`", request `<id>`:
     no report and no reply `<T/2>` after the check-in. Tell the user now
     (name, request, age). The watcher will not wake you for it again
     unless the peer speaks."
   - Every event ends with: "Restart the watcher if anything is still
     open: `<exact Bash call>`."

#### 14.9.4 Who starts it, and how that is enforced (like L3: the hook enforces, the text guides)

- **The exact call,** given verbatim by both prompts below: `Bash`
  with `run_in_background: true`, `description: "ah dispatch watcher"`,
  and the command `node "<absolute hooks dir>/<watcher script>" --session
  <session id> --cwd <cwd>`.
- **PostToolUse hint.** In `hooks/posttooluse-peer-resolve.mjs`, after
  it writes a path-bearing dispatch row: if there is no live watcher for
  the session, return `additionalContext` with the exact call.
- **Stop enforcement.** In `hooks/stop-orchestrator-liveness.mjs`: if
  the session has a watchable dispatch and no live watcher, block once
  per (session, latest dispatch request id) with the exact call. Record
  this as a `watcher-nudge` gate row. `stop_hook_active` allows.
- **Directive.** `agents/orchestrator.md` gains a line saying to start
  the watcher after the first dispatch and after every watcher wake that
  says to. It also replaces 0028 §5.7's `ScheduleWakeup` prose: the
  watcher is the timer in every session.
- **The in-flight tracker must ignore the watcher.** That tracker is
  `hooks/subagent-inflight.mjs`. It must not record a background Bash
  whose command runs the watcher script. Otherwise a long-lived watcher
  would make `stop-peer-nudge` defer for good (`:120`) in an Orchestrator
  that is itself someone's peer.

#### 14.9.5 How the layers interact (no duplicate wake)

| Situation | L1 | L2 (Orchestrator Stop) | L3 (idle notice) | L4 (watcher) |
|---|---|---|---|---|
| peer finishes and sends | arms, then resolves | `seen`, so silent | landed already `seen`: nothing | `seen`: nothing |
| peer finishes, never sends | blocks up to 2× | landed-unread block at the next Stop | "read it" plus `surfaced` | LANDED after `LANDED_QUIET`, unless already `surfaced` |
| peer hung or busy for ever | — | check-ins only while the Orchestrator is active | no notice | CHECK-IN at T, SILENT at T + T/2 |
| peer idle-waiting on its own background work | defers (in flight) | — | "may be waiting" line | as hung; a reply moves the base |
| peer answers a status query "still working" | — | — | — | `heard` moves the base |
| peer crashed or exited | — | check-in | unknown notice → fail-open line | CHECK-IN → ListAgents shows it gone → tell the user |

The shared rows that prevent duplicates:
- `seen` and `surfaced` (L2/L3/L4), so a landed report is surfaced once.
- `liveness-nudge` gate rows (L2/L4), so check-ins share one cadence.
- `idle-seen` (L3), so a re-fired notice is ignored.

L3 never sends a query.

#### 14.9.6 Tests (sandboxed `HOME`, `mktemp -d`, a poll override, every run bounded, `pgrep -f` the watcher script afterwards)

Time is faked by backdating request `created`, response mtimes and gate
`ts`, never by changing thresholds. Every case kills its watcher in a
`trap`.

| # | Case | Expect | Red on `e654823`? |
|---|---|---|---|
| WA1 | path-bearing dispatch; authored response, mtime −3 min; no `seen` | exits 3 within 2 polls; a `watch-event` LANDED row and a `surfaced` row; the next Orchestrator UserPromptSubmit injects the text and writes `watch-consumed` | yes |
| WA2 | as WA1, mtime −30 s | no exit within 2 polls | yes |
| WA3 | as WA1, with a `seen` row | no exit; still running after 3 polls | yes |
| WA4 | no response; request `created` −(T + 1 min) | exits 3: CHECK-IN, plus a `liveness-nudge` gate row; the Stop hook straight after does **not** block for that request | yes |
| WA5 | after WA4, that gate row moved back by T/2 | exits 3: SILENT; a third run emits nothing for that request | yes |
| WA6 | as WA5, plus a `heard` row from X after the check-in | no SILENT | yes |
| WA7 | a second start while the first is live | the second exits 0 at once, "already running" | yes |
| WA8 | the watcher's parent killed | the watcher exits within 2 polls | yes |
| WA9 | a watchable dispatch, no live watcher; Stop | one block with the exact call; the next Stop for the same latest dispatch allows; with a live watcher, no block | yes |
| WA10 | dispatch `SendMessage`, no watcher | PostToolUse `additionalContext` carries the exact call | yes |
| WA11 | a background Bash running the watcher | the in-flight tracker records nothing | yes |
| WA12 | field replay: peer never sends; Orchestrator idle; RB13 setup plus the watcher | LANDED wake carrying the response path | yes |
| WA13 | a prompt naming a forged `<output-file>` path | no file is read; only store rows are injected | guard |

#### 14.9.7 NEEDS-EVIDENCE E5 (the Orchestrator, live)

How long a `run_in_background` Bash lives, and whether it dies with the
session. See §11.


## 15. Implementor gaps 1–4 (r3 rulings)

### 15.1 Gap 1: where `msg new --to-name <member>` writes. **Keep.**

The Implementor's rule becomes spec. The request goes to:
1. `hierarchyDir(member.expected_root)` when the member row has one;
2. otherwise, the pool holding the team file that lists the member: H,
   or a legacy P;
3. otherwise, the caller's pool, unchanged.

Without `--to-name`, behaviour is unchanged.

Why: `msgs/` stays per pool (§2.4), and a recipient's own `msg list`
and index read its own pool. The cost was that a worktree Orchestrator's
liveness hook, which scans its own pool, could not see these exchanges.
§14.4's path-bearing dispatch rows remove that blind spot, and RB5 tests
it. `test-msg-worktree-team` stays the guard for the rule itself.

### 15.2 Gap 2: the first-SessionStart race. **Change: inject the root at launch.**

- The launch funnel already injects `AH_TEAM_FILE` through `--settings`
  env (`roster.mjs:2673`, launch cwd in scope as `cwd`). Inject
  `AH_EXPECTED_ROOT` = `realCwd(cwd)` in the same env object. That is
  the value the member row gets (§2.6), so the two cannot disagree.
- Resolution order for a session's **own** expected root:
  1. the member row's `expected_root`;
  2. `AH_EXPECTED_ROOT`, used only when the session's team was
     attributed through `AH_TEAM_FILE` (attribution `via: "env"`);
  3. the team's `expected_root`.

  The member row wins over the env because a relocation can later
  rewrite the row.
- Which sites use the env value:
  - It matters only in `sessionstart.mjs`, the race site.
  - The worktree gate and `checkin`, which run inside the session, may
    use the same resolution.
  - `teams` resolves *other* members' roots and must not read its own
    env.
- Why this and not "skip the check when the row is missing": skipping
  would lose detection for hand-launched sessions, and the launcher knows
  the exact answer before the session starts.
- Tests:
  - **M3.** SessionStart with `AH_TEAM_FILE` set to a worktree-created
    team, `AH_EXPECTED_ROOT` set to main, no member row yet, and cwd main:
    not misplaced. Red.
  - **M3b.** The `spawn-one` launch command's settings JSON carries
    `AH_EXPECTED_ROOT` = `realCwd(--cwd)`. Red.
  - **M2** stays the guard for the no-env fallback.

### 15.3 Gap 3: `closed` when nothing can be closed. **Keep.**

This amends §4.4 item 4. The top-level `closed` is true only when:
- every target in `close` is verified gone, **and**
- `not_closable` is empty.

Without the second condition, a team made only of terminal-transport
members would report `closed: true` over an empty set, which is the
silent success this spec removes. When both `close` and `not_closable`
are empty, the existing "no active team and no live peers" answer
applies (§4.3).

**Test V4:** a team with only `terminal` members gives `closed: false`,
lists them in `not_closable`, and raises **W8** (§4.5; r5 named the
warning, which r3 had left undefined). Add it if step 4 has
no such test. It is a guard on `e654823`.

### 15.4 Gap 4: exit status of `--close` with `closed: false`. **Keep exit 0.**

This amends §4.4 item 6. The premise of item 6 ("match the existing
failed-close status") was checked: `--close` never set a non-zero exit,
so the status is 0.
- The failure is carried by `closed: false`, `still_live`, `warnings`,
  and the agent-team skill's rule that success requires `closed: true`
  and an empty `still_live` (§4.5).
- A non-zero exit would be a CLI contract change, and this spec does not
  need one.

### 15.5 The minor items

- **W2 prefix text: no change.** W2 lists the stray names themselves,
  which carry the actual prefix.
- **S2–S5 cannot tell before from after the change: accepted.** They are
  guards against closing too much after the change, not red cases.

## 16. Changes r2 → r3

- **New §14, the headline:** report-back in three layers. It is grounded
  in a trace of the incident with no run needed: the token-grammar
  mismatch, and the liveness hook being Stop-only, silent once a
  response exists, and bound to one pool.
- **New §15:** rulings on gaps 1–4.
- **Edits elsewhere:**
  - §2.6 and §4.4 items 4 and 6 amended at the point of change.
  - §9 gains steps 9–15, and docs-writer moves to step 15.
  - §10 adds the r3 rulings.
  - §11 adds E3.
  - §12 adds two r3 risks.
- **Ultra-Advisor:** still not needed. Every r3 mechanism is additive,
  bounded (§14.6), and fails open. None of them closes, deletes or moves
  anything.

## 17. Changes r3 → r4

- **New §14.9: L4, the background dispatch watcher** (user ruling).
  - One process per session; the 0028 §5.7.2 schedule (T, then T/2,
    then stop), with `heard` resetting it.
  - Check-ins are shared with L2 through the same gate rows.
  - Events reach the Orchestrator through store rows injected by
    UserPromptSubmit, never by reading a path named in the prompt.
  - It is started on PostToolUse's hint, and enforced by one Stop block.
  - The in-flight tracker excludes it.
- **§14.5 rewritten from E3's result.**
  - Dedupe; an unknown shape fails open.
  - An idle peer with no report gets an informational line only.
  - No status query and no re-subscribe from L3, because a re-subscribe
    loops (E3).
- **§14.4 item 3:** landed means authored content plus `LANDED_QUIET`,
  not mere existence. `msg new` writes the stub early.
- **Also:** §14.2 gains L4; §14.6 bounds; §14.7 notes the lib move;
  §14.8 adds RB14–RB16; §9 adds steps 14a–14e; §11 records E3 as answered
  and adds E5; §12 adds the r4 risks.
- **Ultra-Advisor:** not needed. L4 only reads the store and wakes the
  Orchestrator. It closes, sends and deletes nothing, and every
  mechanism is bounded.

## 18. Changes r4 → r5 (rulings on the Implementor's gaps at `55af506`)

- **G1, V4's warning:** the spec is right. It is now named **W8**
  (§4.5), and the code must emit it. Every shortfall is a warning (§0),
  and the agent-team skill surfaces warnings, not `not_closable`.
- **G2, L1 role at UserPromptSubmit:** ruled with no evidence run.
  Arm (b) accepts the persisted SessionStart role, which is exact at
  UserPromptSubmit because subagents are already excluded (§14.3).
  RB1 now reproduces a UserPromptSubmit payload with no `agent_type`.
- **G3, exit versus expiry notices:** accepted as indistinguishable. One
  fail-open line serves both (§14.5 step 2).

## 19. Changes r5 → r6 (W8 on `dismiss`; the Implementor stopped at r5)

r5 said "W8 on disband and dismiss plan and close", but `dismiss` has no
`not_closable` key, and a no-pane target `fail()`s on `--close`. The
options were: (a) keep the `fail()` and make W8 disband-only; (b) turn
the no-pane close into `closed: false` JSON with exit 0; (c) W8 on the
plan only.

- **Ruling: (c), which is (a) for `--close` plus W8 on the plan.**
  - **`--close` keeps `fail()`, so (b) is rejected.** Exit 2 cannot be
    mistaken for success, and (b) would change the CLI contract and T9b
    for no gain.
  - **The plan gets W8, so (a) alone is rejected.** The plan is the one
    dismiss output that is exit 0 and silent about a no-pane target. The
    skill reads `expected: 0` with no `next` and has no warning to show,
    so the user never learns that the session needs closing by hand. That
    is the shortfall W8 exists for.
- **Edits:** §4.5 W8 text, §4.7 mechanics, tests D2 and D3 in the test
  table after D1 (with T9b pinned as a guard), and the §9 r5-deltas list. The Status line now
  reads r6.
- **Docs:** describing W8 as disband-only is wrong after r6. Step 15's
  docs-writer must cover the dismiss plan.
