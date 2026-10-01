# 0070 — /pipeline merge guard, and per-run auto-merge approved one click at a time

Implementer: implementor
Reviewer: reviewer

Status: not built. Build after 0068, on the same branch (0068 §11). Begin
with the evidence steps (§9); their results decide what gets built.

Docs: the README `/pipeline` section and the `pipeline-conventions.md` row
for `pr.merge_method` belong to the docs-writer, routed after the build.
cli-tools.md and SKILL.md are part of this build.

## 0. Summary

1. **A merge guard,** on whenever a pipeline run is open. It denies every
   way a run could merge, approve, ready or auto-merge a PR. It matches
   command text and lives in the push guard (§2).
2. **Auto-merge, per run.** An issue run started with `--auto-merge`, or
   with "auto-merge approved for this run", or that answered yes to the
   bootstrap question, may merge its ready PRs at the end of the run. Each
   merge is one command pinned to the PR's head commit:
   `gh pr merge <N> --match-head-commit <sha> --<method>`.
   - The hook answers it with the native permission prompt (`ask`) in the
     top-level session, and denies it everywhere else.
   - The user's click on that prompt is the approval. It is the only
     approval channel a model can't answer: single-use by construction,
     bound to the sha by `--match-head-commit`, and nothing a session with
     Bash can mint.
   - One click per merge.

Merging stays dangerous (0068 §3, D2). A merge under this opt-in is not a
decision. It is never classified, decided, or logged as `decided`.

The user's rulings:
- the approval is the Ultra-Advisor's B4, as written;
- the opt-in is asked once per run at bootstrap, default no, and never
  remembered;
- the explicit flag skips the question and means yes.

## 1. What exists today

- **Rules:** SKILL.md:944: "**Never** merge, approve, enable auto-merge, or
  edit a PR the run didn't open." The footer (:936-937): "…The run never
  merges; a person merges." Both are text only. The residual-risk list
  admits "`gh` misuse, which the guard does not inspect" (:694).
- **The push guard,** hooks/pretooluse-push-guard.mjs, Bash matcher
  (hooks.json:62):
  - shell parsing: `parseShell` :37-146, `commandWord` :167-210;
  - push rules only in opted-in repos (:299-300, :564-565);
  - deny format `ah-push-guard:<RULE> <detail>. Do not retry…`
    (:504-506);
  - CLI `check` (:571).
  - The skill halts on any `ah-push-guard:*` deny it doesn't name
    (:876-877).
- **Run detection:** `pipelineRunLive(cwd)` (lib-hier.mjs:513).
- **Caller identity:** `resolveHierarchyRole(input)`
  (lib-config.mjs:624-634). It returns `direct: true` only when the
  payload's `agent_type` names an ah role; otherwise the session-keyed
  persisted role. A subagent shares its parent's `session_id`.
- **Auto mode:** pipeline runs require `--permission-mode auto`
  (SKILL.md:71-73).
- **`settings.pr`** (lib-conventions.mjs:120-121): `draft`, `issue_link`,
  `reviewers`.

## 2. The merge guard (always on during a run)

While `pipelineRunLive(cwd)` is true for the command's working directory,
the push guard also applies the rules below. They don't need the repo to be
opted in. Outside a run they do nothing, so ordinary sessions merge as
today.

| Rule | Command text |
|---|---|
| `PG-MERGE` | `gh pr merge` in any form except §4's |
| `PG-AUTOMERGE` | `gh pr merge` with `--auto`, `--disable-auto` or `--admin`, always |
| `PG-APPROVE` | `gh pr review` with `--approve` or `-a` |
| `PG-READY` | `gh pr ready` except in §4's compound form |
| `PG-API-MERGE` | `gh api` whose arguments hit `pulls/<n>/merge`, `pulls/<n>/reviews`, or `repos/<o>/<r>/merges` (any method); or any non-GET request, or any request with `-f`/`-F`/`--field`/`--raw-field`/`--input`, to a `git/refs/` path; or whose arguments contain `mergePullRequest`, `mergeBranch`, `updateRef`, `updateRefs`, `enablePullRequestAutoMerge`, `markPullRequestReadyForReview`, `addPullRequestReview`, `submitPullRequestReview` or `event=APPROVE`; or `gh api graphql` whose query isn't inline text (`query=@<file>`, `--input`), because the guard can't read it |
| `PG-RUN-PUSH` | `git push` whose destination is the default branch or a protected branch, in **any** repo, opted in or not. The default branch is origin/HEAD's target; when that can't be resolved, both `main` and `master` count as default. Protected branches come from the conventions when the repo has them |
| `PG-GIT-MERGE` | `git merge` or `git pull` while HEAD is the default branch or a protected branch (`branchProtected`, :310-312) |
| `PG-MERGE-ROLE` | §4's form from any caller but the top-level Orchestrator (§4.2) |
| `PG-MERGE-ERROR` | the merge rules threw on a merge-related command while a run is live, or while liveness couldn't be determined (§4.2a) |

