// The status document read the way every consumer reads it (docs/status-file.md, "Reading it"), and what
// the band, the Pane and the toasts show from it. No engine calls, so the mod's tests drive it directly.
import type { PaneRow, Tone, View } from './types/index.d.ts'

/** The largest status.json read: a bigger file counts as no document. */
export const SIZE_CAP = 262144

export type Doc = {
  expiresMs: number
  memberSessions: readonly string[]
  timeline: readonly { atMs: number; entry: Record<string, unknown> }[]
  teams: readonly unknown[]
}

const INSTANT = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:Z|[+-]\d{2}:?\d{2})/
const CONTROL = /[\x00-\x1f\x7f-\x9f]/g

/** Milliseconds for an ISO-8601 instant (a date, a time and a zone), else NaN. */
function instantMs(v: unknown): number {
  if (typeof v !== 'string') return NaN
  const m = INSTANT.exec(v)
  return m !== null && m[0].length === v.length ? Date.parse(v) : NaN
}

/** UTF-8 length of a string, which is what the size cap counts. */
export function utf8Bytes(s: string): number {
  let n = 0
  for (let i = 0; i < s.length; i++) {
    const c = s.charCodeAt(i)
    if (c < 0x80) n += 1
    else if (c < 0x800) n += 2
    else if (c >= 0xd800 && c <= 0xdbff && i + 1 < s.length) { n += 4; i++ }
    else n += 3
  }
  return n
}

/**
 * The document in a status.json's text, or null when it counts as absent: no text, over SIZE_CAP bytes,
 * not JSON, `schema` not 1, or a field the status entry reads that is missing or of the wrong type
 * (`expires_at`, `member_sessions`, `timeline` with every `at`). `teams` is read field by field, later.
 */
export function parseDoc(text: string | null | undefined): Doc | null {
  if (typeof text !== 'string' || utf8Bytes(text) > SIZE_CAP) return null
  let o: unknown
  try { o = JSON.parse(text) } catch { return null }
  if (typeof o !== 'object' || o === null || Array.isArray(o)) return null
  const d = o as Record<string, unknown>
  if (d.schema !== 1) return null
  const expiresMs = instantMs(d.expires_at)
  if (!Number.isFinite(expiresMs)) return null
  const members = d.member_sessions
  if (!Array.isArray(members) || !members.every((s) => typeof s === 'string')) return null
  const tl = d.timeline
  if (!Array.isArray(tl) || tl.length === 0) return null
  const timeline = []
  for (const entry of tl) {
    if (typeof entry !== 'object' || entry === null || Array.isArray(entry)) return null
    const atMs = instantMs((entry as Record<string, unknown>).at)
    if (!Number.isFinite(atMs)) return null
    timeline.push({ atMs, entry: entry as Record<string, unknown> })
  }
  return { expiresMs, memberSessions: members as string[], timeline, teams: Array.isArray(d.teams) ? d.teams : [] }
}

/**
 * The timeline entry current at `nowMs` (the last with `at` ≤ now, else the first), or null when nothing
 * shows: no document, expired, the entry malformed or not visible, or `sessionId` a member session.
 */
function current(doc: Doc | null, nowMs: number, sessionId: string): Record<string, unknown> | null {
  if (doc === null || nowMs >= doc.expiresMs) return null
  let picked = doc.timeline[0]
  for (const t of doc.timeline) if (t.atMs <= nowMs) picked = t
  const { visible, tone, text, short } = picked.entry
  if (typeof visible !== 'boolean' || typeof tone !== 'string' || typeof text !== 'string' || typeof short !== 'string') return null
  if (!visible || doc.memberSessions.includes(sessionId)) return null
  return picked.entry
}

/**
 * The status entry's text at `nowMs` for the session `sessionId`, or undefined when nothing should show
 * or the `status_entry` option is off. Control characters are stripped.
 */
export function statusText(doc: Doc | null, nowMs: number, sessionId: string, statusEntry: boolean): string | undefined {
  const entry = statusEntry ? current(doc, nowMs, sessionId) : null
  return entry === null ? undefined : (entry.text as string).replace(CONTROL, '')
}

