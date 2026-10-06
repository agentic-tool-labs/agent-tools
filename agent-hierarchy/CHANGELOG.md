# Changelog

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions are the plugin's `version` in `.claude-plugin/plugin.json`. Feature
detail lives in the README and in [docs/](./docs/); design reasoning in
[docs/specs/](./docs/specs/).

## [0.119.0]

### Added
- A role with a shell only for self-care. The Architect (and any custom role whose registry row sets
  `shell: "self-care"`, via `role set --shell self-care`) can run its own `roster.mjs checkin`,
  `whoami` and `status`, and `msg.mjs new --type response` for its own brief, plus the read-only
  `msg.mjs` listings. A hook that runs first on every Bash call refuses everything else and never
  approves a command on its own.

## [0.118.0]

### Added
- Toasts last 10 s by default, configurable with `toast_seconds` (2-60); 0 turns the hierarchy notices off. Click a
  notice to dismiss it, hover to keep it. Click feedback for a member focus is not affected.

## [0.117.1]

### Fixed
- A member session stays excluded from the orchestrator view while it is marked gone: the status file's member
  sessions now list each member's latest registered session whether or not it is live.
- A running member whose roster row was wrongly marked down re-registers itself at its next prompt or stop, but only
  from the process that registered it, so a relaunched copy of a session cannot.

## [0.117.0]

### Added
- Pane: colored section boxes, colored activity icons, grouped by stream. Each section (hierarchy, team, one per
  stream, dispatches) is a bordered box with its own color; each member and dispatch row starts with an icon whose
  shape tells the state and whose color tells the tone. Members and the dispatches sent to them group under their
  stream. Below 40 columns the borders go and the titles stay. The status file gains a member's `stream`.
- Pane: click a team member's name to focus its terminal pane. It works for members that run as herdr agents, runs
  `herdr agent focus <name>` and nothing else, and shows a message only when it fails. The status file gains a
  member's `focusable`. The read-only guard now pins that one helper, whole, and bans `process` everywhere else.

## [0.116.0]

### Added
- Per-peer progress in the status file and the Pane: the last finished tool and its age, refreshed at most every
  15 s (tool name only, never arguments). A working peer reads `working 6m · last Edit 12s`.
- Peers send one-line notes only for news that needs no answer (a surprise that changes the plan, or once at the
  midpoint of a large brief); blocked or decision news goes out as a report. The Orchestrator treats a note as news
  and answers a BLOCKED or NEEDS-DECISION report with a new request.

## [0.115.1]

### Fixed
- The hierarchy Pane is never blank. A visible status document that lists no team now draws one line saying so,
  and a value in the Pane's state that is not a view draws the "nothing here" line instead of nothing.
- That line now names its cause: no file, unreadable, expired, the hierarchy off, not visible, or a member session.
- A session whose own config is disabled no longer hides a live team's view. Its event writes of the status file
  keep the `enabled` already published, and still publish every change at once; `roster.mjs status` and
  `/hierarchy off` still hide the view. Limits are in `docs/status-file.md`.

## [0.115.0]

Reviews that know what a change is meant to deliver, and fixes that do not reach a push unreviewed.

### Added
- A review intent gate. A request to a review-class role (the Reviewer, or any custom role of the review class)
  must state its goal and acceptance. The dispatch hook holds one that does not, on every route that names a
  request file, including a peer brief sent without the sentinel. `roster.mjs deliver` refuses it too.
- The Reviewer audits claims (`verified | unverified | contradicted`), traces every newly emitted or persisted
  value on every caller path, probes each added or changed condition, and treats earlier "resolved" threads as claims.
- `NEEDS-INTENT`: a Reviewer with no spec and no stated intent says so instead of reviewing.
- The Reviewer's report names the range it reviewed.
- A spec section, "Invariants and negative cases", and an Implementor rule: a negative test for every condition
  added or widened, and no unsourced external claims in comments.
- A generic review scenario under `tests/fixtures/review-scenario/`, with a self-check that its defects are real.

