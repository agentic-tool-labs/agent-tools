import { expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type { On } from 'claude-code'

// Everything beneath the plugin is the engine: these hooks answer it and
// record what the plugin asked for.
function world(on: On) {
  const clock = mock.clock(on, { now: 1_000_000 })
  const seen = {
    nudges: [] as string[],
    prompts: [] as string[],
    toasts: [] as string[],
    statuses: [] as (string | undefined)[],
    notifies: [] as string[],
    logs: [] as string[],
    aborts: [] as string[],
  }
  on('turn.abort', (_, e) => (seen.aborts.push(e.turnId), { value: undefined }))
  on('command.register', () => ({ value: { command: 'retry-on-error' } }))
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('classic.StopFailure', () => ({}))
  on('turn.complete', () => ({ text: '' }))
  on('turn.start', (_, e) => ({ turnId: e.turnId }))
  on('prompt.submit', (_, e) => {
    ;(e.origin.kind === 'plugin' ? seen.nudges : seen.prompts).push(e.text)
    return { text: e.text }
  })
  on('ui.toast', (_, e) => (seen.toasts.push(e.text), { value: undefined }))
  on('ui.status', (_, e) => (seen.statuses.push(e.text), { value: undefined }))
  on('ui.notify', (_, e) => (seen.notifies.push(e.text), { value: { isSent: true, channel: 'kitty' } }))
  on('ui.log', (_, e) => (seen.logs.push(e.text), { value: undefined }))
  on('ui.render', ($, e) => {
    const { Text } = $.ui.resolve(e)
    return <Text>engine</Text>
  })
  return { clock, seen }
}

const start = ($: Engine, isInteractive = true) =>
  $.session.start({ cwd: '/', surface: isInteractive ? 'terminal' : null, isInteractive })

const fail = ($: Engine, error: 'server_error' | 'rate_limit' | 'unknown' | 'billing_error' | 'authentication_failed' | 'invalid_request', more: { error_details?: string; last_assistant_message?: string; agent_id?: string } = {}) =>
  $.classic.StopFailure({ error, ...more } as Parameters<Engine['classic']['StopFailure']>[0])

const turnEnd = ($: Engine, reason: 'answer' | 'aborted' | 'error', answer = '') =>
  $.turn.complete({ reason, answer, durationMs: 1, isAborted: reason === 'aborted', turnId: 't1' })

// The engine starts a turn for each nudge it takes; a failure report arriving
// before then still belongs to the failure that nudge answered.
const turnStart = ($: Engine, turnId = 't2') => $.turn.start({ text: '', turnId })

const composer =($: Engine, text: string) =>
  $.prompt.submit({ text, origin: { kind: 'composer' } } as Parameters<Engine['prompt']['submit']>[0])

test('1. a server_error arms a 5 s timer that sends one nudge', async ($, on) => {
  const { clock, seen } = world(on)
  await start($)
  await fail($, 'server_error')
  expect(seen.statuses.at(-1)).toMatch(/retrying in 5s — attempt 1\/3 \(server_error\)/)
  await clock.advance(4999)
  expect(seen.nudges.length).toBe(0)
  await clock.advance(1)
  expect(seen.nudges).toEqual([
    'The previous turn ended on an API error (server_error). Continue the task from where it stopped; re-check any step with side effects before repeating it.',
  ])
  expect(seen.statuses.at(-1)).toBeUndefined()
  await clock.advance(60_000)
  expect(seen.nudges.length).toBe(1)
})

test('2. StopFailure and turn.complete(error) for one turn retry once, in either order', async ($, on) => {
  const { clock, seen } = world(on)
  await start($)
  await fail($, 'server_error')
  await turnEnd($, 'error', 'API Error: 500')
  await clock.advance(5000)
  expect(seen.nudges.length).toBe(1)
  await clock.advance(60_000)
  expect(seen.nudges.length).toBe(1)

  await turnStart($)
  await turnEnd($, 'error', 'API Error: 500')
  await fail($, 'server_error')
  await clock.advance(10_000)
  expect(seen.nudges.length).toBe(2)
  await clock.advance(60_000)
  expect(seen.nudges.length).toBe(2)
})

test('2b. turn.complete(error) alone, its answer empty as a real failure has it, retries once under the generic kind', async ($, on) => {
  const { clock, seen } = world(on)
  await start($)
  await turnEnd($, 'error')
  await clock.advance(2000 + 4999)
  expect(seen.nudges.length).toBe(0)
  await clock.advance(1)
  expect(seen.nudges.length).toBe(1)
  expect(seen.nudges[0]).toContain('(api_error)')
  await clock.advance(120_000)
  expect(seen.nudges.length).toBe(1)
})

test('2c. with no StopFailure at all, each failed turn retries and the budget still ends it', async ($, on) => {
  const { clock, seen } = world(on)
  await start($)
  for (const n of [1, 2, 3]) {
    await turnStart($, `t${n}`)
    await turnEnd($, 'error')
    await clock.advance(120_000)
    expect(seen.nudges.length).toBe(n)
  }
  await turnStart($, 't4')
  await turnEnd($, 'error')
  await clock.advance(120_000)
  expect(seen.nudges.length).toBe(3)
  expect(seen.statuses.at(-1)).toBe('retry-on-error: gave up after 3 attempts (api_error)')
})

test('2d. a StopFailure past the wait upgrades the armed generic retry: its kind, its delay, one nudge', async ($, on) => {
  const { clock, seen } = world(on)
  await start($)
  await turnEnd($, 'error')
  await clock.advance(3000)
  expect(seen.statuses.at(-1)).toMatch(/\(api_error\)/)
  await fail($, 'rate_limit')
  await clock.advance(29_999)
  expect(seen.nudges.length).toBe(0)
  await clock.advance(1)
  expect(seen.nudges.length).toBe(1)
  expect(seen.nudges[0]).toContain('(rate_limit)')
  await clock.advance(120_000)
  expect(seen.nudges.length).toBe(1)
})

test('2e. a late StopFailure of a kind that never retries calls off the armed generic retry', async ($, on) => {
  const { clock, seen } = world(on)
  await start($)
  await turnEnd($, 'error')
  await clock.advance(3000)
  await fail($, 'billing_error')
  await clock.advance(120_000)
  expect(seen.nudges.length).toBe(0)
  expect(seen.toasts.at(-1)).toBe("retry-on-error: won't retry (billing_error)")
})

test('2f. a turn end past the wait does not override the StopFailure before it', async ($, on) => {
  const { clock, seen } = world(on)
  await start($)
  await fail($, 'billing_error')
  await clock.advance(3000)
  await turnEnd($, 'error')
  await clock.advance(120_000)
  expect(seen.nudges.length).toBe(0)

  await turnStart($)
  await fail($, 'rate_limit')
  await clock.advance(3000)
  await turnEnd($, 'error')
  await clock.advance(26_999)
  expect(seen.nudges.length).toBe(0)
  await clock.advance(1)
  expect(seen.nudges.length).toBe(1)
  expect(seen.nudges[0]).toContain('(rate_limit)')
})

test('2g. once a StopFailure has been seen, a failed turn with none is not retried; with none ever seen (2c) it is', async ($, on) => {
  const { clock, seen } = world(on)
  await start($)
  await fail($, 'billing_error')
  await turnStart($)
  await turnEnd($, 'error')
  await clock.advance(120_000)
  expect(seen.nudges.length).toBe(0)
  expect(seen.toasts.at(-1)).toBe('turn failed (unknown): no details')

  // the next turn's StopFailure still retries as before
  await turnStart($, 't3')
  await fail($, 'server_error')
  await clock.advance(5000)
  expect(seen.nudges.length).toBe(1)
})

test('2h. a subagent\'s failed turn, or a main turn that ended any other way, is no failure', async ($, on) => {
  const { clock, seen } = world(on)
  await start($)
  await $.turn.complete({ reason: 'error', answer: '', durationMs: 1, isAborted: false, turnId: 't1', agentId: 'a1' })
  await turnEnd($, 'answer', 'done')
  await turnEnd($, 'aborted')
  await clock.advance(120_000)
  expect(seen.nudges.length).toBe(0)
})

test('3. auth, billing and bad-request errors never submit, and each toasts', async ($, on) => {
  const { clock, seen } = world(on)
  await start($)
  for (const kind of ['billing_error', 'authentication_failed', 'invalid_request'] as const) {
    await fail($, kind)
    expect(seen.toasts.at(-1)).toBe(`retry-on-error: won't retry (${kind})`)
  }
  await clock.advance(120_000)
  expect(seen.nudges.length).toBe(0)
  expect(seen.toasts.length).toBe(3)
})

test('4. unknown retries only on transient text, in details or the last message', async ($, on) => {
  const { clock, seen } = world(on)
  await start($)
  await fail($, 'unknown', { error_details: 'API Error: Connection lost mid-response' })
  await clock.advance(5000)
  expect(seen.nudges.length).toBe(1)

  await turnStart($)
  await fail($, 'unknown', { last_assistant_message: 'API Error: Connection lost mid-response' })
  await clock.advance(10_000)
  expect(seen.nudges.length).toBe(2)

  await turnStart($, 't3')
  await fail($, 'unknown', { error_details: 'something odd' })
  await clock.advance(60_000)
  expect(seen.nudges.length).toBe(2)
  expect(seen.toasts.at(-1)).toBe('turn failed (unknown): something odd')
})

test('5. backoff runs 5, 10, 20 s, then gives up and notifies once', async ($, on) => {
  const { clock, seen } = world(on)
  await start($)
  for (const [i, delay] of [5000, 10_000, 20_000].entries()) {
    await fail($, 'server_error')
    await clock.advance(delay - 1)
    expect(seen.nudges.length).toBe(i)
    await clock.advance(1)
    expect(seen.nudges.length).toBe(i + 1)
    await turnStart($)
  }
  await fail($, 'server_error')
  await clock.advance(120_000)
  expect(seen.nudges.length).toBe(3)
  expect(seen.statuses.at(-1)).toBe('retry-on-error: gave up after 3 attempts (server_error)')
  expect(seen.notifies).toEqual(['retry-on-error: gave up after 3 attempts (server_error)'])
})

test('6. an answered turn resets attempts to 0', async ($, on) => {
  const { clock, seen } = world(on)
  await start($)
  await fail($, 'server_error')
  await clock.advance(5000)
  await turnStart($)
  await fail($, 'server_error')
  expect(seen.statuses.at(-1)).toMatch(/retrying in 10s — attempt 2\/3/)
  await clock.advance(10_000)
  await turnStart($, 't3')
  await turnEnd($, 'answer', 'done')
  await fail($, 'server_error')
  expect(seen.statuses.at(-1)).toMatch(/retrying in 5s — attempt 1\/3/)
})

test('7. a typed prompt while armed cancels the retry', async ($, on) => {
  const { clock, seen } = world(on)
  await start($)
  await fail($, 'server_error')
  await composer($, 'never mind, do this instead')
  await clock.advance(60_000)
  expect(seen.nudges.length).toBe(0)
  expect(seen.prompts).toEqual(['never mind, do this instead'])
  expect(seen.statuses.at(-1)).toBeUndefined()
})

test('8. an abort neither arms nor lets a pending retry fire', async ($, on) => {
  const { clock, seen } = world(on)
  await start($)
  await turnEnd($, 'aborted')
  await clock.advance(60_000)
  expect(seen.nudges.length).toBe(0)

  await fail($, 'server_error')
  await turnEnd($, 'aborted')
  await clock.advance(60_000)
  expect(seen.nudges.length).toBe(0)
  await fail($, 'server_error')
  expect(seen.statuses.at(-1)).toMatch(/attempt 1\/3/)
})

test('9a. a subagent failure never arms', async ($, on) => {
  const { clock, seen } = world(on)
  await start($)
  await fail($, 'server_error', { agent_id: 'a1' })
  await clock.advance(60_000)
  expect(seen.nudges.length).toBe(0)
  expect(seen.statuses.length).toBe(0)
})

test('9b. a headless session never arms', async ($, on) => {
  const { clock, seen } = world(on)
  await start($, false)
  await fail($, 'server_error')
  await clock.advance(60_000)
  expect(seen.nudges.length).toBe(0)
})

test('9c. a headless session arms when the headless option is on', { options: { headless: true } }, async ($, on) => {
  const { clock, seen } = world(on)
  await start($, false)
  await fail($, 'server_error')
  await clock.advance(5000)
  expect(seen.nudges.length).toBe(1)
})

test('10. rate_limit waits at least rateLimitDelayMs', async ($, on) => {
  const { clock, seen } = world(on)
  await start($)
  await fail($, 'rate_limit')
  await clock.advance(29_999)
  expect(seen.nudges.length).toBe(0)
  await clock.advance(1)
  expect(seen.nudges.length).toBe(1)
})

test('11. /retry-on-error off stops arming and on restores it', async ($, on) => {
  const { clock, seen } = world(on)
  await start($)
  const run = (args: string) =>
    $.command.run({ command: 'retry-on-error', args } as Parameters<Engine['command']['run']>[0])

  expect((await run('off')).text).toBe('retry-on-error: off for this session.')
  await fail($, 'server_error')
  await clock.advance(60_000)
  expect(seen.nudges.length).toBe(0)

  await run('on')
  await fail($, 'server_error')
  await clock.advance(5000)
  expect(seen.nudges.length).toBe(1)
  expect((await run('status')).text).toMatch(/^retry-on-error: on; attempts 1\/3; last error: server_error at /)
})

test('12. a failure inside the mod is logged and the session goes on', async ($, on) => {
  const { clock, seen } = world(on)
  on('state.get', () => ({ value: null as never }))
  await start($)
  await expect(fail($, 'server_error')).resolves.toBeDefined()
  await clock.advance(60_000)
  expect(seen.nudges.length).toBe(0)
  expect(seen.logs.length).toBe(1)
  expect(seen.logs[0]).toMatch(/^retry-on-error: /)
})

// A model request beneath the plugin whose chunks the test releases by hand;
// nothing arriving is a stalled stream.
function model(on: On) {
  const queue: (string | null)[] = []
  let wake: (() => void) | undefined
  on('turn.step', async function* (_, e) {
    for (;;) {
      while (queue.length === 0) await new Promise<void>((r) => (wake = r))
      const text = queue.shift()!
      if (text === null) {
        return { turnId: e.turnId, index: e.index, answer: '', toolUses: [], stopReason: 'end_turn', usage: null }
      }
      yield { kind: 'text' as const, index: 0, text }
    }
  })
  const push = (text: string | null) => {
    queue.push(text)
    wake?.()
  }
  return { chunk: (text = 'x') => push(text), end: () => push(null) }
}

const step = ($: Engine, agentId?: string) => {
  const stream = $.turn.step({ turnId: 't1', index: 0, model: 'opus', messageCount: 1, ...(agentId ? { agentId } : {}) })
  const got: unknown[] = []
  const done = (async () => {
    for await (const c of stream) got.push(c)
  })().catch(() => undefined)
  return { got, done }
}

test('13. silence past stallAbortMs aborts once and submits one stalled nudge', async ($, on) => {
  const { clock, seen } = world(on)
  model(on)
  await start($)
  step($)
  await clock.advance(299_000)
  expect(seen.aborts.length).toBe(0)
  await clock.advance(1000)
  expect(seen.aborts).toEqual(['t1'])
  await turnEnd($, 'aborted')
  await clock.advance(5000)
  expect(seen.nudges).toEqual([
    'The previous turn ended on an API error (stalled). Continue the task from where it stopped; re-check any step with side effects before repeating it.',
  ])
  await clock.advance(600_000)
  expect(seen.aborts.length).toBe(1)
  expect(seen.nudges.length).toBe(1)
})

test('14. arriving chunks keep resetting the stall timer and pass through unchanged', async ($, on) => {
  const { clock, seen } = world(on)
  const m = model(on)
  await start($)
  const s = step($)
  for (let i = 0; i < 5; i++) {
    await clock.advance(100_000)
    m.chunk(`c${i}`)
  }
  await clock.advance(299_000)
  expect(seen.aborts.length).toBe(0)
  expect(s.got).toEqual([0, 1, 2, 3, 4].map((i) => ({ kind: 'text', index: 0, text: `c${i}` })))
  await clock.advance(3000)
  expect(seen.aborts.length).toBe(1)
})

test('15. the stall notice appears at 30 s and clears when the stream resumes', async ($, on) => {
  const { clock, seen } = world(on)
  const m = model(on)
  await start($)
  step($)
  await clock.advance(29_000)
  expect(seen.statuses.some((t) => t?.startsWith('API stalled'))).toBe(false)
  await clock.advance(1000)
  expect(seen.statuses.at(-1)).toBe('API stalled 30s — auto-retry at 5:00 (Esc/type to cancel)')
  await clock.advance(15_000)
  expect(seen.statuses.at(-1)).toBe('API stalled 45s — auto-retry at 5:00 (Esc/type to cancel)')
  m.chunk()
  await clock.advance(1000)
  expect(seen.statuses.at(-1)).toBeUndefined()
})

test('16. typing while stalled cancels the watchdog', async ($, on) => {
  const { clock, seen } = world(on)
  model(on)
  await start($)
  step($)
  await clock.advance(60_000)
  await composer($, 'still there?')
  expect(seen.statuses.at(-1)).toBeUndefined()
  await clock.advance(600_000)
  expect(seen.aborts.length).toBe(0)
  expect(seen.nudges.length).toBe(0)
})

test('17. a subagent step is never watched', async ($, on) => {
  const { clock, seen } = world(on)
  model(on)
  await start($)
  step($, 'a1')
  await clock.advance(600_000)
  expect(seen.aborts.length).toBe(0)
  expect(seen.statuses.length).toBe(0)
})

test('18. the watchdog abort does not double-submit through the 0.1 path', async ($, on) => {
  const { clock, seen } = world(on)
  model(on)
  await start($)
  step($)
  await clock.advance(300_000)
  expect(seen.aborts).toEqual(['t1'])
  await fail($, 'unknown', { error_details: 'API Error: Connection lost mid-response' })
  await turnEnd($, 'error', 'API Error: Connection lost mid-response')
  await turnEnd($, 'aborted')
  expect(seen.statuses.at(-1)).toMatch(/retrying in \ds — attempt 1\/3 \(stalled\)/)
  await clock.advance(600_000)
  expect(seen.nudges.length).toBe(1)
})

test('19. a turn that ends normally clears the watchdog', async ($, on) => {
  const { clock, seen } = world(on)
  model(on)
  await start($)
  step($)
  await clock.advance(40_000)
  await turnEnd($, 'answer', 'done')
  await clock.advance(600_000)
  expect(seen.aborts.length).toBe(0)
  expect(seen.statuses.at(-1)).toBeUndefined()
})

test('20. stallWatchdog=false disables the watchdog', { options: { stallWatchdog: false } }, async ($, on) => {
  const { clock, seen } = world(on)
  model(on)
  await start($)
  step($)
  await clock.advance(600_000)
  expect(seen.aborts.length).toBe(0)
  expect(seen.statuses.length).toBe(0)
})

test('21. out of budget, a stall gives up without aborting', { options: { maxAttempts: 0 } }, async ($, on) => {
  const { clock, seen } = world(on)
  model(on)
  await start($)
  step($)
  await clock.advance(300_000)
  expect(seen.aborts.length).toBe(0)
  expect(seen.statuses.at(-1)).toBe('retry-on-error: gave up after 0 attempts (stalled)')
})

test('22. StopFailure then turn.complete(error) inside the window: one nudge', async ($, on) => {
  const { clock, seen } = world(on)
  await start($)
  await fail($, 'server_error')
  await clock.advance(1500)
  await turnEnd($, 'error', 'API Error: 500')
  await clock.advance(120_000)
  expect(seen.nudges.length).toBe(1)
})

test('23. turn.complete(error) then StopFailure: one nudge', async ($, on) => {
  const { clock, seen } = world(on)
  await start($)
  await turnEnd($, 'error', 'API Error: 500')
  await clock.advance(1500)
  await fail($, 'server_error')
  await clock.advance(120_000)
  expect(seen.nudges.length).toBe(1)
})

test('24. StopFailure twice for one failure, the second after the nudge: one nudge', async ($, on) => {
  const { clock, seen } = world(on)
  await start($)
  await fail($, 'server_error')
  await clock.advance(5000)
  expect(seen.nudges.length).toBe(1)
  await fail($, 'server_error')
  await clock.advance(120_000)
  expect(seen.nudges.length).toBe(1)
})

test('25. turn.complete(error) after the window and after the nudge: one nudge', async ($, on) => {
  const { clock, seen } = world(on)
  await start($)
  await fail($, 'server_error')
  await clock.advance(6000)
  await turnEnd($, 'error', 'API Error: 500')
  await clock.advance(120_000)
  expect(seen.nudges.length).toBe(1)
})

test('26. a failure of the nudge turn itself still retries', async ($, on) => {
  const { clock, seen } = world(on)
  await start($)
  await fail($, 'server_error')
  await clock.advance(5000)
  await turnStart($)
  await fail($, 'server_error')
  await clock.advance(10_000)
  expect(seen.nudges.length).toBe(2)
})

const BAND = {
  plugin: 'retry-on-error',
  component: 'AbovePrompt',
  props: { hasSurvey: false, isWorking: true },
} as const

const band = async ($: Engine) => {
  const ui = await $.ui.mount({ ...BAND, surface: 'terminal' } as Parameters<Engine['ui']['mount']>[0])
  const button = await ui.find({ key: 'retry-now' })
  return { ui, button }
}

const now = ($: Engine) =>
  $.command.run({ command: 'retry-on-error', args: 'now' } as Parameters<Engine['command']['run']>[0])

const STALLED_NUDGE =
  'The previous turn ended on an API error (stalled). Continue the task from where it stopped; re-check any step with side effects before repeating it.'

test('27. Retry now fires the stall abort and nudge once, then the band goes', async ($, on) => {
  const { clock, seen } = world(on)
  model(on)
  await start($)
  step($)
  await clock.advance(40_000)
  const { ui, button } = await band($)
  expect(button).toBeDefined()
  await ui.press({ key: 'retry-now' })
  expect(seen.aborts).toEqual(['t1'])
  await ui.unmount()
  expect((await band($)).button).toBeUndefined()
  expect((await now($)).text).toBe('retry-on-error: nothing is stalled.')
  await turnEnd($, 'aborted')
  await clock.advance(5000)
  expect(seen.nudges).toEqual([STALLED_NUDGE])
  await clock.advance(600_000)
  expect(seen.aborts.length).toBe(1)
  expect(seen.nudges.length).toBe(1)
})

test('28. /retry-on-error now fires the same abort and nudge once', async ($, on) => {
  const { clock, seen } = world(on)
  model(on)
  await start($)
  step($)
  await clock.advance(40_000)
  expect((await now($)).text).toBe('retry-on-error: retrying the stalled request now.')
  expect((await now($)).text).toBe('retry-on-error: nothing is stalled.')
  expect(seen.aborts).toEqual(['t1'])
  await turnEnd($, 'aborted')
  await clock.advance(5000)
  expect(seen.nudges).toEqual([STALLED_NUDGE])
  await clock.advance(600_000)
  expect(seen.aborts.length).toBe(1)
  expect(seen.nudges.length).toBe(1)
})

test('29. before a stall shows, there is no band and now does nothing', async ($, on) => {
  const { clock, seen } = world(on)
  model(on)
  await start($)
  expect((await band($)).button).toBeUndefined()
  expect((await now($)).text).toBe('retry-on-error: nothing is stalled.')
  step($)
  await clock.advance(10_000)
  expect((await band($)).button).toBeUndefined()
  expect((await now($)).text).toBe('retry-on-error: nothing is stalled.')
  expect(seen.aborts.length).toBe(0)
  expect(seen.nudges.length).toBe(0)
})

test('30. the band hides when the stream recovers, and on Esc', async ($, on) => {
  const { clock } = world(on)
  const m = model(on)
  await start($)
  step($)
  await clock.advance(30_000)
  expect((await band($)).button).toBeDefined()
  m.chunk()
  await clock.advance(1000)
  expect((await band($)).button).toBeUndefined()
  await clock.advance(30_000)
  expect((await band($)).button).toBeDefined()
  await turnEnd($, 'aborted')
  expect((await band($)).button).toBeUndefined()
})

test('31. the band hides when the user types', async ($, on) => {
  const { clock } = world(on)
  model(on)
  await start($)
  step($)
  await clock.advance(30_000)
  expect((await band($)).button).toBeDefined()
  await composer($, 'still there?')
  expect((await band($)).button).toBeUndefined()
})
