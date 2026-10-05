// The status document read the way every consumer reads it (docs/status-file.md, "Reading it"), with no
// engine calls, so the mod's tests drive it directly.

/** The largest status.json read: a bigger file counts as no document. */
export const SIZE_CAP = 262144

export type Doc = {
  expiresMs: number
  memberSessions: readonly string[]
  timeline: readonly { atMs: number; entry: Record<string, unknown> }[]
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
 * not JSON, `schema` not 1, or a field the consumer reads that is missing or of the wrong type
 * (`expires_at`, `member_sessions`, `timeline` with every `at`).
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
  return { expiresMs, memberSessions: members as string[], timeline }
}

/**
 * The status entry's text at `nowMs` for the session `sessionId`, or undefined when nothing should show:
 * no document, expired, the picked entry malformed or not visible, a member session, or the
 * `status_entry` option off. Control characters are stripped.
 */
export function statusText(doc: Doc | null, nowMs: number, sessionId: string, statusEntry: boolean): string | undefined {
  if (!statusEntry || doc === null || nowMs >= doc.expiresMs) return undefined
  let picked = doc.timeline[0]
  for (const t of doc.timeline) if (t.atMs <= nowMs) picked = t
  const { visible, tone, text, short } = picked.entry
  if (typeof visible !== 'boolean' || typeof tone !== 'string' || typeof text !== 'string' || typeof short !== 'string') return undefined
  if (!visible || doc.memberSessions.includes(sessionId)) return undefined
  return text.replace(CONTROL, '')
}
