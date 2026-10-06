# 0077 — TUI-style Pane: colored section boxes, colored activity icons, grouped by workstream; click a member to focus it

Implementer: implementor
Reviewer: reviewer

Version: the next minor above the base's `plugin.json` version (0.117.0 when the base is 0.116.0). Base: the tip of
`ah/0076-peer-progress` once 0076 is built. If the base is not a 0.116.x version, stop and report. Bump
`agent-hierarchy/.claude-plugin/plugin.json` and the root `.claude-plugin/marketplace.json` together.

Status: r2, rewritten for the user rulings.
- Q1 = Mockup C (boxed sections), with "colors per box" and "indicators color coded".
- Q2 = keep `[ Pane ]`.
- Q3 = investigate member-click. §8 is concrete, on `herdr agent focus <target>`.

r3 (Reviewer 4u91):
- Part 1: HIERARCHY is a box with a row; TEAM may be a title-only box; I3 is scoped; the palette is per team; lib-config
  references.
- Part 2:
  - the team-file re-read is dropped (wrong path in worktree sessions; no trust gained);
  - the literal herdr name pattern is used;
  - W4 is replaced by an exact-text helper;
  - **Part 2 is infeasible if the mod has no process API** (E3c);
  - §8.9 = the Reviewer's four questions.

r4 (evidence joi6 folded in):
- **E1:** no key throws, the bogus key included. The headless kit never paints, so the per-theme color check is now a
  user manual check (M1).
- **E3a:** herdr takes a name or a pane id. **E3b:** it switches workspace and tab; an unknown target exits 1.
- **E3c:** `$.process.run` exists, with `init.timeoutMs` (default 30 s, max 10 min). **Part 2 is feasible.**
- **E3d:** answered.
- A Button's hover needs a keyed Box.

r6 (the Ultra-Advisor ruled **allow with changes**; the user confirmed Q4: the click is the consent, with no opt-in
setting): C1–C7 are applied in §8.2, §8.5, §8.6, §8.9 and §10. Part 2 builds after Part 1.

**Build gate.** Part 1 (§4–§7, the look) can be built once E1 has been run. **Part 2 (§8, member-click) must not be
built until E3 has been run AND the Ultra-Advisor has answered §8.9 AND the Orchestrator re-dispatches with that
ruling.** Part 1 must not depend on Part 2.

**Generic-text rule (binding).** Nothing written under this spec names a product, service, platform, customer,
ticket or incident: code, tests, docs, CHANGELOG, commits. (The terminal multiplexer's binary name appears in code
and docs only as the argv constant it already is in roster.mjs.)

## 1. Goal

- Each section of the Pane is a bordered box, and each box has its own border and title color.
- Each member and dispatch row starts with a one-cell activity icon. Its **shape** tells the state, so it works with
  no color, and its **color** tells the tone.
- Members, and the dispatches sent to them, are grouped by workstream (stream). Members with no stream are under the
  team.
- (Part 2) Clicking a member's name focuses that member's terminal pane, when the member runs in a multiplexer pane.

## 2. Facts (read on `ah/0076-peer-progress`)

- **Row data.** `mod/view.ts` is the single, pure source of row data.
  - `Tone = 'bad'|'warn'|'work'|'idle'`.
  - `PaneRow`: `text`, `member {tone,name,kind,route,state}`, `dispatch {tone,slug,label,eta,pct,elapsed,state}`.
  - `paneRows(view, columns, why)` → `{text,tone}[]`, always at least one row (0075). It uses `drawRow` and `fitCut`,
    with breakpoints at 40 and 28 columns.
- **Drawing.** `mod/register.tsx:169–176` is the Pane render: one `<Text {...toneProps(tone)}>` per row in a column
  `<Box>`.
  - `toneProps`: bad → `{color:'warning',bold}`; warn → `{color:'warning'}`; work → `{}`; idle → `{dimColor}`.
  - The band (register.tsx:119–143) draws a `[ Pane ]` Button that calls the `$`-first helper `openPane`.
- **Engine.** `Box` has `borderStyle`, `borderColor` (via hover types; base-prop support is E1), `paddingX`,
  `flexDirection`. `Text` has `color`, `bold`, `dimColor`, `inverse`.
  - `color` is "a theme key or a raw color". Only `warning` is documented.
  - `Button` has `plain`, `label`, `dimColor`, `hover` and `onPress`, but **no `color`/`bold`**.
  - `$.process.run(argv, init?)` → `{exitCode, stdout, stderr}`. It appears in the bundled engine types
    (claude-code.d.ts 2.1.289, about l.3538–3557), but **not** in the mod's own `mod/types/index.d.ts`.
    - (r4, E3c) It exists, with `init.timeoutMs` (default 30 s, max 10 min). The mod's `index.d.ts` is a stale
      subset.
    - Part 2 adds the `process.run` signature to `mod/types/index.d.ts`, verbatim from the engine types, and nothing
      else from `process`.
    - No capability or prompt was reported. M2 confirms that a click runs with no prompt. If it prompts, report it;
      the prompt is acceptable, as it is extra consent.
