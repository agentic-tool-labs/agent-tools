# 0070 — /pipeline merge guard, and per-run auto-merge approved one click at a time

Implementer: implementor
Reviewer: reviewer

Status: built on the 0068 branch. This version is smaller than what was
built: §2.5 lists what to remove. The evidence steps (§9) are done.

Docs: the README `/pipeline` section, including §2.1's boundary advice, and
the `pipeline-conventions.md` row for `pr.merge_method` belong to the
docs-writer, routed after the build. cli-tools.md and SKILL.md are part of
this build.

## 0. Summary

1. **A merge guard,** on whenever a pipeline run is open. It denies every
   way to merge, approve, ready or auto-merge a PR, except the one pinned
   merge in §4. It does nothing else. It matches command text, so it is a
   speed bump. The real boundary is GitHub's branch protection (§2.1).
2. **Auto-merge, per run.** An issue run started with `--auto-merge`, or
   with "auto-merge approved for this run", or that answered yes to the
   bootstrap question, may merge its ready PRs at the end of the run. Each
   merge is one command pinned to the PR's head commit:
   `gh pr merge <N> --match-head-commit <sha> --<method>`.
   - The hook answers it with the native permission prompt (`ask`) in the
     top-level session, and denies it everywhere else.
   - The user's click on that prompt is the approval. It is single-use, it
     is bound to the sha by `--match-head-commit`, and no session with Bash
     can mint it.
   - One click per merge.
3. **A branch-protection check** at run start. It warns in one line when
   the default branch has no protection on GitHub, and never blocks (§3.3).

Merging stays dangerous (0068 §3, D2). A merge under this opt-in is not a
decision. It is never classified, decided, or logged as `decided`.

The user's rulings:
- the approval is the Ultra-Advisor's B4, as written;
- the opt-in is asked once per run at bootstrap, default no, and never
  remembered;
- the explicit flag skips the question and means yes;
- **low friction:** the local guard covers merges only. GitHub's branch
  protection stops pushes. A run never halts over a command that isn't a
  merge form.

## 1. What exists today

- **Rules:** SKILL.md:944: "**Never** merge, approve, enable auto-merge, or
  edit a PR the run didn't open." The footer (:936-937): "…The run never
  merges; a person merges."
- **The push guard,** hooks/pretooluse-push-guard.mjs, Bash matcher
  (hooks.json:62):
  - its shell parsing (`parseShell`, `commandWord`, `gitInvocations`);
  - push rules only in opted-in repos;
  - deny format `ah-push-guard:<RULE> <detail>. Do not retry…`;
  - CLI `check`.
  - The skill halts on any `ah-push-guard:*` deny it doesn't name
    (:876-877).
- **Run detection:** `pipelineRunLive(cwd)` (lib-hier.mjs:513).
- **Caller identity:** `resolveHierarchyRole(input)`
  (lib-config.mjs:624-634).
- **Auto mode:** pipeline runs require `--permission-mode auto`
  (SKILL.md:71-73).
- **Pushes in a run:** unattended per-commit pushing needs an active push
  guard (opted in, with the bootstrap probe denied `PG-FORCE`,
  SKILL.md:951-958). Without one, push mode is `hook-inactive` and the run
  doesn't push unattended.

## 2. The merge guard (on during a run)

### 2.1 What it is, and what it isn't

- **What it is:** matching on the text of each Bash command, and on the
  name and input of GitHub MCP tool calls, before they run. It stops a
  model that follows the skill from merging, approving, readying or
  auto-merging a PR by mistake. It is a speed bump.
- **What it isn't:** a sandbox. A session with Bash can get past it with
  things the command text doesn't show:
  - a script file or an interpreter;
  - `curl` with the gh token;
  - aliases or config set up earlier;
  - `xargs` or `find -exec`.
- **The real boundary is on GitHub:**
  - **Pushes:** a branch protection rule or ruleset on the default branch
    that requires a pull request, with no bypass for the run's token. Admin
    bypass, if any, is for humans only. That stops direct pushes, ref writes
    and Contents API commits, by any route.
  - **Merges:** GitHub can't tell the user's click from the model's call,
    because both use the same token. Merge approval is a hard wall only
    when the run uses a separate identity (a bot account or a GitHub App
    token) that can't merge without the user's approving review. Setting
    that up is the user's call. The README says how.

### 2.2 Rules

