# review-guide

Helps you hand a reviewer more than a diff. While you work on a branch, you
jot short notes about what each change is for and what deserves a closer look.
When you're ready to open the PR, it compiles those notes into a walkthrough
the reviewer can read top to bottom.

Under the hood it's an append-only JSONL ledger per branch, a small CLI, and a
skill. It has no hooks. Nothing is enforced and nothing runs on its own.

## Install

```
/plugin marketplace add agentic-tool-labs/agent-tools
/plugin install review-guide@agent-tools
```

## Usage

```
node "${CLAUDE_PLUGIN_ROOT}/bin/guide.mjs" note "<narration>" [--watch "<flag>"]... [path ...]
node "${CLAUDE_PLUGIN_ROOT}/bin/guide.mjs" note --skip "<why>" [path ...]
node "${CLAUDE_PLUGIN_ROOT}/bin/guide.mjs" status
node "${CLAUDE_PLUGIN_ROOT}/bin/guide.mjs" guide [--out <path>] [--pr]
```

`note` records what a change does, with optional `--watch` flags for the parts
a reviewer should look at closely. `note --skip` is for a genuinely trivial
change, like a typo: it records why the change needs no narration. `status`
shows which changes still have no note. `guide` compiles the walkthrough.

Since it never runs by itself, there are two ways to use it:

1. Run `/review-guide note ...` and `/review-guide guide --pr` yourself.
2. Give the session a standing instruction to run it before opening a PR. It
   will follow that like any other workflow habit.

Run `guide` and `status` from inside the checkout of the branch you're
compiling. Both the ledger key and the set of changed files come from the
current checkout.

[skills/review-guide/SKILL.md](./skills/review-guide/SKILL.md) describes what a
good note should contain.

## License

Apache-2.0. See [LICENSE](../LICENSE).
