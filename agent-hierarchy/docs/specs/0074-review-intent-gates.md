# 0074: review and intent gates in the role definitions

Implementer: implementor
Reviewer: reviewer

Version: `ah` 0.115.0. Comes after 0073 (0.114.0). If 0.114.0 is not on the branch you build from, stop and report: do not renumber.

**Generic-text rule (binding on everything this spec produces).** No text written under this spec names any product, third-party service, platform, customer, ticket, incident or originating repository. That covers:
- agent files and contracts;
- the directive;
- hook and CLI messages;
- README, CHANGELOG and cli-tools text;
- tests and fixtures;
- commit messages.

Describe failure classes on their own terms, such as "a value that falls back to a default on one caller path" or "a condition widened past its intended inputs". The Reviewer checks this rule like any other acceptance criterion. *(r3: user ruling.)*

## 1. Goal

The role chain has four failure classes. Close them, reusing what ah already has:
1. **A Reviewer can review with no intent.** It checks whether the code is correct, not whether the change delivers what it claims. A claim can be contradicted on a caller path the diff does not show, for example a newly emitted value that holds a default or fallback on one path.
2. **A Reviewer does not trace.** It does not follow new emitted values or changed conditions across caller paths, so a condition widened past its intended inputs goes unnoticed.
3. **Fixes made after a verdict reach a push without review.** Passing tests prove only the cases the fixer just wrote.
4. **Decision-rule fixes skip the design step** and its negative-case analysis, even when the fix is spelled out by a reviewer or a bot. An overbroad condition is exactly what that analysis catches.

## 2. What ah already has (read, not run), and what this spec reuses

- **Reviewer** `agents/reviewer.md` (6,688 B, ceiling 6,700, `tests/test-directive-size.sh:60`).
  - l.24–25 is today's no-spec fallback: "If you were given no spec path, say so and review against the stated intent, flagging that you had no spec."
  - l.32–39: the impl-defect / spec-defect split.
  - l.93–95: the report line (PASS / PASS WITH NITS / CHANGES REQUIRED).
  - Nothing on claims, tracing, prior threads or memory.
- **Orchestrator protocol.** It is injected by `hooks/lib-config.mjs` `buildDirective` (l.2996–3048) and is what every Orchestrator gets; `agents/orchestrator.md` only restates identity.
  - Item 3 (l.3032): the tiers. "Determined (request fixes the spec; no design choices left) → Implementor, then Reviewer."
  - Item 4 (l.3033): the spec handoff.
  - Item 6 (l.3035): the review loop, max 2 round-trips. It has no rule on what range a verdict covers.
  - Item 14 (l.2987): an Orchestrator at or above the Architect's tier takes the Architect contract inline. Its line number comes first because `protocolItems1214` (l.2976–2989) builds items 12–14 separately, and `buildDirective` splices them in at l.3043, after item 11.
  - Item 0 (confirm flow) is ah's existing "ask before each handoff" switch.
  - Directive ceilings: `AUTO_MAX=14600` and `CONFIRM_MAX=16500` (`tests/test-directive-size.sh:39–40`).
- **Architect** `agents/architect.md` (9,821 B, ceiling 9,900). The spec must include "behaviour for the edge cases, what must NOT change, and how the result will be verified". It has no negative-case table and no override enumeration.
- **Implementor** `agents/implementor.md` (5,425 B, ceiling 5,500). "Verify what you can". Nothing on negative tests or on assumptions in comments.
- **Custom-role contracts** `contracts/{review,design,implement,common}.md` are injected for custom and overridden chain roles (`contractBlock`, lib-config l.2909).
  - Ceilings are 450 B per class file and 900 B for common (`tests/test-custom-roles.sh:331–333`). The injected block is ≤ 1350 B (same file, l.325).
  - The class-contract validator (`validateAgentContract`, lib-config l.2578–2677) checks only frontmatter, model and tools, never contract text. So editing contract text cannot make a user role unavailable.
- **Dispatch gate** `hooks/pretooluse-msg-gate.mjs` (114 lines).
  - It reads the request file (`validateRequestToken`, lib-hier l.617–629) and checks `type` and `to:`.
  - Exempt: task-runner/gopher, subagent context, SendMessage without the sentinel, a disabled hierarchy, `msgs:"off"`. Any internal error allows.
  - A SendMessage is checked only when it carries `[hierarchy-peer-brief` (l.85–93). Its role comes from the `to` address via `resolvedPeerTargets` (l.99–105). A no-sentinel send returns at l.92, before `resolveConfig` (l.96–97).
  - Observed in practice: peer briefs arrive as `[hierarchy-msg <path>] …` with no sentinel. **A gate keyed on the sentinel therefore misses the peer-Reviewer route.**