// The file is untrusted past the fields parseDoc checks: every other field is read here, defaulting
// when missing or of the wrong type, and every string has its control characters stripped.
const str = (v: unknown): string => (typeof v === 'string' ? v.replace(CONTROL, '') : '')
const record = (v: unknown): Record<string, unknown> | null => (typeof v === 'object' && v !== null && !Array.isArray(v) ? (v as Record<string, unknown>) : null)
const records = (v: unknown): Record<string, unknown>[] => (Array.isArray(v) ? v.map(record).filter((x): x is Record<string, unknown> => x !== null) : [])
const count = (v: unknown): number => (typeof v === 'number' && Number.isFinite(v) && v > 0 ? Math.floor(v) : 0)
const seconds = (ms: number): number => (Number.isFinite(ms) && ms > 0 ? Math.floor(ms / 1000) : 0)

/** `{m:ss}`: minutes unbounded, seconds two digits; nothing before 0:00. */
const clock = (ms: number): string => { const s = seconds(ms); return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}` }
/** A duration: `{s}s` under a minute, else `{m}m {s}s`. */
const duration = (ms: number): string => { const s = seconds(ms); return s < 60 ? `${s}s` : `${Math.floor(s / 60)}m ${s % 60}s` }
/** An age: `{s}s`, `{m}m` or `{h}h`. */
const age = (ms: number): string => { const s = seconds(ms); return s < 60 ? `${s}s` : s < 3600 ? `${Math.floor(s / 60)}m` : `${Math.floor(s / 3600)}h` }

type Dispatch = {
  id: string; slug: string; label: string; member: string; toName: string
  etaMs: number; sentMs: number; reportedMs: number; checkins: number; state: string; reason: string
}
type Member = {
  name: string; label: string; kind: string; route: string; live: unknown
  activity: string; activityMs: number; activityAt: string; blockedBy: string; note: string
}
type Team = { name: string; pipeline: Record<string, unknown> | null; members: Member[]; dispatches: Dispatch[] }

function readTeams(doc: Doc, nowMs: number): Team[] {
  return records(doc.teams).map((t) => ({
    name: str(t.team) || 'default',
    pipeline: record(t.pipeline),
    members: records(t.members).map((m) => ({
      name: str(m.name), label: str(m.label), kind: str(m.kind), route: str(m.route), live: m.live,
      activity: str(m.activity), activityMs: instantMs(m.activity_at), activityAt: str(m.activity_at),
      blockedBy: str(m.blocked_by), note: str(m.blocked_note),
    })),
    dispatches: records(t.dispatches).map((d) => {
      let state = '', reason = ''
      for (const s of records(d.states)) {
        const atMs = instantMs(s.at)
        if (state === '' || atMs <= nowMs) { state = str(s.state); reason = str(s.reason) }
      }
      return {
        id: str(d.id), slug: str(d.slug), label: str(d.label), member: str(d.member), toName: str(d.to_name),
        etaMs: typeof d.eta_ms === 'number' && Number.isFinite(d.eta_ms) && d.eta_ms > 0 ? d.eta_ms : NaN,
        sentMs: instantMs(d.sent_at), reportedMs: instantMs(d.reported_at), checkins: count(d.checkins), state, reason,
      }
    }),
  }))
}

const etaText = (d: Dispatch): string | null => (Number.isNaN(d.etaMs) ? null : `${d.etaMs / 60000}m`)
const oldestFirst = (a: number, b: number): number => (Number.isNaN(a) ? Infinity : a) - (Number.isNaN(b) ? Infinity : b)

/** The check-in phrase of a stalled dispatch with no report. */
function checkinPhrase(d: Dispatch, nowMs: number): string {
  if (d.checkins === 1) return '1 check-in unanswered'
  if (d.checkins > 1) return `${d.checkins} check-ins unanswered`
  return `no report after ${Math.floor(seconds(nowMs - d.sentMs) / 60)}m`
}
const goneName = (d: Dispatch): string => d.member || d.toName || d.label
const stalledWhy = (d: Dispatch, nowMs: number): string => (d.reason === 'member-gone' ? `${goneName(d)} is gone` : checkinPhrase(d, nowMs))

function overdueText(d: Dispatch, nowMs: number): string {
  const eta = etaText(d)
  const head = eta === null ? `${d.label} is past its eta` : `${d.label} is ${duration(nowMs - d.sentMs - d.etaMs)} past its ${eta} eta`
  return d.checkins > 0 ? `${head} · check-in ${d.checkins} sent` : head
}
const workingText = (d: Dispatch, nowMs: number): string => {
  const eta = etaText(d)
  return `${d.label} ${clock(nowMs - d.sentMs)}${eta === null ? '' : ` of ${eta}`}`
}
const blockedText = (m: Member): string =>
  `${m.label} is waiting on a prompt · ${m.route === 'pane' ? 'answer it through the Orchestrator' : 'answer it in its pane'}`

const memberTone = (m: Member): Tone => (m.live === false ? 'idle' : m.activity === 'working' ? 'work' : m.activity === 'blocked' ? 'warn' : 'idle')
const dispatchTone = (state: string): Tone =>
  state === 'working' ? 'work' : state === 'blocked' ? 'warn' : state === 'overdue' || state === 'stalled' ? 'bad' : 'idle'

/**
 * What the band, the Pane and the toasts show at `nowMs` for `sessionId`, or null whenever the status
 * entry would show nothing for the document itself (absent, expired, invisible, a member session).
 */
export function viewModel(doc: Doc | null, nowMs: number, sessionId: string): View | null {
  const entry = current(doc, nowMs, sessionId)
  if (entry === null || doc === null) return null
  const teams = readTeams(doc, nowMs)
  const dispatches = teams.flatMap((t) => t.dispatches)
  const members = teams.flatMap((t) => t.members)

  let band: View['band'] = null
  if (count(entry.out) > 0 || count(entry.blocked) > 0) {
    const bySent = (state: string) => dispatches.filter((d) => d.state === state).sort((a, b) => oldestFirst(a.sentMs, b.sentMs))
    const severe = [
      ...bySent('stalled').map((d) => ({ tone: 'bad' as Tone, text: `${d.label} stalled on ${d.slug} · ${stalledWhy(d, nowMs)}` })),
      ...bySent('overdue').map((d) => ({ tone: 'bad' as Tone, text: overdueText(d, nowMs) })),
      ...members.filter((m) => m.activity === 'blocked').sort((a, b) => oldestFirst(a.activityMs, b.activityMs))
        .map((m) => ({ tone: 'warn' as Tone, text: blockedText(m) })),
    ]
    const working = bySent('working').map((d) => workingText(d, nowMs))
    if (severe.length) band = { tone: severe[0].tone, head: severe[0].text + (severe.length > 1 ? ` · +${severe.length - 1} more` : ''), tail: [] }
    else if (working.length) band = { tone: 'work', head: `${count(entry.out)} out · ${working[0]}`, tail: working.slice(1) }
  }

  const multi = teams.length > 1
  const heading = (name: string, t: Team): PaneRow => ({ row: 'text', tone: 'idle', text: multi ? `${name} ${t.name}` : name })
  const pane: PaneRow[] = []
  for (const t of teams) {
    pane.push(heading('Hierarchy', t))
    const open = t.pipeline === null ? [] : records(t.pipeline.items).filter((item) => item.open === true)
    const cap = t.pipeline === null ? 0 : count(t.pipeline.round_cap)
    if (!open.length) pane.push({ row: 'text', tone: 'idle', text: 'No pipeline run.' })
    for (const item of open) pane.push({ row: 'text', tone: 'work', text: `round ${count(item.rounds)}/${cap} · ${str(item.to)}` })
    const waiting = t.pipeline === null ? 0 : count(t.pipeline.waiting_on_user)
    if (waiting > 0) pane.push({ row: 'text', tone: 'warn', text: `${waiting} ${waiting === 1 ? 'decision' : 'decisions'} waiting for you` })
  }
  for (const t of teams) {
    pane.push(heading('Team', t))
    for (const m of t.members) {
      const state = m.live === false ? 'gone' : `${m.activity}${m.route === 'pane' && !Number.isNaN(m.activityMs) ? ` ${age(nowMs - m.activityMs)}` : ''}`
      pane.push({ row: 'member', tone: memberTone(m), name: m.name, kind: m.kind, route: m.route, state })
    }
  }
  for (const t of teams) {
    pane.push(heading('Dispatches', t))
    const shown = t.dispatches.filter((d) => d.state !== '' && d.state !== 'expired').sort((a, b) => oldestFirst(b.sentMs, a.sentMs))
    for (const d of shown) {
      const eta = etaText(d)
      const pct = eta === null ? null : Math.min(100, Math.max(0, Math.floor(((nowMs - d.sentMs) / d.etaMs) * 100))) || 0
      pane.push({ row: 'dispatch', tone: dispatchTone(d.state), slug: d.slug, label: d.label, eta, pct, elapsed: clock(nowMs - d.sentMs), state: d.state })
    }
    if (!shown.length) pane.push({ row: 'text', tone: 'idle', text: 'None outstanding.' })
  }

  const toasts: View['toasts'] = []
  for (const d of dispatches) {
    if (d.state !== 'reported') continue
    const took = Number.isNaN(d.reportedMs) || Number.isNaN(d.sentMs) ? '' : ` · ${duration(d.reportedMs - d.sentMs)}`
    toasts.push({ key: `reported:${d.id}`, text: `${d.label} reported · ${d.slug}${took}` })
  }
  for (const m of members) {
    if (m.activity !== 'blocked') continue
    const why = m.note || (m.blockedBy === 'permission' ? 'waiting for permission' : 'waiting on a prompt')
    toasts.push({ key: `blocked:${m.name}:${m.activityAt}`, text: `${m.label} blocked · ${why}` })
  }
  for (const d of dispatches) {
    if (d.state === 'stalled') toasts.push({ key: `stalled:${d.id}`, text: `${d.label} stalled · ${d.slug} · ${stalledWhy(d, nowMs)}` })
  }
  return { band, pane, toasts }
}

/**
 * The seen toast keys whose subject is still in the doc: the dispatch of a `reported:` or `stalled:` key, the
 * member of a `blocked:` key. Anything else is dropped.
 */
export function keepSeen(seen: readonly unknown[], doc: Doc, nowMs: number): string[] {
  const teams = readTeams(doc, nowMs)
  const dispatchKeys = new Set(teams.flatMap((t) => t.dispatches.flatMap((d) => [`reported:${d.id}`, `stalled:${d.id}`])))
  const memberPrefixes = teams.flatMap((t) => t.members.map((m) => `blocked:${m.name}:`))
  return seen.filter((k): k is string => typeof k === 'string' && (dispatchKeys.has(k) || memberPrefixes.some((p) => k.startsWith(p))))
}

/** Display width, one cell per code point: the band, the Pane and the cut all count this way. */
const width = (s: string): number => [...s].length

/** `s` cut to `n` cells, ending in `…` when anything was cut. */
export function cut(s: string, n: number): string {
  const c = [...s]
  return c.length <= n ? s : n <= 0 ? '' : c.slice(0, n - 1).join('') + '…'
}

/** The band's one line at `columns` and its tone, or null when there is no band. */
export function bandLine(view: View | null, columns: number): { text: string; tone: Tone } | null {
  if (view === null || view.band === null) return null
  let text = view.band.head
  for (const item of view.band.tail) {
    const longer = `${text} · ${item}`
    if (width(longer) > columns) break
    text = longer
  }
  return { text: cut(text, columns), tone: view.band.tone }
}

/** The Pane's rows at `columns`, each with its tone; one dim line when there is no view. */
export function paneRows(view: View | null, columns: number): { text: string; tone: Tone }[] {
  if (view === null) return [{ text: cut('No hierarchy status here.', columns), tone: 'idle' }]
  return view.pane.map((r) => ({ text: drawRow(r, columns), tone: r.tone }))
}

const bar = (pct: number): string => '█'.repeat(Math.floor(pct / 10)) + '░'.repeat(10 - Math.floor(pct / 10))

/** One Pane row at `columns`, after the width fallback and then the cuts. */
function drawRow(r: PaneRow, columns: number): string {
  if (r.row === 'text') return cut(r.text, columns)
  if (r.row === 'member') {
    const state = r.state
    return fitCut(r.name, columns, (name) => (columns < 40 ? `${name} ${state}` : `${name} · ${r.kind} · ${r.route} · ${state}`))
  }
  return fitCut(r.slug, columns, (slug) => {
    if (columns < 28) return `${slug} ${r.state}`
    const parts = [`${slug} → ${r.label}`]
    if (columns >= 40) parts.push(`eta ${r.eta ?? '—'}`)
    if (r.pct !== null) parts.push(columns >= 60 ? `${bar(r.pct)} ${r.pct}%` : `${r.pct}%`)
    parts.push(r.elapsed, r.state)
    return parts.join(' | ')
  })
}

/** Cuts `name` (down to 8 cells) until `row(name)` fits `columns`, then cuts the whole row. */
function fitCut(name: string, columns: number, row: (name: string) => string): string {
  const full = row(name)
  const over = width(full) - columns
  if (over <= 0) return full
  return cut(width(name) > 8 ? row(cut(name, Math.max(8, width(name) - over))) : full, columns)
}