- **Read-only guard.** `tests/test-mod-readonly.sh`, plus `walk` in `mod/tests/register.test.ts`.
  - Pane drawables: `Box`, `Text`, `engine`. `Button` is allowed only in the band hook (0073 W1). `$` may go only to
    `$`-first helpers (W2).
  - The allowed calls include `state.set`, `ui.open`, `ui.toast`, `ui.resolve`. There is no `process.*`.
- **Status members** (`describeMembers`): `name, role, label, kind, route, session_id, live, activity, activity_at,
  blocked_by, blocked_note`, plus 0076's `last_tool, last_tool_at`. There is no `stream`, `transport` or
  `transport_id`.
- **Team file** (`<hier>/teams/<team>.json`): member records carry `name`, `transport` (`herdr`|`tmux`|`terminal`),
  `transport_id` and `stream` (set by `spawn-one --stream`, roster.mjs:5256–5259).
  - roster.mjs drives herdr agents **by member name**: `herdr agent get|read|send-keys <member.name>`.
  - Names are validated by `validateHerdrName` (lib-config.mjs:276–285), whose pattern is
    `^[a-z][a-z0-9_-]{0,31}$` (l.278). The team-name pattern is `isTeamAliasShape` (lib-config.mjs:853).
  - Team files live in the team home `teamHomeDir` (lib-roster.mjs:100–103): the main checkout's hierarchy dir, even
    for a worktree session, whose status.json sits in the worktree pool.
- **herdr** (the Orchestrator ran E2): `herdr agent focus <target>` ("Focus an agent", one positional target) exists.
  `herdr pane focus --direction …` moves to a neighbor only, so it is unusable.

## 3. Mockups (ruled: C, colored)

`[c:X]` = the box border and title in color key X (§4.2). `{tone}` = the icon colored by tone. Titles are the first
line inside the box (Box has no border-title prop; see §4.3). Illustrative.

60 columns:
```
╭──────────────────────────────────────────────────────────╮ [c:hier]
│HIERARCHY                                                 │
│plan → build → review   step 2/3                          │
╰──────────────────────────────────────────────────────────╯
╭──────────────────────────────────────────────────────────╮ [c:team]
│TEAM demo                                                 │
│{work}● lead       orchestrator · peer · working 2m       │
│{idle}○ helper     task-runner · peer · idle 4m           │
╰──────────────────────────────────────────────────────────╯
╭──────────────────────────────────────────────────────────╮ [c:stream1]
│STREAM api                                                │
│{work}● builder    implementor · peer · working 6m · last…│
│{warn}■ checker    reviewer · peer · blocked              │
│  {work}↳ fix-auth → builder | eta medium | 60% | 6m | wo…│
│  {bad}▲ add-tests → checker | eta small | 120% | overdue │
╰──────────────────────────────────────────────────────────╯
╭──────────────────────────────────────────────────────────╮ [c:stream2]
│STREAM docs                                               │
│{idle}× writer     docs-writer · pane · gone              │
╰──────────────────────────────────────────────────────────╯
```
Below 40 columns, the boxes are dropped (§4.4); the title line keeps the box color. 30 columns:
```
[c:hier]HIERARCHY
step 2/3
[c:team]TEAM demo
{work}● lead working 2m
{idle}○ helper idle 4m
[c:stream1]STREAM api
{work}● builder working 6m
{warn}■ checker blocked
  {work}↳ fix-auth working
  {bad}▲ add-tests overdue
[c:stream2]STREAM docs
{idle}× writer gone
```
(Part 2: a clickable name is shown with `hover: {underline: true}`. It looks the same at rest.)

## 4. Design, Part 1

### 4.1 Model (view.ts, pure)

- One new **pure exported function in view.ts** turns a view plus a column count into an ordered list of
  **sections**: `{section: 'hierarchy'|'team'|'stream'|'dispatches', key: string, title: string, rows: Row[]}`.
  - Each row carries: `icon` (one character), `tone`, `text` (drawn without the icon, already cut to the inner width),
    an indent (0 or 2), and (Part 2) `focus?: <member name>`.
  - The Implementor names it. It reuses `drawRow`/`fitCut` for the row text.
- The 0075 rules move with it.
  - A null or malformed view, or an empty pane, gives **one** borderless section with today's single idle row and
    today's text. The ≥1-row guarantee and no-throw hold.
  - `paneRows` stays exported and keeps its contract (tests and the band rely on it). It may be built on the new
    function, or left as is.
- `PaneRow` member and dispatch rows gain `icon`. Tone rules are unchanged.

### 4.2 The one style table (view.ts, exported, pure)

