# 0067 — Sub-orchestrators

Status: backlog
Implementer: implementor
Reviewer: reviewer

**Backlog means:** designed, not scheduled. No Implementor is dispatched on
it until the user moves it to `Status: ready`. The backlog convention is
proposed in §12. Before it's promoted, the Ultra-Advisor should review
§5–§8 (§13).

Depends on: spec 0066 (several teams per session), the stream verbs in
roster.mjs, and either §6's single pool or spec 0065's fix.

## 1. What this is for

A managing orchestrator (the **MO**) splits a large piece of work into
workstreams. It hands each one to a **sub-orchestrator** (an **SO**). Each
SO:
- runs as its own session, in its own git worktree;
- builds and runs its own sub-team (architect, implementor, reviewer, …);
- sends status and its result back up to the MO.

The workstreams run in parallel. The user talks to the MO.

## 2. What exists today (verified by reading)

- **Streams** exist in code only; no spec describes them.
  - `stream-open <name>` (roster.mjs:6160-6214) creates a worktree at
    `<main checkout>/.claude/worktrees/<name>` on branch `<name>` off `main`.
  - Under herdr it also opens a tab.
  - It records `streams.<name>` (`state`, `branch`, `base`, `worktree`,
    `tab_id`, `opened`) in the owning team's file.
  - Members join a stream through `spawn-one`/`spawn-ad-hoc --stream <name>`
    (roster.mjs:71-75, `streamAnchor` :4668-4708).
  - `stream-status` shows each stream's peers and open exchanges.
  - `stream-done` only marks it done. It closes no pane and removes no
    worktree.
- **An orchestrator can't be a subagent.** The route gate denies an
  Agent/Task dispatch of `ah:orchestrator` (pretooluse-route-gate.mjs:218,
  :107). So an SO must be a peer session.
- **"orchestrator" is a reserved name**, not a role row or a class
  (lib-config.mjs:468, :1185). The classes are advise, design, review,
  implement and legwork (lib-config.mjs:170-192). Teams are flat: nothing
  records a parent team or a depth.
- **Messages.** msg.mjs files carry `id, type, to, from, slug, parent, reason,
  eta, to_name, from_name, team, team_file, team_guide, created`.
  - `parent` is only for display.
  - `eta` (small, medium, large) is only a label: no liveness check reads
    it.
  - A peer brief (`[hierarchy-peer-brief reply-to=…]`) creates an obligation
    to reply. stop-peer-nudge.mjs blocks Stop at most `MAX_NUDGES` = 2 times,
    then waives it (lib-peer.mjs:48).
- **Pools.** `hierarchyDir(cwd)` is the enclosing checkout's
  `.claude/hierarchy/`, so a linked worktree has its own.
  `AGENT_HIERARCHY_DIR` overrides it and folds every pool into one
  (lib-config.mjs:691-712).
  - Spec 0065: a response written beside its request in another checkout's
    pool is rejected by `validateResponseToken` (lib-hier.mjs:580-595). A
    worktree peer answering a request from the main checkout hits this.
- **Ownership.** `adopt --orchestrator-pid` restamps a team's owner, and
  refuses when a different live owner holds the team.
- **The tier rule** (lib-config.mjs:170-192, pretooluse-route-gate.mjs:192-196)
  denies dispatching a role at or below the session's tier. The exception is
  a request whose `reason` is `context`, `second-opinion` or `parallel`.

## 3. Goals and non-goals

**Goals**
- The MO opens a workstream in one step. That gives it a stream, an SO, and
  a brief.
- Each SO owns its own sub-team, in the stream's worktree.
- Status is always readable from files, so it survives the MO compacting or
  restarting.
- Results arrive as a response file, and the obligation isn't waived while
  the work runs.
- A dead SO or a dead MO leaves work that can be recovered, and nothing is
  killed without asking the user.

**Non-goals**
- Sub-orchestrators more than one level deep (§10 Q1).
- Automatic merging: an SO delivers a branch, and a person merges.
- Sharing one worktree between workstreams.
- Replacing `/ah:pipeline`.

## 4. The sub-orchestrator role

- **A new class, `orchestrate`,** with one built-in role, `sub-orchestrator`,
  in the roles registry (lib-config.mjs `CLASSES` / `BUILTIN_ROWS`):
  - `agent: ah:orchestrator`. It reuses the Orchestrator agent file, with no
    second copy of its text. What makes the session a sub-orchestrator is the
    injected block in §4.1, not a different agent;
  - peer only. The route gate still denies it as a subagent;
  - not a chain step, so the tier rule doesn't apply to it (§8);
  - it owes a response: the workstream result;
  - model: `inherit`, the MO's model, by default (§10 Q6).
