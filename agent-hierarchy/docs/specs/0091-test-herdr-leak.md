# 0091 — Tests can never reach the user's real herdr or tmux

Implementer: implementor
Reviewer: reviewer

Target: **0.129.0** (0.126.0-0.128.0 merge first). Base: `main` a4c0607 (0.125.0). Branch `ah/0091-test-herdr-leak`.

Status: **r1**.

## 1. Goal

Full test loops opened idle tabs labelled `· sx` in the user's real herdr workspace. Each tab is an idle zsh whose cwd is a test sandbox under `/private/tmp/ahprobe.*`, one per loop. After this change, no test can execute the user's real `herdr` or `tmux`. A test that tries fails loudly, and the suite enforces that every test runs under that guard.

## 2. Root cause

**The leaking test.** `tests/test-state-team-peers.sh:230`, on the openrig research branches only (`ah/openrig-*`; not on `main`):

```
stream_open() { OUT=$(cd "$PROJ" && env -u AH_TEAM_FILE CLAUDE_PID="$$" "$@" node "$SB_HOOKS/roster.mjs" stream-open sx --no-worktree … --cwd "$PROJ" 2>&1); RC=$?; }
```
(quoted)

- The file puts no fake `herdr` on PATH. It unsets only `HERDR_PANE_ID` (:143, :206, :285), and never `HERDR_ENV` or `HERDR_WORKSPACE_ID`.
- The loop runs inside the user's herdr pane, so `HERDR_ENV=1` and the real `herdr` on PATH are inherited.
- `detectTransport()` (`hooks/roster.mjs:2405`) returns `herdr`. Separately, a team file whose `transport` is already `herdr` skips that check entirely (`roster.mjs:6560`).
- `stream-open` builds the label `· sx` (`roster.mjs:6588`) and calls `herdr tab create --label "· sx" --cwd <PROJ> --no-focus` (`streamTabCreateArgv`, `:4939`). That goes through `herdrCall` (`:2954-2958`), which runs `execFileSync("herdr", …)`, resolved through PATH with the full inherited env. Result: one real tab per run.

**Why nothing caught it.** These are the structural gaps:

| Gap | Where |
|---|---|
| herdr runs by bare name through PATH with the inherited env, and nothing in the product tells a test from a user | `roster.mjs:2958`, `lib-blocked.mjs:18`, `:27` |
| tmux runs the same way (`list-sessions`, `new-window`, `kill-pane`, `list-panes`). An inherited `TMUX` or the default socket reaches the user's tmux server | `roster.mjs:2408`, `:4014`, `:4066`, `:4490` |
| Isolation is per test file and opt-in. About 26 of 130 files build a fake herdr and 37 have a failing `nolaunch` stub. Many roster-invoking files have neither (for example `test-roster.sh`, `test-roster-spawn.sh`, `test-roster-multi-team.sh`, `test-roster-reap.sh`, `test-multi-owned-teams.sh`, `test-roster-worktree.sh`). No test uses a private tmux socket (`-L` or `TMUX_TMPDIR`: zero matches) | `tests/` |
| No shared env helper, and `main` has no suite runner. `tests/test-suite-hermeticity.sh` only lints the `AH_TEAM_FILE` and `CLAUDE_PID` unsets | `tests/` |

On `main` today, no test is confirmed to leak. The gap rows above are what let the openrig test leak, and what would let the next one.

## 3. The fix

### 3.1 One shared test preamble: `tests/lib-hermetic.sh`

Every `tests/test-*.sh` sources it as its first executable line. When sourced, it:

1. **Unsets** every `HERDR_*` variable (by prefix, not by a fixed list), plus `TMUX`, `TMUX_PANE`, `AH_TEAM_FILE` and `CLAUDE_PID`.
   - A file may re-set any of them afterwards for its own fixtures, as files do today (for example `HERDR_PANE_ID=p-tm-implementor`).
2. **Exports `TMUX_TMPDIR`** as a fresh `mktemp -d` directory. Any real `tmux` started by the file then gets a private server and never sees the user's.
3. **Exports the guard variables:**
   - `AH_TEST_HERMETIC=1`;
   - `AH_TEST_PID=$$`;
   - `AH_TEST_TRIPWIRE`, a file inside that temporary directory.
