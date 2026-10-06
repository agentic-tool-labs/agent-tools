# 0079 — Peers run their own self-care ah commands

Implementer: implementor
Reviewer: reviewer

Version: the next minor above the stack tip, stacked after 0078 Part B. Bump
`agent-hierarchy/.claude-plugin/plugin.json` and the root `.claude-plugin/marketplace.json` together.

Status: r2. One revision folds in:
- the Ultra-Advisor ruling (whbk): **allow with changes C1–C8**; Bash plus a gate; MCP rejected; fail-open accepted;
- the Reviewer's findings (ydju): the `--team` trigger case, the worktree `--req`, never "allow";
- the user rulings: custom roles too; accept the retrieval pause; no team-shaping block for roles that already have a
  shell.

**Generic-text rule (binding).** Nothing written under this spec names a product, service, platform, customer,
ticket or incident.

## 1. Goal (user ruling)

"An architect or any peer agent should be able to run ah tools." The ruled scope is **self-care only**:
- `roster.mjs checkin`, `whoami` and `status`;
- `msg.mjs new --type response` for the agent's own brief, plus read-only listing.

Team-shaping verbs stay orchestrator-only. The ruling covers built-in **and custom** roles that have no shell today.

## 2. What the gate is (r2, C2)

**A role-discipline tripwire, not a security boundary.**
- The architect could already cause execution: Bash-capable subagents and Monitor. It can also Write/Edit the CLIs
  and the gate itself.
- The boundary is the user's permission settings, the same for every role; every command still meets them.
- The gate stops a no-shell role from drifting into general shell use. It does not stop a determined agent.
- It is fail-open by accepted design. If hooks are off, or the gate cannot load, the role is where the reviewer is
  today: it has a shell, and its contract says to use it only for self-care.
- (r2, C6) The role text tells the agent what to do if that happens (§6).

This grant also fixes a real contradiction: `agents/architect.md` already tells the architect to run `msg.mjs new`
and roster verbs with Bash, which its frontmatter forbids.

## 3. Facts (read; main)

- **Role tools:** architect denies `NotebookEdit, Bash, advisor`; reviewer and ultra-advisor have a shell, with
  contracts that limit its use; implementor and orchestrator have everything. Custom roles get the session toolset
  minus their agent file's `disallowedTools`. They are registered in config (`roles.<name>`, with a required
  `class`) via `roster.mjs role set` or a hand edit.
- **Attribution:** `resolveHierarchyRole(input)` (lib-config.mjs:625–647) returns `{role, direct}`.
  - `direct` is true when `agent_type` resolves a role.
  - Otherwise it falls back to the session-keyed role with `direct:false`. Its doc says a policy caller "MUST check
    `direct`".
  - PreToolUse input carries `session_id`, `cwd`, `agent_type?` and `agent_id?` (subagents only).
- **CLIs:** `ROSTER_CLI` and `MSG_CLI` are the absolute paths `cliRootLine()` advertises (lib-config.mjs:116–121).
- **Verbs:**
  - `checkin` acts only on the roster row whose pid is `CLAUDE_PID`, and fails with no row (roster.mjs:7106–7172,
    3411–3413). `--team X` only checks that the team exists.
  - `status` writes the cwd pool's status.json (the CLI also reads `--now` and `--plain`).
  - `msg.mjs new`: `--from` is checked only against the role list. With `--req`, msg.mjs enforces `meta.id === --id`,
    no overwrite, and the to/from/name mirror of the request (msg.mjs:302–359, lib-hier.mjs:334–337). It writes the
    response into `dirname(req)` (l.355–357).
- **Roster rows:** a `down` row carries **no `team`**; `up` rows do (0078 evidence).
- **Bash PreToolUse chain** (hooks.json:38–64): six ah hooks; other plugins also gate Bash.
- **Hook semantics:** a deny blocks; any other failure is non-blocking. An explicit `allow` decision **skips the
  user's permission prompt**.

## 4. Which roles are gated (r2, user ruling: custom roles too)

- **(r3) Built-in roles: a code constant.** One exported set in lib-config.mjs, holding `architect` in r3, names the
  built-in roles that are gated. `lookupRole` returns `resolved: null` for built-ins (lib-config.mjs:613–615), so a
  registry field cannot be read for them. The constant matches the bare role name returned by
  `resolveHierarchyRole`.
- **Custom roles: a role-registry field, `shell: "self-care"`**, read from the role's resolved config entry (the
  same entry `lookupRole` resolves for custom roles).
  - A custom role opts in by setting it: by hand, or with `roster.mjs role set <name> --shell self-care` (a small
    flag on an orchestrator-only verb; any other value is rejected).
- **Why a registry field and not "the agent file lacks Bash":** a role whose agent file denies Bash cannot run any
  command, gate or not. To give it self-care, its file must allow Bash, and then "lacks Bash" can no longer
  identify it. The marker is therefore explicit, and the docs say exactly how to convert a no-shell custom role:
  1. remove `Bash` from its agent file's `disallowedTools`;
  2. set `shell: "self-care"`.
