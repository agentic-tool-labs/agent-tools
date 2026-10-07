// Expected outputs for each status fixture (tests/fixtures/status/<case>.json, embedded in fixtures.ts),
// written by hand from the spec's rules. `now` is chosen to exercise the timeline pick; the band and the
// Pane are drawn at `columns`. A case with no view draws the Pane's one dim line and has no band or toasts.
type Line = { text: string; tone: string }
export type Vector = {
  now: string
  sessionId: string
  columns: number
  statusText: string | undefined
  band: Line | null
  pane: Line[]
  toasts: { key: string; text: string }[]
}

const NO_VIEW = { band: null, pane: [{ text: 'No hierarchy status here.', tone: 'idle' }], toasts: [] }

export const vectors: Readonly<Record<string, Vector>> = {
  bad: {
    now: '2026-01-01T12:01:30.000Z', sessionId: 'sess-orch', columns: 120, statusText: '2 live · 2 out · 2 stalled',
    band: { text: 'reviewer stalled on review-step · 1 check-in unanswered · +1 more', tone: 'bad' },
    pane: [
      { text: 'Hierarchy', tone: 'idle' },
      { text: 'No pipeline run.', tone: 'idle' },
      { text: 'Team', tone: 'idle' },
      { text: 'demo-architect · codex · pane · working 7m', tone: 'work' },
      { text: 'demo-reviewer · codex · pane · working 11m', tone: 'work' },
      { text: 'Dispatches', tone: 'idle' },
      { text: 'build-step → architect | eta 5m | ██████████ 100% | 7:30 | stalled', tone: 'bad' },
      { text: 'review-step → reviewer | eta 5m | ██████████ 100% | 11:30 | stalled', tone: 'bad' },
    ],
    toasts: [
      { key: 'stalled:20260101-115000-b002', text: 'reviewer stalled · review-step · 1 check-in unanswered' },
      { key: 'stalled:20260101-115400-b001', text: 'architect stalled · build-step · no report after 7m' },
    ],
  },
  hidden: { now: '2026-01-01T12:05:00.000Z', sessionId: 'sess-orch', columns: 120, statusText: undefined, ...NO_VIEW },
  idle: {
    now: '2026-01-01T12:00:00.000Z', sessionId: 'sess-orch', columns: 120, statusText: '2 live · 0 out',
    band: { text: '2 live · 0 out', tone: 'idle' },
    pane: [
      { text: 'Hierarchy', tone: 'idle' },
      { text: 'No pipeline run.', tone: 'idle' },
      { text: 'Team', tone: 'idle' },
      { text: 'demo-architect · codex · pane · idle 5m', tone: 'idle' },
      { text: 'demo-reviewer · codex · pane · idle 5m', tone: 'idle' },
      { text: 'Dispatches', tone: 'idle' },
      { text: 'None outstanding.', tone: 'idle' },
    ],
    toasts: [],
  },
  'member-session': { now: '2026-01-01T12:00:00.000Z', sessionId: 'sess-demo-reviewer', columns: 120, statusText: undefined, ...NO_VIEW },
  pipeline: {
    now: '2026-01-01T12:20:01.000Z', sessionId: 'sess-orch', columns: 120, statusText: '2 live · 1 out · 1 stalled',
    band: { text: 'reviewer stalled on ac-1 · no report after 30m', tone: 'bad' },
    pane: [
      { text: 'Hierarchy', tone: 'idle' },
      { text: 'round 2/3 · reviewer', tone: 'work' },
      { text: '1 decision waiting for you', tone: 'warn' },
      { text: 'Team', tone: 'idle' },
      { text: 'demo-architect · codex · pane · idle 35m', tone: 'idle' },
      { text: 'demo-reviewer · codex · pane · working 30m', tone: 'work' },
      { text: 'Dispatches', tone: 'idle' },
      { text: 'ac-1 → reviewer | eta 20m | ██████████ 100% | 30:01 | stalled', tone: 'bad' },
    ],
    toasts: [{ key: 'stalled:20260101-115000-p002', text: 'reviewer stalled · ac-1 · no report after 30m' }],
  },
  warn: {
    now: '2026-01-01T12:00:30.000Z', sessionId: 'sess-orch', columns: 120, statusText: '2 live · 1 out · 1 blocked',
    band: { text: 'architect is waiting on a prompt · answer it through the Orchestrator', tone: 'warn' },
    pane: [
      { text: 'Hierarchy', tone: 'idle' },
      { text: 'No pipeline run.', tone: 'idle' },
      { text: 'Team', tone: 'idle' },
      { text: 'demo-architect · codex · pane · blocked 1m', tone: 'warn' },
      { text: 'demo-reviewer · codex · pane · working 1m', tone: 'work' },
      { text: 'Dispatches', tone: 'idle' },
      { text: 'build-step → architect | eta 10m | ██░░░░░░░░ 25% | 2:30 | blocked', tone: 'warn' },
    ],
    toasts: [{ key: 'blocked:demo-architect:2026-01-01T11:59:30.000Z', text: 'architect blocked · Allow edits to config.toml? (y/n)' }],
  },
  work: {
    now: '2026-01-01T12:05:00.000Z', sessionId: 'sess-orch', columns: 120, statusText: '1 live · 1 out · 1 overdue',
    band: { text: 'architect is 1m 0s past its 5m eta', tone: 'bad' },
    pane: [
      { text: 'Hierarchy', tone: 'idle' },
      { text: 'No pipeline run.', tone: 'idle' },
      { text: 'Team', tone: 'idle' },
      { text: 'demo-architect · codex · pane · working 6m', tone: 'work' },
      { text: 'Dispatches', tone: 'idle' },
      { text: 'build-step → architect | eta 5m | ██████████ 100% | 6:00 | overdue', tone: 'bad' },
    ],
    toasts: [],
  },
}

