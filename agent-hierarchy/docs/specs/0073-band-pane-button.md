# 0073: band button that opens the hierarchy Pane; status entry opt-in

Implementer: implementor
Reviewer: reviewer

Version: `ah` 0.114.0. Builds on 0071 (`docs/specs/0071-hierarchy-status-view.md`), P3 (band, Pane, `/hierarchy-pane`) and P2b (status entry).

## 1. Goal

Two changes ship together as 0.114.0.

- **A. Pane button.** The band (`ui.render` on `AbovePrompt` in `agent-hierarchy/mod/register.tsx`) gets one Button. Pressing it does exactly what `/hierarchy-pane` does: it clears the session's `closed` mark, opens the `ah-status` Pane, and in a member session does nothing. The user asked whether `/hierarchy-pane` could be run by a mouse click. The status line (claude-tui-line, external text) cannot host a control; the band can.
- **B. Status entry opt-in.** The `⚠ ah: …` status entry becomes opt-in. The `status_entry` userConfig defaults to `false`. A missing value means off, and only an explicit true shows the entry. This supersedes 0071 P2b AC 6.

## 2. Facts this design rests on (read, not run)

- Plugin API 2.1.289 (`plugin-authoring/types/claude-code.d.ts`, lines 992–1092). `Button` is "every surface's pressable leaf". The terminal draws it as `[ label ]` and a desktop as a native button. "A click, a `hotkey`, the chord for its `action`, or Enter under the focus raises `ui.press`, its bottom `onPress`." `onPress` runs "in the plugin's own environment". The doc's own example closes over the hook's `$` (`onPress: press => $.ui.copy(...)`). The band site takes the focus "after ctrl+x tab, a click or `open({ focus })`".
- Placement (d.ts ~2382): "an unrequested pane seats at ≥144 columns… an asked one at any width." The plugin-authoring skill says a Pane opened by something the person did, such as a Button press, seats at any width. The live check is N2 below.
- Nothing in the API reports whether a Pane is currently shown, apart from the `UiPane` that `$.ui.open` returns.
- `register.tsx:115–120` is the `/hierarchy-pane` handler. In a member session it answers with text. Otherwise it sets `closed` to false, calls `$.ui.open({ id: 'ah-status', title: 'Hierarchy' })`, and answers with placed or not-placed text.
- `view.ts` `viewModel` returns `null` in a member session (via `current`). `bandLine` returns `null` when the view or `view.band` is null. `view.band` is non-null only when something is out or blocked. **The band, and so the button, is therefore drawn only when there is an out or blocked dispatch.**
- Guard `agent-hierarchy/tests/test-mod-readonly.sh` (383 lines) holds the one allow-list:
  - `ALLOWED_CALLS` already includes `state.set`, `ui.open`, `ui.toast`, `ui.resolve`.
  - `RENDER_ELEMENTS` lists Button as a known element, but `DRAWABLE="Box Text engine"`.
  - These planted cases must fail: `ui.render` (Pane) returning `<Button>` (l.321); `const { Button } = $.ui.resolve(e)` in `session.start` (l.327); `f($)`, where `$` is passed as an argument (l.293).
  - This form is allowed: `const r = ($, e, next) => $.fs.read(p)` (l.348).
  - 0071 §6.3 bans input-taking element types on purpose (spec l.1152, l.1216–1224).
- `status_entry` today is in `.claude-plugin/plugin.json:21–28` (`"default": true`), at `register.tsx:11` (`options?.status_entry !== false`) and `view.ts:84` (`statusText(..., statusEntry: boolean)`). E12 (`docs/specs/0071-evidence.md:234–277`) found that `register` receives the option with its manifest default filled in, that the stored value is read from user settings or `--settings` only, that an upgrade prints nothing, and that update, enable and interactive start never prompt.

## 3. Guard-change verdict (security-relevant)

**The button does not fit the current guard.** No new `$` call and no new event is needed, so `ALLOWED_CALLS`, `ALLOWED_EVENTS`, `MATCHERS` and the `claude plugin validate` hook-subset net are **unchanged**. The guard bans the element on purpose, though, and it also bans the `f($)` form that sharing the open path needs. Two narrow widenings are required, and nothing else may change.

