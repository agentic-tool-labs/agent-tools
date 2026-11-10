import type { Register } from 'claude-code'

// Compacts an idle Claude Code session through the engine ($.session.compact) instead of typing /compact into its
// terminal. scripts/mod.js holds the config, the arm decision and the stats; it claims the turn so arm.js starts no
// injection timer, and disarm.js stops one arm.js already started. Where no engine loads this module, arm.js injects.

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
  // turn.complete, not classic.Stop: where an organization manages Claude Code a user plugin's classic.* hooks are
  // passed over. The main loop's end alone: a subagent's turn (agentId) leaves the session busy.
  on('turn.complete', async ($, e, next) => {
    if (e.agentId) return next(e)
    cancel()
    try {
      const [session_id, cwd, root, usage] = await Promise.all([
        $.session.id(),
        $.session.cwd(),
        $.session.root(),
        $.session.usage(),
      ])
      const plan = await helper($, 'arm', { session_id, cwd, root, tokens: usage.context.tokens ?? null })
      if (plan.ms) {
        timer = $.clock.after(plan.ms, () => void fire($, plan))
        // Whichever of this hook and arm.js's Stop runs first, arm.js's injection timer is stopped.
        await $.process.run(['node', `${$.plugin.root}/scripts/disarm.js`], {
          stdin: JSON.stringify({ session_id }),
          timeoutMs: 10000,
        })
      }
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