- **Pane dispatch** (`route: pane` members, non-`claude` kinds) goes through `node hooks/roster.mjs deliver <name> --req <request path>`, run in Bash. msg-gate never sees it.
- **Class test.** `roleClass(role, resolved)` in `hooks/lib-config.mjs` (around l.376) returns a role's class. `=== "review"` is true for the built-in `reviewer` and for every custom review-class role. msg-gate does not import it today.
- **Token extraction.** `extractMsgToken` (lib-hier l.591) returns the first `[hierarchy-msg …]` token in a text.
- **Message skeleton.** There is one skeleton, `REQUEST_KEYS` / `RESPONSE_KEYS` (`hooks/lib-hier.mjs:52–53`, `skeletonBody` l.195), with no per-role variant. Briefs in practice often carry their content in the `[0] tldr` lines and leave the sections `- none`.
- **Push guard** `hooks/pretooluse-push-guard.mjs`. It is active only in repos that opted in (`.claude/ah-conventions.json`) and during /pipeline merges. It has no notion of a review verdict.
- **/pipeline** (`skills/autonomous-pipeline/SKILL.md` l.1234–1236). Its gate Reviewer reviews the whole `<base>..ah/issue-<N>` range each round, so every fix commit is already re-reviewed there. Rule O1 is already met in /pipeline, and this spec leaves the skill unchanged.
- **Memory.** No ah file mentions any memory tool. A memory plugin, where installed, injects its own recall directive.

## 3. Rules

Each rule has an ID that later sections cite. Each one says whether it is adopted as stated or adapted, what enforces it, and where it lands.

| ID | Rule | Why | Enforced by |
|---|---|---|---|
| R1 intent | **Adapt** the l.24–25 fallback. No spec but stated intent → review and flag "no spec". No intent anywhere (no spec, no goal plus acceptance in the brief, no ticket or PR text the Reviewer can fetch read-only) → verdict `NEEDS-INTENT` naming what is missing; no review. | Keeps the useful no-spec path; closes the empty one. | Prose (reviewer.md, contracts/review.md), backed by the O2 hook. |
| R2 claims audit | **In the Reviewer definition**, not in a brief template. Scoped to claims from the spec or brief goal and acceptance, the PR title and description, and claims the diff itself adds (comments, test names, names and descriptions of logs, metrics and tags). | A template only works when the Orchestrator fills it, and an unfilled brief is one of the failure modes. | Prose plus a required report section. |
| R3 provenance trace | Every value the diff newly emits or persists (log, metric, span, tag, event, stored field, response). Trace it on every caller path that reaches it. | The class is "an observable output that holds a default or fallback on some path". The scope keeps the cost to what the diff touches. | Prose. |
| R4 condition probe | For each condition the diff adds or changes: the input classes it matches, which are unintended, and the nearest neighbours no test covers. | Catches a condition widened past its intended inputs, and the same mistake repeated one dimension at a time across successive fixes. | Prose. |
| R5 prior verdicts are claims | A thread marked resolved, or a brief saying an area is handled, is re-checked at HEAD. | Removes the "already fixed" skip. | Prose. |
| R6 optional recall | A memory tool is available → recall past review findings for the changed files first; none → skip. | No store can be assumed. | Prose; never a dependency. |
| O1 verdict range | A verdict covers only the range it names. Any behaviour-changing commit after it needs a Reviewer verdict on `<reviewed head>..HEAD` before push, PR, merge or reporting done. The Reviewer report names its range. A purely formatting, rename, comment or docs change is exempt, said so to the user. Outside findings after a PASS start a new loop with its own cap. | Tests written alongside a fix prove only the cases in front of the fixer. The range in the report makes a future hook possible. | Prose (directive item 6). **Hook not built** (user ruling, Q2): ah has no reviewed-head record yet, and the push guard runs only in opted-in repos. |
| O2 intent in review briefs | No new skeleton keys: `[1] goal` carries the intent and its source, `[5] acceptance` the criteria. A `claims-to-verify` field is **not** added, because R2 makes the Reviewer derive the claims itself. | One skeleton stays one skeleton. | **Hook plus CLI**, keyed on the request file's `to:` rather than on the dispatch shape, so every route that names a request is covered (§4.6). msg-gate covers the Agent/Task spawn and every SendMessage that names a request; `roster.mjs deliver` covers pane members. |
| O3 decision rules take the design step | A change that adds or alters a decision rule (condition, fallback, default, precedence) is never "Determined", even when a review spells out the fix. It takes the design step: the Architect, or the Architect contract inline under item 14, with its negative cases. **No new "confirm-before-Architect" preference**: item 0's `handoffs:"confirm"` already provides that. | Fits item 3 and item 14 instead of adding a rule beside them. | Prose (directive item 3). |
| O4 prior threads are context | Prior threads go in `[2] context` as unverified, never as resolved. | The brief-side half of R5. | Prose (item 6). |
| A1 invariants and negative cases | The section is mandatory in every spec. | Overbroad conditions are negative-case holes. | Prose (architect.md, contracts/design.md), plus an Orchestrator check before Implementor dispatch (item 4). **No hook**: a request file names its spec path in free text, so no reliable locator exists. |
| A2 override enumeration | In the same bullet as A1. | — | Prose. |
| I1 negative test per condition | Every condition the Implementor adds or widens gets a test for the nearest input that must not match. | — | Prose plus a report line. |
| I2 no unsourced external claims in comments | — | — | Prose. |

