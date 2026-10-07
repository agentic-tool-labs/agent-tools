import type { Register } from 'claude-code'
import { bandLine, keepSeen, nullCause, PANE_BUTTON, paneSections, parseDoc, SIZE_CAP, scope, statusText, toastMs, viewModel, type Doc } from './view.ts'

// The one table from a tone to Text props. Only `warning` is a documented theme key, so bold tells bad from warn;
// any tone not named here draws dim.
const toneProps = (tone: string) =>
  tone === 'bad' ? { color: 'warning', bold: true } : tone === 'warn' ? { color: 'warning' } : tone === 'work' ? {} : { dimColor: true }

// A theme key colors; no key draws dim. Every key comes from view.ts's style table.
const colorProps = (key: string | null) => (key === null ? { dimColor: true } : { color: key })

// The one process the mod may run, on a person's press: focus a member's terminal pane. The guard (tests/test-mod-readonly.sh)
// holds this text whole and allows `process` nowhere else in mod/.
export const focusMember = async ($: any, name: unknown): Promise<boolean> => {
  if (typeof name !== 'string' || !/^[a-z][a-z0-9_-]{0,31}$/.test(name)) {
    await $.ui.toast('Could not focus that member.')
    return false
  }
  try {
    const run = await $.process.run(['herdr', 'agent', 'focus', name], { timeoutMs: 5000 })
    if (run.exitCode === 0) return true
  } catch {
  }
  await $.ui.toast(`Could not focus ${name}.`)
  return false
}

// The one way the Pane opens on the person's request, for the command and the band's button. A member session
// sees no hierarchy view, so nothing is opened there.
const openPane = async ($: any, member: boolean) => {
  if (member) return { text: 'The hierarchy view is hidden in member sessions.', placed: false }
  await $.state.set({ plugin: 'ah', key: 'closed' }, false)
  const opened = await $.ui.open({ id: 'ah-status', title: 'Hierarchy' })
  return opened.isPlaced
    ? { text: 'Opened the hierarchy Pane.', placed: true }
    : { text: 'The hierarchy Pane is open, but this session shows no panes.', placed: false }
}