There is **one exported table**, holding every new icon, icon color and box color. register.tsx only applies it.
(r3) Scope: the table's icon glyphs and its color keys (box palette and icon colors) appear nowhere else in `mod/`.
Existing literals are out of scope and stay where they are: the bar `█░`, `→`, `—` in view.ts, and `'warning'` in
`toneProps`.

| Row state | Icon | Icon color (theme key) | Text props (unchanged `toneProps`) |
|---|---|---|---|
| member `working` | `●` | `success` | work |
| member `idle` | `○` | none, dim | idle |
| member `blocked` | `■` | `warning` | warn |
| member gone (`live === false`) | `×` | none, dim | idle |
| member `unknown` | `?` | none, dim | idle |
| dispatch, work or idle tone | `↳` | the same as its tone (work → `success`, idle → dim) | its tone |
| dispatch, warn tone | `↳` | `warning` | warn |
| dispatch, stalled or overdue (`bad`) | `▲` | `error` | bad |

**Box colors**, an ordered palette:
- `hierarchy` → `claude`, `team` → `permission`.
- Streams take, by their name-sorted index **within their team** (r3), `STREAM_PALETTE = ['suggestion', 'remember', 'ide', 'planMode']`, cycling.
- `dispatches` → none (`borderDimColor`).
- Box colors never use `success`, `warning` or `error`: those mean status.
- **These keys are assumed; E1 decides them.** The title line is always bold, so a key that is not honored degrades
  to a bold default-colored title and a default border, never to anything unreadable.
- **Icons are static** (no spinner). Each is a single code point, `width()` 1. Ambiguous-width ceiling: the same
  exposure as today's bar glyphs. The upgrade path is an ASCII set behind a setting.

### 4.3 Boxes (register.tsx)

- **≥ 40 columns:** each section is `<Box flexDirection="column" borderStyle="round" borderColor={…}>`.
  - Its first child is the title `<Text bold color={…}>`.
  - Then one row each: `<Box flexDirection="row">` holding an icon `<Text>` with the icon color, then the row
    `<Text {...toneProps(tone)}>`, after the indent.
  - Inner width = `columns − 2`. Row text is cut to `inner − 2` (the icon plus a space), minus the indent.
- **No empty boxes, with one exception (r3).** A section with no rows is not emitted, except TEAM.
  - HIERARCHY is emitted only when there is a pipeline, and its pipeline text is a **row** (a text row: no icon,
    indent 0), not part of the title. So it is never title-only.
  - TEAM is emitted whenever the team has any member, even when every member is in a stream. It is then a
    **title-only box**, because it names the team the stream boxes belong to.
  - No streams → no stream boxes. No leftover dispatches → no DISPATCHES box.
- The Pane uses only `Box` and `Text` (Part 1), plus the props `borderStyle`, `borderColor`, `borderDimColor`,
  `flexDirection`, `color`, `bold` and `dimColor`. **There is no guard change in Part 1.**

### 4.4 Narrow widths

- **Below 40 columns: no borders.** Each section becomes its title line (bold, in the box color), then its rows,
  exactly as in the 30-column mockup.
  - 40 is the existing member breakpoint. A border costs 2 of every row's columns, plus 2 rows per section. Below 40
    that cuts most member state text.
- Row text below 40 is today's narrow form: `{name} {state}` with 0076's ` · last …` dropped, and dispatches as
  `{slug} {state}`.
- The icon and indent are never cut away. Every drawn line is ≤ `columns` by `width()`.

### 4.5 Grouping by stream (lib-status + view.ts)

- `describeMembers` emits **`stream`**: the team-file member's `stream`, cleaned and cut to `NAME_CAP`, or null.
  This is schema 1 additive. Add a `docs/status-file.md` members row.
- Section order per team:
  1. HIERARCHY (when there is a pipeline);
  2. TEAM `<team>` with the unstreamed members;
  3. one STREAM per distinct stream, sorted by name: its members, then the dispatches whose `member` is one of them
     (indented);
  4. DISPATCHES with the leftovers.
- A `stream` that is not a non-empty string counts as no stream. A done stream still groups (the status file carries
  no stream state, and none is added).

## 5. Must NOT change (Part 1)

- Tone rules and `toneProps` values. The band, `bandLine`, `[ Pane ]` and 0073 W1/W2 (Q2 ruled). Toasts, the status
  entry, the timeline, the schema number, expiry.
- The read-only guard and its tests (Part 1 adds no element, call or `$` use).
- 0075's ≥1-row and null-row texts; 0076's progress text (it is only placed and cut).

## 6. NEEDS-EVIDENCE (Implementor, sandbox, before the build)

