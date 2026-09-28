# output-discipline

Stops command output from flooding Claude Code's context window.

Tool output gets re-sent as input tokens on every later turn of a session. One
`tail -f` or a bare `npm test` can drop thousands of lines into the context,
and you keep paying for them until the next compaction.

## How this differs from an output compressor

Tools like squeez, rtk, and headroom work at `PostToolUse`. The command runs,
prints 5,000 lines, and they shrink what lands in context. That saves real
money, but you still pay for the compressed dump, and a compressor can't turn
a foreground `tail -f` into a background task.

output-discipline works at `PreToolUse`. It stops the command before it runs
and tells Claude what to run instead. It prevents the flood rather than
shrinking it.

The two approaches work together, and running both is a good idea.

## What it does

A `PreToolUse` hook on the Bash tool refuses three kinds of command, and sends
back a message Claude reads and corrects itself from:

| Category | Examples | What Claude is told to do |
|---|---|---|
| Streaming | `tail -f`, `watch`, `--follow`, `less`, `top` | Use `run_in_background` + the Monitor tool, or a bounded `grep`/`tail -n` |
| Foreground long-runners | `npm run dev`, `vite`, `uvicorn`, `rails s` | Re-run with `run_in_background: true` |
| Verbose one-shots | `npm test`, `pytest`, `make`, `docker build` | Redirect to a file, then `grep`/`head` the interesting lines |

A verbose command goes through untouched if it already redirects (`>`), pipes
to a filter (`| grep`, `| head`, and so on), or uses `tee`. A long-runner goes
through if it's already backgrounded.

A `SessionStart` hook also puts the same rules into context at the start, so
Claude writes well-behaved commands in the first place instead of learning by
getting refused.

## Install

```
/plugin marketplace add agentic-tool-labs/agent-tools
/plugin install output-discipline@agent-tools
```

If you're working on the plugin itself, you can load it straight from a
checkout without a marketplace:

```bash
claude --plugin-dir /path/to/agent-tools/output-discipline
```

Use `/reload-plugins` to pick up edits mid-session.

## Configuration

Two environment variables, which you can set under `env` in `settings.json`:

- `OUTPUT_DISCIPLINE_DISABLE=1` turns the gate off entirely.
- `OUTPUT_DISCIPLINE_ALLOW="foo,bar"` is a comma-separated list of substrings.
  Any command containing one of them is always allowed.

To change which commands get gated, edit the `STREAMING`, `LONG_RUNNING`,
`NOISY`, and `ALREADY_TAMED` regex arrays at the top of
`hooks/pretooluse-bash.mjs`.

## When the hook breaks

It fails open. Empty stdin, malformed JSON, a payload shaped differently than
expected, or any exception inside the hook all exit 0 and let the command run.
A broken hook should never lock you out of the Bash tool.

## Layout

```
output-discipline/
├── .claude-plugin/plugin.json
├── hooks/
│   ├── hooks.json
│   ├── pretooluse-bash.mjs     # the gate
│   └── sessionstart.mjs        # injects the rules as context
└── skills/output-discipline/SKILL.md
```

## License

Apache-2.0. See [LICENSE](../LICENSE).
