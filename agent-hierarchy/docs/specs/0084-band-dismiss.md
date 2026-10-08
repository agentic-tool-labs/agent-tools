# 0084: `[ Dismiss ]` band button — confirm modal, then disband the viewer's own team

Implementer: implementor
Reviewer: reviewer

Status: r2, buildable. Changes since r1 are marked **r2**: the user's ruling, the "Dismiss anyway" step, the roster path, the default-team spelling, and the build-time probes. · Target: ah 0.122.0 (minor: new user-visible action) · Base: branch `ah/0083-pane-own-teams` (0.121.0, tip 5a81364; worktree `.claude/worktrees/0083`). Stack on it.

> **r2 — Build order.** First run the §10 probes (P1-P3). P1 can STOP the build; P2 and P3 only decide what the docs say. Then build §3.

## 1. Goal

The band gets a second button, `[ Dismiss ]`, to the right of `[ Pane ]`. Pressing it:

1. Opens an engine modal (`$.ui.ask`) naming the team, how many sessions will close, and which members are **busy** or have **open dispatches**.
2. If the user confirms, disbands that team through the existing `roster.mjs disband` two-call contract (plan, then close).
3. Reports the outcome in a toast.

User request: "add a 'Dismiss' team button next to the Pane button … dismiss the team with a pop-up modal."

## 2. Today (branch `ah/0083-pane-own-teams`; paths relative to `agent-hierarchy/`)

- **Band** is drawn in `mod/register.tsx:142-179` (`on('ui.render', {component:'AbovePrompt'})`).
  - The `[ Pane ]` Button (`key="ah-pane"`) appears when `bodyColumns >= PANE_BUTTON.minColumns` (40).
  - `PANE_BUTTON = {label:'Pane', width:8, gap:1, minColumns:40}` is at `mod/view.ts:367`.
- **Ownership:** `scope(doc, sessionId)` (`mod/view.ts:97-102`) handles three cases:
  - A doc with no `owners` key passes through whole (legacy, pool-wide).
  - Otherwise it returns only the teams of the owner entry whose `sessions` include the viewer.
  - No match returns null.
  - `current()` returns null for member sessions. So a non-null `view` with an `owners`-bearing doc holds **only the viewer's own teams**.
- **The only exec site** is the pinned helper `focusMember` (`mod/register.tsx:14-26`):
  - It validates the name, runs `$.process.run(['herdr','agent','focus',name],{timeoutMs:5000})`, and toasts on any failure.
  - `tests/test-mod-readonly.sh` pins its text whole as a heredoc (:51-63), cuts it out before lexing, and allows exactly one call site: a `plain` Pane Button onPress (:365-395).
  - `process.run` and `ui.ask` are **not** in `ALLOWED_CALLS` (:32).
- **`roster.mjs disband`** (`hooks/roster.mjs:5980-6110`; contract in `skills/agent-team/SKILL.md:725-812`):
  - Flags: `plan`, `close`, `confirm`, `plan-token`, `team`, `cwd`, `allow-global`, `kill` (ignored). Output is always JSON. `fail()` exits 2 with `roster.mjs: <msg>` on stderr.
  - **Plan (no `--close`)** is read-only. It outputs `{close[], close_token, next, expected, strays, not_closable, team_files, warnings, sources, resync?}`, or `{disbanded:false, reason}`.
  - **`--close --confirm --plan-token <t>`**: `gateClose` (:4593) exits 2 if `--confirm` or `--plan-token` is missing, or if the token is stale.
    - It closes each pane member (`herdr pane close` / `tmux kill-pane`, no shell), first re-checking whether the pane has been reused.
    - It polls up to 3 s to verify each pane is gone.
    - It prunes the closed rows. When none are kept it unlinks the team file (which refreshes status.json).
    - Output adds `closed, results[], pruned, kept, team_removed, still_live?`.
    - Exit is 0 even when `closed:false`.
  - **Teardown scope:** `disband` touches **no worktrees, branches, open requests or messages**. It closes panes and prunes the team file only. Members with no pane (`not_closable`, e.g. `peer`-route sessions) are listed and not closed.
  - It refuses **neither** busy members **nor** open dispatches.
  - Team resolution (`resolveTeamFileScope`, :1496-1525): an explicit `--team` wins. Otherwise it uses the CLAUDE_PID-owned live teams, failing on two or more. With none owned it uses `defaultTeamScope`.
  - The harness puts a PreToolUse prompt on every `disband --close` Bash call (SKILL.md:764). A mod `process.run` is expected **not** to pass through that gate (§10 E3).
