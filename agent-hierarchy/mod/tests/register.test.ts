import { test, expect, mock } from 'claude-code/testing'
import { fixtures } from './fixtures.ts'
import { sectionsFor, vectors } from './vectors.ts'
import { utf8Bytes } from '../view.ts'

const NOW = Date.parse('2026-01-01T12:00:00.000Z')
const REPO = '/work/repo'
const FILE = '/work/repo/.claude/hierarchy/status.json'

// What the staged engine answers: the session's cwd and id, the checkouts (dirs holding `.git`), the
// files, and a record of every entry set and every read.
type World = {
  cwd: string
  id: string
  git: string[]
  files: Record<string, { text: string; mtimeMs: number; kind?: string; isLink?: boolean; size?: number }>
  shown: (string | undefined)[]
  reads: number
  registered: unknown[]
  opens: unknown[]
  placed: boolean
  writes: { key: string; value: unknown }[]
  toasts: string[]
  toastCalls: any[]
  order: string[]
}
const world = (over: Partial<World> = {}): World => ({
  cwd: REPO + '/sub', id: 'sess-orch', git: [REPO], files: { [FILE]: { text: fixtures.work, mtimeMs: 1 } }, shown: [], reads: 0, registered: [], opens: [], placed: true, writes: [], toasts: [], toastCalls: [], order: [], ...over,
})

// Answers every $ call the module makes, from `w`; nothing real is read.
const stage = (on: any, w: World) => {
  on('session.start', (_$: any, e: any) => ({ cwd: e.cwd }))
  on('session.cwd', () => ({ value: w.cwd }))
  on('session.id', () => ({ value: w.id }))
  on('fs.exists', (_$: any, e: any) => ({ value: w.git.some((d) => e.path === d + '/.git') }))
  on('fs.stat', (_$: any, e: any) => {
    const f = w.files[e.path]
    return f ? { value: { kind: f.kind ?? 'file', size: f.size ?? utf8Bytes(f.text), mtimeMs: f.mtimeMs, isLink: f.isLink ?? false } } : { deny: 'no such file' }
  })
  on('fs.read', (_$: any, e: any) => {
    const f = w.files[e.path]
    w.reads++
    return f ? { value: f.text } : { deny: 'no such file' }
  })
  on('ui.status', (_$: any, e: any) => { w.shown.push(e.text); return { value: undefined } })
  on('command.register', (_$: any, e: any) => { w.registered.push(e); return { value: undefined } })
  on('ui.open', (_$: any, e: any) => { w.order.push('open'); w.opens.push(e); return { value: w.placed ? { isPlaced: true } : { isPlaced: false, reason: 'no surface places panes' } } })
  on('state.set', async (_$: any, e: any, next: any) => { w.order.push(`set:${e.key}`); w.writes.push({ key: e.key, value: e.value }); return next(e) })
  on('ui.toast', (_$: any, e: any) => { w.toasts.push(typeof e === 'string' ? e : e.text); w.toastCalls.push(e); return { value: undefined } })
}
const writesOf = (w: World, key: string) => w.writes.filter((x) => x.key === key).map((x) => x.value)
const start = ($: any, w: World, surface: string) => $.session.start({ cwd: w.cwd, surface, isInteractive: true })

// Another plugin that closes ah's Pane from its own command. A close it makes reaches ah's hook with origin
// `plugin`; the kit has no way to raise a person's close.
const CLOSER: any = {
  name: 'closer',
  register(on: any) {
    on('session.start', async ($: any, e: any, next: any) => { await $.command.register({ name: 'close-ah', description: 'closes ah-status' }); return next(e) })
    on('command.run', { command: 'close-ah' }, async ($: any) => {
      try { await $.ui.close({ id: 'ah-status' }); return { text: 'closed' } } catch (err) { return { text: `refused: ${String(err)}` } }
    })
  },
}