Two related points:
- How `NEEDS-INTENT` relates to the old no-spec fallback is settled by R1.
- The rules are written by failure class, so they apply to any kind of change, not to one domain.

## 4. Changes

All text marked "add" below is the required **content**. The Implementor may tighten the wording to meet a byte ceiling, but must keep every rule, scope limit and token (`NEEDS-INTENT`, `verified | unverified | contradicted`, `<base>..<head>`, "Invariants and negative cases"). Everything obeys the generic-text rule at the top.

### 4.1 `agents/reviewer.md`

- **Replace** the l.24–25 sentence. No spec path → review against the intent the brief states (goal plus acceptance, or a ticket or PR description fetched with a read-only tool), flagging that there was no spec. No intent anywhere → no review; verdict `NEEDS-INTENT`, naming what is missing.
- **Add a bullet, "Trace, don't skim"** (R2, R3, R4, R6):
  - (1) The claims audit, with `verified | unverified | contradicted` and `file:line` for each claim.
  - (2) Provenance for each newly emitted or persisted value, on every caller path, naming any path where it holds a default, a fallback or another value.
  - (3) For each added or changed condition: the input classes it matches, which are unintended, and the nearest neighbours no test covers.
  - (2) and (3) are scoped to what the diff touches.
  - The optional memory recall comes first, and is skipped silently when no memory tool is available.
- **Add a bullet, "Prior verdicts are claims"** (R5): a thread marked resolved, or a brief saying an area is handled, is re-checked at HEAD and is never a reason to skip.
- **Report line** (l.93–95) becomes, in order:
  - verdict: PASS / PASS WITH NITS / CHANGES REQUIRED / NEEDS-INTENT;
  - the range reviewed, in exactly one of three forms:
    - `<base>..<head>` (short SHAs) for committed work;
    - `working tree on <head>` for uncommitted work;
    - `n/a: spec review of <path>` (or `n/a: plan review of <path>`) for a review with no diff;
  - a Claims list, one line per claim with its status;
  - the findings as today.
- Frontmatter: unchanged.

### 4.2 `agents/implementor.md`

- **Add** (I1): every condition you add or widen gets at least one test for the nearest input that must NOT match; name each in your report.
- **Add** (I2): a comment may assert an external system's behaviour (a response shape, a library default) only when the spec or evidence cites it. Otherwise leave it out and list it in the report as an assumption.
- **Report line** (last paragraph): also lists the negative tests added and any assumptions.

### 4.3 `agents/architect.md`

- In the "implementable by someone with no other context" bullet, **add** (A1, A2): every spec has an **Invariants and negative cases** section. It states what must NOT change, plus a table of neighbouring inputs the change must leave alone, each with its expected outcome. A rule of the form "when X, substitute, override or fall back to Y" enumerates every other input that also satisfies X, and what happens to each.

### 4.4 `contracts/` (custom roles get the same rules, compressed)

