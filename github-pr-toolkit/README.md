# github-pr-toolkit

Two pull-request workflows that share one setup and one GitHub token.
`/code-critic` writes an adversarial review of a local diff or a GitHub PR.
`/resolve-pr-comments` works through the review threads other people already
opened on a PR. There's also a doctor command for checking the wiring, and a
skill for adding your own review categories to `/code-critic`.

This page covers the shared setup and the `/resolve-pr-comments` flow.
`/code-critic` has its own page: [docs/code-critic.md](docs/code-critic.md).

## What's in it

### `/resolve-pr-comments`

Works through the review threads reviewers already opened. For each one it
assesses the comment, replies, fixes or rejects, and resolves the thread, and
it tracks all of that as a task list. The assessment runs on a model you pick
(default, Opus, Sonnet, or Fable). You can also hand it to a live peer agent
rooted in the repo: an agent-hierarchy peer, an agent-teams teammate, or a
Herdr pane agent.

### `/code-critic`

Writes an adversarial review of a local diff or a GitHub PR. The first
question every run asks is what you want out of it: fix the findings you
approve, or only comment on or report them. The review itself is the same
either way, and comment mode makes no code changes at all.

The review then runs over the categories you pick (general, security, design,
rules-adherence, performance, tests), using parallel review subagents on a
model you choose. That's session default, Opus, Sonnet, or Fable, one model
across all categories, or else the advisor or the main agent. You can also hand
the review to a live peer agent rooted in the repo: an agent-hierarchy peer,
an agent-teams teammate, or a Herdr pane agent.

It's built to keep the signal high. Every finding says what breaks if the
change ships, and finding nothing counts as a successful review. The general
review also flags ephemeral comments, the `// changed from foo to bar`
narration LLMs leave behind, which stops meaning anything once the diff
merges.

Findings are sorted by severity and tracked as a task list, and nits get
batched into a single question. You can fix things locally, or post inline
comments as one review. Each posted comment opens with a colour-coded severity
banner (🔴 CRITICAL … ⚪ NIT) and uses the feedback tone you've configured
(terse, balanced, or suggestion). The review level
(`--level low|medium|high`, default `medium`) decides what happens to a finding that
isn't material.

Full details: [docs/code-critic.md](docs/code-critic.md).

### `/github-pr-toolkit:doctor`

