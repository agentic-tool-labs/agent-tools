# Troubleshooting

Start here, whatever the symptom:

```
node <AH_ROOT>/hooks/roster.mjs doctor --cwd <abs cwd>
```

One read-only JSON object, one row per thing that can be wrong — version and
running root, install path, `CLAUDE_PID`, runtime dir, resolved config, team,
peers, hook errors in the last 24 h, hook syntax, and whether the checkout the
hooks run from is dirty. `--check` exits 1 when any row is red. `<AH_ROOT>` is
on this session's `ah CLI root` line; with no such line, resolve it with the
recipe in [cli-tools.md](./cli-tools.md).

Then: symptom → likely cause → what to run.

| Symptom | Likely cause | What to run |
|---|---|---|
| Anything at all, and you want one place to look first | — | `roster.mjs doctor --cwd <abs cwd>` (above); `--check` for a pass/fail exit |
| A hook seems to do nothing | a hook threw; Claude Code reports that only under `--debug` | the `hook-errors` row of `doctor`, or read `~/.claude/hierarchy/hook-errors.jsonl` |
| Team is gone after a reboot | by design: the team file is cleared once its orchestrator pid is dead | recreate the team through the `ah:agent-team` skill |
| A permission prompt appears for `node …/hooks/roster.mjs` | the plugin's allow hook is not running, or the path is not the installed one — see below | print the session's `ah CLI root:` line and compare it with the path you ran |
| Peer is offline / a dispatch says no live peer | `peers.jsonl` liveness check (`kill(pid, 0)`) shows the peer as down or stale | `/hierarchy peers` to see the roster; `roster.mjs spawn-one <role>` to respawn just that role |
| Roster looks stale or the wrong members appear | Whole-level replace — a higher-precedence level is winning entirely, not merging. Precedence and resolution order are in [SKILL.md — Levels](../skills/agent-roster/SKILL.md#levels) | `roster.mjs show --level <level>` to inspect each level; `roster.mjs resync` to re-derive live topology |
| Team orphaned after the orchestrator session died | `team.json`'s `orchestrator.pid` points at a dead process | `roster.mjs adopt --orchestrator-pid <pid>` — recovery only, refuses to hijack a still-live team |
| Two checkouts / a worktree see different rosters | Worktree roster resolution — see [spec 0027](./specs/0027-worktree-roster-resolution.md) | Point `AGENT_HIERARCHY_DIR` at the same directory in both checkouts if you want them joined |
| Peers in different repos share no messages | Cross-repo limitation, documented in [README.md](../README.md) — different repos resolve different hierarchy dirs | Set `AGENT_HIERARCHY_DIR` to the same path in both sessions |
| A dispatch is denied for a missing `[hierarchy-msg]` pointer | The dispatch/response gate requires a message-file pointer in-band | Follow the deny text's `msg.mjs new` instructions — see [docs/comms-protocol.md](./comms-protocol.md) §5/§6 |
| Tier gate denies a dispatch | Dispatching Architect or Ultra-Advisor at or below your own model's tier | Do it inline, or set `reason: context\|second-opinion\|parallel` in the request file and re-issue |
| A command says `this session owns N live teams (…) — pass --team <name> to say which` | you own several teams and the verb doesn't name a member | [Several owned teams](#several-owned-teams) below |
| A command says `… selects roster "<name>", but there is no rosters.<name> block at any level` | `--roster`, `AH_ROSTER` or `activeRoster` names a roster no level defines | [Named rosters](#named-rosters) below |
| A custom or pack role is missing from routing, or `role list` shows `UNAVAILABLE` with a `pack-…` reason | the pack changed, went missing, or was never trusted on this machine | [Role packs](#role-packs) below |
| A response is denied with "not in its request's directory" or "outside this session's message pool" | the response file is not beside the request it answers | [Response pointers](#response-pointers) below |
| Usage report shows nothing, or looks smaller than expected | **Known limitation:** usage collection is `SubagentStop`-driven (`hooks/subagentstop-usage.mjs` requires an `agent_id`, i.e. a subagent). A **peer** is a separate top-level session, not a subagent, and never fires this hook — its token usage is not captured by `/hierarchy usage` at all | No workaround in this plugin; peer-routed work's token cost has to be read from that peer session directly |

## The ah CLI

Every ah operation is `node <AH_ROOT>/hooks/roster.mjs <verb> --cwd <abs cwd>` or the same with
`msg.mjs` — see [docs/cli-tools.md](./cli-tools.md). There is no server to be disconnected as of
0.73.0 (spec 0048): a call either runs or prints node's own error in the Bash output.

**"I get a permission prompt for `node …/hooks/roster.mjs`."** The plugin's PreToolUse allow hook
(`hooks/pretooluse-ah-cli.mjs`) did not recognise the call. Either plugin hooks are disabled in this
session, or the path is not the installed root (or a sibling of it) — a copy under `/tmp`, or your
own checkout while the installed plugin lives in the cache. Print the session's `ah CLI root:` line
and run that exact path. A command with a `cd … &&` prefix, a pipe, a `$VAR` or a redirection is
also not recognised, by design. If you run without plugin hooks, use the settings allowlist in
[docs/cli-tools.md](./cli-tools.md#permission). A `dismiss`/`disband … --close` command always
prompts — that one is the close gate, and it is meant to.

**"`no orchestrator pid resolvable (CLAUDE_PID unset …)`."** The call is not running inside a Claude
Code Bash tool (a plain terminal, a CI job, a wrapper that strips the environment). Pass
`--orchestrator-pid <pid>` explicitly.

**"`Cannot find module …/hooks/roster.mjs`."** The version directory your context names was removed
by an update. Old and new version dirs normally coexist, so the old CLI keeps working until the
session ends; when it does not, start a new session and use the `ah CLI root:` line it prints.

## Several owned teams

What it is and how to ask for it: [getting-started.md](./getting-started.md#5-spawning-a-team)
("Several teams"); the rules per verb are in [cli-tools.md](./cli-tools.md).

**"`<verb>: this session owns N live teams ("bar", "foo") — pass --team <name> to say which`."**
You own more than one team and the verb acts on one whole team, or names no member. Add `--team
foo`. A name after it, as in `… "x" is a member of none of them`, means the member you named is in
none of your teams' files (a name not yet recorded, a pane id and a session id never match), or
`is a member of more than one of them`; name the team too. `msg.mjs new` says the same for a
recipient it can't place; it writes nothing, so re-run it with `--team` or with `--to-name` set
to a member's name.

**The legacy default team can't be named.** A `team.json` team counts as owned and shows as
`default`, but there is no `--team` spelling for it. With several teams owned, reach it by a
member's name, or disband or untrack the named teams first.

**A team I created isn't listed as mine, or a resumed session owns nothing.** Ownership is the
creating session's pid (`--orchestrator-pid`, else `CLAUDE_PID`), or a session id the team file
records, which `create --commit --session <id>` writes; a new pid with no recorded session id
owns nothing. `roster.mjs teams` lists every team file, with `own` true when the pid matches;
`adopt --orchestrator-pid <pid>` takes over an orphaned team.

**The route gate tells me to `spawn-one` without `--team`.** With several teams owned and no
live peer of the role anywhere, the gate's "no live Architect peer" text names a bare
`spawn-one <role>`, and `roster.mjs` refuses that for the reason above. Add `--team <name>` for
the team that should get the member. When a live peer exists the gate instead names each one,
`bar-architect (team bar), foo-architect (team foo)`: SendMessage the one whose team owns the
work.

**Which teams do I own?** The session's start-up note leads with `You own N live teams: …`, as
does `/hierarchy status`; `roster.mjs doctor` lists each owned team with its roster, and a
selected roster that doesn't exist is a red `roster-selection` row naming the team.

## Named rosters

Selection order, and the verbs that change it, are in
[getting-started.md](./getting-started.md#named-rosters) and
[cli-tools.md](./cli-tools.md) (“Which roster a command uses”).

**"`… selects roster "<name>", but there is no rosters.<name> block at any level`."** The
message names where the selection came from (`--roster`, `AH_ROSTER`, or `activeRoster at
<level> in <path>`) and lists the rosters that are defined. `show`, `add`, `edit`, `remove` and
`create` exit 2 on it; `init` does not, because it creates the roster. Hooks don't fail: they use
the default block and put the message in the session's warnings, which is how you meet it with
no command of your own to blame. `doctor` reports it as a red `roster-selection` row, so
`doctor --check` exits 1. Fix it one of three ways, all named in the message:
`roster.mjs roster use default`, `roster use <other>`, or `init --roster <name>`. If it is
`AH_ROSTER`, unset the variable in that shell instead.

**"`roster delete`: … uses it — nothing was deleted."** A team file here, or in the main
checkout, records that roster. Disband the team (`roster.mjs disband`), or clear an orphaned
record with `roster.mjs reap --commit`. A running team keeps the roster it was built from
whatever you select later.

**"`roster delete`: … `activeRoster` in <path> selects it."** Select another roster first
(`roster use <other> --level <level>`) or `roster use --clear --level <level>`. A selection at a
*different* level does not refuse: the roster is deleted, and the command warns that commands
there will refuse until that selection changes.

**"`roster delete`: … is in the main checkout's file."** From a worktree, a roster that only the
main checkout's file holds at that level can't be deleted. The message gives the command: the
same `roster delete` with `--cwd` set to the main checkout.

**`roster copy` refuses the destination.** A roster can't be called `default` (that means the
unnamed `roster` block), must be 1–32 characters of letters, digits and `-` starting with a
letter or digit, and can't already exist at that level (from a worktree, in either checkout's
file). Delete it first, or pick another name.

**A `rosters.<team>` block is ignored by `create --team <team>`.** `--team` names only the team.
Pass `--roster <team>` to build from that block; `create` warns when it sees the block and you
didn't.

## Role packs

How packs work: [custom-roles.md §6](./custom-roles.md#6-role-packs). When a role adopted from a
pack is unavailable it is dropped from routing (a built-in whose agent a pack overrides
reverts to its shipped agent), and the session's start-up note lists it. `roster.mjs role list`
shows the reason as a `pack-…` code, and `roster.mjs doctor` shows a `warn` `config` row that
says the role is unavailable without naming the reason. A pack role already running as a peer
is untouched.

| Reason | Cause | Fix |
|---|---|---|
| `pack-changed` | something in the plugin changed since you trusted the role. The pin covers every file in the plugin, so a plain `claude plugin update`, even a version bump, trips it for every role adopted from that plugin | `roster.mjs role trust <role> --dry-run` to review, then commit with the pin it prints |
| `pack-untrusted-here` | the pin matches the installed plugin, but this machine holds no stored copy of what was pinned, as with a repo-level row someone else committed, or a new machine | the same `role trust` |
| `pack-missing` | the plugin isn't installed (under that marketplace), or its `ah-roles.json` doesn't offer the role. A same-named plugin from another marketplace never stands in | reinstall the pack, or `roster.mjs role remove <role>` |
| `pack-invalid` | the manifest or the role's row is unreadable or breaks the custom-role rules; the agent file is missing, not UTF-8, or holds a hidden character; or another agent file in the plugin takes the role's agent name | fix the pack and update it, or `role remove` |
| `pack-ambiguous` | two installs of the plugin differ (two marketplaces, or user and project scope), so which one Claude Code loads can't be known | uninstall all but one |
| `pack-symlink` | the plugin holds a symbolic link, which the pin can't cover | reinstall a pack without one, or `role remove` |

`role trust` only works when the pack itself reads cleanly; for `pack-missing`, `pack-invalid`,
`pack-ambiguous` and `pack-symlink` the fix is on the install side. To see what is wrong with
the pack, `roster.mjs pack show <plugin>@<marketplace>` lists every finding, and
`pack show --path <dir>` checks a pack that isn't installed.

Agent-file problems are separate findings under the `pack-agent-…` codes (`pack-agent-key` for a
frontmatter key that isn't allowed, `pack-agent-tools` for a missing or non-plain `tools` entry,
`pack-agent-line` for a line YAML would read differently, and so on), and the class contract's
`name-mismatch` when the frontmatter `name` isn't the agent's name. Each names the line and
says how to fix it; the allowed frontmatter is in
[custom-roles.md](./custom-roles.md#writing-a-pack). A hidden character is reported as
`pack-hidden-chars` with its code point, line and column, in the manifest and in the agent file.

**"`roster.mjs role set … --from`/`role trust` was denied, or asked me to approve."** By design:
adopting or trusting pack content is the user's decision, made in their own top-level session
and approved at Claude Code's own prompt. It is refused in subagent, role and peer sessions, in a
team member's session (`AH_TEAM_FILE` set), and while a pipeline run is live in the checkout; in
a permission mode where the prompt isn't known to reach you it is refused too, with the mode
named. A Bash command that isn't one plain `roster.mjs` command is judged a commit whenever its
text names `roster.mjs`, `role` and `trust` or `--from` in that order, even for `--dry-run`; run
the command on its own, with the absolute path and no `cd`, env prefix, `$VAR` or pipe.

**"A pack role `was not launched`."** Two refusals: the member's auto mode is
`bypassPermissions` or unset, so it would take your settings' default, which may be bypass (give
it one with `roster.mjs edit --member <name> --auto-mode auto`); or a pipeline run is live and
the role is a pack's reviewer or designer, which stay first-party (use the built-in for the run).

## Response pointers

A response to a request is written with `msg.mjs new --type response --id <id> --req <request
path>`, which puts it **beside the request**, in the request's own `msgs/` directory, whichever
checkout the responder's cwd is in. The pointer you then send, `[hierarchy-msg <response path>]`,
is accepted when that file is in the request's directory, in the responder's own pool, or in the
home pool of the message's team file.

**"`response file is not in its request's directory (<dir>) — write it with msg.mjs new --type
response … --req <request path>`."** The file the pointer names sits somewhere else. Don't move
the session's cwd; re-create the response with `--req` set to the request's own path and point at
that. A request's own pointer is different: a peer cwd that drifted (into a worktree, another
repo) gets "file is outside this session's message pool … the file is fine and the cwd is
wrong", and the fix there is the cwd.

The beside-request acceptance arrived in 0.107.1. Before it, a peer in the main checkout
answering an Orchestrator in a linked worktree was denied the pointer it was told to send, the
Stop hook kept nudging for it, and the obligation was logged as undelivered. If you see that
on an older install, update.

After an update, the six things no unit test can see are in
[live-checks.md](./live-checks.md) — one line each, per machine.