### Changed
- A verdict covers only the range it names; a behaviour-changing commit after it is re-reviewed before push.
- A change to a decision rule is never "Determined": it takes the design step.

## [0.114.0]

The band gets a button that opens the Pane, and the status entry becomes opt-in.

### Added
- The band's `[ Pane ]` button. It does what `/hierarchy-pane` does, and is drawn
  only while the band is (never in a member session, during a survey, or below 40
  columns). Click it, or ctrl+x tab then Enter.

### Changed
- The `⚠ ah:` status entry is now opt-in: `status_entry` defaults to `false`.
  **Upgrade note:** if you relied on the `⚠ ah:` line and never set
  `status_entry`, it disappears; set it to true to keep it. A value you stored
  is kept.
- The mod guard now lets the band hook draw a Button with an inline `onPress`, and
  lets `$` be passed to one kind of callee, a once-declared `$`-first helper in
  `register.tsx` (spec 0073 §3).

## [0.113.0]

One team file per repo, teardown that verifies, and finished peer work that is
never left unseen.

### Changed

- **Team home.** A team file now lives in the main checkout's hierarchy dir
  whatever `--cwd` a spawn or `create` is given, so a team with members in a
  worktree and in the main checkout is one file, not two. A team recorded in a
  worktree's own dir by an older release is read and updated there, in place;
  nothing is migrated. Worktrees of one repo share team names, the default
  `team.json` included: a name already live in a sibling worktree now meets the
  usual second-team and ownership refusals instead of silently giving a private
  team. [docs/team-file.md](./docs/team-file.md).
- **Members record their own root.** Each member row carries `expected_root`,
  and the launcher sets `AH_EXPECTED_ROOT`, so a main-checkout member of a
  worktree-created team is no longer flagged misplaced, including at its first
  `SessionStart`.
- **Verified close.** `disband`/`dismiss --close` re-query after closing;
  `closed: true` now means every target is gone and nothing was un-closable.
  Added keys: `expected`, `closed_count`, `still_live`, `strays`,
  `not_closable`, `team_files`, `warnings`. `--close` with `closed: false` still
  exits 0. `teams` rows read from a legacy worktree copy carry `legacy_dir`.
