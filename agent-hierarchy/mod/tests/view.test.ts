import { test, expect } from 'claude-code/testing'
import { fixtures } from './fixtures.ts'
import { vectors } from './vectors.ts'
import { bandLine, BORDER_MIN, toastMs, cut, nullCause, PANE_BUTTON, keepSeen, paneRows, paneSections, STYLE, parseDoc, SIZE_CAP, statusText, utf8Bytes, viewModel } from '../view.ts'

const T0 = '2026-01-01T12:00:00.000Z'
const ms = (iso: string) => Date.parse(iso)

// An inline document: one visible entry at T0, expiring a day later; `over` replaces top-level fields,
// `entry` the entry's.
const docText = (over: Record<string, unknown> = {}, entry: Record<string, unknown> = {}) =>
  JSON.stringify({
    schema: 1, written_at: T0, expires_at: '2026-01-02T12:00:00.000Z', enabled: true, member_sessions: [], teams: [],
    timeline: [{ at: T0, live: 1, blocked: 0, out: 1, overdue: 0, stalled: 0, text: '1 live · 1 out', short: '1/1', tone: 'work', visible: true, ...entry }],
    ...over,
  })
const show = (text: string | null, now = T0, sessionId = 'sess-orch', entryOn = true) => statusText(parseDoc(text), ms(now), sessionId, entryOn)

test('every fixture case has a vector, and every vector names a case', async () => {
  expect(Object.keys(vectors).sort()).toEqual(Object.keys(fixtures).sort())
})

for (const [name, v] of Object.entries(vectors)) {
  test(`vector ${name}: the status entry`, async () => {
    expect(statusText(parseDoc(fixtures[name]), ms(v.now), v.sessionId, true)).toBe(v.statusText)
  })
  test(`vector ${name}: the band, the Pane rows and the toasts`, async () => {
    const view = viewModel(parseDoc(fixtures[name]), ms(v.now), v.sessionId)
    expect(bandLine(view, v.columns)).toEqual(v.band)
    expect(paneRows(view, v.columns)).toEqual(v.pane)
    expect(view === null ? [] : view.toasts).toEqual(v.toasts)
  })
}

test('the entry text has no "ah · " prefix', async () => {
  for (const [name, v] of Object.entries(vectors)) {
    const text = statusText(parseDoc(fixtures[name]), ms(v.now), v.sessionId, true)
    if (text !== undefined) expect(text.startsWith('ah')).toBe(false)
  }
})

test('absent: missing, unparseable, schema 2', async () => {
  expect(show(null)).toBe(undefined)
  expect(show('{"schema": 1,')).toBe(undefined)
  expect(show(docText({ schema: 2 }))).toBe(undefined)
  expect(show(docText())).toBe('1 live · 1 out')
})

test('absent: expired at expires_at, shown just before', async () => {
  expect(show(docText(), '2026-01-02T12:00:00.000Z')).toBe(undefined)
  expect(show(docText(), '2026-01-02T11:59:59.999Z')).toBe('1 live · 1 out')
})

test('absent: visible false', async () => {
  expect(show(docText({}, { visible: false }))).toBe(undefined)
})

test('absent: over 262,144 bytes; exactly 262,144 is read', async () => {
  expect(utf8Bytes('·')).toBe(2)
  const base = docText()
  const exact = base + ' '.repeat(SIZE_CAP - utf8Bytes(base))
  expect(utf8Bytes(exact)).toBe(262144)
  expect(show(exact)).toBe('1 live · 1 out')
  expect(show(exact + ' ')).toBe(undefined)
})

test('absent: a malformed shape', async () => {
  const noMembers = JSON.parse(docText())
  delete noMembers.member_sessions
  expect(show(JSON.stringify(noMembers))).toBe(undefined)
  expect(show(docText({ member_sessions: [1] }))).toBe(undefined)
  expect(show(docText({ timeline: [] }))).toBe(undefined)
  expect(show(docText({ timeline: [{ at: 'yesterday', text: 'x', short: 'x', tone: 'idle', visible: true }] }))).toBe(undefined)
  expect(show(docText({ expires_at: undefined }))).toBe(undefined)
  expect(show(docText({ expires_at: '2026-01-02' }))).toBe(undefined)
  expect(show(docText({}, { visible: 'yes' }))).toBe(undefined)
  expect(show(docText({}, { tone: 3 }))).toBe(undefined)
  expect(show(docText({}, { text: undefined }))).toBe(undefined)
  expect(show(docText({}, { short: undefined }))).toBe(undefined)
})

test('an unknown tone string still shows the entry', async () => {
  expect(show(docText({}, { tone: 'purple' }))).toBe('1 live · 1 out')
})

test('control characters are stripped from the text', async () => {
  expect(show(docText({}, { text: 'a\x1b[31mb\x07c\x9fd\x7fe' }))).toBe('a[31mbcde')
})

test('hidden in a member session, shown in any other', async () => {
  const text = docText({ member_sessions: ['sess-m'] })
  expect(show(text, T0, 'sess-m')).toBe(undefined)
  expect(show(text, T0, 'sess-orch')).toBe('1 live · 1 out')
})

test('the timeline pick: before the first entry, at an entry, just before the next', async () => {
  const two = (first: string) => docText({ timeline: [
    { at: first, text: 'A', short: 'A', tone: 'work', visible: true },
    { at: '2026-01-01T12:01:00.000Z', text: 'B', short: 'B', tone: 'bad', visible: true },
  ] })
  expect(show(two('2026-01-01T12:00:10.000Z'), T0)).toBe('A')
  expect(show(two(T0), '2026-01-01T12:01:00.000Z')).toBe('B')
  expect(show(two(T0), '2026-01-01T12:00:59.999Z')).toBe('A')
})

