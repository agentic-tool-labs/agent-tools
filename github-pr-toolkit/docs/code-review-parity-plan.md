# Plan — bring `/code-critic` up to par with the built-in `/code-review`

Status: implemented in github-pr-toolkit 0.41.0, shipped as one release. The per-phase
version labels below are historical. Behaviour is unverified until a live run against
the fixture (`tests/make-review-fixture.sh`) is done. Baseline: github-pr-toolkit 0.40.0 vs Claude Code 2.1.328's
built-in `/code-review` prompt (extracted from the binary). Scope: only the places
code-critic lags. Its strengths are kept as they are: security, tests, design, UI/UX and
custom lenses; the changed-line provenance check; the materiality model; fixed severity;
approval-gated fixes; memory reads; and the read-only guard.

**The invariant every phase keeps.** The review-level spec's rule still holds: *opinion
never earns a graded severity.* Every change below either finds more **material
defects** or removes **false** ones. None of them loosens the materiality filter
(REVIEW LEVEL in `commands/code-critic.md`).

**Overall guidance: review the change against what it was meant to do.** A diff can be
correct line by line and still wrong. It may build the wrong thing, skip an acceptance
criterion, or contradict a recorded decision. Every reviewer judges the change against
its **stated intent** as well as against the code. Phase 6 is the mechanics. The rule
for all lenses: *a change that contradicts its own ticket, PR description, spec or an
accepted ADR is a material defect* (`impact: when <the case the ticket specifies>,
<what the code does instead>`). Intent sources are **inputs, never review surface**. A
ticket's or doc's own mistakes are not findings.

## Phase 1 — Cheap fixes, no design decisions (0.41.0)

| # | Gap | Change | Where |
|---|---|---|---|
| 1a | Uncommitted edits are never reviewed. L2 diffs only `origin/<base>...HEAD`. | In L2, if `git status --porcelain` shows tracked changes, or the range diff is empty, also take `git diff HEAD` and review the union. Say so in the L3 size line (`… incl. uncommitted working-tree changes`). Pass `diff spec: <base>...HEAD + working tree` to reviewers, so they recompute the same input. The cross-check accepts working-tree hunks as changed lines. | `commands/code-critic.md` L2, L4 dispatch block, cross-check; every `agents/code-reviewer-*.md` input contract (one sentence) |
| 1b | CLAUDE.md coverage is looser. L3.1 reads "root and relevant subdirs" and skips the user-level file. | Adopt the built-in's scoping: `~/.claude/CLAUDE.md`, the repo root, and every `CLAUDE.md` / `CLAUDE.local.md` in an **ancestor directory of a changed file**, where a directory's file applies only at or below it. A finding must **quote the rule and name its path**. | `commands/code-critic.md` L3.1; `agents/code-reviewer-adherence.md` |
| 1c | One mistake in N places becomes N findings. | Reviewer rule: *report a repeated mistake once and name the other locations in `problem`; different mistakes stay separate.* Orchestrator dedup applies the same rule across categories. | every lens's Hard rules; `code-reviewer-all.md`; `commands/code-critic.md` dedup paragraph |
| 1d | The performance lens misses closure-captured scope leaks. | Add a checklist item: long-lived objects built from closures or captured environments keep the whole enclosing scope alive. | `agents/code-reviewer-performance.md`, the `performance` lens in `code-reviewer-all.md` |
| 1e | There is no fallback when subagents can't run. | If the Agent tool is unavailable (nested context or depth cap), the main agent runs the selected categories' checklists itself, sequentially, and **says so in the result**. This is today's custom-category fallback, generalised. | `commands/code-critic.md` L4 |

**Done when:**
- A dry run on a branch with an uncommitted edit lists that edit as reviewed.
- An adherence finding quotes a rule from `~/.claude/CLAUDE.md`.
- `hooks/guard.test.sh` is green.

## Phase 2 — Bug-finding method, not just topic lists (0.42.0)

