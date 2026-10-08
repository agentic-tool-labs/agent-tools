# 0088 — A prompt's countdown never changes its screen hash

Implementer: implementor
Reviewer: reviewer

Target: **0.126.0**. Base: `main` a4c0607 (0.125.0). Branch `ah/0088-cancel-countdown`. Merges before 0089 (0.127.0) and 0090 (0.128.0).

Status: **r2**.
- r2 changes:
  - The mask follows the phrase across soft-wrapped lines and border characters, bounded to 6 lines and to no blank line (§3, item 1).
  - It matches `deny` only.
  - Only the time token after the phrase is masked.
  - New test cases V6-V8, plus new rows in §5.

## 1. Goal

Some Claude Code permission prompts show an auto-deny countdown, for example
`Claude Code will automatically deny this request in 1:39`. The line changes every second.

`roster.mjs answer <name> --cancel --screen-hash <h>` refuses with `screen-changed` whenever the hash of the screen now differs from `<h>`. The hash covers the whole visible screen, countdown line included, so on these prompts every attempt is refused. This was seen live: the same `rm` prompt hashed to `718cad…` and then `64166e…` seconds apart, with no other change on screen. `answer --choice` and the watcher's "second time at this prompt" check have the same flaw.

After this change, a countdown that ticks does not change the hash. Any other change on screen still does.

## 2. Root cause

All screen hashes come from one function: `screenHash` in `hooks/lib-roster.mjs:562-567`.

