import { expect, test } from 'claude-code/testing'

// `process.run` stands in for guard.mjs, whose real decisions guard.test.sh covers. It nudges the first gh Bash call
// or toolkit MCP call per session and records every payload the mod feeds it.
const setup = async ($: any, on: any, sessionId: string) => {
  const runs: { argv: string[]; input: any }[] = []
  let spent = false

  on('session.id', () => ({ value: sessionId }))
  on('session.cwd', () => ({ value: '/tmp' }))
  on('session.start', (_: unknown, e: { cwd: string }) => ({ cwd: e.cwd }))
  on('process.run', (_: unknown, e: { argv: string[]; init?: { stdin?: string } }) => {
    const input = JSON.parse(e.init?.stdin ?? '{}')
    runs.push({ argv: e.argv, input })
    const isGh = input.tool_name.startsWith('mcp__') || /^gh /.test(input.tool_input?.command ?? '')
    let stdout = ''
    if (isGh && !spent) {
      spent = true
      stdout = JSON.stringify({ nudge: 'Use the worker. Re-run unchanged to proceed.' })
    }
    return { value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('tool.call', () => ({ result: { stdout: 'real output', stderr: '', interrupted: false } }))
  await $.session.start({ cwd: '/tmp', surface: 'terminal', isInteractive: true })
  return runs
}

test('Bash gh: the first call is answered NOT RUN, the re-run passes through', { options: { github_pat: 'unused' } }, async ($, on) => {
  await setup($, on, 'sGh')

  const first = await $.tool.call({ tool: 'Bash', command: 'gh pr view 5' })
  expect(first.deny).toBeUndefined()
  expect(first.result.stdout).toBe('[github-pr-toolkit] NOT RUN. Use the worker. Re-run unchanged to proceed.')

  const second = await $.tool.call({ tool: 'Bash', command: 'gh pr view 5' })
  expect(second.result.stdout).toBe('real output')
})

test('a toolkit MCP call is denied rather than answered', { options: { github_pat: 'unused' } }, async ($, on) => {
  await setup($, on, 'sMcp')

  const first = await $.tool.call({ tool: 'mcp__plugin_github-pr-toolkit_github__list_pull_requests' })
  expect(first.result).toBeUndefined()
  expect(first.deny.startsWith('[github-pr-toolkit] NOT RUN. ')).toBe(true)
})

test('a tool outside the covered set never reaches the script', { options: { github_pat: 'unused' } }, async ($, on) => {
  const runs = await setup($, on, 'sOther')

  const read = await $.tool.call({ tool: 'Read', file_path: '/x' })
  expect(read.result.stdout).toBe('real output')
  expect(runs.length).toBe(0)
})

test('the mod feeds the script the session, cwd and tool input', { options: { github_pat: 'unused' } }, async ($, on) => {
  const runs = await setup($, on, 'sFeed')
  await $.tool.call({ tool: 'Bash', command: 'gh api x' })

  const call = runs[0]
  expect(call.argv[2]).toBe('--mod-nudge')
  expect(call.input.session_id).toBe('sFeed')
  expect(call.input.cwd).toBe('/tmp')
  expect(call.input.tool_name).toBe('Bash')
  expect(call.input.tool_input).toEqual({ command: 'gh api x' })
})