test('the status_entry toggle: off clears the entry, on shows it', async () => {
  expect(show(docText(), T0, 'sess-orch', false)).toBe(undefined)
  expect(show(docText(), T0, 'sess-orch', true)).toBe('1 live · 1 out')
})

// ---- the band, the Pane and the toasts, on inline documents
const at = (offsetMs: number) => new Date(ms(T0) + offsetMs).toISOString()
const member = (over: Record<string, unknown> = {}) => ({
  name: 'demo-architect', role: 'architect', label: 'architect', kind: 'codex', route: 'pane', session_id: null,
  live: true, activity: 'working', activity_at: at(-60000), blocked_by: null, blocked_note: null, ...over,
})
// A small-eta dispatch sent `sentAgo` ms before T0, on the producer's schedule from then.
const dispatch = (over: Record<string, unknown> = {}, sentAgo = 60000) => ({
  id: 'd1', slug: 'build-step', to: 'architect', to_name: 'demo-architect', member: 'demo-architect', label: 'architect',
  eta: 'small', eta_ms: 300000, created: at(-sentAgo), sent_at: at(-sentAgo), checkins: 0, reported_at: null,
  states: [
    { at: at(-sentAgo), state: 'working' },
    { at: at(300000 - sentAgo), state: 'overdue' },
    { at: at(450000 - sentAgo), state: 'stalled', reason: 'no-report' },
  ],
  ...over,
})
const team = (over: Record<string, unknown> = {}) => ({ team: null, members: [member()], dispatches: [dispatch()], dispatches_truncated: 0, pipeline: null, ...over })
const viewOf = (teams: unknown[], entry: Record<string, unknown> = {}, now = T0) =>
  viewModel(parseDoc(docText({ teams }, { out: 1, blocked: 0, ...entry })), ms(now), 'sess-orch')
const band = (teams: unknown[], entry: Record<string, unknown> = {}, now = T0, columns = 200) => bandLine(viewOf(teams, entry, now), columns)
const rows = (teams: unknown[], columns = 120, now = T0) => paneRows(viewOf(teams, {}, now), columns).map((r) => r.text)

test('the Pane button reserves its drawn `[ Pane ]` width and a gap, so the fitted band text never overlaps it', async () => {
  expect(PANE_BUTTON.width).toBe(`[ ${PANE_BUTTON.label} ]`.length)
  const two = [team({ dispatches: [dispatch({ id: 'a', label: 'reviewer' }, 30000), dispatch({ id: 'b' }, 90000)] })]
  for (let columns = PANE_BUTTON.minColumns; columns <= 120; columns++) {
    const line = band(two, { out: 2 }, T0, columns - PANE_BUTTON.width - PANE_BUTTON.gap)
    expect([...line!.text].length).toBeLessThanOrEqual(columns - 9)
  }
})

test('band, working: out count, m:ss of T, oldest first, further items only while the line fits', async () => {
  const two = [team({ dispatches: [dispatch({ id: 'a', label: 'reviewer' }, 30000), dispatch({ id: 'b' }, 90000)] })]
  expect(band(two, { out: 2 })).toEqual({ text: '2 out · architect 1:30 of 5m · reviewer 0:30 of 5m', tone: 'work' })
  expect(band(two, { out: 2 }, T0, 40)).toEqual({ text: '2 out · architect 1:30 of 5m', tone: 'work' })
  expect(band(two, { out: 2 }, T0, 20)).toEqual({ text: '2 out · architect 1…', tone: 'work' })
})

const idleEntry = { out: 0, blocked: 0, text: '1 live · 0 out', tone: 'idle' }
test('band, idle: with nothing out and nothing blocked the band is the entry text in its tone', async () => {
  expect(band([team()], idleEntry)).toEqual({ text: '1 live · 0 out', tone: 'idle' })
  expect(band([team()], { ...idleEntry, text: '2 live · 0 out' })).toEqual({ text: '2 live · 0 out', tone: 'idle' })
  expect(band([team()], { ...idleEntry, text: '0 live · 0 out' })).toEqual({ text: '0 live · 0 out', tone: 'idle' })
  expect(band([team()], { ...idleEntry, text: '1 live\x1b · 0 out' })).toEqual({ text: '1 live · 0 out', tone: 'idle' })
  expect(band([team()], idleEntry, T0, 8)).toEqual({ text: '1 live …', tone: 'idle' })
})

test('band, idle: no band for an empty entry text, and an unknown tone reads idle', async () => {
  expect(band([team()], { ...idleEntry, text: '' })).toBe(null)
  expect(band([team()], { ...idleEntry, text: '\x1b' })).toBe(null)
  expect(band([team()], { ...idleEntry, tone: 'purple' })?.tone).toBe('idle')
  expect(band([team()], { ...idleEntry, tone: 'warn' })?.tone).toBe('warn')
})

test('band, idle: counts out but nothing to name, the entry text and tone verbatim', async () => {
  const reported = team({ dispatches: [dispatch({ states: [{ at: at(-60000), state: 'reported' }] })] })
  expect(band([reported], { out: 1 })).toEqual({ text: '1 live · 1 out', tone: 'work' })
})

test('band: a member session, an invisible entry and an expired document draw none', async () => {
  const doc = (over: Record<string, unknown>, entry: Record<string, unknown> = {}) => parseDoc(docText(over, { out: 0, ...entry }))
  expect(bandLine(viewModel(doc({ member_sessions: ['sess-orch'] }), ms(T0), 'sess-orch'), 120)).toBe(null)
  expect(bandLine(viewModel(doc({}, { visible: false }), ms(T0), 'sess-orch'), 120)).toBe(null)
  expect(bandLine(viewModel(doc({}), ms('2026-01-02T12:00:00.000Z'), 'sess-orch'), 120)).toBe(null)
  expect(bandLine(viewModel(doc({}), ms(T0), 'sess-orch'), 120)).not.toBe(null)
})