**W1. `Button` is drawable in the band hook only.**
- Inside the `ui.render` hook whose matcher is `component=AbovePrompt`, `Button` may be destructured from `$.ui.resolve(e)` and returned as a JSX element.
- Everywhere else, Button stays forbidden exactly as now. That covers the Pane `ui.render`, `session.start`, `command.run`, `ui.close` and module scope. Planted cases l.321 and l.327 must still fail unchanged.
- The band hook's exemption covers only its own body. The span of any `on(...)` call nested inside it is excluded, so a Pane render registered inside the band hook gets no exemption. *(Added after review F3, as built.)*
- **Position rule: a Button never leaves the band hook.** *(Added after the F3 re-review. A span-based exemption let a Button value or element escape through an outer binding and be drawn in the Pane. This closes the class rather than documenting it as a ceiling.)* Inside the band span (excluding nested `on(...)` spans), the identifier `Button` may appear in exactly two positions. Every other occurrence fails.
  - **P-a. Destructure.** As a shorthand property, without renaming, in a `const { … }` pattern whose initializer is `$.ui.resolve(e)`. The `const` sits at the band hook's own function depth, not inside any nested function literal. `Button: X`, `X: Button`, `let`/`var` patterns, and any other initializer all fail.
  - **P-b. Tag.** As a JSX tag name, `<Button` or `</Button`, only where all of these hold:
    - (i) The tag lies inside the argument of a `return` statement that belongs to the band hook's own function body. If the hook is an expression-bodied arrow, the tag lies inside that body expression.
    - (ii) No function literal (`=>` or `function`) opens between that `return` (or arrow body start) and the opening tag `<Button`. *(Re-review 2, finding 4: (ii) applies to the opening tag only. A closing `</Button` follows its own `onPress` arrow, and it can only pair with an opening tag that was already checked. The closing tag is still held to (i), (iii), (iv) and (v).)* The Button's own `onPress` arrow opens after the tag, so it is unaffected. A tag inside an `onPress` body therefore fails.
    - (iii) Every `(` still open between that `return` and the tag is a grouping paren, not a call paren. A call paren is a `(` whose preceding token (whitespace and comments skipped) is an identifier, `)`, `]`, `?.` or `>` of a type argument. The keywords `return`, `if`, `while`, `for`, `switch`, `typeof`, `await`, `void` before a `(` make it grouping.
    - (iv) That return argument contains no assignment operator: `=`, `+=`, `-=`, `*=`, `/=`, `%=`, `**=`, `<<=`, `>>=`, `>>>=`, `&=`, `|=`, `^=`, `&&=`, `||=`, `??=`. Not counted as assignment: `==`, `===`, `!=`, `!==`, `<=`, `>=`, `=>`, and a JSX attribute `name=` (an identifier, with optional hyphens, directly inside a JSX opening tag before `=`). The `onPress` arrow body is exempt from (iv), because it is lexed under every existing rule and holds no tag.
    - (v) The tag is not inside a template literal. *(Re-review 2, finding 1: a tagged template, as in ``keep`${<Button …/>}` ``, is a call with no paren.)* The test: count the backticks in the segment that runs from that `return` (or arrow body start) up to the tag. If the count is odd, the tag fails.
      - Backticks inside `'…'` or `"…"` string literals and inside comments are not counted.
      - An escaped backtick inside a template's own text (`` \` ``) is not counted.
      - Closed nested templates contribute pairs, so they do not change the parity.
      - Accepted stricter side effect: a literal backtick in JSX text before the tag, in the same return, fails.
  - **Accepted stricter side effects:** a Button cannot be built inside `.map(...)`, a helper component or a variable and then returned, and it cannot be renamed on destructure. A band that needs more than one Button must write each one inline in the return.
  - **Ceiling (best effort, documented).** *(Orchestrator ruling after re-review 2.)* The position rule is a lexical approximation, not a parse. It stops the escape forms that are named and planted, not every way JavaScript can move a value.
    - Known gaps:
      - A same-file function component wrapper, `<Keep><Button …/></Keep>` where `Keep` stores `props.children` (re-review 2, R6).
      - The general class "JS syntax the lexer does not model".
    - Why this is acceptable: W1 gates no capability. A Button drawn outside the band still reaches only calls already on the allow-list (`onPress` is lexed under every rule), and its press argument `UiPressArgument` is plain data. The security-relevant rule, W2 (`$` passing), is closed.
    - Upgrade path: if W1 ever gates a capability, replace the lexical position rule with a real parse, for example TypeScript's own scanner or parser over `register.tsx`, rather than adding more patterns.
    - No further escape-hardening rounds on W1 below that trigger.
  - **Today's `register.tsx` passes.** The destructure is at hook depth. The tag sits under `return (` → JSX → `{wide ? (` → JSX. The only open parens are grouping (after `return` and after `?`). There is no assignment outside attributes, and `onPress` opens after the tag.