- **E1. Theme keys and box props.** In a scratch plugin render, in a light and a dark theme, report "colored",
  "default" or "throws" for each of:
  - (a) `<Text bold color=K>`;
  - (b) `<Box borderStyle="round" borderColor=K>`, and `borderDimColor`.

  Use K ∈ `claude, permission, suggestion, remember, ide, planMode, success, warning, error`, plus one bogus key.
  Also check:
  - (c) a row `<Box flexDirection="row">` of two `<Text>` inside a bordered Box at 40 and 60 columns: no wrap, and
    the inner width is `columns − 2`;
  - (d) (for Part 2) a `<Button plain label=X>`: the cells it draws equal `width(X)`, with no added padding, and its
    `hover.underline` works.

  **Decides:**
  - any throw → stop and report (the Architect amends);
  - a key drawn default in either theme → drop it from the palette, or from the icon column, and use the next honored
    key in list order;
  - `borderColor` not honored at all → borders stay default, and the title color carries the box color;
  - fewer than 2 honored palette keys → streams share one color;
  - `success`/`error` not honored → working icons dim-free default, and `bad` icons `warning` + bold;
  - (c) wraps → report;
  - (d) only gates Part 2.

## 7. Invariants and negative cases (Part 1; view tests pure)

| Case | Expected | Test |
|---|---|---|
| no streams | no STREAM section; members in TEAM | G1 |
| two streams plus one unstreamed member | TEAM, then STREAM a, then STREAM b (by name) | G2 |
| a dispatch to a streamed member | in that stream, after its members, indented 2 | G3 |
| a dispatch to an unknown member | DISPATCHES | G4 |
| no leftovers | no DISPATCHES section; no empty section except TEAM | G5 |
| (r3) every member streamed | a title-only TEAM box, then the STREAM boxes | G8 |
| (r3) a pipeline present | a HIERARCHY box with a title and one pipeline row; no pipeline → no HIERARCHY box | G9 |
| (r3) the same stream name in two teams | each team colors its streams from its own index | I5 |
| `stream` not a non-empty string | no stream; no throw | G6 |
| a stream name with control characters or too long | cleaned and cut (lib-status) | G7 |
| each state, gone, blocked, overdue | the table's icon and icon color; the text tone as before | I1 |
| every icon | one code point, `width()` 1 | I2 |
| (r5) table literals stay in the table | (a) each table glyph as a **quoted string literal** (`'●'`, `'○'`, `'■'`, `'×'`, `'?'`, `'↳'`, `'▲'`, either quote style) appears in `mod/` only inside the table; (b) `register.tsx` contains no quoted literal of any table color key (the box palette, `success`, `error`), so the drawing gets every new color from the table. `'warning'` in toneProps and other existing uses in view.ts (e.g. l.248 `'permission'`) are out of scope. Bare `?` (TS syntax) is never matched | I3 |
| streams beyond the palette length | colors cycle; no undefined color | I4 |
| ≥ 40 columns | every section bordered; every row line ≤ columns − 2 | D1 |
| < 40 columns (30, 39) | no borders; every line ≤ columns; the icon is kept; ` · last` dropped | D2 |
| 40 columns exactly | bordered (the boundary) | D3 |
| null, malformed or empty view | one borderless section with 0075's row; no throw | D4 |
| the 60-column sample | the row texts match §3 (snapshot) | D5 |
| the read-only guard | unchanged and passing | R1 |

**Must NOT happen:** an empty box other than a title-only TEAM; a box in `success`/`warning`/`error`; an icon whose shape alone does not
distinguish the states; a spinner; a borderline row wrapping; a color chosen outside the table.

## 8. Part 2: click a member's name to focus its pane (DESIGN ONLY; gated)

### 8.1 Argv

- Exactly `['herdr', 'agent', 'focus', <target>]`, via `$.process.run`. **No shell**, no `sh -c`, no string
  concatenation into one argument, and no other flag.
- The binary is the literal `'herdr'`, resolved on PATH. roster.mjs invokes herdr the same way.
  - **Ceiling:** a PATH-planted `herdr` runs, exactly as it would for every roster command today. This adds no new
    trust in PATH.
- `<target>` = the clicked member's **name**, from the view, validated per §8.2 (r3: there is no team-file re-read).
  roster.mjs addresses herdr agents by member name (`agent get|read|send-keys <name>`), so `agent focus` is assumed to
  take the same name. **E3a confirms or refutes this, and reports the name's scope.**
- **Feasibility gate (r3):** if E3c finds that this mod cannot call `$.process.run` (absent from the engine the mod
  runs under, or behind a capability or a prompt a mod cannot meet), **Part 2 is not feasible: the member-click is
  dropped**, and §8.2–§8.9 lapse. No other process path (`$.command.run` of a shelling command, `$.agent.spawn`) is
  an allowed substitute.
- `init`: exactly `{ timeoutMs: 5000 }` (E3c). The output is ignored apart from `exitCode`. An unknown target exits 1
  (E3b), which counts as a failure.