test('band, stalled: the check-in phrase, and who is gone', async () => {
  const stalled = (over: Record<string, unknown>) => [team({ dispatches: [dispatch({ states: [{ at: at(-60000), state: 'stalled', reason: 'no-report' }], ...over })] })]
  expect(band(stalled({}))?.text).toBe('architect stalled on build-step · no report after 1m')
  expect(band(stalled({ checkins: 1 }))?.text).toBe('architect stalled on build-step · 1 check-in unanswered')
  expect(band(stalled({ checkins: 2 }))?.text).toBe('architect stalled on build-step · 2 check-ins unanswered')
  const gone = (over: Record<string, unknown>) => stalled({ states: [{ at: at(-60000), state: 'stalled', reason: 'member-gone' }], ...over })
  expect(band(gone({}))?.text).toBe('architect stalled on build-step · demo-architect is gone')
  expect(band(gone({ member: null }))?.text).toBe('architect stalled on build-step · demo-architect is gone')
  expect(band(gone({ member: null, to_name: null }))?.text).toBe('architect stalled on build-step · architect is gone')
  expect(band(gone({}))?.tone).toBe('bad')
})

test('band, overdue: time past the eta and the check-ins sent', async () => {
  const late = (over: Record<string, unknown> = {}) => [team({ dispatches: [dispatch(over, 340000)] })]
  expect(band(late())).toEqual({ text: 'architect is 40s past its 5m eta', tone: 'bad' })
  expect(band(late({ checkins: 2 }), {}, at(100000))?.text).toBe('architect is 2m 20s past its 5m eta · check-in 2 sent')
})

test('band, blocked member: the answer is through the Orchestrator for a pane member, in its pane otherwise', async () => {
  const blocked = (route: string) => [team({ members: [member({ activity: 'blocked', route })], dispatches: [] })]
  expect(band(blocked('pane'), { out: 0, blocked: 1 })).toEqual({ text: 'architect is waiting on a prompt · answer it through the Orchestrator', tone: 'warn' })
  expect(band(blocked('peer'), { out: 0, blocked: 1 })?.text).toBe('architect is waiting on a prompt · answer it in its pane')
})

test('band: the most severe subject, ties by oldest, +k counts the other non-working items once', async () => {
  const mixed = [team({
    members: [member({ activity: 'blocked' }), member({ name: 'demo-reviewer', label: 'reviewer' })],
    dispatches: [
      dispatch({ id: 'o1', label: 'reviewer', slug: 'late-1' }, 320000),
      dispatch({ id: 'o2', label: 'reviewer', slug: 'late-2' }, 400000),
      dispatch({ id: 'b1', states: [{ at: at(-60000), state: 'blocked' }] }),
    ],
  })]
  expect(band(mixed, { out: 3, blocked: 1 })?.text).toBe('reviewer is 1m 40s past its 5m eta · +2 more')
})

test('G3: an eta_ms that is not a positive number shows eta —, no bar or pct, no "of {T}m", never NaN', async () => {
  for (const eta_ms of [0, -1, 'large', null, undefined]) {
    const bare = [team({ dispatches: [dispatch({ eta_ms })] })]
    expect(band(bare)?.text).toBe('1 out · architect 1:00')
    expect(rows(bare)).toEqual(['Hierarchy', 'No pipeline run.', 'Team', 'demo-architect · codex · pane · working 1m', 'Dispatches', 'build-step → architect | eta — | 1:00 | working'])
    const late = [team({ dispatches: [dispatch({ eta_ms, states: [{ at: at(-60000), state: 'overdue' }] })] })]
    expect(band(late)?.text).toBe('architect is past its eta')
    expect(JSON.stringify([band(bare), rows(bare), band(late), rows(late)]).includes('NaN')).toBe(false)
  }
})

test('Pane, dispatch rows: the width fallback at 60, 40 and 28 columns', async () => {
  const one = [team({ dispatches: [dispatch({ slug: 's', label: 'a' }, 150000)] })]
  const last = (columns: number) => rows(one, columns).at(-1)
  expect(last(60)).toBe('s → a | eta 5m | █████░░░░░ 50% | 2:30 | working')
  expect(last(59)).toBe('s → a | eta 5m | 50% | 2:30 | working')
  expect(last(40)).toBe('s → a | eta 5m | 50% | 2:30 | working')
  expect(last(39)).toBe('s → a | 50% | 2:30 | working')
  expect(last(28)).toBe('s → a | 50% | 2:30 | working')
  expect(last(27)).toBe('s working')
})

test('Pane, member rows: name · kind · route · state from 40 columns, name state below', async () => {
  expect(rows([team({ members: [member({ name: 'm1' })], dispatches: [] })], 40)[3]).toBe('m1 · codex · pane · working 1m')
  expect(rows([team({ members: [member({ name: 'm1' })], dispatches: [] })], 39)[3]).toBe('m1 working 1m')
})

test('Pane: a long slug or name is cut first, down to 8 characters, then the whole row', async () => {
  expect(rows([team({ dispatches: [] })], 40)[3]).toBe('demo-archit… · codex · pane · working 1m')
  expect(rows([team({ dispatches: [dispatch({}, 150000)] })], 60).at(-1)).toBe('build-s… → architect | eta 5m | █████░░░░░ 50% | 2:30 | wor…')
  const long = [team({ members: [member({ name: 'a-very-long-member-name' })], dispatches: [dispatch({ slug: 'a-very-long-slug-for-this' }, 150000)] })]
  expect(rows(long, 30)).toContain('a-very-long-member… working 1m')
  expect(rows(long, 27).at(-1)).toBe('a-very-long-slug-f… working')
  expect(rows(long, 12).at(-1)).toBe('a-very-… wo…')
})

