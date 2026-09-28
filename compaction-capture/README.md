# compaction-capture

When Claude Code compacts a session, the summary it writes is what the model
carries forward, and everything else drops out of its window. The summary
itself isn't lost: the transcript on disk is append-only, so it's sitting in a
`.jsonl` file somewhere. It's just hard to find. This plugin copies each
summary out to a markdown file you can actually open.

## Install

```
/plugin marketplace add agentic-tool-labs/agent-tools
/plugin install compaction-capture@agent-tools
```

Captures are off in every repo until you turn them on there.

It works fine on its own. The two other compaction plugins in this repo,
[idle-compactor](../idle-compactor/README.md) and
[compaction-guard](../compaction-guard/README.md), are separate installs.

## Usage

```
/compaction-capture on       pick a folder and start capturing, for this repo
/compaction-capture off      stop capturing
/compaction-capture status   where captures go, how many exist, whether the hook ran
/compaction-capture where    show the preset folders for this repo
/compaction-capture now      capture immediately, without waiting for a compaction
```

It runs on the `PostCompact` hook, which fires after every compaction
finishes, both when you run `/compact` yourself and when Claude Code compacts
automatically. Each compaction gets one markdown file.

The hook gets the summary in its payload, and the transcript has a matching
entry. The plugin reads both, because they aren't the same text. The payload
copy keeps the model's `<analysis>` reasoning, which the transcript entry
drops. The transcript entry has the provenance (branch, Claude Code version,
token counts) that the payload has no field for. The `source:` line in the
front matter says which copy the body came from. Either one alone is enough to
write a capture.

## Where captures go

`on` offers two presets, or any folder you name:

| Preset | Path |
|---|---|
| Inside this repo | `<repo>/.claude/compaction-captures/` |
| Shared folder | `~/.claude/compaction-captures/<repo-name>/` |

A folder inside the repo doesn't need a per-repo subfolder, since the repo
already is the scope. The shared folder sorts by repo name so different
projects don't pile up together. If you pick a folder inside your repo, you
probably want to gitignore it: captures are conversation summaries and run to
tens of kilobytes each.

Either way, your choice is stored at the user level, in
`~/.claude/compaction-capture/config.json`, keyed by repo path. Nothing gets
added to a working tree just to record a preference.

## What a capture looks like

One file per compaction, named for when it happened and what triggered it,
like `2026-08-05-223612-manual.md`. It has YAML front matter over the summary
text, word for word:

```yaml
---
captured_at: 2026-08-05T22:36:14.108Z
compacted_at: 2026-08-05T22:36:12.994Z
session: 08f958cb-bf78-45da-8c82-0992671a7dec
repo: claude-compaction-tools
branch: main
trigger: manual
pre_tokens: 242889
post_tokens: 21842
claude_code_version: 2.1.217
source: payload
chars: 19292
---
```

Fields Claude Code didn't supply are left out rather than written empty. The
token counts, for example, come from a `compactMetadata` block that not every
version emits.

The body is exactly what Claude Code wrote. No reformatting and no section
parsing, so whatever you do with it later starts from the original.

If the hook fires again for a compaction it already captured, it writes
nothing. Each session remembers the `uuid` of the last summary it wrote.

## Development

```
node compaction-capture/test/run.js
```

The suite runs against a throwaway `HOME`, so it never touches your real
`~/.claude`. It covers pulling the summary out, the per-repo location store,
the front matter, skipping duplicates, and malformed input.

## Uninstall

```
/plugin uninstall compaction-capture@agent-tools
rm -rf ~/.claude/compaction-capture
```

That leaves captures you've already written alone. Delete
`~/.claude/compaction-captures` too (and any in-repo capture folder) if you
want those gone.

## License

Apache-2.0. See [LICENSE](../LICENSE).