- `review.md` **add**:
  - no spec and no stated intent → `NEEDS-INTENT`;
  - audit the change's claims (`verified | unverified | contradicted`);
  - trace new emitted values on every caller path;
  - probe changed conditions;
  - re-check any claim of prior resolution;
  - report the `<base>..<head>` range.
- `design.md` **add**: every spec has an Invariants and negative cases section; enumerate the other inputs that match an override's condition.
- `implement.md` **add**: each condition you add or widen gets a negative test; unsourced external behaviour is a reported assumption, never a comment.
- `common.md`: unchanged.

### 4.5 Orchestrator directive (`hooks/lib-config.mjs` `buildDirective`)

`agents/orchestrator.md` is unchanged. The protocol carries these rules because every Orchestrator gets it.

- **Item 3, append (O3):** a change that adds or alters a decision rule (a condition, fallback, default or precedence) is never Determined, even when a review (human or bot) spells out the fix. It takes the design step: the Architect, or the Architect contract inline under item 14, negative cases included.
- **Item 4, append (A1 check):** when a spec exists, it has an Invariants and negative cases section before the Implementor runs; if it is missing, the spec goes back to its author. A spec you wrote inline under item 14 is not self-checked: the Reviewer gets that spec as its intent, and the R4 condition probe runs against it.
- **Item 6, append (O1, O2, O4, R1):**
  - A verdict covers only the range it names. Any behaviour-changing commit after it, whether rework or a fix for an outside finding, needs a Reviewer verdict on `<reviewed head>..HEAD` before push, PR, merge or reporting done.
    - Passing tests are no substitute.
    - The only exemption is a purely formatting, renaming, comment or docs change, and you say so to the user.
    - Outside findings after a PASS start a new loop with its own cap.
    - If the reviewed head is no longer an ancestor of HEAD, review `<base>..HEAD`.
    - Uncommitted work reviewed as `working tree on <head>` is committed, and the commit reviewed as a delta, before push.
  - A Reviewer brief carries its intent: `[1] goal` holds what the change must deliver and its source (spec path, ticket or PR text); `[5] acceptance` holds the criteria. A gate denies a Reviewer dispatch without them.
  - Prior review threads go in `[2] context` as unverified, never as resolved.
  - `NEEDS-INTENT` → supply the intent (ask the user when you lack it) and re-dispatch. It does not count toward the round-trip cap.
- The same text appears in the `auto` and `confirm` directives.

### 4.6 Review-class intent check (msg-gate hook and `roster.mjs deliver`)

- **One shared check.** Add it to `hooks/lib-hier.mjs` next to `validateRequestToken`. Given a request file's parsed content, it reports which of goal and acceptance are empty. Both callers below use it; no caller parses sections itself.
  - The review-class decision is `roleClass(<to>, resolved) === "review"` from `hooks/lib-config.mjs`, where `<to>` is the request file's frontmatter `to:`.
  - An unknown role makes `roleClass` return no class → not review → no check.
- **Route coverage:**

| Route | How it is gated | Why |
|---|---|---|
| Agent/Task spawn of a review-class role (top-level session) | msg-gate: after today's `validateRequestToken` passes, run the intent check when the request's `to:` is review-class. | Today's gate already reads this file. |
| SendMessage whose **first** `[hierarchy-msg …]` token (via `extractMsgToken`) names an absolute path ending `--request.md`, with or without the `[hierarchy-peer-brief` sentinel, to any address | msg-gate: if the file exists, has `type: request`, and its `to:` is review-class, run the intent check. Later tokens in the same text are ignored. Today's sentinel path is unchanged; the intent check also runs on sentinel sends after their existing checks pass. | Peer briefs in practice carry no sentinel, and `uds:` addresses may not resolve through `resolvedPeerTargets`. The request file is the one reliable key. |
| SendMessage with no `[hierarchy-msg …]` token, or one naming a `--response.md` | not checked | Pings, chat and reports are not dispatches. |
| SendMessage naming a request that is missing or unreadable, with no sentinel | allowed (as today) | Such sends were never checked; a missing file is not an intent signal. |
| `roster.mjs deliver <name> --req <path>` (pane members, any kind) | deliver runs the same intent check when the request's `to:` is review-class. On failure it refuses: non-zero exit, the reason below on stderr, nothing delivered. | Bash calls never pass through msg-gate; deliver already reads the request file. |
| Any dispatch from a subagent context (`agent_id` set) | not checked (existing exemption) | Roles never dispatch roles; the top-level route is gated. |
| /pipeline Reviewer dispatch | gated by whichever route above it uses | See N2. |
| `msgs:"off"`, or a disabled hierarchy | not checked (existing exemption) | A user opt-out stays an opt-out. Because no-sentinel sends return at l.92 before config loads, the new no-sentinel path loads the config and applies these exemptions itself, before checking intent. |
| A prose tasking SendMessage with no `[hierarchy-msg]` token, or a pane reached directly through a terminal multiplexer rather than `roster.mjs deliver` | **not hook-checkable**; the backstop is the Reviewer's own R1 (`NEEDS-INTENT`) | Gating token-less text would hold ordinary chat, and a direct pane send never passes through ah. |

