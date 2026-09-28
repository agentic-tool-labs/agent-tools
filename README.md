# agent-tools

Plugins for coding agents. Most of them are hooks: instead of asking the agent
nicely to behave a certain way, they check what it's about to do and step in.
The rest help with context compaction and pull-request review.

Each plugin stands alone. Install the ones you want; none of them needs any of
the others.

This repo replaces three older ones, `claudetools`, `github-agent-plugins`,
and `claude-compaction-tools`, which are now archived. If you installed
anything from those, see [Moving from the old repos](#moving-from-the-old-repos).

## The plugins

| Plugin | What it does |
|---|---|
| [ah](./agent-hierarchy/README.md) (agent-hierarchy) | Splits work across six roles, from an Orchestrator and an Architect down to a Haiku task runner, and runs each on a model priced for its job. |
| [task-gopher](./task-gopher/README.md) | Gets your main agent to hand tool-heavy legwork to a cheap Haiku runner and reason over the short report it brings back. |
| [output-discipline](./output-discipline/README.md) | Stops commands that would flood the context window, like `tail -f` or an unfiltered test run, before they run, and tells Claude what to run instead. |
| [comment-discipline](./comment-discipline/README.md) | Stops Claude from writing comments that only make sense next to the diff, like `// changed from foo to bar`. |
| [review-guide](./review-guide/README.md) | Lets you note what each change is for as you work, then compiles those notes into a walkthrough for whoever reviews the PR. |
| [github-pr-toolkit](./github-pr-toolkit/README.md) | `/code-critic` writes an adversarial review of a diff or PR, and `/resolve-pr-comments` works through the threads reviewers opened, with the main agent reasoning and Haiku workers doing the GitHub calls. |
| [idle-compactor](./idle-compactor/README.md) | Runs `/compact` when a session has gone idle, timed to land just before the prompt cache expires, or keeps the cache warm instead. |
| [compaction-capture](./compaction-capture/README.md) | Saves each compaction summary to a markdown file, so what the session dropped is still on disk. |
| [compaction-guard](./compaction-guard/README.md) | Restates your standing rules after every compaction, so the ones the summary dropped are back before the next turn. |

## Install

### Claude Code

Add the marketplace, then install whichever plugins you want:

```
/plugin marketplace add agentic-tool-labs/agent-tools
/plugin install ah@agent-tools
/plugin install task-gopher@agent-tools
/plugin install output-discipline@agent-tools
/plugin install comment-discipline@agent-tools
/plugin install review-guide@agent-tools
/plugin install github-pr-toolkit@agent-tools
/plugin install idle-compactor@agent-tools
/plugin install compaction-capture@agent-tools
/plugin install compaction-guard@agent-tools
```

The same commands work from a terminal as
`claude plugin marketplace add agentic-tool-labs/agent-tools` and
`claude plugin install <name>@agent-tools`.

Some plugins need a step after installing, like turning task-gopher on or
giving github-pr-toolkit a GitHub token. Each plugin's README covers that.

### Codex

Codex reads the same marketplace file, so the plugin names are the same:

```
codex plugin marketplace add agentic-tool-labs/agent-tools
codex plugin add task-gopher@agent-tools
```

Swap in any plugin name from the table. `codex plugin list` shows what's
available and what's installed. The plugins are written against Claude Code's
hooks, slash commands, and subagents, and their READMEs describe them in
Claude Code terms.

## Moving from the old repos

The plugins kept their names when they moved. Only the marketplace changed.

| Old repo | Old marketplace | Plugins |
|---|---|---|
| JimCline/claudetools | `claudetools` | ah, comment-discipline, output-discipline, review-guide, task-gopher, and the retired model-banner |
| JimCline/github-agent-plugins | `jimcline` | github-pr-toolkit, and the older resolve-pr-comments and code-critic it replaced |
| JimCline/claude-compaction-tools | `jcline-claude-compaction-tools` | idle-compactor, compaction-capture, compaction-guard |

For each plugin, install the new copy first, then uninstall the old one. Once
nothing from an old marketplace is left, remove that marketplace. Only run the
lines for plugins you actually have. `/plugin` shows what's installed, or run
`claude plugin list` in a terminal.

### Claude Code

Add the new marketplace once:

```
/plugin marketplace add agentic-tool-labs/agent-tools
```

From `claudetools`:

```
/plugin install ah@agent-tools
/plugin uninstall ah@claudetools
/plugin install comment-discipline@agent-tools
/plugin uninstall comment-discipline@claudetools
/plugin install output-discipline@agent-tools
/plugin uninstall output-discipline@claudetools
/plugin install review-guide@agent-tools
/plugin uninstall review-guide@claudetools
/plugin install task-gopher@agent-tools
/plugin uninstall task-gopher@claudetools
/plugin uninstall model-banner@claudetools
/plugin marketplace remove claudetools
```

model-banner was retired rather than moved. Uninstall it; there's nothing to
replace it with.

From `jimcline`:

```
/plugin install github-pr-toolkit@agent-tools
/plugin uninstall github-pr-toolkit@jimcline
/plugin uninstall resolve-pr-comments@jimcline
/plugin uninstall code-critic@jimcline
/plugin marketplace remove jimcline
```

Installing github-pr-toolkit asks for your GitHub token. It replaced the older
resolve-pr-comments and code-critic plugins, so if you have either of those,
install github-pr-toolkit and uninstall them. There's no agent-tools copy of
either.

From `jcline-claude-compaction-tools`:

```
/plugin install idle-compactor@agent-tools
/plugin uninstall idle-compactor@jcline-claude-compaction-tools
/plugin install compaction-capture@agent-tools
/plugin uninstall compaction-capture@jcline-claude-compaction-tools
/plugin install compaction-guard@agent-tools
/plugin uninstall compaction-guard@jcline-claude-compaction-tools
/plugin marketplace remove jcline-claude-compaction-tools
```

`claude plugin list` shows each plugin's scope. The commands above are for
the default, `user`. If an old plugin shows `Scope: project` or
`Scope: local`, run its install and uninstall lines from that project with the
same scope added, for example
`claude plugin install ah@agent-tools --scope project` and
`claude plugin uninstall ah@claudetools --scope project`.

When you're done, restart Claude Code or run `/reload-plugins`. Every
`/plugin` command above also works in a terminal as `claude plugin ...`, for
example `claude plugin uninstall ah@claudetools`.

### Codex

Add the new marketplace once:

```
codex plugin marketplace add agentic-tool-labs/agent-tools
```

From `claudetools`:

```
codex plugin add ah@agent-tools
codex plugin remove ah@claudetools
codex plugin add comment-discipline@agent-tools
codex plugin remove comment-discipline@claudetools
codex plugin add output-discipline@agent-tools
codex plugin remove output-discipline@claudetools
codex plugin add review-guide@agent-tools
codex plugin remove review-guide@claudetools
codex plugin add task-gopher@agent-tools
codex plugin remove task-gopher@claudetools
codex plugin remove model-banner@claudetools
codex plugin marketplace remove claudetools
```

From `jimcline`:

```
codex plugin add github-pr-toolkit@agent-tools
codex plugin remove github-pr-toolkit@jimcline
codex plugin remove resolve-pr-comments@jimcline
codex plugin remove code-critic@jimcline
codex plugin marketplace remove jimcline
```

From `jcline-claude-compaction-tools`:

```
codex plugin add idle-compactor@agent-tools
codex plugin remove idle-compactor@jcline-claude-compaction-tools
codex plugin add compaction-capture@agent-tools
codex plugin remove compaction-capture@jcline-claude-compaction-tools
codex plugin add compaction-guard@agent-tools
codex plugin remove compaction-guard@jcline-claude-compaction-tools
codex plugin marketplace remove jcline-claude-compaction-tools
```

**If `codex plugin list` fails** with "marketplace root does not contain a
supported manifest", one of your configured marketplaces points at a folder
with no manifest in it, and Codex refuses to list anything until it's gone.
Run `codex plugin marketplace list` to find it. If it's one of the three old
marketplaces, remove it with `codex plugin marketplace remove <name>` and carry
on. If it's something else of yours, like a local checkout, fix or remove that
one knowingly.

### Or have your agent do it

Paste this into Claude Code (or Codex) and it will do the migration for you:

```
Move my agent plugins from three archived marketplaces to the new
"agent-tools" marketplace (GitHub: agentic-tool-labs/agent-tools). Do it in Claude
Code and in Codex, for whichever of the two is installed on this machine.

What moved where. Plugin names are unchanged.
- claudetools: ah, comment-discipline, output-discipline, review-guide,
  task-gopher. Also model-banner, which was retired: uninstall it and
  install nothing in its place.
- jimcline: github-pr-toolkit. The older resolve-pr-comments and code-critic
  plugins from jimcline were merged into github-pr-toolkit. If either is
  installed, uninstall it and make sure github-pr-toolkit@agent-tools is
  installed instead. agent-tools has no resolve-pr-comments or code-critic,
  so don't try to install them.
- jcline-claude-compaction-tools: idle-compactor, compaction-capture,
  compaction-guard.

Rules:
- If a command fails, stop and tell me the exact command and error. Don't
  work around it.
- Never remove a marketplace other than claudetools, jimcline, or
  jcline-claude-compaction-tools without asking me first.
- github-pr-toolkit needs my GitHub token. If installing it asks for one,
  stop and let me enter it myself (I can also set it later under /plugin →
  github-pr-toolkit → Configure).
- Run every command from the directory you start in. Project and local
  scopes belong to the project you're in.

0. Run `command -v claude` and `command -v codex`. Do the Claude Code steps
   only if `claude` exists, and the Codex steps only if `codex` exists. If
   neither exists, tell me and stop.

Claude Code:
1. Run `claude plugin list --json` and `claude plugin marketplace list`.
   Write down every plugin installed from claudetools, jimcline, or
   jcline-claude-compaction-tools, with its `scope` field (plain
   `claude plugin list` shows the same thing as `Scope:`), and which of
   those three marketplaces are configured. If there are none of either,
   there's nothing to do in Claude Code; go on to Codex. If any of those
   plugins has a scope other than user, project, or local, stop and ask me.
2. Unless agent-tools is already listed, run
   `claude plugin marketplace add agentic-tool-labs/agent-tools`.
3. Build the target list: every plugin from step 1, minus model-banner, with
   resolve-pr-comments and code-critic replaced by a single
   github-pr-toolkit. Each name keeps the scope of the old plugin it
   replaces; if resolve-pr-comments and code-critic were installed at
   different scopes, stop and ask me. For each name that isn't already
   installed from agent-tools at that scope, run
   `claude plugin install <name>@agent-tools --scope <scope>`.
4. Then uninstall every plugin from step 1 from its old marketplace,
   including model-banner, resolve-pr-comments, and code-critic:
   `claude plugin uninstall <name>@<old marketplace> --scope <scope>`, using
   the scope you wrote down for it.
5. For each old marketplace from step 1 that now has nothing installed from
   it, run `claude plugin marketplace remove <old marketplace>`.

Codex:
6. Run `codex plugin marketplace list`, then `codex plugin list`. If
   `codex plugin list` fails with "marketplace root does not contain a
   supported manifest", use the marketplace list to find the marketplace
   whose root has no manifest. If it's claudetools, jimcline, or
   jcline-claude-compaction-tools, remove it with
   `codex plugin marketplace remove <name>` and run `codex plugin list`
   again. If it's any other marketplace, or you can't tell which one it is,
   stop and ask me.
7. Repeat steps 1 to 5 with the Codex commands. Codex has no scopes, so
   skip everything about scope:
   `codex plugin list`, `codex plugin marketplace list`,
   `codex plugin marketplace add agentic-tool-labs/agent-tools`,
   `codex plugin add <name>@agent-tools`,
   `codex plugin remove <name>@<old marketplace>`, and
   `codex plugin marketplace remove <old marketplace>`.

Verify, in each CLI you used:
8. The plugin list shows every name on that CLI's target list as
   <name>@agent-tools, and nothing from the three old marketplaces. The
   marketplace list no longer shows the old marketplaces.

When you're done, tell me what you installed, what you removed, and what the
verify step showed, and remind me to restart Claude Code (or run
/reload-plugins) so the new copies load.
```

## Why hooks, not prompts

These plugins exist to stop a failure that isn't disobedience. No model reads
"delegate the legwork" and decides to defy it. What happens is that the rule
wears away through exceptions that each look reasonable. This grep is tiny.
That file is half in context already. Dispatching has overhead. The answer is
needed now. Every single call can be defended, and added up, the directive has
been ignored.

Written rules are bad at stopping this, because from the inside the
rationalizing feels like judgment, and judgment is exactly what the model has
been told to keep for itself. So the useful question isn't "is this rule
written down?" It's "how many times does the model have to choose to follow
it?" That gives a ladder, strongest first:

| | Mechanism | Here |
|---|---|---|
| 1 | **Structurally impossible**: the decision doesn't exist | model pinned in agent frontmatter; Reviewer denied `Write`; Architect denied `Bash` |
| 2 | **Hard-denied** at `PreToolUse` | output-discipline's Bash gate. Only safe for rules a machine can check |
| 3 | **Checkpoint with an escape hatch** | task-gopher strict mode, for rules where a flat deny would sometimes be wrong |
| 4 | **Injected directive** | survives compaction, but gets re-decided every turn |
| 5 | **Prose in a document** | read once, fades with distance |

> A directive is a decision the model must re-make every turn.
> A structure is a decision made once.

Seen that way, the strongest thing here isn't the blocking. It's rung 1. A
model pinned in an agent definition isn't so much enforced as impossible to
forget: there's no choice left to wear away on each dispatch. The gates are
how the larger idea gets enforced: take policy out of the decisions made every
turn, and only gate what has to stay a behavior. Gate the mechanics; nudge the
judgment.

This has limits. Judgment can't be gated. "Is this step reasoning or legwork?"
isn't something a machine can check, which is why task-gopher ships a
checkpoint rather than a deny. Every gate is also a tax: false positives cost
real time, and every injected directive sits in context on every request. And
while you can see the gates fire and change behavior, nobody has measured yet
whether gated delegation ends up cheaper than good prompts and nothing else.
That's still open.

## License

Copyright 2026 Jim Cline. Licensed under the [Apache License, Version 2.0](./LICENSE);
see [NOTICE](./NOTICE).
