import { test, expect } from 'claude-code/testing'
import { fixtures } from './fixtures.ts'
import { vectors } from './vectors.ts'
import { bandLine, cut, paneRows, parseDoc, SIZE_CAP, statusText, utf8Bytes, viewModel } from '../view.ts'

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

test('band, working: out count, m:ss of T, oldest first, further items only while the line fits', async () => {
  const two = [team({ dispatches: [dispatch({ id: 'a', label: 'reviewer' }, 30000), dispatch({ id: 'b' }, 90000)] })]
  expect(band(two, { out: 2 })).toEqual({ text: '2 out · architect 1:30 of 5m · reviewer 0:30 of 5m', tone: 'work' })
  expect(band(two, { out: 2 }, T0, 40)).toEqual({ text: '2 out · architect 1:30 of 5m', tone: 'work' })
  expect(band(two, { out: 2 }, T0, 20)).toEqual({ text: '2 out · architect 1…', tone: 'work' })
})

test('band: none while the entry has nothing out and nothing blocked', async () => {
  expect(band([team()], { out: 0, blocked: 0 })).toBe(null)
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

test('Pane: pipeline lines, waiting decisions, and No pipeline run. when no item is open', async () => {
  const pipe = (items: unknown[], waiting = 0) => [team({ pipeline: { anchor_id: 'a', started: at(-600000), round_cap: 3, waiting_on_user: waiting, items } })]
  expect(rows(pipe([{ slug: 's', rounds: 2, open: true, to: 'reviewer' }, { slug: 't', rounds: 1, open: false, to: 'architect' }], 2)).slice(0, 3))
    .toEqual(['Hierarchy', 'round 2/3 · reviewer', '2 decisions waiting for you'])
  expect(rows(pipe([{ slug: 't', rounds: 1, open: false, to: 'architect' }])).slice(0, 2)).toEqual(['Hierarchy', 'No pipeline run.'])
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