- **`disband` reads the whole team.** The team file from its home (and a legacy
  copy), `peers.jsonl` from every pool the team touches, and herdr panes in any
  worktree of the repo. A herdr pane that carries the team's name but is not in
  the record is closed as a **stray**, in the plan you confirm, with a named
  residual risk: matching is by name and checkout only, so another
  orchestrator's agent in the same repo with the same prefix would be closed too
  (warning W2). Orchestrator-role panes and members of other teams are never
  strays. [Team home and teardown](./docs/cli-tools.md#team-home-and-teardown).
- **Loud warnings W1–W8** on plans and closes: no team record found (W1),
  strays (W2), a team split across home and worktree (W3), a team owned by
  another live orchestrator (W4), a pane that changed name before the close
  (W5), a transport that could not be queried (W6), targets still live after
  the close (W7), members with no pane to close (W8: `disband` plans and closes,
  and the `dismiss` plan, which also lists them in `not_closable`;
  `dismiss --close` still exits 2 for such a member). Spawns
  warn, never block, on a split team or a `--cwd` in another checkout than the
  calling shell's.
- **`ScheduleWakeup` prose removed** from the Orchestrator directive; the
  dispatch watcher is the timer in every session.

### Added

- **Report-back, four layers.** (L1) a peer arms its owed reply when the
  `[hierarchy-msg]` token appears anywhere in the wrapped brief and the request
  is addressed to its own role, not only at the start of the first line; (L2)
  the Orchestrator's Stop sees every dispatch in the pool the request lives in,
  and blocks once on a response that landed but was never sent; (L3)
  Orchestrator `SendMessage` dispatches must carry `notify_when_idle: true`
  (denied once, with the fix), and the idle notice is handled by injection,
  never by a status query; (L4) a background dispatch watcher, started by the
  Orchestrator, wakes an idle session with LANDED, CHECK-IN or SILENT events
  when a peer is hung or silent. Fixes the case where two Implementors wrote
  responses, never sent them, and sat idle for hours.
  [Finished work is never left unseen](./README.md#finished-work-is-never-left-unseen).

### Fixed

- **A worktree Orchestrator's `disband`** finds the team, its main-checkout
  members and the panes they sit in, instead of `team: null` and
  `closed: true` over live sessions.

Known limit: run from the main checkout, a legacy team recorded only in a
worktree's own dir is not seen; run `disband` from that worktree.

## [0.112.1]

The status file's readers no longer open anything but a non-empty regular
file. A symbolic link, FIFO, directory or device at `status.json` or
`activity/<x>.json` counts as absent, a linked `activity/` directory is
never swept, and the temp files `ah` writes are created exclusively so a
committed link at a temp name can no longer redirect a write.
`clearActivity` no longer follows a linked `activity` dir. See
[Reading it](./docs/status-file.md#reading-it).

## [0.112.0]

The `ah` mod now shows the hierarchy's status as a band above the prompt, a
Pane, and toasts. See
[The band, the Pane and toasts](./README.md#the-band-the-pane-and-toasts).

### Added

- **The band.** One line above the prompt while dispatches are out or a member
  is blocked. It names the most severe item: a stalled dispatch, then an
  overdue one, then a blocked member. With none of those, it lists the working
  dispatches and their elapsed time. It is drawn above whatever else shows
  there, never in its place, and it steps aside while a survey is up. It
  appears on the terminal and desktop only.
- **The Pane and `/hierarchy-pane`.** The Pane lists the pipeline, the team's
  members and the outstanding dispatches. It opens on its own once per
  session, the first time there is status to show. The engine places an
  unasked Pane from 144 columns, or from 110 once you have opened it yourself;
  below that it waits until the terminal is wide enough. `/hierarchy-pane`
  opens it at any width. Closing the Pane by hand keeps it closed for the
  session, until `/hierarchy-pane`.
- **Toasts.** One toast when a dispatch reports, when a member is blocked, and
  when a dispatch stalls. Each shows at most once per session, also across a
  reload. The first status a session sees toasts nothing, so old events are
  not replayed.
- Team members' own sessions see none of this. `/hierarchy-pane` there opens
  nothing and says the view is hidden in member sessions.

### Changed

- **The mod's read-only guard** allows the `ui.close` hook only with the exact
  matcher `{ id: 'ah-status' }`.

### Known risks

- **A close by hand is checked only by hand.** The plugin test kit cannot
  raise a close by a person, so no automated test shows that closing the Pane
  by hand keeps it closed. The manual check in the spec (P3 AC 4) covers it.
- **Drawing is not tested.** The tests check the trees the mod returns, not
  how a surface paints or places them, so the width floors and placement are
  also covered only by that manual check.
- **The same client risk as 0.111.0.** The mod needs Claude Code 2.1.289 or
  later. An older client may reject the mod file outright, and whether the
  command hooks still load then is untested. The mod has been tested only with
  `--plugin-dir`, not yet as an installed marketplace copy.

## [0.111.0]

`ah` now carries a small read-only mod that shows the hierarchy's status in
the session. See
[The status entry: the team at a glance](./README.md#the-status-entry-the-team-at-a-glance).

### Added

- **The status entry.** The engine shows a `⚠ ah: …` line, such as
  `2 live · 1 out · 1 blocked`, read from `<hier>/status.json` every two seconds.
  It shows in the Orchestrator's and other non-member sessions, and is hidden in
  team members' own sessions. Nothing shows when there is no status file or it
  has expired.
- **The `status_entry` option.** It is on by default. Turn it off with `/config`
  or `claude plugin configure` (user scope only) to hide the line, for example
  when claude-tui-line's `ah` item already shows the counts.
- **Minimum client version.** The mod half of `ah` needs Claude Code 2.1.289 or
  later. An older client may reject the mod file outright. Whether the command
  hooks still load then is untested; this is an accepted risk. The bundled mod
  has been tested only with `--plugin-dir`, not yet as an installed marketplace
  copy.

### Fixed

- **A Claude member with `route: pane` is treated as a Claude session.** In the
  status file it is attributed by its session and hidden like any member
  session, and it gets the Claude check-in wording. Spawning it no longer
  records pane activity for it.

## [0.110.0]

`ah` keeps one status file describing the live hierarchy, for status lines and
the coming `ah` mod to show.

### Added

- **The hierarchy status file.** `<hier>/status.json` describes the live teams,
  their members (live or gone, working, idle or blocked), the work dispatched to
  them (working, overdue, stalled or reported) and any `/pipeline` run. Changes
  that only depend on time are scheduled inside the document, so a reader picks
  the entry current at its own clock and works nothing out. `ah` rewrites it
  whenever hierarchy state changes: peers rows, message files, team files,
  decision rows, check-ins, activity records, every session start, and
  `/hierarchy` config changes. A failed write never affects what triggered it.
  Schema, rules and the shared test fixtures:
  [docs/status-file.md](./docs/status-file.md).
- **`roster.mjs status [--plain] [--now <ISO>]`.** Computes the document, writes
  it and prints it. `--plain` prints the one-line `ah · …` text.
- **Activity records.** A Claude role session records its own activity in
  `<hier>/activity/` from its UserPromptSubmit, Stop and permission-prompt
  events. A new PostToolUse hook on every tool call, registered async, marks it
  working again after a permission prompt. Each run of that hook loads `ah`'s
  libraries (tens of milliseconds) but doesn't delay the next tool. The
  UserPromptSubmit, Stop and permission-prompt hooks run in line. In any session
  of a repo that has a hierarchy directory, role or not, UserPromptSubmit and
  Stop also rewrite status.json: about 6 ms warm and 13 ms cold at p95, measured
  on a live pool. Every `ah` hook now loads the full library set, which adds up
  to about 3 ms per hook process at p95. Pane members are recorded by `deliver`,
  `answer`, spawn, `dismiss` and `disband`.

### Changed

- **A member's exchange stays open until its response holds a report.** A
  skeleton response stub addressed to a member no longer closes the exchange,
  and `msg.mjs sweep` no longer archives such a pair. A response over 4 KB
  counts as a report without being read. Exchanges addressed to the
  Orchestrator, which includes every `/pipeline` run record, still close on any
  response.

  After upgrading, older unfilled stubs of member exchanges show as open again in
  `msg.mjs list`, and their roles count as busy. To clear one that was
  abandoned, write a line of content into its response file. There is no
  automatic migration.
- **Stop-hook check-ins.**
  - The clock starts at the first dispatch, not when the request file was
    written.
  - The second check-in comes half an eta interval after the first.
  - Work sent to a pane member with `roster.mjs deliver` is now checked in on
    too, with the `deliver … --wait-only` command to run instead of
    ListAgents/SendMessage.
- **`merge-check` sign-off.** Only a closed `-ok` addressed to a member, with a
  report in its response, counts as the Architect's sign-off.

## [0.109.0]

`/pipeline` decides safe questions for you instead of waiting.

### Added

- **Decisions on your behalf.** Once a `/pipeline` run has started, a question
  the plan doesn't answer is classified. A **safe** one (it stays on the run's
  branch, is reversible there, stays in the plan's scope and touches nothing
  reserved) goes to the Ultra-Advisor if you allowed it at the start of the
  run, else to the highest-tier member of the team, else to a fresh subagent
  on the Orchestrator's model; never a model below the Orchestrator's tier,
  never the Orchestrator's own context, and if none can take it the question
  waits for you. A **dangerous** one (destructive,
  remote or merge, security and trust including role packs, cost, scope, or
  the run's own rules; anything unclear counts) is parked for you, and
  stops only its own item. At most 4 decisions per item and 20 per run.
  Every decision goes in a per-run log with its reason and how to undo it. The
  final report lists "Decisions made on your behalf" and "Waiting for you";
  issue runs put each item's decisions in its PR body too. See the README's
  [Decisions made for you](./README.md#decisions-made-for-you).
- **`msg.mjs decision add|list`.** Writes and reads the run's decision log
  (`.claude/hierarchy/pipeline/<run id>/decisions.jsonl`). Verbs and refusals:
  [cli-tools](./docs/cli-tools.md).
- **Auto-merge, only if you opt in.** An issue run can merge its PRs at the end
  of the run. Opt in per run with `--auto-merge` or in plain words, or answer
  the start question (default No); plan runs refuse it. Every merge needs your
  click on a permission prompt, pinned to the PR's head commit, and only in
  permission mode `default`, `auto` or `acceptEdits`. Merging is never counted
  as a decision made for you. The final report adds "Merges performed under
  your authorisation" and "Not merged". See the README's
  [Merging](./README.md#merging-only-if-you-opt-in).
- **Merge guard.** While a run is open, a hook refuses `gh pr merge`
  (any unpinned form, `--auto`, `--admin`), `gh pr review --approve`, `gh pr
  ready` outside the pinned form, `gh api` merge, approve and ref-write calls,
  and the GitHub tools that merge or approve. It never blocks `git` commands.
  A speed bump, not a sandbox: GitHub branch protection is what stops pushes,
  and a merge is a hard wall only with a separate bot or App identity.
- **Branch-protection check.** Every run-start notice says whether `main` is
  protected ("on", "on, but …", "OFF" or "unknown"). Read-only; it never
  blocks the run.
- **Run-start notice** now also says who decides for you and where the log is,
  and "guards: prose only (no conventions baseline)" when the repo has no
  committed `.claude/ah-conventions.json`.

### Changed

- **A plan run with no `--branch` has a default branch**,
  `ah/pipeline-<plan-stem>`, created from where you are. If it already exists,
  locally or on `origin`, the run halts before any work and says to pass
  `--branch` or delete it. Before this, no default was defined.
- **Acceptance criteria** can be passed as a file path or typed into the
  request; typed ones are saved to a gitignored scratch file under
  `.claude/hierarchy/specs/` and the run goes ahead on it.
- A question parked for you is now one of the things that notifies you
  mid-run.

### Upgrade notes

- The run asks one extra question at the start (Ultra-Advisor decides, or not)
  unless the session's Ultra-Advisor setting is already `session` or `off`.
- Decisions made for you are real: read the final report, and the PR bodies of
  issue runs, before merging.
- `/pipeline` still never merges unless you opt in. The merge guard is new
  and blocks `gh` merge forms during a run; if a run halts on an
  `ah-push-guard` message, that is the guard.
- Turn on branch protection that requires a PR, with no bypass for your token,
  if you want pushes to `main` stopped by GitHub rather than by the run's rules.

### Not in this release

Sub-orchestrators (spec 0067) are not built.

## [0.108.5]

Everything since 0.105.0: named rosters, role packs, several owned teams, a
message-pointer fix and safer config writes.

### Added

- **Named rosters (0.106.0).** A config level can hold several rosters as
  `rosters.<name>` blocks beside the default `roster` block.
  `roster list`, `copy`, `delete` and `use` manage them. Commands that read
  or edit a roster use the first of `--roster <name>`, `AH_ROSTER`, the most
  specific `activeRoster` (repo-user, then repo, then global), then the default
  block; `default` names the default block everywhere. A running team keeps
  the roster it was built from. See
  [getting-started](./docs/getting-started.md#named-rosters).
- **Role packs (0.107.0).** A role pack is a Claude Code plugin that also
  carries `ah-roles.json`. Its roles reach nothing until you adopt one with
  `role set <name> --from <plugin>@<marketplace>:<role>`: the dry run shows
  the fields, tools and what else the plugin carries, and the commit needs the
  pin it prints. The pin covers the whole plugin tree, so any change makes the
  role unavailable until `role trust` reviews it. `pack list` and `pack show`
  inspect packs. Pack agents get a strict frontmatter allowlist; trust commits
  are asked of you in your own session; pack roles never run with permission
  checks off and never fill a `/pipeline` run's reviewer or designer slot. See
  [custom-roles](./docs/custom-roles.md#6-role-packs).
- **Several owned teams (0.108.0).** One session can own more than one live
  team, and one request can create them ("create team foo from roster x and
  team bar from roster y"). A command that names a member finds its team; a
  whole-team command (`disband`, `untrack --all`, stream commands) needs
  `--team <name>`. `--team @default` names the legacy `team.json` team. Spawn
  text, `msg.mjs list` and the session start-up note cover every owned team.
  A resumed session re-claims a team with `roster.mjs adopt --orchestrator-pid
  <pid> --team <name>`. See
  [getting-started](./docs/getting-started.md#5-spawning-a-team) and
  [troubleshooting](./docs/troubleshooting.md#several-owned-teams).
- **README `/pipeline` section.** How to invoke it, how rosters and pack roles
  pick the team, prerequisites, and which rules are hook-enforced.

### Changed

- With one owned team, hook and command output is unchanged from before.
- `disband`'s close gate reads `team.json` for `--team @default` (its
  confirmation named no members before), and team listing skips files in
  `teams/` that no `--team` could name (0.108.0).
- Pack agent files are checked more strictly (0.107.0): printable ASCII
  outside the description, no YAML null or boolean words (`tools: null` would
  mean every tool), no other agent file claiming the role's name, and hidden
  or lookalike Unicode characters refused with the character, line and column.

### Fixed

- **Response pointers beside their request (0.105.1).** A peer that answered a
  request filed in another worktree's message pool had its response pointer
  rejected, because the placement rule and the validation rule disagreed. A
  response pointer beside its request is now accepted. Spec 0065.
- **Config safety (0.108.3 to 0.108.5).** A config file that exists but is not
  a JSON object (invalid JSON, empty, an array) used to read as a missing file,
  so the next write replaced it. `roster.mjs` writers now exit 2 naming the
  path and parse error and write nothing: `init`, `add`, `edit`, `remove`,
  `tier set/remove`, `role set` (and `--from`), `role trust`, `role remove`,
  `roster copy`, `delete` and `use`. `untrack` and `dismiss --also-config`
  finish their main work, warn, leave the file and report `config.removed:
  false` with the reason, naming the file. Spec 0069.
- **`roster use` and "configured" (0.108.2).** A repo or repo-user file counts
  as configuring nothing only when `activeRoster` is its sole key, so
  `use`, `use --clear` and a `use`-created file no longer change whether a repo
  counts as configured.

### Upgrade notes

Behaviour you might notice. None needs action unless you hit one.

- **A selection naming a missing roster now refuses.** If `--roster`,
  `AH_ROSTER` or `activeRoster` names a roster no level defines, roster verbs
  exit 2 with the source of the name and the fixes. Hooks fall back to the
  default block and warn; `doctor` shows a red `roster-selection` row. See
  [troubleshooting](./docs/troubleshooting.md#named-rosters).
- **`show --roster <missing>` no longer falls back silently.** It used to show
  the default block; it now refuses as above.
- **An unparsable config file is refused, not replaced.** If a write verb now
  exits 2 naming a config file, fix or delete that file; the old behaviour
  overwrote it.
- **Files written by pre-release `roster use` read as configured.** A file
  holding `{version, activeRoster}` now counts as configured, as `{version}`
  does; only a file whose sole key is `activeRoster` counts as preference-only.
- **Teams belong to a session.** With several owned teams, a whole-team command
  without `--team` refuses and lists your teams. A resumed session owns none
  until it re-claims each with `adopt`.
- **Plugin updates can disable adopted pack roles.** The pin covers the whole
  plugin, so a `claude plugin update` makes its roles unavailable until
  `role trust`.

### Not in this release

Specs only, nothing implemented: 0067 (sub-orchestrators, backlog), 0068
(`/pipeline` decides non-dangerous calls itself) and 0070 (`/pipeline` merge
guard and per-run auto-merge). `/pipeline` still never merges.

## Earlier

0.105.0 and before: the initial release and its fixes are in `git log`.