for (const surface of ['terminal', 'desktop'] as const) {
  test(`${surface}: session.start returns what next returned, and sets the entry from the doc`, { options: { status_entry: true } }, async ($, on) => {
    const w = world()
    stage(on, w)
    mock.clock(on, { now: NOW })
    expect(await start($, w, surface)).toEqual({ cwd: w.cwd })
    expect(w.shown).toEqual(['1 live · 1 out'])
  })

  test(`${surface}: the entry is set, then cleared when the file goes`, { options: { status_entry: true } }, async ($, on) => {
    const w = world()
    stage(on, w)
    const clock = mock.clock(on, { now: NOW })
    await start($, w, surface)
    delete w.files[FILE]
    await clock.advance(2000)
    expect(w.shown).toEqual(['1 live · 1 out', undefined])
  })

  test(`${surface}: a missing file sets nothing`, async ($, on) => {
    const w = world({ files: {} })
    stage(on, w)
    const clock = mock.clock(on, { now: NOW })
    await start($, w, surface)
    await clock.advance(4000)
    expect(w.shown).toEqual([undefined])
    expect(w.reads).toBe(0)
  })

  test(`${surface}: no git checkout above the cwd sets nothing and reads nothing`, async ($, on) => {
    const w = world({ git: [] })
    stage(on, w)
    mock.clock(on, { now: NOW })
    await start($, w, surface)
    expect(w.shown).toEqual([undefined])
    expect(w.reads).toBe(0)
  })

  test(`${surface}: the clock moves the entry along the timeline`, { options: { status_entry: true } }, async ($, on) => {
    const w = world()
    stage(on, w)
    const clock = mock.clock(on, { now: NOW })
    await start($, w, surface)
    await clock.advance(240000)
    expect(w.shown).toEqual(['1 live · 1 out', '1 live · 1 out · 1 overdue'])
  })

  test(`${surface}: the file is read again only when its mtime changes`, { options: { status_entry: true } }, async ($, on) => {
    const w = world()
    stage(on, w)
    const clock = mock.clock(on, { now: NOW })
    await start($, w, surface)
    await clock.advance(6000)
    expect(w.reads).toBe(1)
    w.files[FILE] = { text: fixtures.idle, mtimeMs: 2 }
    await clock.advance(2000)
    expect(w.reads).toBe(2)
    expect(w.shown).toEqual(['1 live · 1 out', '2 live · 0 out'])
  })

  const notRead = (label: string, over: { kind?: string; isLink?: boolean; size?: number }) =>
    test(`${surface}: ${label} is absent and not read`, async ($, on) => {
      const w = world({ files: { [FILE]: { text: fixtures.work, mtimeMs: 1, ...over } } })
      stage(on, w)
      mock.clock(on, { now: NOW })
      await start($, w, surface)
      expect(w.reads).toBe(0)
      expect(w.shown).toEqual([undefined])
    })
  notRead('a symbolic link', { isLink: true })
  notRead('a FIFO or device', { kind: 'other' })
  notRead('a directory', { kind: 'dir' })
  notRead('an empty file', { size: 0 })

  test(`${surface}: a regular non-empty file is shown`, { options: { status_entry: true } }, async ($, on) => {
    const w = world({ files: { [FILE]: { text: fixtures.work, mtimeMs: 1, kind: 'file', isLink: false } } })
    stage(on, w)
    mock.clock(on, { now: NOW })
    await start($, w, surface)
    expect(w.reads).toBe(1)
    expect(w.shown).toEqual(['1 live · 1 out'])
  })

  test(`${surface}: a file over 262,144 bytes is not read`, async ($, on) => {
    const w = world({ files: { [FILE]: { text: fixtures.work + ' '.repeat(262144), mtimeMs: 1 } } })
    stage(on, w)
    mock.clock(on, { now: NOW })
    await start($, w, surface)
    expect(w.reads).toBe(0)
    expect(w.shown).toEqual([undefined])
  })

  test(`${surface}: a cwd change finds the other checkout's file`, { options: { status_entry: true } }, async ($, on) => {
    const other = '/other/repo/.claude/hierarchy/status.json'
    const w = world({ git: [REPO, '/other/repo'] })
    w.files[other] = { text: fixtures.idle, mtimeMs: 5 }
    stage(on, w)
    const clock = mock.clock(on, { now: NOW })
    await start($, w, surface)
    w.cwd = '/other/repo'
    await clock.advance(2000)
    w.cwd = '/elsewhere'
    await clock.advance(2000)
    expect(w.shown).toEqual(['1 live · 1 out', '2 live · 0 out', undefined])
  })

  test(`${surface}: a member session sets nothing`, async ($, on) => {
    const w = world({ id: 'sess-demo-reviewer', files: { [FILE]: { text: fixtures['member-session'], mtimeMs: 1 } } })
    stage(on, w)
    mock.clock(on, { now: NOW })
    await start($, w, surface)
    expect(w.shown).toEqual([undefined])
  })

  test(`${surface}: a session whose id becomes a member's hides the entry at the next tick`, { options: { status_entry: true } }, async ($, on) => {
    const w = world({ files: { [FILE]: { text: fixtures['member-session'], mtimeMs: 1 } } })
    stage(on, w)
    const clock = mock.clock(on, { now: NOW })
    await start($, w, surface)
    w.id = 'sess-demo-reviewer'
    await clock.advance(2000)
    expect(w.shown).toEqual(['1 live · 1 out', undefined])
  })

  test(`${surface}: status_entry false clears the entry at once, so a reload with it off leaves no old line`, { options: { status_entry: false } }, async ($, on) => {
    const w = world()
    stage(on, w)
    mock.clock(on, { now: NOW })
    await start($, w, surface)
    expect(w.shown).toEqual([undefined])
  })

  test(`${surface}: with no options the entry is off`, async ($, on) => {
    const w = world()
    stage(on, w)
    mock.clock(on, { now: NOW })
    await start($, w, surface)
    expect(w.shown).toEqual([undefined])
  })

  test(`${surface}: status_entry true shows the entry`, { options: { status_entry: true } }, async ($, on) => {
    const w = world()
    stage(on, w)
    mock.clock(on, { now: NOW })
    await start($, w, surface)
    expect(w.shown).toEqual(['1 live · 1 out'])
  })

  // ---- the band and the Pane, drawn through the module's ui.render hooks
  for (const [name, v] of Object.entries(vectors)) {
    test(`${surface}: ${name} draws its band above the chain's answer and its Pane rows, Box, Text and engine only`, async ($, on) => {
      const w = world({ id: v.sessionId, files: { [FILE]: { text: fixtures[name], mtimeMs: 1 } } })
      stage(on, w)
      beneath(on)
      mock.clock(on, { now: Date.parse(v.now) })
      await start($, w, surface)
      const band = await (await $.ui.mount({ plugin: 'ah', surface, component: 'AbovePrompt', props: bandProps(), viewport: VIEWPORT })).drawn()
      expect(walk(band, ['Button'])).toEqual([])
      expect(texts(band)).toEqual(v.band === null ? [CORE_LINE] : [{ text: v.band.text, props: TONE[v.band.tone] }, CORE_LINE])
      const pane = await (await $.ui.mount({ plugin: 'ah', surface, component: 'Pane', requestId: 'ah-status', props: paneProps(), viewport: VIEWPORT })).drawn()
      expect(walk(pane)).toEqual([])
      // A null view's one line names its cause; every other vector draws exactly its rows.
      const cause = NULL_CAUSE[name]
      if (cause === undefined) expect(boxes(pane)).toEqual(sectionsFor[name].map((b) => ({ ...b, bordered: true })))
      else expect(texts(pane)).toEqual([{ text: `No hierarchy status here (${cause}).`, props: TONE.idle }])
    })
  }

  test(`${surface}: the band draws a Pane button after its text, and pressing it clears the closed mark before one open`, async ($, on) => {
    const w = world()
    stage(on, w)
    beneath(on)
    mock.clock(on, { now: NOW })
    await start($, w, surface)
    const ui = await $.ui.mount({ plugin: 'ah', surface, component: 'AbovePrompt', props: bandProps(), viewport: VIEWPORT })
    expect(buttons(await ui.drawn()).length).toBe(1)
    const before = w.opens.length
    w.order.length = 0
    await ui.press({ key: 'ah-pane' })
    expect(w.order).toEqual(['set:closed', 'open'])
    expect(writesOf(w, 'closed')).toEqual([false])
    expect(w.opens.slice(before)).toEqual([{ id: 'ah-status', title: 'Hierarchy' }])
    expect(w.toasts).toEqual([])
  })

  test(`${surface}: a press that places no Pane toasts the not-placed text`, async ($, on) => {
    const w = world({ placed: false })
    stage(on, w)
    beneath(on)
    mock.clock(on, { now: NOW })
    await start($, w, surface)
    const ui = await $.ui.mount({ plugin: 'ah', surface, component: 'AbovePrompt', props: bandProps(), viewport: VIEWPORT })
    await ui.press({ key: 'ah-pane' })
    expect(w.toasts).toEqual(['The hierarchy Pane is open, but this session shows no panes.'])
  })

  const draw = async ($: any, surface: string, props: any) => buttons(await (await $.ui.mount({ plugin: 'ah', surface, component: 'AbovePrompt', props, viewport: VIEWPORT })).drawn())

  test(`${surface}: the band draws no button in a member session`, async ($, on) => {
    const w = world({ id: 'sess-demo-reviewer', files: { [FILE]: { text: fixtures['member-session'], mtimeMs: 1 } } })
    stage(on, w)
    beneath(on)
    mock.clock(on, { now: NOW })
    await start($, w, surface)
    expect(await draw($, surface, bandProps())).toEqual([])
  })

  test(`${surface}: the band draws no button during a survey or below 40 columns, and below 40 its text is unfitted`, async ($, on) => {
    const w = world()
    stage(on, w)
    beneath(on)
    mock.clock(on, { now: NOW })
    await start($, w, surface)
    expect(await draw($, surface, bandProps({ hasSurvey: true }))).toEqual([])
    expect(await draw($, surface, bandProps({ bodyColumns: 39 }))).toEqual([])
    const narrow = await (await $.ui.mount({ plugin: 'ah', surface, component: 'AbovePrompt', props: bandProps({ bodyColumns: 39 }), viewport: VIEWPORT })).drawn()
    expect(texts(narrow)[0].text).toBe('1 out · architect 1:00 of 5m')
  })

  const hiddenCases = [
    ['an invisible entry', 'sess-orch', (d: any) => { d.timeline[0].visible = false }],
    ['a member session', 'sess-member', (d: any) => { d.member_sessions = [...d.member_sessions, 'sess-member'] }],
  ] as const
  for (const [label, id, edit] of hiddenCases) test(`${surface}: the band draws no button when there is no band (${label})`, async ($, on) => {
    const doc = JSON.parse(fixtures.idle)
    edit(doc)
    const w = world({ id, files: { [FILE]: { text: JSON.stringify(doc), mtimeMs: 1 } } })
    stage(on, w)
    beneath(on)
    mock.clock(on, { now: NOW })
    await start($, w, surface)
    expect(await draw($, surface, bandProps())).toEqual([])
  })

  const E_DOC = (teams: unknown) => JSON.stringify({
    schema: 1, written_at: '2026-01-01T12:00:00.000Z', expires_at: '2026-01-02T12:00:00.000Z', enabled: true, member_sessions: [], teams,
    timeline: [{ at: '2026-01-01T12:00:00.000Z', live: 3, blocked: 0, out: 0, overdue: 0, stalled: 0, text: '3 live · 0 out', short: '3/0', tone: 'idle', visible: true }],
  })
  for (const [label, teams] of [['teams: []', []], ['teams holding only non-records', [1, 'x']]] as const) {
    test(`${surface}: a visible doc with ${label} draws one dim line saying so, and the band shows the entry text`, async ($, on) => {
      const w = world({ files: { [FILE]: { text: E_DOC(teams), mtimeMs: 1 } } })
      stage(on, w)
      beneath(on)
      mock.clock(on, { now: NOW })
      await start($, w, surface)
      const pane = await (await $.ui.mount({ plugin: 'ah', surface, component: 'Pane', requestId: 'ah-status', props: paneProps(), viewport: VIEWPORT })).drawn()
      expect(texts(pane)).toEqual([{ text: 'No live team in the status file.', props: TONE.idle }])
      const band = await (await $.ui.mount({ plugin: 'ah', surface, component: 'AbovePrompt', props: bandProps(), viewport: VIEWPORT })).drawn()
      expect(texts(band)).toEqual([{ text: '3 live · 0 out', props: TONE.idle }, CORE_LINE])
    })
  }

  for (const value of [{}, { pane: 'x' }, 7]) {
    test(`${surface}: a held view of ${JSON.stringify(value)} draws the null-view line, not the engine's fallback`, async ($, on) => {
      const w = world({ files: { [FILE]: { text: E_DOC([]), mtimeMs: 1 } } })
      stage(on, w)
      beneath(on)
      // What the host holds for `view`, whatever an older or newer build of the module left there.
      on('state.get', async (_$: any, e: any, next: any) => (e.key === 'view' ? { value, version: 1 } : next(e)))
      mock.clock(on, { now: NOW })
      await start($, w, surface)
      const pane = await (await $.ui.mount({ plugin: 'ah', surface, component: 'Pane', requestId: 'ah-status', props: paneProps(), viewport: VIEWPORT })).drawn()
      expect(texts(pane).length).toBe(1)
      expect(texts(pane)[0].text.startsWith('No hierarchy status here')).toBe(true)
    })
  }

  const asDoc = (fixture: string, over: Record<string, unknown>) => JSON.stringify({ ...JSON.parse(fixture), ...over })
  const CAUSES: [string, () => World, string][] = [
    ['no file', () => world({ files: {} }), 'no file'],
    ['a file that is not JSON', () => world({ files: { [FILE]: { text: 'not json {', mtimeMs: 1 } } }), 'unreadable'],
    ['a file that is a link', () => world({ files: { [FILE]: { text: fixtures.work, mtimeMs: 1, isLink: true } } }), 'unreadable'],
    ['an expired doc', () => world({ files: { [FILE]: { text: asDoc(fixtures.work, { expires_at: '2026-01-01T11:00:00.000Z' }), mtimeMs: 1 } } }), 'expired'],
    ['a doc that says the hierarchy is off', () => world({ files: { [FILE]: { text: fixtures.hidden, mtimeMs: 1 } } }), 'hierarchy off'],
    ['a doc that is not visible while enabled', () => world({ files: { [FILE]: { text: asDoc(fixtures.hidden, { enabled: true }), mtimeMs: 1 } } }), 'not visible'],
    ['a member session', () => world({ id: 'sess-demo-reviewer', files: { [FILE]: { text: fixtures['member-session'], mtimeMs: 1 } } }), 'member session'],
  ]
  for (const [label, make, cause] of CAUSES) {
    test(`${surface}: the empty Pane names its cause: ${label} -> ${cause}`, async ($, on) => {
      const w = make()
      stage(on, w)
      beneath(on)
      mock.clock(on, { now: NOW })
      await start($, w, surface)
      const pane = await (await $.ui.mount({ plugin: 'ah', surface, component: 'Pane', requestId: 'ah-status', props: paneProps(), viewport: VIEWPORT })).drawn()
      expect(texts(pane)).toEqual([{ text: `No hierarchy status here (${cause}).`, props: TONE.idle }])
    })
  }

  test(`${surface}: the cause follows the file: a doc that becomes visible drops it, and a doc that goes away names it`, async ($, on) => {
    const w = world({ files: { [FILE]: { text: asDoc(fixtures.hidden, { enabled: true }), mtimeMs: 1 } } })
    stage(on, w)
    beneath(on)
    const clock = mock.clock(on, { now: NOW })
    await start($, w, surface)
    const ui = await $.ui.mount({ plugin: 'ah', surface, component: 'Pane', requestId: 'ah-status', props: paneProps(), viewport: VIEWPORT })
    expect(texts(await ui.drawn())[0].text).toBe('No hierarchy status here (not visible).')
    w.files[FILE] = { text: fixtures.work, mtimeMs: 2 }
    await clock.advance(2000)
    expect(texts(await ui.drawn()).some((t) => t.text.startsWith('No hierarchy status here'))).toBe(false)
    delete w.files[FILE]
    await clock.advance(2000)
    expect(texts(await ui.drawn())).toEqual([{ text: 'No hierarchy status here (no file).', props: TONE.idle }])
  })

  test(`${surface}: the band yields to the chain during a survey`, async ($, on) => {
    const w = world({ files: { [FILE]: { text: fixtures.bad, mtimeMs: 1 } } })
    stage(on, w)
    beneath(on)
    mock.clock(on, { now: Date.parse(vectors.bad.now) })
    await start($, w, surface)
    const band = await (await $.ui.mount({ plugin: 'ah', surface, component: 'AbovePrompt', props: bandProps({ hasSurvey: true }), viewport: VIEWPORT })).drawn()
    expect(band).toMatchObject(CORE)
    expect(texts(band)).toEqual([CORE_LINE])
  })

  test(`${surface}: a view change redraws a mounted band, and its going leaves the chain's answer`, async ($, on) => {
    const w = world()
    stage(on, w)
    beneath(on)
    const clock = mock.clock(on, { now: NOW })
    await start($, w, surface)
    const ui = await $.ui.mount({ plugin: 'ah', surface, component: 'AbovePrompt', props: bandProps(), viewport: VIEWPORT })
    expect(texts(await ui.drawn())[0].text).toBe('1 out · architect 1:00 of 5m')
    await clock.advance(2000)
    expect(texts(await ui.drawn())[0].text).toBe('1 out · architect 1:02 of 5m')
    delete w.files[FILE]
    await clock.advance(2000)
    expect(texts(await ui.drawn())).toEqual([CORE_LINE])
  })

  test(`${surface}: the tick writes the view only when it changed`, async ($, on) => {
    const w = world({ files: { [FILE]: { text: fixtures.idle, mtimeMs: 1 } } })
    stage(on, w)
    const clock = mock.clock(on, { now: NOW })
    await start($, w, surface)
    expect(writesOf(w, 'view').length).toBe(1)
    await clock.advance(4000)
    expect(writesOf(w, 'view').length).toBe(1)
    w.files[FILE] = { text: fixtures.work, mtimeMs: 2 }
    await clock.advance(2000)
    expect(writesOf(w, 'view').length).toBe(2)
  })

  for (const [name, now, text, props] of [
    ['bad', Date.parse(vectors.bad.now), vectors.bad.band?.text, { color: 'warning', bold: true }],
    ['warn', Date.parse(vectors.warn.now), vectors.warn.band?.text, { color: 'warning' }],
    ['work', NOW, '1 out · architect 1:00 of 5m', {}],
  ] as const) {
    test(`${surface}: the ${name} band's Text props are ${JSON.stringify(props)}`, async ($, on) => {
      const w = world({ files: { [FILE]: { text: fixtures[name], mtimeMs: 1 } } })
      stage(on, w)
      beneath(on)
      mock.clock(on, { now })
      await start($, w, surface)
      const band = await (await $.ui.mount({ plugin: 'ah', surface, component: 'AbovePrompt', props: bandProps(), viewport: VIEWPORT })).drawn()
      expect(texts(band)[0]).toEqual({ text, props })
    })
  }

  test(`${surface}: a tone the table does not name draws dim`, async ($, on) => {
    const odd = { band: { tone: 'odd', head: 'odd band', tail: [] }, pane: [{ row: 'text', tone: 'odd', text: 'odd row' }], toasts: [] }
    on('state.get', async (_$: any, e: any, next: any) => (e.key === 'view' ? { value: { value: odd, version: 1 } } : next(e)))
    const w = world()
    stage(on, w)
    beneath(on)
    mock.clock(on, { now: NOW })
    await start($, w, surface)
    const band = await (await $.ui.mount({ plugin: 'ah', surface, component: 'AbovePrompt', props: bandProps(), viewport: VIEWPORT })).drawn()
    expect(texts(band)[0]).toEqual({ text: 'odd band', props: { dimColor: true } })
    const pane = await (await $.ui.mount({ plugin: 'ah', surface, component: 'Pane', requestId: 'ah-status', props: paneProps(), viewport: VIEWPORT })).drawn()
    expect(texts(pane)).toEqual([{ text: 'odd row', props: { dimColor: true } }])
  })

  test(`${surface}: another component, and another Pane, pass through`, async ($, on) => {
    const w = world({ files: { [FILE]: { text: fixtures.bad, mtimeMs: 1 } } })
    stage(on, w)
    beneath(on)
    mock.clock(on, { now: Date.parse(vectors.bad.now) })
    await start($, w, surface)
    const other = await (await $.ui.mount({ plugin: 'ah', surface, component: 'Pane', requestId: 'other', props: paneProps(), viewport: VIEWPORT })).drawn()
    expect(other).toMatchObject(CORE)
    expect(texts(other)).toEqual([CORE_LINE])
  })

  // ---- /hierarchy-pane, auto-open and close
  test(`${surface}: session.start registers /hierarchy-pane`, async ($, on) => {
    const w = world()
    stage(on, w)
    mock.clock(on, { now: NOW })
    await start($, w, surface)
    expect(w.registered).toEqual([{ name: 'hierarchy-pane', description: 'Open the hierarchy status Pane' }])
  })

  for (const placed of [true, false]) {
    test(`${surface}: /hierarchy-pane with no status file opens the Pane and answers with text alone (placed ${placed})`, async ($, on) => {
      const w = world({ files: {}, placed })
      on('command.run', { command: 'hierarchy-pane' }, () => ({ text: 'beneath', context: ['sent to the model'], exitCode: 3 }))
      stage(on, w)
      mock.clock(on, { now: NOW })
      await start($, w, surface)
      const answer = await $.command.run({ command: 'hierarchy-pane', args: '' })
      expect(answer).toEqual({ text: placed ? 'Opened the hierarchy Pane.' : 'The hierarchy Pane is open, but this session shows no panes.' })
      expect(w.opens).toEqual([{ id: 'ah-status', title: 'Hierarchy' }])
    })
  }

  for (const [when, now] of [['current', NOW], ['expired', Date.parse('2030-01-01T00:00:00.000Z')]] as const) {
    test(`${surface}: /hierarchy-pane in a member session opens nothing and says why (doc ${when})`, async ($, on) => {
      const w = world({ id: 'sess-demo-reviewer', files: { [FILE]: { text: fixtures['member-session'], mtimeMs: 1 } } })
      on('command.run', { command: 'hierarchy-pane' }, () => ({ text: 'beneath', context: ['sent to the model'], exitCode: 3 }))
      stage(on, w)
      mock.clock(on, { now })
      await start($, w, surface)
      expect(await $.command.run({ command: 'hierarchy-pane', args: '' })).toEqual({ text: 'The hierarchy view is hidden in member sessions.' })
      expect(w.opens).toEqual([])
    })
  }

  test(`${surface}: a session that stops being a member gets the Pane at the next tick`, async ($, on) => {
    const w = world({ id: 'sess-demo-reviewer', files: { [FILE]: { text: fixtures['member-session'], mtimeMs: 1 } } })
    stage(on, w)
    const clock = mock.clock(on, { now: NOW })
    await start($, w, surface)
    w.id = 'sess-orch'
    await clock.advance(2000)
    w.opens.length = 0
    expect(await $.command.run({ command: 'hierarchy-pane', args: '' })).toEqual({ text: 'Opened the hierarchy Pane.' })
    expect(w.opens).toEqual([{ id: 'ah-status', title: 'Hierarchy' }])
  })

  test(`${surface}: another command is not answered`, async ($, on) => {
    const w = world({ files: {} })
    on('command.run', { command: 'other' }, () => ({ text: 'other ran' }))
    stage(on, w)
    mock.clock(on, { now: NOW })
    await start($, w, surface)
    expect(await $.command.run({ command: 'other', args: '' })).toEqual({ text: 'other ran' })
    expect(w.opens).toEqual([])
  })

  for (const placed of [true, false]) {
    test(`${surface}: auto-open fires once, when there is first a view (placed ${placed})`, async ($, on) => {
      const w = world({ files: {}, placed })
      stage(on, w)
      const clock = mock.clock(on, { now: NOW })
      await start($, w, surface)
      expect(w.opens).toEqual([])
      w.files[FILE] = { text: fixtures.work, mtimeMs: 1 }
      await clock.advance(2000)
      expect(w.opens).toEqual([{ id: 'ah-status', title: 'Hierarchy' }])
      await clock.advance(6000)
      expect(w.opens.length).toBe(1)
      expect(writesOf(w, 'opened')).toEqual([true])
    })
  }

  test(`${surface}: auto-open never fires in a member session`, async ($, on) => {
    const w = world({ id: 'sess-demo-reviewer', files: { [FILE]: { text: fixtures['member-session'], mtimeMs: 1 } } })
    stage(on, w)
    const clock = mock.clock(on, { now: NOW })
    await start($, w, surface)
    await clock.advance(4000)
    expect(w.opens).toEqual([])
  })

  test(`${surface}: auto-open does not fire again after a reload`, async ($, on) => {
    const w = world()
    stage(on, w)
    const clock = mock.clock(on, { now: NOW })
    await start($, w, surface)
    expect(w.opens.length).toBe(1)
    await start($, w, surface)
    await clock.advance(2000)
    expect(w.opens.length).toBe(1)
  })

  test(`${surface}: auto-open never fires while the Pane is marked closed`, async ($, on) => {
    on('state.get', async (_$: any, e: any, next: any) => (e.key === 'closed' ? { value: { value: true, version: 1 } } : next(e)))
    const w = world({ files: {} })
    stage(on, w)
    const clock = mock.clock(on, { now: NOW })
    await start($, w, surface)
    w.files[FILE] = { text: fixtures.work, mtimeMs: 1 }
    await clock.advance(4000)
    expect(w.opens).toEqual([])
    expect(writesOf(w, 'opened')).toEqual([])
  })

  test(`${surface}: /hierarchy-pane clears the closed mark before it opens the Pane`, async ($, on) => {
    const w = world({ files: {} })
    stage(on, w)
    mock.clock(on, { now: NOW })
    await start($, w, surface)
    await $.command.run({ command: 'hierarchy-pane', args: '' })
    expect(writesOf(w, 'closed')).toEqual([false])
    expect(w.opens).toEqual([{ id: 'ah-status', title: 'Hierarchy' }])
  })

  test(`${surface}: a close by a plugin does not mark the Pane closed`, { plugins: [CLOSER] }, async ($, on) => {
    const w = world({ files: {} })
    on('ui.close', () => ({ value: undefined }))
    stage(on, w)
    mock.clock(on, { now: NOW })
    await start($, w, surface)
    expect(await $.command.run({ command: 'close-ah', args: '' })).toEqual({ text: 'closed' })
    expect(writesOf(w, 'closed')).toEqual([])
  })

  for (const [beneathAnswer, expected] of [[{ value: undefined }, 'closed'], [{ deny: 'kept open beneath' }, 'kept open beneath']] as const) {
    test(`${surface}: ui.close calls next exactly once and returns what it returned (${expected})`, { plugins: [CLOSER] }, async ($, on) => {
      const w = world({ files: {} })
      let calls = 0
      on('ui.close', () => { calls++; return beneathAnswer })
      stage(on, w)
      mock.clock(on, { now: NOW })
      await start($, w, surface)
      const answer: any = await $.command.run({ command: 'close-ah', args: '' })
      expect(calls).toBe(1)
      expect(answer.text).toContain(expected)
    })
  }


  // ---- toasts
  test(`${surface}: the first view seeds the seen set and toasts nothing`, async ($, on) => {
    const w = world({ files: { [FILE]: { text: fixtures.bad, mtimeMs: 1 } } })
    stage(on, w)
    const clock = mock.clock(on, { now: Date.parse(vectors.bad.now) })
    await start($, w, surface)
    await clock.advance(4000)
    expect(w.toasts).toEqual([])
    expect(writesOf(w, 'seen')).toEqual([vectors.bad.toasts.map((t) => t.key)])
  })

  test(`${surface}: a new key toasts once, with its text, and not again`, async ($, on) => {
    const w = world({ files: { [FILE]: { text: fixtures.idle, mtimeMs: 1 } } })
    stage(on, w)
    const clock = mock.clock(on, { now: NOW })
    await start($, w, surface)
    w.files[FILE] = { text: fixtures.warn, mtimeMs: 2 }
    await clock.advance(2000)
    expect(w.toasts).toEqual(['architect blocked · Allow edits to config.toml? (y/n)'])
    w.files[FILE] = { text: fixtures.warn, mtimeMs: 3 }
    await clock.advance(6000)
    expect(w.toasts.length).toBe(1)
    expect(writesOf(w, 'seen')).toEqual([[], [vectors.warn.toasts[0].key]])
  })

  test(`${surface}: a tick with no view neither prunes nor toasts again`, async ($, on) => {
    const w = world({ files: { [FILE]: { text: fixtures.idle, mtimeMs: 1 } } })
    stage(on, w)
    const clock = mock.clock(on, { now: NOW })
    await start($, w, surface)
    w.files[FILE] = { text: fixtures.warn, mtimeMs: 2 }
    await clock.advance(2000)
    delete w.files[FILE]
    await clock.advance(2000)
    w.files[FILE] = { text: fixtures.warn, mtimeMs: 3 }
    await clock.advance(2000)
    expect(w.toasts.length).toBe(1)
    expect(writesOf(w, 'seen')).toEqual([[], [vectors.warn.toasts[0].key]])
  })

  test(`${surface}: a member session toasts nothing and seeds nothing`, async ($, on) => {
    const doc = JSON.parse(fixtures.warn)
    doc.member_sessions = [...doc.member_sessions, 'sess-member']
    const w = world({ id: 'sess-member', files: { [FILE]: { text: JSON.stringify(doc), mtimeMs: 1 } } })
    stage(on, w)
    const clock = mock.clock(on, { now: NOW })
    await start($, w, surface)
    await clock.advance(4000)
    expect(w.toasts).toEqual([])
    expect(writesOf(w, 'seen')).toEqual([])
  })

  test(`${surface}: the seen set outlives a reload, so a key does not toast twice`, async ($, on) => {
    const w = world({ files: { [FILE]: { text: fixtures.idle, mtimeMs: 1 } } })
    stage(on, w)
    const clock = mock.clock(on, { now: NOW })
    await start($, w, surface)
    w.files[FILE] = { text: fixtures.warn, mtimeMs: 2 }
    await clock.advance(2000)
    await start($, w, surface)
    await clock.advance(4000)
    expect(w.toasts.length).toBe(1)
  })

  test(`${surface}: a key is pruned once its dispatch leaves the doc, and toasts if it comes back`, async ($, on) => {
    const w = world({ files: { [FILE]: { text: fixtures.bad, mtimeMs: 1 } } })
    stage(on, w)
    const clock = mock.clock(on, { now: Date.parse(vectors.bad.now) })
    await start($, w, surface)
    w.files[FILE] = { text: fixtures.idle, mtimeMs: 2 }
    await clock.advance(2000)
    expect(writesOf(w, 'seen').at(-1)).toEqual([])
    w.files[FILE] = { text: fixtures.bad, mtimeMs: 3 }
    await clock.advance(2000)
    expect(w.toasts).toEqual(vectors.bad.toasts.map((t) => t.text))
  })

  test(`${surface}: a member still in the doc keeps its key, so the same block does not toast again`, async ($, on) => {
    const w = world({ files: { [FILE]: { text: fixtures.idle, mtimeMs: 1 } } })
    stage(on, w)
    const clock = mock.clock(on, { now: NOW })
    await start($, w, surface)
    w.files[FILE] = { text: fixtures.warn, mtimeMs: 2 }
    await clock.advance(2000)
    w.files[FILE] = { text: fixtures.idle, mtimeMs: 3 }
    await clock.advance(2000)
    w.files[FILE] = { text: fixtures.warn, mtimeMs: 4 }
    await clock.advance(2000)
    expect(w.toasts.length).toBe(1)
  })

}