- (r4, E3a) herdr takes a name or a pane id. **The name is kept:** its pattern is exact and already validated, while
  the pane-id shape has no specified pattern.
  - **Ceiling:** if two herdr agents ever share a name (for example two checkouts), the click may focus the other one.
    Nothing worse happens: the focus changes, and nothing is sent.
  - The upgrade path: target `transport_id`, with a pattern taken from herdr's id format.
- (r4, E3b) The focus also switches workspace and tab. That is the wanted behaviour.

### 8.2 Validation of `<target>` (all must hold, else no process runs)

1. It is a string matching **exactly `^[a-z][a-z0-9_-]{0,31}$`**, the pattern of `validateHerdrName`
   (lib-config.mjs:278).
   - (r6, C1) The regex literal `/^[a-z][a-z0-9_-]{0,31}$/` is written **inside the pinned helper text** (W4), never
     as a constant outside it: an outside constant could be redefined (for example to `/.*/`) without touching the
     pin. F10 compares the pinned literal with lib-config.mjs:276–278.
   - (r6, C2) The helper first checks `typeof name === 'string'`, then the pattern.
   - The pattern already excludes a leading `-`, whitespace, control characters, `/`, `.` and anything over 32
     characters. F2 pins those cases.
2. The clicked row is a member whose status record has `focusable === true` (§8.4) and `live !== false`, and its
   `session_id` is not this session's (`$.session.id()`).

### 8.3 No team-file re-read (r3)

- Dropped. The team home is the main checkout's hierarchy dir (`teamHomeDir`, lib-roster.mjs:100–103), not the dir
  beside a worktree session's status.json. So the mod could only locate the team file from a status field, and that
  is the untrusted input. The team file and status.json also share writers and the same user, so the re-read adds no
  trust.
- What bounds the risk: the fixed argv, no shell, and the strict name pattern. The worst case driven by data is
  focusing some other herdr agent (see E3a on name scope).
- `focusable` is computed hooks-side by lib-status, which reads the team file through its normal team loading (so
  the home is correct). It decides only whether to draw the affordance.

### 8.4 Which members get the affordance

- `describeMembers` emits **`focusable: boolean`**: true only when the team-file record (lib-status's normal team
  loading, from the team home) has `transport === 'herdr'`, a non-empty `transport_id`, and a name passing §8.2.1. This is schema 1 additive; add a status-file.md row. It is
  display only.
- **Herdr members, live, not the viewer's own session** → the name is clickable.
- **tmux members → no affordance.** Focusing one needs `select-window` plus `select-pane`, and possibly another tmux
  session. That is a second argv and allow-list. Defer it until asked.
- **terminal/plain members, members with no transport id, gone members, pane-kind members with no herdr record, and
  subagent roles → no affordance.**
- **Member sessions** (the mod running inside a role session) → no affordance, matching 0073's `openPane` rule.
- **Below 40 columns:** still clickable (the name is the target, and the width is unchanged).

### 8.5 Drawing the affordance

- For a focusable member row, the name part of the row is drawn as `<Button plain label={name} hover={{underline:
  true}} dimColor={tone === 'idle'} onPress={…}/>`. The icon stays a colored `<Text>`, and the rest of the row stays
  a toned `<Text>`, so colors are kept (Button has no color prop, so only the name loses the tone color).
- (r4) Hover styles apply only inside a keyed Box, so the Button sits in `<Box key={'ah-focus-' + name}>`. The key is
  the validated name, which is unique per row.
- The `onPress` is an inline arrow that calls the **one `$`-first focus helper** with the member name only, the same
  identifier as the Button's `label` (C4). Its try/catch, if any, has an **empty** catch.
- (r6, C5) The feedback lives **inside the helper**, and appears only on failure. On success there is no toast (the
  focus change is the feedback).
  - If the name passed the type and pattern check: `$.ui.toast('Could not focus <name>.')`.
  - Otherwise, fixed text with no name: `$.ui.toast('Could not focus that member.')`.
  - Failure covers: validation fails, a non-zero exit, a throw, or a timeout.
  - stderr is never shown.
- Double-press: two runs, which is harmless (focus is idempotent). No debounce.

### 8.6 Guard widening (exact text for test-mod-readonly.sh; the Reviewer checks the lexer implements each rule)

