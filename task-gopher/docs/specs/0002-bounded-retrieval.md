# 0002: Bounded retrieval: keep context clean without wasting turns

Status: design, for the user's sign-off. Spec text only.
Implementer: implementor
Reviewer: reviewer

Paths are relative to `task-gopher/`. "The gate" is today's strict-mode PreToolUse checkpoint in
`hooks/pretooluse-nudge.mjs`, version 0.22.0. **No code or text here is copied from any other plugin.**

## 1. The problem, in numbers

The audit log `~/.claude/task-gopher.log` holds 104,432 JSON lines, from 12,836 sessions.

| Event | Count |
|---|---|
| `checkpoint` (a deny) | **33,342**: 11,526 at turn start, 21,811 escalated |
| `bypass` (an allowed direct retrieval) | **60,434** |
| `dispatch` (a gopher dispatch) | **9,346**: 9,129 to task-gopher, 217 to smart-gopher |
| `smart-gate-checkpoint` | 230 |
| `verbatim-deny` | 78 |

**What the gate does** (`pretooluse-nudge.mjs`):
- It keys a streak on `session|agent|prompt_id`.
- It denies the first retrieval of a turn, allows the next two, denies the third, and repeats.
- **It compares no call signature.** "Re-running the same call proceeds" only because *any* next call counts
  as the bypass.
- So **35.6% of gated retrievals are denied** (33,342 of 93,776), and that share is fixed by construction.

**What a deny buys:**
- There are 0.28 dispatches per deny. Most denies do not lead to delegation.
- The deny's own message tells the agent to re-run the identical call, and the agent does. **The bulk output
  then enters the context anyway, one turn later.** The gate adds a turn, but does not keep the output out.
- **What happens after a deny** (E-1, measured: stream = `pid|aid`; the next row in the same stream decides;
  "identical" = same tool and same `detail`):

  | Next row after the deny | Count | Share |
  |---|---|---|
  | **An identical re-run of the denied call** | **25,667** | **77.0%** |
  | A different retrieval | 5,186 | 15.6% |
  | **A gopher dispatch** | **1,581** | **4.7%** |
  | Nothing (the turn ended) | 531 | 1.6% |
  | Denied again on the identical call | 377 | 1.1% |

  - The identical re-run comes **2.78 s** after the deny at the median (p90 7.46 s). That is pure turn
    overhead.
  - **Only 4.7% of denies lead to delegation.**
- **Who is hit:**
  - by thread: 95% of denies (31,682) are on the main thread, and 1,660 on subagents;
  - by tool: Bash 21,144 and Read **12,198** (37% of all denies). Grep and Glob have 0, because the agents use
    `grep -n` and `sed -n` through Bash instead.
- **The top denied signatures:**
  - `Read` 12,198 (77.9% re-run);
  - `grep -n` 3,536;
  - `python3 -` 651;
  - `grep -rn` 528;
  - `sed -n` 494;
  - `git diff` 397;
  - `git status` 394.
  - **Write commands are being denied as retrievals:** `git add` 316, `cat >` 239, `cat >>` 204, `sed -i` 153.
    That is classifier noise, about 900 denies.
- The smart-gopher gate denies every new smart-gopher prompt exactly once, and that is a re-run by design.

**The log records no output sizes**, so today's context cost cannot be measured. The new design logs it (§6).

**Conclusion.** The gate trades turns for nothing. **What keeps a context clean is bounding what a call
returns, not refusing the call.**

## 2. The options compared

Each option was judged on five criteria: turns wasted, context kept clean, ease of compliance, implementation
risk, and backward compatibility.

