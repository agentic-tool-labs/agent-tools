# Getting started

Zero to a running team, in the order you'll actually do it.

## 1. Prerequisites

Node only; `herdr` is optional — see
[README.md#prerequisites](../README.md#prerequisites) for the fallback chain.

## 2. Install

```
/plugin marketplace add agentic-tool-labs/agent-tools
/plugin install ah@agent-tools
```

`ah` is the plugin's short name (`agent-hierarchy` is the directory it ships
from — see the root [marketplace.json](../../.claude-plugin/marketplace.json)).

## 3. `/hierarchy init`

Run `/hierarchy init` once. The wizard turns the hierarchy on and sets its
handoff flow (`auto` or `confirm`), at either user scope
(`~/.claude/agent-hierarchy.json`) or project scope
(`<repo>/.claude/agent-hierarchy.json`, committable).

**The one thing every new user gets wrong:** `/hierarchy init` does **not**
define who's on the roster or what model they run. That's a separate step —
`/agent-roster` — and `/hierarchy init` hands off into it automatically when
no roster exists yet.

## 4. Defining a roster

`/agent-roster init` sets the roster's route (peer or subagent) and layout,
then `/agent-roster add` adds a member per role. Each member has these keys:

- `kind` — which agent CLI Herdr starts for this member. Omitted means
  `claude`, and that stays true for every roster written before this key
  existed. Any other value (`codex`, `pi`, … — Herdr owns the list; run
  `herdr agent` to see what your install has) makes the member a *non-Claude*
  agent, which changes the keys below.
- `model` — which model that role runs on. For a non-Claude kind with a model
  mapping (today: codex) it is that harness's model name, e.g.
  `{ "role": "architect", "kind": "codex", "model": "gpt-6-astra", "route": "pane" }`;
  any other non-Claude kind takes its model flag in `args`.
- `effort` — reasoning effort, where the model supports it. **`kind: claude` only.**
- `route` — `peer` (a separate live session, reached with SendMessage),
  `subagent` (spawned in-process by the Agent tool), or `pane` (driven through
  its Herdr pane). A non-claude kind **must** be `pane`.
- `auto_mode` — the spawned session's permission mode. `auto`
  (`--permission-mode auto`) is the hands-off mode. `bypassPermissions` is
  still accepted, but that session can get stuck at a startup confirmation
  screen instead of coming up ready — prefer `auto`. For `kind: codex` the
  mode is translated into codex's own vocabulary — a `--sandbox` policy plus
  an `--ask-for-approval` policy, or `--dangerously-bypass-approvals-and-sandbox`
  for `bypassPermissions` — and emitted after `--` ahead of `args`, so an
  explicit native flag in `args` overrides it.
- `args` — native CLI arguments passed verbatim to the agent. **Non-claude
  kinds only** — for a Claude member, `model`/`effort`/`auto_mode` are the
  validated way to set flags, and `args` would bypass that validation.

`effort` is literally a Claude Code CLI flag (`--effort`), which is why it is
*rejected* rather than ignored for another kind, as `model` is for a kind with
no model mapping: a setting that silently affects nothing is worse than one
that refuses.
`auto_mode` is the exception — permission policy exists in the other CLI's
vocabulary too, so it is translated for a kind that has a mapping (today:
codex) and still rejected for one that does not.

A non-claude member requires a Herdr session (`HERDR_ENV=1`) to spawn — tmux
and terminal transports can only start `claude`. It is briefed with
`roster.mjs deliver`, never SendMessage, and reports only through its response
file. Adding one from a non-Herdr
session still works (rosters are portable); only spawning it needs Herdr.

Your own roles, and members that run in Codex, are covered in
[custom-roles.md](./custom-roles.md).