// What the chain beneath the module answers for the band, and for any Pane but the module's.
const CORE = { type: 'Text', children: ['core'] }
const CORE_LINE = { text: 'core', props: {} }
function beneath(on: any) {
  on('ui.render', { component: 'AbovePrompt' }, () => CORE)
  on('ui.render', { component: 'Pane' }, () => CORE)
}
const VIEWPORT = { columns: 125, rows: 40 }
// The vectors whose view is null, and the cause the empty Pane's line names for each.
const NULL_CAUSE: Record<string, string> = { hidden: 'hierarchy off', 'member-session': 'member session' }
const bandProps = (over: Record<string, unknown> = {}): any =>
  ({ hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 120, scroll: { offset: 0, bodyRows: 10 }, view: {}, ...over })
const paneProps = (): any => ({ title: 'Hierarchy', isFocused: false, bodyColumns: 120, placement: 'inline', scroll: { offset: 0, bodyRows: 20 }, view: {} })
// The Text props each tone draws with, as the spec's table pins them.
const TONE: Record<string, Record<string, unknown>> = { bad: { color: 'warning', bold: true }, warn: { color: 'warning' }, work: {}, idle: { dimColor: true } }

// The Pane's sections as drawn: per top-level Box, its border color (null: dim), whether it has a border, its bold
// title, and each row Box's Texts joined (indent, icon, text).
function boxes(n: any): { title: string; color: string | null; bordered: boolean; lines: string[] }[] {
  return (n.children ?? []).map((b: any) => {
    const kids = (b.children ?? []).filter(Boolean)
    const title = kids[0]?.type === 'Text' && kids[0].props?.bold === true ? kids[0] : null
    const rows = title ? kids.slice(1) : kids
    return {
      title: title ? (title.children ?? []).join('') : '',
      color: b.props?.borderColor ?? null,
      bordered: b.props?.borderStyle === 'round',
      lines: rows.map((r: any) => (r.children ?? []).filter(Boolean).map((t: any) => (t.children ?? []).join('')).join('')),
    }
  })
}

