import { test, expect, mock } from 'claude-code/testing'
import { fixtures } from './fixtures.ts'
import { vectors } from './vectors.ts'
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
  files: Record<string, { text: string; mtimeMs: number }>
  shown: (string | undefined)[]
  reads: number
  registered: unknown[]
  opens: unknown[]
  placed: boolean
  writes: { key: string; value: unknown }[]
}
const world = (over: Partial<World> = {}): World => ({
  cwd: REPO + '/sub', id: 'sess-orch', git: [REPO], files: { [FILE]: { text: fixtures.work, mtimeMs: 1 } }, shown: [], reads: 0, registered: [], opens: [], placed: true, writes: [], ...over,
})

// Answers every $ call the module makes, from `w`; nothing real is read.
const stage = (on: any, w: World) => {
  on('session.start', (_$: any, e: any) => ({ cwd: e.cwd }))
  on('session.cwd', () => ({ value: w.cwd }))
  on('session.id', () => ({ value: w.id }))
  on('fs.exists', (_$: any, e: any) => ({ value: w.git.some((d) => e.path === d + '/.git') }))
  on('fs.stat', (_$: any, e: any) => {
    const f = w.files[e.path]
    return f ? { value: { kind: 'file', size: utf8Bytes(f.text), mtimeMs: f.mtimeMs, isLink: false } } : { deny: 'no such file' }
  })
  on('fs.read', (_$: any, e: any) => {
    const f = w.files[e.path]
    w.reads++
    return f ? { value: f.text } : { deny: 'no such file' }
  })
  on('ui.status', (_$: any, e: any) => { w.shown.push(e.text); return { value: undefined } })
  on('command.register', (_$: any, e: any) => { w.registered.push(e); return { value: undefined } })
  on('ui.open', (_$: any, e: any) => { w.opens.push(e); return { value: w.placed ? { isPlaced: true } : { isPlaced: false, reason: 'no surface places panes' } } })
  on('state.set', async (_$: any, e: any, next: any) => { w.writes.push({ key: e.key, value: e.value }); return next(e) })
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
  test(`${surface}: session.start returns what next returned, and sets the entry from the doc`, async ($, on) => {
    const w = world()
    stage(on, w)
    mock.clock(on, { now: NOW })
    expect(await start($, w, surface)).toEqual({ cwd: w.cwd })
    expect(w.shown).toEqual(['1 live · 1 out'])
  })

  test(`${surface}: the entry is set, then cleared when the file goes`, async ($, on) => {
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

  test(`${surface}: the clock moves the entry along the timeline`, async ($, on) => {
    const w = world()
    stage(on, w)
    const clock = mock.clock(on, { now: NOW })
    await start($, w, surface)
    await clock.advance(240000)
    expect(w.shown).toEqual(['1 live · 1 out', '1 live · 1 out · 1 overdue'])
  })

  test(`${surface}: the file is read again only when its mtime changes`, async ($, on) => {
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

  test(`${surface}: a file over 262,144 bytes is not read`, async ($, on) => {
    const w = world({ files: { [FILE]: { text: fixtures.work + ' '.repeat(262144), mtimeMs: 1 } } })
    stage(on, w)
    mock.clock(on, { now: NOW })
    await start($, w, surface)
    expect(w.reads).toBe(0)
    expect(w.shown).toEqual([undefined])
  })

  test(`${surface}: a cwd change finds the other checkout's file`, async ($, on) => {
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

  test(`${surface}: a session whose id becomes a member's hides the entry at the next tick`, async ($, on) => {
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
      expect(walk(band)).toEqual([])
      expect(texts(band)).toEqual(v.band === null ? [CORE_LINE] : [{ text: v.band.text, props: TONE[v.band.tone] }, CORE_LINE])
      const pane = await (await $.ui.mount({ plugin: 'ah', surface, component: 'Pane', requestId: 'ah-status', props: paneProps(), viewport: VIEWPORT })).drawn()
      expect(walk(pane)).toEqual([])
      expect(texts(pane)).toEqual(v.pane.map((r) => ({ text: r.text, props: TONE[r.tone] })))
    })
  }

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

}

// What the chain beneath the module answers for the band, and for any Pane but the module's.
const CORE = { type: 'Text', children: ['core'] }
const CORE_LINE = { text: 'core', props: {} }
function beneath(on: any) {
  on('ui.render', { component: 'AbovePrompt' }, () => CORE)
  on('ui.render', { component: 'Pane' }, () => CORE)
}
const VIEWPORT = { columns: 125, rows: 40 }
const bandProps = (over: Record<string, unknown> = {}): any =>
  ({ hasSurvey: false, isWorking: false, maxRows: 10, bodyColumns: 120, scroll: { offset: 0, bodyRows: 10 }, view: {}, ...over })
const paneProps = (): any => ({ title: 'Hierarchy', isFocused: false, bodyColumns: 120, placement: 'inline', scroll: { offset: 0, bodyRows: 20 }, view: {} })
// The Text props each tone draws with, as the spec's table pins them.
const TONE: Record<string, Record<string, unknown>> = { bad: { color: 'warning', bold: true }, warn: { color: 'warning' }, work: {}, idle: { dimColor: true } }

// Every Text in the tree, in document order, with its props.
function texts(n: any): { text: string; props: Record<string, unknown> }[] {
  if (typeof n !== 'object' || n === null) return []
  if (n.type === 'Text') return [{ text: (n.children ?? []).join(''), props: n.props ?? {} }]
  return (n.children ?? []).flatMap(texts)
}
// What a drawn tree holds that a status view may not: an element other than Box, Text or core's engine, or a
// node carrying a press, client or raster key.
function walk(n: any): string[] {
  if (typeof n !== 'object' || n === null) return []
  const found = ['Box', 'Text', 'engine'].includes(n.type) ? [] : [`element ${n.type}`]
  for (const key of ['press', 'client', 'raster']) if (key in n) found.push(`${n.type} has ${key}`)
  return [...found, ...(n.children ?? []).flatMap(walk)]
}