- Only the exact string `"self-care"` counts; any other value, or none, means "not gated".
- **Never gated:** a role of the orchestrator class, even if the field is present (the field is ignored there, and
  `role set` rejects it).
- **Consistency note (docs only):** a role with the marker whose agent file still denies Bash simply has no shell.
  Nothing breaks, and nothing is gated.
- **NEEDS-EVIDENCE E3 (Implementor, read-only; r3: custom roles only):** confirm that the `resolved` value from
  `resolveHierarchyRole`/`lookupRole` exposes the role's config entry (so `shell` is readable). If it does not, name
  the accessor that does. If none exists without new I/O, stop: the Architect amends.

## 5. The gate (new hook; the Implementor names it; registered FIRST under the Bash matcher)

### 5.1 Attribution (r2, C1, was BLOCKING)

- **No `agent_id` (the main thread):** role = the direct role, else the persisted one. A gated role → apply §5.2.
- **`agent_id` present (a subagent):** role = **the direct role only** (never the persisted fallback).
  - A gated role there (for example an architect subagent) → deny every Bash call: `CLAUDE_PID` would be the parent
    session's.
  - **Any other subagent → exit 0 silently.** For example, the architect session's own task-gopher subagents run
    their legwork untouched.
- An ungated role, or no role → exit 0 silently.

### 5.2 The allow-list (all must hold; else deny)

1. `tool_input.command` is a string of 1–1024 characters, with no CR/LF. It has **no leading or trailing
   whitespace**; empty tokens → deny.
2. Split on runs of spaces or tabs, every token matches **`^[A-Za-z0-9._/:@+,-]+$`**. (r2, C3: `=` is removed. Under
   the session's shell, a word starting with `=` can expand to a command path.)
3. `tok[0] === 'node'`, and `tok[1]` is exactly `ROSTER_CLI` or `MSG_CLI`, compared as strings.
4. `tok[2]` is an allowed verb. The rest are `--flag value` pairs:
   - each flag is from that verb's list;
   - no flag repeats;
   - every value is a separate token that **does not begin with `-`** (r2, C3).

| CLI | Verb | Allowed flags | Extra conditions |
|---|---|---|---|
| roster | `checkin` | `--cwd`, `--team` | Never `--orchestrator-pid`. **(r2, Reviewer)** `--team` must equal the `team` of this session's **latest roster row that carries a `team`** (its latest `up`; a `down` has none), looked up by `input.session_id`. If no row carries a team, `--team` is denied (checkin's own attribution applies) |
| roster | `whoami` | `--cwd`, `--team` | `--team` matches `isTeamAliasShape` |
| roster | `status` | `--cwd` | (`--now` and `--plain` are deliberately not allowed) |
| msg | `new` | `--type`, `--id`, `--to`, `--from`, `--req`, `--cwd`, `--to-name`, `--from-name` | `--type response` is required. `--from` must equal the caller's role. **(r2, C4 + Reviewer)** `--req` must exist and end in `--request.md`, and `dirname(realpath(req))` must equal `realpath(<hier>/msgs)` of either **the cwd pool or its team home** (`teamHomeDir`), so a worktree session can answer a brief that lives in the main checkout. msg.mjs then binds the id and the mirror |
| msg | `list`, `index`, `downstream`, `roster` | `--cwd` | read-only; (C8) the Reviewer confirms at build, by reading, that each writes nothing. Any verb that writes leaves the table |

5. `--cwd`, when given, equals `input.cwd` or its realpath.

### 5.3 Outputs (r2, C5)

- The gate emits **only** a deny, or a silent exit 0. **No code path emits `permissionDecision: allow`**, because that
  would skip the user's permission prompt.
- The deny reason is one short line. It lists the allowed forms with **the exact current `ROSTER_CLI`/`MSG_CLI`
  paths**, so a session holding a stale plugin path can correct itself. It never echoes the command.
- **Stated ceilings:**
  - a plugin root or cwd containing a space (or any character outside the class) makes self-care unavailable, and the
    deny reason says so;
  - another plugin's hook that rewrites the command after this gate runs is out of scope (same user trust).
- Internal errors: the body is one try/catch, and any throw → deny. A load failure fails open (accepted, §2).

### 5.4 Interplay

- The other ah Bash hooks and the other plugins' gates run after this one. The gate never widens them.
- The retrieval plugin's first-command pause also hits self-care commands, and a re-run passes. **User ruling:
  accepted.**

## 6. Role text (minimal)

