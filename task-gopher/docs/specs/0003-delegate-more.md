# task-gopher 0003: Delegate MORE: an upfront directive aligned with the gate, and how we measure it

Implementer: implementor
Reviewer: reviewer

Status: design, for sign-off. Author: Architect. Date 2026-10-11. Brief 20261011-172035-zuz9 plus the user's
clarifications (gate nudge is KEPT as the backstop; two gophers; keep output out of context).
Paths are relative to `task-gopher/` (main checkout, plugin 0.22.0). Spec text only; no code is written here. The
directive and nudge wording below is content, quoted verbatim, and is the only text the Implementor must not reword.

## 1. Goal

Make delegation the default **before the first tool call**, so the strict gate's checkpoint fires only when the model
forgets. Persuasion by an upfront, short, accurate directive; the gate stays as the backstop. Purpose stated first in
the directive: **keep tool output out of the model's context; only the result comes back.**

Not in scope: the bounded-retrieval rewrite (0002) stays parked and opt-in; the PostToolUse cost line is not built;
the destructive guard, the verbatim-read gate, the smart-gopher gate and the relay's skip rules are unchanged.

## 2. What the audit log says (counts only; log 2026-07-24 to 2026-10-11, 107,737 rows)

- Strict-gated retrieval calls: 96,996 (62,551 bypasses, 34,445 checkpoints; 22,754 of those are "escalated" third-call
  denials, 11,691 are turn-start). Retrieval turns: 11,173. Mean direct calls per retrieval turn ≈ 8.7; 35% of turns
  have 6 or more.
- **The headline rate is mechanical, not behavioural.** The gate denies the first retrieval of a turn, passes the next
  two, and denies every third after (RENUDGE_AFTER=3). A turn with k direct calls therefore draws ceil(k/3) denials, a
  rate of at least 1/3 per call for any turn that makes direct calls at all. The measured 35.5% sits on that floor and has
  been flat since week 33. **"Nudges per retrieval call" cannot fall below about 1/3 whatever the directive does, so it
  is the wrong metric.** (This corrects the framing in the brief.)
- First row of each turn: a checkpoint in 10,322 turns, a dispatch in 2,331 (+ 360 other). Turns with a dispatch and no
  direct retrieval at all: 1,744. Among 3,719 turns with both, the dispatch came first in only 418. Upfront delegation is
  therefore about **18%** of work turns (2,331 of ≈12,917 turns that had a checkpoint or a dispatch).
- **Dispatches per 100 gated calls fell from ≈22 (weeks 31-32) to ≈4-5 (weeks 38-41)** while the directive was at
  1,742 words (SessionStart and every relay) plus a 349-word reminder on every user turn. I make no causal claim; the
  trend says the current text is not working, not why.
- What the gate catches (checkpoints, all time / last 30 days): Read 35.9% / 21.4%; Bash search 32.6% / 34.7%; Bash
  "other" 20.5% / 34.8%; git-read 6.0% / 5.4%; file-view (cat/head/tail) 3.5% / 3.3%; find 1.3% / 0.4%; build 0.1%;
  **test 0.0%**. Grep and Glob (the tools) never appear. The directive today leads with tests and builds, the category the
  gate almost never catches, and does not name the things it does catch: reading files and grepping.
- Inside "other" (last 30 days): python3 21%, sed 9%, git add 5%, node 5%, cat 5%, perl 3%, plus cd/for/&& prefixes the
  counting script did not normalise. So data-printing scripts (python3, node, perl, sed over files) are real retrieval.