- **W3. Button in the Pane render, for the member name only.**
  - The W1 position rules (P-a destructure and P-b tag, (i)–(v)) apply to the **Pane render hook**
    (`ui.render`, `component: 'Pane'`, `requestId: 'ah-status'`) as they do for the band hook, **with one exception,
    to P-b(ii)** (r7, an Implementor gap: the Pane draws one Button per row, so the tag always sits in a callback).
    - **P-b(ii) in the Pane hook only:** between `return` and the `<Button` tag, the only function literals that may
      open are **arrow callbacks passed directly as the sole argument of a `.map(` call**, written as the literal
      token `.map(` and not computed. **At most two are allowed:** sections, then rows.
    - Each such `.map(` call lies inside the hook's own return argument, so P-b(i) and (iii)–(v) still hold. The
      `.map(` call's parenthesis counts as an allowed call paren, and only `.map(` qualifies.
    - Each callback's parameter list contains no `$`. The innermost callback **destructures** the row name it labels
      (for example `({ name, … }) =>`), so W3's "label is a bare identifier" and C4's "label identifier == helper
      argument" hold unchanged.
    - A `function` keyword callback, a block-bodied arrow (`=> {`), or any other function literal on that path fails.
      An expression-bodied arrow is required, so the callback returns the JSX directly.
    - The band hook keeps P-b(ii) unchanged: no function literal before its Button.
  - Why this stays simple: the guard is a tripwire against accidental edits. The exec boundary is the pinned helper
    text (argv plus pattern; Ultra-Advisor ruling 1k39). The exception only allows the shape a list of rows needs, and
    still forbids passing `Button` out to a named row-drawer (the binding leak W1 exists to stop).
  - The Pane `Button` must carry `plain`. Its `label` must be a bare identifier (not a call, template or literal
    expression).
  - Its `onPress` must be an inline arrow whose body is exactly one call to the focus helper, optionally wrapped in
    try/catch with an empty catch.
  - (r6, C4) The Button's `label` identifier and the helper call's name argument must be **the same identifier**: what
    is shown is what is focused.
  - Every other hook keeps `Button` forbidden.
- **W4 (r3): the focus helper is fixed text, matched whole.** This replaces lexer data-flow rules, which a token
  lexer cannot check soundly.
  - The helper is one top-level `$`-first declaration (W2 rules). The guard test holds its **complete source text as
    a literal**, and asserts that `mod/register.tsx` contains that text **exactly once**. Whitespace is normalized
    only by trimming line ends.
  - Any edit to the helper means editing the literal in the test, so the Reviewer always sees both.
  - The helper's required content (the Implementor writes it; the test pins it):
    - it takes `($, name)`;
    - it checks `typeof name === 'string'` and `name` against the §8.2 pattern, written as an inline regex literal inside the pinned text (no outside constant), and returns a failure if either does not hold;
    - it calls `$.process.run(['herdr', 'agent', 'focus', name], { timeoutMs: 5000 })`;
    - it returns success only on `exitCode === 0`;
    - it catches every throw as a failure.
    - It does nothing else: no `fs`, no `state`, no other `$` call apart from `ui.toast` on failure.
  - **(r6, C3) How the match and the exemption work:**
    - (a) "exactly once" is counted on the **comment-blanked** source, with strings kept, so a copy inside a comment
      does not count;
    - (b) that one matched span is **excised by offset** before the lexer runs, so the rest of the guard never sees
      it, and nothing else is exempted;
    - (c) `process.run` is **not** added to `ALLOWED_CALLS`, so the exec is allowed only by excision of the pinned
      span.
  - **(r6, C2; r8 widened)** The guard's whole-word `BANNED_TOKENS` for `mod/` gains **every literal name that can
    obtain or rebind a prototype**: `prototype`, `__proto__`, `getPrototypeOf`, `setPrototypeOf`, `defineProperty`,
    `defineProperties`, `getOwnPropertyDescriptor`, `getOwnPropertyDescriptors`. This stops the pinned pattern check
    from being voided, for example `RegExp.prototype.test = () => true`, `/a/.__proto__.test = …`, or
    `Object.getPrototypeOf(/a/).test = …`.
    - (r8) These tokens, like `process`, are matched **after blanking comments but before blanking strings**, so
      `x['__proto__']` and `Object['getPrototypeOf']` fail too. `mod/types/` is excluded. The pinned span is excised
      first.
    - The Implementor first confirms there is no existing hit in `mod/` for any of them. If there is one, stop and
      report.
    - **Ceiling (unchanged, UA 1k39):** a name computed at run time (for example `RegExp[a + b]`) evades any token
      ban. The guard is a tripwire, not a boundary.
  - **(r8) Exactly one reference to the focus helper.** Outside the pinned span, the helper's identifier occurs
    **exactly once in `mod/`**: as the callee of the Pane `onPress` call (W3).
    - Any other occurrence fails: a call from another hook, an alias (`const f = <helper>`), passing it as a value,
      exporting it, or a second call site in the Pane.
    - So `process.run`, which exists only inside the excised helper, is reachable from the Pane `onPress` and nowhere
      else. This matches the Reviewer's blocking fix.
  - **(r6, C6) The invariant is written down** at the top of `test-mod-readonly.sh` and in the mod's doc (the README
    section or doc that describes the mod):
    - "The mod runs nothing without a user press. Exactly one process may run: the pinned focus helper.
    - A second exec site, or any change to the pinned argv or init, needs a new security ruling, not a guard edit."
    - The existing planted `agent get` case (test-mod-readonly.sh:289) stays.
  - **(r5) The token `process` appears nowhere in `mod/` outside that exact text.** It is checked as a whole word
    **after blanking comments but before blanking strings**, so `$.process`, `$['process']`, `"process"` and
    `const p = $.process` all fail.
    - `mod/types/` is excluded: the type declaration there is not code.
    - The helper text itself is removed from the source before the check, so it counts once.