// The sections the Pane draws for each fixture at its `columns`, written by hand from the spec: the box color
// (null: dim), the title, and each line as drawn (indent, icon, a space, then the text). The null-view cases draw
// the one line of `pane` and so have none here.
export type Boxed = { title: string; color: string | null; lines: string[] }
export const sectionsFor: Readonly<Record<string, Boxed[]>> = {
  bad: [
    { title: 'TEAM default', color: 'permission', lines: ['● demo-architect · codex · pane · working 7m', '● demo-reviewer · codex · pane · working 11m'] },
    { title: 'DISPATCHES', color: null, lines: ['▲ build-step → architect | eta 5m | ██████████ 100% | 7:30 | stalled', '▲ review-step → reviewer | eta 5m | ██████████ 100% | 11:30 | stalled'] },
  ],
  idle: [
    { title: 'TEAM default', color: 'permission', lines: ['○ demo-architect · codex · pane · idle 5m', '○ demo-reviewer · codex · pane · idle 5m'] },
  ],
  pipeline: [
    { title: 'HIERARCHY', color: 'claude', lines: ['round 2/3 · reviewer', '1 decision waiting for you'] },
    { title: 'TEAM demo', color: 'permission', lines: ['○ demo-architect · codex · pane · idle 35m', '● demo-reviewer · codex · pane · working 30m'] },
    { title: 'DISPATCHES', color: null, lines: ['▲ ac-1 → reviewer | eta 20m | ██████████ 100% | 30:01 | stalled'] },
  ],
  warn: [
    { title: 'TEAM default', color: 'permission', lines: ['■ demo-architect · codex · pane · blocked 1m', '● demo-reviewer · codex · pane · working 1m'] },
    { title: 'DISPATCHES', color: null, lines: ['↳ build-step → architect | eta 10m | ██░░░░░░░░ 25% | 2:30 | blocked'] },
  ],
  work: [
    { title: 'TEAM default', color: 'permission', lines: ['● demo-architect · codex · pane · working 6m'] },
    { title: 'DISPATCHES', color: null, lines: ['▲ build-step → architect | eta 5m | ██████████ 100% | 6:00 | overdue'] },
  ],
}
