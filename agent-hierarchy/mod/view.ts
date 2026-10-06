// The status document read the way every consumer reads it (docs/status-file.md, "Reading it"), and what
// the band, the Pane and the toasts show from it. No engine calls, so the mod's tests drive it directly.
import type { PaneRow, TeamModel, Tone, View } from './types/index.d.ts'

/** The largest status.json read: a bigger file counts as no document. */
export const SIZE_CAP = 262144

export type Doc = {
  /** `enabled` when the file holds a boolean there, else null. Only the cause shown for an empty Pane reads it. */
  enabled: boolean | null
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
  return { enabled: typeof d.enabled === 'boolean' ? d.enabled : null, expiresMs, memberSessions: members as string[], timeline, teams: Array.isArray(d.teams) ? d.teams : [] }
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
 * Why there is no view for a document: `unreadable` when it did not parse, else `expired`, `member session`,
 * `hierarchy off` (it says `enabled` is false) or `not visible`. Named in the empty Pane's one line.
 */
export function nullCause(doc: Doc | null, nowMs: number, sessionId: string): string {
  if (doc === null) return 'unreadable'
  if (nowMs >= doc.expiresMs) return 'expired'
  if (doc.memberSessions.includes(sessionId)) return 'member session'
  if (doc.enabled === false) return 'hierarchy off'
  return 'not visible'
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
  lastTool: string; lastToolMs: number; stream: string; sessionId: string; focusable: boolean
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
      lastTool: str(m.last_tool), lastToolMs: instantMs(m.last_tool_at), stream: str(m.stream), sessionId: str(m.session_id), focusable: m.focusable === true,
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

/**
 * The one table of everything the sectioned Pane adds: each row state's icon (one code point, so its shape tells
 * the state with no color) and the theme key that colors it (null draws it dim), the box colors by section, and
 * the palette streams take in turn. The drawing applies these and names no icon or color of its own. Box colors
 * are never the status keys (`success`, `warning`, `error`), which only icons use.
 */
export const STYLE = {
  icon: {
    working: { glyph: '●', color: 'success' },
    idle: { glyph: '○', color: null },
    blocked: { glyph: '■', color: 'warning' },
    gone: { glyph: '×', color: null },
    unknown: { glyph: '?', color: null },
    dispatchWork: { glyph: '↳', color: 'success' },
    dispatchIdle: { glyph: '↳', color: null },
    dispatchWarn: { glyph: '↳', color: 'warning' },
    dispatchBad: { glyph: '▲', color: 'error' },
  },
  box: { hierarchy: 'claude', team: 'permission', dispatches: null },
  streams: ['suggestion', 'remember', 'ide', 'planMode'],
} as const
type IconKey = keyof typeof STYLE.icon
const iconOf = (key: IconKey) => ({ icon: STYLE.icon[key].glyph as string, iconColor: STYLE.icon[key].color as string | null })

const memberIconKey = (m: Member): IconKey => (m.live === false ? 'gone' : m.activity === 'working' ? 'working' : m.activity === 'blocked' ? 'blocked' : m.activity === 'idle' ? 'idle' : 'unknown')
const DISPATCH_ICON: Record<Tone, IconKey> = { work: 'dispatchWork', idle: 'dispatchIdle', warn: 'dispatchWarn', bad: 'dispatchBad' }

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
  const pipelineRows = (t: Team, none = 'No pipeline run.'): PaneRow[] => {
    const rows: PaneRow[] = []
    const open = t.pipeline === null ? [] : records(t.pipeline.items).filter((item) => item.open === true)
    const cap = t.pipeline === null ? 0 : count(t.pipeline.round_cap)
    if (!open.length) rows.push({ row: 'text', tone: 'idle', text: none })
    for (const item of open) rows.push({ row: 'text', tone: 'work', text: `round ${count(item.rounds)}/${cap} · ${str(item.to)}` })
    const waiting = t.pipeline === null ? 0 : count(t.pipeline.waiting_on_user)
    if (waiting > 0) rows.push({ row: 'text', tone: 'warn', text: `${waiting} ${waiting === 1 ? 'decision' : 'decisions'} waiting for you` })
    return rows
  }
  const memberRow = (m: Member): PaneRow => {
    const progress = m.route !== 'pane' && m.activity === 'working' && m.lastTool !== '' && !Number.isNaN(m.activityMs) && !Number.isNaN(m.lastToolMs) && m.lastToolMs >= m.activityMs
    const base = m.live === false ? 'gone' : `${m.activity}${m.route === 'pane' && !Number.isNaN(m.activityMs) ? ` ${age(nowMs - m.activityMs)}` : ''}`
    const state = m.live !== false && progress ? `working ${age(nowMs - m.activityMs)} · last ${m.lastTool} ${age(nowMs - m.lastToolMs)}` : base
    // A click focuses the member's terminal pane: only a member the status file marks focusable (exactly true), still live, and not this session.
    const focus = m.focusable && m.live !== false && (m.sessionId === '' || m.sessionId !== sessionId)
    return { row: 'member', tone: memberTone(m), name: m.name, kind: m.kind, route: m.route, state, base, focus, ...iconOf(memberIconKey(m)) }
  }
  const shownOf = (t: Team): Dispatch[] => t.dispatches.filter((d) => d.state !== '' && d.state !== 'expired').sort((a, b) => oldestFirst(b.sentMs, a.sentMs))
  const dispatchRow = (d: Dispatch): PaneRow => {
    const eta = etaText(d)
    const pct = eta === null ? null : Math.min(100, Math.max(0, Math.floor(((nowMs - d.sentMs) / d.etaMs) * 100))) || 0
    const tone = dispatchTone(d.state)
    return { row: 'dispatch', tone, slug: d.slug, label: d.label, eta, pct, elapsed: clock(nowMs - d.sentMs), state: d.state, ...iconOf(DISPATCH_ICON[tone]) }
  }
  const pane: PaneRow[] = []
  for (const t of teams) {
    pane.push(heading('Hierarchy', t))
    pane.push(...pipelineRows(t))
  }
  for (const t of teams) {
    pane.push(heading('Team', t))
    for (const m of t.members) pane.push(memberRow(m))
  }
  for (const t of teams) {
    pane.push(heading('Dispatches', t))
    const shown = shownOf(t)
    for (const d of shown) pane.push(dispatchRow(d))
    if (!shown.length) pane.push({ row: 'text', tone: 'idle', text: 'None outstanding.' })
  }
  const teamModels: TeamModel[] = teams.map((t) => ({
    name: t.name,
    pipeline: t.pipeline === null ? null : pipelineRows(t, 'Pipeline idle.'),
    members: t.members.map((m) => ({ stream: m.stream, row: memberRow(m) })),
    dispatches: shownOf(t).map((d) => ({ member: d.member, row: dispatchRow(d) })),
  }))

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
  return { band, pane, teams: teamModels, toasts }
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

/** The band's Pane button: its label, its drawn width (`[ Pane ]`), the gap before it, and the narrowest band that draws it. */
export const PANE_BUTTON = { label: 'Pane', width: 8, gap: 1, minColumns: 40 }

/** The band's one line at `columns` and its tone, or null when there is no band. */
export function bandLine(view: View | null, columns: number): { text: string; tone: Tone } | null {
  // A value held in state can come from another version of this module, so its shape is checked, not assumed.
  const band = typeof view === 'object' && view !== null ? (view as { band?: unknown }).band : null
  if (typeof band !== 'object' || band === null) return null
  const { head, tail, tone } = band as { head?: unknown; tail?: unknown; tone?: unknown }
  if (typeof head !== 'string' || typeof tone !== 'string' || !Array.isArray(tail)) return null
  let text = head
  for (const item of tail) {
    const longer = `${text} · ${String(item)}`
    if (width(longer) > columns) break
    text = longer
  }
  return { text: cut(text, columns), tone: tone as Tone }
}

/**
 * The Pane's rows at `columns`, each with its tone. Never empty: no view, or a held value that is not a view,
 * is one dim line (naming `why` when given), and a view that lists no team says so in one dim line.
 */
export function paneRows(view: View | null, columns: number, why: string | null = null): { text: string; tone: Tone }[] {
  const none = [{ text: cut(`No hierarchy status here${typeof why === 'string' && why ? ` (${why})` : ''}.`, columns), tone: 'idle' as Tone }]
  const pane = typeof view === 'object' && view !== null ? (view as { pane?: unknown }).pane : null
  if (!Array.isArray(pane)) return none
  if (pane.length === 0) return [{ text: cut('No live team in the status file.', columns), tone: 'idle' }]
  try {
    return (pane as PaneRow[]).map((r) => ({ text: drawRow(r, columns), tone: r.tone }))
  } catch {
    return none
  }
}

const bar = (pct: number): string => '█'.repeat(Math.floor(pct / 10)) + '░'.repeat(10 - Math.floor(pct / 10))

/** One Pane row at `columns`, after the width fallback and then the cuts. */
function drawRow(r: PaneRow, columns: number): string {
  if (r.row === 'text') return cut(r.text, columns)
  if (r.row === 'member') {
    const state = r.state
    return fitCut(r.name, columns, (name) => (columns < 40 ? `${name} ${state}` : `${name} · ${r.kind} · ${r.route} · ${state}`))
  }
  return fitCut(r.slug, columns, (slug) => (columns < 28 ? `${slug} ${r.state}` : dispatchLine(r, slug, columns)))
}

/** A dispatch row's full form at `columns` (28 or more), which picks how much of it shows. */
function dispatchLine(r: Extract<PaneRow, { row: 'dispatch' }>, slug: string, columns: number): string {
  const parts = [`${slug} → ${r.label}`]
  if (columns >= 40) parts.push(`eta ${r.eta ?? '—'}`)
  if (r.pct !== null) parts.push(columns >= 60 ? `${bar(r.pct)} ${r.pct}%` : `${r.pct}%`)
  parts.push(r.elapsed, r.state)
  return parts.join(' | ')
}

/** Cuts `name` (down to 8 cells) until `row(name)` fits `columns`, then cuts the whole row. */
function fitCut(name: string, columns: number, row: (name: string) => string): string {
  const full = row(name)
  const over = width(full) - columns
  if (over <= 0) return full
  return cut(width(name) > 8 ? row(cut(name, Math.max(8, width(name) - over))) : full, columns)
}

/** The narrowest Pane that draws its sections in borders; below it the borders go and the titles stay. */
export const BORDER_MIN = 40

/** One line of a section: an optional icon cell (with the theme key coloring it, null for dim), its tone, its text already cut to fit, and its indent. */
export type SectionRow = { icon: string | null; iconColor: string | null; tone: Tone; text: string; indent: number; focus: string | null }
/** One Pane section: a box (or, below BORDER_MIN, a title line) holding rows. `color` is the box and title theme key, null for dim. */
export type Section = { section: 'hierarchy' | 'team' | 'stream' | 'dispatches' | 'none'; key: string; title: string; color: string | null; bordered: boolean; rows: SectionRow[] }

/** A member or dispatch row's text at `columns`, cut to `room` cells. */
function sectionText(r: PaneRow, columns: number, room: number): string {
  if (r.row === 'text') return cut(r.text, room)
  if (r.row === 'member') {
    const base = typeof r.base === 'string' ? r.base : r.state
    return fitCut(r.name, room, (name) => (columns < BORDER_MIN ? `${name} ${base}` : `${name} · ${r.kind} · ${r.route} · ${r.state}`))
  }
  return fitCut(r.slug, room, (slug) => (columns < BORDER_MIN ? `${slug} ${r.state}` : dispatchLine(r, slug, columns)))
}

/**
 * The Pane as sections at `columns`: per team, HIERARCHY (when it has a pipeline), TEAM (when it has a member; the
 * members with no stream), one STREAM per stream by name (its members, then the dispatches sent to them, indented),
 * and DISPATCHES (the rest). A section with no rows is left out, except a TEAM whose members are all in streams,
 * which stays as a title. Never empty and never throws: no view, a held value that is not a view, or one from a
 * version without teams gives one borderless section of paneRows' lines.
 */
export function paneSections(view: View | null, columns: number, why: string | null = null): Section[] {
  const flat = (): Section[] => [{
    section: 'none', key: 'none', title: '', color: null, bordered: false,
    rows: paneRows(view, columns, why).map((r) => ({ icon: null, iconColor: null, tone: r.tone, text: r.text, indent: 0, focus: null })),
  }]
  const teams = typeof view === 'object' && view !== null ? (view as { teams?: unknown }).teams : null
  if (!Array.isArray(teams) || teams.length === 0) return flat()
  const bordered = columns >= BORDER_MIN
  const inner = Math.max(1, columns - (bordered ? 2 : 0))
  try {
    const row = (r: PaneRow, indent: number): SectionRow => {
      const iconed = r.row !== 'text'
      let text = sectionText(r, columns, Math.max(0, inner - indent - (iconed ? 2 : 0)))
      // A focusable member's name is drawn as the click target and the rest of the row after it. A name the cut shortened is
      // no target: what is shown must be what is focused, so that row is drawn whole and is not clickable.
      let focus: string | null = null
      if (r.row === 'member' && r.focus === true && text.startsWith(r.name)) { focus = r.name; text = text.slice(r.name.length) }
      return { icon: iconed ? r.icon : null, iconColor: iconed ? r.iconColor : null, tone: r.tone, indent, focus, text }
    }
    const out: Section[] = []
    const multi = teams.length > 1
    const add = (section: Section['section'], key: string, title: string, color: string | null, rows: SectionRow[]) => out.push({ section, key, title: cut(title, inner), color, bordered, rows })
    for (const [ti, t] of (teams as TeamModel[]).entries()) {
      const suffix = multi ? ` ${t.name}` : ''
      if (t.pipeline !== null) add('hierarchy', `hierarchy:${ti}`, `HIERARCHY${suffix}`, STYLE.box.hierarchy, t.pipeline.map((r) => row(r, 0)))
      const streams = [...new Set(t.members.map((m) => m.stream).filter((n) => typeof n === 'string' && n !== ''))].sort()
      if (t.members.length) add('team', `team:${ti}`, `TEAM ${t.name}`, STYLE.box.team, t.members.filter((m) => !streams.includes(m.stream)).map((m) => row(m.row, 0)))
      const claimed = new Set<number>()
      for (const [si, stream] of streams.entries()) {
        const names = new Set(t.members.filter((m) => m.stream === stream).map((m) => (m.row.row === 'member' ? m.row.name : '')))
        const mine = t.dispatches.flatMap((d, i) => (names.has(d.member) ? (claimed.add(i), [row(d.row, 2)]) : []))
        add('stream', `stream:${ti}:${stream}`, `STREAM ${stream}`, STYLE.streams[si % STYLE.streams.length],
          [...t.members.filter((m) => m.stream === stream).map((m) => row(m.row, 0)), ...mine])
      }
      const rest = t.dispatches.filter((_, i) => !claimed.has(i))
      if (rest.length) add('dispatches', `dispatches:${ti}`, `DISPATCHES${suffix}`, STYLE.box.dispatches, rest.map((d) => row(d.row, 0)))
    }
    return out.length ? out : flat()
  } catch {
    return flat()
  }
}