// Every Text in the tree, in document order, with its props.
function texts(n: any): { text: string; props: Record<string, unknown> }[] {
  if (typeof n !== 'object' || n === null) return []
  if (n.type === 'Text') return [{ text: (n.children ?? []).join(''), props: n.props ?? {} }]
  return (n.children ?? []).flatMap(texts)
}
// Every Button in the tree.
function buttons(n: any): any[] {
  if (typeof n !== 'object' || n === null) return []
  return [...(n.type === 'Button' ? [n] : []), ...(n.children ?? []).flatMap(buttons)]
}
// What a drawn tree holds that a status view may not: an element other than Box, Text or core's engine, or a
// node carrying a press, client or raster key.
function walk(n: any, extra: string[] = []): string[] {
  if (typeof n !== 'object' || n === null) return []
  const found = ['Box', 'Text', 'engine', ...extra].includes(n.type) ? [] : [`element ${n.type}`]
  for (const key of ['press', 'client', 'raster']) if (key in n && !extra.includes(n.type)) found.push(`${n.type} has ${key}`)
  return [...found, ...(n.children ?? []).flatMap((c: any) => walk(c, extra))]
}

// ---- the sectioned Pane as drawn
// The `work` fixture with its member in stream `api`; its one dispatch stays in that stream, or with `leftover`
// goes to a member that is in no stream, so it draws in DISPATCHES.
const withStreams = (leftover = true): string => {
  const doc = JSON.parse(fixtures.work)
  doc.teams[0].members[0].stream = 'api'
  if (leftover) doc.teams[0].dispatches[0].member = 'nobody'
  return JSON.stringify(doc)
}
const drawnPane = async ($: any, on: any, w: World, columns: number) => {
  stage(on, w)
  beneath(on)
  mock.clock(on, { now: Date.parse(vectors.work.now) })
  await start($, w, 'terminal')
  return (await $.ui.mount({ plugin: 'ah', surface: 'terminal', component: 'Pane', requestId: 'ah-status', props: { ...paneProps(), bodyColumns: columns }, viewport: { columns, rows: 40 } })).drawn()
}
const anyBorder = (n: any): boolean => typeof n === 'object' && n !== null && (n.props?.borderStyle !== undefined || (n.children ?? []).some(anyBorder))

