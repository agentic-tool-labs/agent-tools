import type { Register } from 'claude-code'

// The strict checkpoint and the smart-gopher gate, answered as a tool result instead of a hook error. The decision stays in
// pretooluse-nudge.mjs (run with --mod-checkpoint); this module only feeds it and shows the answer.

const TOOLS = ['Bash', 'Read', 'Grep', 'Glob', 'Agent', 'Task'] as const

// The main loop's agent type. No event or noun in the mod API carries it: the engine sets this variable under `--agent`
// (seen on 2.1.317, tests/test-mod-injection.sh fails if that stops); the `agent` setting is the other way to name one.
// Subagents are looked up by id.
const mainAgentType = async ($: any): Promise<string | undefined> =>
  (await $.env.get('CLAUDE_CODE_AGENT')) || (await $.settings.read({ key: 'agent' })) || undefined

// What a directive script would inject: the scripts hold the text and the ON/gopher/role gates. A failure injects nothing.
const injection = async ($: any, script: string): Promise<string | undefined> => {
  try {
    const ran = await $.process.run(['node', `${$.plugin.root}/hooks/${script}`], {
      stdin: JSON.stringify({ agent_type: await mainAgentType($) }),
      timeoutMs: 5000,
    })
    if (ran.exitCode === 0 && ran.stdout.trim()) return JSON.parse(ran.stdout).hookSpecificOutput?.additionalContext
  } catch {
    // never block a prompt
  }
  return undefined
}

export const register: Register = on => {
  const turns = new Map<string, string>()
  const types = new Map<string, string>()

  on('turn.start', ($, e, next) => {
    turns.set(e.agentId ?? '', e.turnId)
    return next(e)
  })

  // The one-line reminder each prompt, and the full directive when the conversation does not hold it: a new session, a
  // resume of one that never had it, after /clear or a compaction. prompt.submit is the main loop's alone; a prompt.context
  // block would also reach subagents, gophers included.
  on('prompt.submit', async ($, e, next) => {
    const [directive, tick] = await Promise.all([injection($, 'sessionstart.mjs'), injection($, 'userpromptsubmit.mjs')])
    const added = [tick].filter(Boolean) as string[]
    if (directive) {
      let held = false
      try {
        held = JSON.stringify(await $.session.messages({ as: 'api' })).includes(directive.slice(0, 40))
      } catch {
        // unreadable: inject, a second copy costs less than none
      }
      if (!held) added.unshift(directive)
    }
    return next(added.length ? { ...e, context: [...(e.context ?? []), ...added] } : e)
  })

  // An automatic compaction can land mid-turn, long before the next prompt. A main-loop request that carries fewer
  // messages than the last one follows a compaction, so the directive goes in as a row of its own unless the
  // conversation holds it. Not session.append on the compaction door: where an organization manages Claude Code it
  // passes over installed plugins (the engine's hooks-passed-over warning), and turn.step does not.
  let lastCount: number | undefined
  on('turn.step', async function* ($, e, next) {
    const shrank = !e.agentId && lastCount !== undefined && e.messageCount < lastCount
    if (!e.agentId) lastCount = e.messageCount
    if (shrank) {
      const text = await injection($, 'sessionstart.mjs')
      if (text) {
        try {
          const held = JSON.stringify(await $.session.messages({ as: 'api' })).includes(text.slice(0, 40))
          if (!held) await $.session.append({ message: { type: 'user', content: [{ type: 'text', text }] } })
        } catch {
          // never block a request
        }
      }
    }
    return yield* next(e)
  })

  for (const tool of TOOLS) {
    on('tool.call', { tool }, async ($, e, next) => {
      let reason: string | undefined
      try {
        const { tool: _tool, tool_use_id: _id, consent: _consent, agentId, ...tool_input } = e
        let agent_type = await mainAgentType($)
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