test('Pane: member states and tones, and the age shown for pane members only', async () => {
  const people = [team({
    dispatches: [],
    members: [
      member({ name: 'p-59s', activity_at: at(-59000) }),
      member({ name: 'p-61s', activity: 'blocked', activity_at: at(-61000) }),
      member({ name: 'p-1h', activity: 'idle', activity_at: at(-3600000) }),
      member({ name: 'peer', route: 'peer', kind: 'claude', activity: 'working' }),
      member({ name: 'gone', live: false, activity: 'working' }),
      member({ name: 'odd', activity: 'thinking' }),
    ],
  })]
  const drawn = paneRows(viewOf(people), 120).slice(3, 9)
  expect(drawn).toEqual([
    { text: 'p-59s · codex · pane · working 59s', tone: 'work' },
    { text: 'p-61s · codex · pane · blocked 1m', tone: 'warn' },
    { text: 'p-1h · codex · pane · idle 1h', tone: 'idle' },
    { text: 'peer · claude · peer · working', tone: 'work' },
    { text: 'gone · codex · pane · gone', tone: 'idle' },
    { text: 'odd · codex · pane · thinking 1m', tone: 'idle' },
  ])
})

test('Pane: a working peer shows its last finished tool from the current turn, and nothing else changes', async () => {
  const peer = (over: Record<string, unknown>) => member({ name: 'peer', route: 'peer', kind: 'claude', activity_at: at(-360000), ...over })
  const state = (m: Record<string, unknown>) => paneRows(viewOf([team({ members: [m], dispatches: [] })]), 120)[3].text.replace('peer · claude · peer · ', '')
  // V1: the tool is from this turn
  expect(state(peer({ last_tool: 'Edit', last_tool_at: at(-12000) }))).toBe('working 6m · last Edit 12s')
  expect(state(peer({ last_tool: 'Edit', last_tool_at: at(-360000) }))).toBe('working 6m · last Edit 6m')
  // V2: no tool
  expect(state(peer({}))).toBe('working')
  expect(state(peer({ last_tool: null, last_tool_at: null }))).toBe('working')
  // V3: an idle member keeps today's text
  expect(state(peer({ activity: 'idle', last_tool: 'Edit', last_tool_at: at(-12000) }))).toBe('idle')
  // V4: a pane member keeps today's text
  expect(state(peer({ route: 'pane', last_tool: 'Edit', last_tool_at: at(-12000) })).replace('peer · claude · pane · ', '')).toBe('working 6m')
  // V5: a tool from the previous turn
  expect(state(peer({ last_tool: 'Edit', last_tool_at: at(-361000) }))).toBe('working')
  // V6: unparseable timestamps, no throw
  expect(state(peer({ last_tool: 'Edit', last_tool_at: 'soon' }))).toBe('working')
  expect(state(peer({ activity_at: 'soon', last_tool: 'Edit', last_tool_at: at(-12000) }))).toBe('working')
  expect(state(peer({ last_tool: 'Edit', last_tool_at: 42 }))).toBe('working')
  // a gone member is gone
  expect(state(peer({ live: false, last_tool: 'Edit', last_tool_at: at(-12000) }))).toBe('gone')
})

test('Pane, dispatches: expired rows hidden, reported kept, newest first, state tones', async () => {
  const many = [team({ dispatches: [
    dispatch({ id: 'w', slug: 'old-work' }, 200000),
    dispatch({ id: 'r', slug: 'done', reported_at: at(-10000), states: [{ at: at(-10000), state: 'reported' }, { at: at(590000), state: 'expired' }] }, 120000),
    dispatch({ id: 'x', slug: 'gone-by', states: [{ at: at(-700000), state: 'reported' }, { at: at(-100000), state: 'expired' }] }, 900000),
    dispatch({ id: 'u', slug: 'odd', states: [{ at: at(-5000), state: 'paused' }] }, 5000),
  ] })]
  expect(paneRows(viewOf(many), 120).slice(5)).toEqual([
    { text: 'odd → architect | eta 5m | ░░░░░░░░░░ 1% | 0:05 | paused', tone: 'idle' },
    { text: 'done → architect | eta 5m | ████░░░░░░ 40% | 2:00 | reported', tone: 'idle' },
    { text: 'old-work → architect | eta 5m | ██████░░░░ 66% | 3:20 | working', tone: 'work' },
  ])
})

test('Pane: pipeline lines, waiting decisions, and No pipeline run. whenever no item is open', async () => {
  const pipe = (items: unknown[], waiting = 0) => [team({ pipeline: { anchor_id: 'a', started: at(-600000), round_cap: 3, waiting_on_user: waiting, items } })]
  expect(rows(pipe([{ slug: 's', rounds: 2, open: true, to: 'reviewer' }, { slug: 't', rounds: 1, open: false, to: 'architect' }], 2)).slice(0, 3))
    .toEqual(['Hierarchy', 'round 2/3 · reviewer', '2 decisions waiting for you'])
  expect(rows(pipe([{ slug: 't', rounds: 1, open: false, to: 'architect' }])).slice(0, 2)).toEqual(['Hierarchy', 'No pipeline run.'])
  expect(rows(pipe([], 1)).slice(0, 3)).toEqual(['Hierarchy', 'No pipeline run.', '1 decision waiting for you'])
})

test('Pane: with more than one live team, each heading names its team, null as default', async () => {
  const both = [team({ team: 'alpha', dispatches: [] }), team({ dispatches: [] })]
  expect(rows(both).filter((r) => /^(Hierarchy|Team|Dispatches)/.test(r)))
    .toEqual(['Hierarchy alpha', 'Hierarchy default', 'Team alpha', 'Team default', 'Dispatches alpha', 'Dispatches default'])
})

