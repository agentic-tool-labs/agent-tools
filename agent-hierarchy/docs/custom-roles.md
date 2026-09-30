# Custom roles, and members in other harnesses

Define your own role, put it on the roster, and — if you want — run a member
on Codex instead of Claude. Assumes you already know the roster, a Team and
peers ([getting-started.md](./getting-started.md)).

Every command is `node <AH_ROOT>/hooks/roster.mjs <verb> … --cwd <abs cwd>`
(`R` below); the full flag list is in [cli-tools.md](./cli-tools.md).
`/ah:agent-role` drives the `role` verbs for you, so you rarely type them.

## 1. What a custom role is

A `roles.<name>` row in `agent-hierarchy.json` with two things that matter: a
**class** and an **agent file**. `roster.mjs role` does every read, check and
write — don't hand-edit the JSON.

The class says which step of the chain the role may stand in for, and what its
agent file must look like. The contract is checked when you define the role:

| Class | Stands in for | Tool contract (errors) | Conventions (warnings) |
|---|---|---|---|
| `advise` | Escalate (Ultra-Advisor); every dispatch needs your approval | Read, SendMessage; an explicit `fable` or `opus` model | no Edit, NotebookEdit, advisor |
| `design` | Design (Architect); the tier rule applies | Read, SendMessage, Write | no Bash, NotebookEdit, advisor |
| `review` | Review (Reviewer) | Read, SendMessage; must **not** have Edit, Write, NotebookEdit | has Bash; no advisor |
| `implement` | Implement (Implementor) | Read, SendMessage, Edit or Write, Write or Bash | has Bash; no advisor |
| `legwork` | nothing — errands any role can dispatch | none | none |

Errors refuse the write; warnings print and the write goes ahead.

A bare `agent` name resolves to `<repo>/.claude/agents/<name>.md`, then
`~/.claude/agents/<name>.md`; the first that exists wins.

## 2. Where it sits in the chain

Two placements, for the chain classes (`advise`, `design`, `review`,
`implement`):

- **Alternative** — the row has `routes`, a sentence saying what work it takes.
  It is an in-chain alternative to the built-in for that step, for that work
  only. Example: a Docs-Writer with `routes: "standalone docs: READMEs, docs/,
  guides, changelogs"` takes the docs while the Implementor keeps the code.
  Both are live at once.
- **Side role** — no `routes`. Dispatched only when you ask for it or its
  description fits.

`routes` on a `legwork` role warns and is ignored.

**Who runs as what.** Only a `legwork`-class role can ever run as a subagent
(`--dispatch model`, or a roster `route: subagent`). Every other role — custom
or built-in — runs as a peer session, and the route gate denies a chain role
dispatched as a subagent.

## 3. Defining one

Ask for it, and answer the questions:

```
/ah:agent-role add
```

It suggests a name, the class, placement (and a drafted `routes`), the agent
file, the model, a one-line description and the level, then runs a dry run,
then the write.

