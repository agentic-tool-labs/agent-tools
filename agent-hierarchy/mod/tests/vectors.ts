// Expected outputs for each status fixture (tests/fixtures/status/<case>.json, embedded in fixtures.ts),
// written by hand. `now` is chosen to exercise the timeline pick. P3 adds the band, the pane rows and the
// toast keys to each entry.
export type Vector = { now: string; sessionId: string; columns: number; statusText: string | undefined }

export const vectors: Readonly<Record<string, Vector>> = {
  bad: { now: '2026-01-01T12:01:30.000Z', sessionId: 'sess-orch', columns: 120, statusText: '2 live · 2 out · 2 stalled' },
  hidden: { now: '2026-01-01T12:05:00.000Z', sessionId: 'sess-orch', columns: 120, statusText: undefined },
  idle: { now: '2026-01-01T12:00:00.000Z', sessionId: 'sess-orch', columns: 120, statusText: '2 live · 0 out' },
  'member-session': { now: '2026-01-01T12:00:00.000Z', sessionId: 'sess-demo-reviewer', columns: 120, statusText: undefined },
  pipeline: { now: '2026-01-01T12:20:01.000Z', sessionId: 'sess-orch', columns: 120, statusText: '2 live · 1 out · 1 stalled' },
  warn: { now: '2026-01-01T12:00:30.000Z', sessionId: 'sess-orch', columns: 120, statusText: '2 live · 1 out · 1 blocked' },
  work: { now: '2026-01-01T12:05:00.000Z', sessionId: 'sess-orch', columns: 120, statusText: '1 live · 1 out · 1 overdue' },
}