4. **Does not change PATH.** Files keep their own fake-binary directories. A fake directory is declared to the guard with `AH_TEST_FAKE_BIN` (colon-separated absolute directories), exported by the file after it creates the fakes.

Sourcing it twice is harmless.

### 3.2 One guarded exec for multiplexer binaries (product code)

All herdr and tmux executions in `hooks/` go through **one** helper: the existing `herdrCall` generalised to cover both binaries, or a new shared function in a `lib-*.mjs` that `herdrCall` calls. The three herdr sites and the four tmux sites listed in §2 all use it. There is no second copy of the rule.

When `AH_TEST_HERMETIC` is not `1`, behaviour is byte-identical to 0.125.0.

When `AH_TEST_HERMETIC=1`:
- **Allowed:** resolve the binary name on the current PATH, the same way exec would. If its realpath is inside one of the `AH_TEST_FAKE_BIN` directories, run it as today.
- **Not found on PATH at all:** behave as today, the same ENOENT failure. Nothing real is reached, and some tests rely on the absent-binary path.
- **Otherwise (found, but outside every listed directory): the tripwire.**
  1. Append one line, `<binary> <args joined by space> pid=<process.pid>`, to `AH_TEST_TRIPWIRE`.
  2. Write `ah: test hermeticity: a test reached the real <binary> (<args>). Put a fake in a directory listed in AH_TEST_FAKE_BIN.` to stderr.
  3. Send `SIGTERM` to `AH_TEST_PID`, if it is set and alive, so the test file dies with a non-zero exit even when the caller would swallow a herdr error.
  4. Throw, as a failed exec does today. **Never run the binary.**

Why kill the test: herdr and tmux failures are tolerated on purpose in several product paths, so a refusal alone could leave a test green. The kill makes the leak impossible to miss.

The `herdrOnPath()` PATH scan (`lib-roster.mjs:140`) is unchanged. It executes nothing.

### 3.3 Enforcing it suite-wide: `tests/test-suite-hermeticity.sh`

Add to the existing lint:

- **H1.** Every `tests/test-*.sh` sources `lib-hermetic.sh` before any `node`, `herdr` or `tmux` invocation. The check is textual: the first line that is not blank, a comment or a `set` line must be the source line.
- **H2.** Every file that writes an executable named `herdr` or `tmux` into a directory also exports `AH_TEST_FAKE_BIN` containing that directory.

### 3.4 Migrating the existing tests

- Add the source line to all 130 `tests/test-*.sh` files.
- In each file with a fake `herdr` or `tmux` (the ~26 fake-herdr files, the 37 `nolaunch` stub files, and any others H2 finds), export `AH_TEST_FAKE_BIN=<its bin dir>`.
- Remove each file's own now-redundant unsets of `HERDR_*`, `TMUX` and `TMUX_PANE` only where they sit at the top of the file. Leave in place any unset that a case performs deliberately mid-file.
- Do not weaken any case. A file that newly trips the wire has found a real leak: fix the file (give it a fake), never loosen the guard.

## 4. Files

- New: `agent-hierarchy/tests/lib-hermetic.sh`.
- `agent-hierarchy/hooks/roster.mjs` (`herdrCall` and the four tmux sites).
- `agent-hierarchy/hooks/lib-blocked.mjs` (:18, :27), routed through the shared helper.
- `agent-hierarchy/hooks/lib-roster.mjs`: only if the shared helper lives there.
- `agent-hierarchy/tests/test-*.sh`: all files (§3.4).
- `agent-hierarchy/tests/test-suite-hermeticity.sh`: H1, H2, and the cases in §6.
- `.claude-plugin/plugin.json` and the root `.claude-plugin/marketplace.json` `ah` entry: both `0.129.0`.
- `CHANGELOG.md`: `## [0.129.0]` with `### Fixed`, in plain prose: the test suite can no longer open tabs in your real herdr or windows in your real tmux; every test runs under a shared guard that fails a test which reaches either.

## 5. Invariants and negative cases

Must not change:

- With `AH_TEST_HERMETIC` unset, every herdr and tmux call is byte-identical: same argv, same env, same timeout (`AH_HERDR_TIMEOUT_MS`).
- Users never set `AH_TEST_HERMETIC`. It is documented only in `lib-hermetic.sh`.
- Every existing test case passes after migration, with the same assertions.

