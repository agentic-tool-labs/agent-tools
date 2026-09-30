# 0064 — Named rosters you can select, and role packs from outside the plugin

Implementer: implementor
Reviewer: reviewer

Status: designed, and ready to build in two phases. Each open question in §10
has a recommended default, and this spec is written on those defaults. Base:
`main`. Each phase ships as its own minor bump of ah.

## 0. Summary

**A. Named rosters.** The data already exists: a `rosters.<name>` block at any
`agent-hierarchy.json` level, picked with `--roster <name>` (specs 0032 and
0057). What's missing is everything around it:
- seeing the named rosters;
- copying and deleting them;
- picking one as the standing default for a repo, a machine or a session.

This spec adds one selection rule with one implementation, a config key
`activeRoster`, an environment variable `AH_ROSTER`, and four verbs:
`roster list`, `roster copy`, `roster delete` and `roster use`. With nothing
selected, every command behaves exactly as it does today.

**B. Role packs.** A custom role is a `roles.<name>` row plus an agent file.
The agent file can already live outside this plugin, through a bare name in
`.claude/agents/` or `~/.claude/agents/`, or a `plugin:agent` ref (spec
0056). What's missing is a way to ship roles to someone else.

A role pack is a Claude Code plugin that also carries an `ah-roles.json`
manifest:
- Claude Code installs, updates and removes it;
- ah finds it and lets the user adopt its roles one at a time;
- ah pins each adopted role to the exact content of its whole plugin, as the
  user reviewed it;
- if anything in that plugin changes, ah makes the role unavailable until
  the user trusts it again, through a commit a model can't make alone;
- in `/ah:pipeline`, a pack role never fills a gate slot (Reviewer,
  Architect sign-off, secret scan).

## 1. What exists today

Facts, with file:line on `main`. Paths are under `agent-hierarchy/`.

**Config levels and resolution**
- **Levels.** `ROSTER_LEVELS = ["repo-user", "repo", "global"]`
  (hooks/lib-config.mjs:276), most specific first.
- **Paths** (lib-config.mjs:727-735):
  - global: `~/.claude/agent-hierarchy.json`;
  - repo: `<git root>/.claude/agent-hierarchy.json`;
  - repo-user:
    `~/.claude/agent-hierarchy/projects/<pathSlug(repo root)>/agent-hierarchy.json`.
- **Worktrees.** From a linked worktree, each repo level also tries the main
  checkout (`rosterLevelCandidates`, :772-783).
- **Two resolvers.** Both are in lib-config.mjs and every hook goes through
  them. Only lib-config.mjs and roster.mjs read the file itself.
  - `resolveConfig` (:1275-1491). Top-level scalars (`enabled`, `handoffs`,
    `msgs`, `route`) merge per key, and the most specific level wins
    (:1333-1379). A `roles.<name>` row wins whole, most specific first
    (:1384-1400).
  - `resolveRoster(cwd, rosterKey, …)` (:964-988). A roster block wins whole.
    - With a key, pass 1 looks for `rosters[key]` at every level. Pass 2
      always falls back to the default `roster` block.
    - Blocks with no members are skipped.
    - The result's `teamKey` says which pass matched.
- **Picking the key.** `resolveConfig` picks it at :1469:
  - `opts.roster` if given;
  - else the key the session's team file records (`teamRosterKey`,
    hooks/lib-roster.mjs:893-898);
  - with no team file, null;
  - with a legacy file that has no `roster` property, the team's own name.
- **Preference-only keys.** `teamLayout` and `modelTiers` (:665): a global
  file holding only these counts as unconfigured.

**Named roster blocks**
- **Shape and names.** A `rosters.<name>` block has the same shape as
  `roster`: `{route, members: […]}`. Names are checked by `validateTeamAlias`
  (lib-config.mjs:818-834): `^[A-Za-z0-9][A-Za-z0-9-]{0,31}$`, plus a
  peer-name round-trip check. `default` is a valid name today.
- **`--roster <r>`** (roster.mjs:733-740) is read by `create` and by the
  template verbs `init`, `add`, `edit`, `remove` and `show` (:729).
- **`init --roster r`** creates the block, or replaces it wholesale
  (:4419-4437).
- **`remove`** of the last member leaves `members: []` (:1606-1612).
- **`create --roster r`:**
  - refuses a block that has no members at any level (:4717-4720);
  - records the key in the team file's `roster` field (:4851).
  - docs/team-file.md documents `roster` and `roster_level`.
- **`show --roster r`** silently shows the default block when `r` is missing,
  because it calls `resolveRoster` (:4395).
- **Nothing** lists the named blocks, copies one, deletes one outright, or
  selects one except per command.

**Roles and agent files**
- **One registry:** `CLASSES` (lib-config.mjs:169-195), `BUILTIN_ROWS`
  (:199-205), `registryRoles` (:385-387).
- **Custom rows** are checked by `checkCustomRow` (:1132-1170):
  - `class` is required;
  - `agent` defaults to the name and must not start with `ah:`;
  - `description` and `routes` are one line, at most 160 characters, with no
    backticks (:1109-1114);
  - `model` must be allowed for the class;
  - names are checked by `roleNameError` (:1097-1102).
- **`locateAgentFile`** (:1547-1573):
  - A bare name resolves to `<repo>/.claude/agents/<n>.md`, then
    `~/.claude/agents/<n>.md`.
  - `plugin:agent` resolves to the first install record in
    `~/.claude/plugins/installed_plugins.json` whose `agents/<agent>.md`
    exists.
  - roster.mjs:241 reads installed_plugins.json a second time, for its own
    purpose.
- **`validateAgentContract`** (lib-config.mjs:1721) reads only `name`,
  `description`, `model`, `tools` and `disallowedTools` from the frontmatter
  (:1618).
- **Launching.** A peer launches as `claude --agent <ref> …`
  (roster.mjs:1868-1892). A legwork subagent is dispatched with
  `subagent_type` (`subagentType`, lib-config.mjs:1857-1862). Either way,
  Claude Code itself must have loaded the agent, from `.claude/agents/`,
  `~/.claude/agents/`, or an installed plugin.
- **Enablement.** Whether a plugin is enabled can't be read from files
  (roster.mjs:1040-1041).

**Gates and guards**
- `hooks/pretooluse-roster-skill-gate.mjs:38` gates only the team verbs
  `create`, `adopt`, `move`, `dismiss`, `disband` and `untrack`, which must go
  through the `ah:agent-team` skill first (specs 0042 and 0048). The template
  verbs `init`, `add`, `edit` and `remove` are deliberately ungated
  (:10-17), and so is `role`. The gate matches a single verb word (:80).
- `hooks/pretooluse-ah-cli.mjs` has no verb list. It allows every parsed verb
  except a close command.
- `ROSTER_MUTATING_CMDS` (roster.mjs:168) refuses `init`, `add`, `edit` and
  `remove` while the session owns a live team.

## 2. Goals, non-goals, migration

**Goals**
- **A:**
  - create, list, show, select, delete and copy named rosters;
  - how a session, a repo or a machine picks one;
  - the precedence rules;
  - a per-command override (flag) and a per-session one (environment);
  - the default when none is named.
- **B:**
  - a defined, separate place for role definitions outside this plugin;
  - install from a git URL, a GitHub repo or a directory;
  - discovery that any plugin can join;
  - collision rules against built-in and custom roles;
  - install, update and remove;
  - validation;
  - trust for third-party prompts and tool grants.
  - It builds on 0056's custom roles rather than beside them.

**Non-goals**
- No change to built-in roles, class contracts, the tier rule, the route or
  Ultra-Advisor gates, the team-file schema, or `create --from` history.
- ah does not reimplement plugin installation.
- Rosters shipped inside packs, and a pack scaffold, are follow-ups (§11).

**Migration: none.**
- An existing config means exactly what it means today.
- A missing `activeRoster` means nothing is selected.
- A role row without `from` is resolved as it is today.

## 3. Part A: named rosters

### 3.1 Data

A named roster stays a `rosters.<name>` block. There is one new top-level key.