export const register: Register = (on, options) => {
  // Only an explicit true turns the entry on; a missing or any other value counts as off.
  const statusEntry = options?.status_entry === true || options?.status_entry === 'true'
  // How long the status toasts and the band notice stay, from one read of the option; 0 makes no toast at all.
  const toastFor = toastMs(options?.toast_seconds)
  // Whether the last doc read lists this session, set by every tick. Nothing is drawn from it, and a reload
  // runs session.start again, whose first tick sets it before any command can arrive.
  let member = false

  on('session.start', async ($, e, next) => {
    let cwd: string | undefined
    let file: string | null = null
    let seenMtime: number | undefined
    let doc: Doc | null = null
    // Why `doc` is null: `no file` or `unreadable`. Held with the doc, which is re-read only when the file changes.
    let lost = 'no file'
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
        if (file === null) { doc = null; lost = 'no file' }
        else {
          let st: any = null
          try { st = await $.fs.stat(file) } catch { doc = null; seenMtime = undefined; lost = 'no file' }
          if (st !== null) {
            // ponytail: stat then read by path; a live local process could swap the path between the two calls. A committed file cannot race, and read's own cap bounds a swapped file. Close it if $.fs gains a handle or no-follow read.
            if (st.isLink || st.kind !== 'file' || st.size === 0 || st.size > SIZE_CAP) { doc = null; seenMtime = undefined; lost = 'unreadable' }
            else if (st.mtimeMs !== seenMtime) { seenMtime = st.mtimeMs; doc = parseDoc(await $.fs.read(file)); lost = 'unreadable' }
          }
        }
      } catch {
        doc = null
        seenMtime = undefined
        lost = 'unreadable'
      }
      // The id is read every tick: /clear keeps this environment but starts a new session.
      const now = await $.clock.now()
      const id = await $.session.id()
      // Expiry and visibility do not matter here, only that a shape-valid doc lists this session.
      member = doc !== null && doc.memberSessions.includes(id)
      // Written only on change, since every write redraws the band and the Pane. Compared with the held value,
      // not a closure copy, because the state outlives a reload of this module.
      const view = viewModel(doc, now, id)
      // The cause is written before the view, so the empty Pane already names it when the view changes to null.
      const why = view === null ? (doc === null ? lost : nullCause(doc, now, id)) : null
      const heldWhy = await $.state.get({ plugin: 'ah', key: 'why' })
      if ((heldWhy.value ?? null) !== why) await $.state.set({ plugin: 'ah', key: 'why' }, why)
      const held = await $.state.get({ plugin: 'ah', key: 'view' })
      if (JSON.stringify(held.value) !== JSON.stringify(view)) await $.state.set({ plugin: 'ah', key: 'view' }, view)
      const text = statusText(doc, now, id, statusEntry)
      if (text !== shown) { shown = text; $.ui.status(text) }
      // Each toast key shows at most once per session. The first view a session sees only seeds the set, so old
      // events are not replayed. Nothing changes on a tick with no view: an unreadable or expired file for one
      // tick must not empty the set and replay everything when the file comes back.
      const mine = scope(doc, id)
      if (view !== null && mine !== null) {
        const held = await $.state.get({ plugin: 'ah', key: 'seen' })
        if (held.value === undefined) await $.state.set({ plugin: 'ah', key: 'seen' }, view.toasts.map((t) => t.key))
        else {
          const kept = keepSeen(held.value, mine, now)
          const fresh = view.toasts.filter((t) => !kept.includes(t.key))
          const seen = [...kept, ...fresh.map((t) => t.key)]
          // Written before toasting, so a toast that fails is not shown again.
          if (JSON.stringify(seen) !== JSON.stringify(held.value)) await $.state.set({ plugin: 'ah', key: 'seen' }, seen)
          if (toastFor > 0) for (const t of fresh) await $.ui.toast(t.text, { timeoutMs: toastFor })
        }
      }
      // Opened unasked once per session, the first time there is something to show, unless the person has
      // closed it. Below the engine's width floor the open waits undrawn; that still counts as opened.
      if (view !== null) {
        const opened = await $.state.get({ plugin: 'ah', key: 'opened' })
        const closed = await $.state.get({ plugin: 'ah', key: 'closed' })
        if (opened.value !== true && closed.value !== true) {
          await $.state.set({ plugin: 'ah', key: 'opened' }, true)
          await $.ui.open({ id: 'ah-status', title: 'Hierarchy' })
        }
      }
    }

    await $.command.register({ name: 'hierarchy-pane', description: 'Open the hierarchy status Pane' })
    await tick()
    $.clock.every(2000, () => tick())
    return next(e)
  })

  // The band goes above whatever the rest of the chain draws there, never in its place, and yields to a survey.
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    if (e.props.hasSurvey) return next(e)
    const { value } = await $.state.get({ plugin: 'ah', key: 'view' })
    const wide = e.props.bodyColumns >= PANE_BUTTON.minColumns
    const line = bandLine(value ?? null, wide ? e.props.bodyColumns - PANE_BUTTON.width - PANE_BUTTON.gap : e.props.bodyColumns)
    if (line === null) return next(e)
    const { Box, Button, Text } = $.ui.resolve(e)
    return (
      <Box flexDirection="column">
        {wide ? (
          <Box flexDirection="row">
            <Text {...toneProps(line.tone)}>{line.text}</Text>
            <Box marginLeft={PANE_BUTTON.gap}>
              <Button
                key="ah-pane"
                label={PANE_BUTTON.label}
                onPress={async () => {
                  try {
                    const up = (await $.ui.panes()).some((pane: { id: string; isPlaced: boolean }) => pane.id === 'ah-status' && pane.isPlaced)
                    if (up) {
                      await $.state.set({ plugin: 'ah', key: 'closed' }, true)
                      await $.ui.close({ id: 'ah-status' })
                      return
                    }
                    const r = await openPane($, member)
                    if (!r.placed && !member && toastFor > 0) await $.ui.toast(r.text, { timeoutMs: toastFor })
                  } catch {}
                }}
              />
            </Box>
          </Box>
        ) : (
          <Text {...toneProps(line.tone)}>{line.text}</Text>
        )}
        {await next(e)}
      </Box>
    )
  })

  // Asked for, so the engine places it at any width; not placed means this session's surfaces show no panes.
  // Answers with text alone and never runs another command. A member session sees no hierarchy view at all.
  on('command.run', { command: 'hierarchy-pane' }, async ($) => {
    return { text: (await openPane($, member)).text }
  })

  // A close by the person keeps the Pane closed for the session. Always passes the close on: answering without
  // next would keep the Pane open.
  on('ui.close', { id: 'ah-status' }, async ($, e, next) => {
    if (e.origin.kind === 'person') await $.state.set({ plugin: 'ah', key: 'closed' }, true)
    return next(e)
  })

  on('ui.render', { component: 'Pane', requestId: 'ah-status' }, async ($, e) => {
    const { value } = await $.state.get({ plugin: 'ah', key: 'view' })
    const cause = await $.state.get({ plugin: 'ah', key: 'why' })
    const { Box, Button, Text } = $.ui.resolve(e)
    const sections = paneSections(value ?? null, e.props.bodyColumns, typeof cause.value === 'string' ? cause.value : null)
    return (
      <Box flexDirection="column">
        {sections.map((sec) => (
          <Box key={sec.key} flexDirection="column" {...(sec.bordered ? { borderStyle: 'round', ...(sec.color === null ? { borderDimColor: true } : { borderColor: sec.color }) } : {})}>
            {sec.title !== '' ? <Text bold {...colorProps(sec.color)}>{sec.title}</Text> : null}
            {sec.rows.map(({ indent, icon, iconColor, focus, tone, text }) => (
              <Box flexDirection="row">
                {indent > 0 ? <Text>{' '.repeat(indent)}</Text> : null}
                {icon !== null ? <Text {...colorProps(iconColor)}>{icon + ' '}</Text> : null}
                {focus !== null ? <Box key={'ah-focus-' + focus}><Button key={'ah-name-' + focus} plain label={focus} dimColor={tone === 'idle'} hover={{ underline: true }} onPress={() => focusMember($, focus)} /></Box> : null}
                <Text {...toneProps(tone)}>{text}</Text>
              </Box>
            ))}
          </Box>
        ))}
      </Box>
    )
  })
}