test('the Pane draws each section in a round box with its own color, a bold title in that color, and colored icons', async ($, on) => {
  const w = world({ id: vectors.work.sessionId, files: { [FILE]: { text: withStreams(), mtimeMs: 1 } } })
  const pane = await drawnPane($, on, w, 60)
  expect(walk(pane)).toEqual([])
  expect(boxes(pane).map((b: any) => [b.title, b.color, b.bordered])).toEqual([
    ['TEAM default', 'permission', true], ['STREAM api', 'suggestion', true], ['DISPATCHES', null, true],
  ])
  expect(pane.children.map((b: any) => b.props.key)).toEqual(['team:0', 'stream:0:api', 'dispatches:0'])
  const box = pane.children[1]
  expect(box.props).toMatchObject({ flexDirection: 'column', borderStyle: 'round', borderColor: 'suggestion' })
  expect(box.children[0].props).toMatchObject({ bold: true, color: 'suggestion' })
  expect(box.children[1].children[0]).toMatchObject({ type: 'Text', props: { color: 'success' }, children: ['● '] })
  const dispatchBox = pane.children[2]
  expect(dispatchBox.props).toMatchObject({ borderStyle: 'round', borderDimColor: true })
  expect(dispatchBox.props.borderColor).toBe(undefined)
  expect(dispatchBox.children[0].props).toMatchObject({ bold: true, dimColor: true })
  expect(dispatchBox.children[1].children[0].props).toMatchObject({ color: 'error' })
})