- A Button's `onPress` must be an inline arrow function. Its parameter, if it has one, must not be named `$`. Its body is lexed under every existing rule: the allow-list, no `$` destructuring or storing, and the banned tokens.
- The other input elements (`Input`, `Select`, `Link`, `Code`, `Markdown`, `Client`, `Svg`, `Raster`, `Image`) stay non-drawable everywhere.
- Why this stays inside the 0071 §6.3 item 6 ceiling: the guard exists so that an ordinary edit cannot act, send or answer by accident. A Button press is caused by the person, and its handler can reach only calls that are already allow-listed (`ui.open` and `state.set` are already made unasked by `tick`). The new class it opens is "code that runs on a person's press". That class is closed by the same allow-list, so no new action capability is added.

**W2. `$` may be passed to one kind of callee: a same-file `$`-first helper.**
- A call whose arguments include `$` passes the guard only if all of these hold:
  - (a) the callee is a bare identifier;
  - (b) that identifier is declared exactly once in `register.tsx`, as `const <name> = (async)? ($ …) => …`, with `$` as its first parameter;
  - (c) no other binding of that name exists in the file: no parameter, destructuring target, `let`/`var` or import, no `function`, `function*`, `function *` or `async function*` declaration, and no object or class method shorthand. Any `name(…)` whose closing paren is followed by a body (`{`, optionally after a `: type`) counts as a binding;
  - (d) `$` is the call's first argument.
- Every other `f($)` still fails. That includes planted l.293, `JSON.stringify($)`, member calls `x.f($)` and computed callees.
- A callee counts as a member call when the text before it ends in `.` or `?.`, ignoring whitespace (`x. h($)`, `x\n.h($)`). A spread `...` is not a member access.
- Known stricter side effect, accepted: a `h($)` call followed by `: {`-shaped text, as in the ternary `c ? h($) : {}`, reads as a binding and fails. Write that shape another way.
- *(The last three bullets and the binding list in (c) were added after review F1/F2 so the spec matches the guard as built.)*
- The helper's body is lexed under all the existing rules, so `$` never reaches code the lexer has not seen.
- This closes a class. It is not a one-off exemption, as 0071 §6.3 item 6 requires.

**Required new planted cases (each must fail on the lexer layer alone):**
1. `<Button>` returned from the Pane `ui.render` (already l.321, keep it).
2. `const { Button } = $.ui.resolve(e)` inside the `command.run` hook.
3. `<Button onPress={() => $.session.authorize()}>` inside the AbovePrompt hook. The disallowed call is caught inside `onPress`.
4. `<Button onPress={($) => …}>`, an onPress parameter named `$`.
5. `JSON.stringify($)` and `x.f($)`.
6. `f($)` where `f` is declared twice, or is also a parameter name somewhere else in the file.
7. `f($)` where `f` is declared as `const f = (env) => env.session.authorize()`: the helper's first parameter is not `$`.
8. `f(e, $)`: `$` is not the first argument.
9. Spaced member calls `x. h($)` and `new K(). h($)`, where an object or class method `h(env)` exists (review F1).
10. A nested `function* h(env)`, `function *h(env)` or `async function* h(env)` that shadows a valid `$`-first helper, called as `h($)` (review F2).
11. A Pane `ui.render` `on(...)` holding a `<Button>`, registered inside the AbovePrompt hook (review F3).

The following cases were added after the F3 re-review. Each uses an outer `let` and a Pane hook that draws the escaped value, unless noted otherwise:

12. Q1, a bare value: `B = Button` in the band hook; the Pane returns `<B onPress={() => 0} />`. Fails P-a/P-b on the bare `Button`.
13. Q2, a thunk: `mk = () => <Button onPress={() => 0} />` in the band hook; the Pane returns `mk()`. Fails P-b(i) and P-b(ii).
14. A stored element: `el = <Button onPress={() => 0} />; return next(e)` in the band hook; the Pane returns `el`. Fails P-b(i), because the tag is not in a return.
15. Assignment in the return: `return (el = <Box><Button onPress={() => 0} /></Box>)`. Fails P-b(iv).
16. A call wrap: `return keep(<Box><Button onPress={() => 0} /></Box>)`, where `keep` is a same-file `const`. Fails P-b(iii).
17. A renamed destructure: `const { Button: B } = $.ui.resolve(e)`, then `return <B onPress={() => 0} />`. Fails P-a.
18. A tag in onPress: `<Button onPress={() => { x = <Button onPress={() => 0} /> }} />` inside the return. Fails P-b(ii) on the inner tag.