- **Engine APIs** (types file `plugin-authoring/types/claude-code.d.ts`):
  - `ui.ask(question, string[] | {options?, header?, multiSelect?})` → `Promise<string>` (:2346, :612-628).
    - It takes 2-4 labels and adds an "Other" free-text choice.
    - It resolves to the chosen label or to the typed text, and **rejects** when the dialog is dismissed and in `-p` runs.
  - `process.run(argv, {cwd?, env?, stdin?, timeoutMs?})` → `{exitCode, stdout, stderr, …}` (:3413, :7667, :7694).
    - It **rejects** if the command cannot start or is still running at the timeout.
    - The child inherits the host process env.

## 3. Design

### 3.1 When the button shows

`[ Dismiss ]` is drawn in the AbovePrompt band, right of `[ Pane ]`, only when **all** of these hold:

- The band is drawn at all (`bandLine` non-null, `hasSurvey` false), as today.
- The held view came from a doc that **has** an `owners` key (ownership proven), and it lists ≥1 team. A legacy, pool-wide doc never shows Dismiss: there is no proof the viewer owns anything.
  - The view must carry this fact, because today a legacy view and an owned view are indistinguishable. `mod/view.ts` adds a boolean on `View` meaning "teams are the viewer's own, by `owners`". The name is the Implementor's choice; it is declared in `mod/types/index.d.ts`.
- `bodyColumns` is wide enough for text, both buttons and both gaps. Dismiss gets its own width constant beside `PANE_BUTTON` in `view.ts`: label `Dismiss`, width 11, gap 1. Its min columns = `PANE_BUTTON.minColumns + 12` = 52.
  - Below 52 the band shows `[ Pane ]` alone, exactly as today.
  - The band text budget passed to `bandLine` subtracts both buttons when both are drawn.

Member sessions get a null view, so no band and no button (unchanged).

### 3.2 Which team

- **One owned team:** go straight to the confirm modal for it.
- **2-3 owned teams:** first `ui.ask("Dismiss which team?", {header:'Dismiss', options:['Cancel', <team names…>]})`.
  - `Cancel` is first.
  - Any answer that is not exactly one of the team labels (Cancel, Other text, rejection) → stop, no exec, no toast.
  - Then the confirm modal runs for the chosen team. One team per press.
- **≥4 owned teams:** `ui.ask` cannot show Cancel plus 4 or more labels. Toast `Too many teams to choose here; use the agent-team skill to disband.` with no exec.
- **Team names:** take them from `View.teams[].name`. The default team appears as `default` (`readTeams`, view.ts:170).
- **r2 — How the default team is addressed.** `disband` spells the default team `--team @default` (`DEFAULT_TEAM_ARG`, `hooks/lib-roster.mjs:1216`; `roster.mjs:1420-1425`). `--team default` addresses a team literally named `default`. So each `View.teams[]` entry must carry whether it is the null-keyed default team: a field set in `view.ts` from the raw `team` key, with the name left to the Implementor.
  - The argv team is `@default` exactly when the key is null. Otherwise it is the name, validated per §3.7.
  - The displayed name is never used to decide this.
  - Labels: the picker and the confirm use the displayed name. If two owned teams would show the same label (the null team plus a real team named `default`), the null team is labelled `@default` in both dialogs.