test('a dispatch to a streamed member draws inside its stream box, indented, with no DISPATCHES box', async ($, on) => {
  const w = world({ id: vectors.work.sessionId, files: { [FILE]: { text: withStreams(false), mtimeMs: 1 } } })
  const pane = await drawnPane($, on, w, 60)
  expect(boxes(pane).map((b: any) => b.title)).toEqual(['TEAM default', 'STREAM api'])
  const row = pane.children[1].children[2]
  expect(row.children[0]).toMatchObject({ type: 'Text', children: ['  '] })
  expect(row.children[1]).toMatchObject({ props: { color: 'error' }, children: ['▲ '] })
})

test('below 40 columns the Pane draws no border, and the title keeps its color', async ($, on) => {
  const w = world({ id: vectors.work.sessionId, files: { [FILE]: { text: withStreams(), mtimeMs: 1 } } })
  const pane = await drawnPane($, on, w, 39)
  expect(anyBorder(pane)).toBe(false)
  expect(boxes(pane).map((b: any) => [b.title, b.color, b.bordered])).toEqual([['TEAM default', null, false], ['STREAM api', null, false], ['DISPATCHES', null, false]])
  const title = pane.children[1].children[0]
  expect(title.props).toMatchObject({ bold: true, color: 'suggestion' })
})

