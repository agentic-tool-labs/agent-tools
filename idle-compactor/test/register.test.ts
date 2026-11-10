import { expect, mock, test } from 'claude-code/testing'

// `process.run` stands in for scripts/mod.js and disarm.js: `arm` answers `plan`, `check` answers `checks` in turn
// (then {}), `fired`, `arm` inputs and disarm.js runs are recorded. session.compact is the engine's.
const setup = (
  on: any,
  plan: object,
  compacted: object = { messages: [{ role: 'user', text: 'summary', toolUses: [] }] },
  checks: object[] = [],
) => {
  const seen = {
    compacts: [] as any[],
    fired: [] as any[],
    checked: [] as any[],
    armed: [] as any[],
    disarmed: [] as any[],
    turnsBeneath: 0,
  }
  const clock = mock.clock(on, { now: 0 })
  on('process.run', (_: unknown, e: { argv: string[]; init?: { stdin?: string } }) => {
    const input = JSON.parse(e.init?.stdin ?? '{}')
    const ok = (stdout: string) => ({
      value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false },
    })
    if (e.argv[1].endsWith('/scripts/disarm.js')) {
      seen.disarmed.push(input)
      return ok('')
    }
    const verb = e.argv[2]
    if (verb === 'arm') seen.armed.push(input)
    if (verb === 'fired') seen.fired.push(input)
    if (verb === 'check') seen.checked.push(input)
    return ok(verb === 'arm' ? JSON.stringify(plan) : verb === 'check' ? JSON.stringify(checks.shift() ?? {}) : '{}')
  })
  on('session.id', () => ({ value: 's1' }))
  on('session.cwd', () => ({ value: '/work/sub' }))
  on('session.root', () => ({ value: '/work' }))
  on('session.usage', () => ({ value: { startedAt: 0, context: { tokens: 50_000, window: 200_000 }, rateLimits: [] } }))
  on('session.compact', (_: unknown, e: { instructions?: string }) => {
    seen.compacts.push(e)
    return compacted
  })
  on('prompt.submit', (_: unknown, e: { text: string }) => ({ text: e.text }))
  // Stands for the engine beneath: the mod must always pass turn.complete on.
  on('turn.complete', (_: unknown, e: { answer: string }) => {
    seen.turnsBeneath++
    return { text: e.answer }
  })
  return { seen, clock }
}

const TURN = { answer: 'done', durationMs: 1, isAborted: false, turnId: 't1', reason: 'answer' as const }
const PLAN = { ms: 60_000, instructions: 'keep the plan', sessionId: 's1', tokens: 50_000 }

test('arm on turn.complete, compact once the idle window passes, record the fire', async ($, on) => {
  const { seen, clock } = setup(on, PLAN)
  await $.turn.complete(TURN)
  expect(seen.turnsBeneath).toBe(1)
  await clock.advance(59_000)
  expect(seen.compacts.length).toBe(0)
  await clock.advance(2_000)
  expect(seen.compacts.length).toBe(1)
  expect(seen.compacts[0].instructions).toBe('keep the plan')
  expect(seen.fired.length).toBe(1)
  expect(seen.fired[0].ok).toBe(true)
  expect(seen.fired[0].sessionId).toBe('s1')
})

test('the arm takes the session id, directories and context fill from $.session', async ($, on) => {
  const { seen } = setup(on, PLAN)
  await $.turn.complete(TURN)
  expect(seen.armed.length).toBe(1)
  expect(seen.armed[0]).toEqual({ session_id: 's1', cwd: '/work/sub', root: '/work', tokens: 50_000 })
})

test('an arm runs disarm.js for the session, stopping any timer arm.js started', async ($, on) => {
  const { seen } = setup(on, PLAN)
  await $.turn.complete(TURN)
  expect(seen.disarmed).toEqual([{ session_id: 's1' }])
})

test('a helper that declines to arm (no ms) sets no timer and leaves arm.js armed', async ($, on) => {
  const { seen, clock } = setup(on, {})
  await $.turn.complete(TURN)
  await clock.advance(24 * 60 * 60 * 1000)
  expect(seen.compacts.length).toBe(0)
  expect(seen.disarmed.length).toBe(0)
})

test("a subagent's turn.complete does not arm", async ($, on) => {
  const { seen, clock } = setup(on, PLAN)
  await $.turn.complete({ ...TURN, agentId: 'a1' })
  expect(seen.turnsBeneath).toBe(1)
  expect(seen.armed.length).toBe(0)
  await clock.advance(24 * 60 * 60 * 1000)
  expect(seen.compacts.length).toBe(0)
})

test('classic.Stop no longer arms', async ($, on) => {
  const { seen, clock } = setup(on, PLAN)
  on('classic.Stop', () => ({}))
  await $.classic.Stop({ stop_hook_active: false })
  expect(seen.armed.length).toBe(0)
  await clock.advance(24 * 60 * 60 * 1000)
  expect(seen.compacts.length).toBe(0)
})

test('a prompt before the window passes cancels the compaction', async ($, on) => {
  const { seen, clock } = setup(on, PLAN)
  await $.turn.complete(TURN)
  await clock.advance(30_000)
  await $.prompt.submit({ text: 'back' })
  await clock.advance(120_000)
  expect(seen.compacts.length).toBe(0)
  expect(seen.fired.length).toBe(0)
})

test('a vetoed compaction is recorded as a failure', async ($, on) => {
  const { seen, clock } = setup(on, PLAN, { skip: 'busy' })
  await $.turn.complete(TURN)
  await clock.advance(61_000)
  expect(seen.fired.length).toBe(1)
  expect(seen.fired[0].ok).toBe(false)
  expect(seen.fired[0].reason).toBe('compact-skipped')
})

test('a busy session at fire time waits another window instead of failing', async ($, on) => {
  const { seen, clock } = setup(on, PLAN, undefined, [{ why: 'pending-tool' }])
  await $.turn.complete(TURN)
  await clock.advance(61_000)
  expect(seen.compacts.length).toBe(0)
  expect(seen.fired.length).toBe(0)
  await clock.advance(60_000)
  expect(seen.compacts.length).toBe(1)
  expect(seen.checked[1].deferLogged).toBe(true)
  expect(seen.fired[0].ok).toBe(true)
})

test('a vanished transcript ends the arm without compacting', async ($, on) => {
  const { seen, clock } = setup(on, PLAN, undefined, [{ why: 'gone' }])
  await $.turn.complete(TURN)
  await clock.advance(24 * 60 * 60 * 1000)
  expect(seen.compacts.length).toBe(0)
  expect(seen.checked.length).toBe(1)
})
