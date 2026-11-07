import type { Register } from 'claude-code'

// Compacts an idle Claude Code session through the engine ($.session.compact) instead of typing /compact into its
// terminal. scripts/mod.js holds the config, the arm decision and the stats; it claims the turn before arm.js runs
// beneath this hook, so arm.js starts no injection timer. Where no engine loads this module, arm.js injects as before.

type Plan = { ms?: number; instructions?: string; [k: string]: unknown }

let timer: { cancel(): void } | undefined

function cancel() {
  timer?.cancel()
  timer = undefined
}

async function helper($: any, verb: string, input: unknown): Promise<Plan> {
  const ran = await $.process.run(['node', `${$.plugin.root}/scripts/mod.js`, verb], {
    stdin: JSON.stringify(input),
    timeoutMs: 10000,
  })
  return ran.exitCode === 0 && ran.stdout.trim() ? JSON.parse(ran.stdout) : {}
}

async function fire($: any, plan: Plan) {
  timer = undefined
  // timer.js's pre-fire guard: still busy or settling waits another window; a vanished transcript ends the arm.
  let why: unknown
  try {
    why = (await helper($, 'check', plan)).why
  } catch {
    // no verdict: compact, as an unguarded fire would
  }
  if (why === 'gone') return
  if (why) {
    plan.deferLogged = true
    timer = $.clock.after(plan.ms ?? 0, () => void fire($, plan))
    return
  }
  let outcome: { ok: boolean; reason?: string; detail?: string }
  try {
    const done = await $.session.compact(plan.instructions ? { instructions: plan.instructions } : {})
    outcome = done.skip ? { ok: false, reason: 'compact-skipped', detail: String(done.skip) } : { ok: true }
  } catch (err: any) {
    outcome = { ok: false, reason: 'compact-failed', detail: String(err?.message ?? err) }
  }
  try {
    await helper($, 'fired', { ...plan, ...outcome })
  } catch {
    // the fire log is a diagnostic
  }
}

export const register: Register = on => {
  on('classic.Stop', async ($, e, next) => {
    cancel()
    try {
      const plan = await helper($, 'arm', e)
      if (plan.ms) timer = $.clock.after(plan.ms, () => void fire($, plan))
    } catch {
      // nothing claimed: arm.js beneath arms its injection timer
    }
    return next(e)
  })

  on('prompt.submit', ($, e, next) => {
    cancel()
    return next(e)
  })

  on('session.end', ($, e, next) => {
    cancel()
    return next(e)
  })
}