While a run is live (§2.4) for the command's working directory, the push
guard also applies these rules, in every Claude session in that repo. They
don't need the repo to be opted in. Every rule is a merge form, so nothing
else is affected. Outside a run they do nothing.

| Rule | Denies |
|---|---|
| `PG-MERGE` | `gh pr merge` in any form except §4's |
| `PG-AUTOMERGE` | `gh pr merge` with `--auto`, `--disable-auto` or `--admin`, always |
| `PG-APPROVE` | `gh pr review` with `--approve` or `-a` |
| `PG-READY` | `gh pr ready` except in §4's compound form |
| `PG-API-MERGE` | as built: `gh api` hitting `pulls/<n>/merge`, `pulls/<n>/reviews` or `repos/<o>/<r>/merges`; a non-GET or field-carrying request to `git/refs/`; arguments containing `mergePullRequest`, `mergeBranch`, `updateRef`, `updateRefs`, `enablePullRequestAutoMerge`, `markPullRequestReadyForReview`, `addPullRequestReview`, `submitPullRequestReview` or `event=APPROVE`; `gh api graphql` whose query the guard can't read, in every spelling (`query=@…` attached or separate, `--field=`/`--raw-field=` forms, `--input`) |
| `PG-MCP-MERGE` | a GitHub MCP tool that merges, approves or readies (§2.3) |
| `PG-MERGE-ROLE` | §4's form from any caller but the top-level Orchestrator (§4.2) |
| `PG-MERGE-ERROR` | the merge rules threw, or liveness is unknown, on a merge-form command (§4.2a) |

- **Parsing, as built:**
  - reuse the push guard's shell parsing (wrappers, `env`, `bash -c`,
    subshells, `cd` chains);
  - each invocation's own working directory counts, as well as the
    session's cwd;
  - the `gh pr` subcommand is the first positional after `pr`, skipping
    `-R`/`--repo` in all four spellings (`-R <v>`, `-R<v>`, `--repo <v>`,
    `--repo=<v>`), also when they come before `pr`.
- **Skill handling:** every rule falls under the skill's existing "any
  other `ah-push-guard:*` deny → halt and notify" (:876-877). Each one is a
  merge form, so a halt only ever follows an attempt to merge. §4's form
  never reaches a deny in the right caller.

### 2.3 GitHub MCP merge tools

The GitHub MCP server that github-worker uses loads the `pull_requests`
toolset. That toolset has a merge tool, and github-worker's own tool list
can approve a PR and mark it ready. Without this rule, "only the pinned
click merges" is false.

While a run is live, for an MCP tool whose server name (the `<server>` in
`mcp__<server>__<tool>`) contains `github`, in any case:
- deny `PG-MCP-MERGE` when:
  - the tool name contains `merge`, in any case;
  - or any string value in its input is `APPROVE`, in any case;
  - or the tool is `update_pull_request` and its input sets `draft` to
    false.
- Allow everything else, with no output.

**How it's wired:**
- A new PreToolUse entry in `agent-hierarchy/hooks/hooks.json` matches MCP
  tool names. It runs the push guard, or a sibling script that shares its
  code; your call.
- A non-GitHub MCP tool exits at once, with no output.
- The deny reason starts `ah-push-guard:PG-MCP-MERGE <tool>`.
- Liveness comes from the payload's `cwd`.

**The no-MCP test:**
- `tests/test-ah-cli.sh` T7 bans the MCP tool prefix across ah's code and
  docs. It has one exemption: lib-config's `MCP_TOOL_PREFIX` line, the
  prefix role-pack checks use to read third-party tool names. This rule
  reads third-party tool names for the same reason, so:
  - the guard uses lib-config's `MCP_TOOL_PREFIX` (export it). It doesn't
    write the prefix again;
  - the hooks.json matcher line can't import a constant. It becomes T7's
    second exemption, matched by file and full line text like the first.
    T7's comment names both;
  - cli-tools.md, SKILL.md and the README say "GitHub MCP tools" in words,
    never with the prefix. `docs/specs/` is outside T7's scan.
- A matcher spelled to slip past the grep (`mcp_.*`) is rejected. It keeps
  the dependency and hides it from the test.

### 2.4 When a run counts as live

For the merge rules, liveness has three answers:
- **Not live:** for each hierarchy dir (main and worktree), either it
  provably doesn't exist (not-found from the filesystem), or it and its
  `msgs/` were listed and hold no open run anchor.
  - `existsSync` can't be the not-found test. It also answers false for a
    path it can't read.