test('Pane: control characters are stripped from document strings; no view draws one dim line', async () => {
  const dirty = [team({ members: [member({ name: 'demo\x1b[31m-architect' })], dispatches: [dispatch({ slug: 'build\x07-step' })] })]
  const drawn = rows(dirty)
  expect(drawn).toContain('demo[31m-architect · codex · pane · working 1m')
  expect(drawn.at(-1)).toBe('build-step → architect | eta 5m | ██░░░░░░░░ 20% | 1:00 | working')
  expect(paneRows(null, 120)).toEqual([{ text: 'No hierarchy status here.', tone: 'idle' }])
})

test('toasts: reported with its time, blocked by note, permission or prompt, stalled with who is gone', async () => {
  const view = viewOf([team({
    members: [
      member({ name: 'n1', activity: 'blocked', activity_at: at(-1000), blocked_note: 'Allow? (y/n)' }),
      member({ name: 'n2', label: 'reviewer', activity: 'blocked', activity_at: at(-2000), blocked_by: 'permission' }),
      member({ name: 'n3', label: 'implementor', activity: 'blocked', activity_at: at(-3000), blocked_by: 'login' }),
    ],
    dispatches: [
      dispatch({ id: 'r1', reported_at: at(-200000), states: [{ at: at(-200000), state: 'reported' }] }, 600000),
      dispatch({ id: 's1', member: 'demo-reviewer', label: 'reviewer', slug: 'review', states: [{ at: at(-1000), state: 'stalled', reason: 'member-gone' }] }),
    ],
  })], { out: 1, blocked: 3 })
  expect(view?.toasts).toEqual([
    { key: 'reported:r1', text: 'architect reported · build-step · 6m 40s' },
    { key: `blocked:n1:${at(-1000)}`, text: 'architect blocked · Allow? (y/n)' },
    { key: `blocked:n2:${at(-2000)}`, text: 'reviewer blocked · waiting for permission' },
    { key: `blocked:n3:${at(-3000)}`, text: 'implementor blocked · waiting on a prompt' },
    { key: 'stalled:s1', text: 'reviewer stalled · review · demo-reviewer is gone' },
  ])
})

test('cut: cells counted by code point, ending in …', async () => {
  expect(cut('abcdef', 6)).toBe('abcdef')
  expect(cut('abcdef', 4)).toBe('abc…')
  expect(cut('██████', 3)).toBe('██…')
  expect(cut('abc', 0)).toBe('')
})

test('keepSeen: keys whose dispatch or member is still in the doc stay, everything else goes', async () => {
  const doc = parseDoc(docText({ teams: [team()] }, { out: 1, blocked: 0 }))
  expect(doc).not.toBe(null)
  const seen = ['reported:d1', 'stalled:d1', 'stalled:gone', `blocked:demo-architect:${at(-1000)}`, 'blocked:someone:x', 'other:d1', 7, null]
  expect(keepSeen(seen, doc!, ms(T0))).toEqual(['reported:d1', 'stalled:d1', `blocked:demo-architect:${at(-1000)}`])
})

test('a visible entry that lists no team draws one dim line saying so, and the band shows the entry text', async () => {
  const noTeamKey = JSON.stringify({ ...JSON.parse(docText()), teams: undefined })
  for (const text of [docText(), docText({ teams: [1, 'x'] }), noTeamKey]) {
    const view = viewModel(parseDoc(text), ms(T0), 'sess-orch')
    expect(view).not.toBe(null)
    expect(paneRows(view, 80)).toEqual([{ text: 'No live team in the status file.', tone: 'idle' }])
    expect(bandLine(view, 80)).toEqual({ text: '1 live · 1 out', tone: 'work' })
  }
})

test('a held value that is not a view draws the null-view line and no band, and never throws', async () => {
  for (const held of [{}, { pane: 'x' }, { pane: null }, 7, 'x', [], { pane: [1] }, { pane: [{}] }, { band: 3 }, { band: { head: 1, tail: [], tone: 'work' } }, { band: { head: 'h', tail: 'x', tone: 'work' } }]) {
    const rows = paneRows(held as any, 80)
    expect(rows.length).toBe(1)
    expect(typeof rows[0].text).toBe('string')
    expect(bandLine(held as any, 80)).toBe(null)
  }
  expect(paneRows({} as any, 80)).toEqual([{ text: 'No hierarchy status here.', tone: 'idle' }])
  expect(paneRows({ pane: 'x' } as any, 80, 'expired')).toEqual([{ text: 'No hierarchy status here (expired).', tone: 'idle' }])
})

test('the empty line names its cause, and is cut to the width like any row', async () => {
  expect(paneRows(null, 80)).toEqual([{ text: 'No hierarchy status here.', tone: 'idle' }])
  expect(paneRows(null, 80, 'hierarchy off')).toEqual([{ text: 'No hierarchy status here (hierarchy off).', tone: 'idle' }])
  expect(paneRows(null, 20, 'hierarchy off')[0].text).toBe('No hierarchy status…')
})