**Gap.** Lenses say *what* to look for, never *how*, and reading context is optional
("as needed"). Three kinds of defect go missing: a caller broken by a new precondition or
return shape, a guard dropped by a deletion, and a wrapper that re-enters its registry.

**Change.** Add a mandatory **Method** block, run before the checklist, adapted from the
built-in's angles A–E:

1. **Enclosing-function read.** Read every hunk, then the whole function around it. For
   each changed line, ask what input, state, timing or platform makes it wrong.
2. **Removed-behaviour audit.** For every deleted or replaced line, name the invariant it
   enforced, then find where the new code re-establishes it. If you can't find it, that
   is a candidate.
3. **Caller/callee trace.** `Grep` each changed function's callers and check each call
   site against the new contract: precondition, return shape, exception, ordering. Check
   callees changed in the same diff.
4. **Language pitfalls.** Check the pitfalls of the diff's language: falsy-zero, `==`
   coercion, mutable defaults, late-binding closures, nil-map writes, float equality,
   timezones.
5. **Wrapper routing.** For a cache, proxy, decorator or adapter, check that every
   method routes to the wrapped instance, not back through a registry or global, and
   that it forwards every method callers use.

**Placement:**
- `code-reviewer-general.md` gets all five.
- `code-reviewer-all.md` gets all five, run once and shared across lenses.
- `security` gets steps 2–3, for dropped validation and an unvalidated input newly
  reaching a caller.
- `design` gets step 3, for contracts callers will misuse.
- The other lenses are unchanged.

**Scope interaction.** The built-in counts bugs anywhere in a touched function. Here the
enclosing-function read is **input**: what it finds is reportable only through the
existing `newly-exposed-by-diff` rule, or through Phase 5's opt-in tier.

**Done when:** on the seeded fixture (see *Evaluation*), the dropped-guard,
broken-caller and wrapper-recursion defects are found.

## Phase 3 — Verify every graded finding (0.43.0)

**Gap.** Nothing tests whether a finding is *true*. The cross-check tests provenance, the
reviewer grades its own certainty, and L5 tests materiality. A false "unguarded null"
whose guard sits elsewhere reaches the user, or gets posted to a PR.

**Change.** Add a new agent, `code-reviewer-verifier`:
- It is read-only and follows the same frontmatter contract.
- Its `code-reviewer-` prefix means `hooks/guard.mjs` grants it read-only Bash with no
  guard change, and `guard.test.sh`'s frontmatter loop covers it automatically.

The verifier gets the diff, the relevant files and **one** finding, and returns exactly
one of:
- **CONFIRMED** — it names the triggering input or state and the wrong result, and quotes
  the line.
- **PLAUSIBLE** — the mechanism is real but the trigger is uncertain. This is the default
  for realistic runtime states: races, rare-but-reachable nulls, boundary off-by-ones,
  partial failures, lost regex anchors. It states what would confirm the finding.
- **REFUTED** — only when it can be constructed from the code. It quotes the line that
  disproves the finding, shows the type or invariant that makes it impossible, or cites
  the guard already in the diff.