- **Live:** an open anchor was found.
- **Unknown:** anything else, for example a permission error, `ENOTDIR`, or
  a throw.

Unknown is denied as `PG-MERGE-ERROR`, for merge-form commands only
(§4.2a). Other callers of `pipelineRunLive` are unchanged.

### 2.5 Not in this guard

Pushes are GitHub's job (§2.1). In an opted-in repo the push guard's own
push rules apply, as they did before this spec. Remove these from the
built code, tests and docs, and don't add them:
- **`PG-RUN-PUSH`,** the run's push rule for repos that aren't opted in. A
  run doesn't push unattended in such a repo (§1), so the rule guarded
  nothing the skill does on its own.
- **`PG-GIT-MERGE`,** the rule against a local `git merge`/`git pull` on
  the default branch. It's a local operation, landing it is a push, and it
  blocked an ordinary `git pull` in the user's other sessions.
- **Never built:**
  - allowlists for push, gh, `gh api` or MCP;
  - the switch-and-land compound rule;
  - binding only some sessions.

`git` commands are not merge forms for this guard: no `git` command is ever
denied by a run rule.

### 2.6 Not covered

These are listed in § Residual risk, beside §2.1's statement:
- `curl` and other API clients, `hub`, and gh aliases and extensions;
- scripts and interpreters;
- `xargs`- and `find -exec`-launched commands;
- MCP servers without `github` in their name;
- other ways to land on the default branch: pushes, Contents API commits,
  `merge-upstream`. GitHub's protection covers them.

  The threat model is the push guard's: it stops a compliant, mistaken
  model.

## 3. The opt-in, and the protection check

### 3.1 How a run opts in (issue runs only)

- `--auto-merge` on the invocation, or plain language with the same
  meaning ("auto-merge approved for this run", "with auto-merge", "and merge
  them once I approve") → **yes**, with no question. A misread sentence
  costs little: every merge still needs the user's click.
- Otherwise, bootstrap **step 3b** asks one `AskUserQuestion` (header
  "Auto-merge"): "May this run merge a ready PR once you approve that merge
  in a permission prompt?"
  - "No" is the first option, and the default;
  - "Yes, for this run".

  It can share the `AskUserQuestion` call with 0068's step 3a.
- **Plan runs** open no PR. With `--auto-merge` they refuse in one line:
  "auto-merge needs an issue run — plan runs open no PR". Without it, step
  3b isn't asked.
- **Per run only.** The answer goes in the anchor's `## constraints` (step
  5a) as `merge-opt-in: yes | no`, beside `merge-method:
  merge|squash|rebase`, which comes from `settings.pr.merge_method`. Nothing
  else stores it. The next run asks again. No conventions or config key
  turns it on.

### 3.2 Shown, unmissable

The run-start notification gets one of these lines, filled in and copied
exactly:
- yes: "Auto-merge APPROVED for this run: at the end of the run the
  orchestrator asks you to approve each ready PR's merge in a permission
  prompt — one click per merge, pinned to the PR's head commit."
- no: "Auto-merge: off — a person merges."

It also gets §3.3's protection line.

**PR footer,** § PR creation body item 6, when `merge-opt-in: yes`:
"Opened by an ah /pipeline run (anchor `<id>`). This run may merge it at the
end of the run, but only after you approve that merge in a permission
prompt; otherwise a person merges." With `merge-opt-in: no` the footer stays
as it is today.

### 3.3 Branch-protection check (warns, never blocks)

A read-only check, run once at bootstrap for every run, issue or plan.
- It lives in the push guard's CLI beside `check` and `merge-check`. If ah
  already has a `doctor` command, it can go there instead; your call.
- It finds the default branch the same way `merge-check` does.
- It reads two things:
  - `gh api repos/{owner}/{repo}/branches/<default>`, for its `protected`
    field;
  - `gh api repos/{owner}/{repo}/rules/branches/<default>`, for the
    rulesets that apply.
- The answer is **on** when `protected` is true, or when an applying rule
  has type `pull_request`. Otherwise it is **off**.
- It prints one line, and the skill copies it into the run-start
  notification:
  - on: "Branch protection on `<default>`: on."
  - off: "Branch protection on `<default>`: OFF — GitHub won't stop a push
    or a merge to it. See the README's /pipeline section."
  - any failure (no gh, not authenticated, an API error, no GitHub remote):
    "Branch protection on `<default>`: unknown (<reason>)."
- It never blocks, never halts, never asks, and writes nothing. It always
  exits 0.

## 4. The merge path

