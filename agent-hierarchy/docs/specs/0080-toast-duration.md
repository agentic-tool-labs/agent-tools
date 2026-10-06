# 0080 — Longer, configurable toasts

Implementer: implementor
Reviewer: reviewer

Version: the next minor above the stack tip at build time (stacked after 0077). Bump
`agent-hierarchy/.claude-plugin/plugin.json` and the root `.claude-plugin/marketplace.json` together.

Status: r1.

**Generic-text rule (binding).** Nothing written under this spec names a product, service, platform, customer,
ticket or incident.

## 1. Goal (user)

"Toasts should by default last longer but can be dismissed and can be configured in the plugin."

## 2. Facts (read; engine types 2.1.289; branch ah/0077-pane-tui)

- `$.ui.toast(text, options?: ToastOptions)`, where `ToastOptions = { timeoutMs?: number }`, default 4000. (r3)
  Cited from the engine types, version 2.1.289:
  `/private/tmp/claude-501/bundled-skills/2.1.289/ac9373a5eb47483760ba62e194944d0b/plugin-authoring/types/claude-code.d.ts`
  l.2349–2363 (the `toast` doc remark) and l.12068–12075 (`ToastOptions`). The other 2.1.289 bundle dir
  (`ca8e2e34…`) carries the same file. The Reviewer confirms the remark there; if it differs, report it.
  - **"A click takes it off, the pointer over it holds it."** This is **documented** in the doc remark of the `toast`
    member, so the user-facing doc line may state it.
  - While a pane opened with `holdToasts` is shown, a toast waits undrawn, and its timer has not started.
- **There is no API to dismiss or clear a toast, and no key for it.** The only dismissals are the user's click, or
  the timeout.
- Mod toast calls (register.tsx): l.101 `$.ui.toast(t.text)` for status toasts (reported, blocked, stalled; built by
  `viewModel`, view.ts:281–295), and l.142 `$.ui.toast(r.text)` for the band button's "not placed" notice.
  - (r3) There are two more inside 0077's pinned focus helper (l.16, :24), which are out of scope (D8). "Both toast
    calls" in this spec means l.101 and l.142 only.
- userConfig today (plugin.json): `status_entry` (boolean, default false). register reads it tolerantly
  (register.tsx:25: `true` or `"true"`), because a value set via configure arrives as a string (0073 E12).
  - E12: `register` receives the manifest default when nothing is stored, and update/enable/start never prompt.
- Read-only guard: an object-literal second argument to `ui.toast` passes the lexer (test-mod-readonly.sh:311–315
  rejects only callbacks with parameters).

## 3. Decisions