- Classifier noise (counts from the 160-character `detail`, which truncates, so these are indicative): **39% of
  "search" checkpoints are incidental** (grep as a later pipeline stage, such as a filter on another command's output),
  and ~6% of Bash checkpoints lead with a cheap non-retrieval command (ls, echo, cp, mkdir, sleep). A nudge on a command
  the directive never called retrieval teaches the model to ignore nudges.
- 27% of Bash checkpoints already pipe through a trimmer (`| head`, `| tail`, `| wc`, `| jq`...).

## 3. Design

### D1. The directive (replaces FULL_DIRECTIVE's opening and SHORT_REMINDER; ≤250 words; verbatim)

```
[task-gopher: ON] PURPOSE: keep tool output out of your context; only the RESULT comes back. For Sonnet-tier and above, top-level or subagent. Haiku-tier, or no Agent tool: ignore this and work directly.

DEFAULT, not a preference: legwork goes to a gopher. Legwork = reading files to learn what is in them (Read, cat/head/tail/sed -n); searching (grep/rg/find); git log/diff/show/blame; test, build and lint runs; scripts (python3/node/perl/sed) that print data; any command likely to print over 40 lines; anything touching 3+ files.

PICK THE RUNNER:
- The order can be written with no decisions in it -> task-gopher:task-gopher (Haiku). E.g. "run the suite, report failures only".
- The answer needs picking among candidates, reconciling disagreeing evidence, a summary with an editorial cut, or later steps depend on earlier findings -> task-gopher:smart-gopher (Sonnet). E.g. "which of these call sites is the real entry point, and why".
- Neither -> do it yourself.

START with the order. If you have made 2 direct retrieval calls in a row, the next one goes to a gopher: bundle everything you still need into ONE order.

ORDER, 3 lines: WHERE (paths/branch). HOW (exact commands or method). BACK (what to return and the bar: "counts + file:line, at most 30 lines"). Never order a file back whole.

DO IT YOURSELF: reading a file you are about to Edit; one trivial peek; anything that needs your judgment. Gophers never decide design, security or scope.

A gate checkpoint means you did something listed above. Re-run only for an exception.
```

Rules for this text:
- A test asserts the word count is **≤250** (whitespace split) and that it contains both exact agent names
  `task-gopher:task-gopher` and `task-gopher:smart-gopher` (the bare name does not resolve), the strings `PURPOSE`,
  `PICK THE RUNNER`, the two example orders, the counter "2 direct retrieval calls", and the three-line order template.
- The tier gate stays a sentence of text: the hooks cannot read the model (no model field in the payload; the existing
  `TODO(hard-gate)` stays).
- It stays silent when the plugin is OFF, and inside either gopher and the six `ah:` roles, exactly as today.

### D2. Where each text goes (size is a design variable)

- **SessionStart and the relay's `updatedInput` stamp** carry the D1 text (≈235 words), replacing the 1,742-word
  FULL_DIRECTIVE. This cuts every subagent dispatch prompt by ≈1,500 words.
- **UserPromptSubmit** (every turn) carries a **≤45-word tick**: the purpose clause, the selector in one line, the
  counter. Today's 349-word reminder is replaced.
- **What was in the long directive and must not be lost, and where it goes:** the order contract's fourth line ("WHAT
  IF" the order cannot be followed), the ALLOW-DESTRUCTIVE pre-authorization line, the smart-gopher per-distinct-prompt
  checkpoint explanation, and the escape hatch **move into the gate's deny reasons and the agent definitions**, where they
  are read just in time. The destructive guard's behaviour (ask/block/off, sandbox escape, the allowance file) is
  **unchanged**; only the place that explains it moves. A row proves the deny reasons still tell a model how to pre-authorize.
- Per-agent frontmatter for the two gophers is unchanged.

### D3. One classifier table feeds the gate, the directive and the nudge

The category list the strict gate fires on, the "legwork =" list in D1, and the nudge wording in D5 come from **one
table** in the hooks code, with a row per category: id (read, search, find, git-read, test, build, view, script), the
words the directive uses for it, the runner the nudge recommends, and its nudge text. A test fails if a category the
gate can fire on is missing from the directive's trigger list, or the reverse. **That is how the directive stays aligned
with the gate's predicate:** a nudge then means "you did a thing the directive already told you to delegate."

The category order the gate uses is unchanged; "script" is a new label for the python3/node/perl/sed-over-files commands
the gate already catches under a pipeline-stage match. Adding a label changes no firing decision.

### D4. The gate's checkpoint (kept) and the nudge text (the secondary deliverable)

The checkpoint mechanics are **unchanged** (turn-start deny, two bypasses, every third denied, a dispatch resets, fail-open
cases). Only the deny reason changes, chosen by the category that fired, each ≤60 words, each ending with the
exception line "Re-run this exact call to proceed if it is an exception (a file you will Edit, one trivial peek, or
a step that needs your judgment)." and naming the right runner:

