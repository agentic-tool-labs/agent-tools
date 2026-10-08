# 0090 — The Reviewer files its own report with one ah command

Implementer: implementor
Reviewer: reviewer

Target: **0.128.0** (0.127.0 merges first). Base: `main` a4c0607 (0.125.0). Branch `ah/0090-reviewer-report`.

Status: **r1**.

## 1. Goal

In practice the Reviewer cannot fill its response file, so the Orchestrator copies every review out by hand. After this change, the Reviewer writes its report body into the response file that `msg.mjs new --type response` created, with one `msg.mjs` command. That command needs no permission prompt in a pane where no one is watching.

## 2. Root cause (what the code shows, and what it does not)

ah itself does not deny the Reviewer:

- `agents/reviewer.md:2-12` removes only `NotebookEdit` and `advisor`, so Write, Edit and Bash are all present.
- `hooks/pretooluse-reviewer-write-gate.mjs` (hooks.json:89-93) **allows** Write and Edit for the Reviewer when all of these hold:
  - the target is its own existing `--response.md` in a msgs pool (`msgsDirsOf`);
  - the frontmatter has `type: response` and `from: reviewer`;
  - the frontmatter is left byte-identical.
- The Reviewer is not in `SELF_CARE_BUILTIN_ROLES` (`lib-config.mjs:1227`), so it has a normal shell.

The gate "allows" only by staying silent. It returns no `allow` decision, so Claude Code's own permission check still runs. The Reviewer is a pane member session working in a git worktree (`.claude/worktrees/<n>`). The response file sits in the main checkout's `.claude/hierarchy/msgs/`, which is outside the worktree, under a `.claude/` directory. A Write there raises a permission prompt. In a member session nobody answers it, and since 0.123.0 a prompt in a member session becomes a denial (`lib-config.mjs:73-74`, `MEMBER_ASK_TAIL`). That chain is the most likely cause. It has not been reproduced (§7, A1).

ah's own CLI calls do not hit this: `hooks/pretooluse-ah-cli.mjs` returns `allow` for `node …/hooks/msg.mjs …` in the documented grammar (`docs/cli-tools.md:63-75`). A `msg.mjs` verb therefore works whichever check denied the Write, and keeps the frontmatter intact by construction.

## 3. Contract: `msg.mjs fill`

```
node <R>/hooks/msg.mjs fill --id <id> --from <role> --req <abs request path> --body '<JSON string>' --cwd <abs cwd>
```
(illustrative usage line)

**Behaviour:**

1. **Locate.** The response path is derived the same way `new --type response` names it: beside `--req`, using `createMessage`'s naming (`msgFilename`, `lib-hier.mjs:145`) with the request's frontmatter. Reuse that naming; do not re-derive it.
2. **Validate, each a usage error (`fail`, exit 2, nothing written):**
   - `--req`:
     - absolute;
     - exists;
     - parses as `*--request.md` (`parseMsgFilename`);
     - its id equals `--id` (`ID_RE`).
   - The response file:
     - exists (it was made by `new`; `fill` never creates one);
     - its frontmatter `type` is `response`;
     - its `id` equals `--id`;
     - its `from` equals `--from`.
   - `--body`:
     - present;
     - `JSON.parse` yields a **string**;
     - after trimming it is non-empty;
     - its size is ≤ 64 KiB in UTF-8;
     - no line of it is exactly `---`, so the frontmatter fence cannot be confused.
3. **Write.**
   - The new file is the existing frontmatter block, byte-for-byte (through its closing `---` line and the newline after it), followed by the body. If the body does not end with a newline, add one.
   - Everything after the frontmatter is replaced.
   - The write is atomic: write a temporary file in the same directory, then rename it over the target.
4. **Repeatable.** `fill` may run again on the same response (a revised review). Each run replaces the body.
5. **Output:** `{ "id", "path", "bytes" }` as JSON, or `<id>  <path>` with `--plain`, matching `new`.
6. **Role-agnostic.** Any role may `fill` a response whose `from` it names. Identity is self-declared, the same trust as `new --from`. ah's write gate for Write and Edit is unchanged.

**Body encoding.** The body travels as a single-quoted JSON string:
- newlines are `\n`;
- a single quote is `'`, because a literal `'` cannot appear inside the shell's single quotes.

`--body` joins the single-quoted JSON flags in the invocation rules (`docs/cli-tools.md:55`, alongside `--args`).

**Permission.** `hooks/pretooluse-ah-cli.mjs` must allow `msg.mjs fill … --body '<json>'` under its existing grammar:
- the single-quoted value may contain spaces and any characters except `'`;
- the command stays on one line;
- no other relaxation is made.

If that hook caps the command length below what a 64 KiB body needs, raise the cap for this flag only to fit the 64 KiB limit, and say so in the report.

**Self-care roles** (the Architect, and custom `shell: "self-care"` roles) do not get `fill`. Their token rule forbids quotes, and they author files with Write. `fill` is not added to `VERBS` in `pretooluse-self-care-gate.mjs`.

