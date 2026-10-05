import type { Register } from 'claude-code'
import { bandLine, paneRows, parseDoc, SIZE_CAP, statusText, viewModel, type Doc } from './view.ts'

// The one table from a tone to Text props. Only `warning` is a documented theme key, so bold tells bad from warn;
// any tone not named here draws dim.
const toneProps = (tone: string) =>
  tone === 'bad' ? { color: 'warning', bold: true } : tone === 'warn' ? { color: 'warning' } : tone === 'work' ? {} : { dimColor: true }

export const register: Register = (on, options) => {
  // Only an explicit false turns the entry off; a missing option counts as on.
  const statusEntry = options?.status_entry !== false

  on('session.start', async ($, e, next) => {
    let cwd: string | undefined
    let file: string | null = null
    let seenMtime: number | undefined
    let doc: Doc | null = null
    // null until the first tick, so a fresh environment always sets the entry, clearing any left by the last one.
    let shown: string | undefined | null = null

    // The status file of the git checkout holding `dir`: the first ancestor with a `.git` entry, the way
    // ah's writer finds it. ponytail: AGENT_HIERARCHY_DIR and ah's non-git fallback dir are not followed.
    const locate = async (dir: string): Promise<string | null> => {
      const sep = dir.includes('/') || !dir.includes('\\') ? '/' : '\\'
      const join = (a: string, b: string) => (a.endsWith(sep) ? a + b : a + sep + b)
      for (let d = dir; ; ) {
        if (await $.fs.exists(join(d, '.git'))) return join(join(join(d, '.claude'), 'hierarchy'), 'status.json')
        const cut = d.lastIndexOf(sep)
        const parent = cut > 0 ? d.slice(0, cut) : cut === 0 && d.length > 1 ? sep : d
        if (parent === d) return null
        d = parent
      }
    }

    const tick = async () => {
      try {
        const where = await $.session.cwd()
        if (where !== cwd) { cwd = where; file = await locate(where); seenMtime = undefined; doc = null }
        if (file === null) doc = null
        else {
          const st = await $.fs.stat(file)
          if (st.kind !== 'file' || st.size > SIZE_CAP) { doc = null; seenMtime = undefined }
          else if (st.mtimeMs !== seenMtime) { seenMtime = st.mtimeMs; doc = parseDoc(await $.fs.read(file)) }
        }
      } catch {
        doc = null
        seenMtime = undefined
      }
      // The id is read every tick: /clear keeps this environment but starts a new session.
      const now = await $.clock.now()
      const id = await $.session.id()
      // Written only on change, since every write redraws the band and the Pane. Compared with the held value,
      // not a closure copy, because the state outlives a reload of this module.
      const view = viewModel(doc, now, id)
      const held = await $.state.get({ plugin: 'ah', key: 'view' })
      if (JSON.stringify(held.value) !== JSON.stringify(view)) await $.state.set({ plugin: 'ah', key: 'view' }, view)
      const text = statusText(doc, now, id, statusEntry)
      if (text !== shown) { shown = text; $.ui.status(text) }
    }

    await tick()
    $.clock.every(2000, () => tick())
    return next(e)
  })

  // The band goes above whatever the rest of the chain draws there, never in its place, and yields to a survey.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey) return next(e)
    const { value } = await $.state.get({ plugin: 'ah', key: 'view' })
    const line = bandLine(value ?? null, e.props.bodyColumns)
    if (line === null) return next(e)
    const { Box, Text } = $.ui.resolve(e)
    return (
      <Box flexDirection="column">
        <Text {...toneProps(line.tone)}>{line.text}</Text>
        {await next(e)}
      </Box>
    )
  })

  on('ui.render', { component: 'Pane', requestId: 'ah-status' }, async ($, e) => {
    const { value } = await $.state.get({ plugin: 'ah', key: 'view' })
    const { Box, Text } = $.ui.resolve(e)
    return (
      <Box flexDirection="column">
        {paneRows(value ?? null, e.props.bodyColumns).map((r) => <Text {...toneProps(r.tone)}>{r.text}</Text>)}
      </Box>
    )
  })
}