| Fired on | Text (verbatim) before the exception line |
|---|---|
| read | `task-gopher checkpoint: you are reading files to learn what is in them. Order it instead: task-gopher:task-gopher if you can name the question ("where is X defined, file:line"); task-gopher:smart-gopher if it needs judging or summarising. Order = WHERE / HOW / BACK.` |
| search, find | `task-gopher checkpoint: you are searching code. Order it: task-gopher:task-gopher for a known pattern ("every caller of f, file:line"); task-gopher:smart-gopher to decide which of several candidates is the right one. Order = WHERE / HOW / BACK.` |
| git-read | `task-gopher checkpoint: you are reading history or a diff. task-gopher:task-gopher for "list commits touching P since D"; task-gopher:smart-gopher for "what changed here and does it matter". Order = WHERE / HOW / BACK.` |
| test, build | `task-gopher checkpoint: a test, build or lint run. task-gopher:task-gopher: "run <cmd>, report failures only, at most 30 lines". Order = WHERE / HOW / BACK.` |
| view, script | `task-gopher checkpoint: a command likely to print data. task-gopher:task-gopher: "run <cmd>, return <what>". Order = WHERE / HOW / BACK.` |
| escalated (every 3rd) | the row's text, preceded by `That is 3 direct calls this turn; bundle what you still need into ONE order.` |

The calm one-line `systemMessage` shown to the user is unchanged.

### D5. Classifier hygiene (depends on evidence E1; a decision, not a build, until E1 returns)

If E1 shows the incidental-pipeline matches and the cheap-command matches are real gate firings (not an artefact of
`detail` truncation), the classifier should match a search word only as a **lead command, or a stage with a file or
directory operand, not as a stdin filter**, and should skip commands whose only matching stage is incidental. Rationale:
a nudge the directive did not predict erodes trust in every later nudge. Until E1 returns, make no classifier change.

### D6. The Read rule (DECIDED by the Orchestrator, 2026-10-11: stop denying the first Read)

Read is 36% of all checkpoints and 40% of turn-start ones. Claude Code requires a Read before an Edit, and that Read is
not delegable legwork. **The gate cannot see intent**: a PreToolUse hook sees the Read, not the Edit that may follow,
and a prompt-text heuristic ("the user said fix/change/add") is too fragile to gate on. So the rule is by tool, and it is
the only reliable form (called G1):

- **A Read that is the first direct retrieval of a context+turn passes silently instead of drawing the turn-start deny,
  and opens the cadence exactly as the turn-start deny did.** After it, the next two direct retrievals pass and the third
  is denied (the cadence is unchanged: the turn-start deny is simply replaced by a pass when the call is a Read).
- Any other first retrieval (Bash search, git-read, test/build, view/script) is denied at turn start as today.
- A Read that is not the first retrieval of the turn follows the unchanged cadence.
- A dispatch to either gopher resets the cadence as today, so a Read after a dispatch is again "first".
- Logging (additive): the pass is written as a `bypass` row with `n: 0`, the key `open: "read"`, and the usual `tool`,
  `detail`, `cls`. Existing readers that count bypasses still work; `report.mjs` reports `open: "read"` separately.
- **Consequence for measurement:** about 40% of historical turn-start checkpoints disappear mechanically. Metrics that
  count checkpoints (M3, M4) are therefore **not comparable across the change** without a re-baseline: `report.mjs`
  recomputes the historical log "as if G1" (Read turn-start rows treated as `open: "read"` passes) and prints both.
  M1, M2, M5, M6 are unaffected by G1.
- The weaker consequence the user accepts: a model that explores by Reading gets three free reads before a nudge. The
  directive's trigger list ("reading files to learn what is in them") still tells it not to.

### D7. Instrumentation (small, no behaviour change)

- I-1: `checkpoint` and `bypass` rows gain `cls` (the D3 category the gate matched; the true classifier output, replacing
  later guessing from the truncated `detail`) and `sh` (a short salted hash of the session id, for clustering). No raw ids.
