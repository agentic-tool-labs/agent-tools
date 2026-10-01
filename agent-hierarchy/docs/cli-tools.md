# ah CLI reference

Every agent-hierarchy operation is a Bash call to one of two scripts this plugin ships:

```
node <AH_ROOT>/hooks/roster.mjs <verb> [args…] --cwd <absolute cwd>
node <AH_ROOT>/hooks/msg.mjs    <verb> [args…] --cwd <absolute cwd>
```

There is no MCP server as of 0.73.0 (spec 0048; it was removed because the daemon could be
"down" — `/reload-plugins` fires no SessionStart, so an in-session update left the tools
disconnected). A CLI call either runs or prints node's own error.

`<AH_ROOT>` is the plugin's installed root. Three independent channels publish it, because no one
of them covers every case:

1. **The skill and agent files name it directly.** `${CLAUDE_PLUGIN_ROOT}` is substituted at load
   time in `skills/*/SKILL.md` and `agents/*.md` as well as `commands/`, so a role's own contract
   arrives carrying the absolute path.
2. **SessionStart and UserPromptSubmit inject a root line** — `lib-config.mjs`'s `cliRootLine()`,
   one source of truth for both:

   ```
   ah CLI root (v<version>): <AH_ROOT> — roster: `node <AH_ROOT>/hooks/roster.mjs <verb> --cwd <abs cwd>`, messages: `node <AH_ROOT>/hooks/msg.mjs <verb> --cwd <abs cwd>` (verbs: agent-hierarchy/docs/cli-tools.md)
   ```

   SessionStart alone is not enough: `/reload-plugins` fires no SessionStart, so a session that
   updates mid-flight would never hear the new root. UserPromptSubmit repeats the line on every
   prompt, which covers that and survives compaction. Both use the same classification — nothing
   for subagents, nothing when the hierarchy is configured-and-disabled. The `(v…)` token is the
   plugin version that emitted the line: when two root lines in one context disagree, the most
   recent one wins.
3. **SubagentStart injects the same line into an Agent-tool subagent** — the only event that fires
   there, and it carries the line only inside its `hookSpecificOutput` envelope.
4. **Hook messages** that tell a role to run something spell the absolute command.

If all four somehow failed you, resolve the root — do not guess it, and never glob the cache dir
(several versions coexist there):

```
node -e 'const p=require(process.env.HOME+"/.claude/plugins/installed_plugins.json").plugins,k=Object.keys(p).find(x=>/^(ah|agent-hierarchy)@/.test(x));console.log([].concat(p[k])[0].installPath)'
```

The key is `ah@<marketplace>` (or `agent-hierarchy@<marketplace>`) and its value is an **array** of
install records — hence `[].concat(p[k])[0]`.

## Invocation rules

- `--cwd <absolute path>` on every verb. The CLIs resolve the hierarchy dir, the git root and the
  worktree/main-checkout relationship from it; a relative path or a missing one is a bug in the
  caller, not a default.
- One simple command. No `cd … &&` prefix, no `VAR=1` prefix, no pipe, no redirection, no `$VAR`
  and no command substitution — `--cwd` and `--orchestrator-pid` exist precisely so nothing needs
  shell expansion. The permission hook below recognises only this form.
- JSON arguments (`--args`, `--verified`, `--created`, `--geometry`) travel **single-quoted**.
- Output is always JSON. A non-zero exit means the JSON or the stderr line says why. Exit 3 is a
  *partial* result (`layout-splits`, `create`): real work happened, not all of it — read the JSON.
- `--help`, or no verb at all, prints the script's usage block and exits 0.
- Identity: both CLIs resolve the orchestrator session pid from `--orchestrator-pid` if given,
  else `CLAUDE_PID`, which every Claude Code session exports into the Bash tool's environment.
  The documented form omits the flag; tests, a human shell, and `adopt` (which requires it) use it.

## Permission

The plugin ships a PreToolUse hook (`hooks/pretooluse-ah-cli.mjs`) that returns `allow` for these
two scripts, so ah calls raise no Bash permission prompt. It allows only the grammar above, only
when the script's realpath is under the hook's own installed root or a sibling of it, and never for
a `dismiss`/`disband … --close` command — those stay behind the always-ask close gate
(`hooks/pretooluse-disband-close-gate.mjs`), which prompts every single time. The roster skill
gate's one-per-session `deny` also outranks the `allow`.

Posture: this grants prompt-free execution of two scripts the plugin itself ships, with arguments
restricted to that grammar. The remaining state-changing verbs (`untrack --commit`, `reap
--commit`, `create --commit`, `remove`) are bookkeeping on ah's own state files and were
auto-allowed as MCP calls too.

If you run without plugin hooks, allowlist the two scripts yourself in **user** scope
(`~/.claude/settings.json`) — user, not project, because the path lives under
`~/.claude/plugins/cache` and the rule has to survive version bumps:

```json
{
  "permissions": {
    "allow": ["Bash(node */hooks/roster.mjs *)", "Bash(node */hooks/msg.mjs *)"]
  }
}
```

Spell them exactly like that: the leading `node ` with its space is what keeps a `nodejs-foo`
binary from matching.

## Reading the roster

To inspect the roster run `node <AH_ROOT>/hooks/roster.mjs show --cwd <abs cwd>`; never read
`.claude/agent-hierarchy.json` directly — it misses the worktree/main-checkout and global fallback
resolution that `show` implements.

Write verbs refuse (exit 2) a level file that exists but isn't a JSON object, an empty file
included, and leave it untouched — fix or delete it, then re-run. `untrack` and
`dismiss --also-config` instead warn, leave the file, and finish. Read verbs ignore such a file, as
before.

## After an update, mid-session

`/reload-plugins` fires no SessionStart, so nothing re-announces the root at update time — but the
UserPromptSubmit hook re-states the `ah CLI root:` line on your next prompt, and after a reload that
line comes from the NEW version dir. Take the most recent one in context. Until then the old CLI
keeps running from the old version dir (they coexist under the cache) — stale code, still working.
If the old dir is gone, node says `Cannot find module …/hooks/roster.mjs`; send another prompt and
read the fresh root line, or resolve it with the recipe above.

## Verbs

`--cwd <abs>` is required on every line below and elided from the table. `<R>` = `<AH_ROOT>`.