**`activeRoster`** is a roster name, or `default` (§3.3).
- **Merging.** It is a top-level scalar, so it merges per key the way `route`
  does: the most specific level wins.
- **Where it is read.** From the same candidate paths `resolveRoster` uses
  (`rosterLevelCandidates`). So a repo-level value in the main checkout also
  applies in that checkout's linked worktrees. If `resolveConfig`'s layer
  merge doesn't read main-checkout candidates today, the selection must read
  them anyway.
- **Preference-only, at every level.** Choosing a roster must never make an
  unconfigured setup look configured, or injection would change when nothing
  is really selected.
  - A global file holding only `activeRoster` (with or without the other
    preference-only keys) still counts as unconfigured.
  - A repo or repo-user file whose only keys are `version` and `activeRoster`
    also counts as unconfigured.
  - The `activeRoster` in such a file still applies to the selection (§3.2).
  - Nothing else changes about what counts as configured. A repo-level file
    holding only `version` counts exactly as it does today.
  - `activeRoster` is a new key, so no existing file changes meaning.
- **Writes.** `writeLevelFile` and `migrateStaleKeys` (roster.mjs:1310-1384)
  keep the key.

### 3.2 Which roster a command uses

One implementation in lib-config.mjs answers which roster block to use, and
why. Its answer is a key (a name, or none for the default block) plus a
source, and a level and path when the source is `activeRoster`. Two callers
use it:
- roster.mjs, for the template verbs and `create`, in place of the plain flag
  read at roster.mjs:733-740;
- `resolveConfig`, in place of the key choice at lib-config.mjs:1469.

**For the template verbs and `create`,** the first match wins:
1. `--roster <name>`. Source `flag`.
2. `AH_ROSTER`, when it is set and not empty. Source `env`.
3. `activeRoster`. Source `activeRoster`, with its level and path.
4. Nothing: the default `roster` block. Source `default`.

**For `resolveConfig`,** which every hook uses:
- `opts.roster`, if given. Source `flag`.
- Else, when the session's team scope has a team file, the key that file
  records. This is today's `teamRosterKey` rule, unchanged, including the
  legacy rule that keys by team name. Source `team`.
- Else rules 2–4.

"There is a team file" must be told apart from "the team file records the
default block". `teamRosterKey` returns null for both today. Only "no team
file" falls through to rules 2–4.

**Other verbs keep today's behavior.** `spawn-one`, `spawn-ad-hoc`,
`disband`, `dismiss`, `resync` and the rest act on a live team and its
recorded roster. The Implementor audits every reader of `rosterArg` and
`opts.roster` in roster.mjs, and says in the PR which ones take the
selection. Only the template verbs and `create` do.

**`create --from <history>`** already takes no `--roster` (:4714). It
ignores the selection.

**`init`** creates or replaces the selected block, so the missing-roster
check in §3.4 doesn't apply to it. `init` is how a missing roster gets made.

### 3.3 The name `default`

In `--roster`, `AH_ROSTER`, `activeRoster` and `roster use`, `default`
means the unnamed `roster` block. That lets a narrower level or a single
session undo a wider selection. For example, a repo sets
`activeRoster: game-dev`, and `AH_ROSTER=default` uses the plain roster for
one session.

`default` can no longer be created as a block name: `init --roster default`
and `roster copy <src> default` are refused. A `rosters.default` block that
already exists keeps working for a team whose file records it, because a
team's key is never read as the token. It can't be selected or copied, and
`roster list` shows it with a note saying so. This is a deliberate known
limit (§10 Q3).

### 3.4 A selected roster that doesn't exist

A roster is "defined" when some visible level holds a `rosters.<name>` key,
even one with no members.

- **Verbs** (all but `init`). A selection from rules 1–3 that names an
  undefined roster is refused. The message names:
  - the source: `--roster`, `AH_ROSTER`, or `activeRoster` at `<level>` in
    `<path>`;
  - the rosters that are defined;
  - the fixes: `roster use default`, `roster use <other>`, or
    `init --roster <name>`.

  This makes `show --roster <missing>` refuse where today it quietly shows the
  default block. `create` keeps its existing refusal of a roster that has no
  members (:4717-4720).
- **Hooks.** `resolveConfig` never throws on this. It resolves the default
  block and adds a warning with the same facts to its `warnings`, so
  SessionStart shows it.
- **`doctor`** reports it as a red finding, so `doctor --check` exits 1.

All three use the one check.

Two details the existing suite fixes:
- **Wording.** The refusal keeps the phrase `no rosters.<name> block`, which
  existing tests and scripts search for. It reads `<source> selects roster
  "<name>", but there is no rosters.<name> block at any level (defined: …).
  Fix with …`.
- **Order.** It runs after the refusal to edit the roster while the session
  owns a live team. When both apply, the ownership message comes first; the
  set of commands refused is the same.

### 3.5 Teams

- **`create`** records the selected key in the team file's `roster` field
  (null for `default`), through the existing write at roster.mjs:4851.
  `roster_level` is written as it is today. There are no new team-file
  fields.
- **Team members** resolve their roster through their team file
  (`AH_TEAM_FILE`). They need no `AH_ROSTER`, and one in their environment is
  ignored while their team file is in scope.
- **Live teams.** Changing `activeRoster` never changes a live team.
- **`/ah:pipeline`** creates its team through `create`, so it uses the
  selection too.

### 3.6 Verbs

Each verb takes `--cwd`, and takes `--json` where the existing verbs do.
Human and JSON output both name the roster and its source.

In JSON, the selection is:

    selection: { roster: <name or "default">, source: "flag"|"env"|"activeRoster"|"team"|"default", level: <level or null>, path: <path or null> }

Document it in docs/cli-tools.md.

- **`roster list [--json]`** is read-only. It lists the default block and
  every `rosters.<name>` key visible from cwd. For each name it gives:
  - the level and path that win, and the levels it is shadowed at;
  - its member count and route;
  - whether it is the current selection;
  - which teams use it: teams in this checkout's hierarchy dir (and, from a
    worktree, the main checkout's) whose effective roster key (via
    `teamRosterKey`) is that name. It uses the existing team-file readers.

  A legacy `rosters.default` block is listed with the §3.3 note.
- **`roster copy <src> <dst> [--level L] [--dry-run]`** copies the `src`
  block to `rosters.<dst>`.
  - `src` is resolved by the normal rules, and `default` means the unnamed
    block.
  - It writes at `--level`, by default the level `src` resolved at.
  - It copies `route` and `members` as stored.
  - It refuses:
    - `src` not defined;
    - `dst` failing `validateTeamAlias`, or equal to `default`;
    - `dst` already defined at that level.

  This is how a roster is made from another one. `init --roster` still makes
  an empty one.
- **`roster delete <name> [--level L] [--dry-run]`** removes the
  `rosters.<name>` key at `--level`, by default the level where it resolves.
  - It refuses:
    - `default`;
    - a name that any team file in this checkout's hierarchy dir, or the main
      checkout's, resolves to by `teamRosterKey` (so a legacy team named after
      the block counts). It lists those teams and points at `disband` or
      `reap`.
    - a name that `activeRoster` in the same file selects.
  - It warns and goes ahead when `activeRoster` at another level selects the
    name.
  - From a linked worktree, if the block resolves only from the main
    checkout's file, it refuses and names that path. It never reports success
    for a no-op at the worktree's own path.
  - roster.mjs:1606-1608's comment mentions a `remove … --all` form. If a
    whole-block erase still exists, it and `roster delete` share one
    implementation and the same refusals.
- **`roster use <name>|default [--level L]`** writes `activeRoster`, and
  **`roster use --clear [--level L]`** removes it.
  - `--level` defaults to `repo-user` inside a git repo, else `global`.
  - It refuses a name that no visible level defines, except `default`.
  - It warns, and still writes, when the target level's readers can't see
    the roster, meaning the roster isn't defined at the target level itself:
    - with `--level global`, other repos will see the selection as missing;
    - with `--level repo`, other people working in the repo will see it as
      missing, because the roster lives only in this user's files (repo-user
      or global);
    - with `--level repo-user`, it never warns, because only this user in
      this repo reads that file and they can see every level.
  - `--clear` removes the key. If the file would then hold nothing but
    `version`, it deletes the file, so a file that existed only to hold a
    selection doesn't linger and make the setup read as configured (§3.1).
  - It prints the resulting selection, worked out by the §3.2 rule.