- I-2 (optional): a **log-only** PostToolUse hook on Agent dispatches to either gopher that writes one row per result: the
  `agent`, the result length in characters, and whether the result is a STOP or an escalation request. It outputs nothing
  and injects no context. It exists only to measure mis-routes (§4). If the payload does not carry the result, the
  Implementor reports that and the proxy metrics of §4 stand alone.
- `report.mjs` additionally prints M1-M6 (§4). Today it counts neither `verbatim-deny` nor `exempt`; add both.

## 4. Metrics and targets

Per-call nudge rate is demoted to a diagnostic. Primary metrics are per **turn** (a turn = one `pid`):

| Id | Metric | Baseline (log to 2026-10-11) | Target |
|---|---|---|---|
| M1 | Upfront delegation: turns whose first work event is a dispatch ÷ turns with a checkpoint or a dispatch | ≈18% | ≥40% (≥30% is a pass) |
| M2 | Dispatches per 100 gated direct calls | 4-5 (weeks 38-41) | ≥10 |
| M3 | Escalated (third-call) checkpoints per retrieval turn | 2.04 | ≤1.0 |
| M4 | Turns whose first event is a checkpoint ÷ work turns (turns with a checkpoint or a dispatch) | ≈86% as the log stands; recomputed "as if G1" in the report (Read turn-starts counted as passes) | ≤50% on the "as if G1" basis; informational across the change (G1 lowers it mechanically) |
| M5 | Per-gopher dispatches per 100 gated calls (task-gopher, smart-gopher) | from `agent` on dispatch rows | report; no target |
| M6 | Mis-routes: (a) escalations: a smart-gopher dispatch in the same turn after a task-gopher dispatch (proxy), or a STOP/escalation row if I-2 exists; (b) decision-free smart-gopher orders: a blind-labelled sample of ≥100 smart-gopher order texts (the `smart-gate-checkpoint` rows hold the first 160 characters) | not yet measured | (a) ≤15% of task-gopher turns; (b) ≤20% of sampled smart orders |

Guard metrics that must not regress: verbatim-deny rows per 1,000 dispatches; destructive-blocked rows; task outcome in
the A/B (below); wall-clock per task (a dispatch has latency); unnecessary delegation (a dispatch for a Read-before-Edit
or a trivial peek).

"Nudges rare" is therefore stated as M1 up, M3 down, and the share of turns whose first event is a checkpoint falling
from ≈80% toward ≤50%; the per-call rate is not a target.

## 5. Measurement plan, and what we can and cannot conclude

**Pre-registered before any change ships:** the metrics and targets above, the task list, the sample sizes, and the
analysis (a two-proportion comparison per metric with session-clustered intervals).

1. **Telemetry before/after.** Baseline = weeks 38-41 of the existing log (M2 is flat there at 3.9-4.8 per 100, so the
   baseline is stable). After = the first ≥2 full weeks with I-1 on (≈2,400 retrieval turns at the current rate).
   - With a design effect near 4 for within-session clustering (unknown until `sh` exists), the effective n is ≈600 per
     arm; that detects a shift of about **8 points in M1** (≈3.5 standard errors) and a doubling of M2.
   - **We cannot conclude** that the directive caused it: the workload shifted by 5x in M2 across earlier weeks with no
     known cause, other plugin or model changes can land in the same window, and the user is one operator.
2. **Controlled A/B on a fixed task list** (what supports causation).
   - Arms: **A/A first** (baseline text twice) to measure run-to-run noise; then baseline vs new (D1+D2+D4). If A/A
     differs by more than 10 points on M1, the harness is too noisy to read and is fixed first. An optional third arm
     (new directive, old nudge text) separates directive from nudge; skip it unless the budget allows, and then accept
     that the two cannot be told apart.
   - Task list: 12 fixed tasks on a small checked-in fixture repository (no private names or paths): exploration across
     several files; "which of these is the real entry point"; run-and-report tests; a history question; summarise a
     module; a task needing a Read before an Edit (must not be delegated); a trivial peek; a judgment task. The mix must
     include tasks where delegating is wrong, so over-delegation shows.
   - Size: **7 fresh sessions per task per arm = 84 per arm.** For M1 at a pooled rate near 0.3 and a 20-point
     difference, 80% power at α=0.05 needs ≈80 per arm. A 10-point difference needs ≈310 per arm and is **out of reach**
     by runs; telemetry is the only route there.
   - All runs use a redirected home so `~/.claude/task-gopher.*` are sandbox copies; the user's real audit log is never
     written. No real project, no network.