- **Parsing:** reuse the push guard's shell parsing, so wrappers, `env`,
  `bash -c`, subshells and `cd` chains are seen exactly as push rules see
  them. Don't write a second parser. Shared lib or same file is your call.
  - **Which directory counts:** each merge-type invocation's own working
    directory (after `cd`), as well as the session's cwd. If
    `pipelineRunLive` is true for any of them, the rules apply.
  - **The `gh pr` subcommand** is the first positional argument after
    `pr`, skipping `-R <v>`, `-R<v>`, `--repo <v>` and `--repo=<v>`. So
    `gh pr -R o/r merge 7` is a merge.
- **Push rules overlap:** in an opted-in repo the push guard's own rules
  still apply to every push, and `PG-RUN-PUSH` adds nothing new there.
  `PG-RUN-PUSH` is what covers a repo that hasn't opted in while a run is
  live.
- **Skill handling:** every rule above already falls under the skill's
  existing "any other `ah-push-guard:*` deny → halt and notify" (:876-877).
  §4's form never reaches a deny in the right caller.
- **Not covered,** listed in § Residual risk:
  - `curl` and other API clients, `hub`, `gh` aliases and extensions;
  - `xargs`- and `find -exec`-launched commands, which the shared parser
    doesn't unwrap;
  - a local `git merge` after a `git checkout`/`git switch` to the default
    branch in the same command (`PG-GIT-MERGE` keys on HEAD at hook time).
    Pushing that merge is caught by `PG-RUN-PUSH`;
  - any other evasion of command-text matching.

  The threat model is the push guard's: it stops a compliant, mistaken
  model.

## 3. The opt-in

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

E1 was positive (§9), so the "merges stay manual" variant is not built.

**PR footer,** § PR creation body item 6, when `merge-opt-in: yes`:
"Opened by an ah /pipeline run (anchor `<id>`). This run may merge it at the
end of the run, but only after you approve that merge in a permission
prompt; otherwise a person merges." With `merge-opt-in: no` the footer stays
as it is today.

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
  a hook's `ask` may not reach a human, so deny `PG-MERGE`. Pipeline runs
  require auto mode anyway (SKILL.md:71-73), so a compliant run loses
  nothing. This replaces an evidence step: it costs less than the probe
  and holds whatever bypass mode does.
- The caller must be **the top-level Orchestrator**, fail-closed:
  - the payload has no `agent_id`;
  - and either `agent_type` is absent with a persisted role (from
    `resolveHierarchyRole`) that is null or `orchestrator`, or `agent_type`
    resolves directly to `orchestrator`.

  It depends on §9 E3.

All hold → return `permissionDecision: "ask"` with a reason naming:
- the repo, the PR and the full sha. The repo comes from
  `remote.origin.url` with any userinfo (`user:token@`) stripped, so no
  credential reaches the prompt or the transcript;
- the run's `decision list --summary` line;
- "flagged decisions for this PR are in its body under 'Decisions made on
  your behalf'";
- "approve only if you want this merged now".

The form is right but any other condition fails → deny `PG-MERGE-ROLE` for
a caller failure, or `PG-MERGE` for anything else. Never `allow`.

### 4.2a When the guard itself fails

The merge rules **fail closed during a run**: a guard whose job is to stop
merges can't let one through because it crashed. Scope it so that a guard
bug can't block unrelated commands:
- **Merge-related command:** the command's raw text contains `gh` together
  with one of `merge`, `review`, `ready` or `api`, or `git` together with
  `merge`, `pull` or `push`. This is a plain substring test on the raw text, so it
  works even when parsing threw.
- **A merge-related command, and the merge rules throw** (parsing, reading
  the anchor or the decision log, resolving the caller):
  - `pipelineRunLive` returned true, or itself threw → deny with
    `ah-push-guard:PG-MERGE-ERROR <error message>`. The skill's existing
    "any other deny → halt and notify" covers it.
  - `pipelineRunLive` returned false (no run, determined without error) →
    fail open (exit 0, no output). Outside a run the merge rules have no
    job.
- **Never `ask` or `allow` on an error path,** the §4.1 form included.
- **Commands that aren't merge-related,** and the push rules: unchanged.
  They keep the push guard's existing fail-open on error.

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
- The handler goes in the existing Bash PostToolUse entry
  (hooks.json:167), or a new entry; your call.
