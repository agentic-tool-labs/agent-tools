import { expect, mock, test } from 'claude-code/testing'

// `process.run` stands in for scripts/mod.js: `arm` answers `plan`, `check` answers `checks` in turn (then {}), `fired`
// is recorded. session.compact is the engine's.
const setup = (
  on: any,
  plan: object,
  compacted: object = { messages: [{ role: 'user', text: 'summary', toolUses: [] }] },
  checks: object[] = [],
) => {
  const seen = { compacts: [] as any[], fired: [] as any[], checked: [] as any[], stopsBeneath: 0 }
  const clock = mock.clock(on, { now: 0 })
  on('process.run', (_: unknown, e: { argv: string[]; init?: { stdin?: string } }) => {
    const verb = e.argv[2]
    const input = JSON.parse(e.init?.stdin ?? '{}')
    if (verb === 'fired') seen.fired.push(input)
    if (verb === 'check') seen.checked.push(input)
    const stdout = verb === 'arm' ? JSON.stringify(plan) : verb === 'check' ? JSON.stringify(checks.shift() ?? {}) : '{}'
    return { value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('session.compact', (_: unknown, e: { instructions?: string }) => {
    seen.compacts.push(e)
    return compacted
  })
  on('prompt.submit', (_: unknown, e: { text: string }) => ({ text: e.text }))
  // Stands for the settings hooks beneath (arm.js): the mod must always pass Stop on.
  on('classic.Stop', () => {
    seen.stopsBeneath++
    return {}
  })
  return { seen, clock }
}

const STOP = { session_id: 's1', transcript_path: '/tmp/t.jsonl', cwd: '/tmp', stop_hook_active: false }
const PLAN = { ms: 60_000, instructions: 'keep the plan', sessionId: 's1', tokens: 50_000 }

test('arm on Stop, compact once the idle window passes, record the fire', async ($, on) => {
  const { seen, clock } = setup(on, PLAN)
  await $.classic.Stop(STOP)
  expect(seen.stopsBeneath).toBe(1)
  await clock.advance(59_000)
  expect(seen.compacts.length).toBe(0)
  await clock.advance(2_000)
  expect(seen.compacts.length).toBe(1)
  expect(seen.compacts[0].instructions).toBe('keep the plan')
  expect(seen.fired.length).toBe(1)
  expect(seen.fired[0].ok).toBe(true)
  expect(seen.fired[0].sessionId).toBe('s1')
})

test('a prompt before the window passes cancels the compaction', async ($, on) => {
  const { seen, clock } = setup(on, PLAN)
  await $.classic.Stop(STOP)
  await clock.advance(30_000)
  await $.prompt.submit({ text: 'back' })
  await clock.advance(120_000)
  expect(seen.compacts.length).toBe(0)
  expect(seen.fired.length).toBe(0)
})

test('a helper that declines to arm (no ms) sets no timer', async ($, on) => {
  const { seen, clock } = setup(on, {})
  await $.classic.Stop(STOP)
  await clock.advance(24 * 60 * 60 * 1000)
  expect(seen.compacts.length).toBe(0)
})

test('a vetoed compaction is recorded as a failure', async ($, on) => {
  const { seen, clock } = setup(on, PLAN, { skip: 'busy' })
  await $.classic.Stop(STOP)
  await clock.advance(61_000)
  expect(seen.fired.length).toBe(1)
  expect(seen.fired[0].ok).toBe(false)
  expect(seen.fired[0].reason).toBe('compact-skipped')
})

test('a busy session at fire time waits another window instead of failing', async ($, on) => {
  const { seen, clock } = setup(on, PLAN, undefined, [{ why: 'pending-tool' }])
  await $.classic.Stop(STOP)
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
  await $.classic.Stop(STOP)
  await clock.advance(24 * 60 * 60 * 1000)
  expect(seen.compacts.length).toBe(0)
  expect(seen.checked.length).toBe(1)
})
