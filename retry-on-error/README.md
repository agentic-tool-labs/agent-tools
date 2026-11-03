# retry-on-error

Resumes a Claude Code session when a turn dies on a transient API failure.

Claude Code already retries API requests internally. When those retries run out, the turn ends on an error ("API Error: Connection lost mid-response", `server_error`, `overloaded`) and the session sits idle until someone types. This mod waits a few seconds, then submits a short "continue" prompt for you, so long unattended runs keep going.

It is a function-hooks mod (Claude Code 2.1.310 or newer).

## Install

```
/plugin install retry-on-error@agent-tools
```

## What it does

- **Retries** `server_error`, `overloaded` and `rate_limit`, and `unknown` errors whose text looks transient (connection lost, mid-response, ECONNRESET, socket hang up, stream closed/ended, timeout, a 5xx code).
- **Never retries** errors that will not clear by themselves: authentication, billing, account, credential, invalid request, missing model. It shows a toast naming the error instead. `max_output_tokens` is not retried unless you turn on `retryMaxOutput`.
- **Backs off**: 5 s, 10 s, 20 s (doubling, capped at 60 s; at least 30 s for `rate_limit`). After 3 consecutive auto-retries it gives up, says so in the status line and a toast, and sends one desktop/phone notification.
- **You always win**: typing anything cancels a pending retry and resets the count. Pressing Esc (an aborted turn) cancels it too. A turn that ends with an answer resets the count.
- **Stays in its lane**: acts only in the top-level, interactive session. Subagents, `claude -p` and SDK runs are left alone (unless `headless` is on).
- While a retry is pending the status line reads `retrying in 5s — attempt 1/3 (server_error)`. Otherwise the mod shows nothing.

### Stalled requests

Sometimes the connection stalls mid-request: Claude Code shows "Waiting for API response · will retry in 1m 30s · check your network" and the turn stays open, so no turn-end error ever arrives. The stall watchdog covers that case:

- While the main session has a model request open, the mod watches its response stream. "Stalled" means the stream has been silent: no text, thinking or tool-call chunk has arrived. The engine's own retry markers do not count as progress.
- After 30 s of silence (`stallNoticeMs`) the status line reads `API stalled 30s — auto-retry at 5:00 (Esc/type to cancel)`. It clears if the stream resumes.
- After 5 min of silence (`stallAbortMs`) the mod aborts the running turn and submits the nudge with the kind `stalled`. This counts against the same attempts budget and backoff as an error retry, and gives up the same way. Out of budget, it does not abort: the request is left to Claude Code's own retries.
- You still win: typing anything, pressing Esc, or the turn ending for any reason clears the watchdog. The watchdog's own abort neither cancels its resume nor arms a second retry.
- Subagent requests are never watched, and headless sessions only with `headless` on. `stallWatchdog: false` turns the watchdog off.

The nudge it submits:

> The previous turn ended on an API error (server_error). Continue the task from where it stopped; re-check any step with side effects before repeating it.

The second sentence matters: a cut stream may have run a tool call whose result was never shown.

## Command

`/retry-on-error off` turns it off for this session, `/retry-on-error on` turns it back on, and `/retry-on-error status` (or no argument) shows whether it is on, the attempts used, and the last error kind and time.

## Options

Set them in `/config`, or under `pluginConfigs["retry-on-error"].options` in settings.

| Option | Default | Meaning |
|---|---|---|
| `enabled` | `true` | Global switch |
| `maxAttempts` | `3` | Consecutive auto-retries before giving up |
| `baseDelayMs` | `5000` | First delay; doubles each retry |
| `maxDelayMs` | `60000` | Backoff cap |
| `rateLimitDelayMs` | `30000` | Minimum delay after `rate_limit` |
| `nudgeText` | see above | The prompt submitted; `<kind>` is replaced with the error kind |
| `retryMaxOutput` | `false` | Also continue after `max_output_tokens` |
| `headless` | `false` | Also act in `claude -p` and SDK sessions |
| `notifyOnGiveUp` | `true` | Native notification when the retry budget runs out |
| `stallWatchdog` | `true` | Abort and resume a request whose stream has gone silent |
| `stallNoticeMs` | `30000` | Silence before the status line reports a stall |
| `stallAbortMs` | `300000` | Silence before the stalled request is aborted and resumed |

## Limits

- Where an organization manages Claude Code, `classic.*` hooks pass over plugins you install, so `StopFailure` never arrives and `/plugins` lists it as not running. The mod then hears only that the turn ended on an error, not why, and retries every failure under the kind `api_error`, within `maxAttempts`. That means no 30 s rate-limit wait, and up to `maxAttempts` futile nudges on an error that will not clear, such as a billing or authentication failure.
- The error kind comes from `StopFailure`, which carries no HTTP status, only an error kind and free text. The turn's end carries neither.
- There is no event for "Waiting for API response" or for Claude Code's own internal retries, and no way to tune those. A mod cannot see the engine's retry countdown or state, so the watchdog infers a stall from stream silence alone, measured to about a second. A response that is legitimately silent for longer than `stallAbortMs` (for example a long server-side tool call, which streams only engine chunks) would be aborted and resumed too; raise `stallAbortMs` if that bites.
- Whether "Connection lost mid-response" arrives in the error details or the last assistant message is not documented, so the mod checks both.
- The order of the two signals for a failed turn (`StopFailure` and the turn's end) is not guaranteed. One failure gives one retry either way. If the turn's end arrives first, the mod waits 2 s for `StopFailure` before retrying under `api_error`, and a `StopFailure` later than that still replaces the pending retry's kind and delay, or calls it off.
- A mod reload while a retry is pending drops that retry; the status line clears, so you can see it happened.
- With the agent-hierarchy (`ah`) plugin also installed, this mod resumes first (seconds); ah's slower mail-based resume then finds the session already recovered.
