# 0068 — /pipeline decides non-dangerous calls itself, and records every one

Implementer: implementor
Reviewer: reviewer

Status: not built. One phase, next ah minor (0.109.0). See §11 for the
branch to build it on.

Docs: the README's `/pipeline` section belongs to the docs-writer. Route it
separately once this lands (§7).

## 0. Summary

While a `/pipeline` run is active, a question that today would wait for the
user is first classified. A **dangerous** question still goes to the user. A
**safe** one goes to the highest-reasoning decider available: the
Ultra-Advisor, else the highest-tier chain role, else a fresh subagent on
the Orchestrator's own model (never the Orchestrator's own context). That
decider answers on the user's behalf.

Every decision is appended to a per-run log,
`<hier>/pipeline/<anchor id>/decisions.jsonl`, written and read only through
a new CLI verb, `msg.mjs decision add|list`. The run's final message carries
a report built from that log.

Unknown means dangerous. The writer refuses any line that says both
`decided` and `dangerous`. The classification itself is the model's, so that
refusal is a bookkeeping rule, not a boundary. The boundaries are the
two-key classification (§3) and the effect-level guards it never replaces.

The user's words: "should automatically escalate to the highest reasoning
model to make decisions for the user on non-dangerous decisions. The goal is
to keep the work moving forward. Any decisions decided for the user however
MUST be recorded for a report after all work is done".

## 1. What exists today

- **Routing:** "a call that is properly the user's → Ultra-Advisor"
  (skills/autonomous-pipeline/SKILL.md:129). The Ultra-Advisor writes it into
  `open_questions`, and the Orchestrator pages the user (:191-202).
- **Escalation ladder,** skills/agent-team/SKILL.md:1143-1232:
  1. a live or roster Ultra-Advisor;
  2. ask the user to spawn one;
  3. the highest-reasoning chain role, ranked haiku < sonnet < opus < fable,
     with untiered members below every tiered one; ties go live first, then
     design > review > implement, then roster order (:1177-1189);
  4. the Orchestrator adjudicates itself.

  Approval comes first: `gate.mjs status --session <id>` returns none, off,
  session or each (:1146-1153).
- **Ultra-Advisor gate:** hooks/pretooluse-ultra-gate.mjs. The choice is
  stored per session in `~/.claude/agent-hierarchy.gate.json` through
  `gate.mjs set --session <id> --choice session|each|off`.
- **Tier rule** (agents/orchestrator.md:93-94): don't dispatch an advisor at
  or below your own tier without a `reason:` (context, second-opinion,
  parallel). `TIER` and `tierOf` live at hooks/lib-config.mjs:280-287.
- **Rounds:** the 3-round cap counts exchanges by slug
  (SKILL.md:204-239). Issue runs cap plan rounds at 2, each step at 3 and
  the gate at 3 (:795).
- **Notifications** (:533-539): the cap is hit, the run is blocked, an
  Ultra-Advisor escalation reaches the Orchestrator, the nudge budget runs
  out, a red build, degraded push mode, a secret finding, or an anchor halt.
- **State:** "No new state file". The rounds, the anchor and the issue-run
  records are message files (:1067-1070). Nothing records decisions. ah
  ships no statusline.
- **CLI:** msg.mjs verbs are new, list, downstream, index, sweep, roster,
  route (msg.mjs:188-325). lib-hier resolves the hierarchy dir in this
  order: `AGENT_HIERARCHY_DIR`, else `<git root>/.claude/hierarchy/`, else
  `~/.claude/hierarchy/<basename>` (lib-hier.mjs:6-8). The dir gitignores
  itself (:48-54).

## 2. When this applies

Only while a `/pipeline` run is active, and only **after** the run-start
notification (bootstrap step 7). Everything before that stays interactive,
as today: the team-create confirm, the Ultra-Advisor question (§5.1), and
the pack-override halt. Outside a run nothing changes.

A **decision point** is any question during a run that the plan or spec
does not already answer and that today would go to the user. That covers:
- a call a role marks as the user's: an `open_questions` entry, a
  `want_back`, or the Architect's "flagged for the user" with a default;
- an Ultra-Advisor's question for the user;
- a "genuinely blocked" state that is really a choice, not a missing tool,
  permission or credential.

Design questions that go to the designer today still go there (§ Routing,
spec-defect); they are not decision points. First check the plan: a
question the plan answers is no decision at all.