### 4.1 When, and the command

- **Merge point:** once only, at § End of run, after § Degraded approval
  when there is one, and before the final message. Never mid-run: a
  permission prompt would stall a hands-off run.
- Before the first prompt, send one notification: "Merge approvals are
  waiting for you in the session" (a new § Notification event).
- For each `pr-open` item, in `order`:
  1. Run `merge-check --pr <N>` (§4.3).
  2. Show one Markdown table in the session listing every candidate: PR,
     item, sha, merge-check result. Each row carries the run's
     `decision list --summary` line and a pointer to the PR body's
     "Decisions made on your behalf" section. Failing rows are listed with
     their reasons and are not attempted.
  3. For each passing PR, issue exactly one command:
     `gh pr merge <N> --match-head-commit <sha> --<method>`, or for a
     draft `gh pr ready <N> && gh pr merge <N> --match-head-commit <sha> --<method>`.
     The hook asks the user (§4.2).
- A declined prompt, or a merge that fails on GitHub (head moved, checks,
  protection), is not retried. The PR is reported with the manual command
  for the user's own terminal.

### 4.2 What the hook does with that command

- The command must be exactly the single or compound form above. In the
  merge, `<N>` and `--match-head-commit <sha>` are required (a 40-hex sha),
  and `--<method>` must equal the anchor's `merge-method`. No other flag or
  argument is allowed (`--repo`, `--delete-branch`, `--subject`, `--body`,
  `--auto`, `--admin`). In the compound form, both `<N>` match and
  `gh pr ready` has no other argument.
- The run must be open, with `merge-opt-in: yes`.
- The payload's `permission_mode` must be `default`, `auto` or
  `acceptEdits`. Under `bypassPermissions`, `dontAsk`, or a missing value,
  a hook's `ask` may not reach a human, so deny `PG-MERGE`.
- The caller must be **the top-level Orchestrator**, fail-closed:
  - the payload has no `agent_id`;
  - and either `agent_type` is absent with a persisted role (from
    `resolveHierarchyRole`) that is null or `orchestrator`, or `agent_type`
    resolves directly to `orchestrator`.

All hold → return `permissionDecision: "ask"` with a reason naming:
- the repo, the PR and the full sha. The repo comes from
  `remote.origin.url` with any userinfo (`user:token@`) stripped;
- the run's `decision list --summary` line;
- "flagged decisions for this PR are in its body under 'Decisions made on
  your behalf'";
- "approve only if you want this merged now".

The form is right but any other condition fails → deny `PG-MERGE-ROLE` for
a caller failure, or `PG-MERGE` for anything else. Never `allow`.

### 4.2a When the guard itself fails

The merge rules **fail closed during a run, for merge forms only.** A guard
whose job is to stop merges can't let one through because it crashed. A
guard bug must never block anything else.
- **Merge-form command,** decided from the raw text with no full parse, so
  it works even when parsing threw:
  - it must be true for every form §2.2 denies, the §4.1 forms included;
  - it must be false for reads: `gh pr view`, `gh pr view 7 --json
    mergeable`, `gh pr list --search merge`, `gh pr checks`,
    `gh api repos/o/r/pulls/7`, and every `git` command.
  - A GitHub MCP call is a merge form when its tool name contains `merge`
    or `update_pull_request`, or it carries an `APPROVE` value.
- **A merge-form command, and the merge rules throw** (parsing, reading the
  anchor or the decision log, resolving the caller):
  - liveness (§2.4) is live or unknown → deny with
    `ah-push-guard:PG-MERGE-ERROR <error message>`;
  - not live, determined without error → no output.
- **Never `ask` or `allow` on an error path,** the §4.1 form included.
- **Any other command,** and the push rules: unchanged. They keep the push
  guard's fail-open on error.

### 4.3 merge-check (read-only)

`node <ah>/hooks/pretooluse-push-guard.mjs merge-check --pr <N> --cwd <root>`
prints `{ ok, pr, sha, method, reasons: [<code>...], command }` and writes
nothing. It is advisory: it decides what the run offers. The click is the
approval, and the hook doesn't require that merge-check ran. All of these
must hold for `ok`:

1. **The run:** exactly one open anchor, with `merge-opt-in: yes`, and a
   valid `merge-method` [`no-run`, `off`, `no-method`].
2. **The item:**
   - the head is `ah/issue-<N>` with an open item record under the run's
     tag;
   - an Architect sign-off (`<tag>-i<N>-ok` responded);
   - no open `-x`;
   - status `pr-open`

   [`not-this-run`, `not-signed-off`, `exception`].
