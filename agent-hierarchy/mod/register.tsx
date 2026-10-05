import type { Register } from 'claude-code'
import { parseDoc, SIZE_CAP, statusText, type Doc } from './view.ts'

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
      const text = statusText(doc, await $.clock.now(), await $.session.id(), statusEntry)
      if (text !== shown) { shown = text; $.ui.status(text) }
    }

    await tick()
    $.clock.every(2000, () => tick())
    return next(e)
  })
}
