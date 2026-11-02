import { atom, read, update } from 'claude-code'
import type { Hook, PluginOptions, Register, Timer } from 'claude-code'

import type { RetryLast } from '../types'

type Engine = Parameters<Hook<'session.start'>>[0]
type Failure = { kind: string; details?: string; message?: string; turnId?: string }

const ATTEMPTS = { plugin: 'retry-on-error', key: 'attempts' } as const
const DISABLED = { plugin: 'retry-on-error', key: 'disabled' } as const
const LAST = { plugin: 'retry-on-error', key: 'last' } as const
// True from a nudge's submit until the next main-loop turn starts: a failure
// report arriving in between belongs to the failure that nudge already
// answered. Kept in $.state so it holds across a hot reload.
const NUDGED = { plugin: 'retry-on-error', key: 'nudged' } as const
// True while the stall notice shows; the Retry now band draws from it.
const stalled = atom({ plugin: 'retry-on-error', key: 'stalled' } as const, false)

const RETRYABLE = new Set(['server_error', 'overloaded', 'rate_limit', 'stalled'])
const TRANSIENT = /connection lost|mid-response|ECONNRESET|socket hang up|stream (closed|ended)|timed? ?out|5\d\d/i
// StopFailure and turn.complete(error) both report one failed turn, in an
// order nobody guarantees; StopFailure carries no turnId, so a time window
// pairs them.
const PAIR_MS = 2000

function readOptions(options: PluginOptions) {
  return {
    enabled: options.enabled !== false,
    maxAttempts: Number(options.maxAttempts ?? 3),
    baseDelayMs: Number(options.baseDelayMs ?? 5000),
    maxDelayMs: Number(options.maxDelayMs ?? 60000),
    rateLimitDelayMs: Number(options.rateLimitDelayMs ?? 30000),
    nudgeText: String(options.nudgeText ?? ''),
    retryMaxOutput: options.retryMaxOutput === true,
    headless: options.headless === true,
    notifyOnGiveUp: options.notifyOnGiveUp !== false,
    stallWatchdog: options.stallWatchdog !== false,
    stallNoticeMs: Number(options.stallNoticeMs ?? 30000),
    stallAbortMs: Number(options.stallAbortMs ?? 300000),
  }
}

let opt = readOptions({})
let interactive = true
let fire: Timer | undefined
let tick: Timer | undefined
// A turn.complete(error) that arrived first waits here for its StopFailure,
// which carries the precise error kind.
let fallback: Timer | undefined
let lastStopFailureAt = -Infinity

// The main loop's open model request, watched for stream silence. Chunks only
// bump a counter so the stream path never waits on a $ call; the 1 s watch
// notices a changed count and moves lastAt, so silence is measured to ±1 s.
type Step = { turnId: string; lastAt: number; chunks: number; seen: number; noticed: boolean }
let step: Step | undefined
let watch: Timer | undefined
// The turn the watchdog aborted itself: its aborted/error end must not cancel
// or re-arm the resume the watchdog already scheduled.
let selfAborted: string | undefined

async function inScope($: Engine) {
  return opt.enabled && (interactive || opt.headless) && (await $.state.get(DISABLED)).value !== true
}

async function guarded($: Engine, work: () => Promise<void>) {
  try {
    await work()
  } catch (err) {
    $.ui.log(`retry-on-error: ${err instanceof Error ? err.message : String(err)}`)
  }
}

function stopWatch($: Engine) {
  watch?.cancel()
  watch = undefined
  if (step?.noticed) {
    $.ui.status(undefined)
    void update($, stalled, () => false)
  }
  step = undefined
}

function cancel($: Engine) {
  fire?.cancel()
  tick?.cancel()
  fallback?.cancel()
  fire = tick = fallback = undefined
  selfAborted = undefined
  stopWatch($)
  $.ui.status(undefined)
}