- **`show`** adds `selection` to its output.
- **`create --plan`** carries `selection` only when a roster is selected
  (source other than `default`). A plan without it is built from the default
  block, so plans stay byte-identical when nothing is selected.
- **`create`, `init`, `add`, `edit`, `remove` and `show`,** when given no
  `--roster`, use the selection (§3.2). With nothing selected they behave as
  today, including `add`'s bootstrap when nothing resolves.

**How the verbs are called.** The four are subcommands of one verb,
`roster.mjs roster list|copy|delete|use …`, dispatched the way `role
list|set|remove` is.

**Gating and guards.** An earlier draft of this spec said to gate the three
write verbs "like `init`, `add`, `edit` and `remove`". Those are ungated
(§1), so the rule is:
- **The skill gate doesn't change.** None of the four verbs is gated, and
  `pretooluse-roster-skill-gate.mjs` and
  `tests/check-gate-name-agreement.mjs` stay as they are.
- **`ROSTER_MUTATING_CMDS` (roster.mjs:168) doesn't change either.** None of
  the four joins it, because none of them can change the block a live team
  was built from:
  - `copy` only writes a new name;
  - `delete` already refuses a roster that a team uses (above);
  - `use` changes only which roster later commands pick (§3.5).
- **Usage text.** The new verbs appear in `printUsage` and the usage text.

### 3.7 SessionStart and other injection

- The roster `resolveConfig` returns follows §3.2. So every hook that reads
  it (the route gate, SessionStart, SubagentStart) sees the selection with no
  other change.
- The only new injected text is the §3.4 warning, and it appears only when
  the selection is broken.
- A session with nothing selected gets byte-identical injection. The
  directive-size ceilings (tests/test-directive-size.sh) stay green with no
  trimming. If one fails, stop and report to the Architect.

### 3.8 Skills and docs

- **`skills/agent-roster/SKILL.md`:**
  - flows for list, copy (as well as "new from an existing one"), delete, and
    use or clear.
  - When the user doesn't name a roster, the skill works on the selection and
    says which one it is and how to switch. It doesn't ask.
  - Delete asks for confirmation with AskUserQuestion.
- **`skills/agent-team/SKILL.md`:**
  - `create` uses the selection;
  - the plan names the roster;
  - `--roster` overrides it.
- **`docs/cli-tools.md`:** rows for the four verbs, `AH_ROSTER`,
  `activeRoster` and the `selection` JSON.
- **`docs/getting-started.md`:** in its roster section, a short "Named
  rosters" part covering:
  - what they are;
  - the §3.2 order;
  - `default`;
  - how a repo, a machine or one session picks one.

## 4. Part B: role packs

### 4.1 Why a pack is a Claude Code plugin

**The constraint.** Claude Code launches an agent only from what it has
loaded: `<repo>/.claude/agents/`, `~/.claude/agents/`, or an installed
plugin. ah peers launch with `claude --agent <ref>`, and legwork is
dispatched with `subagent_type`, so both depend on that.

**Why not an ah-owned directory.** A directory of agent files that only ah
knows about would need one of two things:
- copying the files into one of Claude Code's places, which gives two copies
  that drift;
- or making up agents at launch time, which doesn't reach the Agent tool in
  a session that ah didn't start.

**Why a plugin works.** A Claude Code plugin already covers the rest:
- fetching from a git URL, a GitHub repo or a local directory
  (`claude plugin marketplace add`);
- install, update, uninstall and versions;
- loading its agents with their tool limits enforced.

ah already resolves `plugin:agent` refs through installed_plugins.json (§1).
So a role pack is a plugin that also has an `ah-roles.json` file:
- no pack needs any change to this plugin's repo;
- any plugin can be a pack.

**Personal roles** that aren't meant for sharing stay where they are today,
edited live: `~/.claude/agents/` for the user, `<repo>/.claude/agents/` for a
repo.

### 4.2 The manifest

`ah-roles.json` sits at the plugin root. The field names are the contract;
the values here are an example:

```json
{
  "version": 1,
  "roles": {
    "godot-implementor": {
      "class": "implement",
      "agent": "godot-implementor",
      "label": "Godot Implementor",
      "description": "Builds Godot 4 features in GDScript",
      "routes": "Godot scenes, GDScript and shaders",
      "model": "opus"
    }
  }
}
```

- **`version`** must be 1. Any other value makes the whole pack unreadable,
  with the finding `pack-version`.
- **Role keys** follow the custom-role name rules (`roleNameError`), so
  built-in and reserved names are refused.
- **Role fields** are the custom-row fields `class`, `agent`, `label`,
  `description`, `routes`, `model` and `dispatch`. They are checked by
  `checkCustomRow`, the same function custom rows use. `peer` is not allowed,
  because it is a local setting.