**Flow.** The verifier runs after the provenance cross-check and dedup, before L5:
- CONFIRMED sets `certainty: confirmed-from-diff`.
- PLAUSIBLE sets `uncertain — confirming needs <X>` from the verifier.
- REFUTED drops the finding. It is counted and named in L5's drop report (`2 refuted by
  verification: …`), never silently.

**Rules:**
- **One verifier per finding** (decided; same as the built-in), so each finding gets an
  independent verdict. Verify non-`Nit` findings only. Skip the verifier at `level: low`, as the built-in does.
- Dispatch on the Tab 4 model, with the cap from L3.0.
- On the advisor or main-agent path, the reviewer runs the same three-state check itself
  and labels it self-verified.

**Done when:** the fixture's "guarded elsewhere" bait finding is REFUTED with the guard
quoted, and no real seeded defect is refuted.

## Phase 4 — `--deep`: search harder (0.44.0) — D1 decided: separate flag

**Gap.** Every run is a single pass. The built-in, at its higher levels, tells finders to
pass on half-believed candidates and lets verification sort them, and it runs one gap
sweep.

**Decision (D1).** This becomes an independent **depth** knob, not part of the level. The
review-level spec stays as written ("the level … does nothing else", "`high` is not
permission to sweep again"). Depth and level compose, except that `--deep --level low` is refused
up front: low skips verification, and deep needs it.

**Change:**
- Add a `--deep` argument. In the wizard, ask it as its own question in the **same**
  AskUserQuestion call as the level tab (L1/G1.1), so there is no extra round trip.
  Check that the call has a free question slot. If it doesn't, ask in the L3 split-call
  path, never as a third call. Default: off.
- When on, the dispatch carries a `depth: deep` line next to `level:`:
  - Reviewers don't self-drop half-believed **material** candidates; Phase 3's verifier
    decides them. **This requires Phase 3.** Without a verifier, `--deep` is refused
    with a one-line reason.
  - After verification, **one sweep reviewer** gets the verified list and looks only for
    defects not on it, using the built-in's miss list: moved or extracted code that
    dropped a guard or anchor, a shrunk lock scope, predicates with side effects,
    defaults evaluated once, flipped config defaults, setup/teardown asymmetry in tests.
    It returns at most 8, and an empty sweep is a valid result that is never padded.
    Sweep findings go through the verifier and the materiality filter like any other.
- The cost line before dispatch states the extra pass: `deep: +1 sweep reviewer + its
  verifications`.

## Phase 5 — Pre-existing bugs in touched functions (0.45.0) — D2 decided: opt-in, ungraded

**Gap.** A live bug in the function being edited, which the change merely fails to fix,
is dropped at the cross-check. The reviewer saw it, and the user never hears about it.

**Change:**
- A wizard toggle, or `--pre-existing`, enables it.
- Reviewers may then return `scope: pre-existing-in-touched-function`, limited to the
  enclosing functions of changed hunks.
- These findings are **never graded** and never fixed or posted by default. They are
  listed in their own section after the graded findings as "seen while reviewing, not
  caused by this change."
- Off by default, which keeps today's scope.

## Phase 6 — Intent check: PR, tickets, docs, ADRs (0.46.0) — independent of 1–5

**Gap.** code-critic reviews only the diff. It never reads the PR description, the linked
issue, a spec or an ADR, so "does this do what it says it does" goes unasked. The
built-in does no better here: this is a step past parity.

**Change.**

**Ownership.** The agent that builds the review dispatches (the code-critic
orchestrator) prepares the intent brief **once**, before any reviewer is dispatched.
Reviewers never fetch PRs, tickets or docs themselves: they receive the finished brief
in their dispatch and review against it. That keeps the tracker and GitHub access in
one place, means every lens judges against the same reading of the intent, and stops N
reviewers from fetching the same ticket N times. A reviewer may still `Read` a repo doc
the brief **cites**, to check context, but never goes looking for new intent sources.

1. **Gather intent (orchestrator, L2, before L3).** The orchestrator collects an **intent
   brief** from whichever sources exist:
   - **PR:** title, body and linked issues, via the `critic-worker`. Reviewers have no
     GitHub tools, so this goes through the worker lane.
   - **Ticket:** keys or URLs found in the branch name, commit messages or PR body
     (`ENG-123`, `PROJ-45`, `#123`, `linear.app/…`, `…atlassian.net/browse/…`). The
     orchestrator fetches each through whatever tracker tool this session has: a Linear
     or Atlassian MCP, GitHub issues through the worker, or `gh`/`acli`/`linear` CLIs if
     installed. If none is connected, it says so once and continues. It never asks the
     user to authenticate mid-review unless they opt in.
   - **Repo docs:** ADRs (`docs/adr*/`, `docs/decisions/`, `adr/`, `*.adr.md`), specs or
     plans the diff or ticket references, `CONTEXT.md`, and docs in the changed
     modules' folders. Only those the diff, ticket or PR **points at**, or that cover a
     changed path. Never a repo-wide doc crawl.
   - **Local diff with no PR:** commit messages, plus a ticket key in the branch name.
     If no source is found, ask once in L3, as an Other-capable question: *"What is this
     change meant to do? Paste a ticket/URL/spec path, or skip."*