| verb | command |
|---|---|
| new message file | `node <R>/hooks/msg.mjs new --to <role> --from <role> --slug <s> [--to-name <n>] [--from-name <n>] [--parent <id>] [--reason context\|second-opinion\|parallel] [--eta small\|medium\|large] [--type request\|response] [--id <id>] [--team <t>] [--req <abs request path>]` |
| list exchanges | `node <R>/hooks/msg.mjs list [--open\|--closed\|--all] [--to <role>] [--team <t>] [--plain]` |
| downstream dispatches | `node <R>/hooks/msg.mjs downstream [--root-name <n>]` |
| index one message file | `node <R>/hooks/msg.mjs index <abs path>` |
| message roster line | `node <R>/hooks/msg.mjs roster [--team <t>]` |
| sweep closed exchanges | `node <R>/hooks/msg.mjs sweep [--days 7]` |
| log a /pipeline decision | `node <R>/hooks/msg.mjs decision add --team <t> [--input <path>]` with one JSON object in the `--input` file, else on stdin. The skill always writes `<hier>/pipeline/<anchor id>/decision-input.json` with the Write tool and passes it as `--input`: a pipe or heredoc never runs prompt-free. The input file must be a regular file of at most 64 KiB whose real path is inside that run directory, holding one JSON object; it is never deleted. Then it appends one line to the run's log, `<hier>/pipeline/<anchor id>/decisions.jsonl`, and prints `{id, path, counts}`. The run is the team's one open `pipeline-run-anchor` exchange; none or several → exit 2. Fields: `kind` (`decided`\|`parked`), `item` (a slug or `run`), `source`, `question`, `options` (2–4 strings, lettered a–d), `default` (a letter or null), `choice` (a letter within `options` or `other: …`; null when parked), `decider` (`{role, name, model}` and no other key, `role` matching `^[a-z0-9-]+$`; null only on a parked line), `rationale`, `revert` (strings), `review`, `dangerous` (booleans), `why_user` (`dangerous`\|`unsure`\|`cap`; null when decided), `exchange` (a request id or null). The writer adds `id` (`d<k>`, counting only decided and parked lines), `time`, `run`, `decision` (the chosen option's text) and `qkey` (first 12 hex of sha256 of the item and the trimmed, lowercased, whitespace-collapsed question). Refused, exit 2 with `{refused, reason, detail}` on stdout and nothing written: a missing, mistyped or unknown field, or any writer-owned field supplied; `kind: merge`; a decided line that is dangerous, has the user as decider, has a `why_user`, chooses off the list, or answers `other: …` without `review: true`; an `--input` file outside the run directory, not a regular file, over 64 KiB or not one JSON object; a parked line with a choice or no `why_user`; `dangerous: true` with a `why_user` other than `dangerous` (all reason `invalid`); a decided line for a question already parked in the run (`parked-before`) or already decided (`decided-before`, naming the earlier `d<k>`); a decided line over 4 for its item or 20 for the run (`cap`) |
| read a /pipeline decision log | `node <R>/hooks/msg.mjs decision list --team <t> [--run <anchor id>] [--item <slug>] [--summary]` — the open run's log, or with `--run` that run's, open or closed: `{run, path, decisions, skipped}` in file order. Every valid line is listed with its `kind`; a line that won't parse (a torn last line) is skipped and counted. `--summary` prints `{decided, flagged, parked, by_item, skipped, line}` instead, `line` reading e.g. `decisions: 7 decided (2 flagged), 1 waiting for you`; lines of other kinds count nowhere. No open run and no `--run`, or an unknown `--run`, → exit 2 |
| show roster | `node <R>/hooks/roster.mjs show [global\|repo\|repo-user] [--level <L>] [--roster <r>]` — members are shown under the default team name; when a team could not use that name, a `team_name_note` says so |
| list teams | `node <R>/hooks/roster.mjs teams [--orchestrator-pid <pid>]`. The top-level object carries the same `sources` block as `disband`; `untracked_live` rows from `herdr agent list` alone are marked `source: "herdr"`. An orphaned team's row adds `live_members: [{name, role, last_brief_from}]`, its records that are live (one whose liveness cannot be decided is listed with `indeterminate: true`), and `attributed_live: [{name, role, pane_id, last_brief_from}]`, its `untracked_live` rows: live sessions that claim it through their team file or a `<t>-` Herdr name and match no record (never for the legacy `team.json`: an untagged row and the repo-basename prefix are no claim on it). Each is absent when empty. `last_brief_from` is best-effort: the `from_name` (else `from`) of that session's latest peer-pending row, else null. |
| init roster level | `node <R>/hooks/roster.mjs init [level] [--level <L>] --route peer\|pane [--roster <r>]` — `--route subagent` exits 2: only legwork roles run as subagents, so route an individual legwork member instead |
| add roster member | `node <R>/hooks/roster.mjs add [level] [--level <L>] [--roster <r>] --role <R> [--model <M>] [--effort <E>] [--route peer\|subagent\|pane] [--kind <K>] [--args '<json>'] [--auto-mode <A>] [--on-missing auto]` — `--route subagent` only for a legwork role (else exit 2); `--on-missing` is `auto`, its default and only value; a model and an effort are stored only when given, so a member added without `--model` is asked for one when it is spawned |
| edit roster member | `node <R>/hooks/roster.mjs edit [level] [--level <L>] [--roster <r>] --member <name> [--role <R>] [--model <M>] [--effort <E>] [--route …] [--kind <K>] [--args '<json>'] [--auto-mode <A>] [--on-missing …]` — `--model ""` and `--effort ""` clear the field |
| remove roster member | `node <R>/hooks/roster.mjs remove [level] [--level <L>] [--roster <r>] --member <name>` |
| list named rosters | `node <R>/hooks/roster.mjs roster list [--json]` — read-only. The `selection`, then the default block and every `rosters.<name>` key visible from cwd, each with the level and path that win (the first with members, else the most specific), the levels it is `shadowed` at, its member count and route, whether it is `selected`, and the `teams` whose file records it (this checkout's hierarchy dir and, from a worktree, the main checkout's). A legacy `rosters.default` block is listed with a `note`: it can't be selected or copied. Human text without `--json`. |
| copy a roster | `node <R>/hooks/roster.mjs roster copy <src> <dst> [--level <L>] [--dry-run]` — copies `src` (`default` = the unnamed block) to `rosters.<dst>`, `route` and `members` as stored, at `--level` (default: the level `src` resolves at). Refuses an undefined `src`, a `dst` that is `default` or not a valid name, and a `dst` already defined at that level — in any file at that level, so from a worktree the main checkout's counts too; the refusal names that file. This is how a roster is made from another; `init --roster` makes an empty one. |
| delete a roster | `node <R>/hooks/roster.mjs roster delete <name> [--level <L>] [--dry-run]` — removes the `rosters.<name>` key at `--level` (default: the level it resolves at). Refuses `default`, a name any team file here or in the main checkout records (a legacy team keyed by its own name counts; disband or reap it first), and a name `activeRoster` in the same file selects. Warns, and deletes, when `activeRoster` at another level selects it. From a worktree, a block only the main checkout's file holds at that level is refused, naming that file and the `--cwd <main checkout>` to run it with. |
| select a roster | `node <R>/hooks/roster.mjs roster use <name>\|default [--level <L>]` · `… roster use --clear [--level <L>]` — writes (or removes) `activeRoster`, at `repo-user` by default inside a git repo, else `global`. Refuses a name no visible level defines, `default` aside. Warns, and still writes, when the target level's readers can't see the roster: `--level global` when the global file doesn't define it (other repos), `--level repo` when only repo-user or global does (others in the repo); `repo-user` never warns. `--clear` deletes a file left with no keys. Prints the resulting `selection`. |
| create a team | plan: `node <R>/hooks/roster.mjs create [--plan] [--team <t>] [--roster <r>] [--mode auto\|columns\|grid] [--roster-level <L>]` · spawn: `… create --spawn [--team <t>] [--roster <r>] [--mode auto\|columns\|grid] [--roster-level <L>]` · commit: `… create --commit --verified '<json>' --transport <t> --roster-level <L> [--team <t>] [--roster <r>] [--mode auto\|columns\|grid] [--partial] [--session <orchestrator session id>] [--orchestrator-pid <pid>]` · from history: `… create --from <id\|alias> [--team <t>] [--mode …] [--plan\|--commit\|--spawn]`. `--team` is the team's name (default: the repo basename, or a legacy `team.json`'s own prefix); `--roster <r>` builds it from `rosters.<r>` (default: the `roster` block) and a missing block is an error; a `rosters.<t>` block matching `--team <t>` without `--roster` is only warned about (`warnings`). `--mode` defaults to the global `teamLayout` (`~/.claude/agent-hierarchy.json`), else `auto`; a plan reports `layout: {mode, source}` with source `explicit` \| `stored` \| `default`, and an explicit `--mode` on `--spawn`/`--commit` is stored as `teamLayout` for future teams (`--plan` stores nothing). The committed team file records `roster` (the block key, `null` for the default) and `layout`. A roster-driven plan lists `named_rosters` (the valid `rosters.*` keys at every level, sorted) when there are any. Config keys that no longer do anything — `teamAlias`, a roster block's `layout`, a `teamLayout` outside the global file — are reported in every phase's `warnings` (and by `doctor` and `/hierarchy status`), never in session context. A name that cannot be used gets the `team-name-unusable` refusal below. Every phase also takes `--member-model <name>=<model>` (repeatable: the model that member runs on this time, never written to the roster); an unknown or repeated name, a non-claude member, or a model its class does not allow exits 2. A plan lists `members_needing_model` (last) when a launched member has no model — entries shaped as in the `member-model-undefined` refusal below — and never refuses on models; `--spawn` refuses. A claude-kind legwork member with no model is skipped while task-gopher is installed (per `installed_plugins.json`): it is not launched, listed or recorded, never makes the team `partial`, and every phase reports it in `skipped_members: [{name, role, handoff: "task-gopher:task-gopher"}]` with a `message` — its legwork goes to task-gopher subagents. `--no-legwork-handoff` (every phase) counts task-gopher as not installed, so such a member is listed for a model like any other; a driver that cannot dispatch `task-gopher:task-gopher` passes it. Every phase also takes `--names-in-use <name>` (repeatable): a live session name the driver saw in `ListAgents`, `[ref]` stripped — the CLI reads no session names of its own. A member whose name exactly matches one is renamed to the first free `<team>-<role>-<n>` and listed in `renamed_members: [{name, role, renamed_from}]` (present only when a member was renamed); `--commit` re-derives the renames from its own `--names-in-use` and records `renamed_from` on each renamed member. `--partial` is accepted and does nothing: whether a team is partial is derived when it is shown (a pane-route roster member `create` would launch that has no record, by name or `renamed_from`) and never stored. |
| adopt an orphaned team | `node <R>/hooks/roster.mjs adopt --orchestrator-pid <pid> [--team <t>]` |
| reap orphaned records | `node <R>/hooks/roster.mjs reap [--commit]`. The plan's `orphans` carry `live_members` and `attributed_live` as in `teams`. `--commit` clears an orphan only when it has neither; any other is kept and listed in `kept: [{team, live_members?, attributed_live?, next, why}]` (present only when non-empty). With `live_members`, `next` is the `adopt` command for the invoking pid (null when none resolves); with only `attributed_live`, `next` is null — adopting would relaunch its dead records beside the live sessions. |
| herdr layout phase | `node <R>/hooks/roster.mjs layout-splits --mode <m> --pane-count <n> [--self <id>] [--next --created '<json>'] [--apply --target <pane id> --direction right\|down]` — exit 3 = partial, read the JSON |
| disband a team | plan: `node <R>/hooks/roster.mjs disband [--plan] [--team <t>]` · close: `… disband --close --confirm --plan-token <tok> [--allow-global] [--team <t>]` (`--allow-global` is an accepted no-op). Every plan and close result carries `sources` — which of team file / peers.jsonl / `herdr agent list` was consulted, what each yielded, and the name prefix searched under. A plan also carries `next`: the exact close command to run once the user agrees (absolute path, `--confirm --plan-token`, plus `--team`/`--cwd` as given and `--allow-global` only when the close would demand it) — copy it, assemble nothing. A close result adds `pruned: [name…]` (a nameless row appears as its role), `kept: [{name, why}]` (`why` ∈ `added` \| `close-failed` \| `live` \| `indeterminate`), `team_removed`, and `team_file` (`null` when no team file was involved): `--close` reconciles the team file itself, so no bookkeeping call follows it. Top-level `closed` is true iff every close that was attempted succeeded (vacuously true when nothing was closable); whether every member is gone is what `pruned` / `kept` / `team_removed` report. The resolved team file, when it exists but does not read as a team record (unparseable, or parsing to something with no `members` array), is reported as `team_file_unreadable: <path>` and is never written or removed. A plan always carries `next`, even when no member has a pane: running it then closes nothing and still reconciles the record. |
| resync member locations | `node <R>/hooks/roster.mjs resync [--dry-run] [--team <t>] [--bind <b>]` |
| move a member's pane | `node <R>/hooks/roster.mjs move <name> --tab <t> [--split right\|down]` · `… move <name> --new-tab [--workspace <w>]` · `… move <name> --new-workspace` · all take `[--dry-run] [--allow-global] [--team <t>]` (`--allow-global` is an accepted no-op) |
| team history | `node <R>/hooks/roster.mjs history` |
| spawn one roster member | `node <R>/hooks/roster.mjs spawn-one <role> [--member <name>] [--model <M>] [--stream <s>] [--dry-run] [--allow-global] [--team <t>] [--orchestrator-pid <pid>] [--names-in-use <name>]` — `--stream` joins stream `<s>` (see the stream rows below); `--model` launches the member on `M` this time only (a member with no model stored needs it: `member-model-undefined` below); `--names-in-use` renames as `create` does, across the role's roster members: each first takes its team record (one renamed away from its derived name, then one under it), a record found not live whose name is in use is renamed in place, and `--member` matches the final names; not skill-gated; `--allow-global` is an accepted no-op — under Herdr the member name must be `[a-z][a-z0-9_-]`, at most 32 characters; a longer one is refused before any pane opens |
| spawn an ad hoc member | `node <R>/hooks/roster.mjs spawn-ad-hoc <role> [--model <M>] [--effort <E>] [--kind <K>] [--route peer\|pane] [--args '<json>'] [--auto-mode <A>] [--on-missing …] [--stream <s>] [--dry-run] [--allow-global] [--team <t>] [--orchestrator-pid <pid>] [--names-in-use <name>]` (`--role <role>` is accepted in place of the positional; `--names-in-use` renames the derived name as `create` does; `--stream` joins stream `<s>`, see below) — no roster needed; not skill-gated; global roster ignored (`--allow-global` accepted, no-op) — under Herdr the member name must be `[a-z][a-z0-9_-]`, at most 32 characters; a longer one is refused before any pane opens |
| open a stream | `node <R>/hooks/roster.mjs stream-open <name> [--branch <b>] [--base <ref>] [--no-worktree] [--dry-run] [--team <t>] [--orchestrator-pid <pid>]` — records `streams.<name>` in the team file (creating the team, owned as `spawn-ad-hoc`'s would be, when there is none) and spawns nothing. Unless `--no-worktree`, adds the worktree `<main checkout>/.claude/worktrees/<name>` on branch `--branch` (default `<name>`) off `--base` (default `main`), reusing it when it is already that worktree; under herdr, opens a tab labelled `<glyph> <name>` in the caller's workspace without focus. Re-running is idempotent (`existed: true`); on a done stream it re-opens it (`reopened: true`). Output: `{opened, existed, reopened, stream: {name, state, branch, base, worktree, tab_id, opened}, label, worktree_created, branch_created, transport, degraded?, warnings?, next}` — `next` is the two spawn commands. A failed tab create keeps the worktree, records `tab_id: null` and warns; the next `stream-open` retries it. tmux/terminal: no tab, `degraded: "no-tabs"`. `--dry-run` prints `would_run: {git, herdr}` and the `stream` it would record, and executes and writes nothing. Refusals (exit 2, `ok: false`): `stream-name-invalid` (the name must match `^[a-z][a-z0-9_-]{0,39}$`), `worktree-path-occupied`, `branch-in-use` (checked out in another worktree; `detail` is git's stderr), `git-failed` (`detail`); nothing is written on any of them |
| join a stream | `spawn-one <role> --stream <s>` / `spawn-ad-hoc <role> --stream <s>` — without `--stream` both verbs are unchanged. Under herdr the pane goes into the stream's tab: the first member launches into the tab's own pane, later ones split from the earliest-joined stream member in that tab, with the team's layout mode. A stream with no live tab gets one first. The member row gets `stream: "<s>"`, and the tab's id as `tab_id` when the launch reports none; the peer's cwd stays the team's `expected_root`, never the worktree. Output adds `stream: {name, worktree, branch, label?, warnings?}`. Refusals, before any pane opens: `unknown-stream`, `stream-done` (`next`: the `stream-open` that re-opens it), `stream-tab-unavailable` |
| stream board | `node <R>/hooks/roster.mjs stream-status [<name>] [--plain] [--team <t>]` — never writes the team file; re-renders each open stream's tab label. Output: `{team, transport, streams: [{name, state, label, tab: {id, live}\|null, branch, base, worktree: {path, exists}\|null, opened, closed?, peers: [{name, role, status, pane_id, tab_id, in_stream_tab}], exchanges: [{id, slug, to_name, from_name, age_sec}], waiting_on: [{on, request, age_sec}]}], degraded?}`, open streams first, then done, each by `opened`. `status` is herdr's `agent_status` (`working`, `idle`, `blocked`, `done`, `unknown`) or `gone`; `exchanges` are the open ones a stream member sent or owes, `waiting_on` one per exchange, `on` its `to_name`. tmux/terminal: `status: "unknown"`, `label` and `tab` null, no herdr call. `--plain`: one line per stream. An unknown `<name>` is `unknown-stream` |
| wrap up a stream | `node <R>/hooks/roster.mjs stream-done <name> [--dry-run] [--team <t>]` — sets `state: "done"` and `closed`, and labels the tab `✓ <name>`. Closes no pane and removes no worktree or branch. Output: `{done, already_done, stream, label, members, open_exchanges, next, warnings?}` — `next` is a `dismiss` per member, for when the user asks; `open_exchanges` is advisory. Idempotent (`already_done: true`). A tab that is gone is a warning. `--dry-run` writes and renames nothing. Unknown name: `unknown-stream` |
| re-render a stream label (hook) | `node <R>/hooks/roster.mjs stream-label <name> [--self-pane <id> --self-state working\|idle\|blocked] [--team <t>]` — what `hooks/stream-label.mjs` runs; harmless by hand. `{rendered: true, label, previous?}`; an unknown or done stream, a stream with no tab or a gone one, or a non-herdr team is `{rendered: false, reason}`, exit 0 |
| dismiss one member | plan: `node <R>/hooks/roster.mjs dismiss <name> [--plan] [--team <t>]` · close: `… dismiss <name> --close --confirm --plan-token <tok> [--also-config] [--level <L>] [--allow-global] [--team <t>]` (`--allow-global` is an accepted no-op). Plans and close results carry the same `sources` block as `disband`, and a plan carries the same `next` close command. With no team file (for instance right after `disband --close` removed it): exit 0 with `dismissed: false, reason: "no active team and no live peers"` when the peer registry offers no closable session; exit 2, listing the live untracked sessions and the name / pane_id / session_id values `dismiss` accepts, when it does. A plan for the team's last member adds `team_will_be_removed: true`; closing it removes the team file and adds `team_removed: true`. |
| untrack (close nothing) | `node <R>/hooks/roster.mjs untrack <name>\|--all [--plan\|--commit] [--keep-sessions] [--also-config] [--level <L>] [--team <t>]`. Idempotent: with no team file it exits 0 with `untracked: false, already_untracked: true, reason: "no team file to forget"`. Untracking the last member removes the team file and adds `team_removed: true` beside `team_empty`. |
| re-register this session | `node <R>/hooks/roster.mjs checkin [--team <t>] [--orchestrator-pid <pid>]` — the output carries `team` when this session is attributed to one (`null` for a legacy `team.json`); a create commit refuses a verified member object whose `team` is not the team being committed |
| who am I / where is my orchestrator (peer) | `node <R>/hooks/roster.mjs whoami [--team <t>]` — read-only, writes nothing, exit 0 whenever the lookup ran. Matches this session's pane id (`HERDR_PANE_ID`, else this pid's `peers.jsonl` row, else `TMUX_PANE`) against every team record, or only `--team`'s. A launched member knows its team first from `AH_TEAM_FILE`, which the launcher sets on every member it starts; the pane match is the fallback. The path alone names the team, whether or not its file exists (a member starts before `create --commit` writes it, and outlives a reap, disband or untrack that removes it); with no file there is no record, so `member` is `null` and `reason` is `no-team`. Output: `member: {name, role, route}\|null`, `team` (`null` for the legacy `team.json`), `team_file`, `orchestrator: {pid, session_id, live, send_to}\|null`, `answered_by`: `env` \| `pane` \| `null`, `reason`: `null` \| `no-pane-id` \| `no-team` \| `not-a-member` \| `ambiguous` (then `candidates: [{team, name}]`). An `AH_TEAM_FILE` that is not a team file of this repo is never followed; it is reported, beside that real outcome, as `env_team_invalid: {value, kind, why}` with `kind` `other-repo` (a well-formed team file of another repo's hierarchy dir) or `malformed`, and is absent when the variable is unset or accepted. `session_id` is passed through as recorded, and is `null` on every path the agent-team skill uses. `send_to` is usable directly as SendMessage `to`, but is best-effort — derived from the pid, non-null only while the orchestrator is alive and its session socket exists. Reply precedence: the brief's `reply-to` (or the orchestrator's session name from `ListAgents`) is authoritative — see [comms-protocol.md](comms-protocol.md); `send_to` is the fallback when that is lost. The socket directory follows this session's own `CLAUDE_CODE_MESSAGING_SOCKET` when the harness exports it (else `/tmp/cc-socks`); the real directory is harness-owned, so `send_to` stays best-effort. Every output, whatever its `reason`, also carries `last_observed_brief: {from, from_name, reply_to, ts}\|null` — the last obligation row a hook filed for this session in `~/.claude/agent-hierarchy.peer-pending.jsonl`, any status, with `from_name` `null` when none was recorded. These values are observed, not verified: they say who last briefed this session, which can differ from the recorded `orchestrator`, and like `send_to` they are a fallback below the brief's `reply-to` and the `ListAgents` name. `null` is the expected value, not a failure, in two cases: no session id resolves (`CLAUDE_CODE_SESSION_ID`, else the `session_id` on this pid's `peers.jsonl` row), or no row exists — only a sentinel or `[hierarchy-msg …]` brief files one, a plain cross-session message does not, and its absence does not make the session unaddressable. It never changes `reason`. |
| brief a non-claude pane member | `node <R>/hooks/roster.mjs deliver <name> --req <abs request path> [--ping <n>] [--wait-only] [--timeout <s>] [--team <t>]` — run it in the background. Creates (or reuses) the response file beside the request, sends `[hierarchy-msg <req>]`, `Report to: <response>` and the member's standing-instructions path (a ping sends `Ping <n>/3: …`; `--wait-only` sends nothing and only waits), and waits for the turn to end. A member that is working or not ready is waited for first, polling, and both waits share one `--timeout` deadline (default 1800 s). Exit 0 with `{status, sent, name, request, response, agent_status}`; `status` is `reported`, `no-report`, `malformed-report`, `busy` (still working or not ready at the deadline; nothing sent: re-run the same command), `blocked`, `not-live`, `indeterminate`, `timeout` or `not-sent` (`--wait-only` found no response file). `sent` is true only when this run sent its brief or ping, never under `--wait-only`. A report is judged against the body the response file is created with, trailing whitespace aside. `no-report` and `timeout` carry `pane_tail`. `not-live` carries `spawn`: `spawn-one <role> --member <name>` when a roster row derives the name, else `spawn-ad-hoc` with the member's recorded fields and a `spawn_note` that the name may differ. `blocked` carries `blocked_by` (`trust-dialog`, `login`, `approval`, else `harness-prompt`), `screen` (the member's visible screen, verbatim), `screen_hash`, `options` (`[{id, label, description, grants}]`, only those the recognised option block reads; `[]` for `harness-prompt`) and a `message` with the relay steps. Nothing is sent to a member that is working, not ready or at a prompt, and a codex member is sent a brief or ping only while its screen is Codex's idle, empty composer: any other screen, read twice, is `blocked` with `harness-prompt` and `options: []`. `--wait-only` sends nothing and has no composer check. A Claude member, or a name the team does not hold, exits 2; so does an advise-class member when this session has no `session`/`each` Ultra-Advisor decision on record |
| answer a member's prompt | `node <R>/hooks/roster.mjs answer <name> --prompt <blocked_by> --choice <id> --screen-hash <hash> [--team <t>]` — only after asking the user. Sends that option's keys from the kind's table, and only when one `visible` read still shows that prompt with that hash and that option. Exit 0 with `status`: `answered` (`agent_status`, `live`, `prompt_after`, `screen`), `screen-changed` (fresh `blocked_by`, `screen`, `screen_hash`, `options`; nothing sent), `not-live` or `indeterminate`. Takes no keys and no text. Exit 2 for a Claude member, an unknown `--prompt` or `--choice`, or an option not on the screen |
| declare a non-Claude model's tier | `node <R>/hooks/roster.mjs tier set <kind> <model> <haiku\|sonnet\|opus\|fable>` · `… tier remove <kind> <model>` · `… tier list` — how that model compares with Claude's tiers, stored only in the global config's `modelTiers`. `list` also carries `warnings` for entries it ignores (kind `claude`, or not a tier). An advise-class member of a kind with a model mapping must run on a model declared `opus` or `fable` |
| list roles | `node <R>/hooks/roster.mjs role list [--json]` — every built-in and custom role: class, agent, model, level, chain placement (`alt. to <Builtin>: <routes>`, `side`, `legwork`), effective description, and contract status (`shipped`, `ok`, `n warnings`, `UNAVAILABLE: n errors`, or `UNAVAILABLE → reverted to ah:<role>` for a failing built-in override). Invalid rows are listed as `excluded` with their reasons. `--json` adds each role's findings, and `path` names the agent-file copy that was checked. A role adopted from a role pack also shows `from` and its `pin_state` (`trusted`, or its pack reason: `pack-missing`, `pack-invalid`, `pack-ambiguous`, `pack-symlink`, `pack-changed`, `pack-untrusted-here`), and a built-in whose agent a pack overrides has `pack_override: true`; rows without either are unchanged. |
| define or change a role | `node <R>/hooks/roster.mjs role set <name> [--class advise\|design\|review\|implement\|legwork] [--agent <ref>] [--label <l>] [--description <d>] [--routes <r>] [--model <M>] [--dispatch peer\|model] [--level global\|repo\|repo-user] [--scaffold repo\|user] [--dry-run]` — upserts one row at one level (default: the level the role is already defined at, else `repo` with `--scaffold repo`, else `global`), seeded from the effective row. A built-in takes only `--agent`, `--model` and `--dispatch`. `--dispatch model` only for a legwork-class role (else exit 2). `--routes ""` / `--description ""` delete the key. The agent file is validated against the class contract: errors refuse the write and print each finding with its fix; warnings print and the write proceeds. `--scaffold` writes a template that passes the contract, and removes it again if the write fails. `--dry-run` writes nothing. |
| remove a role | `node <R>/hooks/roster.mjs role remove <name> [--level <L>]` — refused while any roster member uses the role; never deletes an agent file. For a built-in, removes only its `agent` override (a pack override's `from` and `pin` too). |
| adopt a role from a pack | `node <R>/hooks/roster.mjs role set <name> --from <plugin>@<marketplace>:<role> [--label <l>] [--description <d>] [--routes <r>] [--model <M>] [--dispatch …] [--level <L>] (--dry-run \| --pin sha256:…)` — `<plugin>:<role>` works when exactly one marketplace offers the plugin. The dry run prints `pack.fields` (verbatim, hidden characters escaped), the findings (contract, pack-agent frontmatter allowlist, pack reasons), `pack.tools` (`effective`, and `flagged`: Bash, Agent, MCP tools, Write, Edit), `pack.also_in_plugin`, `pack.unattended` for an implement-class role with routes, and `pin`. The commit needs `--pin` equal to the pin computed now, refuses while errors stand, writes only `from`, `pin` and the flags passed, and stores a copy of what was pinned in `~/.claude/agent-hierarchy/trusted/`. `--class`, `--agent` and `--scaffold` are refused with `--from` and on any adopted row; a name already defined at the level by another row is refused. A built-in name takes the pack role's agent only, and only from a role of its class. A commit is asked of the user in a top-level session and denied in subagent, role and peer sessions, with `AH_TEAM_FILE` set, and while a pipeline run is live; a Bash command that isn't one plain ah command is judged as a commit when its text names `roster.mjs`, then `role`, then `trust` or `--from`, even with `--dry-run`. roster.mjs itself refuses a commit (exit 2, nothing written) when `AH_TEAM_FILE` is set, or while a pipeline run is live for `--cwd` or its own working directory. The spawn verbs refuse a member of a pack role whose auto mode is `bypassPermissions` or unset. |
| re-trust a pack role | `node <R>/hooks/roster.mjs role trust <name> [--level <L>] (--dry-run \| --pin sha256:…)` — for a row set with `--from`. The dry run shows `fields_changed`, `agent_diff` and `files` (`added`, `removed`, `changed`) against this machine's stored copy — or, with none (`stored_copy: false`), the whole `agent_text` and `files.all` — plus the findings and `pin`. The commit needs that pin, refuses while errors stand, re-pins, keeps the user's own fields, and is gated like adoption. |
| list role packs | `node <R>/hooks/roster.mjs pack list [--json]` — read-only: every installed plugin with `ah-roles.json`, its version and path, its roles (name, class, agent, routes), each role's adoptions (`name`, `level`, `state`), and a count of what else the plugin carries. |
| show one role pack | `node <R>/hooks/roster.mjs pack show <plugin>[@<marketplace>] [--json]` · `… pack show --path <dir> [--json]` (not installed) — read-only: the manifest's findings, each role's fields verbatim with its findings and tools, its adoptions (installed only), `also_in_plugin` (root entries other than `ah-roles.json`, `agents/`, `.claude-plugin/` and README/LICENSE/CHANGELOG files; plugin.json keys beyond the descriptive ones; agent files the manifest doesn't name; any agent file that takes a role's agent name, marked `claims: [<role>…]`), and `digest`, the sha256 of the file list, which is the same for the same tree installed or not. |
| self-check this install | `node <R>/hooks/roster.mjs doctor [--check]` — read-only JSON, one row per thing that can be wrong; `--check` exits 1 on any red row |
| split decision (tests) | `node <R>/hooks/roster.mjs next-split --mode <m> --pane-count <N> --self <pane id> --created '<json>' --geometry '<json>'` |
| route | `node <R>/hooks/msg.mjs route [peers] --session <id>` — prints the session route, always `peers`: chain roles run only as peers. Any other value exits 2 |
| push-guard check | `node <R>/hooks/pretooluse-push-guard.mjs check --branch <name>` — runs the push guard's own evaluation for pushing `<name>` to `origin/<name>` and pushes nothing. Prints one JSON object, exit 0: `opted_in`, `default_branch` (string or null), `conventions` (`"ok"`, `"absent"` or `"invalid: <why>"`), `range` (`<base>..<name> excluding <origin-default>` — commits already on the default branch are never counted, and a merge counts only paths that differ from every parent), `protected_hits` (every protected path touched in the range), `branch_protected`, and last `settings`: when `conventions` is `"ok"`, the file's team settings with the schema defaults applied — `pr` (`draft`, `issue_link`, `reviewers`, `merge_method`: `"merge"` when undeclared, else `"squash"` or `"rebase"`), `ci_secrets` (`"none-on-branches"` when undeclared), `protected_paths` and `protected_branches` (the file's own extensions, never the baseline), `on_item_done` (null when absent); `version` and `issues` are left out. Otherwise `settings` is null. `--branch HEAD` means the current branch; on a detached HEAD, and in a repo that has not opted in, `range` is null, `protected_hits` `[]` and `branch_protected` false. Error (not a repo, a branch that does not resolve): exit 1 with `{"error": "..."}`. Conventions and the guard: [pipeline-conventions.md](pipeline-conventions.md). |
| push-guard merge-check | `node <R>/hooks/pretooluse-push-guard.mjs merge-check --pr <N> --cwd <root>` — read-only and advisory: whether the open /pipeline run may offer PR <N> for its pinned merge. Writes nothing. Prints `{ok, pr, sha, method, reasons, command}`, exit 0; `ok` is true when `reasons` is empty, and `command` is the exact pinned form, `gh pr merge <N> --match-head-commit <sha> --<method>`, behind `gh pr ready <N> && ` for a draft. Reasons: `no-run` (no single open run anchor), `off` (`merge-opt-in` isn't `yes`), `no-method` (no valid `merge-method` in the anchor), `not-this-run` (the head isn't `ah/issue-<I>` with an open item record under the run's tag), `not-signed-off` (no answered `<tag>-i<I>-ok`), `exception` (an open `<tag>-i<I>-x`), `closed`, `head-moved` (`headRefOid` isn't the local `ah/issue-<I>` tip), `stacked-base-open` (the item depends on an issue whose PR isn't merged), `base-not-default`, `not-mergeable:<status>` (`mergeable` not MERGEABLE, or `mergeStateStatus` neither CLEAN nor, for a draft, DRAFT), `no-checks`, `checks-pending`, `checks-failed` (every `statusCheckRollup` entry must be completed SUCCESS, NEUTRAL or SKIPPED), `changes-requested`, `unresolved-threads` (any unresolved review thread, or more than 100). gh failing, or a bad argument: exit 1 with `{"error": "..."}`. |
| push-guard merge rules | While a /pipeline run is open (an open `pipeline-run-anchor` for the session's cwd or for any gh invocation's own directory), in any repo, the push guard denies: `PG-MERGE` `gh pr merge` in any other form; `PG-AUTOMERGE` `gh pr merge` with `--auto`, `--disable-auto` or `--admin`; `PG-APPROVE` `gh pr review --approve`/`-a`; `PG-READY` `gh pr ready` outside the pinned compound form; the `gh pr` verb is the first word after `pr`, skipping `-R <v>`, `-R<v>`, `--repo <v>` and `--repo=<v>`, also before `pr`; `PG-API-MERGE` `gh api` hitting `pulls/<n>/merge`, `pulls/<n>/reviews` or `repos/<o>/<r>/merges`, writing a `git/refs/` path (a non-GET method, or any `-f`/`-F`/`--field`/`--raw-field`/`--input`), a graphql query it can't read (`query=@<file>` in any spelling, `--input`), or naming `mergePullRequest`, `mergeBranch`, `updateRef`, `updateRefs`, `enablePullRequestAutoMerge`, `markPullRequestReadyForReview`, `addPullRequestReview`, `submitPullRequestReview` or `event=APPROVE`. No `git` command is a merge form, and pushes are left to GitHub's branch protection. `PG-MERGE-ERROR`: on a merge form, the merge rules threw, or liveness is unknown (a hierarchy dir, or its `msgs/`, that exists but can't be listed); any other command is never blocked by a guard failure. The pinned form gets the native permission prompt (`ask`) only from the run's top-level Orchestrator (no `agent_id`, and no `agent_type` with a persisted role that is null or orchestrator, or `agent_type: "ah:orchestrator"`) in a run whose anchor has `merge-opt-in: yes` and the same `merge-method`, under permission mode `default`, `auto` or `acceptEdits`; the prompt names the repo from `remote.origin.url` with any userinfo stripped; otherwise `PG-MERGE-ROLE` for the caller, `PG-MERGE` for anything else. Never `allow`. Outside a run the rules do nothing. A PostToolUse hook appends `{kind: "merge", pr, sha, method, time, approval: "permission prompt", ran: true}` to the run's decision log when the pinned form ran, success or not: it never says the PR merged, which is read from GitHub. |
| GitHub MCP merge rule | `hooks/pretooluse-mcp-guard.mjs`, PreToolUse on GitHub MCP tools (any server whose name contains `github`; other tools exit at once). While a run is live for the payload's `cwd`, it denies `ah-push-guard:PG-MCP-MERGE <tool>` when the tool name contains `merge`, any string in its input is `APPROVE`, or the tool is `update_pull_request` with `draft` false. Everything else passes with no output. A failure, or unknown liveness, on such a merge-type call: `PG-MERGE-ERROR`. |
| branch-protection check | `node <R>/hooks/pretooluse-push-guard.mjs protection --cwd <root>` — read-only; reads `gh api repos/{owner}/{repo}/branches/<default>` (`protected`) and `rules/branches/<default>` (a `pull_request` rule), and only when there's no such rule and `protected` is true, `branches/<default>/protection` (`required_pull_request_reviews`, `enforce_admins.enabled`; needs admin access). Prints one line: "Branch protection on `<default>`: on." (a `pull_request` rule, or classic protection requiring a PR with admins not exempt), "…: on, but <reason> — a direct push can still land. See the README's /pipeline section." (classic protection that doesn't require a PR, or that admins can bypass), "…: OFF — GitHub won't stop a push or a merge to it. See the README's /pipeline section.", or "…: unknown (<reason>)." for any failure, including the classic settings being unreadable. Never blocks, writes nothing, always exits 0. A /pipeline run copies the line into its run-start notification. |
| issue intake | `node <R>/hooks/issue-intake.mjs --cwd <abs> --out-dir <abs> (--issues <ref,ref,...> \| --labelled)` — decides which issues of `origin`'s GitHub repo are eligible pipeline input and writes a snapshot of each eligible one to `<out-dir>/issue-<N>.md`: the title, plus the visible text of GitHub's rendered HTML (`bodyHTML`, never the raw markdown) for the body and included comments. A `<ref>` is `N`, `#N` or `https://github.com/<o>/<r>/issues/N`; given order is kept, duplicates dropped. `--labelled` takes every open issue carrying `issues.trigger_label`, in ascending number. Eligibility is decided from metadata alone, so nothing of an ineligible issue's text is fetched, and of the newest 100 comments only those by `trusted_actors` not edited since the label are. The text is fetched with the metadata again, and an issue that no longer passes, or was edited in between, is `edited-during-intake`. Snapshot content lines sit behind a `| ` gutter, and an ineligible local issue's stale `issue-<N>.md` is removed. Prints one JSON object, exit 0: `repo`, `trigger_label`, `trusted_actors`, `items` — each `{issue, eligible: true, snapshot, sha256, lines}` or `{issue, eligible: false, reason}`, with `reason` one of `not-found`, `closed`, `other-repo`, `no-trigger-label`, `untrusted-labeler`, `edited-after-label`, `edited-during-intake`, `hidden-content`. Run-level failure: exit 1 with `{"error": "<code>: <detail>"}`, `<code>` one of `origin-not-github`, `conventions-absent`, `conventions-invalid`, `no-trigger-label`, `org-needs-trusted-actors`, `gh-unavailable` (gh missing, or `gh auth status --hostname github.com` fails), `usage` (bad arguments) or `intake-failed` (any other gh or I/O failure; the detail is fixed text naming the step and issue). On exit 1 nothing under `--out-dir` is meaningful. gh's own output is never printed. Conventions: [pipeline-conventions.md](pipeline-conventions.md). |

A team file that exists but does not read as a team record (unparseable, or parsing to something
with no `members` array) is never written over. `create` (plan included),
`spawn-one` and `spawn-ad-hoc` exit 2 before anything launches when the file they resolve to —
`--team <t>`'s, the default `teams/<prefix>.json`, or a legacy `team.json` — is in that state, naming
its absolute path and the remedy: repair or remove it, or use a different `--team`. Read verbs never
refuse; beside an unparseable legacy `team.json` a bare read verb resolves to that legacy file
rather than to `teams/<prefix>.json`, so it reports that scope.

Flags are validated per verb: `spawn-one`, `spawn-ad-hoc`, `adopt`, `checkin`, `whoami`, `dismiss`,
`disband`, `untrack`, `resync`, `move`, `reap`, `deliver`, `answer`, `tier`, `roster`, `pack`, `stream-open`, `stream-status`,
`stream-done` and `stream-label` reject any flag not in their own set, so
the lists above are exhaustive for those verbs rather than indicative.

`--team @default` names the default team (`team.json`) as explicitly as any named team, in every verb that
takes `--team` and in `msg.mjs`: no owned-team fallback, no refusal for several. No team can be named
`@default`, and any other `@` value is refused. Wherever a team name is printed to pass back (refusal
lists, the owned-teams lead line, the directive's commands), the default team shows as `@default`;
`teams --json` keeps `name: null` for it.
`--team <t>` names a live team, never a roster: `show`, `init`, `add`, `edit` and `remove` refuse it
and point at `--roster <r>`. On team verbs, a session that owns exactly one live team and passes no
`--team` acts on that team. Owning several, a verb that names a member (`dismiss <name>`, `untrack <name>`,
`move <name>`, `deliver <name>`, `answer <name>`, `spawn-one`/`spawn-ad-hoc --member <name>`) takes the team
whose members include that name among the owned ones (recorded member names only: not a pane id or
session id). Every other team verb — `create`, `disband`, `resync`, `untrack --all`, `stream-open`,
`stream-status`, `stream-done`, `stream-label`, and `spawn-one <role>` or `spawn-ad-hoc <role>` without
`--member` — refuses, exit 2, listing the owned teams; a named member that no owned team holds, or
that more than one holds, adds that to the message. An explicit `--team <t>` is taken as given. Verbs
that don't act on one team (`teams`, `doctor`, `whoami`, `checkin`, `adopt`, `tier`, `reap`, `history`,
`show` and the other roster verbs) are unaffected. The default team (a legacy `team.json`) counts as
owned, and is `--team @default`. A session owns a team when its session id matches the one the team
file records, or its pid matches the recorded orchestrator pid and no two known session ids differ; a
dead pid proves nothing, and ownership never checks that the owner is alive. The CLI reads the session
id only from `--session` (never from the environment), and a team records one only when
`create --commit --session <id>` wrote it, which the agent-team skill doesn't pass. So a resumed
session, with a new pid, owns none of its teams in the CLI or in its hooks until it re-claims each one
with `adopt --orchestrator-pid <its pid> [--team <t>]`; `adopt` keeps the recorded session id and
changes only the pid, and it is one call per team. The `own` field of `teams` uses the same rule.
`reap` judges a team by its recorded pid alone, so a team that only a session id owns, with a dead
pid, is an orphan to `reap --commit` (it deletes the team file unless live members are attributed to
it): `adopt` first. `msg.mjs new` without `--team`, owning several, takes the team whose members include
`--to-name` and otherwise refuses and writes nothing; `msg.mjs list` covers every owned team, and each
row carries its `team` (`team=<name>` in `--plain`); `msg.mjs roster` prints every owned team's table,
each under a line naming the team and its roster (JSON: `teams`). The removed `alias` and `layout`
verbs exit 2 naming their replacements (`create --team`, `create --mode`), as does `init --layout`.

**Which roster a command uses.** `show`, `init`, `add`, `edit`, `remove` and `create` take the first
of: `--roster <r>`; `AH_ROSTER`, when set and not empty; `activeRoster`, a top-level config key read
most specific level first (repo-user, repo, global — from a worktree, the main checkout's files
too); else the default `roster` block. In each, `default` means the unnamed `roster` block, so a
narrower level or one session can undo a wider selection; `init --roster default` and
`roster copy <src> default` are refused. `create --from` ignores the selection, and every other verb
acts on its team's recorded roster. Hooks resolve a session's roster the same way, except that a team
file in scope wins over `AH_ROSTER` and `activeRoster` — even one recording the default block. A
global file holding only `activeRoster` (with or without `teamLayout` and `modelTiers`), and a repo or
repo-user file whose only key is `activeRoster`, configure nothing; their selection still applies.
Otherwise `activeRoster` never changes whether a file counts as configured. An `activeRoster` that is empty or not a string is refused as not a roster name. `show`, `roster list` and `roster use` carry the selection, and so does `create`'s plan
when something is selected (with nothing selected, the plan is unchanged):

    selection: { roster: <name or "default">, source: "flag"|"env"|"activeRoster"|"team"|"default", level: <level or null>, path: <path or null> }

`level` and `path` are set only for source `activeRoster`. A selection from `--roster`, `AH_ROSTER`
or `activeRoster` that names a roster no level defines (a `rosters.<name>` key, even one with no
members) makes every one of those verbs but `init` exit 2, naming the source, the defined rosters
and the fixes (`roster use default`, `roster use <other>`, `init --roster <name>`); `init` creates
it. Hooks use the default block instead and add that message to the session's warnings, and
`doctor` adds a red `roster-selection` row. `create` still refuses a selected roster with no
members, and records the selected key in the team file's `roster` (null for `default`).

**`team-name-unusable`.** When the name a team would be created under cannot be used — it fails the
team-name rule on any transport, or, under herdr, some pane-routed member name it derives breaks
Herdr's `[a-z][a-z0-9_-]{0,31}` — `create` (every phase), and `spawn-one` / `spawn-ad-hoc` when they
would create a team, exit 2 with this JSON on stdout and its `message` on stderr, having launched
and written nothing: `ok: false`, `refused: "team-name-unusable"`, `needs_user_choice`, `verb`,
`name`, `name_source` (`basename` \| `legacy-team` \| `explicit`), `transport`, `why`,
`failing_member: {name, length}\|null`, `suggestion` (a name to OFFER, never applied), `suggestion_why`
(when there is no suggestion), `rerun` (the same command with a literal `--team <TEAM>`, `null` when
`needs_user_choice` is false) and `message`. The name is the user's choice: ask, then re-run with
`<TEAM>` replaced by their answer.

**`member-model-undefined`.** When a claude-kind member that `create --spawn`, `spawn-one` or
`spawn-ad-hoc` would launch (`--dry-run` included) has no model — none stored, none given with
`--member-model` / `--model` — the verb exits 2 the same way, after the team-name check and before
anything is launched or written: `ok: false`, `refused: "member-model-undefined"`, `verb`, `members`
(roster order: `{name, role, class, allowed, fallback}`), `rerun`, `rerun_fallback` and `message`.
`allowed` is the class's model allowlist. A member of a kind with a model mapping (today: codex) is
asked for too: it also carries `kind` and `models_command` (codex: `codex debug models`), its
`allowed` is `null` (any model that harness accepts) — or, for an advise-class member, the models of
its kind declared `opus` or `fable` — and its `fallback` is always `null`: models do not carry
across harnesses. `fallback` is `{model, from}` — the highest-tier model a
claude-kind design, review or implement member holds that the class allows (`inherit` never counts),
first in roster order on a tie — or `null`; a legwork member never borrows one, and is listed only
when task-gopher is not installed or `--no-legwork-handoff` is given (otherwise it is skipped, as
under `create` above; `spawn-one` and `spawn-ad-hoc` launch no legwork role). `rerun` is the same command
with one `<MODEL>` flag per listed member (`--member-model <name>=<MODEL>`; `--member <name> --model
<MODEL>`; `--model <MODEL>`). `rerun_fallback` applies every fallback, and is `null` when any is. The
model is the user's choice: ask, then re-run `rerun` with each `<MODEL>` replaced; only a top-level
session that cannot ask runs `rerun_fallback`, and a subagent never does.

**`model` on a non-claude kind.** A kind with a model mapping (today: codex, `--model <M>`) takes a
`model` on `add`, `edit`, `spawn-one --model`, `create --member-model` and `spawn-ad-hoc --model`,
checked for shape only (no whitespace or control characters) — the harness checks the name at the
first turn. `model` together with a model flag in `args` (codex: `--model`, `-m`, `-c model=…`) is a
hard error, as is `approvals_reviewer` in a codex member's `args`, and any `args` on a non-claude
advise-class member. A kind with no mapping rejects `model`: pass its own flag in `args`. A
non-claude chain member whose auto-mode leaves a read-only sandbox (codex `manual`, `plan`) gets a
warning at `add`, `edit` and spawn: it cannot write its report without an approval in its pane.

**Spawning a non-claude member.** Every spawn writes its standing instructions to
`<hierarchy dir>/instructions/<name>.md` (identity, the role's agent body, how a brief and a report
work outside Claude Code) and, for codex, launches it with `--model <M>`,
`-c model_instructions_file="<that file>"`, `--add-dir <message pool>` when the pool is outside the
cwd, and `-c approvals_reviewer="user"`, ahead of the auto-mode flags and `args`. A member that stops
at a prompt it recognises (trust dialog, sign-in, approval) is launched with a `blocked` object of
`deliver`'s shape to relay; spawn never sends a key.

**`name-in-use`.** When Herdr refuses to start a member because another Herdr agent holds its name
(`agent_name_taken`), `spawn-one` and `spawn-ad-hoc` exit 2 with `ok: false`,
`refused: "name-in-use"`, `name`, `rerun` (the same command plus `--names-in-use <name>`), `detail`
and `message`, having closed the empty pane and written nothing. It is not a launch failure.
`create --spawn` reports it on that member's `launch_result`.

**Per-member refusals under `create --spawn`.** `name-in-use`, `harness-cwd-untrusted` and
`agent-file-not-found` fail that member alone: `launch_status: "failed"` with
`launch_result: {reason: "refused", refused: "<name>", …the refusal's fields}`. They are not launch
failures.

**`agent-file-not-found`.** A non-claude member's contract is a built-in role's `agents/<role>.md` in
the running plugin, or a custom role's agent file found by the role resolver. When it is missing,
spawn exits 2 before any pane opens with `ok: false`, `refused: "agent-file-not-found"`, `member`,
`role`, `ref` and `message`.

**`harness-cwd-untrusted`.** When Codex's own config (`$CODEX_HOME/config.toml`, else
`~/.codex/config.toml`, read-only) says the cwd is not trusted and, once the member is ready, no
prompt is recognised on its screen, spawn closes the pane it opened and exits 2 with `ok: false`,
`refused: "harness-cwd-untrusted"`, `member`, `kind`, `cwd` and `message`. Trusting a directory is
the user's decision: they run `codex` there once and answer its question.

**`advise-model-tier`.** A non-claude advise-class member whose model is not declared `opus` or
`fable` is refused before anything is launched or written: `ok: false`,
`refused: "advise-model-tier"`, `member`, `kind`, `model`, `declared_tier` (`null` or the declared
tier), `needs: ["opus","fable"]`, `rerun_declare` (the `tier set` command with `<TIER>`) and
`message`. A kind with no model mapping can never be declared: `model`, `declared_tier` and
`rerun_declare` are `null`, and `add`/`edit`/`spawn-ad-hoc` reject such a member outright.

**Stale keys and `migrated`.** Keys that do nothing any more are ignored, reported by `status`,
`doctor` and every `create` phase (never in session context), and migrated by the next CLI write
to their file — `init`, `add`, `edit`, `remove`, `role set`, `role remove`, `untrack`/`dismiss
--also-config`, and `create`'s stored `--mode`. Chain-role subagent opt-ins: a top-level `route`
other than `peers` (deleted), a chain role's `dispatch:"model"` (deleted), a chain member's
`route:"subagent"` (deleted), `onMissing` `never`/`prompt` (deleted), and a block `route:"subagent"`
(becomes `peer`; each legwork member that inherited it gets its own `route:"subagent"`). Team keys
a roster no longer holds: `teamAlias`, a block's `layout`, and a `teamLayout` outside the global
file (deleted). A roster `members` element that is not an object (null, an array, a string, a number,
a boolean) is ignored by every reader — reported in `warnings` by `status`, `doctor` and `create` as
``roster `<file>`: `members[<i>]` is not an object (`<type>`); ignored`` — and deleted on the next
write. Only the file being written changes; other keys and their order are kept. The
verb's output then carries `migrated: [{path, key, from, to}]` (`to` is `null` for a deletion),
with one stderr notice per file. `gates.jsonl` is never rewritten: a stale `route` record there is
simply not read.

`/agent-team` (teams), `/agent-roster` (the roster template) and `/ah:agent-role` (custom roles) are the skills that drive these
verbs; their SKILL.md files are the operational protocol, this file is the surface.