3. **Why not assume it works.** The four earlier A/B comparisons of instruction text (for a different plugin) came back
   null; I do not know their power, and the effect of a persuasion text on a Sonnet-tier model's first action is
   plausibly small. This spec therefore commits to the A/A first, to reporting effects with intervals, and to stating
   "no detectable effect" when that is the result. A null here is a finding, and the gate remains the backstop either way.
4. **What the A/B cannot tell us:** whether answer quality changed beyond pass/fail on the fixed tasks; behaviour in
   long real sessions; other models; whether the effect persists past novelty.

## 6. Rollout

- **Files changed:** `hooks/directive.mjs` (D1 text, the tick, the category table), `hooks/sessionstart.mjs`,
  `hooks/userpromptsubmit.mjs`, `hooks/pretooluse-nudge.mjs` (the stamped text, the deny reasons by category, the `cls`
  and `sh` fields), a new log-only PostToolUse entry in `hooks/hooks.json` if I-2 is built, `hooks/report.mjs` (M1-M6),
  `tests/` (rows below), `README.md` (the directive section), the A/B harness and fixture under `tests/`.
- **Version:** bump `.claude-plugin/plugin.json` and the root `marketplace.json` entry **together** (a single minor bump
  from 0.22.0). The unmerged bounded-retrieval branch (0.23.x) must be rebased or renumbered by whoever merges second.
- **Staging:** I-1/I-2 and `report.mjs` ship first (no behaviour change) to collect the baseline with `cls`; E1 and E2 run
  on that; then D1-D4 ship; D5 and D6 follow only on their evidence.
- **Who verifies:** the Reviewer checks rows against this spec; an Implementor runs E1-E3 and the A/B; the Orchestrator
  reads M1-M6 from `/task-gopher report` after two weeks. The user decides D6 and the target values.
- Nothing is published or pushed; private remote only.

## 7. Evidence needed (not run by the Architect)

- **E1 (NEEDS-EVIDENCE).** Replay the strict gate's classifier over the retained command strings of the cheap-first-token
  and incidental-search checkpoints and report, for each, which pipeline stage matched. The `detail` field is truncated at
  160 characters, so use fresh sandboxed commands of the same shapes, or the I-1 `cls` data once it exists. *Decides D5:* if
  the matches are real, tighten the classifier; if they are truncation artefacts, leave it.
- **E2 (NEEDS-EVIDENCE, low priority; D6 is already decided).** From a sample of ≥200 session transcripts, for turns whose
  first retrieval was a Read, the fraction followed by an Edit or Write of the same path in the same turn. *Informs a
  revisit only:* if under 20%, the free first Read is mostly exploration and G1 is worth reconsidering.
- **E3 (NEEDS-EVIDENCE).** The A/A run of §5.2. *Decides* whether the A/B is readable at all.

## 8. Decisions made, and not made

- **Made:** keep the gate and its mechanics; replace the per-call nudge-rate target with per-turn metrics (the per-call
  rate has a structural floor of ≈1/3); shrink the injected directive from 1,742 words to ≈235 and the per-turn reminder
  from 349 words to ≈45, moving reference detail into the deny reasons and agent definitions; derive directive, gate and
  nudge from one category table; lead the trigger list with what the gate actually catches (reading, searching, scripts),
  not tests and builds; carve out Read-before-Edit in the text.
- **Decided by the Orchestrator:** D6/G1 (the first Read of a turn is not denied); the per-call "<10%" target is
  dropped in favour of the per-turn metrics.
- **Not made (user-owned):** the target values in §4; whether to run the third A/B arm (new directive with the old
  nudge text; with G1 now also in play, the arms can no longer be separated without it); whether the strict marker should
  become the default (the plugin is opt-in OFF today, and this spec does not change that).