| # | Decision | Why |
|---|---|---|
| D1 | **Dismiss: already supported by the engine. A click on a toast removes it, and hovering holds it. Nothing is built.** The docs say so in one line. | There is no dismissal API to call. Inventing a dismiss affordance (for example a Pane or band button that "clears toasts") is impossible, because toasts cannot be cleared programmatically. |
| D2 | **Default duration: 10 s** (was the engine's 4 s). | The Orchestrator's proposal. Long enough to read a two-part line; short enough not to stack up. |
| D3 | **Config: a userConfig number, `toast_seconds`**, default 10. | The same mechanism as `status_entry`, and no prompt on update (E12). |
| D4 | **(r3) Parsing (tolerant, like `status_entry`).** The input counts as numeric only if it is a finite `number`, or a `string` that matches **`^\s*-?\d+(\.\d+)?\s*$`**. Never coerce with `Number()`, which maps `''`, `'  '`, `false` and `[]` to 0 and would silently turn toasts off. Then: **off only when the numeric value is exactly 0** (`0`, `'0'`, `' 0 '`, `'0.0'`); negative → 10 (the default); otherwise round to a whole second, then clamp: below 2 → 2, above 60 → 60. (r4: the host rejects `timeoutMs` above 60000, "1 to 60000", seen in the
build. So the ceiling is one constant of 60 s, and 61–120 would otherwise drop toasts silently.) Anything non-numeric (missing, empty or blank string, `'abc'`, `'1e3'`, NaN, Infinity, a boolean, an array, an object) → 10. | Strings arrive via configure. The clamp keeps a typo from making toasts flash or linger. A negative is treated as a typo, not as "off", so a misconfiguration stays visible; only an explicit 0 silences. |
| D5 | **Both toast calls use it** (status toasts and the band button's notice). | One knob, one behaviour. |
| D6 | **(r2, user ruling) Off = `toast_seconds: 0`: no ah toasts at all.** Neither toast call is made: no status toasts (reported, blocked, stalled), and no band-button "not placed" notice. | The user said "no ah toasts at all". **Ceiling, stated:** with toasts off, pressing `[ Pane ]` when the Pane cannot be placed gives no feedback. The Pane opens once there is room, as today. If that proves confusing, the band notice can be exempted, which is a one-line change. |
| D8 | **(r3, the Orchestrator's ruling) Stated exception: the two pinned focus-helper toasts (0077 Part 2's `focusMember`, register.tsx:16 and :24) are out of scope.** They keep the engine default (4 s), and they **still show when `toast_seconds` is 0**. | The security pin stays untouched: changing its text needs a new security ruling (0077 C6). Those toasts answer the user's own click. **Ceiling:** the setting governs the mod's status toasts and the band notice only; the docs line says "click feedback for a member focus is not affected". |
| D7 | **(r2) Off changes nothing else.** The Pane, the band, the status entry and the timeline show everything as today. The seen-toast bookkeeping (`keepSeen`) still runs, so turning toasts back on never replays old notices. | Off silences notices only. |

## 4. Changes

- `.claude-plugin/plugin.json` `userConfig` gains `toast_seconds`, with the same entry shape as `status_entry`:
  - `type: "number"`, `title: "Toast seconds"`;
  - description: "How long hierarchy notices stay on screen, in seconds (2–60); 0 turns them off. Click a notice
    to dismiss it early.";
  - `default: 10`.
- `mod/view.ts`: one new **pure exported function** maps the raw option value per D4. It returns **0 (off)** or an
  integer number of ms, 2000–60000. The Implementor names it.
- `mod/register.tsx`: `register` computes the value once from `options` (beside the `status_entry` read).
  - When it is 0, **neither** `$.ui.toast` call is made; never call `toast` with `timeoutMs: 0`.
  - Otherwise, both calls pass `{ timeoutMs: <value> }`.
  - The seen-key bookkeeping is unchanged in both cases. No other change.
- Docs: in the mod's README or doc section, one line on `toast_seconds` and one on dismissal ("click a notice to
  dismiss it; hover to keep it"). CHANGELOG, generic: "Toasts last 10 s by default, configurable with
  `toast_seconds` (2–60, 0 = off); click to dismiss."

## 5. Must NOT change

- Toast content, keys and `keepSeen`; when toasts fire; the band, the Pane, the status entry; the read-only guard
  (the object-literal argument already passes it); `status_entry`.

## 6. NEEDS-EVIDENCE (Implementor, sandboxed HOME/CLAUDE_CONFIG_DIR, as 0073 N4)

- **N1.** Install the base build, then update to this build. Record:
  - whether any prompt or dialog appears (expected: none);
  - the `options.toast_seconds` that `register` receives when (i) nothing is stored (expected 10), (ii) `30` is
    stored, (iii) `"30"` is stored via `configure --values-stdin`.

  Either 30 or `"30"` is fine for (ii) and (iii). D4 handles both. A prompt → stop and report.

## 7. Tests (view tests stay pure; plus a guard run)

| Input to the mapping function | Expected ms | Test |
|---|---|---|
| `undefined`, `null`, `''`, `'abc'`, `NaN`, `Infinity`, `true`, `{}` | 10000 | T1 |
| `10`, `'10'` | 10000 | T2 |
| `30`, `' 30 '` (trimmed), `'30'` | 30000 | T3 |
| `2.4` → 2; `2.6` → 3 (rounded) | 2000, 3000 | T4 |
| `1`, `'1'`, `1.4` | 2000 (clamped) | T5 |
| (r4) `61`, `'61'`, `120`, `999999` | 60000 (clamped; never above the host's 60000 limit) | T6 |
| the result is always 0, or an integer in 2000–60000 | — | T7 |
| (r3) `0`, `'0'`, `' 0 '`, `'0.0'` (exactly zero) | 0 (off) | T8 |
| (r3) `-1`, `-5`, `'-30'`, `-0.4`, `'-0.4'` (any negative) | 10000 (default, not off) | T9 |
| (r3) `0.4`, `'0.4'` (positive, rounds below 2) | 2000 (clamped; not off) | T10 |
| (r3) `''`, `'  '`, `false`, `[]`, `[0]`, `'1e3'`, `'0x10'`, `'10s'` (values that `Number()` would coerce, or that are not plain decimals) | 10000 (never off) | T11 |

- **R1:** with a non-zero value, `register` passes `{ timeoutMs }` to both toast calls, from one computed value. Use
  a stubbed `$` in the existing register tests. Assert that no toast call is made without it.
- **R3 (r2):** with `toast_seconds: 0`:
  - a doc change that would toast (reported, blocked, stalled) makes **no** `ui.toast` call;
  - the band button's not-placed path makes **no** `ui.toast` call;
  - the Pane rows, the band line and the status entry are unchanged from the toasts-on run;
  - turning the setting back on (a new register with 10) does not replay the notices seen while off.
- **R2:** `tests/test-mod-readonly.sh` passes unchanged, with its run recorded.
- **M1 (manual, user):** a toast shows for about 10 s; clicking it dismisses it; hovering holds it; after setting
  `toast_seconds` to 30, it lasts about 30 s; with 0, no notices appear while the Pane still updates.

## 8. User rulings (r2)

1. 10 seconds as the default: yes.
2. Add an off setting: `toast_seconds: 0` = no ah toasts at all (D6, D7).

Dismissing needs nothing new: clicking a notice already closes it, and hovering over it keeps it open. Nothing else
can be built for this, because the engine offers no way for a plugin to close a notice.

## 9. Acceptance

1. N1 recorded (no prompt).
2. T1–T11, R1–R3 are present (R3 also asserts the pinned helper text is byte-identical to the base), seen failing first where new, and green. The full ah suite and `claude plugin test`
   are green.
3. Docs and CHANGELOG generic; both manifests bumped.