Reports orphaned `/code-critic` review markers and offers to clear them, then
diagnoses the GitHub MCP wiring and helps you fix it, all without running
either flow. See [Troubleshooting](#troubleshooting).

### `add-review-category` (skill)

A wizard for adding your own `/code-critic` review category. It can walk you
through building one from the trusted template, or import one from a local
file or from GitHub after validating it. New categories install to
`~/.claude/agents` or the project's `.claude/agents`. See
[docs/code-critic.md](docs/code-critic.md).

## How the work is split

The two flows are complements. code-critic writes reviews, and
resolve-pr-comments works through reviews other people wrote. They divide the
labor the same way.

The orchestrator is a higher-reasoning agent. It reasons, writes the code
fixes, walks you through approving each issue, commits, and pushes. It has no
GitHub tools.

Haiku workers do every GitHub read and write: `github-worker` for the resolve
flow, and `critic-worker` for code-critic's GitHub I/O. They go through the
GitHub MCP server (with a gated `gh` CLI fallback) and hand back only the
distilled results.

Review subagents can split code-critic's adversarial pass across the
categories you select. There's one per built-in category
(`code-reviewer-general`, `-security`, `-design`, `-adherence`,
`-performance`, `-tests`), plus any custom categories you've added with
`add-review-category`, and `code-reviewer-all` covers every selected category
in a single dispatch instead of one agent per category. They run on the model
you pick (*Default (model I'm using)*, Opus, Sonnet, or Fable), the same one
for every category. Haiku isn't offered; it's kept for the I/O workers. The
reviewers are static and read-only, with no GitHub tools and only read-only
git, and the orchestrator checks their findings against the diff it computed
itself.

A `thread-assessor` subagent can take over the resolve flow's reasoning:
judging each reviewer's claim against the current code and proposing fix,
reject, or discuss. It runs on the same kind of model you pick. A gate (Step
3.5) shows you the threads it found before anything gets reasoned about, then
asks how to work them. You can research them all (one assessor per thread, in
parallel), go one at a time (assess, decide, then assess the next, so a thread
resolved early never gets assessed), or assess them all inline. Fanning out
over 6 threads takes a second confirmation, and its default is a rolling
queue: 6 assessors in flight, with the next queued thread dispatched the
moment one returns. That way a busy PR can't quietly turn into 20 subagents at
once, and no slot sits idle waiting on a straggler. The cap is yours to
change. The assessor has no Bash and no GitHub tools, only `Read`, `Grep`,
`Glob`, and `advisor`, so it can't run or change anything, and the
orchestrator checks every `thread_id` it returns.

Raw GitHub API payloads never reach the high-reasoning model's context, and
the expensive model never gets spent driving a tool it doesn't need.

---

## Requirements

| Requirement | Why | Notes |
|---|---|---|
| **Claude Code** (recent) | Plugin MCP server, subagents, PreToolUse hooks | Verified on **v2.1.206** |
| **A GitHub MCP server** | The workers' actual GitHub tools | The default is **GitHub's hosted remote MCP**, connected directly from the plugin's `.mcp.json` with the PAT as a Bearer header. Nothing to install or run locally. Local alternative below |
| **A GitHub Personal Access Token (PAT)** | Authenticates the workers' GitHub API calls | This is the main setup step. **See [GitHub token requirements](#github-token-requirements)** |
| **Git push access to the repo** | The orchestrator commits and pushes your fixes | Uses your normal git auth (SSH or credential helper), **separate** from the PAT |
| **`gh` CLI** *(optional)* | Fallback for servers without native thread operations | `gh auth login`; uses its own auth |

---

## Installation

### 1. Install and enable the plugin

From the marketplace (this repo's root `.claude-plugin/marketplace.json`), in
Claude Code:

```
/plugin marketplace add agentic-tool-labs/agent-tools
/plugin install github-pr-toolkit@agent-tools
```

For local development, point Claude Code at this plugin's directory instead:

```sh
claude --plugin-dir /path/to/agent-tools/github-pr-toolkit
```

> **Coming from the old `resolve-pr-comments` or `code-critic` plugins?** This
> plugin replaces both. Uninstall them, install this one, and enter the PAT
> once (with the combined scopes below).

Enabling the plugin loads everything automatically: both commands
(`/resolve-pr-comments`, `/code-critic`) and their same-named skills, the
doctor, all ten agents (the two Haiku workers, code-critic's seven reviewers,
and the resolve flow's `thread-assessor`), the plugin's GitHub MCP server
(from its own `.mcp.json`, so there's nothing for you to configure), and the
guard hook, which holds the main agent's first GitHub call in a session once
and points it at the workers (see [How the gate works](#how-the-gate-works)).
After an update, run `/reload-plugins`.

### 2. Create a GitHub PAT

[GitHub token requirements](#github-token-requirements) has the exact scopes.
In short: create a token at **GitHub → Settings → Developer settings →
Personal access tokens**, give it access to the repos you'll review, and grant
it PR read and write.

### 3. Give it the token (part of install, no env var)

The plugin declares a secure `userConfig` option, so when you run
`/plugin install github-pr-toolkit@agent-tools`, Claude Code shows a
configuration dialog with a masked **"GitHub Personal Access Token"** field.
Paste your PAT there once. Both commands and both workers share it. It's
stored in your OS keychain, never in `settings.json`, a tracked file, or the
shared `GITHUB_PERSONAL_ACCESS_TOKEN` env var, so it can't clash with your
other GitHub tooling.

You can change it any time through **`/plugin` → `github-pr-toolkit` →
Configure**. Under the hood, the plugin's `.mcp.json` reads it as
`${user_config.github_pat}` and sends it to GitHub's hosted server as a Bearer
header. There's a **known Claude Code issue
([#62442](https://github.com/anthropics/claude-code/issues/62442))** where
sensitive config values can get lost on restart or upgrade. If GitHub access
suddenly breaks, re-enter the PAT there first.

The same dialog has three settings that aren't secret.

**`review_tone`** is how `/code-critic` words its feedback: `terse`, `balanced` (the default), or
`suggestion`. You'll notice it most in the inline review comments code-critic
drafts onto a PR, since those get read by someone who wasn't in your session.
To override it for one run, pass `--tone terse|balanced|suggestion`, or just
say so in the session. It only changes wording. It never changes which
findings get reported, a severity, or what the impact line says. A Critical
stays Critical and still says what breaks, in all three tones. Anything unset
or unrecognized counts as `balanced`, and you're never prompted for it.

**`advisor_policy`** decides when reviewers consult the advisor, in both
`/code-critic` and `/resolve-pr-comments`. The advisor is only worth its cost
when it's stronger than the model asking, and its spend is the one cost the
review stats can't measure, so it isn't on by default. `auto` (the default)
consults only when you explicitly pick a cheaper reviewer model (Sonnet, Haiku,
Fable), and holds off on Opus or a session default you left alone. `always`
consults whatever the model, and `never` never does. You can override it for a
run just by asking, and anything unset or unrecognized counts as `auto`. See
[docs/code-critic.md](docs/code-critic.md).

**`compact_checkpoint_tokens`** (default `200000`) sets when `/code-critic`'s
issue-by-issue loop offers you a compaction checkpoint. Once the conversation
passes roughly that many tokens, it pauses before the next issue, tells you how
many issues remain, and points out that the review state is on the task list
and survives compaction. It never compacts for you. The figure is estimated
from transcript size, not measured. Set it higher to be interrupted less, or
lower to be offered a checkpoint sooner.

You don't have to get this perfect up front. `/resolve-pr-comments` checks
GitHub access before it starts, and if that fails (usually because the token
is missing), it walks you through setup.

### 4. Choose where the GitHub MCP server runs *(optional; the hosted default needs nothing installed)*

The server is defined in the plugin's `.mcp.json`, not in the agent files,
because Claude Code silently drops `mcpServers` declared in plugin agent
frontmatter. By default it connects directly to GitHub's hosted remote MCP
server, with the PAT going from your keychain into a Bearer header:

```json
{
  "mcpServers": {
    "github": {
      "type": "http",
      "url": "https://api.githubcopilot.com/mcp/x/pull_requests",
      "headers": { "Authorization": "Bearer ${user_config.github_pat}" }
    }
  }
}
```

Plugin `.mcp.json` configs do substitute `${user_config.*}` into `headers`;
that's been checked live. The substitution bug
[claude-code#51581](https://github.com/anthropics/claude-code/issues/51581)
affects project-level `.mcp.json`, not this path. The `/x/pull_requests` part
of the URL narrows the server down to the pull-request toolset only (see
[Narrowing the MCP surface](#narrowing-the-mcp-surface-applied-by-default)).

If you'd rather run the official server yourself, edit `.mcp.json`. The env
var and tool names stay the same. Use Docker
(`docker run -i --rm -e GITHUB_PERSONAL_ACCESS_TOKEN -e GITHUB_TOOLSETS=pull_requests ghcr.io/github/github-mcp-server`)
or the native `github-mcp-server stdio` binary, with
`env: { GITHUB_PERSONAL_ACCESS_TOKEN: "${user_config.github_pat}" }`.

### 5. (Optional) `gh` CLI fallback

```sh
gh auth login
```

The official server handles listing unresolved threads, replying in a thread,
and resolving threads natively, so `gh` is only a fallback for servers that
can't. The fallback is gated. A worker may use `gh` for an operation only after
the MCP call for that same operation failed, and it has to flag the fallback in
what it returns (`via: gh (mcp error: …)`) so a broken MCP setup can't hide
behind it. The preflight health check uses MCP only, for the same reason. It's
still worth setting up.

## GitHub token requirements

The PAT authenticates the workers' GitHub API calls: reading PRs and review
threads, posting replies to review comments, and resolving conversations. Your
code pushes go through your normal git auth, not this token (see
[About code pushes](#about-code-pushes)).

### Classic PAT (simplest)

| Scope | Needed for |
|---|---|
| **`repo`** | **Required.** Read PRs and review threads, post review-comment replies, resolve threads (private and public repos). |
| `read:org` | Only if you work with **organization-owned** repos and want the server's org tools. |

Create it at **Settings → Developer settings → Personal access tokens → Tokens
(classic)**. Check **`repo`**, set an expiry, generate it, and paste it into
the plugin's **GitHub Personal Access Token** field (step 3).

### Fine-grained PAT (least privilege, recommended)

Create it at **Settings → Developer settings → Personal access tokens →
Fine-grained tokens**:

- **Repository access:** pick the specific repos you'll review (or *All
  repositories*).
- **Permissions:** the minimum is the three rows below. You can drop Contents
  if you'll never use `/code-critic`.

| Permission | Access | Needed for |
|---|---|---|
| **Metadata** | Read-only | Mandatory (auto-selected for every fine-grained token). |
| **Pull requests** | **Read and write** | Read review threads and comments, post replies, **resolve threads**. This is the only capability the worker needs. |
| **Contents** | **Read** | `/code-critic` needs it to check the PR branch out into a worktree. (If you'll only ever use `/resolve-pr-comments`, you can leave it out.) Grant **Read and write** only if you push over HTTPS with *this* token (see below). |

> **Permission to resolve conversations:** the token's user needs **write or
> triage** access to the repository (or has to be the PR or comment author). A
> read-only collaborator can fetch and reply but can't resolve threads.

### About code pushes

Step 6 of the flow (applying approved fixes) is done by the orchestrator using
`git`, over whatever git auth you already have (SSH keys or a credential
helper), **not** this PAT. If you push over HTTPS using a token, that token
needs `repo` (classic) or **Contents: Read and write** (fine-grained).

### Narrowing the MCP surface *(applied by default)*

Two separate layers keep the surface small, and both come configured.

The server toolset: the plugin connects to the hosted server's
`/x/pull_requests` endpoint (or, if you run it locally, with
`-e GITHUB_TOOLSETS=pull_requests`), so only the pull-request toolset loads.
Repo admin, actions, code security, org, and file-write tools aren't even
registered.

The worker allowlist: the `tools:` line in `agents/github-worker.md` lists only
the five PR tools it actually calls: `list_pull_requests`,
`search_pull_requests`, `pull_request_read`,
`add_reply_to_pull_request_comment`, and `pull_request_review_write`.

This is separate from the PAT scopes above. The PAT is the real security
boundary at GitHub's API, while the toolset and allowlist limit what the model
can even try to call. Keep both tight. (If you switch to a different MCP
server, adjust these tool names, and if it can't resolve threads natively, rely
on the `gh` fallback.)

---

## Check the setup

Run the command against any PR you can access:

```
/resolve-pr-comments <PR number or URL>
```

Its preflight confirms GitHub access through a worker, checks `gh`, and, if
anything's missing, walks you through the fix before doing any work.

---

## Usage

```
/resolve-pr-comments            # asks which PR (defaults to this repo's remote)
/resolve-pr-comments 123        # target PR #123
/resolve-pr-comments <PR URL>
```

Or just ask in plain language, like *"resolve the unresolved review comments
on PR 123"*, and the bundled `resolve-pr-comments` skill starts the same flow.
The command and skill share one name and one procedure. The skill hands off to
the command file, so there's no duplicated logic to drift apart.

Here's how a run goes:

1. Preflight and onboarding, with an MCP-only health check.
2. One worker fetches the unresolved threads. It only fetches fields that
   can't be worked out another way, and hands off through a file on very large
   PRs.
3. The orchestrator assesses them, optionally consulting an advisor.
4. You approve, deny, or discuss each issue (or have it address them all).
5. The orchestrator fixes, commits, and pushes.
6. You confirm.
7. One batched worker posts every reply and resolves every thread. It returns
   `ok: <N> replied+resolved`, with detail only for failures, checked against
   the count it was sent.
8. Final report.

Batching, and only reporting exceptions, keeps the orchestrator's context
lean. Every worker dispatch has a fixed overhead (plus whatever ambient hooks
inject, such as a routing block), so a 5-thread run costs about 3 dispatches
instead of 7 or more.

---

## How the gate works

The GitHub MCP server is defined in the **plugin's `.mcp.json`**, so its tools
(namespaced `mcp__plugin_github-pr-toolkit_github__*`) are session-visible. The
delegation gate is enforced by the plugin's `PreToolUse` guard hook
(`hooks/guard.mjs`), which **holds the main agent's first GitHub call once per session**:

- **Main agent (no `agent_id` in the hook input) → held once per session.** In any
  session, and during its own `/code-critic` review alike, the main agent's first GitHub
  MCP or `gh` call is held once with a calm redirect to `github-pr-toolkit:github-worker`.
  A re-run proceeds under your normal permission rules, and nothing is held again that
  session.
- **The `gh` CLI shares that one hold with the MCP tools.** `gh` is GitHub I/O by another
  transport, so covering MCP while leaving `gh` out would leave the nudge toothless: an
  orchestrator without `create_pull_request` simply reaches for `gh pr create`. Exactly
  two carve-outs, both local credential checks returning no repository data, are never
  held: **`gh auth status`** and **`gh --version`** (`/github-pr-toolkit:doctor` needs
  them when MCP is what's broken).
  Detection is at command position only, so `grep 'gh api' file` and `echo "run gh auth"`
  are not false-blocked — but wrapper heads (`bash -c "gh …"`, `xargs`, `env`, `eval`)
  are covered, since a wrapper is a way to reach a shell without `gh` at the head of a
  Bash string. Inside the workers `gh` remains available as its gated fallback.

**Testing the guard:** `bash github-pr-toolkit/hooks/guard.test.sh` — 177 cases over
every rule, both directions (blocked *and* allowed), including that the armed-window git
rules do **not** reach the workers (`critic-worker` runs `git commit` in that exact
window, and stranding it would present as a worktree bug nowhere near the hook), and that
a reviewer's mutating Bash is never *granted* — asserted on the grant itself, since exit 0
covers both "allowed" and "not granted" and would hide a leaked grant.
Worth running after any edit to `guard.mjs`, because this hook fails **silently**: an
accidental exit 0, or a crash exiting 1, is indistinguishable from correct enforcement
until something that should have been blocked succeeds.

One documented limitation, asserted in the suite so it can't drift: the **assessing gate
and the reviewer Bash grant are head-only** — unlike the `gh` scan they don't look inside
a wrapper payload, so `bash -c "git diff"` is refused during assessment even though a
bare `git diff` is fine. That's the safe direction (a wrapper is exactly where a test run
would hide during a static review); re-issue without the wrapper.
- **This plugin's workers (`agent_type` is `github-worker`/`critic-worker`) →
  actively granted** (`permissionDecision: "allow"`), so the non-interactive Haiku
  workers run without prompts.
- **This plugin's review subagents (`agent_type` is `code-reviewer-*`) → granted
  Bash ONLY when every command segment is read-only inspection** and nothing
  outbound (`gh` / `git push|commit|worktree|pull`) rides along; anything else falls
  through and auto-denies, which enforces their static-review contract by
  construction. They are never granted the GitHub MCP tools. The reviewer agents ship
  no `tools:` allowlist — they inherit the session's tools, so any memory MCP server
  present comes along without enumeration — and their `disallowedTools` removes
  `Write`/`Edit`/`MultiEdit`/`NotebookEdit` outright. Bash can't be denied that way
  without costing them the read-only git they use to recompute the diff, so the hook
  gates it at runtime instead.
- **Any other subagent → normal permission flow** (prompt/rules decide). The resolve
  flow's `thread-assessor` lands here by design: it matches neither grant above, so it
  is shipped with **no Bash at all** (`Read`/`Grep`/`Glob` + `advisor` only, none of
  which this hook gates). Bash in that agent would fall through and auto-deny in a
  non-interactive subagent, stranding it mid-task — so don't add Bash to it without
  adding a matching branch to `guard.mjs`.

> **Why not the inline-frontmatter gate?** The original design scoped the server
> inline in each worker agent's `mcpServers:` frontmatter, so the orchestrator never
> had the connection at all. Claude Code **silently drops `mcpServers` (and
> `permissionMode`) in plugin agent frontmatter** (verified on v2.1.206: no server
> spawn, no `mcp-logs-*` dir, tools report "No such tool available") — so the server
> moved to `.mcp.json` and the gate moved into the hook.

---

## Security notes

This plugin's two workers are where GitHub work is meant to go. The guard hook
holds the main agent's first GitHub call in a session once and points it at
them; after that, the main agent can use the GitHub MCP tools under your normal
permission rules. What the workers can do is limited by their explicit `tools:`
allowlists, and by the
orchestrators handing them narrow, literal tasks. The workers also declare
`permissionMode: bypassPermissions` for their Bash use (the git and `gh`
fallback). Current Claude Code may not honor that frontmatter for plugin
agents, in which case their Bash calls follow your normal permission rules. The
`code-reviewer-*` subagents get no GitHub tools at all, and the guard hook
limits their Bash to read-only inspection commands that don't reach outside
the machine. A reviewer that tries to run tests, execute code, or push just
gets denied.

Keep the PAT out of version control, scope it to the repos you actually
review, and set an expiry.

---

## Troubleshooting

Start with `/github-pr-toolkit:doctor`. It first reports any orphaned
`/code-critic` review markers in `.git` and offers to clear them. Then it
probes the plugin's GitHub MCP server through both workers and reports whether
they can connect and authenticate, without running either flow. Then it walks
you through the fix and probes again.

- **Claude's first `gh` or GitHub MCP call in a session is held.** That is **by design,
  not a stuck lock**, in or out of a review — see the guard-hook section above. Re-run it
  (nothing is held again that session) or have Claude delegate to `github-worker`.
  `gh auth status` and `gh --version` are never held. The hold is the `covered` check
  plus `stopOnce` in `hooks/guard.mjs`.

- **`/code-critic` blocks `git commit` or `push`, or blocks Bash in general,
  when no review is running.** This one is the stuck-marker symptom: a run
  crashed and left a marker in `.git`. The guard ignores markers older than 8
  hours, so it clears up on its own. But a bare `.git/code-critic.lock` (armed
  when the session id wasn't available) blocks every session in the repo until
  then. Step 0 of `/github-pr-toolkit:doctor` lists the markers and offers to
  clear them. `/code-critic`'s own cleanup only runs the next time you start a
  review in that repo. To clear them by hand:
  `rm -f .git/code-critic*.lock .git/code-critic*.assessing .git/code-critic*.ctxmark`.

- **`No such tool available: mcp__plugin_github-pr-toolkit_github__*`.** The
  plugin's server never connected. The most common cause is an empty
  `github_pat` config, because **sensitive config values can be lost when
  Claude Code restarts or upgrades
  ([#62442](https://github.com/anthropics/claude-code/issues/62442))**.
  Re-enter the PAT through `/plugin` → `github-pr-toolkit` → Configure. Then
  check your network access to `api.githubcopilot.com`.
- **`permissions … haven't granted` from a worker.** The plugin's guard hook
  isn't loaded. Run `/reload-plugins` or restart the session.
- **Health check fails, or an auth error (401/403).** The PAT is invalid,
  expired, or missing scopes.
  `Incompatible auth server / does not support dynamic client registration`
  is a bad-PAT 401 in disguise (the bridge's OAuth
  fallback failing). Fix the PAT and ignore the OAuth wording.
- **Worker dispatches blocked by the permission classifier.** Don't phrase
  worker prompts with "ONLY use X" or "Y is FORBIDDEN". Next to the
  tool-routing text that ambient hooks inject, that reads as instructions from
  two conflicting sources, which looks like an injection. Say what success
  means instead of banning tools.
- **Can reply but can't resolve threads.** The token's user doesn't have write
  or triage access on the repo, or (on a non-official server) thread resolution
  isn't exposed. Install and authenticate `gh` for the fallback.