test('nullCause names why a document gives no view', async () => {
  expect(nullCause(null, ms(T0), 'sess-orch')).toBe('unreadable')
  expect(nullCause(parseDoc(docText({}, { visible: false })), ms(T0), 'sess-orch')).toBe('not visible')
  expect(nullCause(parseDoc(docText({ enabled: false }, { visible: false })), ms(T0), 'sess-orch')).toBe('hierarchy off')
  expect(nullCause(parseDoc(docText({ member_sessions: ['sess-m'] })), ms(T0), 'sess-m')).toBe('member session')
  expect(nullCause(parseDoc(docText()), ms('2026-01-02T12:00:00.000Z'), 'sess-orch')).toBe('expired')
  // Must NOT change: an expired doc is expired before it is anything else, and a doc with no `enabled` boolean is not "hierarchy off".
  expect(nullCause(parseDoc(docText({ enabled: false, member_sessions: ['sess-m'] }, { visible: false })), ms('2026-01-03T00:00:00.000Z'), 'sess-m')).toBe('expired')
  expect(nullCause(parseDoc(docText({ enabled: 'no' }, { visible: false })), ms(T0), 'sess-orch')).toBe('not visible')
  // A member session sees no view, and the line it gets names no team data.
  expect(viewModel(parseDoc(docText({ member_sessions: ['sess-m'], teams: [team()] })), ms(T0), 'sess-m')).toBe(null)
})

// ---- the sectioned Pane
const peer = (name: string, over: Record<string, unknown> = {}) => member({ name, label: name, kind: 'claude', route: 'peer', ...over })
const secs = (teams: unknown[], columns = 120) => paneSections(viewOf(teams), columns)
const titles = (teams: unknown[], columns = 120) => secs(teams, columns).map((x) => x.title)
const line = (r: { icon: string | null; text: string; indent: number }) => `${' '.repeat(r.indent)}${r.icon === null ? '' : r.icon + ' '}${r.text}`
const lineWidth = (r: { icon: string | null; text: string; indent: number }) => [...line(r)].length
const streamTeam = (over: Record<string, unknown> = {}) => team({
  members: [peer('lead'), peer('builder', { stream: 'api' }), peer('checker', { stream: 'api' }), peer('writer', { stream: 'docs', live: false })],
  dispatches: [dispatch({ id: 'd1', slug: 'fix-auth', member: 'builder', to_name: 'builder', label: 'builder' }), dispatch({ id: 'd2', slug: 'free-task', member: 'lead', to_name: 'lead', label: 'lead' })],
  ...over,
})
const PIPE = { anchor_id: 'a', started: T0, round_cap: 3, waiting_on_user: 0, items: [{ slug: 'ac', rounds: 2, open: true, to: 'reviewer' }] }

test('G1 no streams: one TEAM section with every member, no STREAM', async () => {
  const x = secs([team({ members: [peer('a'), peer('b')], dispatches: [] })])
  expect(x.map((z) => z.section)).toEqual(['team'])
  expect(x[0].rows.map((r) => r.text.split(' ')[0])).toEqual(['a', 'b'])
})

test('G2 streams by name after TEAM, G3 a dispatch to a streamed member sits in its stream after the members, indented 2', async () => {
  const x = secs([team({
    members: [peer('c'), peer('a', { stream: 'b' }), peer('b', { stream: 'a' })],
    dispatches: [dispatch({ member: 'a', slug: 'to-a' })],
  })])
  expect(x.map((z) => z.title)).toEqual(['TEAM default', 'STREAM a', 'STREAM b'])
  const b = x[2].rows
  expect(b.map((r) => r.indent)).toEqual([0, 2])
  expect(b[1].text.startsWith('to-a')).toBe(true)
  expect(b[1].icon).toBe(STYLE.icon.dispatchWork.glyph)
})

test('G4 a dispatch to an unknown or an unstreamed member goes to DISPATCHES; G5 no leftovers, no DISPATCHES, and no empty section but TEAM', async () => {
  const left = secs([team({ members: [peer('c'), peer('a', { stream: 'x' })], dispatches: [dispatch({ member: 'nobody', slug: 'one' }), dispatch({ id: 'd2', member: 'c', slug: 'two' })] })])
  expect(left.map((z) => z.title)).toEqual(['TEAM default', 'STREAM x', 'DISPATCHES'])
  expect(left[2].rows.map((r) => r.text.split(' ')[0]).sort()).toEqual(['one', 'two'])
  const none = secs([team({ members: [peer('c'), peer('a', { stream: 'x' })], dispatches: [dispatch({ member: 'a' })] })])
  expect(none.map((z) => z.section)).toEqual(['team', 'stream'])
  for (const z of [...left, ...none]) expect(z.rows.length > 0 || z.section === 'team').toBe(true)
})

test('G8 every member streamed: a title-only TEAM box, then the STREAM boxes', async () => {
  const x = secs([team({ members: [peer('a', { stream: 'x' }), peer('b', { stream: 'y' })], dispatches: [] })])
  expect(x.map((z) => z.title)).toEqual(['TEAM default', 'STREAM x', 'STREAM y'])
  expect(x[0].rows).toEqual([])
  expect(x.slice(1).every((z) => z.rows.length === 1)).toBe(true)
})

test('G9 a pipeline draws a HIERARCHY box with a row; no pipeline, no box; a team with nothing draws nothing of its own', async () => {
  const x = secs([team({ pipeline: { ...PIPE, waiting_on_user: 1 }, members: [peer('a')], dispatches: [] })])
  expect(x[0].section).toBe('hierarchy')
  expect(x[0].rows.map((r) => [r.icon, r.text])).toEqual([[null, 'round 2/3 · reviewer'], [null, '1 decision waiting for you']])
  expect(secs([team({ pipeline: { ...PIPE, items: [] }, members: [peer('a')], dispatches: [] })])[0].rows.map((r) => r.text)).toEqual(['Pipeline idle.'])
  expect(titles([team({ members: [peer('a')], dispatches: [] })])).toEqual(['TEAM default'])
  expect(secs([team({ members: [], dispatches: [] })]).map((z) => z.section)).toEqual(['none'])
})

