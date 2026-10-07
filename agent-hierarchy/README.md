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

The [status entry](#the-status-entry-the-team-at-a-glance), and the
[band, the Pane and toasts](#the-band-the-pane-and-toasts), need Claude Code
2.1.289 or later.

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

A Reviewer needs to know what the change is meant to deliver: a review brief
states its goal and acceptance, and a dispatch without them is held until it
does. A Reviewer that finds no intent anywhere answers `NEEDS-INTENT` instead of
reviewing. A verdict covers only the range it names, so a behaviour-changing
commit made after it gets its own review of that range before it is pushed.

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

## The status entry: the team at a glance

While a team is up, `ah` shows one line above your prompt:

```
⚠ ah: 3 live · 1 out · 1 blocked
```

It counts the live members and the dispatches still out, and adds blocked
members, overdue dispatches and stalled dispatches when there are any. It shows
while something is live or out, or a `/pipeline` run is open, and stays hidden
while the hierarchy is off (`/hierarchy off`).

- **Who sees it.** Every session in the checkout except the team's members:
  the Orchestrator, plain sessions, and `--agent` sessions on no team. A
  member, including a Claude member running in a pane, sees nothing. A linked
  worktree is its own pool, so a session there shows that worktree's teams,
  not the main checkout's.
- **The `⚠ ah:` part** is drawn by Claude Code, on its own line above any
  status line. `ah` supplies only the text after it, and the `⚠` glyph is
  Claude Code's and can't be changed.
- **Read-only.** The entry is a Claude Code mod, in `mod/`. It reads
  `.claude/hierarchy/status.json` ([format](./docs/status-file.md)) and draws
  the line. It never sends a message, answers a prompt, or runs anything named
  in the file.
- **Turning it on.** The entry is off by default: the `status_entry` option is
  `false` until you set it. Turn it on with `/config`, or from a shell:

  ```
  echo '{"status_entry":"true"}' | claude plugin configure ah@agent-tools --values-stdin
  ```

  Restart Claude Code afterwards. Leave it off when claude-tui-line's `ah` item
  already shows the same counts, for example. It is a user setting: project
  and local settings files can't set it, so it applies to you in every repo.
- **"1 userConfig option not yet set".** A fresh install prints this once. It
  is informational: the default (on) still applies. An upgrade prints nothing.
- **Claude Code 2.1.289 or later.** The mod API needs it. The mod ships inside
  `ah` rather than as a separate plugin, so an older client that rejects the
  mod file is a known risk, accepted with that choice; `ah` neither detects
  nor works around it.

## The band, the Pane and toasts

The same mod shows the team in three more places, to every session that sees
the status entry. A member session sees none of them (more on that
[below](#who-sees-them)).

### The band

Whenever the hierarchy has something to show for this session (a team is live,
work is out, or a pipeline runs), whether or not the `status_entry` option shows it
in the status bar, one line sits just above the prompt and names
the thing most worth your attention. It ends with a `[ Pane ]`
button: click it, or press ctrl+x then tab and Enter, to open the hierarchy Pane,
the same as `/hierarchy-pane`. Pressing it while the Pane is open closes it
(and it stays closed for the session), which `/hierarchy-pane` never does. The
button is only there while the band is, and not on a very narrow terminal.
The band, the Pane, the status bar entry and the toasts show only the teams this
session's orchestrator owns, not other orchestrators' teams in a shared checkout.

```
architect is waiting on a prompt · answer it through the Orchestrator
```

It picks a stalled dispatch first, then an overdue one, then a blocked member,
and only then work in progress. When other stalled, overdue or blocked items
remain, it ends with `· +2 more` (for example).

| Subject | Example |
|---|---|
| stalled | `reviewer stalled on review-step · 1 check-in unanswered`; before any check-in, `· no report after 7m`; when the member has left, `· demo-reviewer is gone` |
| overdue | `architect is 1m 0s past its 5m eta`, plus `· check-in 1 sent` once one has gone out |
| blocked | `… · answer it through the Orchestrator` for a pane-driven member; `… · answer it in its pane` for a Claude member |
| working | `2 out · architect 2:30 of 10m · reviewer 0:45 of 5m`, adding each further dispatch while it fits |
| idle (nothing working, stalled, overdue or blocked) | `1 live · 0 out`, the status entry's own text, in its tone |

Stalled and overdue lines draw in the warning colour and bold, blocked in the
warning colour, and work in the default colour. The words carry the severity
too, so the line reads the same without colour. The times count up every 2
seconds, and the line is cut to the terminal's width with `…`. It steps aside
while Claude Code shows a survey above the prompt.

### The Pane and `/hierarchy-pane`

The Pane, titled **Hierarchy**, is the whole picture:

```
Hierarchy
round 2/3 · reviewer
1 decision waiting for you
Team
demo-architect · codex · pane · idle 35m
demo-reviewer · codex · pane · working 30m
Dispatches
ac-1 → reviewer | eta 20m | ██████████ 100% | 30:01 | stalled
```

- **Hierarchy:** each open `/pipeline` item with its round, and how many
  decisions are waiting for you. `No pipeline run.` when there is none.
- **Team:** one row per member: name, kind, route and what it's doing, or
  `gone` once it has left. A pane-driven member's row also says how long ago.
- **Dispatches:** newest first, each with its eta, a progress bar, the time
  since it was sent and its state. A reported dispatch stays for 10 minutes.
  `None outstanding.` when there is none.
- With more than one live team, each heading names its team (`Team
  agent-tools`).
- A narrow Pane drops the bar below 60 columns and the eta below 40. Below 28,
  a dispatch row is just its slug and state, and below 40 a member row is just
  its name and state. Long slugs and names are cut first.
- With nothing to show (no status file, the hierarchy off, nothing up) it reads
  `No hierarchy status here.`

Rows use the band's colours; idle and finished rows are dimmed.

`/hierarchy-pane` opens the Pane at any width and replies `Opened the
hierarchy Pane.` If this session's surfaces show no panes at all, it replies
`The hierarchy Pane is open, but this session shows no panes.`

- **When it opens unasked.** The first time in a session that there is
  something to show, `ah` asks for the Pane once. Claude Code places an unasked
  pane only in a terminal at least 144 columns wide. Once you have opened it
  yourself with `/hierarchy-pane`, in this session or an earlier one, 110
  columns is enough, until you next close it by hand. In a narrower terminal
  it waits, and appears if you widen the window.
- **Closing it.** Close it by hand and it stays closed for the rest of the
  session, whatever changes. `/hierarchy-pane` opens it again.

### Toasts

A short notice pops up for three things:

- a dispatch reports: `reviewer reported · p3-s6 · 6m 40s`, with the time from
  sending to report;
- a member is blocked: for a pane-driven member, the note `ah` recorded with
  the block when there is one (`architect blocked · Allow edits to
  config.toml? (y/n)`); for a Claude member at a permission prompt,
  `· waiting for permission`; otherwise `· waiting on a prompt`;
- a dispatch stalls: `reviewer stalled · review-step · 1 check-in unanswered`.

Each event toasts once per session, and a reload of the plugin doesn't repeat
it. Whatever is already there the first time a session has something to show
counts as seen and is not toasted, so a new session, or a mod first loaded
mid-session, doesn't replay old events. A member that blocks again
later toasts again. A status file that is unreadable for a moment doesn't
replay anything when it comes back.

### Who sees them

The same sessions as the status entry: the Orchestrator, plain sessions, and
`--agent` sessions on no team. A member session gets no band, no Pane opening
on its own and no toasts, and there `/hierarchy-pane` opens nothing and replies
`The hierarchy view is hidden in member sessions.`

The `status_entry` option turns on only the `⚠ ah:` line. The band, the Pane
and the toasts have no switch of their own. Like the entry, they only read the
status file: the mod opens its own Pane and shows toasts, and never sends a
message, answers a prompt, or runs anything named in the file.

The `toast_seconds` option sets how long the mod's notices (a reported dispatch,
a blocked or stalled member, the band's "not placed" note) stay on screen: 10
seconds by default, 2 to 60, and 0 turns them off. Click a notice to dismiss it;
hover over it to keep it. Click feedback for a member focus is not affected.

The mod runs nothing without a user press. Exactly one process may run: the
pinned focus helper, which a click on a team member's name triggers
(`herdr agent focus <name>`, a fixed argument list with no shell, and only for a
name that passes herdr's agent-name rule). A second exec site, or any change to
the pinned argv or init, needs a new security ruling, not a guard edit.
The guard also allows the helper exactly one caller, the click handler of the
Pane's member name, and bans every literal name that reaches a prototype.

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

### Finished work is never left unseen

Four layers, each enough on its own to surface a report that was written but
never sent. Finished work stays unseen only if all four fail.

**L1, the peer cannot go idle holding an unsent report.** A peer arms its
owed reply when a delivered brief's `[hierarchy-msg <path>]` token is the
first thing on the first line, as before, **or** appears anywhere in the
wrapped body, provided the path ends `--request.md`, exists, and its
frontmatter `to` is the receiving session's own role. The role is the one
the session started as (or the one persisted at `SessionStart`), so a quoted
brief addressed to another role arms nothing. Once armed, the existing Stop
block applies: at most twice per obligation, then released.

**L2, the Orchestrator's Stop sees every dispatch.** Each dispatch is
recorded with the request's path and the address it was sent to, so
liveness looks in that request's own message pool, not only the current
cwd's. When an exchange has a response with authored content, is at least
120 s old, and the Orchestrator never saw it arrive, the next Stop blocks
once with the response path: "the peer wrote this report but never sent it
to you; read it now". One block per request, ever.

**L3, an idle peer wakes an idle Orchestrator.** A `SendMessage` from an
Orchestrator that carries a request token must set `notify_when_idle: true`;
the first send without it is denied once with the exact fix (re-send with the
flag, or without it if the target rejects it), then passes. When the idle
notice arrives, ah injects what to do: the response path if the report landed
unsent, or "may be waiting on its own background work; the dispatch watcher
checks in at `<time>`". An unrecognised notice gets a line telling the
Orchestrator to call `ListAgents`. A repeat of the same notice is ignored.
The handler never queries the peer and never asks to re-subscribe, which
would fire again at once.

**L4, the dispatch watcher.** An idle Orchestrator also gets a timer. After
the first dispatch the Orchestrator starts one background process:

```
Bash, run_in_background: true, description: "ah dispatch watcher",
command: node "<ah root>/hooks/dispatch-watcher.mjs" --session <session id> --cwd <cwd>
```

A PostToolUse hint after the dispatch gives the exact call, and the
Orchestrator's Stop blocks once per latest dispatch if none is running. One
process per session; a second start exits at once ("already running"). It
polls every 15 s and exits with code 3 to wake the session, when:

- **LANDED:** a response was written, is 120 s old, and was never read:
  the response path is injected.
- **CHECK-IN:** a dispatch has no report after its eta (small 5 min, medium
  10, large 20; counted from the dispatch or the peer's last message): the
  Orchestrator is told to `ListAgents` and send one status query.
- **SILENT:** no report and no reply half an eta after the check-in: the
  Orchestrator is told to tell you.

A peer that replies to the status query restarts the clock. The events reach
the Orchestrator from the report-back store on its next prompt, never from a
path named in the prompt. Every event ends with the call to restart the
watcher. It exits on its own when its session is gone or after 12 h. It never
blocks; at most three wakes per request per silence window.

Launching a member also sets `AH_EXPECTED_ROOT` to the directory it starts in
(see [docs/team-file.md](./docs/team-file.md)). Teams and teardown, including
verified close and the warnings, are in
[docs/cli-tools.md](./docs/cli-tools.md#team-home-and-teardown).

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

The bash suite in `tests/` needs the `claude` CLI on `PATH`. The mod's
read-only guard checks the module with `claude plugin validate`, and the mod's
own tests run through `claude plugin test`. Without `claude`, both fail rather
than pass.

## What's new

- **0.106.0** named rosters: several rosters side by side, pick one per repo, machine or session.
- **0.107.0** role packs: roles shipped in a plugin, adopted one at a time behind a pin.
- **0.108.0** several owned teams: one session can own more than one team, and one sentence can create them.
- **0.108.5** config safety: write commands refuse a config file that won't parse instead of replacing it; a missing roster selection now refuses. Upgrade notes and the full list: [CHANGELOG.md](./CHANGELOG.md).
- **0.109.0** `/pipeline` decides safe questions for you and parks dangerous ones: [Decisions made for you](#decisions-made-for-you). Plan runs get a default branch. Issue runs can merge a PR for you, one approving click each, if you opt in: [Merging](#merging-only-if-you-opt-in).
- **0.114.0** the band's `[ Pane ]` button opens the hierarchy Pane; the `⚠ ah:` status entry is now opt-in (`status_entry` defaults to off): [The band](#the-band).
- **0.115.0** review and intent gates: a Reviewer brief must state its goal and acceptance, the Reviewer audits claims and traces new values and changed conditions, and a verdict covers only its range.
- **0.113.0** one team file per repo, whatever worktree you spawn from, and `disband`/`dismiss` verify the close and warn loudly; finished peer work is never left unseen (four report-back layers, including a dispatch watcher): [Finished work is never left unseen](#finished-work-is-never-left-unseen), [Team home and teardown](./docs/cli-tools.md#team-home-and-teardown).

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
needs `--team foo` when you own several (`--team @default` is a legacy
`team.json` team). A session you resume doesn't own its teams again on its
own: re-claim each with `roster.mjs adopt --orchestrator-pid <pid> --team foo`.
More:
[docs/getting-started.md](./docs/getting-started.md#5-spawning-a-team),
[docs/troubleshooting.md](./docs/troubleshooting.md#several-owned-teams).

## `/pipeline`: run a plan or issues to completion

`/pipeline` (`/ah:pipeline` where the plugin name is needed) works through a
list of items unattended. Each item goes through Architect, Implementor and
Reviewer; the Reviewer takes item N while the Implementor starts N+1. An item
gets at most 3 rework rounds. If it is still failing after the third, the run
stops that item and tells you, rather than starting a fourth. Issue runs add
caps of their own: at most 2 plan rounds per issue, and 3 per step and per
gate.

After the first notice (branch, route, permission mode, secret scanner, and who
decides questions for you) it only interrupts you when something needs a
person: a round cap, a real blocker, an Ultra-Advisor escalation, a red build,
a secret-scan finding, a halted push or a question parked for you (see
[Decisions made for you](#decisions-made-for-you)). **It never merges unless you opt in** (see
[Merging](#merging-only-if-you-opt-in)). Issue runs push an `ah/issue-<N>` branch per
issue (dependent issues stack on the branch they depend on) and open a draft
PR that says `Refs #N` or `Closes #N`; you review and merge. Before every push
it scans the patch for secrets, with gitleaks if installed, otherwise with the
`ah:secret-scanner` agent, and it stops on a finding.

    /pipeline docs/plans/search.md                   # a plan or spec file, run item by item
    /pipeline docs/plans/search.md --branch feat/search   # …on a branch you name
    /pipeline 12 14                                  # GitHub issues 12 and 14
    /pipeline #12 https://github.com/acme/app/issues/14   # refs may be #N or an issue URL
    /pipeline --labelled                             # every open issue carrying the trigger label

A plan run with no `--branch` works on `ah/pipeline-<plan-stem>`, made from
where you are: the plan's file name without its extension, lowercased, other
characters turned into `-`, cut at 40 characters. `docs/plans/search.md` runs
on `ah/pipeline-search`. If that branch already exists, locally or on `origin`,
the run stops before doing any work and tells you to pass `--branch` or delete
the old one; it never reuses a branch. It never pushes to `main` or a
protected branch. A file and issue refs can't be mixed, and `--branch` doesn't
apply to issue runs. A bare number is an issue; write `./12` for a file named
`12`. Acceptance criteria work either way: pass a file path, or type the
criteria into the request and the run saves them verbatim, one per line, to a
gitignored scratch file under `.claude/hierarchy/specs/`, runs on that, and
names the file in its start notice. The branch is named after the file (for
example `ah/pipeline-acs-20260930-2045`).

### Decisions made for you

During a run, questions the plan doesn't answer used to wait for you. Now,
once the run has started, a **safe** question is decided for you by the
strongest reasoner available, and a **dangerous** one waits for you.

- **Who decides.** A safe question goes to the Ultra-Advisor if you allowed it
  at the start of the run (the run asks once, unless you have already said),
  else to the highest-tier member of the team, else to a fresh subagent on the
  Orchestrator's own model. It is never a model below the Orchestrator's tier,
  and never the Orchestrator's own context. If none of those can take it, the
  question waits for you. The start notice says which decider applies, and
  where the log is.
- **What counts as dangerous.** Anything destructive or hard to undo; anything
  remote or merge-related (pushes outside the run's own, merging, approving,
  tracker writes); security and trust, including role packs, permissions,
  hooks, CI and build or dependency configuration; cost, such as spawning
  top-tier members you don't have; scope, such as a new item or a dropped
  criterion; and the run's own rules (caps, guards, the push regime). A
  question it can't classify counts as dangerous.
- **Caps.** At most 4 decisions per item and 20 per run; a question over a cap
  waits for you.
- **A dangerous or unsure question** stops only its own item (in an issue run
  the item ends `needs-user` and its dependents wait). The rest of the run
  carries on, and you answer at the end rather than mid-run.
- **Everything is on the record.** Each decision goes into a per-run log,
  `.claude/hierarchy/pipeline/<run id>/decisions.jsonl`, with the decider, the
  reason and how to undo it. The final report has **Decisions made on your
  behalf**, with product, UX or interface calls flagged "review" first, then
  **Waiting for you**; issue runs also put each item's decisions in its PR
  body. Read the log with `msg.mjs decision list`; the verbs are in
  [docs/cli-tools.md](./docs/cli-tools.md).

Decisions never change the 3-round cap, and the run's usual checks (review,
secret scan, push guard) still apply to whatever a decision produces. Where
the repo has no committed `.claude/ah-conventions.json`, the start notice says
"guards: prose only": protected paths are then the run's instructions, not a
hook.

**Who does the work.** The run builds its team itself with `roster.mjs
create`, so no team has to exist first, and the roster is chosen as in
[Named rosters](#named-rosters): `--roster`, then `AH_ROSTER`, then
`activeRoster`, then the default block. Select a roster before you start
(`/agent-roster use docs`, or launch the session with `AH_ROSTER=docs`). The
route is peer sessions unless you asked for subagents.

**Pack roles.** A role adopted from a [role pack](#role-packs-roles-from-someone-elses-plugin)
may take implementation work in a run, and is never launched with permission
checks off. The Reviewer and designer slots stay first-party: a pack Reviewer or
designer is refused while a run is open, and a run halts before starting if a
pack overrides the built-in Reviewer or Architect. Adopting or trusting a pack
role is refused while a run is live.

**Before you start.** The session must be in `--permission-mode auto`. Issue
runs also need `gh` installed and logged in to github.com, a GitHub `origin`,
and a `.claude/ah-conventions.json` that sets `issues.trigger_label` (plus
`trusted_actors` for an organisation's repo). The same file can switch on the
push guard, which refuses force pushes, protected branches, other remotes and
`--no-verify`. Most of the rules above, including draft PRs, the round caps
and the secret scan, are the run's own instructions, not hook guarantees.
What a hook does enforce is the push guard and the merge rules in
[Merging](#merging-only-if-you-opt-in); both match command text, so they are
a speed bump, not a sandbox. Run state lives in the gitignored `.claude/hierarchy/`; a stale
open run anchor there makes the next run halt. Everything the conventions file
accepts is in [docs/pipeline-conventions.md](./docs/pipeline-conventions.md);
the full run procedure is
[skills/autonomous-pipeline/SKILL.md](./skills/autonomous-pipeline/SKILL.md).

### Merging, only if you opt in

By default a run never merges: a person does. You can let an issue run do the
merging for you, with your approval on every merge.

- **Opting in.** Pass `--auto-merge`, or say so in plain words ("with
  auto-merge", "and merge them once I approve"). Otherwise the run asks once at
  the start, with "No" as the default. The answer is for that run only; nothing
  remembers it, and no config key turns it on. A plan run refuses it, because a
  plan run opens no PR. The start notice says whether auto-merge is on.
- **One click per merge.** At the end of the run, for each PR that is ready
  (signed off, checks passed, nothing requesting changes, no unresolved review
  threads, head unchanged), the run offers `gh pr merge <N>
  --match-head-commit <sha>` in a permission prompt, and your click is the
  approval. The merge is pinned to that exact commit, so a PR that changed
  since the run looked is refused. Decline and nothing runs; a merge GitHub
  refuses is reported with gh's own message and not retried. The prompt only
  appears in permission mode `default`, `auto` or `acceptEdits`; under bypass
  or don't-ask modes the merge is refused, because the prompt might never reach
  you.
- **Merging is never decided for you.** It isn't one of the questions in
  [Decisions made for you](#decisions-made-for-you), and it isn't logged as a
  decision. The final report lists **Merges performed under your
  authorisation** and **Not merged**, each PR with the reason. Check that
  report against GitHub: the log says a merge command ran, not that it merged.
- **What the merge guard blocks.** While a run is open, a hook refuses `gh pr
  merge` in any other form, `gh pr review --approve`, `gh pr ready` outside the
  pinned form, `--auto`, `--disable-auto` and `--admin`, `gh api` calls that
  merge, approve or write refs, and the GitHub tools that merge, approve or
  mark a PR ready. A refusal halts the run. It never blocks `git` commands, and
  it does nothing outside a run. Rule details:
  [docs/cli-tools.md](./docs/cli-tools.md).

**Honest limits.** The merge guard reads command text, so it stops a run that
follows its instructions from merging by mistake, and nothing more. `curl`,
scripts, `gh` aliases and extensions, and `xargs` or `find -exec` get past it,
and pushes aren't covered by it at all. The real boundary is on GitHub:

- **Pushes.** Branch protection or a ruleset on `main` that requires a pull
  request, with no bypass for the run's token, stops direct pushes by any
  route. The run uses your own token, so a bypass you have, it has: for classic
  branch protection turn on "Do not allow bypassing the above settings", and for
  a ruleset keep your own role off the bypass list. Every run's start notice
  carries a read-only line, "Branch protection on `main`: on", "on, but …" with
  the reason, "OFF", or "unknown", and the run goes ahead whatever it says.
- **Merges.** GitHub can't tell your click from the run's call, because both
  use your token. Merge approval is a hard wall only if the run uses a separate
  bot account or GitHub App identity that can't merge without your approving
  review. Setting that up is your call; without it, the prompt is a speed bump.

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
/hierarchy-pane                     # open the hierarchy status Pane
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
can manage. How to use it:
[`/pipeline`](#pipeline-run-a-plan-or-issues-to-completion).

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
mod/             the status entry, band, Pane and toasts (a Claude Code mod) and its tests
docs/specs/      per-feature design records
tests/           HOME-redirected; real config untouched
```

## License

Apache-2.0. See [LICENSE](../LICENSE).
