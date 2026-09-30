# 0065 — Response pointers are valid beside their request

Status: ready for implementation
Plugin: agent-hierarchy (ah) 0.105.0 → 0.105.1
Stream worktree: /Users/jimcline/git/repos/agent-tools/.claude/worktrees/fix-msg-pointer-cwd (branch `fix-msg-pointer-cwd`). Commit there. Do not push.

Implementer: implementor
Reviewer: reviewer

All paths below are relative to the plugin root `agent-hierarchy/` unless absolute.

## 1. Symptom

A peer role session (e.g. an Architect) runs with its cwd in the main checkout. Its Orchestrator runs in a linked worktree `.claude/worktrees/<name>`. The Orchestrator's request lands in the **worktree's** pool. As spec 0037 and the brief direct, the peer writes its response **beside the request** (`msg.mjs new --req <request path>`).

- **Send hook.** `pretooluse-sendmessage-response.mjs` denies every `SendMessage` carrying `[hierarchy-msg <that response path>]` with the reason "file is outside this session's message pool … the file is fine and the cwd is wrong".
- **Stop hook.** `stop-peer-nudge.mjs` blocks the finish until a `SendMessage` carrying exactly that pointer goes out. `owedLine` embeds `responsePlan(rec.msg).path`, which is beside the request. It nudges twice, then waives and logs the task as undelivered.

So the only report the peer is told to send is one the send hook refuses. The reports go out as plain text, and the obligations are recorded as undelivered.

## 2. Root cause

Two rules disagree about where a response lives:

| Rule | Where the response lives | Code |
|---|---|---|
| Placement (spec 0037) | `dirname(request path)` | `lib-hier.mjs` `createMessage` (`:344` `targetMsgs = opts.reqPath ? dirname(opts.reqPath) : msgsDir(dir)`); `responsePlan` (`:375-392`) |
| Validation | `msgsDir(hierarchyDir(responder cwd))`, OR the pool of the message's `team_file` home | `lib-hier.mjs:585` inside `validateResponseToken`, via `isUnder` (`:543`) and `messageHome` (`:212-217`) |

The two rules agree only when:

- the request sits in the responder's cwd pool, or
- the request's frontmatter carries an existing absolute `team_file` whose home pool holds the request.

`team_file` is often null: `teamFileFor` (`lib-hier.mjs:200-204`) returns null when no team file exists at `teamPath(<sender's hierarchy dir>, team)`. That happens, for example, for a team stood up in the main checkout whose Orchestrator writes from a stream worktree. The request that dispatched this very spec has `team: fix-msg-ptr` and `team_file: null`. So `messageHome` is not a dependable escape.

The validator was never taught the 0037 invariant, "a reply lands beside its request". The fix is there, not in pool resolution.

The same gap strands responses from all four hierarchyDir divergence vectors, not just worktree vs main checkout:

- worktree vs main checkout;
- `cd` drift;
- non-repo cwd falling back to `~/.claude/hierarchy/<basename>`;
- `AGENT_HIERARCHY_DIR` set in one session only.

Anchoring on the request closes all four for responses.

### Rejected alternatives

- **Unify `hierarchyDir` / `findGitRoot` across worktrees.** Spec 0027 §2 rules against it, and the 0037 Ultra-Advisor ruling re-affirmed that. It merges id sequences and pools and has a large blast radius.
- **Copy the request or response into the responder's pool.** This fakes message state.
- **Drop the location check for responses entirely.** This would accept a response file anywhere with the right id and from. The request-anchored rule is just as simple and keeps a response findable in the requester's own pool, which is the point of 0037.
- **Replace the existing acceptance (cwd pool, team home) with beside-request only.** This is cleaner, but it breaks back-compat for anyone whose response sits in their own pool. That can only happen by bypassing `msg.mjs`, but the brief requires back-compat, so the new rule is additive.

## 3. Requirements

### R1 — `validateResponseToken` accepts a response that sits beside the request it answers

File: `hooks/lib-hier.mjs`, `validateResponseToken` (`:580-595`).

- The function takes one additional **optional** input: the absolute path of the request the response is meant to answer. Existing callers that omit it must behave exactly as today.
- The location check passes when **any** of these holds:
  1. the file is under `msgsDir(dir)`, as today;
  2. `messageHome(path, fm)` is non-null, as today;
  3. **new:** a request path was supplied, it is absolute, it ends `--request.md`, it exists, and the response file's directory is the same directory as the request's.
- The directory comparison in (3) is done on symlink-resolved paths. Reuse `realCwd` (`lib-hier.mjs:760`, realpath with raw-path fallback). Do not write a new realpath helper. The reason: on macOS `/tmp` and `/var/folders` are symlinks, and mixing an aliased path with a real one must not deny.
- (3) widens **location only**. Every other check still applies, in the same order:
  - suffix `--response.md`;
  - `fm.type === "response"`;
  - `fm.from === expectedFrom`;
  - `fm.id === expectedId`.
- Do not change the existing `isUnder` resolve-only semantics for clauses (1) and (2).

### R2 — The location-failure reason names the request's directory when one was supplied