test('I5 each team colors its streams from its own index; G6 a stream that is not a non-empty string is no stream', async () => {
  const x = secs([
    team({ team: 'one', members: [peer('a', { stream: 'x' }), peer('b', { stream: 'y' })], dispatches: [] }),
    team({ team: 'two', members: [peer('c', { stream: 'y' })], dispatches: [] }),
  ])
  expect(x.filter((z) => z.section === 'stream').map((z) => [z.title, z.color])).toEqual([['STREAM x', 'suggestion'], ['STREAM y', 'remember'], ['STREAM y', 'suggestion']])
  const odd = secs([team({ members: [peer('a', { stream: 42 }), peer('b', { stream: '' }), peer('c', { stream: null }), peer('d', { stream: ['x'] })], dispatches: [] })])
  expect(odd.map((z) => z.section)).toEqual(['team'])
  expect(odd[0].rows.length).toBe(4)
})

test('I1 icons and icon colors come from the one table; the text tone is unchanged', async () => {
  const members = [peer('w'), peer('i', { activity: 'idle' }), peer('b', { activity: 'blocked' }), peer('g', { live: false }), peer('u', { activity: 'thinking' })]
  const x = secs([team({ members, dispatches: [] })])[0].rows
  expect(x.map((r) => [r.icon, r.iconColor, r.tone])).toEqual([
    ['●', 'success', 'work'], ['○', null, 'idle'], ['■', 'warning', 'warn'], ['×', null, 'idle'], ['?', null, 'idle'],
  ])
  const sent = (state: string, i: number, extra: Record<string, unknown> = {}) => dispatch({ id: `d${i}`, slug: `s${i}`, member: 'zz', states: [{ at: at(-60000), state, ...extra }] })
  const ds = [sent('working', 0), sent('blocked', 1), sent('overdue', 2), sent('stalled', 3, { reason: 'no-report' }), sent('reported', 4)]
  const d = secs([team({ members: [], dispatches: ds })])[0].rows
  expect(d.map((r) => [r.text.split(' ')[0], r.icon, r.iconColor, r.tone]).sort()).toEqual([
    ['s0', '↳', 'success', 'work'], ['s1', '↳', 'warning', 'warn'], ['s2', '▲', 'error', 'bad'], ['s3', '▲', 'error', 'bad'], ['s4', '↳', null, 'idle'],
  ])
})

test('I2 every icon is one code point; I4 streams past the palette cycle with no undefined color; no box is a status color', async () => {
  for (const { glyph } of Object.values(STYLE.icon)) expect([...glyph].length).toBe(1)
  const x = secs([team({ members: ['a', 'b', 'c', 'd', 'e', 'f'].map((n) => peer(n, { stream: n })), dispatches: [] })])
  expect(x.filter((z) => z.section === 'stream').map((z) => z.color)).toEqual(['suggestion', 'remember', 'ide', 'planMode', 'suggestion', 'remember'])
  const status = ['success', 'warning', 'error']
  for (const z of secs([streamTeam({ pipeline: PIPE })])) expect(status.includes(z.color as string)).toBe(false)
  for (const c of [...Object.values(STYLE.box), ...STYLE.streams]) expect(status.includes(c as string)).toBe(false)
})

test('D1 from 40 columns every section is bordered and every row fits the inner width; D3 40 is the boundary', async () => {
  expect(BORDER_MIN).toBe(40)
  for (const columns of [40, 41, 60, 120]) {
    const x = secs([streamTeam({ pipeline: PIPE })], columns)
    expect(x.every((z) => z.bordered)).toBe(true)
    for (const z of x) {
      expect([...z.title].length).toBeLessThanOrEqual(columns - 2)
      for (const r of z.rows) expect(lineWidth(r)).toBeLessThanOrEqual(columns - 2)
    }
  }
  expect(secs([streamTeam()], 39).some((z) => z.bordered)).toBe(false)
})

test('D2 below 40 columns: no borders, lines fit, the icon and indent stay, and the last-tool part is dropped', async () => {
  const working = peer('builder', { stream: 'api', last_tool: 'Edit', last_tool_at: at(-12000), activity_at: at(-360000) })
  const wide = secs([team({ members: [working], dispatches: [dispatch({ member: 'builder' })] })], 120)
  expect(wide[1].rows[0].text).toContain(' · last Edit 12s')
  for (const columns of [39, 30, 24, 10]) {
    const x = secs([team({ members: [working, peer('lead')], dispatches: [dispatch({ member: 'builder', slug: 'fix-auth' })] })], columns)
    expect(x.some((z) => z.bordered)).toBe(false)
    const lines = x.flatMap((z) => z.rows)
    for (const r of lines) expect(lineWidth(r)).toBeLessThanOrEqual(columns)
    for (const z of x) expect([...z.title].length).toBeLessThanOrEqual(columns)
    expect(lines.some((r) => r.text.includes(' · last'))).toBe(false)
    expect(lines.every((r) => r.icon !== null)).toBe(true)
    expect(lines.some((r) => r.indent === 2)).toBe(true)
  }
  const x = secs([team({ members: [working], dispatches: [dispatch({ member: 'builder', slug: 'fix-auth' })] })], 30)
  expect(x[1].rows.map(line)).toEqual(['● builder working', '  ↳ fix-auth working'])
})

test('D4 no view, a malformed view, an empty pane and a view from before teams give one borderless section and never throw', async () => {
  const views: any[] = [null, undefined, 3, 'x', {}, { pane: 'x' }, { pane: [], teams: [] }, { pane: [{ row: 'text', tone: 'idle', text: 'older view' }] }, { pane: [], teams: 'x' }, { teams: [{ name: 'x', members: 3 }], pane: [] }]
  for (const view of views) {
    const x = paneSections(view, 60)
    expect(x.length).toBe(1)
    expect(x[0].bordered).toBe(false)
    expect(x[0].rows.length).toBeGreaterThan(0)
  }
  expect(paneSections({ pane: [{ row: 'text', tone: 'idle', text: 'older view' }] } as any, 60)[0].rows[0].text).toBe('older view')
  expect(paneSections(null, 60, 'no file')[0].rows[0].text).toBe('No hierarchy status here (no file).')
})

