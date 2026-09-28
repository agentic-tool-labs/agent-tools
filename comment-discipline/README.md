# comment-discipline

Stops Claude from writing comments that only make sense while the diff is on
screen:

```js
// changed from foo to bar
// NEW: added validation
// now uses the new API
// as suggested, kept this for backwards compat
// increment counter          ← above counter++
// temporary
```

Once the change merges, every one of those describes a change nobody can see
any more. Git history already records what changed. The code doesn't need to
narrate its own edit.

`/code-critic` in [github-pr-toolkit](../github-pr-toolkit/README.md) catches
these at review time. This plugin stops them being written in the first place.

## Install

```
/plugin marketplace add agentic-tool-labs/agent-tools
/plugin install comment-discipline@agent-tools
```

Then run `/comment-discipline init` (see [Setup](#setup)).

## The rule

Don't write change narration; references of any kind (ticket or issue IDs,
spec numbers, finding IDs, review-round labels, decision markers); asides
aimed at the reviewer; comments that restate the line; task narration
(`// Step 1: …`); or bare time markers.

Do write public-API behavior and contracts, and why non-obvious code is the
way it is: a workaround, an external constraint, a deliberate tradeoff. A
comment describes how the current code works, never what changed, which spec
applied, or what was decided.

Two guards keep it from backfiring.

First, it never asks you to document anything. A review lens can be purely
subtractive, but an authoring rule can't, because the model is deciding
whether to write a comment at all. Without this guard the rule turns into
defensive doc-comments added to prove compliance, which is worse than the
original problem. When in doubt, write nothing.

Second, it only covers comments you write or edit. It doesn't go cleaning up
comments that were already there. That makes for noisy diffs and is out of
scope.

Time markers are fine with a condition attached.
`// TODO: remove once the v2 endpoint lands` is good and stays. A bare `// for now` isn't, and neither is an
issue number standing in for the condition. A TODO is the one place a reminder
about a decided deferral belongs.

## When the rule is injected

A `SessionStart` hook injects the rule on `startup`, `resume`, `clear`, `fork`,
and `compact`. The last one matters most: compaction is what quietly drops a
directive mid-session and lets the old habit creep back.

## Reaching subagents

`SessionStart` only fires for the main session. A subagent isn't a session, so
that hook never runs inside one. That gap matters more here than for most
plugins, because subagents write plenty of code, and an Implementor or a
general-purpose agent is exactly who leaves `// NEW: added validation` behind.

So the rule reaches subagents two ways.

1. **When they spawn, through `SubagentStart`.** A hook injects the rule into
   the subagent's own context as it starts, before its first turn. This event
   does deliver into the subagent, but only when the hook emits a JSON
   `hookSpecificOutput` object. The same text written as plain stdout is
   thrown away silently with no error. That's the opposite of how
   `SessionStart` behaves, and it's why this channel is easy to write off as
   broken. Agent types known not to write code (`Explore`, `Plan`, a
   task-gopher runner) are skipped, so the roughly 2.4KB is only spent where
   code might get written.
2. **On the first edit, as a backstop.** A `PostToolUse` hook on
   `Edit`/`Write`/`NotebookEdit` injects the rule once per subagent.
   `SubagentStart` marks each agent it reached, so for a normal dispatch this
   hook finds the mark and stays quiet.

Before 0.3.0 the first channel was a relay clause: the directive asked the
dispatching agent to copy the rule by hand into any dispatch prompt that might
write code. That cost the parent output tokens on every dispatch, depended on
the model cooperating, and had to place its copy below any block already at the
top of the prompt so it didn't break another plugin's check for a sentinel at
the top. `SubagentStart` needs none of that, and it doesn't compete for the
`Agent` tool's input, which `task-gopher`'s relay already owns.

It has two limits.

The backstop is probably redundant now. Measured on 2026-07-29,
`SubagentStart` fires for workflow-spawned agents too, meaning agents created
without any `Agent` tool call, which a prompt-rewriting channel can't reach at
all. So the case the backstop was kept for, a spawn with no `SubagentStart`
event, may never happen. It stays for the one case that's still real: the hook
fired but couldn't save its mark. It costs one file read per edit, set against
a channel whose failures are silent.

The first edit isn't covered by the backstop, because that injection arrives
with the edit's result. `SubagentStart` is what covers edit #1, and it's the
only thing covering a subagent that makes exactly one edit.

The full design, and how to pick a channel in other plugins, is written up in
[docs/subagent-directive-relay.md](../docs/subagent-directive-relay.md).

## Sweeping what's already there

The rule only governs comments written from now on.
`/comment-discipline sweep [path]` audits the comments already in the tree. `hooks/sweep.mjs` finds
candidates deterministically: git-tracked source only, `docs/specs/**`
excluded, one regex table per kind of comment the rule forbids, with `--json`
and `--count` options. The command then judges each candidate: keep it,
rewrite it to drop just the offending part, or remove it. Past 40 candidates it
splits the judging across subagents. It reports what it found, then asks you
once: apply, show the diff first, or report only. The finder is tuned for
precision, so treat what it finds as candidates, not verdicts.

## Setup

```
/comment-discipline init        # asks: every project, or just this repo?
/comment-discipline init global # ~/.claude/comment-discipline.json
/comment-discipline init repo   # <repo>/.claude/comment-discipline.json
```

After that it just works. To turn it on or off:

```
/comment-discipline on
/comment-discipline off
/comment-discipline status
```

## Scopes

| Scope | File | Applies to |
|---|---|---|
| global / user | `~/.claude/comment-discipline.json` | every project |
| repo / project | `<repo>/.claude/comment-discipline.json` | that repo only |

Both can exist, and the project file wins, so a repo can opt out of a global
install without touching it. `on` and `off` flip the narrowest scope that
already exists, so turning it off in one repo never quietly rewrites your
global setting.

There are three states. Unconfigured shows a one-line nudge to set it up.
Enabled injects the rule. `enabled: false` stays silent, because nagging
someone to configure a thing they deliberately turned off is the annoying
failure.

A config file that isn't valid JSON is ignored with a warning instead of
crashing the hook. A hook that throws on every `SessionStart` is miserable to
track down.

## License

Apache-2.0. See [LICENSE](../LICENSE).