### 3.3 The plan call (exec 1)

Run `disband` **plan** for the chosen team, with an explicit `--team` and `--cwd` = `$.session.cwd()`. Use argv with no shell and a timeout of 15 s.

| Plan result | Behaviour |
|---|---|
| Exit ≠ 0, reject, timeout, unparseable stdout, or `close_token` missing | Toast `Could not dismiss <team>: <reason>`, no modal. Reason = first stderr line with `roster.mjs: ` stripped, else `plan failed`. Control characters stripped, cut to 120 chars. |
| `{disbanded:false, reason}` | Toast `Nothing to dismiss: <reason>`. |
| **r3** Plan has a `source` key (a team-less plan carries `source:"peers"`), or `team_files` is not a non-empty array | Toast `Could not dismiss <team>: no team file`. No modal, no close exec. |
| A valid plan | Go to §3.4. |

The plan is read-only, so running it before the modal is safe. It provides the close count and the `warnings`, `strays` and `not_closable` lists, which SKILL.md:787 requires the user to see before confirming.

### 3.4 The confirm modal

`ui.ask(question, {header:'Dismiss', options:['Cancel', 'Dismiss <team>']})`. **`Cancel` is the first option.**

The question is built from the plan and from the held view's team model, in this order, as plain sentences ending in `?`:

1. `Dismiss team <team>? This closes <len(close)> member session(s): <names>.`
2. **Busy (required):** `BUSY now: <names whose activity is working>.` Or, when there are none, `No member is busy.`
3. `Blocked: <names>.` (only when non-empty).
4. **Open dispatches (required):** `Open dispatches: <n> (<member> <state>, …).` "Open" means the dispatch's current state is `working`, `overdue`, `stalled` or `blocked`; `reported` and `expired` are excluded. When there are none, `No open dispatches.`
5. When busy or open > 0: `Their in-flight work will be lost.`
6. Plan `warnings` (each), `strays` (names), and `not_closable` (`Not closed (no pane): <names>.`), when present.
7. Closing line: `Worktrees, branches and messages are left as they are.`

Data requirement: each `View.teams[]` entry gains a per-team summary from `mod/view.ts` (pure, no `$`): member count, busy names, blocked names, and open dispatches as member + state. Busy, blocked and open are computed from the same parsed member `activity` and dispatch `state` the Pane rows use. The confirm text must never disagree with the Pane.

Data is read from the held state `view` at press time (≤2 s old). If that team has left the view by the time of the press → stop silently.

**Only** the exact answer `Dismiss <team>` proceeds. Cancel, Other free text, or a rejection (Esc or no UI) → nothing runs and no toast is shown.

