import { expect, test } from 'claude-code/testing'

// `process.run` stands in for pretooluse-nudge.mjs, whose real decisions tests/test-relay-gate.sh covers. It answers
// a checkpoint once per (prompt_id, tool) for a Grep or a grep Bash, and records every payload the mod feeds it.
const setup = async ($: any, on: any, sessionId: string) => {
  const runs: { flag: string; input: any }[] = []
  const seen = new Set<string>()

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
  on('classic.SessionStart', () => ({}))
  const runs = await setup($, on, 'sAgent')
  await $.classic.SessionStart({ source: 'startup', agent_type: 'task-gopher:task-gopher' })
  await $.turn.start({ text: 'go', turnId: 't1' })
  await $.tool.call({ tool: 'Grep', pattern: 'x' })

  expect(runs.find(r => r.flag === '--mod-checkpoint')!.input.agent_type).toBe('task-gopher:task-gopher')
})