const clockText = (ms: number) => {
  const s = Math.round(ms / 1000)
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`
}

async function checkStall($: Engine, s: Step) {
  const now = await $.clock.now()
  if (s !== step) return
  if (s.seen !== s.chunks) {
    s.seen = s.chunks
    s.lastAt = now
  }
  const silent = now - s.lastAt
  if (silent >= opt.stallAbortMs) {
    await retryStall($, s)
  } else if (silent >= opt.stallNoticeMs) {
    if (!s.noticed) void update($, stalled, () => true)
    s.noticed = true
    $.ui.status(
      `API stalled ${Math.floor(silent / 1000)}s — auto-retry at ${clockText(opt.stallAbortMs)} (Esc/type to cancel)`,
    )
  } else if (s.noticed) {
    s.noticed = false
    $.ui.status(undefined)
    void update($, stalled, () => false)
  }
}

// Aborts the stalled request and arms the resume nudge. The stall timeout, the
// Retry now button and `/retry-on-error now` all land here; stopping the watch
// before the first await claims the step, so it fires once per stall.
async function retryStall($: Engine, s: Step) {
  if (s !== step) return
  stopWatch($)
  if (!(await inScope($))) return
  const attempts = (await $.state.get(ATTEMPTS)).value ?? 0
  // Out of budget: give up as an error retry does, and leave the request to the engine.
  if (attempts < opt.maxAttempts) {
    selfAborted = s.turnId
    await $.turn.abort({ turnId: s.turnId }).catch((err: unknown) => {
      selfAborted = undefined
      throw err
    })
  }
  await handle($, { kind: 'stalled', turnId: s.turnId })
  if (fire) selfAborted = s.turnId
}

// Forces the stall timeout early; false when no stall is showing.
async function retryNow($: Engine) {
  if (!step?.noticed) return false
  await retryStall($, step)
  return true
}

function isRetryable(f: Failure) {
  if (RETRYABLE.has(f.kind)) return true
  if (f.kind === 'max_output_tokens') return opt.retryMaxOutput
  return f.kind === 'unknown' && TRANSIENT.test(`${f.details ?? ''}\n${f.message ?? ''}`)
}

function nudge(kind: string) {
  return kind === 'max_output_tokens'
    ? 'Continue from where you stopped.'
    : opt.nudgeText.replaceAll('<kind>', kind)
}

const nudgeOut = async ($: Engine) => (await $.state.get(NUDGED)).value === true

// Every nudge goes through here. The version check makes two submits racing
// for one failure claim it once.
async function submitNudge($: Engine, kind: string, attempts: number) {
  const held = await $.state.get(NUDGED)
  if (held.value === true) return
  if (!(await $.state.set(NUDGED, true, { ifVersion: held.version })).isSet) return
  await $.state.set(ATTEMPTS, attempts + 1)
  void $.prompt.submit({ text: nudge(kind) })
}

async function handle($: Engine, f: Failure) {
  if (await nudgeOut($)) return
  const last: RetryLast = { kind: f.kind, at: await $.clock.now() }
  if (f.details !== undefined) last.details = f.details
  if (f.turnId !== undefined) last.turnId = f.turnId
  await $.state.set(LAST, last)

  if (!isRetryable(f)) {
    $.ui.toast(
      f.kind === 'unknown'
        ? `turn failed (unknown): ${f.details ?? f.message ?? 'no details'}`
        : `retry-on-error: won't retry (${f.kind})`,
    )
    return
  }

  const attempts = (await $.state.get(ATTEMPTS)).value ?? 0
  if (attempts >= opt.maxAttempts) {
    const text = `retry-on-error: gave up after ${attempts} attempts (${f.kind})`
    cancel($)
    $.ui.status(text)
    $.ui.toast(text)
    if (opt.notifyOnGiveUp) await $.ui.notify(text)
    return
  }

  let delay = Math.min(opt.baseDelayMs * 2 ** attempts, opt.maxDelayMs)
  if (f.kind === 'rate_limit') delay = Math.max(delay, opt.rateLimitDelayMs)

  cancel($)
  let left = Math.ceil(delay / 1000)
  const show = () =>
    $.ui.status(`retrying in ${left}s — attempt ${attempts + 1}/${opt.maxAttempts} (${f.kind})`)
  show()
  tick = $.clock.every(1000, () => {
    left = Math.max(0, left - 1)
    show()
  })
  fire = $.clock.after(delay, () => {
    cancel($)
    void guarded($, () => submitNudge($, f.kind, attempts))
  })
}