- `agents/architect.md`:
  - remove `Bash` from `disallowedTools`;
  - add one sentence to the "never execute" bullet: "Exception: self-care ah commands (`roster.mjs
    checkin`/`whoami`/`status`; `msg.mjs new --type response` for your own brief; `msg.mjs list`/`index`) you run
    directly with Bash. A hook refuses everything else. **If any other command is not refused, the gate is down: do
    not use the shell, and report it.**" (C6)
  - As a subagent, the contract is unchanged: no shell use.
- `agents/reviewer.md`: one clause: "self-care ah commands you run yourself; everything else you delegate".
- `buildRoleSessionNotice()`: the "no Bash? write the file yourself" fallback becomes "run `msg.mjs new --type
  response` yourself".
- `docs/cli-tools.md`: a "Self-care (any peer)" list (the §5.2 table). The custom-roles doc gets the two-step
  conversion (§4) and the `--shell self-care` flag.

## 7. Must NOT change

- Every ungated role's Bash behaviour, including roles that already have a shell: there is **no team-shaping block**
  (user ruling).
- The six existing ah Bash hooks. `roster.mjs` and `msg.mjs` behaviour, except `role set` gaining `--shell`.
- The architect's other denials (`NotebookEdit`, `advisor`).

## 8. Tests (new `tests/test-self-care-gate.sh`; hook driven with crafted inputs; nothing executes the CLIs)

**ALLOW (the hook exits 0, with no output), for a gated role, main thread:**

| Input | Test |
|---|---|
| `checkin --cwd <cwd>`, with and without `agent_type` in the payload (C1, C7) | A1 |
| `checkin --team <team of latest up>` when the latest row is a teamless `down` (the Reviewer's trigger case) | A2 |
| `whoami`; `status --cwd <cwd>` | A3 |
| `msg new --type response … --req <main hier>/msgs/x--request.md` from a **worktree** cwd | A4 |
| `msg list --cwd <cwd>` | A5 |
| the same as A1 for a **custom** role with `shell: "self-care"` | A6 |
| (r3) `msg new --type response … --req <msgs>/../msgs/x--request.md`, and a symlink whose realpath is in a msgs dir | A7 |

**DENY, gated role, main thread (each its own case):**
- D1 other commands: `ls`, `npm test`, `node -e 1`.
- D2 chaining or substitution: `;`, `&&`, `|`, `>`, `$( )`, a backtick, a newline.
- D3 quotes, `~`, a glob, any `=` (`--to-name =node`, `--cwd=x`), and a value starting with `-` (`--id -h`).
- D4 a prefix: env, `exec`, `command`, `env`.
- D5 the CLI path: wrong, relative, `..`, a trailing `/`, another version.
- D6 every team-shaping verb, plus msg `sweep`, `decision add` and `route`.
- D7 `--orchestrator-pid`.
- D8 `--team`: another team; no teamed row.
- D9 msg: `--type request`; no `--type`; a foreign `--from`; a `--req` that is not `--request.md`, or does not
  exist, or whose **realpath** dirname is outside both msgs dirs. That includes a symlink or a `..` spelling that
  resolves outside. (r3: the realpath rule decides. A symlink or `..` spelling that resolves **inside** a msgs dir is
  allowed: A7.)
- D10 a repeated, unknown or valueless flag.
- D11 a foreign `--cwd`.
- D12 an empty command; 1025 characters; leading or trailing whitespace.
- D13 a gated-role **subagent** (`agent_id` plus a gated direct role), including an allowed form.
- D14 an internal throw → deny.
- D15 `status --now x` and `status --plain`.

**UNTOUCHED (exit 0 silently):**
- U1 implementor, reviewer, ultra-advisor or orchestrator running anything.
- U2 no role.
- **U3 (C1) a task-gopher subagent inside an architect session runs `ls`.**
- U4 a custom role with no `shell` field, or a different value.
- U5 an orchestrator-class role carrying `shell: "self-care"` (ignored).

**INVARIANTS:**
- I1 (C5) no code path emits `allow`: a grep of the hook for `allow` as a decision value finds nothing, and every
  test's output is empty or a deny.
- I2 the deny text contains the current ROSTER_CLI and MSG_CLI paths.
- I3 `role set --shell <other>` is rejected, and `--shell self-care` on an orchestrator-class role is rejected.
- C1/C2 content checks: architect.md has no `Bash` in `disallowedTools`, has the exception sentence, and has the C6
  sentence; hooks.json lists the gate first under Bash.

## 9. Acceptance

1. **(C7) Evidence before build** (Implementor):
   - E1: does a top-level `--agent` architect session's PreToolUse payload carry `agent_type`? The tests cover the
     observed shape.
   - E2: is `CLAUDE_PID` in that session's Bash env equal to its registered pid?
   - E3 (§4).
2. All §8 tests are present and seen failing at the base where new. The full ah suite and `claude plugin test` are
   green.
3. **(C8)** The Reviewer confirms, by reading, that the read-only msg/roster verbs write nothing.
4. Manual M1 in a live architect session:
   - checkin, whoami and a response run;
   - `ls` is refused with the reason;
   - a task-gopher subagent's `ls` runs.
5. Generic text; both manifests bumped.

## 10. Rulings recorded

- Ultra-Advisor whbk: Q1 Bash plus a gate (MCP rejected); Q2 fail-open acceptable; Q3 sound after C3; Q4 no reach
  after C4.
- User: custom roles too (§4); accept the pause (§5.4); no team-shaping block (§7).
- The follow-on (an auto re-register hook) is placed in 0078 Part B, §5.6.