- **W5. No other new call.** Outside the helper, nothing new: the Pane render gains only the W3 Button and its
  `onPress`.

**Planted cases (each must FAIL the guard):**
1. `process.spawn` anywhere.
2. `process.run` outside the helper text (in a render, in `openPane`, at module scope).
3. The helper text altered in any one character (a changed argv element, an added fifth element, a spread, a
   template string, `sh -c`, a second argument with another key, a removed pattern check). Each is one planted case:
   3a–3h.
4. The helper text present twice.
5. `process` reached by alias outside the helper (`const p = $.process`, `const {run} = $.process`,
   `$['process']`).
9. A Pane Button without `plain`.
10. A Pane Button whose `label` is a call or template.
11. A Pane Button `onPress` that is not exactly one focus-helper call (extra statements, `$` passed elsewhere, a
    member call).
12. The focus helper declared twice, or bound another way (W2 rules).
13. A Button in any hook other than the band and the Pane.
6. (r6, C3) The pinned text placed inside a comment or a string, with an **altered** live helper.
7. (r6, C4) A Button with `label={a}` and `onPress={() => focus($, b)}`.
8. (r6, C1) The pattern written as a constant outside the pinned text (for example `const NAME_RE = /.*/` used by the
   helper).
14. (r6, C2) `prototype` anywhere in `mod/` (for example `RegExp.prototype.test = () => true`).

15. (r7) A map callback stored or defined outside the return (`const draw = (r) => <Button…/>`, then `rows.map(draw)`).
16. (r7) Three nested `.map(` callbacks before the Button.
17. (r7) A Button in a non-map callback: `.filter(r => <Button/>)`, `.flatMap(…)`, `.forEach(…)`, an IIFE
    `(() => <Button/>)()`.
18. (r7) A `function` keyword map callback, or a block-bodied arrow `=> { return <Button/> }`.
19. (r7) A computed map: `rows['map'](r => <Button/>)`.
20. (r7) A map callback whose parameter is `$` or contains `$`.
21. (r7) A Button inside a map callback in the **band** hook (the exception is Pane only).
22. (r7) A row-drawer: `Button` passed as an argument (`drawRow(Button, r)`) or captured in a helper.

23. (r8) `/a/.__proto__.test = () => true`; `x['__proto__']`.
24. (r8) `Object.getPrototypeOf(/a/).test = …`; `Object['getPrototypeOf'](x)`.
25. (r8) `Object.setPrototypeOf(…)`; `Object.defineProperty(RegExp, …)`; `Object.defineProperties(…)`;
    `Object.getOwnPropertyDescriptor(…)` and the plural form.
26. (r8) The focus helper referenced a second time: called from the band hook; called at module scope; aliased
    (`const f = <helper>`); passed as a value (`run(<helper>)`); exported; a second Pane call site.
27. (r8) No reference at all: the helper is pinned but the Pane never calls it (an unused exec site).

**Must PASS (r8):** the one Pane call, plus a comment that mentions the helper's name. The reference count is taken
on code with comments and strings blanked, so a mention there is not a reference.

**Must PASS (r7):** `return (<Box>{sections.map((s) => <Box …>{s.rows.map(({ name, … }) => <Box key={…}><Button
plain label={name} onPress={() => focus($, name)} …/></Box>)}</Box>)}</Box>)` inside the Pane hook. This is
illustrative; the exact attribute set follows W3 and §8.5.

(Cases 6–8 and 14 of r2 were folded into 3 and 5. The numbers are reused above for r6's cases. The existing planted `$.process.run(['herdr','agent','get'])`
case, test-mod-readonly.sh:289, stays failing.)

**Must PASS:** the exact helper text once, the W3 Button form, and the band unchanged.

### 8.7 Behaviour tests (Part 2)

| Case | Expected | Test |
|---|---|---|
| a valid herdr member clicked | `process.run` called once with exactly `['herdr','agent','focus',<name>]` (stubbed `$`) | F1 |
| the helper called with `-x`, `a b`, `../t`, `A`, a 33-character name, a name with a control character, or a non-string | no run; failure toast | F2 |
| a status member with `focusable` not exactly true | rendered with no Button | F3 |
| a non-zero exit or a throw from run | a failure toast; no throw out of `onPress` | F7 |
| a tmux, terminal, gone or self member | rendered with no Button | F8 |
| a member session | no Button anywhere in the Pane | F9 |
| the mod's name pattern | string-equal to lib-config.mjs:278's | F10 |
| `focusable` from lib-status | true only for `transport === 'herdr'` with a non-empty `transport_id` and a name passing the pattern; a worktree session's status still gets it right (the team home is used) | F11 |

