# compaction-guard

Restates your standing rules after every compaction, so anything the summary
dropped is back in context before the next turn.

Losing information in a compaction is expected. Losing a rule is the case that
hurts. A dropped constraint looks exactly like a constraint that never existed.
There's no gap where it used to be, so the next turn carries on confidently
past it. "Don't do X" rules are the worst of these, because once they're gone
the path they ruled out is open again and nothing says so.

[compaction-capture](../compaction-capture/README.md) saves the summary.
This plugin deals with what the summary left out.

## Install

```
/plugin marketplace add agentic-tool-labs/agent-tools
/plugin install compaction-guard@agent-tools
```

It works fine on its own. The two other compaction plugins in this repo,
[idle-compactor](../idle-compactor/README.md) and
[compaction-capture](../compaction-capture/README.md), are separate installs.

## Usage

```
/compaction-guard            whether the guard is on here, and in which mode
/compaction-guard show       the directive exactly as it would be injected
/compaction-guard on|off     enable or disable for this repo
/compaction-guard mode default|append|replace
/compaction-guard set <file> use a file's contents as the directive
/compaction-guard reset      drop this repo's overrides
```

The directive is injected on `SessionStart` and again on `PostCompact`. Both of
those events take their context as plain stdout. Neither one reads the
structured `hookSpecificOutput` envelope, so writing JSON there injects
nothing.

`SessionStart` skips `resume`, because the restored transcript already has the
directive in it. It doesn't skip `clear`: right after a clear the context is
empty, which is exactly when a standing rule needs to be there.

## What it can and can't protect

It can protect standing directives: rules, constraints, instructions. The hook
knows that text, so it restates it word for word after every compaction. That
doesn't depend on the summarizer cooperating at all.

It can't protect in-flight task state, like which task is under way or what was
just decided. A hook has no way of knowing that, so it can't restate it. If you
want the summary to keep that, you need a `## Compact Instructions` section in
your CLAUDE.md, which is a separate and weaker mechanism.

## Why restating after the fact still helps

The `PostCompact` text lands after the summary, so it can't steer the
compaction that just happened. It does two other things. It survives into the
next compaction, since it can't be compacted away by the one that triggered
it. And it asks whether the rules governing the current work can still be
stated, which turns a loss that already happened into something the model can
say out loud instead of something silent.

## Configuration

Settings live in `~/.claude/compaction-guard/config.json`. Per-repo overrides
are keyed on the enclosing git worktree, so nothing is written into a working
tree to record a preference.

The shipped directive introduces itself as operator-configured policy. That's
on purpose. A model treats hook stdout as untrusted third-party content, and it
will discount an anonymous block of text that gives orders.

[docs/compaction-guard-design.md](./docs/compaction-guard-design.md) has the
measurements behind all of this, and the approaches that were tried and
dropped.

## Development

```
node compaction-guard/test/run.js
```

The suite runs against a throwaway `HOME`, so it never touches your real
`~/.claude`. It covers which events inject and which are skipped, the recovery
paragraph that only `PostCompact` adds, and malformed payloads. It also pins
the rule that output is plain text rather than a JSON envelope, because that
mistake fails silently.

## Uninstall

```
/plugin uninstall compaction-guard@agent-tools
rm -rf ~/.claude/compaction-guard
```

## License

Apache-2.0. See [LICENSE](../LICENSE).
