# 0082: the band shows whenever the status entry is visible (idle form)

Implementer: implementor
Reviewer: reviewer

Status: r2 (Reviewer findings addressed; changes marked **r2**) · Target: ah 0.120.0 (minor: visible behaviour change) · Base: main e694e7a (0.119.2)

## 1. Goal

The AbovePrompt band line, and its `[ Pane ]` button, show in every session where the status timeline entry is current and visible (a team is live, work is out, or a pipeline runs) — not only when a dispatch is working/stalled/overdue or a member is blocked. When none of the existing busy/alert forms applies, the band shows an **idle form**: the current timeline entry's own `text` (for an idle team, `1 live · 0 out`) in the entry's tone (`idle` for an idle team). This puts the `[ Pane ]` button within reach at all times a team is up.

## 2. Today (read from source)

- `mod/view.ts:213-232` `viewModel`: `band` starts `null`; it is built only inside `if (count(entry.out) > 0 || count(entry.blocked) > 0)`, and even then only when a dispatch is `stalled`/`overdue`/`working` or a member is `blocked`. Every other case leaves `band: null`.
- `mod/view.ts:324-337` `bandLine`: `null` band → `null` line.
- `mod/register.tsx:141-171`: `hasSurvey` → pass through; `bandLine(...) === null` → pass through (no band, no button); else the band text, plus the `[ Pane ]` Button when `bodyColumns >= PANE_BUTTON.minColumns` (40).
- `mod/view.ts:72-80` `current`: `null` (so `viewModel` → `null`, so no band) when there is no document, it has expired, the current entry is malformed or `visible` is false, or the session is in `member_sessions`.
- Producer `hooks/lib-status.mjs:345-356` `timelineEntry`: `visible = enabled && (live > 0 || out > 0 || anyPipeline)`; `text = "<live> live · <out> out"` plus ` · <n> blocked|overdue|stalled` for each non-zero count; `tone` = `bad` (overdue+stalled > 0) / `warn` (blocked > 0) / `work` (out > 0) / `idle`.

## 3. Change (one file of product code: `mod/view.ts`)

In `viewModel`, after the existing busy/alert selection, when `band` is still `null`, set the **idle form**:

- `head`: the current entry's `text` with control characters stripped (the same stripping `statusText` and the module's `str` reader apply). `tail`: `[]`.
- `tone`: the entry's `tone` when it is exactly one of the four `Tone` values (`bad`, `warn`, `work`, `idle`); otherwise `idle`.
- If the stripped text is empty, `band` stays `null` (no empty band carrying a lone button).

Requirements on the shape of the change:

- The existing busy/alert forms (stalled, overdue, blocked member, working, `+N more`, the tail fitting) and their selection order are untouched. The idle form is only a fallback for "no band was chosen".
- Do not add or change anything in `mod/register.tsx`, `mod/types/index.d.ts` (`View['band']` already fits: `{ tone, head, tail }`), the lexer guard, or the producer (`hooks/lib-status.mjs`). `View.band` keeps its type; `bandLine` keeps its behaviour.
- No new `$` call, import, or function literal in any hook body; `tests/test-mod-readonly.sh` must pass unchanged.

Illustrative only (not prescriptive) — the whole decision:

```
band === null && entry text (stripped) !== ''  →  { tone: knownTone(entry.tone) ?? 'idle', head: strippedText, tail: [] }
```

### 3.1 Exact idle band text and tone

| Situation (current entry) | Band text | Tone |
|---|---|---|
| Team live, nothing out (`live 1, out 0`) | `1 live · 0 out` | `idle` |
| Two members, nothing out | `2 live · 0 out` | `idle` |
| Pipeline running, no team (`live 0, out 0`, visible via `anyPipeline`) | `0 live · 0 out` | `idle` |
| `out > 0` / `blocked > 0` but no dispatch in `working`/`stalled`/`overdue` and no `blocked` member in `teams` (e.g. dispatches truncated, teams list disagrees with counts) | the entry text verbatim, e.g. `1 live · 1 out` | the entry tone, e.g. `work` |

At `bodyColumns >= 40` the text is followed by the `[ Pane ]` button (unchanged layout: text, gap 1, button); below 40 the text alone, cut with `…` by `bandLine` as today.

## 4. Invariants and negative cases

Must NOT change: member sessions see no band/Pane/toasts; `hasSurvey` yields; the width rule and `PANE_BUTTON`; every existing busy/alert band text and tone; the `status_entry` option (0.114.0) still governs only the status-bar entry (the band does not read it); toasts; Pane rows and sections; the auto-open-once rule in `register.tsx:124-131` (it already keys on `view !== null`, which this change does not alter).

The fallback rule ("when no band was chosen, use the entry text") is also satisfied by these inputs; each outcome:

| Input | Expected | At base |
|---|---|---|
| Member session (`sessionId` in `member_sessions`) | `viewModel` null → `bandLine` null | same (pin) |
| Entry `visible: false` (hierarchy off, nothing live) | null | same (pin) |
| `now >= expires_at` | null | same (pin) |
| No document / unparseable / schema ≠ 1 | null | same (pin) |
| `hasSurvey` true | band hook passes through (register.tsx:142) | same; no unit test hook exists for register.tsx in view tests — leave covered by unchanged code, note in report |
| `out 0, blocked 0`, entry text `1 live · 0 out`, tone `idle` | `{ text: '1 live · 0 out', tone: 'idle' }` | null → **fails at base** |
| Same, text with control chars `1 live\x1b · 0 out` | `{ text: '1 live · 0 out', tone: 'idle' }` | null → fails at base |
| Same, entry `text: ''` | null | null (pin) |
| **r2** Visible entry, `teams` absent, `[]` or not an array (view.test.ts:343-351 inputs; docText entry `1 live · 1 out`, tone `work`) | `{ text: '1 live · 1 out', tone: 'work' }` — the band follows the visible entry, not the teams list; the Pane still says it lists no team | null → **fails at base** (existing pin flips, see §5) |
| Same, entry `tone: 'purple'` | tone `idle` | null → fails at base |
| `out 1`, only dispatch in state `reported`, entry tone `work` | `{ text: <entry text>, tone: 'work' }` | null → fails at base |
| `out 2`, two working dispatches | `2 out · architect 1:30 of 5m · reviewer 0:30 of 5m`, `work` (unchanged) | same (pin) |
| Stalled / overdue / blocked member | existing texts (view.test.ts:154-175) | same (pin) |
| Idle form at 20 columns, text longer than 20 | cut to 20 with `…` | n/a (fails at base) |

## 5. Tests (`mod/tests/view.test.ts`, `mod/tests/vectors.ts`)

- Replace `view.test.ts:150-152` ("band: none while the entry has nothing out and nothing blocked") with the idle-form test. Note the `docText` helper's default entry `text` is `'1 live · 1 out'`; pass `text: '1 live · 0 out', tone: 'idle'` explicitly so the assertion is meaningful.
- **r2** `view.test.ts:343-351` ("a visible entry that lists no team draws one dim line saying so, and no band"): change only its band assertion from `null` to the idle form for that entry (`{ text: '1 live · 1 out', tone: 'work' }` with docText's defaults; if the test overrides text/tone, use those) for every no-team input it covers, and retitle it to say the band shows the entry text. Its Pane-line assertion is unchanged. This is the pin for the no-team case.
- Add one test per new row of the §4 table marked "fails at base"; add a single pin test covering member session, `visible: false` and expired returning `null` from `bandLine(viewModel(...))` (some of these may already be implied by vectors — an explicit band-level pin is still wanted).
- `vectors.ts`: every vector whose `viewModel` is non-null and whose expected `band` is `null` now expects the idle form for that fixture's entry at its `columns`. Update those values; list in the report which vector names changed and why. A vector whose expected `band` changes for any other reason is a defect — stop and report.
- Prove the new idle test can fail: it must fail against base `view.ts` (state that it did in the report).
- Run the mod test suite and `tests/test-mod-readonly.sh`; both green.

## 6. Version and docs

- `.claude-plugin/plugin.json` → `0.120.0`; `CHANGELOG.md` entry (one line: the band and its Pane button now show whenever a team is live; idle form shows the live/out counts). **r2:** also bump the root `.claude-plugin/marketplace.json:16` (repo root, the agent-hierarchy entry) from `0.119.2` to `0.120.0`.
- **r2** `agent-hierarchy/README.md:254` ("While a dispatch is out or a member is blocked, one line sits just above the prompt…"): reword the condition to whenever the hierarchy status entry is visible for this session (a team is live, work is out, or a pipeline runs), keeping the rest of the sentence. In the band subject table (`README.md:268-273`) add a row for the idle form: subject `idle` (nothing working, stalled, overdue or blocked), text `1 live · 0 out`. `README.md:257` (button only while the band shows) stays as is. Then grep `agent-hierarchy/docs/` for any other "band only while work is out/blocked" prose and correct it the same way.

## 7. Decisions made

- **Text source = the entry's `text`** (producer-owned, already `N live · M out[ · …]`), not a new string built in the mod: one implementation of the counts line, and the band and status entry never disagree.
- **Tone = entry tone (validated), else `idle`.** For the idle team this is `idle`, as asked; in the mismatch case (counts say busy, teams list shows nothing to name) the colour stays honest instead of reading idle over `1 overdue`.
- **Fallback also covers the mismatch case**, not just `out 0 && blocked 0`: the brief's rule is "band whenever the entry is visible", so no visible-entry state keeps a null band except empty text.
- **r2 No team listed, entry visible → band shows** (entry text, entry tone). The band tracks the visible entry, the same signal as the status entry and the Pane auto-open; the Pane already explains the missing team, and the `[ Pane ]` button is how to get there. Keeping null here would make a second, teams-derived visibility rule.

## 8. Open questions (user's call; defaults chosen, buildable as written)

- Pipeline-only, no team: band reads `0 live · 0 out  [ Pane ]`. Acceptable, or should it say something pipeline-specific? Default: as written (generic, producer text).
- With `status_entry` on, the idle band and the status-bar entry show the same text twice. Default: accept the duplication (band is the button's carrier).