test('a null view draws one line with no border and no icon', async ($, on) => {
  const w = world({ id: vectors.work.sessionId, files: {} })
  const pane = await drawnPane($, on, w, 60)
  expect(anyBorder(pane)).toBe(false)
  expect(texts(pane).length).toBe(1)
})

// ---- clicking a member's name focuses its pane (the pinned helper, through the Pane's Button)
// The `work` fixture's one member, marked focusable (or not) and renamed.
const focusDoc = (over: Record<string, unknown> = {}, base: string = fixtures.work): string => {
  const doc = JSON.parse(base)
  Object.assign(doc.teams[0].members[0], { name: 'demo-architect', route: 'peer', kind: 'claude', focusable: true, ...over })
  return JSON.stringify(doc)
}
const OK = { value: { exitCode: 0, stdout: '', stderr: '' } }
// Mounts the Pane over `text`, answering process.run with `run`; returns what was run and toasted.
const focusPane = async ($: any, on: any, text: string, run: (e: any) => any = () => OK, id: string = vectors.work.sessionId) => {
  const w = world({ id, files: { [FILE]: { text, mtimeMs: 1 } } })
  const calls: any[] = []
  stage(on, w)
  beneath(on)
  mock.clock(on, { now: Date.parse(vectors.work.now) })
  on('process.run', (_$: any, e: any) => { calls.push(e); return run(e) })
  await start($, w, 'terminal')
  const ui = await $.ui.mount({ plugin: 'ah', surface: 'terminal', component: 'Pane', requestId: 'ah-status', props: paneProps(), viewport: VIEWPORT })
  return { w, calls, ui }
}
const buttonCount = async (ui: any) => (await ui.findAll({ type: 'Button' })).length

test('F1 a click on a focusable member runs exactly the fixed argv with the fixed timeout, once, and shows nothing', async ($, on) => {
  const { w, calls, ui } = await focusPane($, on, focusDoc())
  expect(await buttonCount(ui)).toBe(1)
  await ui.press({ key: 'ah-name-demo-architect' })
  expect(calls).toEqual([{ argv: ['herdr', 'agent', 'focus', 'demo-architect'], init: { timeoutMs: 5000 } }])
  expect(w.toasts).toEqual([])
})

for (const name of ['-x', 'a b', '../t', 'A', 'a'.repeat(33), '', 'a.b', '-', '1a']) {
  test(`F2 the name ${JSON.stringify(name)} fails the pattern: nothing runs, and the toast carries no name`, async ($, on) => {
    const { w, calls, ui } = await focusPane($, on, focusDoc({ name }))
    expect(await buttonCount(ui)).toBe(1)
    await ui.press({ key: `ah-name-${name}` })
    expect(calls).toEqual([])
    expect(w.toasts).toEqual(['Could not focus that member.'])
  })
}

for (const name of ['a', 'a'.repeat(32), 'a1_b-2']) {
  test(`F2b the name ${JSON.stringify(name)} is at the pattern's edge and runs`, async ($, on) => {
    const { calls, ui } = await focusPane($, on, focusDoc({ name }))
    await ui.press({ key: `ah-name-${name}` })
    expect(calls.map((c) => c.argv[3])).toEqual([name])
  })
}

for (const focusable of ['true', 1, 'yes', false, null, {}, [true], undefined]) {
  test(`F3 focusable ${JSON.stringify(focusable) ?? 'absent'} is not exactly true: no Button`, async ($, on) => {
    const doc = JSON.parse(focusDoc({ focusable }))
    if (focusable === undefined) delete doc.teams[0].members[0].focusable
    const { ui } = await focusPane($, on, JSON.stringify(doc))
    expect(await buttonCount(ui)).toBe(0)
  })
}

const FAILS: [string, (e: any) => any][] = [
  ['a non-zero exit', () => ({ value: { exitCode: 1, stdout: '', stderr: 'secret' } })],
  ['an exit with no code', () => ({ value: { exitCode: 127 } })],
  ['a refusal', () => ({ deny: 'boom' })],
  ['a throw', () => { throw new Error('boom') }],
  ['no result', () => ({ value: undefined })],
]
for (const [label, run] of FAILS) {
  test(`F7 ${label} from the run shows the failure with the name and never throws out of the press`, async ($, on) => {
    const { w, calls, ui } = await focusPane($, on, focusDoc(), run)
    await ui.press({ key: 'ah-name-demo-architect' })
    expect(calls.length).toBe(1)
    expect(w.toasts).toEqual(['Could not focus demo-architect.'])
    expect(w.toasts.join('')).not.toContain('secret')
  })
}

