# task-gopher

Gets your main, high-reasoning agent to hand the legwork to a cheap Haiku
runner, so the expensive model spends its tokens on judgment instead of tool
output.

## The idea

You don't send your most expensive person out to fetch things. A gopher
(go-fer) runs the errands. task-gopher gives the lead agent a cheap one to send
out: running builds and tests, sifting logs, grepping the tree, reading files,
and bringing back a short report. The lead agent reasons over that report.

Tool output costs you twice. Once when the pricey model writes the tool call,
and again on every later turn, because tool results get re-sent as input
tokens until the next compaction. A single unfiltered test run or a big `grep`
can park thousands of lines in the reasoning model's context and keep charging
for them. If a cheap model does that work and returns only the answer, both
costs go down.

## Install

```
/plugin marketplace add agentic-tool-labs/agent-tools
/plugin install task-gopher@agent-tools
```

It ships turned off, because it changes how the agent works. Turn it on with
`/task-gopher on` (see [Turning it on and off](#turning-it-on-and-off)).

## What it does

When it's on, the plugin injects a directive telling the main agent to hand
work to a bundled `task-gopher` subagent (pinned to `model: haiku`) when the
step is:

- tool-heavy or output-heavy: test suites, builds, installs, verbose or
  long-running bash, sifting logs.
- information gathering that can be summarized: "find where X is defined",
  "list the callers of Y", "summarize module Z", reading or searching across
  many files.

There's a second bundled agent, `smart-gopher` (pinned to `model: sonnet`). It
takes delegated work that needs some judgment along the way, not just
execution. See [When to escalate to smart-gopher](#when-to-escalate-to-smart-gopher).

The main agent keeps everything that needs reasoning: design decisions,
correctness and security calls, tradeoffs, and writing or editing code. When a
task needs reasoning, it splits the work. task-gopher runs the step or gathers
the raw material and reports back briefly, and the main agent reasons over the
report.

The call the main agent makes about what to send out is kept shallow on
purpose, so it doesn't burn reasoning deciding what to delegate:

> Would doing this myself flood my context, or is it a mechanical task I can
> specify exactly? → dispatch it. Does it need my judgment? → keep the judgment,
> dispatch only the legwork. When unsure, keep it.

This is meant as a default, not something weighed step by step. The failure
it guards against is talking yourself out of it one step at a time: "this one
read / grep / diff is quick, I'll just do it." Small retrievals are exactly
what floods context once they add up, so what triggers a dispatch is the kind
of work, not the size of any single step. When several small retrievals come up
together (read these three files, grep for X, diff against main), the agent
batches them into one order instead of doing them inline. An explicit override
from a skill or command wins, for example a GitHub worker that owns the MCP
connection. That's a deliberate exception, not a violation.

## task-gopher runs orders; it doesn't decide things

The contract is written into the subagent's own instructions:

- It carries out explicit orders and nothing more. It doesn't reason, plan,
  design, or decide, and it makes no design, correctness, security, or scope
  calls.
- It can run tasks that change state, like a build, a migration, or a script,
  but only when the order says exactly what to do and what result to expect.
  It runs the task and reports whether the result matched. It has no
  file-editing tools; it runs tasks, it doesn't edit.
- It never fills a gap with a guess. If an order is ambiguous or would need it
  to decide something (which file, which flag, whether something is "safe",
  what the user "probably meant"), it stops, says exactly what's missing, and
  hands the decision back.

Because the runner won't improvise, it's on the lead agent to hand down
complete orders with no decisions left in them, and with the exact result it
expects.

smart-gopher is different. It's allowed to make decisions about the work, but
never about the project. It can reason about which file or call site is meant,
whether two pieces of evidence disagree, or what a confusing module actually
does. It hands design, architecture, security, and scope calls back to the
lead, the same way task-gopher hands back a gap.

### Writing orders

The runner sees nothing but the dispatch prompt. It can't see the lead's
context and it won't fill gaps. Worse, it may not notice a gap at all: it runs
the order literally, wherever and however it lands. So every order covers four
things.

**Where.** Absolute paths or cwd, and for anything touching git, the exact repo
and branch or ref. An order that assumes "the branch we're on" runs on whatever
happens to be checked out. If the order names a branch, the runner checks it
before running and stops on a mismatch. If it doesn't name one, the runner
reports which branch it actually ran on.

**How.** The exact method: commands, search patterns, files. "Find where X is
defined" invites improvisation. "Run `grep -rn 'class X' src/` and report every
file:line" doesn't. The runner uses the method it's given and never swaps in
its own. A failed or empty result gets reported as the result.

**What back.** The report format, a size limit, and how complete it has to be
(every match, or the first N). Short never means incomplete: the runner
returns everything the order asks for, and anything cut to fit a size limit is
named and counted, never dropped silently.

**What if.** What to do on a failure or an empty result. Almost always "report
exactly what happened and stop", never "try something else" uninvited.

If the lead can't spell out an order to that level, there's still a judgment
call hiding in it. The directive tells the lead to settle that first, because
handing Haiku an order with room for judgment doesn't delegate the judgment,
it randomizes it.

### A dispatch has to shrink things

task-gopher only pays for itself when its report is smaller than what it read.
It reads a lot and returns a little. The pattern to avoid is ordering it to
read a whole file and hand the contents back word for word. That puts just as
many tokens back in the lead's context, with an extra hop and nothing saved.
So the directive tells the lead: if you really need the full file in front of
you, read it yourself. Otherwise narrow the ask. Grep and return only the
matching `file:line` plus a little context, the one function you care about, a
direct answer, or a summary. Ask "where is X handled, and what does that code
look like?", not "send me all of foo.ts". If you can't name an expected answer
that's smaller than the source, narrow it or do it yourself. The gopher's own
prompt backs this up: it distills instead of pasting whole files.

## The runner never destroys or publishes without you

A runner that makes no judgments can't be allowed to take actions that need
one. The dangerous case isn't a runner deciding to delete something. It's a
runner whose ordered command fails, and which then reaches for a bigger hammer
to make it work. `git worktree remove` turns into
`git worktree remove --force`, and the safety check that just refused was the only thing between
the order and the work it's about to destroy.

So a `PreToolUse` guard classifies every `Bash` command the runner makes and,
for each stage of a shell pipeline, asks you to approve it. The risk is yours, so
the go-ahead has to be yours too. It intercepts two kinds of command.

Destructive ones: `rm -rf`/`rm -f`, `git reset --hard`, `git clean -fdx`,
`git worktree remove`/`prune`, `git branch -D`, `git restore`,
`git checkout --`, `git rebase`, `git commit --amend`, `git stash drop`,
history rewrites, `find -delete`, in-place `sed -i`, recursive
`chmod`/`chown`, `rsync --delete`, `dd`, `shred`, `docker`/`kubectl`/`helm`
teardown, `terraform destroy`/`apply`, `dropdb`, and SQL `DROP`/`TRUNCATE`.

Anything that leaves the machine: `git push`, `gh pr`/`issue`/`release`
writes, `npm`/`cargo`/`gem`/`poetry` publish, and `curl` with a write method.

The guard runs whether or not the delegation directive is turned on, because
the runners can be dispatched either way. It applies to both bundled runners,
task-gopher and smart-gopher, and to nothing else.

There's one known gap: the guard only sees `Bash`. smart-gopher also has
`Edit` and `Write`, and the `PreToolUse` matcher in `hooks.json` is
`Read|Grep|Glob|Bash|Agent|Task`, so an `Edit` or `Write` call never reaches
this hook. smart-gopher can overwrite or truncate a tracked file without the
guard getting involved. That's accepted for now. Git is how you recover a
tracked file, and `git reset --hard` and `git checkout --` are themselves
guarded, so an edit you can't undo still needs a guarded Bash command
somewhere downstream. Extending the guard to `Edit`/`Write` with a path-based
classifier is real follow-up work, not something to bolt on here.

### Why it asks you and not the lead

The obvious shortcut is to let the model that dispatched the runner approve the
command. It's the expensive reasoner, it has the context, and it would save you
an interruption. It's still the wrong answer. One model vouching for another
isn't informed consent. It's the same failure one level up, and what's at risk
(your work, your repo, your production database) isn't the model's to risk.

So the guard asks every time, even when the lead approved the command in
advance. That approval isn't thrown away. It shows up in the prompt as context,
so you can see the lead meant it:

```
Reinstall dependencies in /Users/me/proj.
ALLOW-DESTRUCTIVE: rm -rf /Users/me/proj/node_modules
Then run `npm install` and report the exit code.
```

With that order, the prompt tells you the runner wants to run
`rm -rf /Users/me/proj/node_modules`, that the runner can't judge whether
that's right, and that its lead vouched for this exact command. You still
decide.

The match has to be exact, which is what makes that disclosure trustworthy. A
different path is a different command, and a command that's only mentioned in
the order's prose grants nothing.

### When nobody's at the keyboard

A prompt is useless in an unattended run, so the guard checks the session's
`permission_mode` first. In `default`, `acceptEdits`, and `plan` it asks. In
`auto`, `dontAsk`, and `bypassPermissions`, which exist precisely to stop
asking, a prompt wouldn't reach anyone, so it denies the command instead and
says so in the denial. An `ALLOW-DESTRUCTIVE` line is the only way through
there. That's really what the line is for: committing in advance to one
specific command in a run you won't be watching.

If the payload has no permission mode at all, that counts as unattended too.
The guard never bets that someone is watching.

### Guard modes

`~/.claude/task-gopher.guard` holds one word. If the file is missing, the mode
is `ask`.

| mode | behavior |
| --- | --- |
| `ask` *(default)* | prompt you every time; deny where no prompt can reach you |
| `block` | never prompt; hard-deny, and only `ALLOW-DESTRUCTIVE` lets a command through |
| `off` | no guard |

Set it with `/task-gopher guard ask|block|off`, and check it with
`/task-gopher guard status` (or just `/task-gopher guard`).

Every `ALLOW-DESTRUCTIVE` line the lead writes is recorded in
`~/.claude/task-gopher.allow`, keyed by session and exact command, so one
authorization covers both runners for the rest of that session. In `ask` mode
it's shown to you inside the prompt; it doesn't skip the prompt. It only lets
a command through on its own in `block` mode, or where no prompt can reach you.
`/task-gopher allow list` shows what's been recorded, and
`/task-gopher allow clear` revokes all of it.

**Scratch-repo experiments.** A runner standing in a real repository whose
command writes a local `git config user.*` identity, or builds a path on a
variable it never assigns (each Bash call is a fresh shell), is denied
outright if any git write in it names no scratch path (`git -C "$T/r" …`).
It never asks, no `ALLOW-DESTRUCTIVE` line releases it, and mode `off` disables it.

### What it doesn't catch

Pattern matching isn't a shell parser. A command hidden in a variable, a
base64 blob, or a script file that does the deleting will get through. This
stops a runner improvising, not an attacker. Prompts, denials, and approved
runs all go into the audit log, and `/task-gopher report` prints them.

## Who may delegate: the tier gate

What decides whether an agent may delegate is its model tier, not where it sits
in the agent tree. Any agent at Sonnet tier or above, whether it's the
top-level agent or a subagent, may dispatch to the Haiku task-gopher. A
Haiku-tier agent may not. That's also what stops task-gopher (itself Haiku)
from dispatching to task-gopher and recursing.

The reasoning: the point is to move cheap legwork off an expensive reasoner.
If the agent doing the work is already Haiku, there's nothing to save, and
Haiku delegating to Haiku is pure overhead. A capable reasoner should push
legwork down whether it's the main agent or a subagent.

One catch shapes how this is built: Claude Code hook payloads carry no model
field. (Checked against the CLI: the payload is `session_id`,
`transcript_path`, `cwd`, `prompt_id`, `permission_mode`, `agent_id`,
`agent_type`, and `effort`. That `effort` is the thinking level,
`low|medium|high`, not a capability tier. Hooks get no "reasoning index".) So a
hook can't read the tier. Instead:

- The directive reaches the main session through the injection hooks, and
  reaches subagents through the relay (see
  [Reaching subagents](#reaching-subagents-the-relay); `SessionStart` and
  `UserPromptSubmit` never fire for subagents). task-gopher itself is skipped
  by name through `agent_type`, so the runner that could recurse never sees the
  directive by either route.
- The directive opens with a tier gate: if you're Haiku-tier, ignore it and do
  the work yourself; if you're Sonnet-tier or higher, follow it. Each agent
  opts out based on its own model identity, which the model knows far more
  reliably than any payload field could tell it.
- task-gopher's own prompt is the hard backstop. It never delegates onward,
  full stop.

> **The tier gate is soft for now.** With no model or tier field exposed to
> hooks, the gate depends on each agent recognizing its own tier and opting
> out. The plugin can't enforce it. That's reliable for "am I Haiku?", but it
> isn't a hard guarantee. If a future Claude Code version adds a model or tier
> field to the hook payload, this becomes a hard gate: the hook would skip
> injection for Haiku-tier agents directly. It's tracked as a `TODO(hard-gate)`
> in `hooks/directive.mjs`.

smart-gopher is Sonnet-tier, so by the tier gate alone it would be allowed to
dispatch. What actually stops it is `disallowedTools: Agent, Task` in its
frontmatter. The tier gate governs who may dispatch to a gopher, not what a
gopher can do once it's running.

## When to escalate to smart-gopher

There are exactly two moments to reach for smart-gopher. One is when you're
about to do tool-heavy work yourself only because you can't write an order for
it with no decisions left in. The other is when task-gopher has already stopped
on a gap, and the gap is a judgment call rather than a missing fact. It's not a
general upgrade: anything you can specify exactly still goes to task-gopher.
And it's not a way to offload your own design, correctness, security, or scope
decisions. Those stay with you either way.

### The smart-gopher gate

Using the least-privileged runner first is enforced, not just suggested. A
`PreToolUse` hook checkpoints each distinct dispatch to smart-gopher: it denies
the attempt with a nudge to confirm task-gopher really couldn't do it, in the
same "re-run to proceed" style as the strict retrieval checkpoint. Unlike that
checkpoint, this one:

- fires once per exact request, not once per turn. The identical retry goes
  straight through for good, but any other smart-gopher prompt, even later in
  the same session, gets its own fresh checkpoint. Getting past the gate buys
  trust for that one request, not a pass for the session.
- matches on the exact prompt text (hashed, not stored). A slightly reworded
  retry is a different request and gets challenged again. That errs toward
  more checkpoints, not fewer.
- doesn't need strict mode. It runs whenever the plugin is on.
- only gates dispatches to smart-gopher. task-gopher dispatches never get this
  checkpoint.

It's a speed bump, not a wall. It can't check that the agent really
reconsidered, only that it paused once per request. `smart-gate-checkpoint`
lines in the audit log record when it fired.

### The verbatim-read gate

Ordering the runner to read a file and hand it back whole costs more than
reading it yourself. Haiku reads the bytes, writes them out again, and you read
them a second time, plus the cost of a dispatch. The written rule against this
was routinely ignored, so a `PreToolUse` hook now denies those orders outright.
It catches a whole-file object ("the full file contents", "return the entire
source"), wording that asks to read the whole thing, or any single line range
of 80 lines or more. Unlike every other gate here, this one is a hard deny. No
per-session key, no re-run to proceed, because a retry pass would teach
rewording instead of narrowing. Narrow the order so the answer is smaller than
the source, or read the file directly. The word "verbatim" on its own is
deliberately not a trigger: 70% of real orders use it, and they mean "don't
paraphrase". Denials show up in the audit log as `verbatim-deny`.

### Escape hatch

Dispatching isn't a trap. If task-gopher comes back with something incomplete,
wrong, or not enough, or says it couldn't go on because an order needed a
decision, the main agent can do the task itself or re-dispatch once with a
sharper, fully specified order. It won't ping-pong. A stalled dispatch costs
more than just doing the work.

## Reaching subagents: the relay

The directive says it applies to subagents too, but Claude Code's
`SessionStart` and `UserPromptSubmit` hooks never fire for subagents (a
subagent isn't a session). A subagent gets its own agent file, the CLAUDE.md
hierarchy, and the dispatch prompt, and that's all. Left alone, a Sonnet-tier
subagent would never see the directive.

`SubagentStart` is another channel that works (it does reach the subagent,
given a JSON payload), but it doesn't carry the dispatch prompt, so it can't
skip dispatches to task-gopher itself or to agents that have no `Agent` tool.
This plugin needs both of those, so it rewrites the prompt instead. See
[docs/subagent-directive-relay.md](../docs/subagent-directive-relay.md).

The trick is to apply the relay before the subagent exists. Spawning a subagent
is just an `Agent` tool call, and `PreToolUse` fires for it in the spawning
agent's loop with the full dispatch prompt visible in the hook input. That hook
can rewrite the call before it runs. Whenever the plugin is on (strict mode not
needed):

- The hook returns `hookSpecificOutput.updatedInput` with the directive added
  to the top of the dispatch prompt. The subagent starts with the directive at
  the top of its context. The parent never gets involved: it doesn't see the
  rewrite, isn't bounced, and spends no output tokens copying anything.
- `PreToolUse` also fires inside a subagent's own loop, so a subagent
  dispatching a grandchild gets the same rewrite. The chain is automatic and
  doesn't depend on any model cooperating.
- Some dispatches are skipped: those to either bundled gopher (they're the
  point, and neither can dispatch onward), built-in subagents without the
  `Agent` tool (`Explore`, `Plan`, `statusline-setup`,
  `output-style-setup`), and any prompt that already carries the
  `[task-gopher: ON]` sentinel near the top, so a hand-pasted directive isn't
  doubled. That check only looks at the top of the prompt, so a mention of the
  sentinel further down doesn't count. The directive also opens with an escape
  clause for agents that have no tools.
- The gate also skips agents whose definition file lists `tools:` without
  `Agent` or `Task`, and the six `ah:` hierarchy roles, whose own agent files
  already carry the delegation rule.

Some agents have no definition file the gate can read, notably SDK-defined
agents. You can exempt those by hand, using the exact namespaced
`subagent_type`:

```
/task-gopher relay-exempt                     # list the exemptions
/task-gopher relay-exempt add <agent-type>
/task-gopher relay-exempt remove <agent-type>
```

The list lives in `~/.claude/task-gopher.relay-exempt`, one type per line.
Exempting an agent that can dispatch just means it stops being told to
delegate.

This replaced an earlier deny-and-retry design, where the hook rejected
dispatches without the directive and made the parent paste the block in. That
worked, but cost a round trip plus about 1.4K tokens of parent output per
dispatch, and needed per-context bounce counters to avoid deny loops. Rewriting
the call in flight costs none of that.

> **One limit:** delivery depends on the harness honoring `updatedInput` on
> the `Agent` tool. That's been checked live: a probe dispatched with a
> 300-character prompt reported receiving a 7,300-character one that opened
> with the tier gate. If a future version stops honoring it, the relay fails
> silently. The dispatch still works; the subagent just never sees the
> directive. The `relay-injected` count in `/task-gopher report` is how you'd
> notice.

## Turning it on and off

It ships off, since it changes how the agent works.

```
/task-gopher on         # enable delegation
/task-gopher off        # disable, main agent handles tools itself
/task-gopher status     # show current state
/task-gopher            # toggle
/task-gopher strict     # enable strict mode (also turns delegation on)
/task-gopher strict off # back to guidance-only
```

The state is a marker file at `~/.claude/task-gopher.enabled` (if it exists,
the plugin is on). It lives in your home directory, so the setting survives
plugin updates. Turning it on takes effect on your next prompt, and it's set up
again automatically in new sessions and after compaction.

## Strict mode

The directive is guidance, and a capable agent can still decide "this one read
is quick, I'll just do it" on every small step and never actually delegate.
Strict mode adds a checkpoint on top. When it's on, a `PreToolUse` hook blocks
a direct retrieval (a `Read`, `Grep`, or `Glob`, or retrieval-style `Bash` like
`grep`, `find`, `cat`, `git diff`, or a test or build run) with a message
telling the agent to consider dispatching to task-gopher and to batch this with
its other reads, greps, and diffs into one order. Re-running the same call goes
through. A reader such as `cat`, `head` or `tail` counts in every chained
command (after `;`, `&&`, `||`, `&` or a newline), not only the first, but not
after a pipe, where it only trims output. It never fires on commands that aren't retrievals (`git commit`,
`mkdir`, and so on) or inside task-gopher itself. It also skips an agent whose
definition has a `tools:` allow-list without `Agent` or `Task`, such as a
read-only scanner: that agent can't dispatch, so the advice would only cost it
a turn. The agent is found the same way as for the relay skip. If it can't be
found, or has no `tools:` line, the checkpoint applies as usual.

A command whose every part is a listed action isn't checkpointed, even when a
word in it looks like a lookup. The actions are writing a heredoc or its own
text (`cat >` from a heredoc, `echo`, `printf`, `tee`), herdr pane, tab and
workspace control, git and gh writes (`git commit`, `git push`, `gh pr create`
and the like), plugin updates, `cd` and `sleep`. One `herdr pane read` capped
at 60 lines with `--lines`, piped only through `grep`, `head` or `tail`, passes
too. A lookup anywhere in the command is still checkpointed, including one
nested in `$(…)`, backticks, `bash -c` or `eval`. Each pass is logged as
`exempt` in the audit log.

> **Limit:** the exemption is a fixed list. A lookup the hook can't see, such
> as one inside a script file or in a variable holding the command, was never
> caught and still isn't.

It doesn't nudge once and give up for the rest of the turn. It escalates on
repeated bypasses: it blocks the first retrieval of a turn, lets the next two
direct retrievals through quietly, then blocks again on the third in a row,
and on every third after that. An agent that keeps pulling things into its own
context gets checkpointed again instead of drifting quietly.

Dispatching to task-gopher resets the count. Good behavior buys a clean slate,
so an agent that delegates is left alone and one that doesn't keeps getting
stopped.

Each count covers one agent within one turn, keyed on `session_id`,
`agent_id`, and `prompt_id` together. All three matter. Versions before 0.7.0
keyed on the turn alone, which put the main agent, every subagent it spawned,
and every other Claude Code session on the machine into one shared counter.
That broke the gate both ways. A subagent almost never got checkpointed,
because the parent had already used up the turn's one block before the
subagent ran. And whenever another context wrote its own id, the next reader
saw a foreign turn and re-fired the first-retrieval checkpoint, so "re-run to
proceed" silently didn't work. Over five days of real use, 76% of
first-retrieval checkpoints fired on a turn that was already in progress, a
median 2.7 seconds after that turn's previous event.

So subagents get their own checkpoint now. That costs one extra round trip for
each subagent that does retrievals. Dispatches to task-gopher itself are
exempt, so the runner never pays it.

> **One limit:** this pushes the agent to choose; it can't guarantee a good
> choice. The hook can't check that the agent really reconsidered, since a
> re-run always passes, and it can't tell a retrieval from a read the agent
> needs for its own reasoning or editing. That's why it escalates instead of
> hard-blocking every read, why strict mode is opt-in and separate from turning
> the plugin on, and why it keeps an audit log so you can check whether the
> choices were good ones.

### Audit log and report

The plugin appends to a JSONL log at `~/.claude/task-gopher.log`. It writes
one line per checkpoint (the strict gate blocked something), per bypass (a
direct retrieval done anyway, with the exact file or command), per dispatch (a
delegation to task-gopher), and per relay event (`relay-injected` when a
dispatch got the directive added, `relay-ok` when it already had one). Every
line has a `prompt_id` and a time. Checkpoint and bypass lines need strict
mode; dispatch and relay lines are written whenever the plugin is on. Since a
re-run always passes, this log is where the gate gets its teeth: it's the
record of what the agent chose to do itself.

```
/task-gopher report      # summarize the log
/task-gopher log clear   # wipe it
```

The report shows totals, the bypass-to-dispatch ratio (lower is better), which
tools get bypassed most, and the latest bypasses with what was run directly.
You can see at a glance whether the lead is choosing deliberately or just
clicking through the checkpoint. For example:

```
turns logged:   5  (3 saw the strict gate)
checkpoints:    3  (times the strict gate blocked)
bypasses:       4  (direct retrievals done anyway)
dispatches:     2  (delegations to task-gopher; 1 in strict-gated turns)
bypass/dispatch ratio: 4.00  (strict-gated turns only; lower is better)
bypassed tools: Read 3, Bash 1
subagent relay:  5 stamped, 1 already carried it
recent bypasses (last 4) — what was run directly:
  - 2026-07-16 14:40:00  Read: src/app.ts
  - 2026-07-16 14:40:00  Bash: git diff main -- config/
  ...
```

## How it's wired

- `agents/task-gopher.md` is the Haiku runner. It has read, search, and run
  tools (`Read, Grep, Glob, Bash, WebFetch, WebSearch`) and nothing that edits
  files. Its prompt tells it to carry out exact orders only, return the
  smallest report that fully answers, stop and report instead of deciding,
  never delegate onward, check a named branch before running, and never
  truncate silently.
- `hooks/` holds the hooks. `SessionStart` (startup, resume, clear, and
  compact) injects the full directive. `UserPromptSubmit` injects a one-line
  reminder each turn. `PreToolUse` runs the subagent relay whenever the plugin
  is on, the per-request smart-gopher gate, and, in strict mode, the escalating
  retrieval checkpoint. All three write to the audit log, and `report.mjs`
  renders it. Every hook does nothing when the plugin is off, and nothing inside
  task-gopher itself. The tier gate and the relay are covered in
  [Who may delegate](#who-may-delegate-the-tier-gate) and
  [Reaching subagents](#reaching-subagents-the-relay).
- `commands/task-gopher.md` is the `/task-gopher` slash command.

## Works well with output-discipline

It pairs naturally with [output-discipline](../output-discipline/README.md).
output-discipline blocks commands that would flood the context before they
run, and task-gopher moves the work that gets past that gate onto a cheaper
model. The task-gopher runner follows output discipline too, keeping its own
context lean while it works.

## License

Apache-2.0. See [LICENSE](../LICENSE).