- **Risk the Implementor should know:** the 1,742-to-235-word cut removes text some behaviours may rely on (the order
  contract's "WHAT IF", the allowance line). Row R-3 below must pass before the long text is deleted.

## 9. Invariants and negative cases

What must not change: the destructive guard (ask/block/off, sandbox escape, allowance file); the verbatim-read gate (the
H1-H3 hard deny); the smart-gopher per-distinct-prompt checkpoint; the relay's skip rules (gophers, the builtin agents,
the six `ah:` roles, the user exemption file, agents with no dispatch tool); the OFF, strict and guard state files; the
checkpoint cadence; fail-open behaviour; the audit log's existing keys and event names.

| Neighbouring input | Expected |
|---|---|
| Plugin OFF | No directive, no tick, no relay, no checkpoint (unchanged) |
| Inside `task-gopher` or `smart-gopher`, or an `ah:` role | Silent: no directive, no tick, no relay |
| A subagent dispatch to a non-gopher agent that can dispatch | Stamped with the D1 text (≈235 words), not the old 1,742 |
| A prompt already carrying `[task-gopher: ON]` in its first 200 characters | Passed through, logged `relay-ok` |
| A Haiku-tier model reading the directive | The tier sentence tells it to ignore the rest |
| Non-strict ON | Only the relay, the smart gate and the verbatim gate act; direct Read/Grep/Glob/Bash never touched |
| The first direct retrieval of a turn is a Read | Passes silently (`bypass`, `n: 0`, `open: "read"`); the next two pass; the third is denied (D6) |
| The first direct retrieval of a turn is a Bash search/git-read/test/build/script | Denied at turn start as today |
| A second Read, or a Read after other retrievals | The unchanged cadence |
| A Read right after a dispatch | Treated as first again (a dispatch resets) |
| A Read whose gate state cannot be written | Fail open (unchanged) |
| An exempt Bash (git/gh write, herdr, cd, sleep, plugin update, commit-message heredoc) | Not checkpointed (unchanged) |
| An order to a gopher naming a whole file or a range of 80+ lines | Still hard-denied (verbatim gate, unchanged) |
| A destructive command inside a runner | Still ask/block per the guard; the reason text still shows how to pre-authorize |
| A checkpoint of category *read*, *search*, *git-read*, *test or build*, *view or script* | The matching D4 text, ≤60 words plus the exception line |
| A command the classifier fires on that has no category in the table | Cannot occur: a test enumerates the classifier's outputs against the table |
| `cls` and `sh` absent in old log rows | `report.mjs` treats them as unknown and still prints |
| Missing `prompt_id`, unwritable state, agent with no Agent/Task tool | Fail open (unchanged) |

## 10. Verification (bash suites with the redirected home, as the existing tests)

- R-1: the D1 text has ≤250 words and every required token; the tick has ≤45 words; the SessionStart output and the
  relay stamp equal the D1 text exactly.
- R-2: the table test of D3 (every category the gate can fire on is in the directive and has a deny text, and the
  reverse).
- R-3: each deny reason is ≤60 words (plus the exception line), names the right runner for its category, and the
  destructive-guard and smart-gate reasons still contain the pre-authorization instructions.
- R-4: every row of §9 whose behaviour is unchanged passes the existing suites untouched (`test-relay-gate.sh`,
  `test-destructive-gate.sh`, `test-userpromptsubmit.sh`).
- R-5: `checkpoint` and `bypass` rows carry `cls` and `sh`; `report.mjs` prints M1-M6 on a synthetic log, and on the old
  log without crashing.
- R-6: the A/B harness runs end to end on 2 tasks in a redirected home and leaves the real `~/.claude/task-gopher.*`
  untouched (checked by digest).
- R-7 (G1 cadence): in one context+turn, Read, Read, Read, Read gives pass(`n:0`, `open:"read"`), pass, pass, deny; Bash
  grep first gives deny, pass, pass, deny; Read after a dispatch is again a free first; a Read as the second call follows
  the cadence; unwritable state fails open.
- R-8 (selector, folded from the user addendum): the D1 text contains the two-line selector with one example each and the
  exact names of both gophers; every D4 deny text names `task-gopher:task-gopher` or `task-gopher:smart-gopher`, and the
  *read*, *search/find* and *git-read* texts name both with their example; M5 (per-gopher counts) and M6 (mis-routes)
  are printed by `report.mjs`.

### Can-fail rows (each assertion is proven able to fail before it is trusted)