3. **The head:** state OPEN, and `headRefOid` equals the local
   `ah/issue-<N>` tip, which is the signed-off tip [`closed`,
   `head-moved`].
4. **Base and stack:** `baseRefName` is the default branch. A dependent
   needs its base PR MERGED and itself retargeted
   [`stacked-base-open`, `base-not-default`]. v1 deletes no branches, so
   stacked dependents usually stay unmerged and are reported.
5. **Mergeable:** `mergeable` MERGEABLE; `mergeStateStatus` CLEAN, or
   DRAFT for a draft [`not-mergeable:<status>`].
6. **Checks:** at least one check, and every `statusCheckRollup` entry
   completed SUCCESS, NEUTRAL or SKIPPED [`no-checks`, `checks-pending`,
   `checks-failed`]. With `ci_secrets: "skip-ci"` there are no checks, so
   nothing is offered.
7. **Reviews:**
   - `reviewDecision` is not CHANGES_REQUESTED;
   - no unresolved review thread (GraphQL `reviewThreads` `isResolved`);
     more than 100 threads → fail

   [`changes-requested`, `unresolved-threads`].

`command` is the exact §4.1 form for that PR, with `ready &&` for a draft.

### 4.4 The record

A merge is not a decision, but the report must show it. A **PostToolUse**
Bash handler sees each §4 command that ran. That happens only after the
user approved the prompt, because the hook never returns `allow` for the
form. It appends a `merge` line to the run's decision log through 0068's
writer core: `{ kind: "merge", pr, sha, method, time, approval:
"permission prompt", ran: true }`.

**What the line may claim:** only that the pinned command for that PR and
sha ran after the hook asked the user. It never claims the PR merged. The
handler fires whether gh succeeded or failed, so it writes no outcome
field. Whether the merge happened is read from GitHub at report time (§6),
never from this line.

- `msg.mjs decision add` refuses `kind: "merge"`, so the model's CLI path
  can't write one.
- `merge` lines count toward no cap and appear in no "Decisions" section.
- A declined prompt runs nothing, so it writes nothing.

## 5. Where it lives

- `agent-hierarchy/hooks/pretooluse-push-guard.mjs`: §2.2's rules, §4.2,
  `merge-check` and §3.3's check. Remove §2.5's rules. Its header says the
  merge rules read the run anchor and the decision log.
- `agent-hierarchy/hooks/hooks.json`: the MCP entry (§2.3). The Bash entry
  is unchanged.
- `agent-hierarchy/hooks/lib-config.mjs`: export `MCP_TOOL_PREFIX`.
- `agent-hierarchy/tests/test-ah-cli.sh`: T7's second exemption (§2.3).
- The §4.4 PostToolUse handler, in agent-hierarchy/hooks/.
- `agent-hierarchy/hooks/lib-conventions.mjs`: `pr.merge_method`
  (`"merge"` | `"squash"` | `"rebase"`, default `"merge"`), validated, and
  printed by `check`'s `settings`.
- 0068's writer lib: `kind: "merge"`, and the msg.mjs refusal.
- `agent-hierarchy/skills/autonomous-pipeline/SKILL.md`:
  - § Invocation: the flag and the plain-language forms, and the plan-run
    refusal;
  - § Bootstrap: step 3b; and §3.3's check, with its line in the run-start
    notification;
  - step 5a: the anchor lines;
  - § Notification: the fixed lines and the new event;
  - § PR creation: the footer. Item 5 becomes "Never merge, approve,
    enable auto-merge, or edit a PR the run didn't open — except § Merge on
    your approval";
  - new § Merge on your approval: §4.1 and §4.3;
  - § Decisions on the user's behalf, D2: add 0068 §3's sentence, "A merge
    done under the user's own per-run merge authorisation is not a
    decision…";
  - § End of run: the report (§6);
  - status derivation: a PR in state MERGED → `merged` (terminal);
  - § Residual risk: §2.1 in plain words ("a speed bump, not a sandbox",
    and the GitHub boundary), and §2.6's list. Remove the local
    `git merge` line (:1004) and every `PG-RUN-PUSH`/`PG-GIT-MERGE` mention;
  - § What this skill does not do: "No hook of its own" names the merge
    rules in the push guard, the MCP entry, and the PostToolUse record.