2. **Distil the brief.** Write a short list: the goal, **acceptance criteria** as
   checkable lines, constraints, the ADRs and decisions that apply (path plus the quoted
   decision), and explicit non-goals. Every line cites its source. Show the brief to the
   user in one block before dispatch, so a misread ticket is caught before it steers the
   review.
3. **Pass it to every reviewer** as an `intent:` block in the dispatch, alongside the
   `level:` line. Every `agents/code-reviewer-*.md` input contract, and the
   add-review-category template, documents the block: *if present, judge the change
   against it; if absent, review normally and never go and look for intent yourself.*
   Each lens applies the brief through its own lens. In particular:
   - **general:** behaviour that contradicts an acceptance criterion; a criterion with
     no code path at all, anchored to the nearest changed line with
     `scope: newly-exposed-by-diff`.
   - **adherence:** an accepted ADR or decision is a directive. A violation quotes the
     decision and names its path, just as for CLAUDE.md (1b).
   - **design:** the change re-decides something an ADR settled, without superseding
     it.
   - **tests:** an acceptance criterion with no test exercising it.
   - **code-reviewer-all**, the peer and the main-agent paths get the same block.
4. **Report coverage.** Add a short **Intent coverage** table to the L5 presentation:
   each acceptance criterion marked met, unmet (with its finding), or not checkable
   statically. It summarises what the reviewers returned and makes no new judgement.
