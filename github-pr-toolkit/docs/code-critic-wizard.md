# `/code-critic` wizard — steps and paths (design, rev 1)

Status: implemented in github-pr-toolkit 0.41.0 (`commands/code-critic.md` L3, L3.0, L3.1, L4). It replaces the reviewer and model part of L3 and
L3.0 in `commands/code-critic.md`. Every other ask keeps its current content and moves
only where this doc says so.

**Hard constraints** (unchanged; they explain the shape):
- `AskUserQuestion` takes ≤ 4 questions per call and ≤ 4 options per question. "Other"
  is always added automatically.
- A question needed later is never deferred to "after". That is how asks went missing
  before. A question that may turn out not to apply is still asked, and if it doesn't
  apply, a one-line note says so.
- Flags and plain-language statements answer a question in advance. That question is
  then skipped and the answer is announced in one line.

## The flow at a glance

```
/code-critic [args]
  │
  ├─ Step 0  arm guard · parse flags (--level --deep --pre-existing --fresh --intent)
  │          mode: PR given → PR flow │ --branch/--against/nothing → Local │ ambiguous → ASK 0
  │
  ├─ ASK A  "Set up the run"                       (Local L1 / PR G1.1)
  │    Q1 Outcome     report only* │ fix │ decide after       (PR: comment* │ fix on branch │ decide after)
  │    Q2 Target      Local: base = main* │ other branch │ commit/tag
  │                   PR:    worktree = .claude/worktrees/pr-N* │ elsewhere
  │    Q3 Level       medium* │ low │ high
  │    Q4 Extras      (multi) deep │ pre-existing │ start fresh [only if a ledger exists]
  │    → refuse deep+low here
  │
  ├─ (no ask) diff · intent brief shown · ledger loaded · peer discovery (peer-dispatch §1–§2)
  │
  ├─ ASK B  "What to review, and by whom"           (L3; split in two calls when customs exist)
  │    Q1 Categories  (multi) general │ security │ design │ adherence
  │    Q2 More areas  (multi) performance │ tests │ UI/UX │ deployment
  │       [customs → extra category tabs in call B1; Q3+Q4 then ride together in call B2]
  │    Q3 Who reviews  Subagents* │ Peer agents │ Main agent (me) │ Advisor
  │    Q4 Model (subagents)  Default (session) │ Opus │ Sonnet │ Fable
  │       question text names the peers' own models: "peers keep their own — rev-1: opus"
  │
  ├─ ASK C  path follow-up — only the path chosen in Q3 (≤ 4 questions, one call)
  │    Subagents ──► C-S
  │    Peer agents ─► C-P
  │    Main / Advisor ─► no ASK C (adherence-basis, if needed, is asked alone)
  │
  ├─ STOP checkpoint · review · verify · (deep passes)
  │
  ├─ L5 present  →  ASK D  how to work the list  (L6/G6)  →  nit batch ask  →  per-issue
  └─ L8/G7 commit-push or publish ask  →  Review stats
```

`*` marks the default option.

## ASK B, Q3 — "Who reviews?" (identity only)

| Option | Shown as | Notes |
|---|---|---|
| **Subagents** | `Subagents — plugin reviewers on a model you pick` | The recommended default. Shape and pacing come in C-S. |
| **Peer agents** | when live: `Peer agents — 2 live here: rev-1 · reviewer · opus · idle; rev-2 · …`. When none are live: `Peer agents — none live in this repo` | Always visible. Picking it with no live peer gives a one-line "none live, start one or pick another", and Q3 alone is re-asked. |
| **Main agent (me)** | `Main agent — I review it myself` | |
| **Advisor** | `Advisor — one independent pass` | |

Peers come from peer-dispatch discovery: P1 roster peers, P2 teammates, P3 pane agents.
Busy peers, and peers not rooted in this repo, are named as unavailable and not counted
as live.

## ASK B, Q4 — "Model for subagents"

The options are unchanged: **Default (model I'm using)**, Opus, Sonnet, Fable. Only the
question text changes. It says the model applies to **subagents**, and that **peers keep
their own model**, naming each live peer's model from `roster.mjs show` →
`members[].model`, or `own model (unknown)` for a P2 or P3 peer with no recorded model.

When Q3 ≠ Subagents, give a one-line note that Q4 does not apply. The tab is never
dropped.

**Advisor consultation directive:**
- Subagents: the existing tier rule, from Q4.
- Peers: `advisor: none` (peer-dispatch §7).
- Main agent: the tier rule as today.

## ASK C-S — Subagents follow-up

| Q | Question | Options | Asked when |
|---|---|---|---|
| 1 | **Shape** | One per category* (fan-out; strongest) │ One agent, all categories (cheaper; one reasoner) | 2+ categories. The recommended option follows the diff-size rule, with the high-stakes override stated. |
| 2 | **Pacing** | 6 at a time, rolling* │ all N at once │ one at a time | 2+ categories. N includes shards. If Q1 picks "one agent", a one-line note says pacing doesn't apply. |
| 3 | **Adherence basis** | infer from codebase* │ I'll state the rules | Adherence selected and no directives found (today's L3.1 ask, folded in here) |

When only 1 category is selected, the dispatch is announced and there is no ASK C-S
unless Q3 is needed.

## ASK C-P — Peer agents follow-up

| Q | Question | Options | Asked when |
|---|---|---|---|
| 1 | **Which peers** (multi) | up to 4 live candidates: `name · role · model · idle`, ordered by role fit; more are reachable via Other | 2+ live peers. With exactly 1, it is announced and selected. |
| 2 | **Split** | One peer holds every lens* │ Split categories across the chosen peers | 2+ peers chosen and 2+ categories |
| 3 | **Adherence basis** | as in C-S | as in C-S |

**Split across peers.** Categories are assigned round-robin in the order of Q1 and Q2,
most role-fit peer first. Each peer gets its own request file and brief, carrying only
its categories' checklists, plus the METHOD and DISPATCH EXTRAS, and returns its own
roll-call. The collision check and slug run per peer: `critic-<branch>-<peer>`.

**One peer, every lens.** This is today's peer path.

**Models.** Peers always run their own model. The plan line names them:
`2 peers: rev-1 (opus) — general, security, design; rev-2 (sonnet) — adherence,
performance, tests`. Review stats record each peer's model. Coverage, verification
(L4.6, on the Q4 model, or self-verified when Q3 ≠ Subagents) and deep passes apply to
peer returns as they do to subagent returns.

## Ask budget per path (worst case, before L5)

| Path | Calls |
|---|---|
| Subagents | A, B (or B1 + B2 with customs), C-S |
| Peer agents | A, B (or B1 + B2), C-P |
| Main / Advisor | A, B (or B1 + B2), plus the adherence basis only if needed |

That is one call more than today on the subagent path, because today's separate L3.0
and L3.1 asks become a single C-S. For a single category with directives present, the
call count is unchanged.

## Decisions
1. A peer with no recorded model is labelled `own model (unknown)`. It is still offered
   and can take part in a split.
2. A peer that goes busy or silent mid-review is never reassigned automatically. The run
   stops and asks whether its categories go to the remaining peers, to subagents on the
   Tab 4 model, or to the orchestrator.