- `agent-hierarchy/docs/cli-tools.md`: `merge-check`, its reasons, §3.3's
  check, and the rule codes. Remove `PG-RUN-PUSH` and `PG-GIT-MERGE`.
- README `/pipeline` section (docs-writer, after the build):
  - recommend a ruleset or branch protection on the default branch that
    requires a pull request, with no bypass for the run's token, and admin
    bypass for humans only;
  - say that merge approval is a hard wall only with a separate bot or App
    identity for the run;
  - explain the run-start protection line.
- `on_item_done` is unchanged. It fires at `pr-open`, and a later merge
  doesn't call it again.
- Version: with 0068's release (0.109.0).

## 6. Final report

The final message gets **"Merges performed under your authorisation"**.
The merge state always comes from `gh pr view <N> --json
state,mergeCommit,mergedAt,headRefOid` at report time; the `merge` lines
say only which commands ran.
- **Listed as merged:** a PR with a `merge` line whose GitHub state is
  MERGED, and whose merged head equals the line's sha. Per PR: the sha,
  `mergedAt`, the approval ("your click on the permission prompt"), and
  the merge commit.
- **A `merge` line, but GitHub doesn't show it merged at that sha:**
  listed under "Not merged" as "head moved or merge refused", with the
  state GitHub reports.

Then **"Not merged",** for every other `pr-open` item: the merge-check
reasons, or "you declined", and the manual command
`gh pr merge <N> --match-head-commit <sha> --<method>`.

A PR that GitHub shows MERGED with no `merge` line was merged outside the
run. It is listed as "merged outside the run" and never counted as a merge
under your authorisation.

The section opens with the run-start line, copied.

## 7. Failure modes

| Case | Result |
|---|---|
| new commits after merge-check | GitHub refuses, through `--match-head-commit`. Any non-zero exit of the §4 command is reported as "head moved or merge refused", with gh's message verbatim (§9 E2) |
| an auto-decided commit after the table | the same: the sha changed, so the approval is void, which is the right failure |
| the user declines | nothing runs; reported "you declined" |
| a subagent or peer issues the form | `PG-MERGE-ROLE` |
| no opt-in | `PG-MERGE` for every form |
| the run halts | no end-of-run merge point, so nothing merges |
| the protection check can't run | "unknown (<reason>)" line; the run goes on |

## 8. Tests

Mutation standard. Use a fake `gh` on `PATH` with fixture JSON, and the
push guard's existing test pattern.

- **G1 Denies during a run.** One row each for:
  - `gh pr merge 7`, `--auto`, `--admin`;
  - `gh pr review 7 --approve` and `-a`;
  - `gh pr ready 7`;
  - `gh api -X PUT repos/o/r/pulls/7/merge`;
  - `gh api repos/o/r/pulls/7/reviews -f event=APPROVE`;
  - `gh api repos/o/r/merges -f base=main -f head=x`;
  - `gh api -X PATCH repos/o/r/git/refs/heads/main -f sha=…`;
  - graphql `mergePullRequest`, `mergeBranch`, `enablePullRequestAutoMerge`,
    `markPullRequestReadyForReview`;
  - graphql with an unreadable query: `-F query=@q.graphql`,
    `-Fquery=@q.graphql`, `--field=query=@q.graphql`,
    `--raw-field=query=@q.graphql`, `--input q.json`.

  Plus the wrapped forms `env X=1 …`, `bash -c "…"` and `(cd sub && …)`.
  Plus `gh pr -R o/r merge 7`, `gh pr --repo o/r merge 7`,
  `gh pr --repo=o/r review 7 --approve`, `gh -R o/r pr ready 7`. Plus the
  session cwd outside the repo, with `cd <run repo> && gh pr merge 7`.

  [drop each rule in turn] [skip wrapper parsing] [read the verb as
  args[1]] [use only the session cwd] [skip the attached query spellings]
- **G2 No run, no effect.** No open anchor → no deny for any of them.
  [deny outside a run]
- **G3 Ask.** With an open run, `merge-opt-in: yes` and a top-level
  payload:
  - the single form returns `ask`;
  - the compound form returns `ask`;
  - the reason holds the PR, the sha and the summary line.

  [return allow] [omit the sha from the reason]
- **G4 Form refusals,** one row each:
  - no `--match-head-commit`; a short sha; the wrong method;
  - each extra flag;
  - a compound form with a mismatched `<N>`;
  - `merge-opt-in: no`.

  [one mutation per check]