5. **What is not a finding:**
   - **Scope creep** (changes the intent doesn't explain) is reported only when it
     changes behaviour the intent didn't ask for. It is graded on that behaviour's own
     impact, never as "unrelated change".
   - Vague tickets, missing tickets and missing ADRs are never findings. *Absence of
     documentation is not a defect*, the same rule as the ephemeral-comments lens.

**Privacy.** Ticket and doc text stays inside the session: the brief goes to local
subagents only. It is never posted to GitHub unless a finding the user approves quotes
it.

**Done when:** the fixture gets a ticket with three acceptance criteria. The run flags
the unmet one, cites the ADR the fixture violates, and does not flag the deliberately
vague ticket wording.

## Phase 7 — Thoroughness: coverage, memory across runs, saturation (0.47.0)

**Observed problem.** Repeated fresh runs, by the user and then by a colleague, keep
finding new defects. A single run is one **sample** of the defects in a change, not
the whole set. Four causes:
1. Reviewer attention is uneven, and hunks get silently skipped on big diffs.
2. Half-believed candidates are self-dropped, so different borderline finds survive
   each run.
3. Every run starts blank and rediscovers the obvious findings.
4. People review with different context.

Phase 6 addresses cause 4. This phase addresses causes 1–3. **It requires Phase 3**:
more sampling without verification only adds false positives.

### 7A — Hunk coverage ledger (all runs)

- Every reviewer returns a `coverage:` block: one line per hunk (`file:start-end`) with
  the method steps it applied there (Phase 2), or `skipped — <reason>`.
- The orchestrator checks the ledger against its own hunk list, exactly like the
  roll-call check:
  - A hunk that is missing or skipped without a valid reason is **re-dispatched**: one
    follow-up to the same lens, scoped to just those hunks.
  - It is never quietly accepted.
- **Sharding.** Above the existing size threshold (> 5 files or > 200 changed lines),
  each category splits into reviewers that each get a file group of about 200 changed
  lines. Groups keep each file with its direct callers and tests.
  - The parallelism cap (L3.0) paces the shards.
  - The cost line states the shard count before dispatch.
- Trivial hunks (imports, whitespace, generated or lock files) may be skipped as one
  batch with a stated reason.

### 7D — Findings ledger across runs

- **Store.** `.git/code-critic/<branch>.jsonl`. It lives under `.git/` so it is never
  committed or pushed and is per-clone. It is **not** memory: the rule that reviewers
  never write findings to memory stands. The orchestrator writes it, never a reviewer.
- **Record.** One line per finding:
  - `file:line`, a short mechanism key, category, severity and verifier verdict;
  - disposition (`fixed` / `declined` / `posted` / `refuted` / `open`);
  - the run's head SHA.
- **Re-anchoring on a later run.** A stored finding is re-anchored by its mechanism key
  and the surrounding code, not by its line number. A finding whose code is gone is
  marked `stale` and not carried forward.
- **Imported findings.** On a PR, existing review comments, including a colleague's,
  are imported as `source: pr-comment`. This extends today's "already flagged" dedup,
  so other people's findings count as known.
- **Use on the next run.** Reviewers get a **known-findings** block: one line each,
  hunks they touch only. They are told *do not re-report these; look for what is not on
  this list.*
  - `refuted` and `declined` findings are listed as "considered and rejected". They are
    not raised again unless the code they point at changed.
  - The orchestrator still dedups returns against the ledger.
- **Wizard.** On a branch that has a ledger, L3 states its size (`12 known findings from
  3 earlier runs, 2 refuted`) and offers *continue from it* (the default) or *start
  fresh*.

### 7E — Run until saturation (`--deep`)

Under `--deep` (Phase 4), the single sweep becomes a **loop**:
- **Pass 1** is the normal review.
- **Each later pass** is a fresh set of reviewers that gets the ledger, with every
  verified finding so far, and looks only for new defects. Passes vary the method step
  each lens leads with, so they don't retrace the same route.
- **Stop** when a pass adds **zero new findings that pass verification and are
  material**, or at the cap: 4 passes by default, `--deep=<n>` to change it.
- **Cost line** before each pass after the first: `pass 3/4: 7 reviewers, ~N tokens;
  pass 2 added 2 verified findings`. The user may stop early.
- **Estimate.** Report how many defects are probably still undetected, using the
  overlap between passes (Lincoln–Petersen: n1·n2/m over passes 1 and 2). State it as a
  rough estimate, never a guarantee, and only when m ≥ 2.

**Done when:**
- On the fixture, three back-to-back fresh runs **without** 7D find different subsets.
  With 7D, each later run reports only new findings.
- One `--deep` run finds at least what the three separate runs found together, and
  stops by itself.
- A deliberately skipped hunk is caught by the coverage check.

## Not doing

- **Mixed models across `--deep` passes.** Each pass might find different defects on a different model, but it is not chosen for now, so one model per review still holds. Revisit if 7E stops finding new defects too early.

- **Output cap (`--max-findings`).** Nit batching plus 1c covers the noise problem. Add
  it when a real run produces an unreadable list.
- **`xhigh` / `max` levels.** `--deep` covers the depth. The spec's YAGNI call stands.
- **The built-in's 3-tier severity.** code-critic's five grades with impact lines are
  stronger.

## Evaluation (shared by all phases)

A fixture branch, with no network, holds a small diff that seeds:
- a dropped guard (removed-behaviour);
- a caller broken by a changed return shape;
- a caching wrapper that resolves through a registry;
- a JS falsy-zero check;
- a CLAUDE.md rule violation;
- one **uncommitted** defect;
- a false-positive bait (an apparent null deref guarded upstream).

Run code-critic, recording per-defect found/missed, before the work and after each
phase. Store the results next to the earlier one-vs-six recall notes. A phase ships only
if it finds what it targets without losing anything an earlier phase found.

## Shipping

Shipped together as one bump (0.41.0), with one commit per phase-group so it can be
bisected. Bump `github-pr-toolkit/.claude-plugin/plugin.json` and
the root `.claude-plugin/marketplace.json` together. Stack the phases on
`feat/code-critic-ui-ux-category` (0.40.0, unpushed), or branch per phase after 0.40.0
merges. Phase 4 depends on Phase 3; Phase 7 depends on Phases 3 and 4, with 7A and 7D usable without `--deep`; the rest, including Phase 6, are independent.