### 8.8 NEEDS-EVIDENCE for Part 2 (Implementor, read-only plus a sandbox herdr session; generic names)

- **E3a.** What `herdr agent focus <target>` accepts: the agent name (as `agent get` does), a pane id (the
  `w1H:pE` shape), or both? Run `herdr agent focus --help` and try each form on a sandbox agent.
  - Also report **name scope**: are herdr agent names unique per herdr server, or can two teams or checkouts register
    the same name?
  - **Decided (r5):** herdr takes the name (E3a done). The target stays the name. A name shared across workspaces is
    possible but harmless (focus only), and it is the stated §8.1 ceiling. There is no `transport_id` branch.
- **E3b.** Does it switch tabs/workspaces to reach the agent? What does it exit with, and print, for an unknown
  target?
- **E3c (widened, decides feasibility).** From the engine types and docs the mod is built against:
  - does the mod's `$` expose `process.run`? Give its signature;
  - does it need a manifest capability, or raise a permission prompt?
  - does `init` take a timeout, and what is the documented behaviour for a hung child?

  Absent, or unusable by a mod → Part 2 is not feasible (§8.1).
- (E3d is answered by reading, so it is removed: §8.3.)
- **E1(d)** above (plain Button width and hover).

### 8.9 Question for the Ultra-Advisor

**RULED (r6), by the Ultra-Advisor (response 1k39): allow with changes C1–C7, all applied.**
- Q1 yes: status.json is treated as fully untrusted, and the pattern bounds the effect to which agent gets focus.
- Q2 yes.
- Q3 yes: the exec is enforced by a pinned, exactly-matched helper text, with C1 and C3, not by lexer data-flow
  rules. (This answers the reviewer's wording nit.)
- Q4: no opt-in setting; the user confirmed that the click is the consent.
- The guard is a tripwire against accidental edits, not a boundary against a hostile author (0071). The safety of the
  exec rests on the fixed argv plus the pattern, both pinned.

Original question, for the record. This applied only if E3c found the API usable. Context: the ah mod is today a read-only renderer under a lexer
guard. The proposal is that on an explicit user click it runs `herdr agent focus <name>`, a fixed argv via
`$.process.run` with no shell, from one fixed-text helper (W4).

- **Q1.** status.json and the team file share writers and trust, and the team-file path cannot be derived beside
  status.json in worktree sessions. Is pattern-only validation of the status name (`^[a-z][a-z0-9_-]{0,31}$`, plus
  `focusable`) sufficient, with the team-file re-read dropped?
- **Q2.** Is a PATH-resolved `herdr` acceptable, as roster.mjs does already?
- **Q3.** Must the process call live in a fixed-text helper that the guard matches whole (as §8.6 W4 now specifies),
  instead of the W4 lexer rules (array literal + 3 literals + one identifier + data flow)?
- **Q4.** Does exec-on-click need a user opt-in setting (default off) to keep the mod read-only by default, or is the
  explicit click itself consent enough?

The Architect's leaning (not a ruling): Q1 yes; Q2 yes (no new trust in PATH); Q3 yes (exact text is sound, and
smaller); Q4 is the user's call, through the Ultra-Advisor. The residual risk is precedent and a guard bypass, not
the data.

## 9. Open questions

- §8.9 to the Ultra-Advisor (the Orchestrator routes it).
- For the user, only if E3a shows that herdr focuses by pane id and not by name: nothing changes for them. It is
  noted for completeness; no question now.

## 10. Acceptance

**Part 1:**
1. E1 is run and recorded; the §4.2 table is adjusted only as E1 decides.
2. Every §7 test is present and seen failing first where new. The full ah suite and `claude plugin test` are green.
   The guard is unchanged in the diff.
3. `docs/status-file.md` has the `stream` row. The CHANGELOG is generic ("Pane: colored section boxes, colored
   activity icons, grouped by stream"). The version is bumped in both manifests.
4. Manual M1 (the user; r4, replaces E1's per-theme part, which cannot be checked headless): `/hierarchy-pane` with
   a team that has one stream, at a wide and a narrow width. Do it in **both** a light and a dark theme.
   - Report each box color and each icon color as "colored and readable", "plain" or "unreadable".
   - Apply §6's rules to the answers: drop or swap any key that is plain or unreadable. That is a one-line table
     edit, with no redesign.

**Part 2 (ruled; builds after Part 1):** (r6, C7) Part 2 is **not accepted** without a recorded run of
`tests/test-mod-readonly.sh`, with its exit code in the Reviewer's evidence. That run includes every planted case
above, and the C6 invariant text is present. E3 is recorded (E3c usable, or Part 2 is dropped); every
§8.6 planted case fails; the helper text is pinned; F1–F3 and F7–F11 pass; `focusable` is in status-file.md. Manual M2: click a herdr member's name, and its pane gets
focus; click a tmux member, and there is nothing to click.