export const register: Register = (on, options) => {
  opt = readOptions(options)

  on('session.start', async ($, e, next) => {
    interactive = e.isInteractive
    await guarded($, async () => {
      await $.command.register({
        name: 'retry-on-error',
        description: 'Auto-retry after API errors: on, off, status, or now (retry a stalled request)',
      })
    })
    return next(e)
  })

  on('classic.StopFailure', async ($, e, next) => {
    // agent_type is also set on the main thread under --agent; agent_id only in a subagent.
    if (e.agent_id === undefined) {
      await guarded($, async () => {
        if (!(await inScope($)) || selfAborted !== undefined) return
        lastStopFailureAt = await $.clock.now()
        fallback?.cancel()
        fallback = undefined
        await handle($, { kind: e.error, details: e.error_details, message: e.last_assistant_message })
      })
    }
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    if (e.agentId === undefined) {
      await guarded($, async () => {
        stopWatch($)
        if (e.turnId === selfAborted && (e.reason === 'aborted' || e.reason === 'error')) return
        if (e.reason === 'answer') await $.state.set(ATTEMPTS, 0)
        else if (e.reason === 'aborted') cancel($)
        else if (e.reason === 'error') {
          if (!(await inScope($))) return
          if ((await $.clock.now()) - lastStopFailureAt <= PAIR_MS) return
          fallback?.cancel()
          fallback = $.clock.after(PAIR_MS, () => {
            fallback = undefined
            void guarded($, () => handle($, { kind: 'unknown', message: e.answer, turnId: e.turnId }))
          })
        }
      })
    }
    return next(e)
  })

  on('turn.start', async ($, e, next) => {
    if (e.agentId === undefined) {
      await guarded($, async () => {
        if (await nudgeOut($)) await $.state.set(NUDGED, false)
      })
    }
    return next(e)
  })

  on('turn.step', async function*($, e, next) {
    let s: Step | undefined
    if (e.agentId === undefined && opt.stallWatchdog) {
      await guarded($, async () => {
        if (!(await inScope($))) return
        stopWatch($)
        const now = await $.clock.now()
        const mine: Step = { turnId: e.turnId, lastAt: now, chunks: 0, seen: 0, noticed: false }
        step = s = mine
        watch = $.clock.every(1000, () => void guarded($, () => checkStall($, mine)))
      })
    }
    try {
      for await (const c of next(e)) {
        // Engine chunks include the engine's own retry markers, which mean
        // the request is still stuck, so they do not count as progress.
        if (s && c.kind !== 'engine') s.chunks++
        yield c
      }
    } finally {
      if (s && s === step) stopWatch($)
    }
  })

  on('prompt.submit', async ($, e, next) => {
    if (e.origin.kind === 'composer' || e.origin.kind === 'bridge') {
      await guarded($, async () => {
        cancel($)
        await $.state.set(ATTEMPTS, 0)
      })
    }
    return next(e)
  })

  on('command.run', { command: 'retry-on-error' }, async ($, e) => {
    const arg = e.args.trim().toLowerCase()
    if (arg === 'now') {
      let fired = false
      await guarded($, async () => {
        fired = await retryNow($)
      })
      return { text: fired ? 'retry-on-error: retrying the stalled request now.' : 'retry-on-error: nothing is stalled.' }
    }
    if (arg === 'off' || arg === 'on') {
      await $.state.set(DISABLED, arg === 'off')
      if (arg === 'off') cancel($)
      return { text: `retry-on-error: ${arg} for this session.` }
    }
    const disabled = (await $.state.get(DISABLED)).value === true
    const attempts = (await $.state.get(ATTEMPTS)).value ?? 0
    const last = (await $.state.get(LAST)).value
    const state = !opt.enabled ? 'off (globally)' : disabled ? 'off (this session)' : 'on'
    const lastText = last ? `${last.kind} at ${new Date(last.at).toISOString()}` : 'none'
    return {
      text: `retry-on-error: ${state}; attempts ${attempts}/${opt.maxAttempts}; last error: ${lastText}`,
    }
  })

  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    // The atom is read for its redraws; `step` decides, since a reload drops the
    // watched step while the stored flag can still say true.
    const isStalled = await read($, stalled)
    if (e.props.hasSurvey || !isStalled || !step?.noticed) return next(e)
    const { Box, Button, Text } = $.ui.resolve(e)
    return (
      <Box>
        <Text dimColor>retry-on-error: API stalled </Text>
        <Button key="retry-now" label="Retry now" onPress={() => guarded($, async () => void (await retryNow($)))} />
      </Box>
    )
  })
}
