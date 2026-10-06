/** A severity the drawing layer names; the module turns it into Text props in one table. */
export type Tone = 'bad' | 'warn' | 'work' | 'idle'

/** One Pane row as data: a heading or line of text, a team member, or a dispatch. Widths are applied when drawing. */
export type PaneRow =
  | { row: 'text'; tone: Tone; text: string }
  | { row: 'member'; tone: Tone; name: string; kind: string; route: string; state: string; base: string; icon: string; iconColor: string | null; focus: boolean }
  | { row: 'dispatch'; tone: Tone; slug: string; label: string; eta: string | null; pct: number | null; elapsed: string; state: string; icon: string; iconColor: string | null }

/** One team as data, for the sectioned Pane: its pipeline rows (null when it has no pipeline), its members with their stream ('' for none), and its dispatches with the member each went to. */
export type TeamModel = {
  name: string
  pipeline: PaneRow[] | null
  members: { stream: string; row: PaneRow }[]
  dispatches: { member: string; row: PaneRow }[]
}

/**
 * What the band, the Pane and the toasts show at one instant, with nothing that depends on width. The band's
 * line is `head`, then each `tail` item while it fits.
 */
export type View = {
  band: { tone: Tone; head: string; tail: string[] } | null
  pane: PaneRow[]
  teams: TeamModel[]
  toasts: { key: string; text: string }[]
}

declare module 'claude-code' {
  interface PluginState {
    ah: {
      /** The current view; null whenever nothing should show (no document, expired, invisible, member session). */
      view: View | null
      /** Why `view` is null, named in the empty Pane's line; null while there is a view. */
      why: string | null
      /** Toast keys already shown this session; never written means not yet seeded. */
      seen: string[]
      /** Auto-open has fired this session. */
      opened: boolean
      /** The person closed the Pane this session; /hierarchy-pane clears it. */
      closed: boolean
    }
  }
}
