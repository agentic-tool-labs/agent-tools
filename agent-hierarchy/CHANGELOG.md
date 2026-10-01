# Changelog

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions are the plugin's `version` in `.claude-plugin/plugin.json`. Feature
detail lives in the README and in [docs/](./docs/); design reasoning in
[docs/specs/](./docs/specs/).

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