- A declined prompt runs nothing, so it writes nothing.

## 5. Where it lives

- `agent-hierarchy/hooks/pretooluse-push-guard.mjs`: the §2 rules, §4.2
  and `merge-check`. Its header says it is stateless; it now reads the run
  anchor and the decision log, so update the header.
- The §4.4 PostToolUse handler, in agent-hierarchy/hooks/.
- `agent-hierarchy/hooks/lib-conventions.mjs`: `pr.merge_method`
  (`"merge"` | `"squash"` | `"rebase"`, default `"merge"`), validated, and
  printed by `check`'s `settings`.
- 0068's writer lib: `kind: "merge"`, and the msg.mjs refusal.
- `agent-hierarchy/skills/autonomous-pipeline/SKILL.md`:
  - § Invocation: the flag and the plain-language forms, and the plan-run
    refusal;
  - § Bootstrap: step 3b;
  - step 5a: the anchor lines;
  - § Notification: the three fixed lines and the new event;
  - § PR creation: the footer. Item 5 becomes "Never merge, approve,
    enable auto-merge, or edit a PR the run didn't open — except § Merge on
    your approval";
  - new § Merge on your approval: §4.1 and §4.3;
  - § Decisions on the user's behalf, D2: add 0068 §3's sentence, "A merge
    done under the user's own per-run merge authorisation is not a
    decision…". The 0068 build left it out because this spec wasn't built
    yet;
  - § End of run: the report (§6);
  - status derivation: a PR in state MERGED → `merged` (terminal);
  - § Residual risk: §2's not-covered list;
  - § What this skill does not do: "No hook of its own" names the merge
    rules in the push guard and the PostToolUse record.
- `agent-hierarchy/docs/cli-tools.md`: `merge-check`, its reasons, and the
  rule codes.
- `on_item_done` is unchanged. It fires at `pr-open`, and a later merge
  doesn't call it again.
- Version: with 0068's release (0.109.0), or the next minor after it.

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

## 8. Tests

Mutation standard. Use a fake `gh` on `PATH` with fixture JSON, and the
push guard's existing test pattern.

- **G1 Denies during a run.** One row each for:
  - `gh pr merge 7`, `--auto`, `--admin`;
  - `gh pr review 7 --approve` and `-a`;
  - `gh pr ready 7`;
  - `gh api -X PUT repos/o/r/pulls/7/merge`;
  - `gh api repos/o/r/pulls/7/reviews -f event=APPROVE`;
  - graphql `mergePullRequest`, `enablePullRequestAutoMerge`,
    `markPullRequestReadyForReview`;
  - `git merge x` and `git pull` on the default branch.

  Plus the wrapped forms `env X=1 …`, `bash -c "…"` and `(cd sub && …)`.
  Plus:
  - `gh pr -R o/r merge 7`, `gh pr --repo o/r merge 7`, `gh pr --repo=o/r
    review 7 --approve`, `gh pr -R o/r ready 7`;
  - `gh api repos/o/r/merges -f base=main -f head=x`;
  - `gh api -X PATCH repos/o/r/git/refs/heads/main -f sha=…`;
  - `gh api repos/o/r/git/refs -f ref=refs/heads/x -f sha=…`;
  - `gh api graphql -f query='mutation{mergeBranch…}'`, and
    `gh api graphql -F query=@q.graphql`;
  - session cwd outside the repo, with `cd <run repo> && gh pr merge 7`.

  [drop each rule in turn] [skip wrapper parsing] [read the verb as
  args[1]] [use only the session cwd]
- **G1b Push during a run, repo not opted in.** No conventions file, a run
  live:
  - `git push origin ah/issue-5:main` → `PG-RUN-PUSH`;
  - `git push origin HEAD:master` with no origin/HEAD → `PG-RUN-PUSH`;
  - `git push origin ah/issue-5` → no output.

  [apply only in opted-in repos] [skip the main/master fallback]
- **G4b Permission mode.** The pinned form, top-level and opted in, with
  `permission_mode` set to `bypassPermissions`, `dontAsk`, or missing →
  `PG-MERGE`; with `auto` → `ask`. [ignore permission_mode]
- **G4c No credentials in the prompt.** With
  `remote.origin.url=https://u:tok@github.com/o/r.git`, the `ask` reason
  contains `github.com/o/r` and not `tok`. [print the URL verbatim]
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
- **G5 Callers,** one row each:
  - `agent_id` present;
  - `agent_type: "ah:implementor"`;
  - a persisted implementor role with no `agent_type`;
  - a non-ah subagent `agent_type`.

  All → `PG-MERGE-ROLE`. [skip the agent_id check]
