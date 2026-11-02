import type { Register } from 'claude-code'

// The one-time GitHub nudges, answered as a tool result instead of a hook error. The decisions stay in guard.mjs
// (run with --mod-nudge); this module only feeds it the call and shows the answer.

const COVERED = /^(Bash|mcp__github__.*|mcp__plugin_github-pr-toolkit_github__.*)$/

export const register: Register = on => {
  on('tool.call', async ($, e, next) => {
    if (!COVERED.test(e.tool)) return next(e)
    const { tool, tool_use_id: _id, consent: _consent, agentId, ...tool_input } = e
    if (agentId) return next(e) // subagents are the delegates; the hook entry grants them

    let nudge: string | undefined
    try {
      const ran = await $.process.run(['node', `${$.plugin.root}/hooks/guard.mjs`, '--mod-nudge'], {
        stdin: JSON.stringify({
          session_id: await $.session.id(),
          cwd: await $.session.cwd(),
          tool_name: tool,
          tool_input,
        }),
        timeoutMs: 5000,
      })
      if (ran.exitCode === 0 && ran.stdout.trim()) {
        const answer = JSON.parse(ran.stdout)
        if (typeof answer.nudge === 'string') nudge = answer.nudge
      }
    } catch {
      // a broken nudge never blocks a tool
    }
    if (nudge === undefined) return next(e)
    const text = `[github-pr-toolkit] NOT RUN. ${nudge}`
    if (tool === 'Bash') return { result: { stdout: text, stderr: '', interrupted: false } }
    return { deny: text }
  })
}