test('D5 the 60-column sample', async () => {
  const x = secs([streamTeam({ pipeline: PIPE })], 60)
  expect(x.map((z) => [z.title, z.color, z.rows.map(line)])).toEqual([
    ['HIERARCHY', 'claude', ['round 2/3 · reviewer']],
    ['TEAM default', 'permission', ['● lead · claude · peer · working']],
    ['STREAM api', 'suggestion', ['● builder · claude · peer · working', '● checker · claude · peer · working', '  ↳ fix-auth → builder | eta 5m | ██░░░░░░░░ 20% | 1:00 |…']],
    ['STREAM docs', 'remember', ['× writer · claude · peer · gone']],
    ['DISPATCHES', null, ['↳ free-ta… → lead | eta 5m | ██░░░░░░░░ 20% | 1:00 | work…']],
  ])
})

test('a focusable member row splits into the name (the click target) and the rest; a cut name is no target; others carry no focus', async () => {
  const mk = (over: Record<string, unknown>) => team({ members: [peer('builder', { focusable: true, ...over })], dispatches: [] })
  const row = (columns: number, over: Record<string, unknown> = {}) => secs([mk(over)], columns)[0].rows[0]
  expect([row(60).focus, row(60).text]).toEqual(['builder', ' · claude · peer · working'])
  expect([row(30).focus, row(30).text]).toEqual(['builder', ' working'])
  const long = 'a-very-long-member-name-here'
  expect(secs([team({ members: [peer(long, { focusable: true })], dispatches: [] })], 20)[0].rows[0].focus).toBe(null)
  for (const over of [{ focusable: false }, { focusable: 'true' }, { live: false }, { session_id: 'sess-orch' }]) expect(row(60, over).focus).toBe(null)
  expect(row(60, { session_id: 'someone-else' }).focus).toBe('builder')
  expect(secs([team({ members: [peer('builder')], dispatches: [] })])[0].rows[0].focus).toBe(null)
})

test('S13 a session listed in member_sessions draws no band, toast, Pane view or status entry, while its member is marked gone', async () => {
  const gone = team({ members: [member({ name: 'demo-architect', session_id: 'sess-orch', live: false, activity: 'idle' })], dispatches: [dispatch({ states: [{ at: at(-60000), state: 'stalled', reason: 'member-gone' }] })] })
  const text = docText({ member_sessions: ['sess-orch'], teams: [gone] }, { out: 1, blocked: 0, stalled: 1, tone: 'bad' })
  expect(statusText(parseDoc(text), ms(T0), 'sess-orch', true)).toBe(undefined)
  expect(viewModel(parseDoc(text), ms(T0), 'sess-orch')).toBe(null)
  expect(bandLine(viewModel(parseDoc(text), ms(T0), 'sess-orch'), 120)).toBe(null)
  expect(paneRows(viewModel(parseDoc(text), ms(T0), 'sess-orch'), 120, nullCause(parseDoc(text), ms(T0), 'sess-orch')).map((r) => r.text)).toEqual(['No hierarchy status here (member session).'])
  expect(statusText(parseDoc(text), ms(T0), 'some-other-session', true)).not.toBe(undefined)
})

// ---- toast_seconds
const MS = (...vals: unknown[]) => vals.map(toastMs)
test('T1 a missing or non-numeric value is the default', async () => {
  expect(MS(undefined, null, '', 'abc', NaN, Infinity, -Infinity, true, {})).toEqual(Array(9).fill(10000))
})
test('T2 ten is ten seconds', async () => { expect(MS(10, '10')).toEqual([10000, 10000]) })
test('T3 a number or a plain decimal string, trimmed, in range', async () => { expect(MS(30, ' 30 ', '30')).toEqual([30000, 30000, 30000]) })
test('T4 a fraction rounds to a whole second', async () => { expect(MS(2.4, 2.6)).toEqual([2000, 3000]) })
test('T5 below two seconds is two', async () => { expect(MS(1, '1', 1.4)).toEqual([2000, 2000, 2000]) })
test('T6 above 60 seconds is 60 (the host rejects a longer toast)', async () => { expect(MS(61, 121, 1e9, '120')).toEqual([60000, 60000, 60000, 60000]) })
test('T7 the result is 0 or a whole number of seconds from 2 to 60, for any input', async () => {
  const inputs: unknown[] = [undefined, null, '', 0, '0', -1, 0.4, 1, 2, 59.5, 120, 121, 1e300, -1e300, 'x', [], {}, [1], '12', ' 7.5 ', true, false, NaN]
  for (const v of inputs) {
    const ms = toastMs(v)
    expect(ms === 0 || (Number.isInteger(ms) && ms % 1000 === 0 && ms >= 2000 && ms <= 60000)).toBe(true)
  }
})
test('T8 exactly zero is off', async () => { expect(MS(0, '0', ' 0 ', '0.0', -0)).toEqual([0, 0, 0, 0, 0]) })
test('T9 any negative is the default, not off', async () => { expect(MS(-1, -5, '-30', -0.4, '-0.4')).toEqual(Array(5).fill(10000)) })
test('T10 a positive that rounds below two is two, not off', async () => { expect(MS(0.4, '0.4')).toEqual([2000, 2000]) })
test('T11 values Number() would coerce, or that are not plain decimals, are the default and never off', async () => {
  expect(MS('', '  ', false, [], [0], '1e3', '0x10', '10s', '+5', '.5', '5.', '1,5')).toEqual(Array(12).fill(10000))
})
