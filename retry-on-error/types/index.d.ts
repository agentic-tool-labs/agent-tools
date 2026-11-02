export type RetryLast = { kind: string; details?: string; at: number; turnId?: string }

declare module 'claude-code' {
  interface PluginState {
    'retry-on-error': {
      attempts: number
      disabled: boolean
      last: RetryLast
      nudged: boolean
      stalled: boolean
    }
  }
}