## 3. Safe or dangerous — the classification rule

A question is **safe** only when every one of its options meets all four
tests:
- **S1 Contained.** Its effects stay inside the run's branch (working-tree
  files and commits on that branch) and the run's own
  `.claude/hierarchy/` records.
  - **Nothing the run itself will execute changes.** No option may add,
    remove or edit any of these: dependency manifests or lockfiles;
    package, build or test scripts or their config; container or
    tool-version files; env files; git attributes; git config; or any file
    a hook, CI or the test runner loads.
  - **No other ref:** no new branch, tag, worktree or stash.
  - The branch's commits are pushed to origin and appear in the run's
    draft PR under § Push regime. That push is inside "the branch", not an
    escape.
- **S2 Reversible on the branch.** Editing or reverting commits on the
  branch undoes it, and nothing has been merged.
- **S3 In scope.** It implements, tests or documents an item already in the
  plan. It adds no item, AC, feature or third-party dependency, drops no AC
  and changes no AC's meaning.
- **S4 Not reserved.** It touches none of the classes D1–D6.

**Anything else is dangerous, including any case where a test can't be
settled.** Default-deny. The reserved classes, every one dangerous (the
lists are examples, not limits):
- **D1 Destructive or irreversible:**
  - deleting or overwriting data or files beyond what the item's spec
    changes;
  - history rewrites, force-push, deleting branches or tags;
  - real data stores or migrations;
  - killing, dismissing or abandoning in-flight work (the standing rule).
- **D2 Remote and merge:**
  - any push outside § Push regime, including the degraded-mode approval;
  - merging, approving, readying or retargeting a PR;
  - tracker writes, and posting anywhere outside the repo.

  A merge done under the user's own per-run merge authorisation (spec 0070)
  is not a decision. It is the plan answering the question (§2), so it is
  never classified, never decided and never logged as a `decided` line.
- **D3 Security and trust:**
  - permissions and settings, CLAUDE.md, hooks, agent definitions;
  - role-pack adoption, trust and pins;
  - credentials and secrets, auth logic, network egress;
  - CI config, protected paths (`settings.protected_paths` and the
    pipeline-conventions baseline);
  - the repo's build, test, dependency and tool configuration;
  - git config and the hooks path;
  - any permission prompt.