The test for R-1/R-2/R-3/R-8 reads the text it checks from a path or variable it is given, so a deliberately broken copy
can be fed to it. Each case below must make the test **fail**, and the test file runs all of them as a negative section
that itself fails if any broken copy passes:

| Broken copy | Must be rejected by |
|---|---|
| D1 text plus 30 extra words (over 250) | R-1 word cap |
| D1 with `task-gopher:smart-gopher` replaced by `smart-gopher` | R-1 / R-8 exact-name check |
| D1 without the `PURPOSE` clause first | R-1 ordering check |
| D1 without "2 direct retrieval calls" | R-1 counter check |
| D1 with the selector's smart-gopher bullet removed | R-8 |
| a category added to the gate's table but not the directive's trigger list | R-2 |
| a D4 text that names no gopher, or runs over 60 words | R-3 / R-8 |
| the tick over 45 words | R-1 |
| G1 broken (a Read first still denied; or a Bash first passed) | R-7 |

## 11. Implementation list (an Implementor builds this without further questions)

Paths relative to `task-gopher/`. The Implementor makes the code choices; the contracts are §3, §4 and §9.

1. `hooks/directive.mjs`: the D1 text (verbatim from §3) as the one text injected at SessionStart and stamped by the relay;
   the ≤45-word tick as the text injected every turn; the category table of D3 (id, directive wording, recommended runner,
   deny text, matched-by pattern) exported for the gate; remove the 1,742-word FULL_DIRECTIVE and the 349-word
   SHORT_REMINDER only after R-3 passes. Keep `SENTINEL`; keep `TODO(hard-gate)`.
2. `hooks/sessionstart.mjs` and `hooks/userpromptsubmit.mjs`: inject the new texts; same silence rules as today (OFF,
   inside the gophers, inside the six `ah:` roles).
3. `hooks/pretooluse-nudge.mjs`: (a) the relay stamps the D1 text; (b) deny reasons come from the category table, one per
   category plus the "escalated" lead sentence; (c) G1 (§D6); (d) `cls`, `sh` on `checkpoint` and `bypass` rows, and
   `open: "read"` on the free-Read pass; (e) the destructive guard, the verbatim gate, the smart gate and the relay's skip
   rules untouched. The deny reasons of the destructive and smart gates must still carry the pre-authorization text that
   the long directive used to carry (R-3).
4. `hooks/hooks.json` and a new small script, only if I-2 is built: a log-only PostToolUse entry for Agent dispatches to
   either gopher (writes one row; outputs nothing; fails open). If the payload lacks the result, skip I-2 and say so in
   the report.
5. `hooks/report.mjs`: add M1-M6; add `verbatim-deny` and `exempt` counts; print the "as if G1" recomputation of M3/M4 from
   the old log; treat rows without `cls`/`sh`/`open` as unknown; never throw (as today).
6. `tests/`: a new `tests/test-directive.sh` (R-1, R-2, R-3, R-8 and the can-fail section), additions to
   `tests/test-relay-gate.sh` (R-4 unchanged behaviour, R-5, R-7), HOME-redirected like the existing suites. No test
   touches the real home.
7. `commands/task-gopher.md` and `README.md`: describe the new directive, G1, and `report` additions in a few lines; remove
   any text that quotes the old directive.
8. Versions: bump `.claude-plugin/plugin.json` and the root `.claude-plugin/marketplace.json` task-gopher entry **together**
   to the same next minor from 0.22.0 (a test or a manual check asserts they are equal). There is no plugin CHANGELOG
   (none found); do not create one.
9. Private remote only; nothing pushed to origin; nothing merged to main (the user's parked decision).

Commit order inside the one order: (a) `report.mjs` and the `cls`/`sh` fields (no behaviour change); (b) category table,
D1, tick, D4 texts, G1, and the tests. The long directive text is deleted in (b) only after R-3 is green.

## 12. Orders

- **Order 1 (normal priority): §11.** Implementor; Reviewer afterwards against R-1..R-8 and the §9 table.
- **Order 2 (low priority, separate): E1, E2, E3 and the A/B harness (§5, §7).** E1 and E3 gate the D5 classifier decision
  and the readability of the A/B; E2 is informational. Nothing in Order 1 waits for them.