| Option | Turns wasted | Context clean? | Agent effort | Risk | Verdict |
|---|---|---|---|---|---|
| Today's call-count gate | One per three retrievals | **No**: the re-run delivers the output | High (endless re-runs) | — | Replace |
| Deny once per command signature per turn | Fewer, but every new signature still costs one | No | Medium | Low | Still a turn tax, with no context benefit |
| Gate on a predicted output size (allow `git status -s`, `ls`, bounded `Read`; deny unbounded commands) | Only on "big" commands | No: the re-run still delivers it | Medium | Prediction is brittle | Better aimed, same flaw |
| PostToolUse measurement plus a reminder on the next turn | **0** | Not this call; it nudges the next | Low | Low | Good as a supplement |
| A `gopher batch` tool | 0 | Yes, when used | It requires the model to choose | Medium | It relies on the model's choice, which the brief rules out as the mechanism |
| A deny that carries the answer (the hook runs the command, and returns the head plus a path) | 0 re-runs | Yes | Low | **High**: the hook does not know the Bash tool's live cwd or environment, and runs side effects in hook context | Reject |
| Learning exemptions from the log | Fewer over time | No | Low | Low | Treats the symptom |
| **Bounded output by rewrite**: PreToolUse `updatedInput` runs the call in the real shell, spools the full output to a file, and returns small output verbatim, or the head and tail plus the path when it is large; a short PostToolUse note when it truncated | **0** | **Yes, every call is capped** | **None**: nothing to choose, nothing to re-run | Medium (needs N1-N4) | **Recommended** |

## 3. The recommendation: bounded retrieval

**In strict mode, the hook never denies a retrieval.** It does three things instead:
1. **It caps what the call returns.** It rewrites gated calls so that their output is bounded: Bash through a
   spool wrapper; `Read` and `Grep` through their own limit parameters.
2. **It points at the spill.** When it truncates, it says so in a PostToolUse note, gives the path of the full
   output, and suggests task-gopher for sifting it.
3. **It counts bytes, not calls.** It logs the delivered and total size of each retrieval, so the context cost
   can be measured, and the success metric (§7) is computed from those rows.

**Delegation still has a pull.** A large output is never thrown at the agent. The agent gets the head and tail,
plus a path. Sifting the rest is exactly the task the note offers to hand to task-gopher, at no turn cost.

## 4. Exact behaviour

### 4.1 Which calls are bounded

The classifier is today's, reused: `RETRIEVAL_ANY`, `READER_LEADING`, nested lookups, the `isExempt` action
list, and `cannotDispatch`.

| Call | Rewrite (`updatedInput`) |
|---|---|
| A Bash retrieval (by the classifier), **not** `run_in_background` | Spool wrapper (§4.2) |
| Bash with `run_in_background` | None. Its output already goes to a file |
| A Bash call that is not a retrieval (writes, exempt actions) | None |
| `Read` with no `limit` and no `offset` | Add `limit: READ_CAP_LINES` (default **600**). With an explicit `limit` or `offset`: unchanged |
| `Grep` with `output_mode: content` and no `head_limit` | Add `head_limit: GREP_CAP` (default **250**) |
| `Glob` | None (results are paths, and are bounded in practice) |
| Agents whose `tools:` list has no Agent or Task (`cannotDispatch`, including task-gopher itself) | **None.** Runners need the full output |

### 4.2 The Bash spool wrapper

- The command is rewritten to run **in the same shell**, as a brace group, not a subshell. That preserves `cd`,
  environment changes and exit status.
- The illustrative shape:
  `{ <original command>\n} >"$TG_SPOOL" 2>&1; __tg=$?; sh <plugin>/bin/tg-show "$TG_SPOOL" $__tg; (exit $__tg)`
  - `TG_SPOOL` is `<TMPDIR or /tmp>/task-gopher/<session-short>/<seq>.out`, mode 0600.
  - The command text is inserted verbatim, followed by a newline, so that a trailing comment or a heredoc
    stays valid.
- **`bin/tg-show`** (POSIX sh):
  - **When the spool is at most `SHOW_LINES` (120) lines and at most `SHOW_BYTES` (12 KiB),** it prints the
    file verbatim, with no banner. Small outputs are untouched, so `git status -s`, `ls` and short greps look
    exactly as they do today.
  - **Otherwise** it prints:
    - the first `HEAD_LINES` (40) lines;
    - `… [task-gopher: <N> lines, <B> KiB; full output in <path>] …`;
    - the last `TAIL_LINES` (40) lines, because test and build failures sit at the end.
  - **It logs** one JSON row: `{event: "spooled", tool: "Bash", detail, total_bytes, total_lines,
    delivered_bytes, truncated}`.
- **The exit code is the original command's.** stderr is merged into the spool, as the Bash tool already
  merges it for the model.

### 4.3 PostToolUse notes (new; never a block)