The following cases were added after re-review 2:

19. R1, a tagged template: `const keep = (q, x) => { s = x; return x }`, and the band hook returns ``keep`${<Button onPress={() => 0} />}` ``; the Pane returns `s`. Fails P-b(v).
20. R2, a comparison that hides an assignment: `return (q <w, s = <Button onPress={() => 0} />)`. Fails P-b(iv) once `<` after an identifier is read as the less-than operator rather than a tag (an impl-defect fix, rule unchanged).

**Required new allowed forms (must pass):** the band hook returning `<Box><Text>…</Text><Button onPress={() => …}>…</Button></Box>`; a `$`-first helper declared once and called as `helper($)` from two hooks.

0071 §6.3 and §6.6 are amended by cross-reference only (see §6). The guard script keeps its single copy of the rules.

**Confidence: medium-high.** The threat model in 0071 §6.3 item 6 is "an ordinary edit that acts by accident, not a hostile author", and W1 and W2 keep every call on the allow-list. If the Orchestrator or user wants a second opinion on W2 in particular, the question for the Ultra-Advisor is: *"Does permitting `name($)` to a once-declared, `$`-first, same-file helper let an ordinary edit route `$` past the allow-list in a way the lexer cannot see?"* **Fallback if W2 is rejected:** drop W2 and repeat the two lines (set `closed` false, then open) in the button handler. That is a second copy of the behaviour, which goes against the user's DRY rule, so it is not the default.

## 4. Design A: the Pane button

**One implementation of "open the Pane on the person's request".**
- It is a single `$`-first helper in `register.tsx`, as allowed by W2. Both the `/hierarchy-pane` handler and the band Button's `onPress` call it.
- Its behaviour is exactly today's handler body at `register.tsx:116–119`:
  - member session → no state write, no open;
  - otherwise → set `closed` to false, then `$.ui.open({ id: 'ah-status', title: 'Hierarchy' })`.
- It yields the same three answer texts as today: member, placed and not-placed, verbatim.
- The command handler returns `{ text }` from it, with behaviour and text byte-identical to 0.113.0.
- The command never runs another command. Neither does the button.

**The Button.**
- It is drawn in the band row, after the band text. The row is a `Box` with `flexDirection="row"`; the band's existing `next(e)` stays below, in the existing column `Box`.
- It is non-`plain`, so the terminal shows a recognisable `[ Pane ]` affordance. Label: `Pane`. Element `key`: `ah-pane`.
- It has no `hotkey`. A bare digit in an empty composer answers a band Button that has one, which would clash with surveys. It also has no `action`, no `autoFocus` and no `variant`.
- **Width.**
  - The band text is fitted to `bodyColumns` minus the Button's drawn width (`[ Pane ]` is 8 columns) minus one gap column.
  - The label and the reserved width live in `view.ts` as one exported pure value or values, so the render and the view tests share one source.
  - When `bodyColumns` is below 40, no Button is drawn and the band renders exactly as in 0.113.0. That keeps a narrow band readable.
- **When it is drawn:** only when `bandLine` returns non-null. So it is never drawn in a member session (the view is null), never when a survey is up (the hook passes through, as now), and never when the band itself is hidden. This decision is listed under Q1.
- **When the Pane is already open:** the Button is still drawn. The API cannot tell whether the Pane is shown. Pressing again is idempotent: `closed` is already false, and `open` re-raises the same id. No hide or disable logic is added.
- **Press feedback:**
  - Placed → nothing more; the Pane appearing is the feedback.
  - Not placed → `$.ui.toast` with the same not-placed text the command returns (toast is already allow-listed).
  - Member → unreachable, because no button is drawn there. If it is reached anyway, the helper does nothing and nothing is toasted.
- `onPress` must not throw out: an error from `open` is swallowed silently, the same way `tick`'s errors are.