- It splits the screen into lines, trims trailing whitespace from each, drops trailing blank lines, and takes the sha256 of what is left.
- Nothing volatile is masked. The only existing animation masking (Braille cells, for Codex's sparkle, near `lib-roster.mjs:457-463`) is used to detect the composer, never for the hash.
- `grep` finds no handling of "automatically deny" or of a countdown anywhere in `hooks/`.

Every place that uses the hash calls this one function through `readPromptCore` (`hooks/lib-blocked.mjs:51`):

| Consumer | Location | Effect today |
|---|---|---|
| `answer --cancel` hash check | `roster.mjs:6954-6957` | always `screen-changed` on a countdown prompt |
| `answer --choice` hash check | `roster.mjs:6996-6997` | the same, for any recognised prompt that shows a countdown |
| Watcher BLOCKED wake: the hash in the printed cancel command, the `blocked-wake` gate row, `extra.screen_hash` | `dispatch-watcher.mjs:187-205` | the printed hash is stale within a second |
| Watcher "second time at the same prompt" check (`g.screen_hash === hash`) | `dispatch-watcher.mjs:190` | never true on a countdown prompt, so the second-time line is lost |
| `deliver` and spawn report `screen_hash` (`blockedFields`), and the relay command | `roster.mjs:3798-3800`, `:3842` | the hash handed to the caller goes stale |

## 3. The fix (one place)

`screenHash` masks countdown text before hashing. Every consumer above is fixed by this one change, and no consumer changes.

Requirements:

1. **What is masked (r2: survives soft wraps).** Exactly one kind of token is masked: the time value that **immediately follows** the phrase `automatically deny this request in`. It is replaced by one fixed placeholder before hashing.
   - **Time forms:**
     - clock `\d+:\d{2}` (for example `1:39` and `0:05`);
     - seconds `\d+\s*s(ec(ond)?s?)?\b` (for example `45s` and `9 seconds`).
   - **Case-insensitive.** The match is on `deny` only. No real harness string uses reject or approve, so those are not matched.
   - **The phrase and its time may span soft-wrapped lines.** A narrow pane wraps the line at word boundaries. Today's live screen:
     ```
     ⚠ Claude Code will
     automatically deny
     this request in 1:38,
     to avoid blocking
     ```
     When matching, any run of whitespace, line breaks, and box-drawing border characters (U+2500–U+257F, for example `│`) between words counts as one separator. So the phrase may break between any two of its words, and the time may sit on a later line than `in`.
   - **Bound.** A match may span at most **6 screen lines**, counted from the line holding `automatically`, and never crosses a blank line (empty after trimming). A phrase that would need more lines, or a blank line, is not matched, and nothing is masked.
   - **Only the characters of the time token are replaced.** They are replaced in the line where the token sits. Every other character on every line of the span is hashed as it is.
   - **Mid-word breaks are not handled.** That is, a word hard-split because it is longer than the pane is wide. The words of this phrase are at most 13 characters, and a pane narrower than that is not a working pane.
2. **What stays.** Everything outside the masked token is hashed exactly as today, including:
   - the rest of the countdown sentence (`to avoid blocking …`);
   - every other number on the screen;
   - any time value not preceded by the phrase (for example a command `sleep 1:30`, or a log timestamp).

   If the harness rewords the phrase, nothing matches and the hash behaves as in 0.125.0, so `answer` fails safe with `screen-changed`.
3. **The phrase and the time forms are module-level constants** in `lib-roster.mjs`, next to `screenHash`, so a wording change is a one-line edit.
4. **The masking affects only the hash.** The `screen` text returned by `readPromptCore`, the excerpt (`excerptOf`), prompt recognition (`recognizeScreen`, `screenLines`) and the displayed screen are unchanged. The user still sees the real countdown.
5. **The hash format does not change:** 64 lowercase hex characters, sha256.
6. **Order:** trim trailing whitespace from each line, then mask, then drop trailing blank lines and hash. Masking a line never makes it blank. A blank line, for the 6-line bound, is one that is empty after this trim.

Nothing else changes in `answer`: the check order (§6.3 of spec 0085), `not-blocked`, the single Esc, and `cancelled` / `still-blocked` all stay as they are. When the countdown runs out, the prompt leaves the screen, so the hash differs or the member is not blocked. Both are refused today and still are.

**Upgrade.** A `blocked-wake` gate row written by 0.125.0 holds an unmasked hash. A countdown screen read by 0.126.0 hashes differently, so the first wake after the upgrade can miss the second-time line once. That is acceptable, and nothing migrates. On a screen without a countdown line, the hash is byte-for-byte identical to 0.125.0's.

## 4. Files

- `agent-hierarchy/hooks/lib-roster.mjs`: `screenHash` plus the constant.
- `agent-hierarchy/tests/test-blocked-watcher.sh`: new cases (§6). `hash_of` already calls `screenHash` from `lib-roster.mjs`, so it follows automatically.
- `agent-hierarchy/tests/test-chain-roles-other-harnesses.sh`: one `--choice` case (§6, row V5).
- `agent-hierarchy/.claude-plugin/plugin.json` and the root `.claude-plugin/marketplace.json` `ah` entry: both `0.126.0`.
- `agent-hierarchy/CHANGELOG.md`: a `## [0.126.0]` entry under `### Fixed`, in plain prose. One sentence: an auto-deny countdown on a permission prompt no longer makes `answer --cancel`/`--choice` refuse with `screen-changed`, and the watcher's second-time line works on such prompts.

Not touched: `roster.mjs`, `dispatch-watcher.mjs`, `lib-blocked.mjs`, and spec 0085.

## 5. Invariants and negative cases

Must not change:

- The hash of any screen that has no countdown line is identical to 0.125.0's.
- A real change on screen (a different prompt, a different command or path in the prompt, or added or removed options) still gives a different hash.
- `screen` and the excerpt still show the real countdown.

| Input (screen the caller hashed → screen now) | Expected |
|---|---|
| The same prompt, countdown `1:39` → `1:12` | same hash; `--cancel` sends Esc and reports `cancelled` or `still-blocked` |
| The same prompt, countdown `0:59` → `45s`, or `9 seconds` | same hash |
| Countdown line present, and the prompt's command changes (`rm a` → `rm b`) | different hash → `screen-changed`, nothing sent |
| Countdown line → the countdown expired and the prompt is gone | different hash, or `not-blocked`; nothing sent |
| A line without the phrase holding a time: `sleep 1:30` → `sleep 1:31` | different hash (not masked) |
| A countdown line where text other than the time changes (`deny` → `approve`) | different hash (the words are still hashed; `approve` does not match, so its time is not masked either) |
| A countdown line appears where there was none | different hash |
| Uppercase or mixed case `Automatically Deny … in 1:39` | masked the same way |
| A narrow pane, with the phrase wrapped as in the live screen (`automatically deny` / `this request in 1:38,`), ticking to `1:12` | same hash |
| The phrase split between `automatically` and `deny`, and the time alone at the start of the next line (`in` / `1:38, to avoid`) | same hash |
| A border `│` at the start or end of each wrapped line | same hash when the time ticks |
| A wrapped countdown, and the prompt's command changes | different hash → `screen-changed` |
| A blank line between `this request in` and the time | not masked → different hash when it ticks (bounded) |
| A phrase needing more than 6 lines from `automatically` to the time | not masked |
| The words `automatically deny this request` with no `in <time>` | nothing masked |
| `sleep 1:30` on the line after a countdown block | not masked |
| A screen with no countdown line | hash equals 0.125.0's hash |
| Codex/Gemini member screens | unaffected unless they contain the phrase; if they do, the same masking applies (harmless) |

## 6. Verification (each new case fails on 0.125.0)

In `tests/test-blocked-watcher.sh`, using the existing fake `herdr` (`$HS/screen`, `$HS/status`, `$HS/keys`):

- **V1.** The screen is the default prompt plus the line `Claude Code will automatically deny this request in 1:39`. Take `h` from `hash_of`. Rewrite the screen with `1:12`. Then `answer --cancel --screen-hash h` reports `cancelled` (with `esc_unblocks`) and `$HS/keys` holds exactly one `esc`.
- **V2.** The same countdown screen, but the hash is taken and then the command line in the prompt is changed: `screen-changed`, and `$HS/keys` is empty.
- **V3.** The watcher's second wake on the countdown screen, with the countdown changed between the wakes, carries the second-time line (mirror the existing "the second wake at the same screen carries the second-time line" case).
- **V4.** Unit checks via `node -e` importing `screenHash`:
  - (a) `1:39` and `0:05` after the phrase hash equal;
  - (b) `45s` and `9 seconds` after the phrase hash equal;
  - (c) `sleep 1:30` and `sleep 1:31` with no phrase hash differently;
  - (d) the default no-countdown screen's hash equals a literal 64-hex value computed from 0.125.0's `screenHash`. The Implementor computes that value on the base commit before editing and pastes it into the test.
- **V6 (r2, two pane widths).** The same prompt rendered at two widths, each with the time ticking (`1:38` → `1:12`):
  - **wide:** `⚠ Claude Code will automatically deny this request in 1:38, to avoid blocking progress on an unattended session` on one line;
  - **narrow:** the live wrap, `⚠ Claude Code will` / `automatically deny` / `this request in 1:38,` / `to avoid blocking` / `progress on an` / `unattended session`.

  At each width the two times hash equal. At each width, changing the command line in the prompt hashes differently.
- **V7 (r2, split phrase).** `… will automatically` / `deny this request in` / `1:38, to avoid …` gives the same hash when the time ticks, and the same with a `│ ` prefix and ` │` suffix on every line.
- **V8 (r2, bounds).** Each of the following hashes differently when the time ticks:
  - a blank line inserted before the time;
  - a span that needs 7 lines;
  - the phrase with `approve` in place of `deny`.
- **V1 and V2** use the narrow wrap as well as the one-line form.

In `tests/test-chain-roles-other-harnesses.sh`:

- **V5.** One `--choice` case on a recognised prompt with a countdown line, where the countdown changes between the read and the answer. The choice is sent. If no recognised Claude prompt exists in that suite's fixtures, use any recognised prompt and add the countdown line, since the mask does not depend on the kind.

The full suite passes (`run-suite.sh`).

## 7. Assumptions to confirm while building

- **A1.** The countdown wording is `⚠ Claude Code will automatically deny this request in M:SS, to avoid blocking progress on an unattended session`, from live screens at two widths. Under one minute, the form (`0:45` or `45s`) is unverified, so both are masked.
- **A2.** `herdr agent read --source visible` returns plain text without ANSI (no stripping is done today and the hash works). If the countdown arrives with ANSI codes between the digits, report it rather than adding ANSI stripping to the hash.

## 8. Open questions (defaults taken)

- None for the user.