- **Check:** the request has a non-empty **goal** and a non-empty **acceptance**.
  - A key counts as non-empty when either its `[0] tldr` line (`- [N] key: <text>`) has text after the colon, or its `## [N] key` section has a bullet whose text is not empty.
  - Text counts as empty when it is blank, or (trimmed, case-insensitive) one of `none`, `n/a`, `na`, `-`, `tbd`.
  - Locate both by key name (`goal`, `acceptance` from `REQUEST_KEYS`), not by index.
- **Deny** (same `decide` shape as today), with these texts:
  - Reason: `ah: a Reviewer brief needs its intent. Fill [1] goal (what the change must deliver, and its source: spec path, ticket or PR text) and [5] acceptance in <path>, then re-issue this dispatch. Missing: <goal|acceptance|goal, acceptance>.`
  - systemMessage: `ah: held a Reviewer dispatch until its brief states the intent; it will be re-sent.`
- **The deny is not one-shot.** It re-checks the file on every attempt, and a filled file passes at once.
- **Deny order.** Every existing check and deny, including the one-shot `notify_when_idle` deny (msg-gate l.47–58), runs first. The intent deny comes only after all of them pass, so there is at most one hold per attempt.
- **deliver's refusal text** is the same reason line, with "re-issue this dispatch" reading "re-run deliver".
- **Unchanged:** all existing exemptions, and "any internal error allows" in msg-gate.
  - A parse failure while checking intent allows in msg-gate.
  - In deliver, an internal error in the intent check proceeds with the delivery, so the check never strands a pane.
  - Reuse the `readMsgFile` read; there is no second section parser.
- Header comments: one sentence on the review-class intent check, in msg-gate and at deliver.
- `docs/cli-tools.md`: one line under `deliver` saying that a review-class request needs goal and acceptance.

### 4.7 Ceilings (a deliberate decision, per spec 0045 §9.6)

New ceilings are the measured size after the change, rounded **up** to the next 100 B (the next 50 B for contracts). They must not exceed these caps; if the text cannot fit, report a gap rather than raising further.

| File / measure | Today | Cap |
|---|---|---|
| reviewer.md | 6,700 | 7,900 |
| implementor.md | 5,500 | 5,900 |
| architect.md | 9,900 | 10,300 |
| directive auto / confirm | 14,600 / 16,500 | +700 each |
| contracts/review.md, design.md, implement.md | 450 each | 450 (no raise; must fit) |
| injected contract block | 1,350 | 1,400 |

- Update `tests/test-directive-size.sh` and `tests/test-custom-roles.sh` (l.325, l.331–333) to the new numbers.
- Update the comment beside the ceilings only if it states a reason that is no longer true.

### 4.8 Tests

- **Hook and CLI.** Add cases H1–H22, plus H7b and H7c, from §6:
  - msg-gate cases go in the existing test that covers `pretooluse-msg-gate.mjs` (the Implementor finds it; the name is unverified);
  - deliver cases go in the existing test that covers `roster.mjs deliver` (same).
- **Content assertions.** Add one small test script, or add to an existing agent-content test if one fits. Grep for:
  - reviewer.md: `NEEDS-INTENT`, `unverified`, `contradicted`, `<base>..<head>`, `working tree on`, `n/a:`, "caller path", "Prior verdicts are claims" (R5; amended from "resolved", which base reviewer.md already holds, so it could not fail at base; the new phrase has 0 hits at base d481f93 in reviewer.md, orchestrator.md and contracts/review.md);
  - implementor.md: "must NOT match", "assumption";
  - architect.md: "Invariants and negative cases";
  - contracts/review.md: `NEEDS-INTENT`;
  - contracts/design.md: "negative cases";
  - contracts/implement.md: "negative test";
  - `buildDirective` output in both modes: "covers only the range", "never Determined", "Invariants and negative cases", `NEEDS-INTENT`.
  - Each assertion must be seen FAILING at HEAD before the edit, and passing after. Pick tokens only the new rule text introduces; a common word the base file already contains does not qualify.