**Must NOT change:**
- the auto-open rules (`opened` and `closed` in `tick`);
- the `ui.close` hook;
- the Pane render;
- the toast seeding;
- `/hierarchy-pane`'s registration (name and description) and its answer texts;
- the AbovePrompt survey pass-through;
- the band tone styling (`toneProps`);
- `ALLOWED_CALLS`, `ALLOWED_EVENTS`, `MATCHERS`;
- `hooks.json`.

**Surfaces:**
- Terminal: mouse click (subject to N1), or ctrl+x tab to focus the band then Enter.
- Desktop Code tab: a native button.

## 5. Design B: status entry opt-in

- **Manifest.** In `agent-hierarchy/.claude-plugin/plugin.json`, `userConfig.status_entry` keeps exactly the E12 shape (`type`, `title`, `description`, `default`, the same keys in the same order). Only two values change:
  - `"default": false`
  - the description, to: `Show the hierarchy line (⚠ ah: …) in the status area. Off by default; turn it on if claude-tui-line's ah item does not already show it.`
- **Read rule.** At `register.tsx:11` the entry is on only for an explicit true, meaning the boolean `true` or the string `"true"`. Anything else is off: missing, `false`, `"false"`, or any other value.
  - The string form is accepted because the README's `claude plugin configure --values-stdin` example passes a string.
  - `view.ts` `statusText` and its boolean parameter are unchanged.
- **Upgrade behaviour.**
  - A user who never set the option loses the `⚠ ah:` line on 0.114.0.
  - A user who explicitly stored `true` keeps it. A user who stored `false` sees no change.
  - No config dialog is expected (E12). N4 confirms this for a changed default.
  - The fresh-install "1 userConfig option not yet set" line stays informational.
- **Tests (`agent-hierarchy/mod/tests/register.test.ts`).**
  - Add a case where options are omitted: the entry is not shown, and `w.shown` holds only `undefined` and no `⚠ ah:` text.
  - The string `"true"` form has no register test. *(Amended after review F5: the `claude plugin test` harness rejects a non-boolean option, so the test cannot be written.)* The read rule still accepts it. Only N4(iii) verifies it end to end.
  - Keep the `false` and `true` cases at l.189 and l.197.
  - Every existing register test that asserts a shown entry without passing options must now pass `{ options: { status_entry: true } }`. The Implementor finds them all; none may be deleted to make the suite pass.
- **Unaffected.** `view.test.ts` l.106 is unchanged because `statusText`'s signature is unchanged. `mod/tests/vectors.ts`, `mod/tests/fixtures.ts`, `tests/fixtures/status/*.json` and `tests/test-mod-fixtures-drift.sh` are also unchanged. The status fixtures are inputs, and the vectors call `statusText` with an explicit boolean. If any vector's expected `statusText` was computed through the register default, that is a spec gap: stop and report it.

## 6. Docs

- **`agent-hierarchy/README.md`.**
  - l.223–227: the status entry is off by default; turn it on with `/config`, or `echo '{"status_entry":"true"}' | claude plugin configure ah@agent-tools --values-stdin`; restart afterwards; user scope only. Keep the existing scope sentence.
  - l.343: same meaning, with "on" and "off" swapped.
  - Band section: add one sentence saying the band shows a `[ Pane ]` button (click it, or ctrl+x tab then Enter) that opens the hierarchy Pane, the same as `/hierarchy-pane`.
- **`agent-hierarchy/CHANGELOG.md`**, new `0.114.0` section on top:
  - Added: the band's `[ Pane ]` button.
  - Changed: the status entry is now opt-in. **Upgrade note:** if you relied on the `⚠ ah:` line and never set `status_entry`, it disappears; set it to true to keep it.
- **Spec `0071-hierarchy-status-view.md`.** Add one short note under P2b AC 6 (l.2368) and one beside the P2b README bullets (l.2304–2312): "Superseded in 0.114.0 by spec 0073 §5: the entry is opt-in." Add one note at the end of §6.3 item 6 and in §6.6 by the planted-case list: "Widened in 0.114.0 by spec 0073 §3 (W1, W2)." Do not rewrite 0071's history.
- **Versions.** Set `0.114.0` in both `agent-hierarchy/.claude-plugin/plugin.json` and the agent-hierarchy entry in the root `.claude-plugin/marketplace.json` (l.16). Both must move together.

## 7. Acceptance