- **No request path supplied:** the `why` text is unchanged. It is the current `outsidePool(dir)` text, which is still correct for requests.
- **Request path supplied, and all three clauses fail:** the `why` must say both of these, in plain words:
  - the file is not in its request's directory, naming that directory;
  - the remedy is to write the response with `msg.mjs new --type response … --req <request path>`, which places it beside the request.

  It must **not** say "the cwd is wrong". Moving cwd is not the remedy for a response.
- Exact wording is the Implementor's call.

### R3 — The send hook passes the request each obligation came from

File: `hooks/pretooluse-sendmessage-response.mjs`.

- **Per-record loop.** In the loop over `qualifying` records (`:142-153`), each `validateResponseToken` call supplies that record's request path (`rec.msg`) as the new input.
- **Fallback reason.** The re-check at `:155-157` reports why a present token failed. It must validate against the qualifying record whose request id equals the id in the token's filename (`parseMsgFilename(token)`), and fall back to the oldest record when none matches. Today it always uses the oldest. With two open requests, a response to the newer one that fails on location would be misreported as "wrong id".
- **Unchanged:**
  - the present-but-invalid-token path still denies on every attempt, with no one-round allowance;
  - echo-cap behaviour;
  - the missing-token nudge;
  - gate records;
  - fail-open on error.

### R4 — Neither validator reads a file whose name disqualifies it

Files: `hooks/lib-hier.mjs`, `validateRequestToken` (`:558-570`) and `validateResponseToken`.

- Today both functions call `readMsgFile(path)` on any existing absolute path before checking the filename suffix. A pointer at `/dev/zero`, a FIFO, or a large unrelated file therefore makes the hook read it.
- Move the suffix check (`--request.md` / `--response.md`) ahead of the read in both functions, so a wrongly named file is never opened.
- Resulting reason change: a wrongly named file outside the pool now reports "not a request file" or "not a response file" rather than the pool reason. That is acceptable.
- Nothing else about `validateRequestToken` changes. In particular, it gets no beside-request clause: a request has no request to sit beside, and the cwd-drift deny for requests is a deliberate ruling.

### R5 — Version bump

`0.105.0` → `0.105.1` in both of these, together:

- `agent-hierarchy/.claude-plugin/plugin.json`
- the agent-hierarchy entry in `/Users/jimcline/git/repos/agent-tools/.claude-plugin/marketplace.json`

If `main` has moved past 0.105.x when this lands (the named-rosters stream is concurrent), take the next patch above `main`'s version. The Orchestrator owns resolving that at merge.

## 4. Must NOT change

- **Pool resolution:** `hierarchyDir`, `findGitRoot`, `mainHierarchyDir`, `checkoutRoot` (`lib-config.mjs`).
- **Response placement:** `createMessage` `--req` placement and `responsePlan`.
- **Anything that keys off the request path:**
  - `stop-peer-nudge.mjs`, including its text, which already points at the beside-request path;
  - `posttooluse-peer-resolve.mjs` and `hasResponseToken`, which already have no pool check and resolve correctly once the send goes through;
  - `userpromptsubmit-peer-tracking.mjs` and `extractPendingRecord`;
  - `subagentstop-msg-nudge.mjs`.
- **Other hooks:** `pretooluse-msg-gate.mjs` and `pretooluse-route-gate.mjs` behaviour.
- **Files owned by the concurrent named-rosters stream:** `roster.mjs`, `lib-config.mjs`, `lib-roster.mjs`. Do not edit them.
- **Plain-text reports:** a `SendMessage` without a pointer still does not satisfy a report obligation. That is by design (spec 0028/0031), not part of this bug.

## 5. Edge cases

| Case | Expected |
|---|---|
| Request and response both in the responder's cwd pool (the normal same-checkout case) | Allowed, as today. |
| Request in the worktree pool, `team_file` null, responder cwd in the main checkout, response beside the request | **Allowed** (was denied). This is the bug. |
| Request in the worktree pool, `team_file` pointing at a team file whose home pool does not hold the request | Allowed by R1(3) (was denied). |
| Request in the main pool, responder cwd in a worktree | Allowed by R1(3). |
| Response in a directory that is neither its request's directory, the cwd pool, nor the team home | Denied. The reason names the request's directory (R2). |
| Response beside its request but `fm.id` is a different request's id | Denied, "wrong id", as today. |
| Pointer at the request file itself, beside itself | Denied, "not a response file". |
| Request path and response path spelled through different symlink aliases of the same directory | Allowed (realpath comparison). |
| Pending record's `msg` is not absolute, is missing, or does not end `--request.md` | Clause (3) does not apply. Behaviour is exactly as today. |
| `AGENT_HIERARCHY_DIR` set | Unchanged. All pools collapse to one, so clause (1) already holds. |
| Pointer at `/dev/zero`, a FIFO, or a non-`.md` file | Denied on name without being opened (R4). |
| Two open requests, response to the newer one fails on location | Reason reports location against the newer request, not "wrong id" (R3). |

### Security