- **`sub-orchestrator` is refused as a custom role name,** like
  `orchestrator`.

### 4.1 What an SO session is told

When a session's own team file records a `parent` (§5.2), SessionStart and
compact inject one extra block. That block is empty for every other session,
so their text stays byte-identical. It says:
- which workstream this is, and the path of its brief;
- who it reports to (the MO's member name and address);
- the duties:
  - status by the §6 rules;
  - the result as a response to the brief;
  - user questions and Ultra-Advisor needs go up to the MO (§7);
  - no sub-orchestrators of its own (§7);
  - no merge and no push unless the brief allows it.

## 5. Spawn and ownership

### 5.1 How a workstream opens

The steps, all driven by the new `/ah:workstream` skill (§9) over existing
verbs:
1. `stream-open <ws>` in the MO's team: the worktree, the branch, and the
   herdr tab.
2. `spawn-one sub-orchestrator --stream <ws> --member <mo-team>-so-<ws>`:
   the SO's pane opens in the stream's tab, with its cwd in the worktree.
   Evidence step E2 confirms the cwd.
3. The MO writes the brief. It is a request to the SO with `reason:
   parallel`, `eta`, and a `workstream: <ws>` field (§6.1). The MO sends it
   with SendMessage.
4. The SO builds its sub-team with `/ah:agent-team` create:
   - `--team <ws>`, with the roster the brief names, or the selected
     roster;
   - `--stream <ws>`, so its members join the same worktree and tab;
   - `--parent <mo-team>`, so the new team file records its parent.

   `create` gains `--stream` and `--parent`, which are now only on
   `spawn-one`.

### 5.2 Records

- **The child team file** (the SO's team) gains a `parent` record:
  `{team, member, hierarchy_dir, stream}`.
  - `team` is the MO's team, and `member` is the SO's name in it.
  - Its `orchestrator` record is the SO's own pid and session.
- **The MO's stream record** (`streams.<ws>`) gains `sub_orchestrator` (the
  member name), `child_team` and `brief` (path). Only the MO writes these.
- **The workstream status file,** `<pool>/streams/<ws>.json`, holds `state`,
  `summary`, `heartbeat` and `result` (§6).
  - It has one writer: the SO. The MO writes it only while recovering from
    a dead SO (§9).
  - So several SOs never write the MO's team file at the same time, and no
    status update is lost to a concurrent read-modify-write.
  - Writes are atomic (a temp file, then a rename).
- **Each side points at the other,** so either can recover the tree alone
  (§8).
- **Depth.** `create --parent` is refused when the parent team itself has a
  `parent`. `spawn-one sub-orchestrator` is refused in a session whose own
  team has a `parent`.
- **Breadth.** `spawn-one sub-orchestrator` is refused when the MO's team
  already has `maxSubOrchestrators` live ones. That is a roster-level
  scalar, default 3 (§10 Q2).

### 5.3 How it fits spec 0066

- The MO may own several teams (0066). Each workstream belongs to the one
  MO team whose stream it is.
- A child team is owned by its SO, not by the MO. So 0066's owned-team rules
  never count child teams as the MO's.
- An SO owns exactly one team, its child team. `create` from an SO session
  is refused for a second team.
- `roster.mjs teams` shows each team's `parent`, so the tree is visible from
  either side.

## 6. Relay protocol

### 6.1 Brief

The brief is a request file. `workstream: <ws>` is a new frontmatter field,
written only when set, so other messages stay byte-identical. It holds:
- the goal;
- the scope, including the files or areas the SO must not touch;
- the branch;
- the acceptance criteria;
- the roster to use;
- whether it may push or open a draft PR (default: neither);
- the `eta`.

### 6.2 Status

- **The durable status lives in the workstream status file** (§5.2). The SO
  updates it with one new verb, `stream-report <ws> --state
  working|blocked|review|done --summary "<one line>"`:
  - it writes `state`, `summary` and `heartbeat` (now);
  - only the SO named in the MO's stream record may run it. Any other
    session is refused, except the MO during recovery;
  - `summary` is one line of at most 160 characters, with no backticks;
  - it is ungated.
- **A heartbeat is stamped at every SO Stop** by the existing Stop hook
  path, so a working SO stays fresh without spending tokens.
- **Change notices.** On a change of `state`, the SO also sends the MO one
  compact SendMessage, whose first line is `[workstream <ws> <state>]
  <summary>`. It doesn't send one on every heartbeat.
- **Quiet, overdue and dead.** `stream-status` shows each workstream's
  state, summary, heartbeat age, and pid liveness. "Quiet" is judged against
  its `eta` (small 30 min, medium 2 h, large 6 h), and "dead" means the pid
  is gone. These are labels only: nothing acts on them by itself (§10 Q8).

### 6.3 Result

- **The result is the SO's response to the brief.** It is written beside the
  brief, in the same pool (§6.4). It carries the tldr, the branch and head
  commit, the test evidence, what was left out, and open questions. Then:
  - `stream-report <ws> --state done`;
  - a SendMessage with `[hierarchy-msg <path>]`.
- **The obligation.**
  - A brief with a `workstream` field isn't nudged at Stop while its status
    file is `working`, `blocked` or `review`, and its heartbeat is fresh by
    the `eta` rule.
  - It is nudged when the SO marks the stream `done` without having sent the
    response, and whenever the heartbeat has gone stale.
  - stop-peer-nudge.mjs reads the status file to decide.
- **If the SendMessage fails** (the MO is gone), the SO still writes the
  response, records its path in `result`, and stops. The next MO finds it
  (§8).

### 6.4 One pool for the whole tree

- **Every session in a tree uses the MO's hierarchy dir:** the SO and its
  sub-team's members.
- The SO's pane is launched with `AGENT_HIERARCHY_DIR` set to it, and every
  spawn from inside the tree passes it on.
- So the team files and messages of the whole tree live in one place, and
  spec 0065's cross-pool rejection can't arise inside a tree.
- Code still runs in the worktree. Repo-level config still resolves from
  the worktree's git root, which falls back to the main checkout's files
  (`rosterLevelCandidates`).
- Evidence step E1 confirms that every ah path honours the variable.
- Spec 0065 should still land, for ordinary streams.

## 7. Escalation and caps

- **The user talks to the MO.** An SO doesn't use AskUserQuestion.
  - For a decision that needs the user, it sends the MO a request (`reason:
    context`, slug `ws-<ws>-question`) and sets its stream state to
    `blocked`.
  - The MO asks the user and answers.
  - Default per §10 Q3.
- **The Ultra-Advisor.** In an SO session, the ultra gate denies the
  dispatch and says to escalate to the MO as NEEDS-ULTRA-ADVISOR. The MO
  asks the user and dispatches.
- **Depth 1, breadth `maxSubOrchestrators`** (§5.2).
- **Inside a sub-team,** every existing rule applies unchanged: review-loop
  caps, the route gate, the pipeline's rules if the SO runs one.
- **Merging.** An SO never merges. It pushes or opens a draft PR only when
  the brief allows it.
- **Permission mode.** The SO's member `autoMode` governs its pane. Its
  sub-team members use their own rows.

## 8. The tier rule

- **MO to SO:** a brief carries `reason: parallel`, so the tier rule passes
  it, whatever the two models are. Delegating a workstream is parallel work,
  not the MO handing off reasoning it should do itself.
- **Inside a sub-team,** the tier rule applies against the SO's own model,
  as for any orchestrator.
- **An SO on a lower tier than its Architect** is allowed, as it is for the
  Orchestrator today.

## 9. Failure modes

- **The SO dies** (its pid is gone, or its heartbeat is stale and the pane
  is closed):
  - `stream-status` shows it as dead.
  - The MO tells the user and asks with AskUserQuestion:
    - respawn an SO into the same stream. It adopts the child team (`adopt
      --orchestrator-pid`), and reads the brief, its stream record and open
      exchanges;
    - have the MO adopt the child team and finish the workstream itself;
    - wind down. Each child member is dismissed through the two-phase
      `dismiss`.
  - No member is killed without that answer (CLAUDE.md: never stop
    in-flight work without asking).
- **The MO compacts.** Nothing is lost: the stream records and message files
  hold the state. SessionStart's compact re-injection lists each workstream:
  name, state, summary, heartbeat age, and the result path when done.
- **The MO dies.**
  - SOs keep working. Their change notices fail, and the next state is still
    written to the record.
  - A new MO session in the main checkout adopts the MO's team with the
    existing adopt. It then sends each live SO a one-line
    `[workstream <ws> reattach]` giving its new address.
  - Results already written are in `result`.
- **An SO compacts.** Its brief path and its parent come back in the §4.1
  block, and its team file holds the rest.
- **Two workstreams touch the same files.** The brief's scope is the only
  guard. Merging is a person's job, so conflicts surface at merge time.
- **The worktree is removed under a live SO.** `stream-status` reports it.
  The SO's own commands fail, and it reports `blocked`.

## 10. Open questions for the user (defaults in parentheses)

- **Q1** Depth: one level of SOs (default), or allow an SO to have SOs.
- **Q2** At most 3 live SOs per MO team (default), or another number.
- **Q3** User questions: every question goes through the MO (default), or an
  SO may ask in its own pane.
- **Q4** What an SO delivers: a local branch, not pushed (default); or a
  pushed branch; or a draft PR. The brief can override it per workstream.
- **Q5** Pools: one pool for the tree (default), or a pool per worktree once
  0065 lands.
- **Q6** SO model: the MO's model (default), or a roster setting.
- **Q7** A dead SO: always ask the user (default); nothing automatic.
- **Q8** Quiet, overdue and dead are labels only (default), or they send the
  MO a notice.

## 11. Evidence steps (when promoted)

- **E1** With `AGENT_HIERARCHY_DIR` set in a sandbox:
  - audit every ah path that resolves a pool or a team file, and list any
    that ignore the variable;
  - have a worktree member write a response beside a request, and see it
    accepted by the send and Stop hooks.
  - **Any gap:** back to the Architect.
- **E2** Does `spawn-one --stream` start the pane with its cwd in the
  worktree, and in the stream's herdr tab? If not, §5.1 step 2 needs a
  `--cwd` rule.
- **E3** A SendMessage from a pane in the worktree to the MO's session is
  delivered, and a failed one is reported to the sender.
- **E4** Measure how much the MO's context grows per workstream over a
  two-workstream run, with change notices only. The breadth default (Q2)
  depends on it.

## 12. Proposed backlog convention (docs/spec-process.md)

Add one short paragraph to docs/spec-process.md:
- A spec whose header has `Status: backlog` is designed and not scheduled.
- Don't dispatch an Implementor on it.
- It moves to `Status: ready` only when the user says so. At that point the
  spec is re-checked against the code that moved in the meantime, and its
  evidence steps run first.

Today Status lines are free text, and "backlog" appears in no spec.
Everything else stays free text. That doc edit is a separate small change,
for docs-writer or the Implementor when routed.

## 13. Files (when promoted)

- `agent-hierarchy/hooks/lib-config.mjs`: the `orchestrate` class and the
  `sub-orchestrator` built-in; the reserved name; `maxSubOrchestrators`.
- `agent-hierarchy/hooks/roster.mjs`:
  - `create --stream/--parent`;
  - the `parent` and stream-record fields;
  - the depth, breadth and one-team refusals;
  - `stream-report`;
  - `stream-status` columns;
  - `AGENT_HIERARCHY_DIR` passed on at spawn;
  - `teams` shows `parent`.
- `agent-hierarchy/hooks/msg.mjs` and `lib-hier.mjs`: the `workstream` field.
- `agent-hierarchy/hooks/stop-peer-nudge.mjs`: the workstream obligation
  rule (§6.3).
- The Stop hook that stamps the heartbeat, and SessionStart: the §4.1 block
  and the compact workstream list.
- `agent-hierarchy/hooks/pretooluse-ultra-gate.mjs`: the escalate-up deny in
  SO sessions.
- New `agent-hierarchy/skills/workstream/SKILL.md` (`/ah:workstream open |
  status | close | recover`) over the verbs above. It is a new skill, not a
  section of agent-team, which is already long.
- `agent-hierarchy/docs/custom-roles.md`, `docs/cli-tools.md`, and a stream
  contract section in `docs/team-file.md`. Streams have no spec today, and
  this builds on them.
- Tests: a new `tests/test-sub-orchestrators.sh` under the mutation
  standard. It covers the depth, breadth and one-team refusals, the records
  on both sides, the `stream-report` writes, the obligation rule (fresh,
  stale, done without a response), the ultra-gate deny, byte-identical
  injection for non-SO sessions, and the recovery adopt.

## 14. Decisions, confidence, escalation

- **An SO is a peer running the existing Orchestrator agent,** plus an
  injected block. There is no second agent file, and the route gate's
  subagent deny stays.
- **Status lives in a status file per workstream, with one writer.** Change
  notices are extra, so compaction and restarts lose nothing, and parallel
  SOs never race on the MO's team file.
- **One pool per tree,** not a fix per crossing.
- **The obligation follows the workstream record,** not the 2-nudge Stop
  rule, which would waive a long workstream within minutes.
- **Confidence:** medium. The design is coherent, but it adds concurrency
  (parallel sessions writing one pool and one stream record) and a recovery
  protocol.
- **Escalation:** before it's promoted from backlog, dispatch the
  Ultra-Advisor with: "Sub-orchestrators (0067 §5–§9): is the single-pool,
  record-based status and obligation design sound under concurrent writes,
  MO or SO death, and compaction? What breaks?"