When a call was truncated (Bash spooled, Read capped below the file's length, Grep hitting `head_limit`), the
hook adds `additionalContext` in **one line**:

`task-gopher: output truncated (<N> lines; full output at <path>). To sift it without filling your context, dispatch task-gopher:task-gopher with the path and what to find.`

- For `Read`, the line reads `continue with offset <600>` or the dispatch.
- **It is shown at most once per spool file**, and at most once every 3 calls per context, so it cannot become
  the new nag.

### 4.4 The smart-gopher and whole-file gates

- **The smart-gopher first-attempt deny is removed.** It is always re-run, by design, so it is a pure turn tax.
  It becomes `log-only`, plus a PostToolUse line on the first smart-gopher dispatch in a session:
  `smart-gopher costs more than task-gopher; use it only when the order needs judgement`.
- **The whole-file refusal (verbatim gate) stays.** Its deny changes the order: the agent must rewrite it.
  That is a real course change, not a re-run.
- **The destructive gate is unchanged.** It is a safety gate.

### 4.5 Modes and backward compatibility

- **`/task-gopher strict on` now means bounded mode.**
- **`/task-gopher strict legacy`** keeps today's call-count deny, for one minor version, as a rollback. It
  writes `legacy` into `~/.claude/task-gopher.strict`, whose content today is ignored; existence alone is the
  "on" signal.
- **Removed in the next minor version.**
- With the plugin off, nothing changes.

## 5. Failure modes

| Failure | Behaviour |
|---|---|
| The spool dir is not writable | The rewrite is skipped and the call runs unchanged. One `spool-skip` log row. **Fail open, never deny** |
| `tg-show` is missing or fails | The wrapper prints the spool file whole (the old behaviour) and exits with the original status |
| A command with unbalanced braces or an odd heredoc | It is caught by N4's matrix. On a parse doubt (an odd number of unescaped `{`/`}` outside quotes), the rewrite is skipped |
| Interactive commands (`less`, a pager) | Today's classifier already catches `less`. Spooled to a file, it behaves as `cat`. `git` pager variables are set to `cat` inside the wrapper |
| Another plugin's PreToolUse also rewrites `updatedInput` | **N2 decides.** If the last writer wins, task-gopher declares the order it needs. If they compose, nothing is needed. If they conflict, the rewrite is skipped while another rewriting hook is active (fail open) |
| Disk growth | Spool files for a session are removed at SessionEnd. Files older than 24 h are swept at SessionStart |
| A secret in the output | It lands on disk only in a 0600 file under a 0700 dir, in the session's temp root. That is no worse than the transcript, which already holds it |

## 6. Logging

New events: `spooled`, `spool-skip`, `read-capped`, `grep-capped` and `note` (each PostToolUse line shown).
- Each carries `total_*` and `delivered_*` sizes where known.
- `checkpoint` and `bypass` disappear in bounded mode. They still appear in `legacy`.

## 7. Success metric (computed from the audit log)

- **Wasted turns:** retrieval denies per 1,000 gated retrievals.
  - **Baseline: 356** (33,342 of 93,776).
  - **Target: 0** in bounded mode. The whole-file and destructive gates are excluded.
- **Context cost:** the p90 and p99 of `delivered_bytes` per retrieval.
  - **Target:** p99 ≤ `SHOW_BYTES` plus the head-and-tail banner (≈ 16 KiB).
  - The baseline is unknown, because the old log has no sizes. The first week of `spooled` rows with
    `truncated: false` and `true` gives it.
- **Delegation kept:** dispatches per 1,000 retrievals.
  - **Baseline: 100** (9,346 of 93,776).
  - Target: at least 80. This guards against delegation vanishing once the nag is gone. The PostToolUse note
    supplies the pull.
- **The report** is a new `task-gopher report --bounded` (or an extension of the existing report) that prints
  these three numbers for a date range.

## 8. Tests (bash suites in `tests/`, `HOME` redirected to a `mktemp -d` sandbox, as today)

| # | Check | Mutant killed |
|---|---|---|
| B-1 | A 5-line retrieval (`git log -n 3`) through the wrapper prints byte-identical output to the unwrapped command, with no banner, and the same exit code | A banner on small output |
| B-2 | A 5,000-line `grep -rn` prints 40 head lines, the banner with the right counts and path, and 40 tail lines; the spool holds all 5,000 lines | No tail; wrong counts |
| B-3 | `cd sub && grep x f` through the wrapper leaves the shell in `sub`, as the unwrapped command does (checked in the hook test by running the rewritten text in one shell, then `pwd`) | A subshell wrapper |
| B-4 | Exit codes 0, 1, 2 and 130 pass through | Status flattened |
| B-5 | A heredoc and a trailing `# comment` survive the rewrite | Text inserted without the newline |
| B-6 | `run_in_background: true` → no rewrite. An exempt action (`git commit`) → no rewrite. An agent with `cannotDispatch` → no rewrite | Over-wrapping |
| B-7 | `Read` with no limit gets `limit: 600`; with a `limit`, unchanged; the PostToolUse note fires only when the file is longer than 600 lines | Cap applied to explicit reads |
| B-8 | `Grep` content mode with no `head_limit` gets 250; files mode is unchanged | Wrong mode capped |
| B-9 | In bounded mode, no `checkpoint` event is ever written for Read, Grep, Glob or Bash over 100 mixed calls; `strict legacy` restores today's deny sequence (the existing `strict:` rows re-run under legacy) | Denies left in; rollback broken |
| B-10 | The smart-gopher dispatch is not denied; one PostToolUse line appears per session | The tax kept |
| B-11 | Spool dir not writable → the command runs unwrapped, and there is one `spool-skip` row | A deny on infrastructure failure |
| B-12 | The note appears at most once per spool, and at most once every 3 calls per context | The note becomes the nag |
| B-13 | The `spooled` rows carry `total_bytes` and `delivered_bytes`, and the report prints the three metrics from a fixture log | Metrics not computable |

## 9. NEEDS-EVIDENCE (implementor, sandbox-safe)

- **E-1, done** (§1): 77.0% of denies are followed by an identical re-run, and 4.7% by a dispatch. A caveat:
  `detail` is capped at 300 characters in the log, so long commands that differ only after that point count as
  identical. The true identical share is therefore at most 77.0%. The direction is unchanged.
- **E-2, the write-command false positives:** sample the 912 denies of `git add`, `cat >`, `cat >>` and
  `sed -i` (§1), and identify the classifier path that gated each (`RETRIEVAL_ANY` in another stage of the
  pipeline? `READER_LEADING` on `cat >`?). **Decides** whether bounded mode needs a classifier fix. A wrapped
  write with small output is harmless, but needless.
- **N1:** PreToolUse `updatedInput` is honoured for **Bash, Read and Grep** (it is verified only for Agent so
  far), and the model sees the rewritten input. **Decides whether the design is viable**; the fallback is
  PostToolUse truncation, if supported.
- **N2:** two plugins' PreToolUse hooks returning `updatedInput` for the same call: last wins, composed, or
  error? **Decides §5's coordination rule**, which matters with other plugins that inspect Bash.
- **N3:** PostToolUse `additionalContext` is delivered for Bash, Read and Grep results.
- **N4:** a matrix of 30 real commands, sampled from the log's `detail` field (pipes, `&&`, `cd`, heredocs,
  `$( )`, quotes, braces, `set -e`), run through the brace-group rewrite in a persistent shell. Compare output,
  exit code, `pwd` and environment after. **Decides** the parse-doubt skip rule.
- **N5:** the wrapper's overhead (p50 ms) against the unwrapped command.

## 10. Migration and rollout

- **0.23.0:** bounded mode as `strict on`; `strict legacy`; the smart-gate deny removed; new log events; the
  README §Strict mode rewritten around "caps output, never blocks retrieval"; tests B-1 to B-13; the existing
  `strict:` tests kept under legacy.
- Both version files are bumped together: `.claude-plugin/plugin.json`, and the root
  `.claude-plugin/marketplace.json` (task-gopher entry).
- **After 1 week:** compute §7 from the log. If the delegation guard (≥80 per 1,000) fails, tune the
  PostToolUse note (§4.3) before considering any deny.
- **0.24.0:** remove `legacy`.

## 11. Decisions for the user

| Q | Question | Default |
|---|---|---|
| T1 | Replace the deny gate with bounded output (this spec) | **Yes** |
| T2 | The caps: `SHOW_LINES`/`SHOW_BYTES` 120/12 KiB, head and tail 40/40, `Read` 600 lines, `Grep` 250 | **These**, to be tuned after a week of `spooled` data |
| T3 | Remove the smart-gopher first-attempt deny | **Yes**, it is always re-run |
| T4 | Keep `strict legacy` for one version as a rollback | **Yes** |
