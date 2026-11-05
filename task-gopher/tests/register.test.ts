import { expect, mock, test } from 'claude-code/testing'

// What says the main loop's agent type: the --agent variable, then the agent setting.
const agentSources = (on: any, { env, setting }: { env?: string; setting?: string } = {}) => {
  on('env.get', () => ({ value: env }))
  on('settings.read', () => ({ value: setting ? { agent: setting } : {} }))
}

// `process.run` stands in for pretooluse-nudge.mjs, whose real decisions tests/test-relay-gate.sh covers. It answers
// a checkpoint once per (prompt_id, tool) for a Grep or a grep Bash, and records every payload the mod feeds it.
const setup = async ($: any, on: any, sessionId: string, agent?: { env?: string; setting?: string }) => {
  const runs: { flag: string; input: any }[] = []
  const seen = new Set<string>()

  agentSources(on, agent)
  on('session.id', () => ({ value: sessionId }))
  on('session.cwd', () => ({ value: '/tmp' }))
  on('agent.list', () => ({ value: [] }))
  on('session.start', (_: unknown, e: { cwd: string }) => ({ cwd: e.cwd }))
  on('turn.start', (_: unknown, e: { turnId: string }) => ({ turnId: e.turnId }))
  on('process.run', (_: unknown, e: { argv: string[]; init?: { stdin?: string } }) => {
    const input = JSON.parse(e.init?.stdin ?? '{}')
    const flag = e.argv[2]
    runs.push({ flag, input })
    let stdout = ''
    const isLookup = input.tool_name === 'Grep' || (input.tool_name === 'Bash' && /grep/.test(input.tool_input?.command ?? '')) ||
      (input.tool_name === 'Agent' && input.tool_input?.subagent_type === 'task-gopher:smart-gopher')
    if (flag === '--mod-checkpoint' && isLookup && !seen.has(`${input.prompt_id}|${input.tool_name}`)) {
      seen.add(`${input.prompt_id}|${input.tool_name}`)
      stdout = JSON.stringify({ checkpoint: 'Could task-gopher do this? Re-run the same call to proceed.' })
    }
    return { value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('tool.call', () => ({ result: { stdout: 'real output', stderr: '', interrupted: false } }))
  await $.session.start({ cwd: '/tmp', surface: 'terminal', isInteractive: true })
  return runs
}

test('Bash: first call is answered NOT RUN, the re-run passes through', async ($, on) => {
  await setup($, on, 'sBash')
  await $.turn.start({ text: 'go', turnId: 't1' })

  const first = await $.tool.call({ tool: 'Bash', command: 'grep foo bar' })
  expect(first.deny).toBeUndefined()
  expect(first.result.stdout).toBe('[task-gopher] NOT RUN. Could task-gopher do this? Re-run the same call to proceed.')
  expect(first.result.interrupted).toBe(false)

  const second = await $.tool.call({ tool: 'Bash', command: 'grep foo bar' })
  expect(second.result.stdout).toBe('real output')
})

test('Bash: a call the script lets through is not answered', async ($, on) => {
  await setup($, on, 'sBashOk')
  await $.turn.start({ text: 'go', turnId: 't1' })

  const ran = await $.tool.call({ tool: 'Bash', command: 'echo hi' })
  expect(ran.result.stdout).toBe('real output')
})

test('Grep: the first call is denied rather than answered, the re-run passes', async ($, on) => {
  await setup($, on, 'sGrep')
  await $.turn.start({ text: 'go', turnId: 't1' })

  const first = await $.tool.call({ tool: 'Grep', pattern: 'x' })
  expect(first.result).toBeUndefined()
  expect(first.deny.startsWith('[task-gopher] NOT RUN. ')).toBe(true)

  const again = await $.tool.call({ tool: 'Grep', pattern: 'x' })
  expect(again.deny).toBeUndefined()
})

test('Agent: a smart-gopher gate answer is denied with the NOT RUN prefix; other agents are left alone', async ($, on) => {
  await setup($, on, 'sAgentGate')
  await $.turn.start({ text: 'go', turnId: 't1' })

  const other = await $.tool.call({ tool: 'Agent', subagent_type: 'general-purpose', prompt: 'x' })
  expect(other.deny).toBeUndefined()

  const gated = await $.tool.call({ tool: 'Agent', subagent_type: 'task-gopher:smart-gopher', prompt: 'x' })
  expect(gated.deny.startsWith('[task-gopher] NOT RUN. ')).toBe(true)
})

test('Read: a script that lets the call through leaves it alone', async ($, on) => {
  await setup($, on, 'sRead')
  await $.turn.start({ text: 'go', turnId: 't1' })

  const read = await $.tool.call({ tool: 'Read', file_path: '/x' })
  expect(read.deny).toBeUndefined()
})

test('the mod feeds the script the turn, session and tool input', async ($, on) => {
  const runs = await setup($, on, 'sFeed')
  await $.turn.start({ text: 'go', turnId: 't9' })
  await $.tool.call({ tool: 'Grep', pattern: 'needle' })

  const call = runs.find(r => r.flag === '--mod-checkpoint')!
  expect(call.input.session_id).toBe('sFeed')
  expect(call.input.prompt_id).toBe('t9')
  expect(call.input.tool_name).toBe('Grep')
  expect(call.input.tool_input).toEqual({ pattern: 'needle' })
  expect(call.input.agent_type).toBeUndefined()
})

test('an --agent main loop sends its agent type; a plain session sends none', async ($, on) => {
  const runs = await setup($, on, 'sAgent', { env: 'task-gopher:task-gopher' })
  await $.turn.start({ text: 'go', turnId: 't1' })
  await $.tool.call({ tool: 'Grep', pattern: 'x' })

  expect(runs.find(r => r.flag === '--mod-checkpoint')!.input.agent_type).toBe('task-gopher:task-gopher')
})

test('the agent setting names the main loop when no --agent did', async ($, on) => {
  const runs = await setup($, on, 'sAgentSetting', { setting: 'ah:reviewer' })
  await $.turn.start({ text: 'go', turnId: 't1' })
  await $.tool.call({ tool: 'Grep', pattern: 'x' })

  expect(runs.find(r => r.flag === '--mod-checkpoint')!.input.agent_type).toBe('ah:reviewer')
})

// `process.run` stands in for the two directive scripts, whose gates tests/test-userpromptsubmit.sh covers. `transcript`
// is what the conversation holds; the test's own prompt.submit hook sits beneath the mod and records what reached it.
const DIRECTIVE = '[task-gopher: ON] PURPOSE: keep tool output out of your context; the rest'
const TICK = '[task-gopher: ON] one line'
const inject = ($: any, on: any, { silent = false, broken = false, transcript = '', env = undefined as string | undefined } = {}) => {
  const seen: { context?: readonly string[]; inputs: any[] } = { inputs: [] }
  agentSources(on, { env })
  on('session.messages', () => ({ value: [{ role: 'user', content: transcript }] }))
  on('process.run', (_: unknown, e: { argv: string[]; init?: { stdin?: string } }) => {
    seen.inputs.push(JSON.parse(e.init?.stdin ?? '{}'))
    const additionalContext = e.argv[1].endsWith('sessionstart.mjs') ? DIRECTIVE : TICK
    const stdout = broken ? 'not json' : silent ? '' : JSON.stringify({ hookSpecificOutput: { additionalContext } })
    return { value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('prompt.submit', (_: unknown, e: { text: string; context?: readonly string[] }) => {
    seen.context = e.context
    return { text: e.text }
  })
  return seen
}

test('a conversation without the directive gets it, ahead of the reminder', async ($, on) => {
  const seen = inject($, on)
  await $.prompt.submit({ text: 'go' })
  expect(seen.context).toEqual([DIRECTIVE, TICK])
})

test('a conversation holding the directive gets the reminder alone', async ($, on) => {
  const seen = inject($, on, { transcript: `<system-reminder>${DIRECTIVE}</system-reminder>` })
  await $.prompt.submit({ text: 'go' })
  expect(seen.context).toEqual([TICK])
})

test('a conversation holding only the reminder still gets the directive', async ($, on) => {
  const seen = inject($, on, { transcript: `<system-reminder>${TICK}</system-reminder>` })
  await $.prompt.submit({ text: 'go' })
  expect(seen.context).toEqual([DIRECTIVE, TICK])
})

test('scripts that stay silent (OFF, a gopher, a role) add nothing', async ($, on) => {
  const seen = inject($, on, { silent: true })
  await $.prompt.submit({ text: 'go' })
  expect(seen.context).toBeUndefined()
})

test('the scripts are told the main loop agent type', async ($, on) => {
  const seen = inject($, on, { silent: true, env: 'ah:architect' })
  await $.prompt.submit({ text: 'go' })
  expect(seen.inputs.map(i => i.agent_type)).toEqual(['ah:architect', 'ah:architect'])
})

test('a script that fails never blocks the prompt', async ($, on) => {
  const seen = inject($, on, { broken: true })
  await $.prompt.submit({ text: 'go' })
  expect(seen.context).toBeUndefined()
})

// Two main-loop requests, `counts` messages each; what the mod appended as rows of its own.
const steps = async ($: any, on: any, counts: number[], { transcript = '', agentId = undefined as string | undefined, silent = false } = {}) => {
  const rows = mock.session(on)
  inject($, on, { transcript, silent })
  on('turn.step', async function* (_: unknown, e: { turnId: string; index: number }) {
    return { turnId: e.turnId, index: e.index, answer: '', toolUses: [], stopReason: 'end_turn', usage: null, id: 'r' }
  })
  for (const [index, messageCount] of counts.entries()) {
    for await (const _ of $.turn.step({ turnId: 't1', index, model: 'm', messageCount, ...(agentId && { agentId }) })) {
      // no chunks
    }
  }
  return rows.appended().filter((r: any) => JSON.stringify(r.message).includes('PURPOSE'))
}

test('a request after a compaction (fewer messages) gets the directive as a row', async ($, on) => {
  expect((await steps($, on, [40, 3])).length).toBe(1)
})

test('after a compaction, a conversation that already holds the directive gets no second copy', async ($, on) => {
  expect((await steps($, on, [40, 3], { transcript: `<system-reminder>${DIRECTIVE}</system-reminder>` })).length).toBe(0)
})

test('after a compaction, scripts that stay silent (OFF, a gopher, a role) add nothing', async ($, on) => {
  expect((await steps($, on, [40, 3], { silent: true })).length).toBe(0)
})

test('a request that carries as many messages or more is left alone', async ($, on) => {
  expect((await steps($, on, [3, 3, 5])).length).toBe(0)
})

test('a subagent request that shrinks is left alone', async ($, on) => {
  expect((await steps($, on, [40, 3], { agentId: 'a1' })).length).toBe(0)
})