Value spaces and validation rules are in
[SKILL.md — Levels](../skills/agent-roster/SKILL.md#levels) and
[SKILL.md — `add` / `edit` / `remove`](../skills/agent-roster/SKILL.md#add--edit--remove).

### Named rosters

A config level can hold more than one roster: named rosters are
`rosters.<name>` blocks beside the default `roster` block — a `game-dev` team
and a `docs` team in one repo, say. `/agent-roster list` shows them, `copy`
makes one from another, and `delete` removes one no team uses.

Commands that read or edit a roster (`show`, `init`, `add`, `edit`, `remove`,
and `create` when it builds a team) use the first of:

1. `--roster <name>` on the command;
2. the `AH_ROSTER` environment variable, when set and not empty;
3. `activeRoster`, a config key: the repo-user level wins over repo, and repo
   over global;
4. the default `roster` block.

`default` names the default block in each of these, so a narrower level or a
single session can undo a wider choice. `AH_ROSTER=default` gives one session
the default block in a repo whose `activeRoster` is `game-dev`.

- **One repo, just you:** `/agent-roster use game-dev` writes `activeRoster`
  to your own file for the repo (repo-user).
- **One repo, everyone:** `use game-dev --level repo`, in the committed file.
- **This machine:** `use game-dev --level global`.
- **One session:** start it with `AH_ROSTER=game-dev`.

A running team keeps the roster it was built from; changing the selection
affects only teams created later.

Different rosters for different workloads is the use: a lean one for routine
fixes, a fuller one for a feature.

    /agent-roster init repo-user --route peer --roster docs    # an empty `docs` roster
    /agent-roster add repo-user --roster docs --role implementor   # …then fill it
    /agent-roster copy default game-dev                        # or start from the default block
    /agent-roster use game-dev                                 # build the next team from it
    /agent-roster list                                         # what exists, where, and which is selected

A name is 1–32 letters, digits or `-`, starting with a letter or digit;
`default` is reserved for the unnamed block, so it can't be created, copied
to or deleted. `delete` refuses a roster a live team was built from: disband
the team first. `--team` names a live team, never a roster; to build a team
from `rosters.docs`, pass `--roster docs` to `create`.

If the selection names a roster no level defines, commands exit 2 with the
roster's source and the fixes; hooks fall back to the default block and warn;
`doctor` shows a red `roster-selection` row. See
[troubleshooting.md](./troubleshooting.md#named-rosters). Roles other people
publish come separately, as [role packs](./custom-roles.md#6-role-packs).

## 5. Spawning a team

`/agent-roster create` spawns the resolved roster as a live **Team** — a
Roster is the definition, a Team is the running instantiation of it (see
[CONTEXT.md](../CONTEXT.md) for the exact distinction). Layout confirmation
is asked every time, `auto` or `manual` alike — `auto` only skips the
per-member placement prompt; `manual` walks you through each member's
placement individually.

**Several teams.** One request can build more than one team: "create team foo
from roster foo-named-roster and create team bar from roster bar-named-roster".
The Orchestrator asks only what the request doesn't already say. Afterwards,
name the team when you ask for something ("disband foo"); a member's name
already says its team ("dismiss bar-reviewer").

Phrasings it reads without asking:

- "create team foo from roster x and team bar from roster y": foo from x, bar
  from y.
- "a team for each of x and y": each team takes its roster's name.
- "create teams foo and bar, both from x": both use x.
- "create team docs": the selected roster, as for one team.

What it does ask, once for everyone: a name you didn't give, a roster that
can't be worked out, a member with no model, each question naming its team.
It plans every team, asks, then launches, checks in and commits team by team;
one team failing doesn't undo the others, and it asks once whether to retry.
You end up owning every team it built.

Owning several teams changes how you address them. A command that names a
member (`dismiss bar-reviewer`, `move foo-architect …`) finds the team from
the name. A command about a whole team (`disband`, `untrack --all`, the
stream commands) needs `--team foo`; without it the command refuses and lists
the teams you own, and in conversation the Orchestrator asks which you mean.
Messages follow the same rule: `msg.mjs new` takes the team from `--to-name`,
and `msg.mjs list` shows every owned team with a `team` on each row. The
session's start-up note says which teams you own; the legacy default team, if
you have one, is `@default` (`--team @default`). A team is yours by the pid of
the session that created it, so a session you resume owns none of its teams
until it re-claims each with `roster.mjs adopt --orchestrator-pid <pid> --team
<name>`. Details:
[cli-tools.md](./cli-tools.md); when it goes wrong,
[troubleshooting.md](./troubleshooting.md#several-owned-teams).

## 6. The first dispatch

This is the part that makes the model click. Say the Orchestrator (your
session) needs a design for a new feature:

1. The Orchestrator dispatches the **Architect** with the problem and
   constraints. The Architect writes a spec file and stops — it never
   implements.
2. The Orchestrator dispatches the **Implementor** with the spec's absolute
   path. The Implementor builds exactly what the spec says.
3. The Orchestrator dispatches the **Reviewer** with the spec path and the
   diff. The Reviewer validates it and labels any finding **impl-defect**
   (back to the Implementor) or **spec-defect** (back to the Architect).

Every one of those dispatches carries a message-file pointer, not inline
prose — you'll see a line like this in your terminal:

```
[hierarchy-msg /path/to/.claude/hierarchy/msgs/20260826-101500-a1b2--architect--new-feature--request.md]
```

That's normal: it's the brief, written to a file so it survives compaction
and re-dispatch. You write one with the message CLI:

```
node <AH_ROOT>/hooks/msg.mjs new --to architect --from orchestrator --slug new-feature --cwd "$(pwd)"
```

`<AH_ROOT>` comes from the `ah CLI root:` line the plugin injects at session
start. See [docs/cli-tools.md](./cli-tools.md) and
[docs/comms-protocol.md](./comms-protocol.md) for the format.

## 7. Tearing down

Bare `roster.mjs disband` is **read-only** — it's just the plan step,
showing what would close. `/agent-team disband` runs the whole contract
(plan → confirm → close) and **will close sessions** once you confirm — see
[SKILL.md — `disband`](../skills/agent-team/SKILL.md#disband) for the full
sequence.

Use `roster.mjs untrack --all --keep-sessions --commit` when you just want the
bookkeeping cleared and the sessions left running — a single, non-destructive
call that removes `team.json` and closes nothing, for when those sessions hold
work worth keeping.

## 8. Where to go next

- [docs/cli-tools.md](./cli-tools.md) — the `roster.mjs` / `msg.mjs` verb
  surface, the invocation form, and permissions.
- [docs/troubleshooting.md](./troubleshooting.md) — symptom → cause → fix.
- [README.md](../README.md) — the full picture: roles, lanes, gates, usage
  tracking.
