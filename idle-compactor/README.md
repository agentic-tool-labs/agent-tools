# idle-compactor

Runs `/compact` for you when a session has been sitting idle, timed to land
just before Anthropic's prompt cache expires. You can attach your own focus
instructions to it. There's also a keepalive mode that pings the cache instead
of compacting, for when you'd rather keep your local context exactly as it is.

## Why the timing matters

Anthropic's prompt cache has two lifetimes: 5 minutes (the default,
`cache_control: {"type": "ephemeral"}`) and 1 hour (`"ttl": "1h"`). While a
session's cached prefix is alive, re-sending it costs about 0.1× the base input
price. Once it expires, the next turn pays for a full cache write: 1.25× on the
5-minute cache, 2× on the 1-hour one.

So the useful moment to compact is a few minutes before the cache dies. That's
late enough that if you come straight back you still land on a warm cache, and
early enough that the compaction request itself reads the warm prefix instead
of paying to write the whole thing again.

The defaults follow from that: 55 minutes for the 1-hour cache, 4 minutes for
the 5-minute one. The plugin asks which you use the first time it runs.

## How it works, and the catch

Claude Code's hooks can't start a compaction. There's no idle or timer hook, no
hook output that submits a turn or runs a slash command, and `PreCompact` can
only block a compaction that's already under way.

So the plugin does the one thing that does work: it types `/compact` into your
terminal for you.

```
turn ends ──▶ Stop hook (arm.js)
                 ├─ context below the token floor?  →  do nothing
                 └─ spawn a detached timer process, recording an armId
you type  ──▶ UserPromptSubmit hook (disarm.js)  →  kill timer, delete state
idle      ──▶ timer.js wakes, re-verifies the armId and that the transcript
              has not been touched, then types "/compact" + Enter into the
              pane this session is running in
```

