import { test, expect } from 'claude-code/testing'
import { fixtures } from './fixtures.ts'
import { vectors } from './vectors.ts'
import { parseDoc, SIZE_CAP, statusText, utf8Bytes } from '../view.ts'

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
