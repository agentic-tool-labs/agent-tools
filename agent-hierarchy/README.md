# agent-hierarchy

Splits work across six roles and runs each one on a model priced for what that
role actually does. Design happens on a strong model, review on a mid one, and
legwork on Haiku, and no role spends its tokens doing a cheaper role's job.

| Role | Default model | Does | Never does |
|---|---|---|---|
| **Orchestrator** | the session itself | decomposes, dispatches, synthesizes, polices the lanes | design or implement non-trivial changes |
| **Ultra-Advisor** | `fable` | adjudicates the hardest calls | implement; run routine steps |
| **Architect** | `opus` | design reasoning; writes the spec | implement or **execute**: no tests, builds, experiments |
| **Reviewer** | `opus` | validates the diff against the spec | edit anything, or **run** anything |
| **Implementor** | `inherit` (session model) | builds exactly the spec; runs what it builds | design; fill spec gaps with its own judgment |
| **Task-Runner** | `haiku` (delegates to task-gopher when installed) | explicit-order legwork | reason or decide |

For the whole flow, the lanes, and the tiers on one page, see the visual map:
[docs/hierarchy.html](./docs/hierarchy.html)
([rendered](https://htmlpreview.github.io/?https://github.com/agentic-tool-labs/agent-tools/blob/main/agent-hierarchy/docs/hierarchy.html)).

## Install

```
/plugin marketplace add agentic-tool-labs/agent-tools
/plugin install ah@agent-tools
```

The plugin installs under the short name `ah`. Then run `/hierarchy init`
once. You can make the config user-wide (`~/.claude/agent-hierarchy.json`) or
commit it to a repo (`<repo>/.claude/agent-hierarchy.json`), and the repo file
wins. From then on a
`SessionStart` hook injects the resolved role-to-model table and the
orchestration protocol, and injects them again after compaction so they last
through long sessions. It stays silent inside subagents on purpose. The role
agents carry their own contracts in `agents/*.md`, and a worker that started
orchestrating would defeat the point.

## Where to read next

- [Getting started](./docs/getting-started.md): from nothing to a running
  team, in the order you'd do it.
- [CLI reference](./docs/cli-tools.md): the `roster.mjs` and `msg.mjs` verbs,
  how to invoke them, and permissions.
- [Troubleshooting](./docs/troubleshooting.md): symptom, cause, fix.
- [Comms protocol](./docs/comms-protocol.md): the message-file wire format and
  gates, for contributors.

## Prerequisites

Everything above runs on Node alone, with no external binary. The one optional
dependency is `herdr`, which you only need if you opt into the `herdr`
transport (`HERDR_ENV=1`) for teams of peers in panes. Without it, roster
spawning falls back to tmux, and without tmux, to plain terminal windows.
Nothing breaks; you just don't get herdr's pane placement. It's been checked
against herdr 0.8.2. See herdr's own install instructions for getting it on
your `PATH`.

## The flow

Trivial edits (a typo, a config value) skip the chain entirely. A request
that's already fully specified skips the Architect but still gets the
Reviewer. Everything else goes like this:

```
Orchestrator → Architect (spec file) → Implementor (builds it) → Reviewer
        ↑            ↑                        ↑                     |
        |            └── spec-defect ─────────┼───── impl-defect ───┘
        └── Ultra-Advisor, only when the chain can't settle it
```

The spec file is the contract. The Orchestrator picks one absolute path, every
role works against it, and it's a living document: it gets amended before the
Reviewer runs, so the review always checks the current design. The Reviewer
labels every finding as an **impl-defect** (the code is wrong, so it goes back
to the Implementor) or a **spec-defect** (the spec is wrong, so it goes back to
the Architect). After two round trips the loop goes up to the Ultra-Advisor
instead of going in circles.

## Lanes: reasoning roles never execute

The expensive roles read. They don't run things. That's enforced three ways at
once, because prose alone already failed once: a live Architect ran test
cycles because its old charter allowed "execution legwork".

Mechanically: the Architect's frontmatter denies `Bash` outright. The Reviewer
keeps `Bash`, because the diff has to be in its own context to be judged and
`git diff`, `status`, and `show` are its tools, but its contract limits it to
read-only inspection.

By contract: when the Architect's design depends on an empirical result, it
writes a **NEEDS-EVIDENCE** item into the spec (what to run, and what each
outcome would decide) and stops. For the Reviewer, "verify, don't assume"
means "have it run": every suite, build, or repro script is a required
task-gopher dispatch with an order that leaves no decisions open, judged from
the short report that comes back.

By the Orchestrator: item 11 of its protocol makes keeping the lanes its job.
It dispatches the Architect with design questions only (never "and verify it
works"), sends NEEDS-EVIDENCE legwork to the Implementor at implementation
rates, and when a role's report shows it did another role's work, rejects that
part and sends it to the right role.

All four reasoning roles also deny the harness's generic `advisor` tool. The
hierarchy's escalation path goes through the Orchestrator to the
Ultra-Advisor, and a sideways `advisor` call often lands on the same model the
role is already running: a second opinion from yourself, at full price.

## Handoffs: automatic or confirmed

You choose who moves the chain forward. It's stored as `handoffs` in the
config:

- **`auto`** (the default): the Orchestrator does the handoffs itself and
  reports.
- **`confirm`**: before every dispatch to a reasoning role (review-loop
  re-dispatches included), it asks you first, naming the role, the model, and
  what's being handed off. If that role has a peer configured (see below) and
  the peer is listed, your options are **Task peer / Dispatch subagent / Do it
  inline / Skip**. Otherwise they're **Dispatch / Do it inline / Skip**. If you
  skip, it has to tell you what goes undesigned or unchecked. Legwork
  dispatches are never gated; errands aren't handoffs.

You can switch at any time, either way, in plain words ("ask me before
handoffs", "stop asking") or with `/hierarchy flow auto|confirm`. The
Orchestrator updates the config and follows the new mode straight away, with
no restart.

## The escalation gate: you approve the Ultra-Advisor

The Ultra-Advisor is the top of the hierarchy and its most expensive tier, and
"escalate to the best model" is exactly the call an Orchestrator is worst
placed to make about its own work. So it doesn't get to decide alone. A
`PreToolUse` hook denies the first Ultra-Advisor dispatch of every session and
hands back the question to put to you. You answer once:

- **Yes, rest of session**: escalate now and every later time, with no more
  prompts.
- **Ask me each time**: escalate now; each later escalation asks again.
- **No, not this session**: escalation is blocked. The Orchestrator settles the
  question with the Architect or inline, and tells you what that leaves
  unadjudicated.

The answer only lasts for the session. It's stored in
`~/.claude/agent-hierarchy.gate.json`, keyed by session, never in
`agent-hierarchy.json`, so a new session always asks again. A standing "yes"
that outlived the session it was given in would turn a consent gate into a
one-time formality, which is exactly what this is built to avoid.

The gate watches both ways of reaching the role: an `Agent`/`Task` dispatch
matched by `subagent_type`, and a `SendMessage` whose `to` names the
Ultra-Advisor's peer session. Tasking the peer instead of spawning a subagent
can't get around your approval. Everything else passes untouched, including a
`SendMessage` to any other peer, and the gate does nothing while the hierarchy
is disabled. In `confirm` mode the gate's question replaces the normal handoff
confirmation for that dispatch, so you're asked once, not twice.

Change it any time in plain words ("don't use the ultra advisor", "go ahead
and escalate whenever") or with
`/hierarchy gate [status|session|each|off|reset]`.

## Usage tracking that costs no tokens

A `SubagentStop` hook adds up each finished subagent's transcript (token counts
the harness already logged) into `~/.claude/agent-hierarchy.usage.jsonl`. It's
plain Node reading local files. No model is ever asked to count or report its
own usage.

```
SESSION 4eff7610 (latest with subagent activity)
  role           agents  calls       out        in  cache-read
  orchestrator        1    777      1.4M      1.6k      152.0M
  task-runner        30    428     72.8k      3.7k        4.7M
  other               3     28      8.4k       352      645.5k

LAST 7 DAYS — output tokens by role
  orchestrator  ████████████████████████ 1.4M
  task-runner   █                        72.8k
```

`/hierarchy usage [day|week|month|all]` shows it (the only token cost is the
printed report entering context), or you can run it for free in any terminal:

```
node <repo>/agent-hierarchy/hooks/usage-report.mjs [day|week|month|all] [--json]
```

Roles are worked out at report time from each record's raw `agent_type`.
Main-session transcripts are scanned incrementally with a byte-offset cache,
so closed sessions never get parsed twice. Fresh input and cache reads are
separate columns. A cache-read token is about 10× cheaper, and lumping them
together would make the numbers meaningless. If the report says
`(N transcripts not found)`, the collector's path logic broke. That's a bug to
report, not something you did wrong.

## Durable agents (retired)

Durable agents were an experiment in keeping a role's Claude Code session
alive in a tmux pane between sends. Repeated work for the same role could then
skip the subagent cold start (reading the whole spec again, re-sending the
whole briefing, starting with no prompt cache) every time. The economics held
up. The setup didn't. It only ever worked on macOS with iTerm2, and driving a
terminal emulator to type into a live session turned out to be a fragile way
to solve what's really a headless-server problem. Session ids rotate, relays
break on `/clear`, and every fix bought another edge case.

The feature has been removed. herdr's headless server is the direction being
explored instead. The design specs and the incident report from the
experiment are kept in `docs/retired/` for reference.

## Peer or subagent, set per role

The harness has a built-in way to reach another running session: `ListAgents`
to see it and `SendMessage` to give it a task. That's the headless mechanism
the durable-agents experiment was reaching for. For each of Ultra-Advisor,
Architect, Reviewer, and Implementor, `/hierarchy init` asks you for an
explicit **`dispatch`** route, stored per role in the config:

- **`"peer"`** is the recommended default, and it's also what every config
  written before this option existed already did. The Orchestrator checks
  `ListAgents` for that role's peer session and sends it a `SendMessage`
  instead of spawning a fresh subagent. If the peer isn't listed, it spawns
  one (`roster.mjs spawn-one` or `spawn-ad-hoc`), and it never falls back to a
  subagent unless you opt in. That avoids the same cold-start and re-briefing
  cost the pane experiment was going after, without a terminal in the loop.
  The peer's name is either the `<repo>-<role>` convention (for example
  `agent-hierarchy-architect`) or a name you pick or type during `init`,
  stored as the role's `"peer"` config value.
- **`"model"`** always spawns a fresh subagent for that role. It never routes
  to a peer, even when one with a matching name is running.

`/hierarchy init` offers both up front. You can pick from the peers currently
running (ranked with the most likely name match first) or type a name
directly, instead of always getting the convention name.

The Ultra-Advisor's peer route has the same approval gate as its subagent
route (see [the escalation gate](#the-escalation-gate-you-approve-the-ultra-advisor)).
The `PreToolUse` hook watches `SendMessage` calls addressed to the
Ultra-Advisor's named peer, not just `Agent`/`Task`, so going through a peer
can't skip your approval. Task-Runner has no `dispatch` setting. It's always a
subagent, with task-gopher as its fast path.

### A peer has to report back, so the brief makes it

A subagent's report is built in: its final text goes back to whatever
dispatched it, automatically. A peer's report is voluntary. It only exists if
the peer chooses to `SendMessage` it back, and a peer that finishes the work
and goes idle without doing that strands whoever gave it the task. Nothing
else notices or nudges it.

So every peer brief opens with one machine-readable line, the sentinel:

```
[hierarchy-peer-brief reply-to="sender" task="<short-slug>"]
```

`reply-to="sender"` is the normal case. A delivered peer message always
arrives wrapped as `<cross-session-message from="uds:/..." from-name="...">`,
and copying that `from` into the reply's `to` is the reliable route back. The
sender often can't be found through the peer's own `ListAgents`, so the reply
address really comes from the envelope, not the sentinel. Only write an
explicit `reply-to="<name> [ref]"` when you want the report to go to a third
session. `task` is a short slug that tells apart several briefs sent to the
same peer and gives the reply a subject line.

The injected directive requires every peer brief to open with the sentinel,
and to carry the same self-contained brief a subagent would get, since the
peer shares none of the caller's context. It has to end with an explicit order
to report back, naming the exact report expected and saying plainly that the
task isn't complete until that report is sent. And if no reply comes and
`ListAgents` shows the peer idle, the caller pings it once, then tells the user
the peer stalled. It only falls back to a subagent for that role if the user
opts in.

On the peer's side, hooks enforce this rather than relying on prose. A
`UserPromptSubmit` hook records an owed reply when a brief's sentinel arrives.
A `PostToolUse` hook on `SendMessage` marks it settled once the peer sends a
reply to the recorded address. A `Stop` hook stops the peer's turn from ending
while a reply is still owed. It nudges at most twice per obligation and then
lets it go, so a broken or unanswerable brief can never trap a session. The
state lives in `~/.claude/agent-hierarchy.peer-pending.jsonl`, append-only and
scoped to the session like the rest of this plugin's state. Enforcement only
switches on for a turn delivered by a peer (a brief, a ping, or any other
wrapped message), so chatting directly with a peer you've tasked doesn't
trigger a nudge or use one up.

## Message files, roster, tier rule

Three mechanisms, added in 0.29.0, move traffic between agents out of context
windows and into files, and stop two dispatch mistakes that quietly cost a lot.

**Message files.** Every role dispatch travels as a request file and every
report as a response file, in the hierarchy's runtime directory
(`<git root>/.claude/hierarchy/msgs/`, or `~/.claude/hierarchy/<repo>/`
outside a repo; `AGENT_HIERARCHY_DIR` overrides both, and the directory
gitignores itself). `hooks/msg.mjs new` is the only way to create one. It
writes flat frontmatter (`id`, `type`, `to`/`from`, optional
`to_name`/`from_name`, `parent`, `reason`) and a fixed `## [N] key` skeleton.
Requests have tldr, goal, context, constraints, files, acceptance, and
want_back sections. Responses have tldr, status, changes, evidence, gaps, and
open_questions. Only a pointer travels in the message itself:
`[hierarchy-msg <abs path>]`. A `PreToolUse` gate denies a role dispatch
(`Agent`/`Task`, or a `SendMessage` peer brief) whose text has no valid
pointer. A `SubagentStop` gate blocks, once, a role subagent whose final
message is missing the matching response pointer. The peer report-back
tracker wants the same pointer in a peer's reply. The catch is the token math:
this only saves context when readers index the file (`grep -n '^## \['`) and
read sections selectively. A role that reads the whole file pays what inline
text would have cost, plus the cost of writing the file. `msgs: "off"` in the
config turns the whole protocol off.

**Peer roster.** `peers.jsonl` in the same directory is the source of truth for
which peer sessions exist. Peer sessions' `SessionStart` and `SessionEnd`
hooks write `up` and `down` records with the session pid (liveness is
`kill(pid, 0)`), and a `PostToolUse` hook records `seen` and `briefed` from
`ListAgents` output and sent briefs (anything from the last 30 minutes counts
as live). A role can have several instances, since the config's `peer` accepts
an array, and open briefs are split per instance by `to_name` (briefs with no
assignee count against every instance).

**Routing preference.** When `ah` dispatches a role that can be a peer
(Architect, Ultra-Advisor, Reviewer, Implementor), it's always a peer unless
the user has opted in to subagents. The default route, `peers`, is a wall, not a reminder:
every `Agent` spawn of those roles is denied, and the denial is the whole
instruction. Either `SendMessage` the live peer (it's named), or run the exact
`spawn-one` command (for a roster member whose `onMissing` is `auto` or unset)
or `spawn-ad-hoc` command (no roster member), then `SendMessage` the name it
prints. Only a roster member with an explicit `onMissing: "prompt"` asks once,
offering to spawn the peer first. The opt-ins all belong to the user:
`msg.mjs route subagents --session <id>` (or `prefer-peers`: a peer when one is
live and free, otherwise a subagent), a `route` key in the config, a
user-written `dispatch: "model"`, or a roster member with `route: "subagent"`
or `onMissing: "never"`. `route peers` takes back a session opt-in. Under
`subagents`, a `SendMessage` peer brief is denied once. Role sessions and
subagents never dispatch these roles at all; they send the need back to the
Orchestrator as `NEEDS-<ROLE>`. Task-Runner and task-gopher are exempt, since
errands aren't roster dispatches.

**Tier rule.** Dispatching an advisor role (Architect, Ultra-Advisor) at or
below the session's own model tier (haiku < sonnet < opus < fable) is
consulting yourself at twice the cost, so the gate denies it, once, unless the
request file's `reason:` explains why (`context`, `second-opinion`,
`parallel`).

One limit across repos: peers in different repos resolve different hierarchy
directories, so they share no roster or messages. If you need them joined,
point `AGENT_HIERARCHY_DIR` at the same directory in both sessions.

**Checked payloads.** These were checked against Claude Code v2.1.233 while
building 0.29.0, and haven't been re-checked since. `SessionStart` and
`PreToolUse` hook input carries no `model` field and there's no `CLAUDE_MODEL`
env var, so the tier gate does nothing unless the model comes in on the
dispatch, from the environment, or from a cached record; the directive uses
the "model unknown" wording. `SubagentStop` does carry
`last_assistant_message` and `agent_transcript_path` (a fixture is committed
under `tests/fixtures/`), which is what the response gate reads. In every hook,
`process.ppid` equals the `CLAUDE_PID` env var and is the live Claude session
process, so roster liveness checks that pid. `SessionEnd` payloads carry no
`agent_type`, so a peer's `down` record is matched to its earlier `up` by
`session_id`.

## Internals (for contributors)

The message-file wire format, the dispatch and response gates, the peer
roster, and routing preference are documented in
[docs/comms-protocol.md](./docs/comms-protocol.md) rather than repeated here.
Terms like Roster, Team, Route, Auto-mode, and Check-in registry are defined in
[CONTEXT.md](./CONTEXT.md). Each feature's design reasoning lives in its spec
under [docs/specs/](./docs/specs/). Good places to start:
[0001](./docs/specs/0001-agent-roster.md) (roster),
[0013](./docs/specs/0013-agent-hierarchy-mcp-server.md) (MCP server),
[0026](./docs/specs/0026-downstream-dispatch-visibility-and-orchestrator-only-route-gate.md) (route gate),
[0028](./docs/specs/0028-orchestrator-conduit-and-liveness.md) (conduit and liveness).

## What's new

- **0.106.0** named rosters: several rosters side by side, pick one per repo, machine or session.
- **0.107.0** role packs: roles shipped in a plugin, adopted one at a time behind a pin.
- **0.108.0** several owned teams: one session can own more than one team, and one sentence can create them.

The installed version is in `.claude-plugin/plugin.json`. Each feature below
is complete enough to use; the linked page has the detail.

## Named rosters

A roster is the list of members a team is built from. Until now there was one
per level; now a level can hold several, as `rosters.<name>` blocks beside the
default one. Commands that read or edit a roster use the first of `--roster
<name>`, the `AH_ROSTER` environment variable, the `activeRoster` config key,
then the default block. A running team keeps the roster it was built from.

```
/agent-roster copy default docs     # new roster "docs", starting from the default
/agent-roster use docs              # later teams you create use it (this repo, just you)
/agent-roster list                  # what exists, where, and which is selected
AH_ROSTER=docs claude               # or: one session only
```

`use docs --level repo` shares the choice with the repo, `--level global` makes
it machine-wide; `use default` goes back. More, including names and deleting:
[docs/getting-started.md](./docs/getting-started.md#named-rosters).

## Role packs: roles from someone else's plugin

A role pack is an ordinary Claude Code plugin that also has an `ah-roles.json`.
You install it with Claude Code, but nothing in it routes, dispatches or
spawns until you adopt a role: you review its dry run (fields, tools, what else
the plugin carries) and approve a pin in Claude Code's own prompt. The pin
covers the whole plugin, so any change, even a plain `claude plugin update`,
makes its roles unavailable until you review and trust them again. A pack role
never runs with permission checks off, and in `/pipeline` runs it may implement
but never review.

```
/agent-role install owner/my-pack   # shows the roles and everything else the plugin carries, then installs
/agent-role adopt                   # dry run, then commit with the pin it prints
/agent-role trust my-role           # after an update: review the change, re-pin
```

Nothing is trusted on your say-so in a subagent, peer or pipeline session; the
approval is yours, in your own session. Writing a pack, the trust model and its
limits: [docs/custom-roles.md](./docs/custom-roles.md#6-role-packs).

## Several teams in one session

A session can own more than one team. Ask for them in a sentence, and the
Orchestrator asks only what you left out (a name, a roster, a model):

```
create team foo from roster x and team bar from roster y
```

Afterwards, say which team you mean: `disband foo`. A member's name already
says its team: `dismiss bar-reviewer`. The session's start-up note lists the
teams you own, and a command about a whole team (`disband`, `untrack --all`)
needs `--team foo` when you own several. More:
[docs/getting-started.md](./docs/getting-started.md#5-spawning-a-team),
[docs/troubleshooting.md](./docs/troubleshooting.md#several-owned-teams).

## Commands

```
/hierarchy init                     # wizard: scope, flow mode, model per role
/hierarchy status                   # resolved table + where each value came from
/hierarchy flow [auto|confirm]      # who advances the chain
/hierarchy gate [status|session|each|off|reset]   # Ultra-Advisor escalation gate (this session)
/hierarchy usage [day|week|month|all]   # per-role token report
/hierarchy msgs [open|closed|all]   # list message-file exchanges
/hierarchy msgs off|required        # toggle the message-file protocol
/hierarchy peers                    # live peer roster
/hierarchy sweep [days]             # archive old closed exchanges
/hierarchy on | off                 # toggle without losing the config
/agent-roster [show|init|add|edit|remove|list|copy|delete|use]   # define the roster, or keep several and pick one
/agent-team [create [auto|manual]|spawn-one <role>|spawn-ad-hoc <role>|dismiss <name>|disband|untrack|teams|resync|move|adopt|reap|history]   # stand up, reshape, or tear down a live team
/agent-role [list|add|edit|remove|check|install|update|uninstall|adopt|trust] [name]   # define your own roles, or take them from a role pack
/pipeline <plan-or-spec-path> [--branch <name>]   # run a plan to completion on its own
```

`/agent-role` is for roles of your own, like a ui-implementor or a custom
reviewer. It adds, edits, or removes a custom role and its agent file, `list`
shows which roles exist, and `check` looks for problems with your roles (or
one role) and walks you through fixing them. Putting a new role on the roster
afterwards is `/agent-roster`, and starting it in a live team is `/agent-team`.

`/pipeline` takes a plan, a spec, or a list of acceptance criteria and runs it
to completion by itself: round after round of Architect, Implementor, and
Reviewer, with a hard cap on escalations and as few check-ins with you as it
can manage.

Which roles exist, and their model, effort, and route, is `/agent-roster`'s
job, not `/hierarchy`'s. `/hierarchy set <role> <model>` was replaced by
`/agent-roster edit --member <name> --model <model>`. See
[docs/getting-started.md](./docs/getting-started.md).

Which models are valid depends on the role. `haiku` is never valid for a
reasoning role, and the Ultra-Advisor has to be top tier (`fable` or `opus`),
since inheriting a weaker session model would make the tier meaningless.
`inherit` means "leave the `model` parameter off the `Agent` call"; it's never
passed literally.

## Layout

A per-file list here would go stale the moment someone adds a hook, so the
directory itself is the file list. Roughly:

```
agents/          one contract per role (frontmatter pins model + tool denies)
hooks/           hooks and the libraries they share
commands/        the /hierarchy and /pipeline commands
skills/          agent-roster, agent-team, agent-role, autonomous-pipeline
docs/specs/      per-feature design records
tests/           HOME-redirected; real config untouched
```

## License

Apache-2.0. See [LICENSE](../LICENSE).