That means the plugin needs a way to send keystrokes to your terminal. By
default it only uses methods that can pick out your specific pane or tab.
Methods that type into whichever window has focus are off unless you turn them
on (see [Blind injection](#blind-injection)).

## Requirements

You need Node.js 18 or newer on your `PATH`. Claude Code's npm install brings
its own Node, but the native installer doesn't, so check this. If `node` is
missing the hooks fail harmlessly and the plugin just never fires;
`/idle-compact doctor` will tell you.

You also need a supported terminal (see [Terminal support](#terminal-support)).

## Install

```
/plugin marketplace add agentic-tool-labs/agent-tools
/plugin install idle-compactor@agent-tools
```

In the first session after installing, the plugin asks you two things: the idle
threshold, and the smallest context worth compacting. Run `/idle-compact setup`
whenever you want to change those answers.

It works fine on its own. The two other compaction plugins in this repo,
[compaction-capture](../compaction-capture/README.md) and
[compaction-guard](../compaction-guard/README.md), are separate installs.

## Usage

```
/idle-compact                 show current settings and armed timers
/idle-compact on              enable
/idle-compact off             disable and cancel every pending timer
/idle-compact 1h              use the 1-hour cache TTL  → 55 minutes
/idle-compact 5m              use the 5-minute cache TTL →  4 minutes
/idle-compact 25              use an explicit 25-minute threshold
/idle-compact min-tokens 40000   only compact above this context size
/idle-compact min-tokens 0       no floor; compact whenever idle
/idle-compact keepalive       ping the cache instead of compacting (see below)
/idle-compact compact         switch back to the default /compact mode
/idle-compact max-pings 12    stop keepalive after this many pings (default 12)
/idle-compact blind on|off    allow or block focus-based injection
/idle-compact prompt          set the focus instructions sent with /compact
/idle-compact prompt show     what would be sent, and from which file
/idle-compact prompt clear    stop sending one
/idle-compact test            show which injection method would be used
/idle-compact test send       actually type a harmless command, end to end
/idle-compact stats           how many times it has autocompacted, per session and total
/idle-compact stats sessions  live view: every session's idle state and time to compact
/idle-compact stats reset     clear the fire history
/idle-compact doctor          full diagnostics
/idle-compact paths           absolute node and plugin paths
/idle-compact reset           restore defaults
/idle-compact setup           re-run the first-run configuration
```

## Terminal support

| Terminal | Method | Targeted? | Notes |
|---|---|---|---|
| herdr | `herdr pane run $HERDR_PANE_ID` | yes | |
| tmux | `send-keys -t $TMUX_PANE` | yes | |
| GNU screen | `-X stuff` | yes | |
| WezTerm | `wezterm cli send-text --pane-id` | yes | |
| kitty | `kitty @ send-text --match id:` | yes | needs `allow_remote_control yes` |
| iTerm2 | AppleScript, matched on `ITERM_SESSION_ID` | yes | |
| Apple Terminal | AppleScript, matched on the tab's tty | yes | |
| X11 | `xdotool --window $WINDOWID` | yes | only when `WINDOWID` is set |
| X11 | `xdotool` to the active window | **no** | opt-in |
| Wayland | `ydotool` | **no** | opt-in, needs `ydotoold` |
| Windows | `WriteConsoleInput` on the session's own console | yes | Windows Terminal, conhost, VS Code |
| Windows | PowerShell `AppActivate` + `SendKeys` | **no** | opt-in, fallback |

The plugin tries these in order and uses the first one that works. If your
terminal isn't listed and you're not in tmux, it detects nothing and stays
dormant. Running Claude Code inside tmux is the most portable fix.

macOS asks for Automation permission the first time one of the AppleScript
methods runs.

On Windows, the first method attaches to the console Claude Code itself is
running in and writes the keystrokes into that console's input buffer. It
doesn't care which window has focus, and it hits the right tab even when
Windows Terminal has a dozen open. `SendKeys` sits behind it as an opt-in
fallback for hosts where attaching fails.

### Blind injection

`xdotool` without `WINDOWID`, `ydotool`, and Windows `SendKeys` all type into
whatever window has focus. If you've alt-tabbed away, `/compact` gets typed
into that other application. That's why they're off by default. To allow them:

```
/idle-compact blind on
```

Only turn this on if you're fine with that trade-off. On Windows you'll rarely
get this far, because console injection is tried first and doesn't depend on
focus.

## Compaction prompt

`/compact` takes optional focus instructions, and the plugin can attach yours
to every idle compaction, so it types `/compact <your text>` instead of a bare
`/compact`.

```
/idle-compact prompt        walk through writing one and choosing where it lives
/idle-compact prompt show   what would be sent, and from which file
/idle-compact prompt clear  stop sending one
```

The wizard saves your text to a file and remembers the path. You can put it in
the repo at `.claude/compaction-prompt.md` (so it can be committed and shared),
at the user level in `~/.claude/compaction-prompt.md` (used by every repo that
doesn't have its own), or at any path you name. A repo prompt wins over the
user-level one.

Two things to know. It only applies to compactions this plugin fires; a
`/compact` you type yourself isn't touched. And newlines get flattened to
spaces, because the text is typed as a single terminal line and an embedded
newline would submit the command early and leave the rest as a stray prompt.
Anything past 800 characters is dropped, and `prompt show` tells you when that
happens.

## Keepalive mode

Compacting is the default, but sometimes you want the opposite: keep your
local conversation exactly as it is, and just stop the server-side prompt
cache from going cold while you're away. `/idle-compact keepalive` switches to
that.

Instead of typing `/compact`, the plugin sends the idle session a short
do-nothing message on the same schedule. Claude's reply refreshes the cache
without summarizing anything away. This only pays off on the 1-hour cache.
Pinging a 5-minute cache costs more than it saves over the hour, so keepalive
won't turn itself on under `ttl 5m`.

```
/idle-compact keepalive         switch to keepalive mode
/idle-compact compact           switch back to the default /compact mode
/idle-compact max-pings 12      stop after this many pings (default 12, about 11h)
```

Each ping is classed as a cache hit or miss from the usage block of Claude's
reply, and the running hit rate shows up in `/idle-compact doctor`. If a ping
can't be typed at all (no terminal method available, or the method errored),
the loop just stops rather than retrying blind. Nothing was typed, so nothing
was spent, and it won't try again until you come back and a new turn re-arms
it.

## Safety checks

A compaction only fires when all of these are true:

1. The plugin is enabled.
2. The context is at least `min-tokens`, measured from the last `usage` block
   in the transcript as
   `input_tokens + cache_creation_input_tokens + cache_read_input_tokens`.
   The default is 20,000, because compacting a small context throws away a
   cheap warm cache to win back almost nothing. Set it to `0` to drop the
   floor entirely. First-run setup asks you for this value.
3. The `armId` recorded when the timer started still matches the state file.
   A timer replaced by a newer turn can't fire, and a recycled PID can't be
   mistaken for a live timer.
4. Nothing has been written to the transcript more than 60 seconds after
   arming.
5. The Claude Code process that armed the timer is still running.

The timer checks every 15 seconds instead of sleeping once, so putting the
machine to sleep doesn't quietly swallow the deadline.

## Configuration

Settings live in `~/.claude/idle-compactor/config.json`. Per-session timer
state lives in `~/.claude/idle-compactor/sessions/`.

These environment variables override the file for a single session:

| Variable | Effect |
|---|---|
| `CLAUDE_IDLE_COMPACT_DISABLE` | `1` to disable, `0` to force enable |
| `CLAUDE_IDLE_COMPACT_TTL` | `1h` or `5m` |
| `CLAUDE_IDLE_COMPACT_MINUTES` | explicit threshold in minutes |
| `CLAUDE_IDLE_COMPACT_MIN_TOKENS` | minimum context size |
| `CLAUDE_IDLE_COMPACT_ALLOW_BLIND` | `1` to permit blind injection |

## Development

```
node idle-compactor/test/run.js
```

The suite runs against a throwaway `HOME`, so it never touches your real
`~/.claude`. It covers token accounting, how the threshold is worked out, the
arm/disarm/re-arm cycle, every way the timer can abort, keepalive's
ping/confirm/cap loop and the check that tells its own ping apart from real
activity, the compaction prompt, the CLI, and the first-run notice.

You can check the manifests with
`claude plugin validate idle-compactor/.claude-plugin/plugin.json` and
`claude plugin validate .claude-plugin/marketplace.json`.

## Uninstall

```
/plugin uninstall idle-compactor@agent-tools
rm -rf ~/.claude/idle-compactor
```

## License

Apache-2.0. See [LICENSE](../LICENSE).