const NO_BUTTON: [string, Record<string, unknown>, number][] = [
  ['a gone member', { live: false }, 0],
  ['a member row of this very session', { session_id: vectors.work.sessionId }, 0],
  ['a member that is not focusable', { focusable: false }, 0],
  ['a member of another session', { session_id: 'some-other-session' }, 1],
]
for (const [label, over, want] of NO_BUTTON) {
  test(`F8 ${label}: ${want} Button`, async ($, on) => {
    expect(await buttonCount((await focusPane($, on, focusDoc(over))).ui)).toBe(want)
  })
}

test('F9 in a member session the Pane holds no Button anywhere', async ($, on) => {
  const { ui, calls } = await focusPane($, on, focusDoc({}, fixtures['member-session']), () => OK, vectors['member-session'].sessionId)
  expect(await buttonCount(ui)).toBe(0)
  expect(calls).toEqual([])
})

test('a focusable member row draws its name as the Button and the rest as toned text; a name the width cut is not a Button', async ($, on) => {
  const { ui } = await focusPane($, on, focusDoc())
  const pane = await ui.drawn()
  const row = pane.children[0].children[1]
  expect(row.children.map((c: any) => c.type)).toEqual(['Text', 'Box', 'Text'])
  expect(row.children[1].props.key).toBe('ah-focus-demo-architect')
  expect(row.children[1].children[0]).toMatchObject({ type: 'Button', props: { plain: true, label: 'demo-architect' }, hover: { underline: true } })
  expect(row.children[2].children).toEqual([' · claude · peer · working'])
  await ui.unmount()
  const narrow = await $.ui.mount({ plugin: 'ah', surface: 'terminal', component: 'Pane', requestId: 'ah-status', props: { ...paneProps(), bodyColumns: 12 }, viewport: { columns: 12, rows: 40 } })
  expect(await narrow.findAll({ type: 'Button' })).toHaveLength(0)
})

// ---- toast_seconds
const TOASTING = { options: { toast_seconds: 30 } }
// (The kit rejects a string for a number option, so string forms are covered by the pure mapping's tests.)
const toasting = async ($: any, on: any, w: World) => {
  stage(on, w)
  beneath(on)
  const clock = mock.clock(on, { now: NOW })
  await start($, w, 'terminal')
  w.files[FILE] = { text: fixtures.warn, mtimeMs: 2 }
  await clock.advance(2000)
  return clock
}
for (const [label, opts, ms] of [['a stored 30', { toast_seconds: 30 }, 30000], ['nothing stored', {}, 10000], ['a negative', { toast_seconds: -3 }, 10000], ['1', { toast_seconds: 1 }, 2000], ['500', { toast_seconds: 500 }, 60000]] as const) {
  test(`R1 ${label}: the status toast passes the same timeoutMs, from one value`, { options: opts }, async ($, on) => {
    const w = world({ files: { [FILE]: { text: fixtures.idle, mtimeMs: 1 } } })
    await toasting($, on, w)
    expect(w.toastCalls).toEqual([{ text: 'architect blocked · Allow edits to config.toml? (y/n)', timeoutMs: ms }])
  })
  test(`R1 ${label}: the band's not-placed notice passes it too`, { options: opts }, async ($, on) => {
    const w = world({ placed: false })
    stage(on, w)
    beneath(on)
    mock.clock(on, { now: NOW })
    await start($, w, 'terminal')
    const ui = await $.ui.mount({ plugin: 'ah', surface: 'terminal', component: 'AbovePrompt', props: bandProps(), viewport: VIEWPORT })
    await ui.press({ key: 'ah-pane' })
    expect(w.toastCalls).toEqual([{ text: 'The hierarchy Pane is open, but this session shows no panes.', timeoutMs: ms }])
  })
}

test('R3 with toast_seconds 0 a doc change that would toast makes no toast call, and the view is the same as with toasts on', { options: { toast_seconds: 0 } }, async ($, on) => {
  const w = world({ files: { [FILE]: { text: fixtures.idle, mtimeMs: 1 } } })
  await toasting($, on, w)
  expect(w.toastCalls).toEqual([])
  expect(writesOf(w, 'seen')).toEqual([[], [vectors.warn.toasts[0].key]])
  const ui = await $.ui.mount({ plugin: 'ah', surface: 'terminal', component: 'AbovePrompt', props: bandProps(), viewport: VIEWPORT })
  expect(texts(await ui.drawn())[0].text).toBe(vectors.warn.band?.text ?? '')
})

test('R3 with toast_seconds 0 the band button\'s not-placed path makes no toast call', { options: { toast_seconds: 0 } }, async ($, on) => {
  const w = world({ placed: false })
  stage(on, w)
  beneath(on)
  mock.clock(on, { now: NOW })
  await start($, w, 'terminal')
  const ui = await $.ui.mount({ plugin: 'ah', surface: 'terminal', component: 'AbovePrompt', props: bandProps(), viewport: VIEWPORT })
  await ui.press({ key: 'ah-pane' })
  expect(w.toastCalls).toEqual([])
  expect(w.opens.length).toBeGreaterThan(0)
})

test('R3 notices seen while off are not replayed when toasts are on again', { options: { toast_seconds: 0 } }, async ($, on) => {
  const w = world({ files: { [FILE]: { text: fixtures.idle, mtimeMs: 1 } } })
  await toasting($, on, w)
  expect(w.toastCalls).toEqual([])
  const seen = writesOf(w, 'seen').at(-1)
  expect(seen).toEqual([vectors.warn.toasts[0].key])
})

test('R3 the pinned helper is unchanged: its two toasts keep the engine default and show whatever toast_seconds is', { options: { toast_seconds: 0 } }, async ($, on) => {
  const w = world({ id: vectors.work.sessionId, files: { [FILE]: { text: JSON.stringify({ ...JSON.parse(fixtures.work), teams: [{ ...JSON.parse(fixtures.work).teams[0], members: [{ ...JSON.parse(fixtures.work).teams[0].members[0], name: 'A', focusable: true, route: 'peer', kind: 'claude' }] }] }), mtimeMs: 1 } } })
  stage(on, w)
  beneath(on)
  mock.clock(on, { now: Date.parse(vectors.work.now) })
  on('process.run', () => ({ value: { exitCode: 1 } }))
  await start($, w, 'terminal')
  const ui = await $.ui.mount({ plugin: 'ah', surface: 'terminal', component: 'Pane', requestId: 'ah-status', props: paneProps(), viewport: VIEWPORT })
  await ui.press({ key: 'ah-name-A' })
  expect(w.toastCalls).toEqual([{ text: 'Could not focus that member.' }])
})
