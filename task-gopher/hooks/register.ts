import type { Register } from 'claude-code'

// The strict checkpoint and the smart-gopher gate, answered as a tool result instead of a hook error. The decision stays in
// pretooluse-nudge.mjs (run with --mod-checkpoint); this module only feeds it and shows the answer.

const TOOLS = ['Bash', 'Read', 'Grep', 'Glob', 'Agent', 'Task'] as const

export const register: Register = on => {
  const turns = new Map<string, string>()
  const types = new Map<string, string>()

  on('turn.start', ($, e, next) => {
    turns.set(e.agentId ?? '', e.turnId)
    return next(e)
  })

  // The main loop's agent type (an `--agent` session) is only on the classic events; subagents are looked up by id.
  let mainType: string | undefined
  on('classic.SessionStart', ($, e, next) => {
    mainType = e.agent_type
    return next(e)
  })
  on('classic.UserPromptSubmit', ($, e, next) => {
    mainType = e.agent_type
    return next(e)
  })

  for (const tool of TOOLS) {
    on('tool.call', { tool }, async ($, e, next) => {
      let reason: string | undefined
      try {
        const { tool: _tool, tool_use_id: _id, consent: _consent, agentId, ...tool_input } = e
        let agent_type = mainType
        if (agentId) {
          if (!types.has(agentId)) {
            const found = (await $.agent.list()).find(a => a.id === agentId)
            if (found) types.set(agentId, found.type)
          }
          agent_type = types.get(agentId) // a subagent never inherits the main loop's type
        }
        const ran = await $.process.run(['node', `${$.plugin.root}/hooks/pretooluse-nudge.mjs`, '--mod-checkpoint'], {
          stdin: JSON.stringify({
            session_id: await $.session.id(),
            prompt_id: turns.get(agentId ?? ''),
            agent_id: agentId,
            agent_type,
            cwd: await $.session.cwd(),
            tool_name: tool,
            tool_input,
          }),
          timeoutMs: 5000,
        })
        if (ran.exitCode === 0 && ran.stdout.trim()) {
          const answer = JSON.parse(ran.stdout)
          if (typeof answer.checkpoint === 'string') reason = answer.checkpoint
        }
      } catch {
        // a broken checkpoint never blocks a tool
      }
      if (reason === undefined) return next(e)
      const text = `[task-gopher] NOT RUN. ${reason}`
      if (tool === 'Bash') return { result: { stdout: text, stderr: '', interrupted: false } }
      return { deny: text }
    })
  }
}