Automated, all green:
1. `tests/test-mod-readonly.sh` passes with W1 and W2. All existing planted cases still fail. The new planted cases 1–20 in §3 each fail on the lexer layer alone, and the new allowed forms pass.
2. `tests/test-mod-plugin-test.sh` (`claude plugin test` on the plugin root) passes, with these register tests added:
   1. `/hierarchy-pane` behaviour and texts are unchanged (the existing tests at l.303–321 and l.406–414 pass unmodified).
   2. Band press. With a fixture that draws the band (for example `work`), the rendered AbovePrompt contains a Button keyed `ah-pane`. Pressing it writes `closed=false` before one `ui.open({ id:'ah-status', title:'Hierarchy' })`. With `placed=false` it toasts the not-placed text; with `placed=true` it toasts nothing. **How the press is driven depends on N3.**
   3. No Button in a member session (`member-session` fixture), none when `hasSurvey`, none when `bodyColumns < 40` (where the band text equals the 0.113.0 output for that width), and none when `bandLine` is null.
   4. The status entry: omitted options → not shown; `true` → shown; `false` → not shown. The string `"true"` is verified by N4(iii) only, because the harness rejects non-boolean options *(amended after review F5)*.
3. The `view.ts` tests cover the reserved-width fitting: at `bodyColumns ≥ 40` the band text width is ≤ `bodyColumns − 9`.
4. `claude plugin validate agent-hierarchy` lists exactly the same hooks as 0.113.0.

Manual checks by the user, in plain words:
- **M1.** In a terminal narrower than 144 columns, with an agent out, click `[ Pane ]` on the line above the prompt. The hierarchy Pane opens. Close it, then click again: it reopens.
- **M2.** Press ctrl+x then tab to put focus on that line, then press Enter. The Pane opens.
- **M3.** After upgrading, the `⚠ ah:` line is gone and no settings dialog appeared. Run `/config`, turn on Status entry, restart: the line is back.

## 8. NEEDS-EVIDENCE

These are for the Implementor to run before or while building. The results route back here only if they contradict the default stated with them.

- **N1. Does a terminal click reach a band Button?**
  - Run: in a live session at 0.114.0, click `[ Pane ]` (this is M1).
  - Yes → as designed.
  - No (the terminal does not deliver the click) → keep the button, because the keyboard path and the desktop still work. The README sentence then reads "ctrl+x tab, then Enter". Report back; no re-dispatch is needed.
- **N2. Does a press-opened Pane seat below 144 columns?**
  - Run: M1 in a terminal of about 100 columns.
  - Seats → as designed.
  - Waits undrawn → re-dispatch the Architect (the open may need `focus`, or the press may not count as "asked").
- **N3. Can `claude plugin test` drive a band press?**
  - Check the mock harness (`claude plugin test` / the plugin-authoring reference) for a way to raise `ui.press` on a rendered Button, or to reach a rendered element's `onPress`.
  - Yes → AC 2.2 is a register test.
  - No → AC 2.2 becomes: (a) a register test that the rendered band contains the `ah-pane` Button, plus (b) the helper's behaviour proven through the command path (AC 2.1), plus (c) M1. Report which one applied.
- **N4. No prompt and the right value when the default changes on upgrade.**
  - Run: in a sandboxed `HOME`/`CLAUDE_CONFIG_DIR` (as `test-mod-plugin-test.sh` does), install 0.113.0, then update to the 0.114.0 build. Record whether any prompt or dialog appears, and what `options.status_entry` the register receives in three cases: (i) nothing stored, (ii) `true` stored before the update, (iii) `"true"` stored via `configure --values-stdin`.
  - Expected: no prompt; (i) false, (ii) true, (iii) true or `"true"`.
  - A prompt appears, or (ii) or (iii) is lost → re-dispatch the Architect.
  - Every Claude process the probe started must be gone afterwards: check with `pgrep -fl claude` and kill any of the probe's sandbox runs still alive.

## 9. Open questions for the user (defaults chosen; the build does not block on these)

- **Q1. Button only when the band shows.** The band, and so the button, appears only while a dispatch is out or blocked. A Pane button that is always present would mean a new permanent line above the prompt whenever a hierarchy exists, which is a visible product change. The default is no. The user may want it.
- **Q2. Label.** `[ Pane ]`. The alternatives are a one-glyph `plain` icon, which is smaller but less discoverable, or `[ Hierarchy ]`.