- **Generic review scenario (§4.10).** Its deterministic self-check script.
- **Generic-text rule: enforced by review, not by a test** (ruled; the deny-list grep is dropped). A deny-list test would have to name the very words the rule forbids, in a committed file, so the test would break the rule it enforces. Instead the Reviewer reads the full diff and every commit message against the generic-text rule (top of spec) and reports any hit as a finding. Do not add a deny-list, word-list or name grep anywhere.
- Full ah suite green.

### 4.9 Docs and version

- `agent-hierarchy/CHANGELOG.md`, new `0.115.0` section, in generic terms:
  - Added: the review intent gate (hook and deliver); the Reviewer claims audit, provenance trace and condition probe; `NEEDS-INTENT`; the reviewed range in reports; the spec's Invariants and negative cases section; Implementor negative tests; the generic review scenario fixture.
  - Changed: a verdict covers only its range, and fixes after it are re-reviewed.
- The README section describing roles or the review loop, if one exists: one sentence each on `NEEDS-INTENT` and on the re-review rule. If none exists, change nothing.
- Version `0.115.0` in `agent-hierarchy/.claude-plugin/plugin.json` and the root `.claude-plugin/marketplace.json` agent-hierarchy entry, together.

### 4.10 Generic review scenario (user ruling Q3)

A small synthetic fixture that has both failure classes. A deterministic self-check proves the defects really exist, so the scenario cannot rot into a fixture that contains no bug. The Reviewer-behaviour part stays a written manual check, because no cheap deterministic form exists: any check of what a Reviewer *reports* needs a model run, and its output is not exact. That is why the scenario is a fixture plus a self-check, not an eval.

- **Location:** `agent-hierarchy/tests/fixtures/review-scenario/`, plus the script `agent-hierarchy/tests/test-review-scenario.sh`. Plain Node ESM with no dependencies. Use generic domain words only: "item", "kind", "stored kind", "reason".
- **Three snapshots** (full files, not patches), each a small module with the same shape:
  - `v0/`, the base. There are two loaders.
    - **List path:** reads an item record and infers `kind` from other fields when `kind` is absent (an item with an `expires` field → `"temporary"`).
    - **Single-item path:** maps an absent `kind` to `"unspecified"`, and a value it does not recognise to `"unspecified"` with `reason: "unrecognized"`.
    - An emit function reports `{ id }` for the single-item path.
  - `v1/`, change 1. The emit adds `kind`, taken from the single-item loader. Its comment and test name claim: "emitted events carry each item's real kind".
    - **Defect:** on the single-item path, a temporary item with no explicit `kind` emits `"unspecified"`. The claim is contradicted on that caller path.
  - `v2/`, change 2. A "fix": when the loaded kind is `"unspecified"`, substitute the item's stored kind.
    - **Defect:** the condition is wider than intended. It also rewrites a non-temporary item with an absent kind to its stale stored kind, and it masks an `"unrecognized"` value, dropping its `reason`.
  - `brief-v1.md` / `brief-v2.md`: request-skeleton briefs with goal and acceptance filled, stating the claim. They are used by the manual check.
- **The self-check** (`test-review-scenario.sh`, deterministic, no model, no network):
  - (a) v1: feeding a temporary item without `kind` through the single-item emit yields `"unspecified"`, while the list path yields `"temporary"`. That proves the claim is contradicted.
  - (b) v2: an item with an unrecognised kind emits the stored kind and no `reason`, and a non-temporary item with an absent kind emits the stored kind. That proves the condition is overbroad.
  - (c) v0: emit has no `kind`, as a baseline.
  - Each assertion prints PASS/FAIL, and the script exits non-zero on any failure. It needs no temp dir: it runs `node` against the fixture files in place and writes nothing.
- **Manual check M2** (§7) uses this fixture.

## 5. Must NOT change