**The name.** Lowercase letters, digits and `-`, starting with a letter, at
most 31 characters (`/^[a-z][a-z0-9-]{0,30}$/`). It can't end in `-` or
`-<digits>` (that suffix is a peer's instance number), and it can't be a
built-in role's name or `orchestrator`, `advisor` or `other`. It also becomes
part of the peer name (`<team-prefix>-<name>`), which Herdr caps at 32
characters in total (`[a-z][a-z0-9_-]{0,31}`) — keep it short, especially for
a global role, since every repo has its own prefix.

The command underneath:

```
R role set docs-writer --class implement \
  --routes "standalone docs: READMEs, docs/, guides, changelogs" \
  --scaffold user --dry-run
```

| Flag | Meaning |
|---|---|
| `--class advise\|design\|review\|implement\|legwork` | the class (§1) |
| `--agent <ref>` | the agent file: a bare name, or `plugin:agent` |
| `--routes "<sentence>"` | makes it an alternative; `--routes ""` demotes it to a side role |
| `--description`, `--label`, `--model` | as named; `--description ""` deletes the key |
| `--dispatch model` | legwork only (exit 2 otherwise) |
| `--level global\|repo\|repo-user` | where the row lives; default is where the role is already defined, else `repo` with `--scaffold repo`, else `global` |
| `--scaffold user\|repo` | write a template agent file that passes the contract: `~/.claude/agents/<agent>.md` or `<repo>/.claude/agents/<agent>.md` |
| `--dry-run` | write nothing; print the findings |

Drop `--dry-run` to commit. If the agent file is repo-level, define the role at
`repo` too — a global row pointing at it is unavailable in every other repo.

**The fix loop.** Each error finding prints its fix. In `/ah:agent-role` you
choose: let it apply a frontmatter fix for you (only to your own bare-name
file, never a plugin's), change the role's class to the one it suggests, or
fix it yourself. To restrict a tool, remove it from `tools` or add it to
`disallowedTools` — never a scoped entry like `Bash(git:*)`, which grants the
whole tool. Then it dry-runs again until there are no errors.

**The Specialisation section.** A scaffolded file is a short identity
paragraph, then `## Specialisation` with one placeholder line. Replace that
line with what makes this role yours; the hierarchy contract arrives by
injection, so the file never restates it. `/ah:agent-role` asks you for the
text and edits only that line.

Check and inspect:

```
R role list            # class, agent, model, placement, contract status
R role list --json     # adds each role's findings
R role remove <name>   # refused while a roster member uses it; never deletes a file
```

A role that fails its contract shows `UNAVAILABLE: n errors`.

## 4. Using it

Add it to the roster, then start it:

```
R add --role docs-writer --model opus
R spawn-one docs-writer          # a roster-conforming member
R spawn-ad-hoc docs-writer       # a member the roster doesn't describe
R create --spawn                 # or the whole team
```

The spawn verbs also take `--dry-run`, which prints the launch line and starts
nothing. `add` only writes the template; it launches nothing. A live Team is not
changed by a roster edit — use `spawn-one` or `spawn-ad-hoc` to add a member.
`/agent-team` and `/agent-roster` drive these.

**Models.** A member's model is stored only when you set one. Add it without
`--model` and you are asked at spawn; answer with `--model <M>` on `spawn-one`,
or `--member-model <name>=<M>` on `create`, for that spawn only. Without one,
the spawn is refused with `member-model-undefined` and lists the models the
class allows. `edit
--model ""` clears a stored one. An `advise` role always needs an explicit
`fable` or `opus`.

## 5. A member in another harness (Codex)

A roster member's `kind` picks the agent CLI Herdr starts. Omitted means
`claude`. Set `kind: codex` and it runs in Codex:

```
R add --role architect --kind codex --model <codex-model> --route pane
```

Which model names are valid depends on your account; `codex debug models`
lists them.

What changes for a non-Claude member:

- **`route` must be `pane`**, and spawning needs a Herdr session
  (`HERDR_ENV=1`). `add` and `edit` work anywhere.
- **`model`** is the harness's own model name, checked for shape only; the
  harness checks it at the first turn. `effort` is rejected. `auto_mode` is
  translated into Codex's sandbox and approval flags. `args` passes native
  flags verbatim, but not a model flag if `model` is set, nor Codex's approvals
  setting (`approvals_reviewer`, which every member launches with its own), and
  not at all on an advise-class member.
- **Its contract** is not loaded the way a Claude agent's is. Each spawn writes
  standing instructions to `<hierarchy dir>/instructions/<name>.md` — identity,
  the role's agent body, how a brief and a report work outside Claude Code —
  and launches Codex with them.
- A Codex member whose `auto_mode` leaves a read-only sandbox (`manual`,
  `plan`) gets a warning: it can't write its report without an approval in its
  pane.

**Tiers.** The hierarchy ranks models by Claude's tiers. For a Codex model,
you declare where it stands:

```
R tier set codex <codex-model> opus
R tier list
R tier remove codex <codex-model>
```

It is stored only in the global config. An **Ultra-Advisor** (advise class) on
a non-Claude kind must run on a model declared `opus` or `fable`; otherwise the
spawn is refused with `advise-model-tier` and prints the `tier set` command to
re-run. The tier is your call — an agent asks you rather than declaring it.

**Briefing it.** Claude Code's SendMessage can't reach a non-Claude member. The
Orchestrator briefs it with `deliver`, in the background:

```
R deliver <name> --req <abs request path>
```

It sends the request's `[hierarchy-msg …]` line, a `Report to:` path and the
standing-instructions path, waits for the turn to end, and returns a `status`
(`reported`, `no-report`, `busy`, `blocked`, …). The report is only the
response file. Nothing is sent to a member that is working or at a prompt. A
brief to an Ultra-Advisor needs your approval for the session, as it does for a
Claude one.

**Prompts.** Codex can stop at a trust dialog, a sign-in or an approval. Spawn
and `deliver` report it as `blocked` with the screen verbatim and the options
it recognises. The Orchestrator asks you, then sends your choice:

```
R answer <name> --prompt <blocked_by> --choice <id> --screen-hash <hash>
```

It sends only when the screen still shows that prompt and option, and never
free text. If no option is offered, or you'd rather do it yourself, answer in
the pane and the Orchestrator re-runs. Trusting a directory is always yours.
If Codex shows its trust dialog, that is a prompt like any other: it comes back
`blocked` with trust and distrust options, and you pick. Only when no prompt is
recognised *and* Codex's own config says the directory is untrusted is the
spawn refused (`harness-cwd-untrusted`) and its pane closed; run `codex` there
once and answer its question.

**Limits.**

- **Tool limits are advisory outside Claude.** A Codex member's agent file
  can't enforce `disallowedTools`; Codex's own sandbox is the only real limit,
  and it follows your Codex configuration.
- **Keys are pinned to the tested Codex version.** The prompt options and the
  idle-composer check match `codex-cli 0.154.0-alpha.6.2`. A changed label or
  layout is not offered or sent (it fails closed): the brief comes back
  `blocked` with `harness-prompt` and no options, and you answer in the pane.

## 6. Role packs

A role pack is how you share roles with someone else. It is an ordinary
Claude Code plugin that also has an `ah-roles.json` at its root. Claude Code
installs, updates and removes it; ah finds it and lets you adopt its roles
one at a time. Roles only you use can stay where they are, in
`~/.claude/agents/` or a repo's `.claude/agents/`.

### The format

```json
{
  "version": 1,
  "roles": {
    "godot-implementor": {
      "class": "implement",
      "agent": "godot-implementor",
      "label": "Godot Implementor",
      "description": "Builds Godot 4 features in GDScript",
      "routes": "Godot scenes, GDScript and shaders",
      "model": "opus"
    }
  }
}
```

- `version` must be 1, or the whole pack is unreadable.
- Each role takes the custom-role fields: `class` (required), `agent`,
  `label`, `description`, `routes`, `model` and `dispatch`. They follow the
  same rules as your own rows, and built-in names are refused. `peer` isn't
  allowed, because it is a local setting. Unknown keys are warned about and
  ignored.
- `agent` names a file in the plugin, `agents/<agent>.md`, and defaults to the
  role's name. It can't point at another plugin's agent or at a path.
- No hidden text: control characters other than newline and tab, invisible
  formatting characters (bidirectional controls, zero-width characters),
  Unicode tag characters, variation selectors, the line and paragraph
  separators, and invisible filler characters are refused, in the fields and
  in the agent file; the finding names the character, its line and column.
  That refuses an emoji written with a variation selector (⚠️, say): write
  the plain character instead. The agent file must be valid UTF-8.
- A pack agent's frontmatter may hold only `name`, `description`, `model`,
  `tools`, `disallowedTools`, `color`, `effort` and `maxTurns`, each once, as a
  plain unquoted key. `tools` is required, and every tool entry is a plain
  name (no quotes, `[…]` list, or `Tool(scope)` form). A value continues onto
  more lines only as `- item` lines under an empty `tools` or
  `disallowedTools`, or as a `|` or `>` block under `description`. Tabs in the
  indentation, `#` comments, and anything else — `permissionMode`, `hooks`, MCP
  server settings, `skills`, `memory`, a YAML anchor — are errors. ah reads the
  file this strictly so that it sees exactly the tools YAML would grant. Your
  own agent files aren't held to this.

### Installing, adopting and trusting

`/ah:agent-role install <source>` takes a git URL, `owner/repo` or a local
directory. It shows you the pack's roles and everything else the plugin
carries before anything is installed, installs it, checks that what got
installed is what you reviewed, and offers its roles.

Nothing from a pack routes work, dispatches or spawns until you adopt it:

    roster.mjs role set <name> --from <plugin>@<marketplace>:<role> --dry-run

The dry run prints the pack's fields exactly as they will reach your
sessions, the agent's tools with the risky ones flagged, what else the plugin
carries, and a pin. You commit with that pin (`--pin sha256:…`), and approve
it in Claude Code's own prompt. The row keeps only `from`, `pin` and your own
fields; everything else is read from the pack each time. You pick the local
name, so two packs can offer the same one. A built-in's name replaces that
built-in's agent, if the pack role has the built-in's class.

The pin covers the whole plugin, not just the agent file: its hooks,
scripts and skills too. If anything in the plugin changes, even after a
plain `claude plugin update`, every role adopted from it becomes unavailable
(`pack-changed`) until you look at the change:

    roster.mjs role trust <name> --dry-run

shows the field changes, a diff of the agent file, and every file added,
removed or changed since you trusted it. Commit it with the pin it prints.
ah keeps a copy of what you trusted in `~/.claude/agent-hierarchy/trusted/`,
and a role is available only when this machine has one. So a repo-level row
committed by someone else stays unavailable (`pack-untrusted-here`) until you
trust it yourself.

`/ah:agent-role update <plugin>` and `uninstall <plugin>` drive Claude
Code's own plugin commands and walk you through re-trusting or removing the
adopted roles. `roster.mjs pack list` and `pack show` inspect packs at any
time.

### Pipeline runs

`/ah:pipeline` never merges: it pushes branches and opens draft PRs, and a
person merges them, relying on the Reviewer's verdict. So a pack role can
implement work in an unattended run (its dry run says so), but it never fills
the reviewer or designer slot there: those stay first-party, and while a run
is live the spawn verbs refuse a pack reviewer or designer. If the built-in
Reviewer or Architect itself is overridden by a pack role, the run halts
before it starts.

ah never launches or dispatches a pack role with permission checks off. The
spawn verbs refuse a pack role's member whose auto mode is
`bypassPermissions`, or unset (it would take your settings' default mode,
which can be bypass); give it one with `roster.mjs edit --member <name>
--auto-mode auto`. And a session in bypass mode can't dispatch a pack role's
agent as a subagent. What remains: you can switch a running pane into bypass
yourself, or launch `claude --agent <plugin>:<agent>` in bypass outside ah;
and every agent in an installed plugin is a subagent type in every session,
adopted or not, which is Claude Code's side.

### What this does and doesn't protect

- Installing a plugin is Claude Code's trust decision. Once installed, its
  agents are available in every session and its hooks and MCP servers run in
  every session, whatever ah does. That's why ah shows all of it before
  install, and why packs that carry only roles are best.
- Nothing runs in the hierarchy until you adopt it, one role at a time.
- The pin is a tripwire, not a gate: it makes a changed role unavailable
  until you review it, but it can't stop the plugin's own hooks or MCP
  servers from running the new content. It covers the plugin's files as they
  sit on disk, and nothing the role reaches while it runs: not the network
  (for a role with Bash or WebFetch), not other files, and not a `.git`
  directory inside the plugin, which the pin skips because a fetch rewrites
  it; a role could read other versions out of it. `pack show` lists a `.git`
  directory, so you see it before install.
- Adopting and trusting need the exact pin, and your approval in your own
  session; role, peer and subagent sessions and pipeline runs are refused.
  A command that isn't one plain ah command is treated as a trust commit
  when its text names one, and `roster.mjs` itself refuses a commit from a
  team member or during a pipeline run, however the command was written.
  What remains: a subagent in a mode that runs commands without asking could
  hide the words from the gate, and a session with Bash could still edit the
  config or the stored copies by hand.
- Tool limits are role discipline, not a sandbox: a reviewer with Bash can
  still write files. The real boundary is the session's permission mode,
  which is why a pack role never runs with permission checks off.
- The fields that reach every session's context keep the one-line,
  160-character, no-backtick limits, and you see them verbatim before you
  trust them.

## Where to go next

- [cli-tools.md](./cli-tools.md) — every verb and flag.
- [`agent-role`](../skills/agent-role/SKILL.md),
  [`agent-roster`](../skills/agent-roster/SKILL.md),
  [`agent-team`](../skills/agent-team/SKILL.md) — the protocols behind the
  commands.
- [troubleshooting.md](./troubleshooting.md) — symptom → cause → fix.