- **D4 Cost:**
  - spending beyond what bootstrap set up: spawning top-tier members the
    roster doesn't have;
  - answering the Ultra-Advisor gate (that is the user's choice);
  - raising a cap;
  - re-running a scan.
- **D5 Scope:** anything S3 excludes.
- **D6 The run's own rules:**
  - a cap, a guard, the push regime, the completion gate or a round count;
  - a 4th round;
  - anything the skill or a gate keeps for the user.

**Two keys.** The Orchestrator classifies before dispatching. A dangerous
question is never sent to a decider. The decider classifies again (§4.3),
and if either key says dangerous, the question goes to the user.

**What bounds it.** Every option must pass. A decider chooses only among
options the Orchestrator has already passed, and an `other:` answer is
re-classified (§4.3). So text injected into a question can at worst park
it, or steer the choice among options already judged safe.

**What classification is not.** It judges each option as described. The
diff that option produces still goes through the review loop, the secret
scan, the push guard and the protected-path check. Classification replaces
none of them.

**Where D3 is enforced in code.** The push guard enforces protected paths
only in repos that commit `.claude/ah-conventions.json`
(pretooluse-push-guard.mjs:1-13). Elsewhere D3 is prose, and the run-start
notification says so (§5.3, Q10).

**After a merge.** Once an item's PR has merged, S2 can't hold for that
item. Any further question on it is parked as `dangerous`.

**Review flag.** A safe question that a role marked as "the user's call"
(product behaviour, UX, a public interface or format) is still
auto-decided, and is always flagged for the user's review in the report.

## 4. Who decides, and how

### 4.1 The decider

Each time, the Orchestrator runs the agent-team ladder (§1) as follows:
- Step 2 was settled at bootstrap (§5.1), so it is never asked mid-run.
- Step 1, the Ultra-Advisor, is used only when the gate is `session`.
- Before any dispatch, apply the tier rule:
  - skip a candidate whose tier is below the Orchestrator's own, or whose
    tier is unknown;
  - a candidate at the same tier is dispatched with `reason: context`. It
    decides from a clean context, apart from the session driving the run.
- No candidate left → step 4, but **the Orchestrator never decides in its
  own context.** In an issue run that context has read the snapshot, so
  the two keys would be one.
  - Dispatch a fresh Agent-tool subagent on the Orchestrator's own model,
    `general-purpose` or `ah:orchestrator`, with the same brief (§4.2).
  - Log it as `decider: { role: "orchestrator", name: <the subagent's
    id>, model }`.
  - The brief is the Agent prompt itself, with no msg.mjs exchange. The
    `## decisions` block is parsed from the subagent's final report under
    §4.3's rules, so `exchange` is null.
  - If no fresh subagent can be dispatched: an issue run parks the
    question as `unsure`; a plan run parks it too. Nobody self-decides.

### 4.2 The brief

A request through `msg.mjs new` to the decider:
- slug `dec-<anchor suffix>-<k>`, where `<anchor suffix>` is the last
  hyphen segment of the anchor id and `<k>` is the first log id the batch
  will take;
- `--eta` set honestly, like any dispatch.

The **`dec-` prefix is reserved.** No work-item slug may start with it, so a
decision exchange never adds to an item's round count. Issue-run item slugs
start with `<tag>-`, so they can't collide.

Body:
- `## constraints`:
  - the run anchor id;
  - the item slug, or `run`;
  - the statement "The user has delegated this decision to you for this
    run; answer it on their behalf within your own contract";
  - this section's reply format;
  - §3's rule, by path and section.
- 1–4 questions, numbered `q1`–`q4`, each with:
  - the question in plain words;
  - 2–4 options, lettered `a)` to `d)`, each with its consequence;
  - the default, if the raising role gave one;
  - who raised it;
  - the Orchestrator's classification, and why it is safe.
- context as paths: the plan, the item's spec, the item's commit range.
  **In issue runs: no snapshot or trace path and no issue text,** the same
  rule as for Implementors (SKILL.md:728). A decider must not be argued
  into an option by third-party text.

### 4.3 The reply, parsed fail-closed

The decider's response file has a `## decisions` section. For each question
it holds exactly these four lines:
```
q<n> decision: a | b | c | d | other: <one line> | unsure | dangerous
q<n> rationale: <one line>
q<n> revert: <one line: how to undo it>
q<n> review: yes | no
```
- An option's letter is a decision. The log stores that option's text,
  resolved from the letter, so near-miss wording can't slip through.
- `other:` in a **plan run**: re-classify it against §3. If it fails, park
  the question as dangerous. `other:` always means `review: yes`.
- `other:` in an **issue run**: always parked as `unsure`. The
  Orchestrator that would re-classify it has seen the issue text.
- `unsure` or `dangerous` → parked (§4.4), with that as the reason.
- A missing, malformed or extra line for a question, or no reply at all →
  that question is parked with reason `unsure`.
- **Never re-ask.** A parked question is never sent to another decider, or
  to the same one again, after compaction included. Asking until you get
  an answer is not deciding.

### 4.4 Parked questions

A parked question **stops only its own item**:
- **Plan runs:** the item stops, as at a round-cap stop, and the run carries
  on with the remaining items. Items that need the stopped item's work wait
  for it.
- **Issue runs:** the item ends with a new exception, `needs-user`
  (terminal, recorded as a `<tag>-i<N>-x` record), and its dependents become
  `blocked-by`.

Parking is a notification event (§5.3). The questions are asked at the end
(§6), never mid-run with `AskUserQuestion`, because that would stall a
hands-off run.

Run-level questions (item `run`) that block every item halt the run and
notify, as "genuinely blocked" does today.

### 4.5 Caps

- At most **4** decided per item and **20** per run (Q1).
- Before dispatching, check the counts with `decision list --summary`.
- Over a cap → the question is parked with reason `cap`.
- The writer enforces both caps too (§5.2).
- Parked lines don't count toward a cap.

### 4.6 Applying a decision

**Log first, then apply.**
1. Run `decision add` first.
2. Only on exit 0 route the answer to the role that raised the question,
   quoting the printed id: "decided on the user's behalf by `<decider>`
   (d<k>)".
3. Exit 2 → nothing is routed; a refused line must never have acted. What
   happens next depends on the refusal:
   - **`cap`:** add a `parked` line with `why_user: "cap"`.
   - **`parked-before`:** add nothing. The question is already parked, and
     its earlier `parked` line stands.
   - **Any field refusal** (a missing or mistyped field, an unknown key, a
     writer-owned field): add a `parked` line with `why_user: "unsure"`,
     with the refusal text as its `rationale`. Build it from the fields
     that were valid.
   - **If that `parked` add is refused as well:** stop the item exactly as
     for a parked question (§4.4), put both refusal texts in the stop
     notice (issue runs: the `needs-user` exception record), and don't try
     again.

The raising role then carries on: it amends the spec, or builds.
Implementor commits for the decision name `d<k>` in the body, so the report
can point at the change.

## 5. Changes

### 5.1 Bootstrap — one new step, before team creation

**Step 3a, decision authority.** Read
`gate.mjs status --session <id>`:
- `session` → the Ultra-Advisor may decide. Don't ask.
- `off` → it may not. Don't ask.
- `none` or `each` → one `AskUserQuestion` (header "Decisions"):
  - "Ultra-Advisor decides (rest of session)" →
    `gate.mjs set --choice session`;
  - "No Ultra-Advisor — top team member, else me" →
    `gate.mjs set --choice off`.

  `each` isn't offered: re-asking at each escalation would stall a hands-off
  run. The question says that dangerous calls always come to the user.
- Allowed, but no Ultra-Advisor member is live or in the roster → in the
  same `AskUserQuestion` call, ask the ladder's step-2 question (spawn one,
  on fable or opus, or don't).

### 5.2 The log, through `msg.mjs decision`

**Location:** `<hier>/pipeline/<anchor id>/decisions.jsonl`. `<hier>` is
lib-hier's resolved hierarchy dir, so `AGENT_HIERARCHY_DIR` is honoured and
the dir stays gitignored. `sweep` never touches it, and nothing deletes it.

**`msg.mjs decision add --team <T> --cwd <abs>`:**
- reads one JSON object on stdin;
- finds the run by the skill's exactly-one rule: open exchanges of team T
  with slug `pipeline-run-anchor`. Zero or several → exit 2, write nothing;
- validates, then appends one line with a single append call;
- prints `{ id, path, counts }`.

Input fields:
- `kind`: `decided` | `parked`
- `item`: an item slug, or `run`
- `source`: the role or member that raised it
- `question`
- `options`: an array, 2–4 strings, lettered a–d in order
- `default`: a letter, or null
- `choice`: a letter within `options`, or `other: …`; null when parked.
  The writer stores the chosen text as `decision`.
- `decider`: `{ role, name, model }`; `role` is
  ultra-advisor|architect|reviewer|implementor|<custom>|orchestrator.
  `orchestrator` always means a fresh subagent (§4.1), with its id as
  `name`.
  - Required on `decided` lines.
  - On `parked` lines it is the decider that answered `unsure` or
    `dangerous`, or `null` when the question was parked before any
    dispatch: classified dangerous by the Orchestrator, or over a cap.
  - `null` is refused on `decided` lines.
- `rationale`, `revert`
- `review`: boolean
- `why_user`: `dangerous` | `unsure` | `cap`; null when decided
- `dangerous`: boolean
- `exchange`: the decision request's id, or null when parked before
  dispatch or decided by a step-4 subagent

The writer adds the **writer-owned** fields:
- `id`: `d<k>`, where k = the number of valid `decided` and `parked` lines
  so far, plus 1. Lines of other kinds, such as auto-merge's `merge` lines,
  carry no id and don't count toward k;
- `time` (ISO), and `run` (the anchor id);
- `decision`: the option text resolved from `choice`;
- `qkey`, computed by the writer: the first 12 hex characters of
  sha256(`<item>\n<normalized question>`). Normalized means trimmed,
  lowercased, and with every run of whitespace collapsed to one space. The
  model never computes it. Exact or near-exact repeats are caught here;
  paraphrases are caught by the Orchestrator's `list --item` check before
  dispatch.

**The caps** (4 decided per item, 20 per run) are exported constants in the
writer lib, `agent-hierarchy/hooks/lib-decisions.mjs`. msg.mjs, and later
auto-merge's hook, import them from there.

**Refusals** (exit 2, nothing written), each with a reason:
- a missing or mistyped field;
- an unknown input key, or any writer-owned field supplied by the caller
  (`id`, `time`, `run`, `decision`, `qkey`). Fail-closed;
- `decided` with `dangerous: true`, `decider.role` "user", or a `why_user`;
- `decided` whose `choice` is neither a letter within `options` nor
  `other: …`;
- `decided` when a `parked` line with the same `qkey` already exists in the
  run (reason `parked-before`). The writer is the code backstop for "never
  re-ask" after compaction; before dispatching, the Orchestrator checks
  `list --item <slug>`;
- `parked` with a `choice`, or with no `why_user`;
- `dangerous: true` with a `why_user` other than `dangerous`;
- `decided` over either cap: 4 for its item, 20 for the run.

**`msg.mjs decision list --team <T> [--run <anchor id>] [--item <slug>] [--summary] --cwd <abs>`:**
- with no `--run`, the open anchor by the exactly-one rule; with `--run`,
  that run, open or closed;
- prints `{ run, path, decisions: [...], skipped }`, in id order;
- a line that won't parse, such as a torn last line after a crash, is
  skipped and counted in `skipped`, never fatal;
- `decisions` holds every valid line, each with its `kind`. Lines of other
  kinds (auto-merge's `merge` lines) are listed because the report needs
  them, but no count includes them;
- `--summary` prints instead
  `{ decided, flagged, parked, by_item: { <slug>: { decided, parked } }, skipped }`,
  plus `line`, a one-line text, e.g. `decisions: 7 decided (2 flagged), 1 waiting for you`.

No run anchor and no `--run` → exit 2.

### 5.3 Notifications and visibility

- The run-start notification gets a **fifth** fact:
  - who decides: Ultra-Advisor | `<role>` | a fresh subagent on the
    Orchestrator's model;
  - the log path;
  - with no committed `.claude/ah-conventions.json`, also "guards: prose
    only (no conventions baseline)" (Q10).
- New notification event: **a decision parked for the user.** It carries the
  item, the reason and the question.
- Every notification after run start, and every status answer the
  Orchestrator gives the user mid-run, ends with `decision list --summary`'s
  `line`. That line is the run's status line; no statusline integration
  (Q7).
- Decided questions are not notified one by one: no running commentary.

### 5.4 Final report — both run types

The run's final message gets a section **"Decisions made on your behalf"**,
built from `decision list`, never from memory:
- grouped by item, in id order within each item; flagged lines first,
  marked "review";
- each line: id; the question in one line; the decision; the decider (role,
  name, model); the rationale; the revert hint; the item's branch, and the
  commits naming `d<k>`, if any;
- then **"Waiting for you":** every parked line, with its item, reason,
  question and options, so the user can answer and re-run;
- the totals line and the log path.

Where it goes:
- **The item's PR body, issue runs.** § PR creation's body gets a
  "Decisions made on your behalf" section for that item, flagged lines
  first, written into the body file before the PR is created. It sits
  after the Reviewer's guide and before the footer. This is how someone
  merging from GitHub sees the flagged decisions at the merge point.
  Writing the run's own PR body is inside the push regime, not D2's
  "posting outside the repo". A decision on the item after the PR exists
  is impossible (§3, after a merge) or rare; if one happens, the PR body is
  updated through the same worker order § PR creation uses.
- **Plan runs:** they open no PR, so the report lives only in the final
  message. That message is new: send it after § Completion gate and the
  last push, before the anchor closes.
- **Issue runs:** § End of run's message gets the section.
- **A halt, in either run type:** the halt notification's session message
  carries the section as well.

### 5.5 SKILL.md edits (skills/autonomous-pipeline/SKILL.md)

- The "Full spec" line (:17-20) also names this spec.
- Routing table row (:129): "a call that is properly the user's" → § Decisions
  on the user's behalf.
- § Ultra-Advisor escalation (:191-202): unchanged for parked questions.
  Add one line: as a decider, it answers in `## decisions` (§4.3), not
  `open_questions`.
- § Bootstrap: step 3a (§5.1).
- New section **§ Decisions on the user's behalf**, after § Routing, holding
  §2–§4:
  - the S1–S4 / D1–D6 rule verbatim in substance, with the anchor sentence
    "Anything else is dangerous";
  - the ladder with the tier rule;
  - the brief and the reply format, with the line
    `q<n> decision: a | b | c | d | other: <one line> | unsure | dangerous`;
  - "Log first, then apply" (§4.6);
  - step 4's fresh subagent and "never decides in its own context";
  - "Never re-ask";
  - parking, the caps, and the `dec-` reservation.
- § The 3-round cap: one line saying decisions never add, reset or extend
  rounds, and that `dec-` exchanges don't count.
- § Notification: the fifth fact and the new event (§5.3).
- § Exceptions and status derivation: `needs-user` (Execution list) is
  notified.
- § End of run and § Completion gate: the report (§5.4).
- § What this skill does not do: "No new state file" gains its one
  exception, the decision log. A log of what was decided can't be derived
  from slug counts. Everything else in that list stays.
- § Bootstrap step 6 and § Invocation: §5.6's branch rule and typed-ACs
  line.

### 5.6 Plan-run branch, and typed ACs

These two come from the user's rulings, added to this spec because they edit
the same SKILL.md. They are independent of auto-decide.

**Default branch for a plan run.** Today a plan run with no `--branch` has
no rule: step 6 records only "the resolved branch". New rule:
- `/pipeline <path>` with no `--branch` → the branch is
  `ah/pipeline-<stem>`. `<stem>` is the plan file's basename without its
  extension, slugged:
  - lowercase;
  - every run of characters outside `[a-z0-9]` becomes one `-`;
  - no `-` at either end;
  - at most 40 characters, with no trailing `-` after the cut.

  For example, `0068-pipeline-auto-decide.md` →
  `ah/pipeline-0068-pipeline-auto-decide`. An empty stem → refuse before
  any work, and say to pass `--branch`.
- It is created off HEAD at bootstrap step 6, right before the anchor is
  written. The anchor records it, as today.
- **Halt if it exists:** `refs/heads/ah/pipeline-<stem>` or
  `refs/remotes/origin/ah/pipeline-<stem>` already existing → halt and
  notify before any work. Name the branch, and say to pass `--branch` or
  delete the old one. This is the plan-run counterpart of issue runs'
  `branch-exists`. Never reuse or reset an existing branch.
- With `--branch <name>`, nothing changes.

**Typed ACs.** ACs typed into the request with no file are written by the
Orchestrator, verbatim, one per line, to
`<root>/.claude/hierarchy/specs/acs-<YYYYMMDD-HHMM>.md`. The run is then a
plan run on that path, and the default branch comes from it, e.g.
`ah/pipeline-acs-20260930-2045`. The file is gitignored scratch. The
run-start notification names it. § Invocation gets this as one line. The
README's "put it in a file and pass the path" stays true.

### 5.7 What stays the same

- Every stop that isn't a question:
  - the 3-round cap, red build, nudge exhaustion, the secret scan and its
    no-re-roll rule, degraded mode and its approval, anchor halts;
  - the pack-override halt and the gate slots;
  - the push regime and the guards.
- agents/*.md is not edited: the delegation statement travels in the
  brief.
- gate.mjs and the Ultra-Advisor gate hook, the SessionStart injection, the
  row shape of `msg.mjs list`, and the frontmatter keys.

## 6. Interaction with today's check-ins

| Today | With this spec |
|---|---|
| a user's call → the Ultra-Advisor → the user | safe: decided (§4); dangerous, unsure or over a cap: parked |
| Architect's open questions, with defaults | decision points; the default is one option |
| "genuinely blocked" | a choice → classify it; a missing tool, permission or credential → notify, as today |
| 3-round cap hit | unchanged; never decided |
| red build, nudge exhaustion, scan finding, degraded mode, anchor halt | unchanged |
| degraded approval | unchanged; still the user's (D2) |
| bootstrap questions | unchanged, plus step 3a |
| parked questions | asked after the run, from the "Waiting for you" list |

## 7. Files

- `agent-hierarchy/hooks/msg.mjs`: the `decision add|list` verbs. Reuse
  lib-hier's dir resolution and msg.mjs's own team and anchor lookup; don't
  write a second one.
- `agent-hierarchy/skills/autonomous-pipeline/SKILL.md`: §5.5.
- `agent-hierarchy/docs/cli-tools.md`: the two verbs, their fields and
  their refusals.
- `agent-hierarchy/tests/test-pipeline-decisions.sh`: new (§8).
- Version 0.109.0 in plugin.json and the root marketplace.json.
- README `/pipeline` section: docs-writer, routed separately by the
  Orchestrator. Not part of this build.

## 8. Tests

Mutation standard: each [bracketed mutation] must make at least one row
fail. Use the sandbox and `AGENT_HIERARCHY_DIR` pattern of
tests/test-msg-cli.sh.

- **W1 Append.** With one open anchor:
  - two `decided` adds give `d1` and `d2`, each line holding every field
    plus `id`, `time` and `run`;
  - the file is `<hier>/pipeline/<anchor id>/decisions.jsonl`.

  [number from 0] [write outside the run dir]
- **W2 Invariants.** Each §5.2 refusal exits 2 and leaves the file
  byte-identical. One row per refusal.

  [allow decided+dangerous] [allow decider role user] [accept an off-list
  letter] [allow parked without why_user]
- **W2b Refusal reason for parking.** A refused `add` prints a reason the
  Orchestrator can park with: the `cap`, `parked-before` or field reason,
  on stdout as JSON with exit 2. [exit 0 on refusal]
- **W2c Never re-ask.**
  - A `parked` line, then a `decided` line with the same item and
    question, in the same run → refused with `parked-before`. The same
    holds when the question differs only in case and whitespace.
  - A different question is accepted.

  [skip the qkey check] [hash without normalizing]
- **W2e Fields.**
  - An unknown key → refused.
  - Each writer-owned field supplied by the caller (`id`, `time`, `run`,
    `decision`, `qkey`) → refused.
  - `decider: null` on a `decided` line → refused; on a `parked` line →
    accepted.

  [accept unknown keys] [accept a caller qkey] [allow a null decider when
  decided]
- **W1b Ids skip other kinds.** A raw `{"kind":"merge",…}` line injected
  into the file:
  - the next `add` still gets the next `d<k>`, counting only decided and
    parked lines;
  - `list` shows the merge line;
  - `--summary` counts it nowhere.

  [count every line toward k]
- **W2d Letters.**
  - `choice: "b"` stores `options[1]` as `decision`.
  - `choice: "e"` with 4 options is refused.

  [store the letter instead of the text]
- **W3 Caps.**
  - The 5th `decided` for an item is refused; a `parked` for that item is
    still accepted.
  - The 21st `decided` in the run is refused.

  [skip the item cap] [count parked toward the cap]
- **W4 Run lookup.**
  - No open anchor → refused.
  - Two open anchors → refused.
  - A closed anchor is ignored by `add` and readable by `list --run`.

  [take the newest anchor]
- **W5 Reader.**
  - A torn last line is skipped and counted in `skipped`.
  - `--item` filters.
  - `--summary` counts, and its `line` text is right.

  [fail on a bad line] [count parked as decided]
- **K Skill anchors** (grep SKILL.md):
  - the § Decisions heading;
  - "Anything else is dangerous";
  - the S1–S4 and D1–D6 labels;
  - the reply-format line with letters;
  - "Never re-ask";
  - "Log first, then apply", "only on exit 0", and the per-refusal park
    rules;
  - "never decides in its own context";
  - the issue-run `other:` → `unsure` line;
  - S1's execution clause and "No other ref";
  - the bounding sentence "Classification replaces none of them";
  - the PR-body decisions section;
  - "guards: prose only (no conventions baseline)";
  - step 3a, with both options' texts;
  - the fifth notification fact;
  - "Decisions made on your behalf" and "Waiting for you";
  - `needs-user`;
  - the `dec-` reservation;
  - the routing-table row;
  - the "No new state file" exception sentence;
  - `ah/pipeline-<stem>`, its slug rules, and the halt-if-exists sentence;
  - the typed-ACs line with `acs-<YYYYMMDD-HHMM>.md`.

  [delete each anchor in turn]

Then run the full suite. Every existing row stays green; if one fails, stop
and report.

## 9. Assumptions not verified

- Anchor ids end in a hyphen segment that is unique enough for the
  `dec-<suffix>-<k>` slug (e.g. `…-1vr2`). If not, use any deterministic
  suffix of 1–8 [a-z0-9] characters from the id, so the slug fits
  `^[a-z0-9-]{1,32}$`. That is the Implementor's call; say which in the PR.
- msg.mjs's team resolution and its open-exchange listing can be reused by
  `decision add` for the exactly-one lookup without a new import cycle. If
  not, stop and report.
- A single `appendFileSync` of one line under ~16 KB is not interleaved on
  a local filesystem. There is one writer (the Orchestrator), so that is
  enough. W5 covers a torn line after a crash.

## 10. Open questions for the user (defaults taken)

- **Q1 Caps:** 4 decided per item and 20 per run (default); or other values.
- **Q2 A parked question:** stops only its item, and the run goes on
  (default); or halts the run.
- **Q3 Issue runs:** parked → `needs-user`, terminal (default); or hold the
  item and ask at the end, then resume it.
- **Q4 When to ask parked questions:** after the run, from the report
  (default); or at once with `AskUserQuestion`, which stalls hands-off runs.
- **Q5 A candidate at the same tier:** dispatched with `reason: context`
  (default, for a decider apart from the session driving the run); or the
  Orchestrator decides itself.
- **Q6** A safe question a role marked "the user's call" is always flagged
  for review (default yes).
- **Q7 Status line:** the summary line in notifications and status answers
  only (default); or also a statusline segment. ah ships none, so that would
  be a separate tool reading the log.
- **Q8 Opt-out:** none (default); or a `--ask-me` flag that turns
  auto-decide off for a run.
- **Q9 Branch:** see §11.
- **Q10, ruled by the user:** with no committed conventions baseline,
  auto-decide still runs, and the run-start notification's fifth fact says
  "guards: prose only (no conventions baseline)".
- **Merge opt-in, ruled by the user:** asked once per run at bootstrap,
  default no, never remembered; `--auto-merge` skips the question. See spec
  0070.

## 11. Branch

Recommended: build it on a new branch off `main` after PR #1
(feat/0064-named-rosters) merges. This spec edits the same SKILL.md that PR
#1 changed (gate slots, packs), and msg.mjs, which 0066 touched. Building
on top of an open PR means rebasing or retargeting later. If PR #1 is
expected to wait, branch off `feat/0064-named-rosters` instead, and merge
it after PR #1.

## 12. Decisions, confidence, follow-ups

- **A JSONL log and a CLI verb, not message files.**
  - The report and the status line need every decision's text, cheaply,
    after compaction; reading two message files per decision costs far
    more.
  - A step-4 subagent's answer comes back in its Agent result, with no
    exchange to hold it.
  - The verb puts the bookkeeping invariants in code rather than prose:
    no line both decided and dangerous, the caps, a single run, and no
    deciding a question already parked.
  - The order "log first, then apply" (§4.6) is what gives them force: a
    refused line never acts.
- **Keyed by the anchor id:** both run types have one, so the plan-run
  anchor needs no new `run-tag:`.
- **Default-deny, with two keys:** the cost of a wrong "safe" is a
  dangerous act with no user involved. The cost of a wrong "dangerous" is
  one item waiting.
- **Park and go on, not ask mid-run:** this keeps the work moving, which is
  the user's stated goal. `AskUserQuestion` would stall the session.
- **No `each` at step 3a:** a hands-off run can't re-ask at every
  escalation.
- **Confidence:** high after review. The Ultra-Advisor reviewed §3
  (exchange 20260930-204437-dnwb): sound in shape, with leaks on three
  edges. Its fixes are in:
  - B1: S1's execution and ref clauses, D3's additions, and the bounding
    sentence;
  - B2: step 4 is a fresh subagent;
  - B3: log first, then apply;
  - S1: the PR-body section;
  - S2: issue-run `other:` → `unsure`;
  - S3: `qkey`, `parked-before`;
  - S4: letters;
  - S5: the honesty wording, and where D3 is enforced in code.

  Its B4, the merge path, is spec 0070. The user chose B4 as written: a
  native permission prompt for each merge.
- **Rejected, per the Ultra-Advisor:**
  - "auto-decide only in plan runs": the user wants unattended issue runs,
    and B2 and S2 close the steering channel;
  - an allowlist of safe files instead of B1's execution clause: it would
    park every legitimate test-config change.
- **The plan-run branch rule and the typed-ACs line (§5.6)** are the user's
  rulings, not this spec's design.
- **The merge guard and auto-merge are spec 0070.** Merging stays D2,
  dangerous, here: it is never auto-decided. 0070's only merge path is the
  user's own per-run authorisation. 0070 extends §5.2's writer with two
  kinds that `decision add` refuses, so build the writer's core as a lib
  that both msg.mjs and the push guard can import.