- `REQUEST_KEYS`, `RESPONSE_KEYS` and `skeletonBody`: one skeleton, no per-role variant.
- msg-gate's existing behaviour for every non-review role and every existing exemption; "any internal error allows". The intent check only adds denials for review-class requests; it never removes a check.
- `roster.mjs deliver` for every non-review request.
- `pretooluse-push-guard.mjs`, and `skills/autonomous-pipeline/SKILL.md` (except the possible one-line N2 edit).
- The class-contract validator (`validateAgentContract`).
- `agents/orchestrator.md`.
- The Reviewer's read-only, never-execute contract, and the impl-defect / spec-defect split.
- The item 6 round-trip cap (2), and its escalation to the Ultra-Advisor.
- Item 0 and the confirm flow. No new user preference or config key.
- No dependency on any memory plugin: R6 is conditional prose only.

## 6. Invariants and negative cases (A1 and A2 applied to this spec)

**The hook rule, "when a review-class dispatch's goal or acceptance is empty → deny".**

| # | Input | Expected |
|---|---|---|
| H1 | Reviewer request, goal and acceptance filled in the tldr lines only, sections `- none` | allow |
| H2 | Reviewer request, filled in the sections only, tldr text blank | allow |
| H3 | Reviewer request, goal blank in both places | deny, `Missing: goal` |
| H4 | Reviewer request, acceptance `- [5] acceptance: n/a`, section `- none` | deny, `Missing: acceptance` |
| H5 | Implementor or Architect request with an empty goal | allow (not review-class) |
| H6 | Custom review-class role request, goal empty | deny, as for the reviewer |
| H7 | `msgs:"off"`, Reviewer request with an empty goal | allow (exemption) |
| H7b | `msgs:"off"`, no-sentinel SendMessage naming a reviewer request with an empty goal | allow (exemption) |
| H7c | Hierarchy disabled; otherwise the same as H7b | allow (exemption) |
| H8 | Subagent context (`agent_id` set), Reviewer request with an empty goal | allow (exemption) |
| H9 | SendMessage to a Reviewer peer with no `[hierarchy-msg]` token (a ping or chat) | allow (not a dispatch) |
| H10 | Reviewer request, goal "see spec", acceptance filled | allow. Semantic thinness is caught by the Reviewer's `NEEDS-INTENT`. |
| H11 | Ultra-Advisor second-opinion request with an empty goal | allow (not review-class) |
| H12 | Request file that disappeared or has bad frontmatter | today's deny (validateRequestToken), unchanged |
| H13 | No-sentinel SendMessage naming a reviewer request with an empty goal, to a `uds:` address | deny, `Missing: goal` |
| H14 | Same as H13 with goal and acceptance filled | allow |
| H15 | No-sentinel SendMessage naming an architect request with an empty goal | allow (not review-class) |
| H16 | No-sentinel SendMessage naming a `--response.md` | allow (not a request) |
| H17 | No-sentinel SendMessage naming a missing request path | allow (as today) |
| H18 | Sentinel peer brief to a Reviewer, no `notify_when_idle`, empty goal | the existing notify deny first; after it is fixed, the intent deny |
| H19 | `roster.mjs deliver` with a reviewer request whose acceptance is empty | refused: non-zero exit, reason on stderr, nothing delivered |
| H20 | `roster.mjs deliver` with an implementor request whose goal is empty | delivered as today |
| H21 | Request whose `to:` is a role the config does not know | allow (no class → not review) |
| H22 | SendMessage whose first token is an architect request, citing a reviewer request with an empty goal later in the text | allow (first token only) |

**The range rule, "the report names its range".**

| Input | Expected |
|---|---|
| Committed work | `<base>..<head>` |
| Uncommitted working tree | `working tree on <head>`; the commit then needs a delta review before push |
| Spec or plan review, no diff | `n/a: spec review of <path>` |
| A NEEDS-INTENT verdict | the form that would apply, or `n/a`; it does not count toward the cap |

**O1, "behaviour-changing commit after a verdict → re-review the delta".**

| Input | Expected |
|---|---|
| Docs-only, comment-only, rename-only or formatting-only commit | exempt, stated to the user |
| Generated file or lockfile change | **not** exempt (it can change behaviour) |
| Test-only change | **not** exempt (a test change can hide a defect) |
| Fix for an outside (bot or human) finding after a PASS | re-review; a new loop with its own cap |
| History rewritten so the reviewed head is not an ancestor | review `<base>..HEAD` |
| /pipeline run | already covered by its full-range gate |