## 4. Files

- `agent-hierarchy/hooks/msg.mjs`: the `fill` verb, and the usage header comment.
- `agent-hierarchy/hooks/lib-hier.mjs`: only if a small shared helper is needed to split the frontmatter from the body. Reuse `parseFrontmatter` and its `end` offset.
- `agent-hierarchy/hooks/pretooluse-ah-cli.mjs`: accept `--body` as a single-quoted JSON flag.
- `agent-hierarchy/agents/reviewer.md`:
  - the report flow (:66-70, :100-107) becomes: `msg.mjs new --type response …`, then **one** `msg.mjs fill … --body '<json>'` carrying the whole report in the existing format (:109-113);
  - remove the "fill the sections with Edit" instruction;
  - state the `\n` and `'` encoding;
  - keep the rule "never edit anything but your own response file".
- `agent-hierarchy/docs/cli-tools.md`:
  - a `fill` row in the msg verb table (:116-126);
  - `--body` in the single-quoted JSON list (:55).
- Tests (§6).
- `.claude-plugin/plugin.json` and the root `.claude-plugin/marketplace.json` `ah` entry: both `0.128.0`.
- `CHANGELOG.md`: `## [0.128.0]` with `### Added`, in plain prose: a new `msg.mjs fill` verb writes a response body into an existing response file, keeping the frontmatter; the Reviewer files its report with it.

Not touched:
- `pretooluse-reviewer-write-gate.mjs` (Write and Edit stay allowed exactly as today, as a fallback);
- the self-care gate;
- `new`'s behaviour;
- the response skeleton.

## 5. Invariants and negative cases

Must not change:

- The frontmatter bytes of the response file.
- `new --type response`, with output identical to 0.125.0.
- The Reviewer write gate's decisions.
- Every existing `msg.mjs` verb.

| Input | Expected |
|---|---|
| A valid `fill` on a response made by `new` | the body is replaced, the frontmatter is identical, the output JSON is printed |
| `fill` run twice | the second body replaces the first |
| The response file does not exist | exit 2, `msg.mjs: … no response … run new first`; nothing created |
| `--from architect` on a `from: reviewer` response | exit 2; unchanged |
| `--id` differs from the request's id | exit 2 |
| A relative `--req`, a missing one, or a `--response.md` given as `--req` | exit 2 |
| `--body` is not JSON, is a JSON number or object, or is `"   "` | exit 2 |
| The body has a line that is exactly `---` | exit 2 |
| The body is larger than 64 KiB | exit 2 |
| The body has no trailing newline | written with one newline appended |
| A request in the main checkout's msgs, `--cwd` a worktree | works (path derived from `--req`, as `new` does) |
| `pretooluse-ah-cli.mjs` given `msg.mjs fill … --body '<json>'` | `allow` |
| The same, with a pipe, redirection or `$(…)` outside the quotes | not allowed (unchanged grammar) |
| The self-care gate (Architect) given `msg.mjs fill …` | refused, as for any unlisted verb |
| A Reviewer Write to its response with the frontmatter unchanged | allowed, as today |

## 6. Verification (each new case fails on 0.125.0)

- `tests/test-msg-response.sh`, or a new `tests/test-msg-fill.sh` registered in `run-suite.sh`, covers every row of §5 from `fill` down to the trailing newline. One case:
  - checks the frontmatter bytes with `cmp` on the head before and after;
  - checks that a body containing `it's` lands as `it's`.
- `tests/test-msg-reply-beside-request.sh`: one `fill` case with a worktree `--cwd` against a main-checkout request.
- The ah-cli permission hook's test file gets the allow and deny rows from §5, driven by payload as its existing cases are.
- `tests/test-self-care-gate.sh`: one case, `fill` refused for the Architect.
- `tests/test-reviewer-write-gate.sh`: passes unchanged.
- The full suite (`run-suite.sh`) passes.

## 7. Assumptions to confirm while building

- **A1. NEEDS-EVIDENCE (informative; does not change the design).** In a pane Reviewer session working from a worktree, have it Write its own response file and record the exact denial text. Expected: a Claude Code permission denial with the member-session tail. If it is instead the ah reviewer write gate's text, note that in the report. `fill` still fixes the problem, because it keeps the frontmatter by construction.
- **A2.** The name of the ah-cli permission hook's test file, and how that hook lists the single-quoted JSON flags. Extend the existing list. Do not add a second mechanism.

## 8. Open questions (defaults taken)

- **Q1.** Should Write and Edit on the response file stay allowed now that `fill` exists? Default: **yes**. They cost nothing, and they help a top-level Reviewer whose cwd is the main checkout.
- **Q2.** Should other roles (the Implementor, and Codex members) be told to use `fill`? Default: **no**, not in this change. The verb is role-agnostic, so a later change can adopt it per role.
