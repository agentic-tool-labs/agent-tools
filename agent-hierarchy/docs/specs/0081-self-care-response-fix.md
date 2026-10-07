# 0081: self-care response form, last observed brief, registered pid

Implementer: implementor
Reviewer: reviewer

Status: r3 (Reviewer findings addressed; changes marked **r2**/**r3**) · Target: ah 0.119.2 (patch) · Base: main eda89f8 (0.119.1)
Parent: docs/specs/0079-peer-self-care-cli.md and its rulings C1–C8. They still bind: deny by default, the gate never emits "allow", the token class (no `=`, no value starting with `-`), per-verb flag lists, the realpath msgs rule, team-shaping unreachable.

## 1. Goal

A shell-less role (today: architect) must be able to answer its brief with `msg.mjs new --type response` by copying the form it is told to use. Today every place that tells it the form disagrees with the gate, so the only working fallback is hand-writing the response file. Also fix two observability defects found in the same live check:

- `whoami.last_observed_brief` is overwritten by non-brief rows.
- `checkin` and `whoami` never show the session's registered pid.

## 2. Root causes (read from source, not run)

### B1: `msg.mjs new --type response` denied in every form

The gate requires `--from <own role>`, and no text a self-care role sees tells it that.

- `hooks/pretooluse-self-care-gate.mjs:143`: `if (flags.get("type") !== "response" || flags.get("from") !== role || !flags.has("req")) return "";`. A missing `--from` is rejected, and so is `--from orchestrator` from an architect.
- The deny text built at `pretooluse-self-care-gate.mjs:68-76` (`:72`) tells the agent `new --type response --id <id> --req <your request path> [--cwd <cwd>]`. That has no `--from`, so obeying the gate's own instruction is refused by the gate.
- `agents/architect.md:134` and the identical lines in `implementor.md:73`, `reviewer.md:99`, `task-runner.md:68` and `ultra-advisor.md:88` say `--to <role> --from <role>`. The surrounding prose says "`id`/`from` from the request frontmatter". A careful reader fills `--from` with the request's `from`, which is the orchestrator, and is refused. That is exactly what happened live.
- Hook-generated hints wrap MSG_CLI in double quotes. Quotes fail `TOKEN_RE` (`pretooluse-self-care-gate.mjs:40`), so for a self-care role these hints are refused even when they are otherwise right:
  - `pretooluse-sendmessage-response.mjs:94`: quoted, and has `--from ${role}`.
  - `stop-peer-nudge.mjs:96`: quoted, and has no `--from`.
  - `subagentstop-msg-nudge.mjs:139`: quoted, and has `--from`.
  - `lib-config.mjs:3089`, the peer prompt: quoted, and has no `--from`.
- `msg.mjs` itself does not need `--from`. With `--req` it derives `to` and `from` from the request (`lib-hier.mjs:344-345`) and cross-checks any value given (`:337-338`; `:338`: `--from` must equal the request's `to`). Only the gate needs it.

### B2: `last_observed_brief` nulled with no new brief

This is unrelated to B1: the gate never reads peer state (`pretooluse-self-care-gate.mjs:100-113` reads only the roster team and the `--req` file).

- `roster.mjs:4422-4424` `lastBriefRow` takes the latest peers row for the session and excludes only `type` `turn` and `dispatch`.
- `subagent-inflight.mjs:113`/`:122` (via `appendSubagentRecord`, `lib-peer.mjs:292`) append `{type:"subagent", session_id, agent_id, status, ts}` whenever a subagent starts or stops while a brief is pending. The live check dispatched a subagent at about 00:14:57Z. That row became the "brief", and whoami rendered it as `from/from_name/reply_to: null`.
- The same leak exists for `idle-seen` and `watch-consumed` (`userpromptsubmit-peer-tracking.mjs:77`, `:150`), `seen` and `surfaced` (`lib-peer.mjs:276`), `watcher` (`dispatch-watcher.mjs:104`) and `heard` (`:135`).
- Unverified: whether the row was the "started" or the "stopped" row. Either one is fixed by the same change (NEEDS-EVIDENCE N1, optional).

### E2: no way to see the registered pid

- `roster.mjs:7158` stores `pid: myPid` in the checkin record, but checkin's output object (around `:7160-7170`) omits it.
- whoami (`:7202-7218`) prints only the orchestrator's pid.

### B3: gate ordering versus task-gopher

Out of scope. The task-gopher strict checkpoint is another plugin's PreToolUse hook; ordering across plugins is not ours to fix in a patch.

## 3. Changes

### 3.1 One canonical response form (B1)

- **Decision:** keep the gate's requirement that `--from` equals the session's role (L143 unchanged). It is the anti-forgery check and it is cheap. Fix every text so it says the same thing.
  - Rejected alternative: make `--from` optional and have the gate check the request's `to` instead. That widens the gate's trust logic in a patch, for no gain once the texts are right.
- Add **one** exported renderer in `hooks/lib-config.mjs`, beside `MSG_CLI`. It produces the response command line from (id or placeholder, own role, request path or placeholder, optional cwd).
  - Canonical shape: `node <MSG_CLI> new --type response --id <id> --from <role> --req <request path>`, optionally followed by `--cwd <cwd>`.
  - No `--to`. It is derived from the request, and it is one fewer thing to get wrong.
  - MSG_CLI is rendered **unquoted** when it matches the gate's token class, and double-quoted otherwise. In the quoted case a self-care role cannot be served at all, which is today's limitation and is left as is.
  - The token class must come from the one definition the gate uses. Move or export `TOKEN_RE` so the gate and the renderer share it; do not copy it.
- Every one of these must use the renderer, with the role substituted as the actual role string, not `<role>`, wherever the code knows it:
  1. The gate's deny text (`pretooluse-self-care-gate.mjs:72`). The role is known there.
  2. `pretooluse-sendmessage-response.mjs:94`.
  3. `stop-peer-nudge.mjs:96`.
     - **r2:** no role is in scope there today. Resolve it with `resolveHierarchyRole(input).role`, which is the same source the gate uses, so the two cannot disagree. Render `<your role>` when that is null.
  4. `subagentstop-msg-nudge.mjs:139`.
  5. The peer prompt, `lib-config.mjs:3089`. If the role is unknown at that point, render the placeholder `<your role>`.
- The hint in item 2 also tells a shell-less agent to hand-write the file. Keep that sentence.
- Static agent files (`agents/{architect,implementor,reviewer,task-runner,ultra-advisor}.md`, the response-command line and the sentence around it):
  - Rewrite to the canonical shape with placeholders: `--id <id> --from <your role> --req <abs request path> --cwd <abs cwd>`.
  - Replace "`id`/`from` from the request frontmatter" with words that make the sources unambiguous: `--id` is the request's `id`, `--from` is **your own role**, and `--req` is the brief's `[hierarchy-msg]` path.
  - These files cannot import the renderer, so a test pins them (§5 T6).
- `docs/cli-tools.md:118` and `:197`: make the response example and the self-care row match the canonical shape. `:197` already states the rule correctly; only align the example.

### 3.2 `last_observed_brief` (B2)

- Change `lastBriefRow` in `roster.mjs` (or the selection it feeds) so it considers **only rows written as an observed brief**: the pending row appended by `userpromptsubmit-peer-tracking.mjs` (around L113-126).
- Use a positive selection, not a longer exclusion list, so no future typed row can leak in.
- **r2, discriminator decided:** a brief row is a peers row for this session that has **no `type` field**.
  - That covers the original pending row (`userpromptsubmit-peer-tracking.mjs:115-126`). Msg-file briefs and plain wrapped briefs share that one writer, so they have the same shape.
  - It also covers the full copies that `stop-peer-nudge.mjs:139`/`:141` append (`{...rec, ts, status:"pending"|"waived"}`), and **r3:** the `{...rec, status:"resolved"}` copy from `posttooluse-peer-resolve.mjs:53`, whose ts becomes the resolve time. Those are the same brief and must be accepted, so status is **not** part of the selection.
- whoami reports from/from_name/reply_to from the latest such row. Its `ts` is that row's ts, which may be a nudge or waive copy's time; that is accepted and is what the field means from now on.
- Every typed row is excluded: `subagent`, `seen`, `surfaced`, `idle-seen`, `watch-consumed`, `watcher`, `heard`, `turn`, `dispatch`, and any future type.
  - **r2:** `heard` is written only when the sender is one of this session's own dispatch targets (`userpromptsubmit-peer-tracking.mjs:134`), so it is never a brief. The r1 STOP clause is dropped.
- **r2, second caller:** `lastBriefFrom` (`roster.mjs:4427`) feeds orphanDependents `last_brief_from` (`:4448`, `:4455`) and shares the selection.
  - Its expected change is a fix: it will no longer report a `heard` row's `from` (a peer this session dispatched) as the session's last briefer.
  - Both callers must use the same selection, not two copies of it. Add a T4 case for `last_brief_from`.

### 3.3 Registered pid (E2)

**r2: rewritten** (Reviewer F1/F2: `member` can be null, and "checkin record" was undefined).

- **`checkin`** output gains top-level `pid`: the exact value written into the row it appends (`myPid`).
  - It is `number | null`. It is null when `CLAUDE_PID` is unset or not numeric (`Number()` gives NaN, which serializes as null). Do not change how `myPid` is computed.
- **`whoami`** output gains top-level `registered_pid` (`number | null`) in **every** output shape, including `empty()` (`roster.mjs:7199`) and the no-member path. Those are exactly the cases where seeing the pid matters. `member` stays as it is, and may still be null.
- **Selection:** `registered_pid` is the `pid` of the latest roster row with `status:"up"` whose `session_id` equals this session's id.
  - **r3:** "this session's id" is `CLAUDE_CODE_SESSION_ID` **only**. If it is unset or empty, `registered_pid` is `null`.
    - Do **not** reuse whoami's `last_observed_brief` source (`roster.mjs:7193`). That source falls back to `myRow.session_id`, and `myRow` is keyed on pid (`:7189`), which would make this field pid-derived.
  - Rows from **any** writer count: checkin (`:7155`), sessionstart (`sessionstart.mjs:167`) and self-heal (`lib-hier.mjs:988`) all write the same `status:"up"` shape. "Registered up row" is the term from now on.
  - It is **never** matched by pid. whoami's existing `myRow` lookup (`:7189`) keys on `pid === CLAUDE_PID`, so using it would compare the env pid with itself. Do not reuse it for this field.
  - It is `null` when the session id is unknown or there is no matching up row. There is no pid fallback.
- `pid` and `registered_pid` are the contract. Nothing else in either output changes, `orchestrator.pid` included.

### 3.4 Release

- Bump to 0.119.2 in `agent-hierarchy/.claude-plugin/plugin.json` **and** the root `.claude-plugin/marketplace.json`, both together.
- Add a changelog entry if the plugin keeps one.

## 4. Invariants and negative cases

The gate stays deny-by-default and never emits "allow". `TOKEN_RE`, the per-verb flag lists, the `--cwd` rule, `reqOk` and the CLI path equality stay as they are. `msg.mjs`/`lib-hier.mjs` `createMessage` is unchanged.

| Input (self-care architect unless noted) | Expected |
|---|---|
| `node <MSG_CLI> new --type response --id X --from architect --req <real request in pool msgs>` | allowed (was denied at base only by texts; gate behaviour unchanged) |
| same, without `--from` | **denied** (unchanged) |
| same with `--from orchestrator` | **denied** (unchanged) |
| same with `--to orchestrator --from architect` | allowed (unchanged; `--to` stays in the allowlist) |
| same with MSG_CLI double-quoted | denied (unchanged) |
| `--req` outside pool/team-home msgs, or not `*--request.md` | denied (unchanged) |
| `--type request` | denied (unchanged) |
| `ls`, pipes, `=`, other verbs | denied, same deny text apart from the corrected msg form |
| non-self-care role (implementor, shell-ful) running the rendered form | runs; the gate does not apply (unchanged) |
| rendered form when MSG_CLI contains a space | quoted; self-care roles cannot run it (known limit, unchanged) |
| whoami with latest row a real brief | block filled from that brief (unchanged) |
| whoami with brief then `subagent`/`seen`/`surfaced`/`idle-seen`/`watch-consumed`/`watcher`/`heard` rows | block still shows the **brief** |
| **r2:** brief → nudge copy (pending) → waived copy → `subagent` row | the brief's from/from_name/reply_to; ts of the **waived copy** |
| **r2:** orphanDependents `last_brief_from` with a later `heard` row | the brief's `from`, not the heard sender's |
| **r2:** request `to` ≠ own role (e.g. a custom self-care role briefed as its class) | the gate allows the canonical form; msg.mjs rejects it (`lib-hier.mjs:338`) (unchanged; not a regression) |
| whoami with only non-brief rows / only turn+dispatch / other session's rows / no store | `null` (unchanged) |
| checkin output | gains `pid` only (null if `CLAUDE_PID` unset); `checked_in/cwd/expected_root/misplaced/team` unchanged |
| **r2:** whoami, member resolved, up row for this session_id | `registered_pid` = that row's pid |
| **r2:** whoami, `member: null` (no team / `empty()`), up row exists for this session_id | `registered_pid` still = that row's pid |
| **r2:** whoami, no up row for this session_id, or session id unknown | `registered_pid: null`; never filled from `CLAUDE_PID` |
| **r2:** whoami, up row exists only for another session_id with the same pid | `registered_pid: null` |
| **r3:** whoami with `CLAUDE_CODE_SESSION_ID` unset, an up row whose pid = `CLAUDE_PID` | `registered_pid: null` (no pid fallback) |
| whoami `orchestrator.pid` | unchanged (still the team file's orchestrator) |

## 5. Tests

All tests are sandboxed in the existing style: HOME/cwd redirected to `mktemp -d`, checked non-empty. Each **new** negative test must be shown failing on base eda89f8 before the fix (record that in the PR).

- **T1 (B1 regression, real-shaped payload)** in `tests/test-self-care-gate.sh`:
  - Build a PreToolUse Bash payload shaped like a live `claude --agent ah:architect` main session: agent_type architect, real cwd, team roster present, a real `*--request.md` in the pool msgs.
  - Feed a deny-triggering command (`ls`) and take the msg-response form out of the deny text.
  - Substitute `<id>` and `<your request path>`, then feed it back. It must be **allowed**.
  - Fails at base, because the form has no `--from`.
- **T2:** for hint generators 2, 3 and 5 in §3.1, render the hint for a self-care architect main session with a real request, run that exact command string through the gate, and expect it allowed. Fails at base (quotes or missing `--from`).
  - **r2:** generator 4 (`subagentstop-msg-nudge`) is shown only to subagents, which the gate either does not gate or denies outright (gate `:87`, `:118`). For it, T2 is a **shape assertion** instead: MSG_CLI unquoted when it fits the token class, and `--from <role>` present with the real role.
- **T3:** keep or add the denials for a missing `--from` and `--from orchestrator`. These pin the invariant and are not expected to fail at base.
- **T4** in `tests/test-roster-whoami.sh`: a brief row followed by each non-brief row type listed in §4 still yields the brief's from/reply_to/ts. Fails at base for at least `subagent`.
  - **r2:** add the brief → nudge copy → waived copy → subagent case (expect the waived copy's ts).
  - **r2:** add an orphanDependents `last_brief_from` case with a trailing `heard` row.
- **T5 (r2 rewritten):**
  - checkin prints `pid` equal to the pid on the up row it appended.
  - whoami `registered_pid` equals that same value, both with a member resolved and with `member: null`.
  - It is `null` for a store with no up row for this session_id, including one whose only up row has the same pid under another session_id.
  - checkin with `CLAUDE_PID` unset prints `pid: null`.
  - **r3:** the positive cases set `CLAUDE_CODE_SESSION_ID`. Add a case with it unset where an up row matches `CLAUDE_PID`, and expect `registered_pid: null`.
  - Fails at base (fields absent).
- **T6:** for each of the five `agents/*.md` files, the response-command line contains `--from <your role>` and `--req`. No file says to take `from` from the request frontmatter. Fails at base.
- The full plugin suite stays green.

## 6. NEEDS-EVIDENCE (optional, does not block)

- **N1:** in the live pool `.claude/hierarchy/peers.jsonl` (or wherever `readPeerRecords` reads), find this architect session's row (session_id `cea53057-fbe5-46ad-8cc9-c9334bfc46e8`) at ts `2026-10-07T00:14:57.293Z` and report its `type`/`status`.
  - `subagent`: B2 root cause confirmed.
  - Any other type: still covered by §3.2's positive selection; just note it in the PR.

## 7. Decisions made, and the one left to the user

- **Kept `--from` mandatory** in the gate rather than relaxing it.
- **Dropped `--to`** from the canonical form, because `msg.mjs` derives it.
- **Brief rows are the untyped rows** (r2). Nudge and waive copies count as the brief.
- **`registered_pid` is a top-level field**, matched by session id against any writer's up row (r2).
- **B3 is out of scope.**
- **For the user:** none blocking. If they would rather let shell-less roles omit `--from` (the gate checks the request's `to` instead), that is a later minor change, not this patch.

## 8. Risks

- The peer prompt (`lib-config.mjs:3089`) is injected into every peer, so changing its text changes every role's instructions.
  - **r2:** the goldens that embed it are `tests/fixtures/0056-i1/golden/notice-{architect,implementor,reviewer,task-runner,ultra-advisor}.json`. Regenerate them deliberately and review the diff, which should show only the response-form line.
  - No other test asserts the old deny or hint strings.
- A future writer that appends untyped peers rows would be read as a brief. Typed rows are the convention there, so keep it that way.