- **G4b Permission mode.** The pinned form, top-level and opted in, with
  `permission_mode` set to `bypassPermissions`, `dontAsk`, or missing →
  `PG-MERGE`; with `auto` → `ask`. [ignore permission_mode]
- **G4c No credentials in the prompt.** With
  `remote.origin.url=https://u:tok@github.com/o/r.git`, the `ask` reason
  contains `github.com/o/r` and not `tok`. [print the URL verbatim]
- **G5 Callers,** one row each:
  - `agent_id` present;
  - `agent_type: "ah:implementor"`;
  - a persisted implementor role with no `agent_type`;
  - a non-ah subagent `agent_type`.

  All → `PG-MERGE-ROLE`. [skip the agent_id check]
- **G6 Fail closed for merge forms only.** Force a throw in the merge rules
  (an unreadable decision log, or a stubbed liveness that throws):
  - the pinned form with the run's `decisions.jsonl` unreadable (a
    directory in its place) → `PG-MERGE-ERROR`, not `ask`;
  - `gh pr merge 7` with liveness throwing → `PG-MERGE-ERROR`;
  - with no run live → no output;
  - with a run live and the same throw, each of these → no output: `ls`,
    `git push origin ah/issue-5`, `git merge x`, `gh pr view 7 --json
    mergeable`, `gh pr list --search merge`, `gh api repos/o/r/pulls/7`;
  - **liveness unknown:** a hierarchy dir, or its parent, made unreadable
    (chmod 000), then `gh pr merge 7` → `PG-MERGE-ERROR`. The same setup
    with `gh pr view 7` → no output.

  [fail open during a run] [fail closed for every command] [count `git` or
  a read as a merge form] [read an unreadable dir as no run]
- **G7 GitHub MCP tools.** A run live.
  - Each of these → `PG-MCP-MERGE`:
    - `mcp__plugin_github-pr-toolkit_github__merge_pull_request`;
    - `mcp__github__merge_pull_request`, a server with another name;
    - `…__pull_request_review_write` with `event: "APPROVE"`;
    - `…__update_pull_request` with `draft: false`.
  - These → no output:
    - `…__pull_request_review_write` with `event: "COMMENT"`;
    - `…__update_pull_request` with only `title`;
    - `…__create_pull_request`, `…__pull_request_read`;
    - `mcp__blender__get_scene_info`, not a GitHub server;
    - any of the denied calls with no run live.
  - T7 stays green, with exactly two exempt lines.

  [match only one server name] [skip the APPROVE check] [apply outside a
  run]
- **G8 Removed rules stay removed.** A run live, repo not opted in, each →
  no output: `git push origin HEAD:main`, `git push --all origin`,
  `git checkout main && git merge ah/issue-5 && git push`, `git pull` on
  main. In an opted-in repo, the push guard's own push rules give the same
  answers as before this spec. [keep PG-RUN-PUSH] [keep PG-GIT-MERGE]
- **P1 Protection check.** With fixture `gh` output:
  - `protected: true` → the "on" line;
  - `protected: false` and a `pull_request` rule → "on";
  - `protected: false`, no rules → the "OFF" line;
  - gh exiting non-zero → "unknown (<reason>)".

  Every row exits 0 and writes no file. [block on off] [treat unknown as
  on] [ignore rulesets]
- **C1 merge-check.** Each §4.3 reason in its own row, from fixture output.
  All good → `ok` with the exact `command`, and draft → the compound form.
  It never writes a file. [drop each precondition in turn]
- **R1 Record.**
  - The PostToolUse handler appends one `merge` line for a §4 command,
    with `ran: true` and no outcome field.
  - It writes none for any other Bash command.
  - `msg.mjs decision add` refuses `kind: "merge"`.

  [record every gh command] [allow the CLI to write merge] [write an
  outcome field]
- **R2 Report state.** With a fixture `gh pr view`:
  - a `merge` line plus MERGED at the same sha → listed as merged;
  - a `merge` line plus OPEN → "head moved or merge refused";
  - MERGED with no line → "merged outside the run".

  The report section's builder is skill text, so assert these through the
  K anchors if no code builds the section.

  [trust the line as merged]