- **Clause (3) creates no new write location.** It widens acceptance only to the one directory `msg.mjs new --req` already writes into.
- **The anchor is trusted only as far as today's arming.** It is the request path from this session's own pending record, keyed by `session_id`. That record is armed only by an inbound cross-session brief whose first line is an existing `--request.md` pointer, which is the same trust boundary spec 0031/0037 already accept.
- **Nothing file-derived is echoed before location passes.** A deny reason echoes frontmatter fields only once the location check has passed, and never echoes file bodies.
- **Hooks stop reading arbitrary files.** With R4, a hook never opens a file whose name is not a message file, so the pointer check can no longer be used to make a hook read an arbitrary path.

## 6. Verification

The tests are bash scripts in `tests/`. Model them on `tests/test-sendmessage-response-nudge.sh` for the payload and role-attribution helpers, and on `tests/test-msg-worktree-team.sh` for creating a real `git worktree add` with `HOME="$FAKEHOME"`.

**`AGENT_HIERARCHY_DIR` must be unset in T1–T3.** With it set, all pools coincide and the bug cannot reproduce.

Sandbox rules:

- every sandbox is `mktemp -d`, checked non-empty;
- every git write uses `git -C "$T/…"`.

**New file: `tests/test-response-pointer-beside-request.sh`**

- **T1 — Repro, end to end.** Uses a real main checkout plus a linked worktree.
  1. The request is created with `msg.mjs new --type request … --cwd <worktree>` and no team, so `team_file: null`.
  2. Arm the peer through the real `userpromptsubmit-peer-tracking.mjs`, with a cross-session-wrapped prompt whose first line is `[hierarchy-msg <request path>]`, session S, cwd = the main checkout.
  3. The response is created with `msg.mjs new --type response … --req <request path> --cwd <main checkout>` and given an authored body.
  4. Then assert, in order:
     - (a) every `PreToolUse` hook that `hooks/hooks.json` chains on `SendMessage`, run in its listed order, allows a `SendMessage` from S, as a directly attributed `architect`, carrying `[hierarchy-msg <response path>]` plus one status line;
     - (b) `posttooluse-peer-resolve.mjs` then records the obligation resolved;
     - (c) `stop-peer-nudge.mjs` for S does not block.
- **T2 — Negative location.** Response file placed in a third directory, not beside its request and outside the cwd pool. Assert that the send hook denies and that the reason names the request's directory.
- **T3 — Symlink alias.** Same as T1 step 4(a), but the request path the peer was armed with and the response pointer reach the pool directory through different aliases (one realpath'd, one not). Assert allowed.
- **T4 — Wrong id beside the request.** Assert denied with "wrong id".
- **T5 — Suffix before read.** A pointer at an existing non-message file (e.g. a regular `.txt` in the sandbox) is denied as "not a response file". Where practical, a FIFO named `x.txt` does not hang the hook: run it under `timeout`.

**It must be shown that the new tests can fail.** Before applying the lib or hook change, run T1 and T2 against the unmodified hooks. Record in the Implementor report that:

- T1(a) fails with the "outside this session's message pool" deny;
- T2's reason assertion fails.

Then apply the fix and show them passing.

**Regression suites, which must stay green:**

- `tests/test-sendmessage-response-nudge.sh`
- `tests/test-msg-gate.sh` (its outside-pool case at `:72-74` must still deny)
- `tests/test-msg-worktree-team.sh`
- `tests/test-msg-reply-beside-request.sh`
- `tests/test-msg-response.sh`
- `tests/test-peer-reportback.sh`
- `tests/test-report-back-completion.sh`

After those, run the full `tests/test-*.sh` loop, with output captured to a log file and failures grepped. There is no package.json or runner script: each script exits 0 iff all of its checks pass.

If any `PreToolUse` hook other than `pretooluse-sendmessage-response.mjs` denies in T1(a) after the fix (e.g. `pretooluse-route-gate.mjs`), **stop and report it as a spec gap.** Do not patch that hook. §7 A1 assumes it does not deny.

## 7. Assumptions (not verified by execution)

- **A1.** In the T1 scenario, the rest of the `PreToolUse` `SendMessage` chain allows the send:
  - `pretooluse-msg-gate.mjs` skips directly attributed role sessions (`:52-55`);
  - `pretooluse-route-gate.mjs` resolves `to` as the Orchestrator, which is neither chain-eligible nor tier-gated.

  This was read from source, not run. T1(a) verifies it.
- **A2.** The reported real-world trigger was `team_file` null or foreign. This is inferred from `teamFileFor` and `messageHome`. T1 reproduces the null case directly, and the §5 table covers the foreign case by the same clause.
- **A3.** `rec.msg` in pending records is the absolute path exactly as the brief carried it. This follows from `extractPendingRecord`, which stores `extractMsgToken(prompt)` verbatim and requires `existsSync`.

## 8. Out of scope / follow-ups (not decided here)

- Realpath semantics for `isUnder` clauses (1)/(2) when the hook payload `cwd` and the pointer use different symlink aliases. Nothing has been reported. Leave it.
- Whether `msg.mjs new` should write `team_file` for a team whose file lives in the main checkout while the sender is in a worktree. That is on the roster side and would overlap named-rosters. With R1(3) in place, nothing depends on it.
