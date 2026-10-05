import { test, expect, mock } from 'claude-code/testing'
import { fixtures } from './fixtures.ts'
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
}
const world = (over: Partial<World> = {}): World => ({
  cwd: REPO + '/sub', id: 'sess-orch', git: [REPO], files: { [FILE]: { text: fixtures.work, mtimeMs: 1 } }, shown: [], reads: 0, ...over,
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
}
const start = ($: any, w: World, surface: string) => $.session.start({ cwd: w.cwd, surface, isInteractive: true })

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
    expect(w.shown).toEqual([])
    expect(w.reads).toBe(0)
  })

  test(`${surface}: no git checkout above the cwd sets nothing and reads nothing`, async ($, on) => {
    const w = world({ git: [] })
    stage(on, w)
    mock.clock(on, { now: NOW })
    await start($, w, surface)
    expect(w.shown).toEqual([])
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
    expect(w.shown).toEqual([])
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
    expect(w.shown).toEqual([])
  })

  test(`${surface}: status_entry false keeps the entry cleared`, { options: { status_entry: false } }, async ($, on) => {
    const w = world()
    stage(on, w)
    mock.clock(on, { now: NOW })
    await start($, w, surface)
    expect(w.shown).toEqual([])
  })

  test(`${surface}: status_entry true shows the entry`, { options: { status_entry: true } }, async ($, on) => {
    const w = world()
    stage(on, w)
    mock.clock(on, { now: NOW })
    await start($, w, surface)
    expect(w.shown).toEqual(['1 live · 1 out'])
  })
}