- **C1 merge-check.** Each §4.3 reason in its own row, from fixture output.
  All good → `ok` with the exact `command`, and draft → the compound form.
  It never writes a file. [drop each precondition in turn]
- **G6 Fail-closed on error.** Force a throw in the merge rules (e.g. an
  unreadable decision log, or a stubbed `pipelineRunLive` that throws):
  - a merge-related command with a run live, or with `pipelineRunLive`
    throwing → deny `PG-MERGE-ERROR`. One row is the pinned form with the
    run's `decisions.jsonl` unreadable (a directory in its place) → deny,
    not fall-through and not `ask`;
  - with no run live → no output;
  - a non-merge command (`ls`) with a run live and the same throw → no
    output.

  [fail open during a run] [fail closed for every command]
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
  - the two run-start lines, verbatim;
  - "head moved or merge refused";
  - "merged outside the run", and "never from this line";
  - `PG-MERGE-ERROR`, `PG-RUN-PUSH`;
  - § Residual risk: the `xargs`/`find -exec` and checkout-then-merge
    lines;
  - the footer;
  - "Merge approvals are waiting for you in the session";
  - the end-of-run-only merge point;
  - both command forms;
  - the report headings;
  - the item-5 exception.

Then run the full suite.

## 9. Evidence steps (NEEDS-EVIDENCE, first in the build)

- **E1 `ask` under auto mode.** In a `--permission-mode auto` session, a
  PreToolUse hook returns `permissionDecision: "ask"` for a Bash command.
  Does the human get the prompt, or does auto mode answer it? Record also
  whether the PreToolUse payload carries `permission_mode`.
  - **Surfaces to the human** → build §3-§4 as written.
  - **Auto mode answers it** → don't build §4's ask path. With
    `merge-opt-in: yes`, the hook denies the form (`PG-MERGE`) exactly as
    with no opt-in. The run-start line is the "merges stay manual" one, the
    footer stays as it is today, the end-of-run merge point shows only the
    table with the manual commands, and §4.4 isn't built. §2, step 3b, the
    anchor lines, merge-check and the report's "Not merged" are still
    built.
- **E2 Stale sha.** The exit code and message of
  `gh pr merge <N> --match-head-commit <stale sha>`, so the report can say
  "head moved since approval". If gh's message can't be told apart, report
  "merge failed: <gh message>".
- **E3 Caller fields.** With a logging PreToolUse hook, record whether
  `agent_id`, `agent_type` and `session_id` are present for a Bash call
  from:
  - (a) a plain top-level session;
  - (b) a top-level `--agent ah:orchestrator` session;
  - (c) a subagent of (a);
  - (d) a peer `--agent ah:implementor` session.
  - `agent_id` only in (c) → §4.2 stands.
  - No `agent_id` in (c) → narrow §4.2 to "no `agent_type` and a persisted
    role that is null or orchestrator". A `--agent ah:orchestrator`
    top-level session then can't use the path; document that.
- **E4 gh fields.** `gh pr view --json
  state,isDraft,headRefOid,baseRefName,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup`
  returns those fields in the installed gh, and `gh pr merge --help` lists
  `--match-head-commit`. A missing field → the REST or GraphQL equivalent;
  if there is none, stop and report. No `--match-head-commit` → step 3b and
  the flag refuse with "gh too old for pinned merges".

**Outcomes** (Claude Code 2.1.286, gh 2.96.0, 2026-09-30):
- **E1 positive.** In an interactive `claude --permission-mode auto`
  session, a PreToolUse hook's `ask` for a Bash command reached the human:
  "Hook PreToolUse:Bash requires confirmation for this command … Do you want
  to proceed? 1. Yes 2. No". §3-§4 are built as written. The payload carries
  `permission_mode` ("auto").
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
  allow rule matching `gh pr merge`. If such a rule could skip the prompt,
  the record's `approval` field would overclaim. The report's merge state
  comes from GitHub either way.
- The run's Orchestrator session is interactive, as E1 tested. In a
  non-interactive session (`claude -p`) nobody can answer an `ask`; that
  wasn't tested and is not supported for auto-merge.

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
- **The guard lives in the push guard:** one parser, one deny format, and
  the skill's existing halt handling.
- **Merges only at the end of the run:** a mid-run prompt would stall a
  hands-off run.
- **merge-check is advisory:** the click is the authority, and merge-check
  only decides what is offered.
- **The `merge` record is written by a hook, not the CLI:** a PostToolUse
  event exists only for a command the user approved.
- **on_item_done is untouched:** no new status for teams' skills.
