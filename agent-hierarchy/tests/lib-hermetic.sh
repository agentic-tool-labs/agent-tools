#!/usr/bin/env bash
# agent-hierarchy — the shared hermetic preamble. Every tests/test-*.sh sources this as its first executable line.
#
# After it, a test cannot reach the user's real herdr or tmux:
#   - every HERDR_* variable and TMUX / TMUX_PANE / AH_TEAM_FILE / CLAUDE_PID is unset (a file may set any of them
#     again for its own fixtures);
#   - TMUX_TMPDIR is a fresh directory, so a tmux a test starts gets a private server;
#   - AH_TEST_HERMETIC=1 turns on the guard in hooks/lib-mux.mjs, the one place herdr and tmux are executed. With it,
#     a binary runs only when it resolves, on the PATH of the call, into a directory listed in AH_TEST_FAKE_BIN
#     (colon-separated absolute directories). Anything else is the real binary: the call is written to
#     AH_TEST_TRIPWIRE, reported on stderr, the process AH_TEST_PID is sent SIGTERM, and nothing runs.
# A test that has a fake herdr or tmux exports AH_TEST_FAKE_BIN=<its bin dir> after creating it. PATH is not changed.
# AH_TEST_HERMETIC is for the test suite only; nothing else sets it.
#
# Sourcing it twice in one shell changes nothing.

if [ "${AH_TEST_HERMETIC:-}" = 1 ] && [ "${AH_TEST_PID:-}" = "$$" ]; then
  return 0 2>/dev/null || true
fi

for _ah_v in $(compgen -v HERDR_); do unset "$_ah_v"; done
unset _ah_v TMUX TMUX_PANE AH_TEAM_FILE CLAUDE_PID AH_TEST_FAKE_BIN

# A short root keeps the unix socket path under the platform limit.
_ah_t=$(mktemp -d /tmp/ahtt.XXXXXX) || return 1
export TMUX_TMPDIR="$_ah_t"
export AH_TEST_HERMETIC=1
export AH_TEST_PID=$$
export AH_TEST_TRIPWIRE="$_ah_t/tripwire"
: >"$AH_TEST_TRIPWIRE"
unset _ah_t