**r2 — "Dismiss anyway" (the user's decision).** When the team has ≥1 busy member **or** ≥1 open dispatch, a **second** `ui.ask` follows a `Dismiss <team>` answer, before any close:

- Options: `['Cancel', 'Dismiss anyway']`, with `Cancel` first. Header `Dismiss`.
- Question, ending in `?`: `<team> has work in flight: <busy names> busy; <n> open dispatch(es). Close it anyway and lose that work?`
  - Name the busy members; omit the busy clause when there are none.
  - Give the dispatch count; omit that clause when it is 0.
- Only the exact answer `Dismiss anyway` proceeds. Every other answer, and a rejection, cancels: no close exec, no toast.
- Busy and open are judged from the same press-time snapshot as the first modal. The view is not re-read between the two dialogs.

When nobody is busy and nothing is open, there is one modal only.

### 3.5 The close call (exec 2)

`disband --close --confirm --plan-token <close_token> --team <team> --cwd <cwd>`, with argv only and a 30 s timeout. This is the same command the plan's `next` names. The mod builds the argv itself from validated parts and never execs `next` verbatim.

| Result | Toast |
|---|---|
| Exit 0, `closed:true`, `still_live` absent or empty | `Dismissed <team>.` |
| Exit 0, `closed:false` or `still_live` non-empty | `<team>: not all sessions closed (<still_live or kept names>).` |
| Exit 2 with a stale-token message | `<team> changed since the check; press Dismiss again.` |
| Any other non-zero exit, reject, timeout, or unparseable output | `Could not dismiss <team>: <reason>` (as §3.3) |

Outcome toasts use the engine's default duration, whatever `toast_seconds` says: the pinned helper passes no duration. When `toast_seconds` is 0 they **still show**. They are the only report of a destructive action, so turning off ah status toasts must not hide them. `focusMember`'s failure toast already ignores `toastFor`.

After success, nothing else is done: `disband` refreshes status.json, and the next 2 s tick drops the band.

### 3.6 Re-entrancy

A press while a dismiss is in flight (modal open or exec running) does nothing. A new state key in `PluginState.ah` (types file) holds the flag. It is set at the start and cleared in a `finally`. It lives in memory only; a reload clears it.

### 3.7 Validation (trust boundary)

status.json is pool-wide and writable by any session, so every value that reaches argv is validated in the helper:

- **Team name:** the same name rule `roster.mjs` uses for team names (`validateTeamAlias`, `roster.mjs:1427`; Implementor: reuse that rule's pattern verbatim; cite where it lives in the guard comment). Anything else → toast `Could not dismiss that team.`, with no exec.
  - **r2:** the literal `@default` is allowed only when it was produced from a null team key (§3.2).
- **Plan token:** must match the shape `closeToken` produces (16 lowercase hex characters). It is checked twice: in `readPlan` (`view.ts`), and again inside the pinned helper just before the dialogs, so the pinned text alone guarantees what follows `--plan-token`. Otherwise treat it as a failed plan.
- **cwd:** `$.session.cwd()`. It must be absolute; otherwise there is no exec.
- **r2 — The roster script path:** `$.plugin.root` + `/hooks/roster.mjs`. `plugin.root` is the plugin's absolute directory, the one holding `.claude-plugin/` (types `claude-code.d.ts:2236-2245`).
  - It is never taken from status.json or any pool file.
  - If the root is not an absolute string → toast `Could not dismiss <team>: plugin path unavailable`, with no exec.
  - Read it the way the types file declares it (property or call). In either form it is the `$` access `plugin.root`.
- The executable is `node`, resolved by PATH, as `herdr` already is.

### 3.8 Where the code goes, and the guard

- **`mod/register.tsx`:** add one new pinned async helper, beside `focusMember`, owning §3.2-§3.7 (both `ui.ask` calls and both `process.run` calls). The band hook draws the Dismiss Button, `key="ah-dismiss"`, whose onPress only calls that helper with `$`.
- **`mod/view.ts`:** the width constant, the ownership boolean on `View`, the per-team summary, and a pure question builder. The builder takes a team summary plus the parsed plan fields and returns the question string, so §3.4 is unit-testable without `$`. `view.ts` still holds no `$`.
- **`tests/test-mod-readonly.sh`** (**r2:** under the user's ruling, §7):
  - Add `ui.ask` and `plugin.root` to `ALLOWED_CALLS`. If the guard allows either only inside the pinned helper, that is acceptable and stricter.
  - Pin the new helper's whole text as a second heredoc, with the same exact-once and cut-out rules as `focusMember`. Add its `NET_EXTRA_CALL` line.
  - Allow exactly one call site: a non-`plain` Button with `key="ah-dismiss"`, in the **AbovePrompt** hook only, whose onPress is `() => <helper>($)` (optionally `async` or `try{}catch{}`).
  - `focusMember`'s rules are unchanged: still exactly one Pane call site, and no calls from the band.
  - The word `process` stays banned outside the two pinned helpers.
  - Update the header (:10-13) to name both exec sites and to say, in plain words, that the user approved the dismiss site, with one confirm dialog, plus a second when work is in flight, standing in for the chat confirmation and the harness prompt. A third site or any argv change still needs a new ruling.

## 4. Invariants and negative cases

**Must NOT change:**

- `disband` itself: no new flag, no new teardown path, no change to plan/close semantics or the harness `--close` gate for Bash calls.
- The SKILL.md two-call contract for the Orchestrator.
- `[ Pane ]` behaviour, label, key, and its 40-column rule.
- `focusMember` text and its guard rules.
- Band text and tone, toasts, Pane rows.
- 0083 owners scoping.
- `view.ts` holds no `$`.

The rule "show Dismiss when the viewer owns a live team" is also met by, or near to, these inputs:

| Input | Expected |
|---|---|
| Member session (in `member_sessions`) | No band, no Dismiss (view null) |
| Legacy doc (no `owners`), team live | Band + `[ Pane ]`, **no** Dismiss |
| `owners` present, viewer in no entry | No band (0083), no Dismiss |
| `owners` present, viewer owns team A; team B (foreign) in the doc | Dismiss offers A only; B is never a choice, never in argv |
| Owned view, `bodyColumns` 40-51 | `[ Pane ]` only |
| Owned view, `bodyColumns` ≥ 52 | `[ Pane ]` + `[ Dismiss ]` |
| `hasSurvey` | Band passes through, no buttons (unchanged) |
| Pipeline-only (no team) visible entry | No Dismiss (zero teams) |
| Confirm answered `Cancel` / Other text / dialog rejected | No close exec, no toast |
| **r2** Busy member or open dispatch, confirm `Dismiss <team>`, then `Cancel` / Other / reject on the second dialog | No close exec, no toast |
| **r2** Busy member or open dispatch, confirm, then `Dismiss anyway` | Close exec runs |
| **r2** Nobody busy, no open dispatch (idle members, or only `reported`/`expired` dispatches), confirm | Close exec runs after **one** dialog; no second dialog |
| **r2** Only `blocked` members (none working), no open dispatch | One dialog (blocked is not busy); the `Blocked:` line is in the question |
| **r2** Default (null-key) team owned | argv `--team @default` |
| **r2** Real team named `default` owned | argv `--team default` |
| **r2** Both owned | Picker labels `@default` and `default`; each maps to its own argv |
| **r2** `plugin.root` missing or not absolute | Toast, no exec |
| Team picker answered `Cancel` / Other / rejected | No exec at all |
| Team name fails the validation pattern | No exec; toast `Could not dismiss that team.` |
| Plan exit 2 / timeout / reject / bad JSON / bad token shape | Toast with reason; no modal; no close exec |
| **r3** Plan with `source:"peers"` (the team file is gone, so `disband` planned over the pool's live peers) | Toast `Could not dismiss <team>: no team file`; no `ui.ask`; no close exec |
| Plan `{disbanded:false}` | Toast `Nothing to dismiss: …`; no modal |
| Close stale token | Toast "changed since the check" |
| Close exit 0 but `closed:false` / `still_live` | Toast naming what's left; never "Dismissed" |
| Second press while the first is in flight | Ignored |
| ≥4 owned teams | Toast pointing to the skill; no exec |
| `toast_seconds: 0` | Outcome toasts still show (engine default duration); status toasts still off |

## 5. Tests

`mod/tests/view.test.ts`:

- **Ownership boolean:** true for a doc with `owners` where the viewer matches; false for a legacy doc; view null for no match or for a member session.
- **Per-team summary:** busy, blocked and open-dispatch derivation, including `reported`/`expired` excluded and `stalled`/`overdue` included. A foreign team's members never appear.
- **Question builder:** both the busy and the no-busy wording; open dispatches present and absent; warnings, strays and not_closable lines; the in-flight sentence only when busy or open > 0.
- **Width:** at 51 columns there is no Dismiss; at 52 Dismiss shows; the band text budget subtracts both buttons.

`mod/tests/register.test.ts`, via the `stage()` fakes:

- Add a `ui.ask` fake to the world: scripted answers, or a reject, with recorded `{question, options}`. Reuse the per-test `process.run` fake pattern of `focusPane()` (:865-875), with scripted results per call.
- **Cancel does nothing:** press Dismiss, answer `Cancel`. Exactly one `process.run` (the plan) and zero close calls. No toast.
- Same for an Other free-text answer, and for an `ask` reject.
- **Options order:** `options[0] === 'Cancel'` for both the picker and the confirm.
- **Confirm path:** two `process.run` calls. The close argv contains `--close --confirm --plan-token <token from plan> --team <team> --cwd <cwd>`. Toast `Dismissed <team>.`
- **Busy in the question:** the fixture has one member `working` and one dispatch `overdue`. The question contains `BUSY now: <name>` and the dispatch.
- **r2 — Dismiss anyway:**
  - With the busy fixture, two `ui.ask` calls; the second has `options[0] === 'Cancel'` and `'Dismiss anyway'`. A `Cancel`, Other or reject on the second → zero close calls.
  - With an idle fixture → exactly one `ui.ask` before the close.
  - With a dispatch-only fixture (open dispatch, nobody working) → two dialogs.
- **r2 — Default team:** a doc whose owned team has key null → plan and close argv carry `--team @default`. A named `default` team → `--team default`. Both owned → picker labels `@default` and `default`.
- **r2 — Roster path:** the argv's script path equals the faked `plugin.root` + `/hooks/roster.mjs`. A non-absolute root → no exec plus a toast.
- **Foreign team never dismissable:** the doc has `owners` with the viewer owning A and B owned by another session. The picker and confirm never mention B, and no argv contains B. With the viewer owning none, there is no band and no Dismiss button.
- **Member session:** no Dismiss button (button count).
- **Legacy doc:** `[ Pane ]` present, Dismiss absent.
- **Process failure → toast:** a table over the plan and the close, covering exit 2 with stderr, a reject, a timeout reject, non-JSON stdout, and `closed:false`. Each produces its §3.3/§3.5 toast. Mirror the `FAILS` table at :914-919.
- **Re-entrancy:** a second press while the `ask` promise is pending → no second `ask`.
- **Validation:** a team named with shell metacharacters, an underscore, a dot, a leading dash, or more than 32 characters in a crafted doc → no exec, and the validation toast. (Capital letters are valid: `isTeamAliasShape` allows them.)

`tests/test-mod-readonly.sh`:

- Negative fixtures: a second `process.run` outside both helpers fails. Each of the following fails too:
  - calling the dismiss helper from the Pane hook;
  - a Dismiss Button whose onPress does anything but call the helper;
  - an edited helper text;
  - `ui.ask` used outside the helper.
- Every existing guard case still passes.

Prove that the new register tests can fail: run them against the base `register.tsx` (no button). They must fail, and the report must say so.

Run the mod suite, `tests/test-mod-readonly.sh`, and `tests/test-mod-fixtures-drift.sh`.

## 6. Version and docs

- `agent-hierarchy/.claude-plugin/plugin.json` and the root `.claude-plugin/marketplace.json` (agent-hierarchy entry) → `0.122.0`.
- `CHANGELOG.md`, `## [0.122.0]`, Added: the band's `[ Dismiss ]` button; a confirm modal naming busy members and open dispatches; it runs the same `disband` plan/close; results come as toasts.
- `README.md` band section: one paragraph on `[ Dismiss ]`, covering the following, and add the 52-column rule beside the 40-column `[ Pane ]` rule:
  - when it shows (own teams, wide enough);
  - what the modal says;
  - that it closes member panes only and leaves worktrees, branches and messages alone;
  - that peer-route members are not closed;
  - **r2:** the second "Dismiss anyway" dialog when work is in flight, and the P2/P3 observations (§10.1).

  **r2:** the CHANGELOG line also names the "Dismiss anyway" step.
- `skills/agent-team/SKILL.md` § disband: one sentence saying the band button is a user-driven path to the same plan/close, with its own modal. The Orchestrator's two-call contract is unchanged.
- Docs stay generic, with no ticket or customer references. If any size cap bites, raise the cap and do not cut contract text (no current test caps README or SKILL.md).

## 7. Decisions made

- **r2 — User's decision: one pop-up is enough.** The user ruled that the mod may run `disband` itself. The Dismiss dialog, a human-only modal (rejects in `-p` runs, cannot be answered by the model), stands in for both the chat confirmation and the harness prompt that guard the Orchestrator's own `disband --close`. The Orchestrator's path keeps both of its layers unchanged.
- **r2 — User's decision: "Dismiss anyway".** When any member is busy or any dispatch is open, a second dialog must be confirmed. Losing in-flight work takes two deliberate answers; an idle team takes one.
- **r2 — Explicit `--team` always, including `@default`, plus `--cwd`.** The child process never needs `CLAUDE_PID` to resolve the team (P1 checks that nothing else in `disband` does).
- **r3 — `CLAUDE_PID` in `disband` (P1, ruled).** With an explicit `--team`, `disband` reads `CLAUDE_PID` only at `hooks/roster.mjs:4679`, for a legacy second copy of the team file in the pool dir (`teardownTeam`). Without it that copy is left out of the close set with a plan warning: the close set only narrows. Accepted; `roster.mjs` is unchanged.
- **Reuse `disband` verbatim (plan → close with token)** and do not add a new teardown path. The plan supplies the close set, warnings and strays the modal must show, and the token keeps "what the user saw" equal to "what gets closed".
- **The busy and open-dispatch data comes from the mod's own parsed view**, the same source as the Pane rows, rather than from new plan output. `disband` stays unchanged, and the modal matches what the Pane shows.
- **Dismiss is offered only on an `owners`-proven view.** The legacy pool-wide doc cannot prove ownership, and dismissing a foreign team is the one failure that must not happen.
- **The team is always passed explicitly with `--team`.** The mod never relies on `CLAUDE_PID` in the child env (unverified, §10), and an implicit resolution could pick a different team than the one shown.
- **Cancel is first in both dialogs. Every non-exact answer cancels**, and so does a rejection.
- **Outcome toasts ignore `toast_seconds: 0`.** Reporting a destructive action is not a status nicety.
- **One team per press**, at most 3 in the picker; beyond that the user is sent to the skill.

## 8. Open questions (user's call; defaults chosen)

- **Q1:** At 40-51 columns there is no Dismiss button, because Pane takes priority. Acceptable? Default: yes.
- **Q2 (r2, answered):** the user chose the "Dismiss anyway" second dialog (§3.4).
- **Q3:** Should Dismiss also be reachable from the Pane (e.g. a per-team row button)? Default: band only, as requested. **r2:** default confirmed.
- **Q1 (r2):** default confirmed.

## 9. Escalation

**r2:** none outstanding. The user ruled R1 (§7: one pop-up is enough). The prompt-submit alternative is dropped; `$.prompt.submit` is not used.

## 10. r1 evidence questions (answered; kept for the record)

**r2** answers, from the evidence response of 2026-10-07 (types file and repo reading):

- **E1:** `$.plugin.root` (§3.7).
- **E2:** `--team @default` (§3.2).
- **E4:** `$.prompt.submit` exists but is unused.
- **E3, E5, and the child env:** answered from the types file only, never observed running. They become the P2, P3 and P1 build probes below.

### 10.1 r2 — Build probes (first step, before code)

- **P1 — STOP-or-proceed: does `disband` need `CLAUDE_PID` when `--team` is explicit?**
  - Method: trace `hooks/roster.mjs` `disband` (plan and `--close`) and everything it calls (`resolveTeamFileScope`, close-set building including the pool-copy team "when owned or orphaned", `gateClose`, `closeToken`, `reconcileAfterClose`). Look for any read of `CLAUDE_PID`, `CLAUDE_CODE_SESSION_ID`, `ownedLiveTeams`, or `teamOwnedBy` reachable with `--team <name>` and with `--team @default`.
  - None → proceed.
  - Some, but the only effect is an informational field → proceed, and name it in the report.
  - Some, and it changes the close set, the token, or refusal → **STOP** and report the path. Do not work around it: the mod cannot read `CLAUDE_PID`, because `$.env.get` is not allowed, and passing an env value is a design change.
  - Optional live check, if a live session is available: a throwaway mod in a sandbox `CLAUDE_CONFIG_DIR` runs `$.process.run(['env'])`. Record whether `CLAUDE_PID` is present. This is informational only.
- **P2 — Does a mod `process.run` fire PreToolUse?** Expected: no (it is its own event, not `tool.call`). Observe it live if possible; otherwise record "unobserved".
  - **The design is valid either way.** If it does fire, the user also sees the harness's existing `disband --close` permission prompt after the Dismiss dialog(s). That is an extra layer and acceptable: no code change.
  - Document whichever was observed in the README paragraph. If unobserved, say nothing about it there.
  - Not acceptable: a gate that **denies** the mod's call outright with no prompt. The close then fails and a "Could not dismiss" toast shows. Report this and do not work around it.
- **P3 — `ui.ask` from a band onPress, idle versus busy.** Observe it live if possible.
  - Proceed in every case:
    - It shows while busy → nothing to note.
    - It waits for the turn to end, then shows → acceptable. The re-entrancy flag holds until then, so further presses are ignored.
    - It rejects while busy → that is a cancel. README: "Dismiss works when the session is idle."
  - STOP only if it never resolves even while idle.
  - Note: `ui.ask` passes through other plugins' `tool.call` (AskUserQuestion) hooks. A denial there rejects the call, which is a cancel. That is correct and needs no handling.

### 10.2 r1 questions (superseded; answers above)

- **E1: roster path.** How can mod code obtain the absolute path of its own plugin's `hooks/roster.mjs` without reading a pool file? Candidates:
  - a `$` API for the plugin root (search the types file for `plugin`, `root`, `dir`);
  - `import.meta.url` inside a mod file: is it allowed by the guard's lexer, and is it defined at runtime?
  - a path relative to the mod file, if the engine resolves one.

  Each result decides a different design:
  - a `$` API → it needs adding to `ALLOWED_CALLS` (part of R1);
  - `import.meta` → a guard carve-out;
  - **none** → the exec design cannot locate the CLI safely, and the r1 prompt-submit alternative (since dropped) becomes the design.
- **E2: default team.** How does `disband` address the default team (team key null, shown as `default`) explicitly? Does `--team default` work, or is there another spelling?
  - If there is none, Dismiss is offered for the default team only when it is the viewer's sole owned team, and `--team` is omitted for it. In that case `CLAUDE_PID` resolution matters (see next).
  - Also report whether a `$.process.run` child has `CLAUDE_PID` and `CLAUDE_CODE_SESSION_ID` set. Probe: a throwaway mod in a sandbox HOME that runs `['env']`, or the engine docs.
- **E3: hook gate.** Does a `$.process.run` child fire PreToolUse hooks? Expected: no. This decides whether R1 is "replacing the harness prompt" (no) or "adding a modal before it" (yes; then R1 is moot).
- **E4: prompt submission.** Does the mod API have any call to submit or queue a user prompt into the session? Search the types file. This is needed only for the r1 prompt-submit alternative (since dropped).
- **E5: ui.ask from a band onPress.** Does `$.ui.ask` resolve when called from an AbovePrompt Button onPress while the session is idle, and while it is busy? Use the `claude-code/testing` harness if it models this; otherwise a sandboxed live probe.

Probes must be sandbox-safe: variables assigned in-script, `T=$(mktemp -d)` checked non-empty, and no write outside `$T` and the session scratchpad.