**R1, "no intent → NEEDS-INTENT".**

| Input | Expected |
|---|---|
| No spec; brief has goal and acceptance | review; flag "no spec" |
| No spec; a PR or issue description the Reviewer can fetch read-only | review against it; flag "no spec" |
| Spec path given; brief goal thin | review against the spec |

**O3, "decision-rule change → never Determined".**

| Input | Expected |
|---|---|
| A typo or a config value with no condition | trivial or Determined, as today |
| A constant that a condition compares against (a threshold) | decision rule → design step |

**The generic-text rule.**

| Input | Expected |
|---|---|
| A failure-class description ("a fallback on one caller path") | allowed |
| Any product, service, platform, customer, ticket or incident name, in any file this spec touches | not allowed |
| Generic fixture words (item, kind, reason) | allowed |

## 7. Acceptance

**Automated** (all green):
1. The hook and CLI tests H1–H22 (with H7b and H7c) pass.
2. The content assertions in §4.8 pass, and each was seen failing at HEAD first.
3. `tests/test-review-scenario.sh` passes (a), (b) and (c). It is also seen failing when a snapshot's defect is removed, for example by temporarily making v1's single-item loader infer the kind. Revert that afterwards.
4. `tests/test-directive-size.sh` and `tests/test-custom-roles.sh` pass with the new ceilings, which are within the §4.7 caps.
5. The full ah suite exits 0.
6. `claude plugin validate agent-hierarchy` lists the same hooks as 0.114.0.
7. The generic-text rule holds across the diff. The Reviewer confirms it by reading the full diff and commit messages; there is no test for it (§4.8).

**Manual checks** (the user or the Orchestrator; optional; plain words):
- **M1.** Ask for a Reviewer on a small change with no spec and an empty goal: the dispatch is held and asks for the goal. Fill in only "review this", with no acceptance: still held. Fill in both: the review runs.
- **M2.** Using `tests/fixtures/review-scenario/`:
  - Ask a Reviewer to review v0→v1 with `brief-v1.md`. Its Claims list marks "emitted events carry each item's real kind" as `contradicted` on the single-item path.
  - Then ask it to review v1→v2 with `brief-v2.md`. Its condition probe names the non-temporary absent-kind item and the unrecognised kind as unintended matches.
- **M3.** After a Reviewer PASS, make one behaviour-changing commit and ask the Orchestrator to push. It dispatches a Reviewer on `<reviewed head>..HEAD` first.

## 8. NEEDS-EVIDENCE (Implementor measures; none blocks the design)

- **N1.** Byte sizes before and after: `buildDirective` (auto and confirm), each edited agent file, and the injected review/design/implement contract blocks. Set the ceilings per §4.7. A size over its cap is a gap.
- **N2.** Does `/pipeline`'s reviewer brief step fill `[1] goal` and `[5] acceptance`? Read the skill's brief instructions.
  - If yes, nothing changes.
  - If no, add one line to that step requiring both. That is the only allowed skill edit; a gate deny mid-run would otherwise cost a round.

## 9. User rulings and open items

- **Q1 (ruled): accept** the deeper review reading, scoped to what the change touches.
- **Q2 (ruled): no hard push gate now.** O1 stays prose, and the reported range keeps a later hook possible.
- **Q3 (ruled): a generic test, not a replay.** That is §4.10 together with the generic-text rule.
- **Deny-list test (ruled): dropped.** A deny-list would carry the very words the rule forbids, so the generic-text rule is enforced by Reviewer reading (§4.8).

## 10. Risks for the Implementor

- `reviewer.md` has 12 B of headroom today. The new text must be tight to fit the 7,900 cap.
- Contract files must fit 450 B with no raise; `review.md` is 215 B today.
- The hook must never block a non-review dispatch, and it must allow on any internal error. A wrong class lookup could block every Reviewer; cover H5, H6, H11, H15 and H21.
- The no-sentinel SendMessage path widens which sends msg-gate inspects. It may deny only when all of these hold: a readable `--request.md` is named (first token), its `to:` is review-class, and its intent is empty. Every other send must leave the hook exactly as today.
- The no-sentinel path runs after the exemption checks (config load, `msgs:"off"`, disabled, subagent), not at today's l.92 early return.
- The scenario fixture must stay generic (generic-text rule) and must keep its defects. The self-check exists to prove both.