| Input (`AH_TEST_HERMETIC=1`) | Expected |
|---|---|
| A fake `herdr` in `$SANDBOX/bin`, listed in `AH_TEST_FAKE_BIN`, first on PATH | runs the fake |
| A fake `herdr` on PATH, but its directory is not listed | tripwire line, stderr message, test killed, binary not run |
| No fake; the real herdr is on PATH (the openrig leak) | the same: tripwire, nothing reaches the real herdr |
| No `herdr` anywhere on PATH | the ENOENT failure as today; no tripwire, no kill |
| A symlink in a listed directory pointing at the real `/opt/homebrew/bin/herdr` | tripwire, because the realpath is outside the listed directories |
| A team file with `transport: "herdr"` and `HERDR_ENV` unset | still guarded (the guard is at exec, not at detection) |
| tmux: `detectTransport`'s `list-sessions` fallback with no fake tmux | tripwire. Files that reach it must provide a fake tmux, or one that fails, in a listed directory |
| `AH_TEST_HERMETIC` unset (a user session) | unchanged; the real herdr runs |
| `AH_TEST_PID` unset or dead | no kill; the tripwire line and the throw still happen |
| Probe scripts (`tests/probe-*.sh`, not `test-*`) | not covered by H1; they keep their own sandbox and the shim that forbids herdr |

## 6. Verification (each new case fails on 0.125.0)

In `tests/test-suite-hermeticity.sh`:

- **G1 (the guard fires; the negative test).** In a child `bash` that sources `lib-hermetic.sh`:
  - put a directory `$T/realbin` holding a `herdr` that logs its argv to `$T/real.log` first on PATH, and leave it **out** of `AH_TEST_FAKE_BIN`;
  - set up a sandbox team with `transport: "herdr"`;
  - run `roster.mjs stream-open sx …`.

  Assert all of:
  - the child exits non-zero (killed);
  - `$T/real.log` does not exist;
  - the tripwire file has one `herdr tab create … --label · sx …` line;
  - stderr names the binary.
- **G2 (an allowed fake runs).** The same, but with `$T/realbin` listed in `AH_TEST_FAKE_BIN`: the child completes, and `$T/real.log` holds the `tab create` argv.
- **G3 (tmux).** The same pattern for tmux via a `spawn` that reaches `new-window`. An unlisted fake gives the tripwire, and a listed one runs.
- **G4 (no guard, no change).** With `AH_TEST_HERMETIC` unset and the logging fake first on PATH, the call runs the fake. This proves the product path is unchanged outside tests.
- **G5 (symlink).** A listed directory holding a symlink to `$T/realbin/herdr` gives the tripwire.
- **H1 and H2 lint cases.** A synthetic test file without the source line fails H1. A synthetic file that writes `bin/herdr` without exporting `AH_TEST_FAKE_BIN` fails H2. Both run against a temporary copy and never against the real tree.

Then the full suite passes with every file migrated, and running it leaves no tripwire file with content.

## 7. Assumptions to confirm while building

- **A1.** No file on `main` trips the wire after migration. Any file that does is a real leak. Fix it in this change and list it in the report.
- **A2.** `TMUX_TMPDIR` set to a fresh directory, with `TMUX` unset, keeps a real `tmux` off the user's server (tmux's documented socket lookup). Belt and braces: the guard already refuses an unlisted tmux.

## 8. Open questions (defaults taken)

- **Q1.** Is killing the test file on a tripwire too harsh? Default: **kill**. A swallowed refusal could leave a leaking test green, and that is how this leak went unseen.
- **Q2, for the Orchestrator rather than the user.** `test-state-team-peers.sh` lives only on the `ah/openrig-*` branches. 0091 cannot fix it on `main`. When those branches take 0.129.0, H1 and the guard will force the fix. Until then, that file should get a fake `herdr` and `unset HERDR_ENV HERDR_WORKSPACE_ID` on the research branch now, as a one-line R11 follow-up, so loops stop leaking today.
- **Q3, for the user.** Ten idle `· sx` tabs are open in the user's herdr now. Closing them is the user's call. Nothing in this change touches the real herdr.
