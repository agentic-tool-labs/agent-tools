# Changelog

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions are the plugin's `version` in `.claude-plugin/plugin.json`. Feature
detail lives in the README and in [docs/](./docs/); design reasoning in
[docs/specs/](./docs/specs/).

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