- **V1** `pr.merge_method` is validated, defaulted and printed by `check`.
- **K Skill anchors:**
  - `--auto-merge` and the plain-language line;
  - step 3b's question, with "No" first;
  - the plan-run refusal;
  - the two run-start lines, verbatim, and the three protection lines;
  - "head moved or merge refused";
  - "merged outside the run", and "never from this line";
  - `PG-MERGE-ERROR`, `PG-MCP-MERGE`;
  - § Residual risk: "a speed bump, not a sandbox", the GitHub boundary,
    and the `xargs`/`find -exec` line;
  - no `PG-RUN-PUSH` or `PG-GIT-MERGE` anywhere in SKILL.md or
    cli-tools.md;
  - the footer;
  - "Merge approvals are waiting for you in the session";
  - the end-of-run-only merge point;
  - both command forms;
  - the report headings;
  - the item-5 exception.

Then run the full suite.

## 9. Evidence (done)

**Outcomes** (Claude Code 2.1.286, gh 2.96.0, 2026-09-30):
- **E1 positive.** In an interactive `claude --permission-mode auto`
  session, a PreToolUse hook's `ask` for a Bash command reached the human.
  The payload carries `permission_mode` ("auto").
- **E2 skipped** (the user's choice: no throwaway PR). Any non-zero exit of
  the §4 command is reported as "head moved or merge refused", with gh's own
  message verbatim.
- **E3 positive.** Plain top-level: no `agent_id`, no `agent_type`.
  Top-level `--agent ah:orchestrator`: `agent_type: "ah:orchestrator"`, no
  `agent_id`. Top-level `--agent ah:implementor`: `agent_type:
  "ah:implementor"`, no `agent_id`. A general-purpose subagent: `agent_id`
  and `agent_type: "general-purpose"`. §4.2 stands.
- **E4 positive.** `gh pr view --json` returns all eight fields; `gh pr
  merge --help` lists `--match-head-commit`; GraphQL
  `reviewThreads(first: 100) { totalCount nodes { isResolved } }` answers.

## 10. Assumptions not verified

- GitHub reports `mergeStateStatus` DRAFT for drafts, and `gh pr ready`
  doesn't change the head sha.
- A PostToolUse Bash event fires only after the command ran, so a declined
  prompt writes no `merge` line.
- A hook's `ask` still shows the prompt when the user's settings carry an
  allow rule matching `gh pr merge`. The report's merge state comes from
  GitHub either way.
- The run's Orchestrator session is interactive, as E1 tested. A
  non-interactive session (`claude -p`) is not supported for auto-merge.
- `GET repos/{o}/{r}/branches/<b>` returns `protected` to a token with read
  access, and `GET repos/{o}/{r}/rules/branches/<b>` lists the ruleset
  rules that apply, with `type: "pull_request"` for a required PR. If
  either is wrong, the check says "unknown" and the run goes on.
- GitHub applies a ruleset or branch protection that requires a pull
  request to Contents API commits and ref writes, not only to pushes.
- The `pull_requests` MCP toolset's merge tool has `merge` in its name.

## 11. Open questions for the user (defaults taken)

- **Q1 Merge method default:** `merge` (default; keeps stacked dependents
  mergeable after their base merges); or `squash`.
- **Q2 Delete merged head branches** (lets stacked PRs retarget and merge
  in the same run): no (default, v1); or yes, as an allowed
  `--delete-branch` in §4's form.

## 12. Decisions

- **The approval primitive is the native permission prompt** (the user's
  ruling, the Ultra-Advisor's B4). Rejected: an authorisation line minted
  by `merge-check`, which any Bash session could mint; and GitHub-review
  evidence.
- **The local guard covers merges only** (the user's ruling: low friction,
  no traps). GitHub's branch protection stops pushes. Allowlists for push,
  gh, `gh api` and MCP were designed and dropped: each could halt a run over
  a command that isn't a merge, and they bound the user's other sessions.
  `PG-RUN-PUSH` and `PG-GIT-MERGE` are removed for the same reason.
- **The rules bind every Claude session in the repo during a run:** they
  deny only merge forms, so the cost is that only the run's pinned click
  merges while a run is open. That is the user's model.
- **The protection check warns and never blocks:** it points the user at
  the real boundary without stopping a run.
- **GitHub MCP merge tools are covered:** it is cheap, and without it "only
  the pinned click merges" is false.
- **The guard lives in the push guard:** one parser, one deny format, and
  the skill's existing halt handling.
- **Merges only at the end of the run:** a mid-run prompt would stall a
  hands-off run.
- **merge-check is advisory:** the click is the authority, and merge-check
  only decides what is offered.
- **The `merge` record is written by a hook, not the CLI:** a PostToolUse
  event exists only for a command the user approved.
- **on_item_done is untouched:** no new status for teams' skills.