- **`agent`** names an agent inside this plugin: `agents/<agent>.md` under
  its install path.
  - It may not contain `:`, `/`, `\` or `..`.
  - It defaults to the role key.
  - It resolves as `<plugin>:<agent>`, so a pack can't point a role at
    another plugin's agent or at a path.
- **Unknown keys** warn and are ignored.
- **Hidden text is refused** (`pack-hidden-chars`). This covers the
  manifest's string fields and the role's agent file, and means:
  - control characters other than newline and tab;
  - Unicode format characters (category Cf, which includes the
    bidirectional controls);
  - the tag block U+E0000–U+E007F.

  Every place ah prints pack text (dry runs, `pack show`, `role trust`
  diffs) escapes ANSI sequences. Otherwise the text the user reviews
  wouldn't be the text the model reads.
- **The agent file must be valid UTF-8,** or the role is refused.
- **A malformed file** never crashes a hook. The pack is reported as
  unreadable.
- **A pack's other agents,** the ones not in the manifest, stay ordinary
  plugin agents.

### 4.3 Discovery

- **What counts as a pack:** an install record in installed_plugins.json
  whose install path holds `ah-roles.json`.
  - Pack code reuses lib-config.mjs's installed_plugins.json reader
    (`installedPluginsPath` and `locateAgentFile`'s record walk,
    :1509-1573). It does not add a third reader.
  - The plugin's name is the `<plugin>` part of its `<plugin>@<marketplace>`
    key, which is the same name agent refs use.
- **Duplicates.** ah can't be sure which install record Claude Code loads,
  so for packs it doesn't guess.
  - An adopted row records `<plugin>@<marketplace>` (§4.4).
  - Its agent is still launched as `<plugin>:<agent>`, which Claude Code
    resolves by the plugin name alone. So every install record for that
    plugin name, in any marketplace and any version or scope, is a
    candidate.
  - ah computes the pin (§4.5) for every candidate. If more than one
    distinct value comes out, the role is unavailable with `pack-ambiguous`,
    and the finding lists the records.
  - Rows without `from` keep `locateAgentFile`'s first-existing rule
    unchanged.
  - (Evidence step E4 shows which record Claude Code actually loads. The
    rule stands whatever it finds.)
- **No other search path.** A directory can be inspected before install
  (`pack show --path`, §4.7). But roles are adopted only from installed packs,
  because only those can be launched.
- **Enablement** can't be read (§1). A role from a disabled pack fails at
  spawn, as a disabled plugin agent does today. This is a known limit.

### 4.4 Adopting a role

Nothing from a pack reaches the registry, the routing text or a spawn until
the user adopts it:

    role set <name> --from <plugin>@<marketplace>:<role> [--label L] [--description D] [--routes R] [--model M] [--dispatch …] [--level L] (--dry-run | --pin sha256:…)

- **`--from` names the marketplace.** `<plugin>:<role>` is accepted when
  exactly one installed marketplace offers that plugin. It is stored in full,
  and when several marketplaces offer it the command is refused with a list
  of them.
- **Committing needs `--pin`.** Without `--dry-run`, the command needs
  `--pin` set to the pin the dry run printed. It refuses a different value,
  exactly as `role trust` does (§4.5).
- **What the row holds:** `from: "<plugin>@<marketplace>:<role>"`, `pin`
  (§4.5), and only the fields the user passed.
  - Class, agent and the other fields are read from the manifest each time
    the row is resolved, and then the row's own fields are laid over them.
  - Changes from the pack's author arrive only through trust (§4.5), and the
    user's own settings survive it.
- **How it resolves.** Such a row is expanded into a full custom row before
  `checkCustomRow` and the class contract run. That happens in the one place
  custom rows are loaded (lib-config.mjs:1384-1394). From there on it is an
  ordinary custom role:
  - `routes` makes it an in-chain alternative;
  - `--routes ""` makes it a side role;
  - every existing check applies.
- **Refused flags.** `--class`, `--agent` and `--scaffold` are refused with
  `--from`, and on any row that has `from`. The message says to remove the
  role and define your own to change them.
- **The dry run** prints:
  - the pack's fields, verbatim and ANSI-escaped (they reach every
    session's context through routing);
  - the contract findings;
  - the pack-agent findings and the effective tool list, with flags (§4.6);
  - what the plugin carries besides roles (§4.7);
  - for an implement-class role with `routes`, exactly this line: "takes
    work in unattended /ah:pipeline runs (pushes draft PRs, does not merge)"
    (§10 Q7, decided by the user);
  - the pin to commit with.
- **The commit is gated.** A non-dry-run `role set --from` or `role trust`
  goes through `hooks/pretooluse-roster-skill-gate.mjs`. The hook already
  parses roster commands (`parseAhCommand`, :79-80). This is a second rule
  in it, separate from its one-shot skill rule:
  - **Top-level interactive session** (a plain session or the Orchestrator):
    native `ask`, so the user approves in Claude Code's own prompt, which a
    model can't answer. The pattern follows
    `hooks/pretooluse-disband-close-gate.mjs:31`, which already asks the user
    this way. It applies only in permission modes where that prompt is
    known to reach the user (evidence step E6); in any other mode, deny, and
    say which mode to switch to.
  - **Deny** when any of these is true:
    - the session is a subagent (`isSubagent`);
    - its hierarchy role is anything other than the Orchestrator
      (`resolveHierarchyRole`), which covers role and peer sessions;
    - `AH_TEAM_FILE` is set (a team member);
    - a pipeline run is live in this checkout (§4.9).
  - **Ordering.** The rule runs before the hook's early exit for subagents
    (:76). It isn't one-shot: every commit is checked, and nothing is
    recorded.
  - **It fails closed.** Any error while judging a command that parses as a
    `--from` commit or a `role trust` commit denies it. This is unlike the
    skill rule, which fails open.
  - **Other files.** `tests/check-gate-name-agreement.mjs` and the
    one-shot `VERBS` list don't change.

  An earlier ruling said phase 2 needed no gate change. That is superseded:
  these two commits are gated. `role list`, the dry runs and `pack` stay
  ungated.
- **Default level:** the existing `role set` rule. That is where the row
  already is, else `global`.

**Collisions**
- **Pack role names** never enter the registry by themselves, so two packs
  may offer the same name. The user picks the local `<name>` at adoption, and
  it may differ from the pack's name.
- **A name already defined at the target level** by a row with a different
  `from`, or with none, is refused: "pick another name or remove it first".
  The same `from` again re-seeds that row and re-pins it, after a dry run as
  trust does.
- **Across levels,** the existing whole-row rule applies: the most specific
  level wins.
- **A built-in name** as `<name>` replaces that built-in's agent file (the
  existing override).
  - Only `agent` comes from the pack, plus `model` if the user passes it.
  - The manifest's class must equal the built-in's class, or the command is
    refused.
  - It is pinned like any adopted row.
- **One agent claimed by two roles** gets the existing refusal
  (roster.mjs:412-413).

### 4.5 Pins and trust

**The pin covers the whole plugin, not just the agent file.** An agent's
behaviour also comes from the rest of its plugin. Its body can tell it to
read or run another file there, and the plugin's hooks, MCP servers, skills
and scripts switch on with it. So a pin over one file would let a plugin
update change what the role does and still read as trusted.

The pin is `sha256:<64 lowercase hex>` of the UTF-8 bytes of
`JSON.stringify([1, row, agentText, files])`, where:
- `1` is the format version;
- `row` is the role's manifest row, with its keys sorted;
- `agentText` is the agent file's text (it must be valid UTF-8, §4.2);
- `files` is an array of `[relpath, sha256hex]` pairs, one per regular file
  under the install path. Paths use `/` and are relative to the install path.
  The array is sorted by path, and a top-level `.git` directory is skipped.

This form is permanent once it ships. Changing it later would need a
migration.

Consequences:
- **Any change in the plugin changes the pin of every role adopted from it:**
  another role's row, the manifest's formatting, a hook, a script, a skill.
  The `update` flow already trusts one role at a time (§4.8), so this costs
  a few more prompts, not a new flow.
- **Symbolic links.** A symbolic link anywhere in the tree (checked without
  following it) makes the role unavailable with `pack-symlink`, because what
  it points at isn't pinned.
- **Speed.** Hashing a whole tree runs on every resolution, SessionStart
  included. Evidence step E5 measures it. There is no cache in the first
  version.

**The stored copy.** On adoption and on trust, ah stores what it pinned at
`~/.claude/agent-hierarchy/trusted/<hex>.json`, keyed by the hash so repos
share it. It holds `row`, `agentText` and the `files` map, which is exactly
enough to recompute the hash. It has two uses:
- the `role trust` diff;
- resolution: an adopted role is available only when this machine has a
  stored copy for its pin that re-hashes to its own name. This applies at
  every level. So a cloned repo, or a commit from someone else, can't make
  a role live that this machine's user never trusted, and a doctored stored
  copy can't fake a diff.

**Checks on every resolution** of a `from` row:
- The plugin isn't installed, there is no manifest, or the manifest has no
  such role: unavailable, `pack-missing`.
- The manifest is unreadable or invalid: unavailable, `pack-invalid`, with
  the finding.
- More than one candidate record, with different pins (§4.3): unavailable,
  `pack-ambiguous`.
- A symbolic link in the tree: unavailable, `pack-symlink`.
- The hash doesn't match the pin: unavailable, `pack-changed`, with the fix
  `role trust <name>`.
- No stored copy for the pin on this machine, or one that doesn't re-hash to
  its name: unavailable, `pack-untrusted-here`, with the fix
  `role trust <name>`.

"Unavailable" is the state a contract failure already produces:
- `role list` shows `UNAVAILABLE`;
- SessionStart leaves the role out of routing;
- spawn refuses it.

The new reasons go through that same path. Whatever shows unavailable roles
today (`role list`, SessionStart's contract check, `doctor`) shows them too.

**`role trust <name> --dry-run`** works on a `from` row only. It shows:
- the manifest-field changes;
- a line diff of the agent file against the stored copy;
- the files added, removed and changed anywhere in the plugin;
- the current findings;
- the pin it would write.

With no stored copy (for example, a repo row adopted on another machine), it
shows the whole current agent file and the full file list, and says so. It
adds no npm dependency: it may use the system `diff -u` when present, and
otherwise prints both texts.

**`role trust <name> --pin sha256:…`** commits.
- It refuses unless the pin given equals the pin it computes now. So what
  gets trusted is exactly what the dry run showed; if the pack changed in
  between, the commit fails.
- It refuses while any error finding stands, as `role set` does.
- Otherwise it writes the new pin and stored copy.
- The commit is gated (§4.4).

**Repo-level rows.** A repo-level row committed with a pin makes the role
available on another machine only when both hold: that machine's installed
content hashes to the pin, and its user has trusted it there (the stored
copy). Until then, that machine sees `pack-changed` or
`pack-untrusted-here`.

### 4.6 Extra checks for pack agents

An agent file can grant more than its tool list does, and more keys will
come. So for an agent that a `from` row points at, the frontmatter is held to
an **allowlist**, which fails closed. This is on top of the class contract.

- **Allowed keys:** `name`, `description`, `model`, `tools`,
  `disallowedTools`, `color`, `effort`, `maxTurns`. Any other key is an
  error, including `permissionMode`, `hooks`, `mcpServers`, `skills`,
  `memory`, `isolation` and `initialPrompt`.
- **`tools` is required and explicit.** It must be a non-empty list with no
  wildcard. Leaving it out would inherit every tool, MCP tools and Agent
  included.
- **Strict grammar.** Every non-blank line between the `---` fences must be
  either an unquoted top-level key from the list or a continuation of one (an
  indented list item or a folded line). Everything else is an error:
  - a quoted key;
  - a duplicate key;
  - a YAML anchor, alias or merge key (`&`, `*`, `<<`);
  - any line ah can't classify.

  ah's frontmatter reader today skips lines it doesn't recognise
  (lib-config.mjs:1620-1621). A quoted `"permissionMode": …` would slip past
  it, yet it is valid YAML to Claude Code. The strict check must not have
  that gap.
- **The dry run** (`role set --from`, `role trust`) prints the effective tool
  list and flags `Bash`, `Agent`, any `mcp__*` tool, `Write` and `Edit`.

A user's own bare-name files are unchanged, and so are existing
`plugin:agent` rows without `from` (§10 Q6). Pack support for `skills` and
`memory` is a follow-up, to add when a real pack needs it. The whole-tree
pin (§4.5) would already cover skills shipped in the same pack.

Evidence step E3 checks whether `claude --agent <plugin>:<agent>` honours
these keys from a plugin agent. That tells us how big the gap was; the
allowlist stands either way.

### 4.7 Inspecting packs

- **`pack list [--json]`** is read-only. For every installed pack it shows:
  - the plugin, its version (from its `plugin.json`) and its install path;
  - its roles: name, class, agent, routes;
  - each role's adoption: local name, level, `trusted` or `changed`;
  - a count of what the plugin carries besides roles.
- **`pack show <plugin> [--json]`** and **`pack show --path <dir> [--json]`**
  are read-only. They show one pack in full:
  - the manifest findings;
  - each role's fields verbatim, with its contract and pack-agent findings;
  - its adoption status (installed packs only);
  - **also in this plugin:**
    - every entry of the plugin root other than `ah-roles.json`, `agents/`,
      `.claude-plugin/` and README, LICENSE or CHANGELOG files;
    - every `plugin.json` key other than `name`, `version`, `description`,
      `author`, `homepage`, `repository`, `license` and `keywords`;
    - every agent file that isn't in the manifest.

  The point of this list is to flag hooks, MCP servers, commands and skills,
  which run in every session once the plugin is installed, whatever ah does.
  The list works by exclusion, so a new kind of plugin component shows up
  without a code change.
  - **Content digest:** the sha256 of the `files` array (§4.5), so the same
    tree can be recognised before and after install (§4.8).
- **`pack` verbs are not gated,** because they are read-only.

### 4.8 Install, update and remove

These are flows in `/ah:agent-role` (skills/agent-role/SKILL.md). They drive
Claude Code's own plugin commands and the ah verbs above. Each `claude plugin
…` command is shown to the user before it runs, and the user's permission
settings govern it.

**`install <source>`** takes a git URL, `owner/repo`, or a local directory:
1. Add the source as a marketplace.
2. Run `pack show --path` on the plugin's directory.
   - For a local directory, that is the directory itself.
   - For a remote source, it is wherever the marketplace was fetched to
     (evidence step E1).
   - If nothing is fetched before install, inspect a shallow clone in a
     scratch directory instead.
3. Show the roles and everything else the plugin carries. Ask with
   AskUserQuestion: install, or cancel.
4. Install the plugin. Then run `pack show` on the installed plugin and
   compare its content digest with the one from step 2. A marketplace entry
   can take the plugin from somewhere other than what was inspected. If the
   digests differ, tell the user that what got installed isn't what they
   reviewed, offer to uninstall it, and adopt nothing.
5. Offer its roles for adoption (AskUserQuestion, multi-select). For each
   role the user picks:
   - run `role set <name> --from … --dry-run` and show the result;
   - commit with the `--pin` the dry run printed. The commit is gated
     (§4.4), so the user also approves it in Claude Code's own prompt.
6. Tell the user that sessions already running need a restart to dispatch
   the new agents as subagents. Peers spawned from now on are fine.

**`update <plugin>`:**
1. Update the marketplace and the plugin.
2. Run `pack show <plugin>`.
3. For each adopted role that is now `pack-changed` (any change in the
   plugin changes all of them, §4.5), run `role trust <name> --dry-run` and
   show the diff. Ask: trust, leave it unavailable, or remove the role. A
   trust commits with the printed `--pin`.

**`uninstall <plugin>`:**
1. List the roles adopted from it (`role list --json`, filtered on `from`).
2. Ask: remove those roles too (recommended), or keep them (they become
   unavailable).
3. Remove them with `role remove`. That is refused while a roster member uses
   the role; the flow then names the roster and points at `/agent-roster`.
4. Uninstall the plugin, and optionally remove its marketplace.

**`adopt`** and **`trust`**, for packs already installed, are the §4.4 and
§4.5 steps on their own.

### 4.9 Pipeline runs and spawn limits

**Gate slots stay first-party.** In `/ah:pipeline`, the checks on
unattended code are the Reviewer's verdict, the Architect's sign-off
(skills/autonomous-pipeline/SKILL.md:235, :881) and the secret scan (:299).
A role from a pack must never fill one. Otherwise one pack could supply both
the implementer and its only check. And the item's `Reviewer:` line
(SKILL.md:140-142) can come from third-party issue text.

- **Resolution at queue time** (SKILL.md:133-150, "The item's implementer /
  reviewer"). When that step would pick a role whose row has `from` as the
  item's reviewer or designer, the pipeline uses the built-in instead. That
  covers a pack alternative picked by the user, by a spec's `Reviewer:` line,
  or by the routing rule. The user is told in the run summary.
  - `role list --json` must show `from` on each row, and on a built-in whether
    its agent is overridden by a `from` row, so the skill can tell.
  - An additional-reviewer slot doesn't exist today, and none is added.
- **A built-in overridden by a pack.** If the built-in Reviewer or Architect
  is itself overridden by a `from` row (§4.4), there is no first-party role
  for that slot. The run halts at bootstrap, before any work. It says which
  override to remove (`role remove <built-in>` restores the shipped agent),
  or suggests running the item interactively.
- **The secret scan** always dispatches `ah:secret-scanner` by its fixed
  name. It isn't a roles row, so a pack can't replace it. No change is
  needed.
- **Implement-class pack roles** may take work in unattended runs (§10 Q7,
  decided). Their code is still checked by the first-party Reviewer.

**Backstop in code.** While a pipeline run is live in this checkout,
`spawn-one` and `spawn-ad-hoc` refuse a review-class or design-class role
whose row has `from`, including a built-in overridden by one. Chain roles
always run as peers spawned by roster.mjs (§1), so a pack reviewer or
designer can't be started for the run even if the skill's rule is skipped.
What remains: a pack peer that was already running before the run started.
The skill's rule covers that case, and nothing in code does.

**"A pipeline run is live"** means one test, shared by this backstop and the
gate in §4.4:
- if `hooks/pretooluse-push-guard.mjs` already recognises a pipeline run,
  reuse its check;
- otherwise, an open `pipeline-run-anchor` exchange for this checkout's team,
  found by the location procedure in skills/autonomous-pipeline/SKILL.md
  (§ The run anchor).

A stale open anchor then blocks these commits too. That is deliberate: the
next run reports the stale anchor anyway.

**No `bypassPermissions`.** `spawn-one`, `spawn-ad-hoc` and `create` refuse
to launch a `from` role, including a built-in overridden by one, when the
member's `autoMode` is `bypassPermissions`. That value is still accepted for
legacy configs (lib-roster.mjs:82-85). The refusal says to pick another mode.

### 4.10 Security notes

- **What ah can't gate.** Installing a plugin is Claude Code's trust
  decision. Once it is installed:
  - its agents become subagent types in every session;
  - its hooks and MCP servers run in every session.

  ah can't gate that. It shows all of it before install (§4.7, §4.8) and
  recommends packs that carry only roles.
- **Nothing runs until it is adopted.** No pack role routes, dispatches or
  spawns until the user adopts it. That happens one role at a time, after a
  dry run that prints its fields verbatim.
- **What the pin gives, and what it doesn't.**
  - It works as a tripwire, not a gate: if anything in the plugin changes
    after the user trusted it, the role goes unavailable until the user
    reviews the change (§4.5). That holds even after a plain
    `claude plugin update` run outside ah.
  - It doesn't stop the plugin's own hooks or MCP servers from running with
    the new content. That is Claude Code's side (above).
- **A human commits trust.**
  - Adoption and trust commit only with the exact pin the dry run printed.
  - The commit goes through Claude Code's own approval prompt in a top-level
    interactive session, and is refused in role, peer and subagent sessions
    and in pipeline runs (§4.4).
  - What remains: a session with Bash can still hand-edit
    `agent-hierarchy.json` or the stored copies. ah can't hold that line.
    Requiring a self-verifying stored copy at resolution (§4.5) narrows it.
- **Tool limits are role discipline, not a sandbox.**
  - The class contract and the frontmatter allowlist (§4.6) decide which
    tools an agent file asks for.
  - They don't confine what a granted tool does. A review-class role with
    Bash can still write files and push.
  - The boundary is the session's permission mode, and a pack role can't run
    under `bypassPermissions` (§4.9).
  - A pack can't point a role at another plugin's agent or at a path.
- **Injected text.** `description`, `routes` and `label` reach every
  session's context. They keep the existing limits (one line, 160
  characters, no backticks), refuse hidden characters (§4.2), and are shown
  verbatim and ANSI-escaped at adoption and at trust.
- **Advise class.** An advise-class pack role keeps the Ultra-Advisor rule:
  every dispatch needs the user's approval.
- **The autonomous pipeline.**
  - `/ah:pipeline` never merges: a person merges
    (skills/autonomous-pipeline/SKILL.md:923, :930). What it does unattended
    is push `ah/issue-N` branches and open draft PRs, and the person who
    merges relies on the Reviewer's verdict.
  - So a pack role must never be the check on that code: in pipeline runs,
    gate slots are always first-party (§4.9).
  - Whether pack implement-class roles take work in unattended runs at all
    is §10 Q7.
- **Rows committed to a repo.** A repo-level `from` row activates a role only
  when this machine's installed content matches the pin and this machine's
  user has trusted it (§4.5). That reaches no further than a repo can today
  with a `.claude/agents/` file.

### 4.11 Not changed

- Built-in roles and classes.
- Existing custom rows, bare-name refs, and `plugin:agent` refs without
  `from`.
- The route gate and the Ultra-Advisor gate.
- Codex members. Their instructions file takes the agent body from the
  resolved file, so a pack role works there unchanged.
- `role remove` never deletes a file or touches a plugin. Stored copies stay
  in place: they are small and shared.

## 5. Files

**Phase 1 (A)**
- `agent-hierarchy/hooks/lib-config.mjs`:
  - the selection (§3.2);
  - the `activeRoster` merge, candidate paths and preference-only status
    (§3.1);
  - the missing check and its warning (§3.4).
- `agent-hierarchy/hooks/roster.mjs`:
  - the `rosterArg` seam (:733-740);
  - `roster list`, `roster copy`, `roster delete` and `roster use`;
  - `selection` in `show`;
  - the `doctor` finding;
  - the usage text;
  - `writeLevelFile` and `migrateStaleKeys` keeping `activeRoster`.
- No hook gate changes (§3.6).
- `agent-hierarchy/skills/agent-roster/SKILL.md` and
  `agent-hierarchy/skills/agent-team/SKILL.md` (§3.8).
- `agent-hierarchy/docs/cli-tools.md` and
  `agent-hierarchy/docs/getting-started.md` (§3.8).
- New `agent-hierarchy/tests/test-roster-select.sh` (§6).
- Version: the next ah minor, in `agent-hierarchy/.claude-plugin/plugin.json`
  and in ah's entry in `.claude-plugin/marketplace.json`, together.

**Phase 2 (B)**
- `agent-hierarchy/hooks/lib-config.mjs`:
  - manifest reading and checks, reusing `checkCustomRow` and
    `roleNameError`, plus the hidden-text and UTF-8 checks (§4.2);
  - pack discovery, on the existing installed_plugins.json reader, with every
    candidate record kept (§4.3);
  - `from`-row expansion, where custom rows load;
  - computing and checking pins over the whole tree, and verifying stored
    copies (§4.5);
  - the new unavailable reasons;
  - the strict frontmatter allowlist for pack agents (§4.6);
  - the shared "pipeline run is live" test (§4.9).
- `agent-hierarchy/hooks/roster.mjs`:
  - `role set --from` and `role trust`, each with `--pin`;
  - `role list` showing `from`, pin state and pack overrides of built-ins (in
    both text and `--json`);
  - `pack list` and `pack show`, with the content digest;
  - the spawn refusals (§4.9);
  - ANSI escaping wherever pack text is printed;
  - the usage text.
- `agent-hierarchy/hooks/pretooluse-roster-skill-gate.mjs`: the commit rule
  (§4.4).
- `agent-hierarchy/skills/autonomous-pipeline/SKILL.md`: at queue-time
  resolution, gate slots stay first-party, and the bootstrap halts on a
  pack-overridden built-in (§4.9).
- `agent-hierarchy/skills/agent-role/SKILL.md`: the §4.8 flows.
- `agent-hierarchy/docs/custom-roles.md`: a new section, "Role packs",
  covering the format, adopting, trust, install/update/uninstall, the
  pipeline limits (§4.9), and the security notes (§4.10), in plain words. `agent-hierarchy/docs/cli-tools.md`: rows.
- New `agent-hierarchy/tests/test-role-packs.sh` (§6).
- Version: the next ah minor, in both files.

## 6. Tests the change needs

**How to test**
- **Mutation standard.** Each row must be seen failing against a
  deliberately broken build before it counts as coverage
  (docs/spec-process.md). Where it helps, a suggested mutation is in
  brackets.
- **Results table.** Whoever lands each phase writes the table of results,
  after it lands.
- **Sandboxes** redirect HOME and build fresh repos, as
  tests/test-roster-levels.sh does. Phase 2 also writes a fake
  `~/.claude/plugins/installed_plugins.json` that points at plugin
  directories in the sandbox.

**Phase 1** (test-roster-select.sh)
- **S1 Nothing selected.** `show`, `create --plan` and `add` use the default
  block, as today. [make the selection default to the first named block]
- **S2 Precedence.** Flag, then `AH_ROSTER`, then `activeRoster` at
  repo-user, then repo, then global. [swap env and `activeRoster`]
- **S3 `default`.** At each source, it selects the unnamed block over a wider
  selection. [treat `default` as a block name]
- **S4 A missing selection:**
  - `show`, `add` and `create` refuse and name the source;
  - `init` creates the block;
  - `resolveConfig` warns and uses the default block without throwing;
  - `doctor --check` exits 1.

  [drop the check]
- **S5 Team files:**
  - A team file in scope wins over `AH_ROSTER` and `activeRoster`.
  - It still wins when it records the default block.
  - A legacy team file keys by team name.
  - With no team file, the selection applies.

  [let a null from `teamRosterKey` fall through]
- **S6 `create`** with no flag records the selected key in the team file
  (null for `default`). [record only the flag]
- **S7 `roster list`** shows names, the winning level, shadowing, counts, the
  selection with its source, the teams per name, and a legacy
  `rosters.default` with its note.
- **S8 `roster copy`:**
  - copies default to named, and named to named at another level, verbatim;
  - refuses a missing `src`, a `default` or invalid `dst`, and an existing
    `dst`.
- **S9 `roster delete`:**
  - removes the block;
  - refuses `default`, a name a team resolves to (including a legacy team),
    and a name `activeRoster` selects in the same file;
  - warns for another level.
- **S10 `roster use`:**
  - writes repo-user by default inside a repo, and global outside one;
  - refuses an undefined name;
  - `--clear` removes the key;
  - accepts `default`.
- **S11** `activeRoster` survives `writeLevelFile`. A global file holding only
  `activeRoster` counts as unconfigured.
- **S12** From a linked worktree, the main checkout's repo-level
  `activeRoster` applies.
- **S13** `AH_ROSTER=""` counts as unset.
- **S15 Nothing configured.** In a sandbox with no configuration at any
  level:
  - `roster use default` keeps `resolveConfig().configured` false and
    SessionStart's injection byte-identical to before;
  - `roster use --clear` then leaves no repo-user file;
  - a repo-user file holding `version`, `activeRoster` and a roster block
    still counts as configured.

  [treat the file as configured whenever it exists]
- **S16 Audience warning.** `roster use X --level repo` warns when X is
  defined only at repo-user or global, and not when X is defined at repo.
  `--level global` warns when X isn't defined at global. `--level repo-user`
  never warns. [warn only for global]
- **S14 Not gated or guarded.** None of the four verbs is gated. While the
  session owns a live team, `roster copy`, `roster delete` and `roster use`
  still run, and `add` is still refused as today. [add `roster` to the skill
  gate's list or to `ROSTER_MUTATING_CMDS`]
- **The existing suite** passes unchanged, test-directive-size.sh included.

**Phase 2** (test-role-packs.sh)
- **P1 `pack list`** finds plugins that have `ah-roles.json` and skips those
  that don't.
- **P2 Manifest and text checks:**
  - `version` other than 1;
  - a bad or built-in role name;
  - `agent` containing `:`, `/` or `..`;
  - a field over 160 characters, or with a newline or a backtick;
  - an unknown key warns;
  - `pack-hidden-chars`: a bidirectional control or a U+E00xx tag character
    in a field, and a zero-width character in the agent file;
  - a non-UTF-8 agent file is refused;
  - an ANSI sequence in a field prints escaped.

  [drop the Cf check]
- **P3 `role set --from`:**
  - the dry run prints the fields verbatim and the pin;
  - a commit with no `--pin`, or with a stale one, is refused;
  - a commit with the printed pin writes only `from`
    (`<plugin>@<marketplace>:<role>`), `pin` and the flags passed;
  - `<plugin>:<role>` expands when exactly one marketplace offers the plugin,
    and is refused when two do;
  - resolution yields the manifest's class and `<plugin>:<agent>`;
  - for an implement-class role with `routes`, the dry run prints the exact
    unattended-runs line (§4.4).

  [copy manifest fields into the row]
- **P4 Names and flags:**
  - a local name different from the pack's works;
  - a taken name is refused;
  - `--class`, `--agent` or `--scaffold` with `--from` is refused.
- **P5 A built-in via `--from`:** a class mismatch is refused; a match
  overrides the agent and is pinned.
- **P6 The pin covers the tree.** Each of these gives `pack-changed` in
  `role list`, leaves the role out of SessionStart's routing, and makes spawn
  refuse it, while the agent file stays untouched:
  - changing one byte of a file under `hooks/`;
  - changing a script under `bin/`;
  - adding a file;
  - reformatting `ah-roles.json`;
  - changing another role's row.

  Also:
  - changing only a file under `.git/` keeps the role trusted;
  - a known fixture tree hashes to a fixed pin (this pins the serialization).

  [pin only the agent file and row]
- **P7 `role trust`:**
  - the dry run shows the field changes, the agent file diff, and the files
    added, removed and changed, all against the stored copy;
  - with no stored copy, it shows the full file and the file list;
  - it refuses while errors stand, and with a stale `--pin`;
  - the commit re-pins and writes a stored copy;
  - the user's own fields survive.
- **P8 Frontmatter allowlist (pack agents).** Each of these is an error:
  - an unlisted key (`permissionMode`, `skills`, `memory`, a made-up one);
  - a quoted `"permissionMode":` key [the lenient line parser];
  - a duplicate key;
  - `&anchor`, `*alias` or `<<:`;
  - `tools` missing, or containing a wildcard;
  - a line that can't be classified.

  The dry run flags `Bash`, `Agent`, `mcp__*`, `Write` and `Edit`. The same
  keys in a user's own bare-name file behave as today.
- **P9 An uninstalled plugin.** With its record removed, the role is
  `pack-missing`, and `role remove` still works.
- **P10 `pack show --path`** on an uninstalled directory lists the roles and
  the "also in this plugin" entries: a hooks dir, `.mcp.json`, `commands/`,
  and an agent not in the manifest.
- **P11** test-custom-roles.sh and test-role-contract.sh pass unchanged.
- **P12 Symbolic links.** A symbolic link anywhere in the pack tree gives
  `pack-symlink`. [follow links while hashing]
- **P13 Ambiguous installs.** Two install records for the same plugin name
  (two marketplaces, or two versions) with different content give
  `pack-ambiguous`. Identical content stays available. [take the first
  record]
- **P14 Stored copies:**
  - a valid row whose pin matches the installed content, but with no stored
    copy on this machine, gives `pack-untrusted-here`;
  - so does a stored copy edited so that it no longer re-hashes to its name;
  - a committed repo-level row behaves the same on a fresh HOME.

  [skip the stored-copy check]
- **P15 The commit gate** (`pretooluse-roster-skill-gate.mjs`, driven by
  hook payloads):
  - for a non-dry-run `role set --from` or `role trust`:
    - in a top-level interactive payload, the result is `ask`;
    - it is `deny` with `agent_id` set (subagent), with a non-Orchestrator
      `agent_type`, with `AH_TEAM_FILE` set, and with a live pipeline run;
    - it is `deny` in a permission mode E6 excluded;
    - it is `deny` when the rule throws;
  - dry runs, `role list` and `pack` pass;
  - the one-shot skill rule is unchanged.

  [fail open on error]
- **P16 Pipeline spawn backstop.** With a live pipeline run:
  - `spawn-one` and `spawn-ad-hoc` refuse a review-class or design-class
    `from` role, and a Reviewer or Architect built-in overridden by one;
  - an implement-class `from` role spawns.

  Without a live run, all of them spawn.
- **P17 No `bypassPermissions`.** A `from` role member with that `autoMode`
  is refused by `spawn-one`, `spawn-ad-hoc` and `create`, and a non-pack
  member with it behaves as today.
- **P18 Install check.** The flow in §4.8, step 4 (a digest that differs
  before and after install) is skill prose. `pack show`'s digest must be
  stable for the same tree and change when the tree changes; that part is
  testable.

## 7. Evidence steps for the Implementor

The decisions are already made; these steps fill in exact text. Record what
you find in the PR.

- **E1 (phase 2).** Find the `claude plugin` command lines for:
  - adding a marketplace from a git URL, from `owner/repo`, and from a local
    directory;
  - installing, with a scope;
  - updating a plugin, and updating a marketplace;
  - uninstalling;
  - removing a marketplace.

  Then, in a HOME-redirected sandbox, add a local-dir marketplace that holds a
  plugin carrying `ah-roles.json`:
  - Read `~/.claude/plugins/known_marketplaces.json` to see where a source
    lands before any install. The §4.8 flow uses that path; if a remote source
    isn't fetched before install, the flow uses the shallow-clone branch.
  - Install the plugin to confirm Claude Code accepts a plugin that carries
    the file. If it refuses, stop and report to the Architect: that is a spec
    gap.
- **E2 (phase 1): done.** The build found that the gate covers only team
  verbs and that `pretooluse-ah-cli.mjs` has no verb list (§1). That settles
  §3.6: no gate changes.

The phase 2 steps below come from the Ultra-Advisor's review. For E3 and
E4, the fix stands whatever they find; they only size the risk, and the
result goes in the PR.

- **E3 (phase 2).** Does a session launched with
  `claude --agent <plugin>:<agent>` honour `permissionMode`, `hooks`,
  `mcpServers`, `initialPrompt` or `memory` from a plugin agent file? Test
  each key with a harmless marker (for example, a hook that writes a file in
  the sandbox). The allowlist in §4.6 stands either way.
- **E4 (phase 2).** With two install records for one plugin name (two
  versions, or the same name from two marketplaces), which one does Claude
  Code load? Does it match `locateAgentFile`'s first-existing pick? The
  `pack-ambiguous` rule in §4.3 stands either way.
- **E5 (phase 2).** Measure the wall time of the tree hash (§4.5) for a large
  real plugin (about the size of godot-prompter), run the way SessionStart
  would run it.
  - **50 ms or less:** no change.
  - **More than 50 ms:** stop and report the numbers to the Architect. A size
    cap (`pack-too-large`, unavailable) comes first, and a stat-keyed cache
    only if the cap isn't enough. The Architect sets the cap from your
    numbers.
- **E6 (phase 2).** Hook the commit gate's `ask` (§4.4) into a sandbox
  session, and record whether Claude Code's approval prompt reaches the user
  in each of these permission modes: `default`, `acceptEdits`, `auto`,
  `plan`, `dontAsk`, `bypassPermissions`. Also confirm that the PreToolUse
  payload carries the permission mode.
  - The gate asks only in modes where the prompt reached the user, and
    denies in all others.
  - If the payload doesn't carry the mode, the gate asks and relies on
    Claude Code. Record that as a known limit.

## 8. Build order

1. **Phase 1:** all of §3. It can ship and be reviewed on its own.
2. **Phase 2:** all of §4, after phase 1 has merged. Both phases touch
   roster.mjs's usage text and lib-config.mjs's loading code.
   - The Ultra-Advisor has reviewed the trust model, and its fixes are in
     §4 (§11).
   - Run E3–E6 first. E5 can send the build back to the Architect.

## 9. Assumptions not verified

- **Where agents load from.** Claude Code loads agents only from the three
  places in §4.1. If it gains another, packs still work.
- **An extra root file.** Claude Code accepts a plugin with an extra
  `ah-roles.json` at its root. E1 checks this.
- **installed_plugins.json.** Its records keep the shape lib-config.mjs
  reads today: `plugins["<name>@<marketplace>"]` is an array of records, each
  with an `installPath`. Claude Code owns that file.
- **Which install record Claude Code loads, and whether `--agent` sessions
  honour extra frontmatter keys.** Both are unverified (E3, E4). The design
  fails closed either way.
- **Where the hook sees session kind.** PreToolUse payloads carry
  `agent_id` for subagents and `agent_type` for `--agent` sessions; ah's
  hooks already rely on both (`isSubagent`, `isTopLevelAgentSession`,
  lib-config.mjs:547, :556). Whether the payload also carries the permission
  mode is checked by E6.
- **Pipeline role resolution is skill prose.** Queue-time resolution
  (SKILL.md:133-150) has no code, so the gate-slot rule is prose there. The
  spawn refusal (§4.9) is the code backstop.

## 10. Open questions for the user

Each question has a default, and the spec is written on it.

- **Q1: How packs are built.** Packs are Claude Code plugins (default), or ah
  gets its own pack directory and installer. The default is recommended
  because only plugin agents can be launched natively (§4.1).
- **Q2: What a selection affects.** Selecting a roster also retargets `init`,
  `add`, `edit`, `remove` and `show` (default), or it affects only `create`.
- **Q3: The name `default`.** It is reserved for the unnamed roster
  (default). A legacy `rosters.default` block then keeps working only for its
  team.
- **Q4: Where `roster use` writes.** Your personal file for the repo by
  default (repo-user), or the shared repo file that is committed.
- **Q5: Install, update and remove.** They are `/ah:agent-role` flows over
  `claude plugin` (default), or `roster.mjs pack install|update|remove` verbs
  that run `claude plugin` themselves.
- **Q6: Allowlist scope — decided.** The frontmatter allowlist (§4.6) applies
  to pack roles only. Widening it to every `plugin:agent` row would break
  existing rows.
- **Q7: Packs in the pipeline — decided by the user.** Implement-class pack
  roles do take work in unattended `/ah:pipeline` runs. The adoption dry run
  prints "takes work in unattended /ah:pipeline runs (pushes draft PRs, does
  not merge)". Gate slots stay first-party whatever the answer (§4.9).
- **Q8: Deferred features.** Packs that ship ready-made rosters, and a
  scaffold for writing a pack (`pack new`), are deferred (default).

## 11. Decisions, confidence, follow-ups

These are vetoable. Each lists the decision and its reason.

- **Named rosters stay `rosters.<name>` blocks.** They already exist, with
  the right resolution and team recording; only the tooling around them was
  missing.
- **One selection rule, one implementation,** used by roster.mjs and
  `resolveConfig`, so hooks and verbs can't disagree.
- **Team files outrank the selection.** A live team keeps the roster it was
  built from.
- **A missing selection is refused by verbs and warned by hooks,** so an
  explicit choice never falls back silently and a hook never crashes on
  config.
- **`roster use` defaults to repo-user,** because a personal choice
  shouldn't change a committed file.
- **`copy` covers "new from an existing roster",** so there is one verb, not
  two.
- **Packs ride on Claude Code plugins** (§4.1).
- **Adoption is per role and explicit.** Installing never routes work.
- **An adopted row stores only `from`, `pin` and the user's own settings,**
  and the rest is read from the manifest. There's no second copy to drift,
  and the user's settings survive trust.
- **The pin covers the whole plugin tree.** Agent behaviour also comes from
  the rest of the plugin. The cost: any pack change re-trusts every role
  adopted from it.
- **The stored copy is required at resolution,** not only for diffs. A
  cloned repo can't activate a role this machine never trusted.
- **Trust commits carry `--pin` and are gated** (`ask` for a person, `deny`
  for everyone else), so a model can't trust something the user never saw.
- **Gate slots stay first-party in the pipeline.** A pack can't supply both
  the code and its only check.
- **Ambiguous installs are unavailable,** because ah can't know which record
  Claude Code loads.
- **The frontmatter allowlist applies to pack agents only.** Users' own files
  are their call.
- **The "also in this plugin" list works by exclusion,** so new plugin
  component kinds are flagged without a code change.

**Confidence**
- **Part A: high.** It builds on resolution that is already tested.
- **Part B: medium-high now.** The Ultra-Advisor reviewed the trust model
  and found the first draft wasn't enough. Its fixes are folded in:
  - the whole-tree pin (§4.5);
  - the frontmatter allowlist (§4.6);
  - `--pin` plus the commit gate (§4.4);
  - first-party gate slots and the spawn limits (§4.9);
  - `pack-ambiguous` (§4.3);
  - hidden-text checks (§4.2);
  - required stored copies (§4.5);
  - the digest check after install (§4.8);
  - honest wording on tool limits (§4.10).

  It also corrected a premise. `/ah:pipeline` never merges: it pushes
  branches and opens draft PRs, and a person merges. Every fix fails closed,
  so each holds however E3–E6 turn out.
- **What's left.** A session with Bash can still hand-edit config or stored
  copies (§4.10). A pack peer already running before a pipeline run starts is
  covered by the skill's rule, and nothing in code covers it (§4.9).

**Follow-ups (not built)**
- Rosters in packs: a manifest `rosters` key, adopted with
  `roster copy <plugin>:<roster> <name>`.
- A pack scaffold.
- `doctor` pruning stored copies that nothing pins.
- `skills:` and `memory:` in pack agents, when a real pack needs them
  (§4.6).
- An additional-reviewer slot in the pipeline, where a pack reviewer could
  run next to the first-party one (§4.9).
- A size cap or a cache for the tree hash, if E5 calls for one.
- Reading plugin enablement, if Claude Code ever exposes it in a file.
