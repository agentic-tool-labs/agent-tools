#!/usr/bin/env bash
# agent-hierarchy — the shared hermetic preamble. Every tests/test-*.sh sources this as its first executable line.
#
# After it, a test cannot reach the user's real herdr, tmux, claude or codex, and cannot leave a tmux server behind:
#   - every HERDR_* variable and TMUX / TMUX_PANE / AH_TEAM_FILE / CLAUDE_PID is unset (a file may set any of them
#     again for its own fixtures);
#   - TMUX_TMPDIR is a fresh directory, so a tmux a test starts gets a private server (a test that passes tmux -S puts
#     the socket under it);
#   - AH_TEST_HERMETIC=1 turns on the guard in hooks/lib-mux.mjs, the one place herdr and tmux are executed and the
#     check on the shell strings that launch a member. With it, a guarded binary runs only when it resolves, on the
#     PATH of the call, into a directory listed in AH_TEST_FAKE_BIN (colon-separated absolute directories). Anything
#     else is the real binary: the call is written to AH_TEST_TRIPWIRE, reported on stderr, the process AH_TEST_PID is
#     sent SIGTERM, and nothing runs.
# A test that has a fake herdr, tmux, claude or codex exports AH_TEST_FAKE_BIN=<its bin dir> after creating it. PATH is
# not changed.
#
# This file also owns how a test ends. A test never sets its own trap: it registers cleanup with
#   hermetic_on_exit '<command>'
# and the handler below runs those commands in order on every way out (normal exit, a failed command, SIGTERM, SIGINT,
# SIGHUP), then kills any tmux server still listening on a socket under TMUX_TMPDIR (reporting it as a leak and
# failing the test), then removes TMUX_TMPDIR.
#
# AH_TEST_HERMETIC is for the test suite only; nothing else sets it. Sourcing this twice in one shell changes nothing.

if [ "${AH_TEST_HERMETIC:-}" = 1 ] && [ "${AH_TEST_PID:-}" = "$$" ]; then
  return 0 2>/dev/null || true
fi

for _ah_v in $(compgen -v HERDR_); do unset "$_ah_v"; done
unset _ah_v TMUX TMUX_PANE AH_TEAM_FILE CLAUDE_PID AH_TEST_FAKE_BIN

# The real tmux, found before a test prepends fakes to PATH. A value inherited from a parent test is kept.
if [ -z "${AH_REAL_TMUX+x}" ]; then
  AH_REAL_TMUX=$(command -v tmux 2>/dev/null || true)
fi
export AH_REAL_TMUX

# A short root keeps the unix socket path under the platform limit.
_ah_t=$(mktemp -d /tmp/ahtt.XXXXXX) || return 1
export TMUX_TMPDIR="$_ah_t"
export AH_TEST_HERMETIC=1
export AH_TEST_PID=$$
export AH_TEST_TRIPWIRE="$_ah_t/tripwire"
: >"$AH_TEST_TRIPWIRE"
_AH_HERMETIC_DIR="$_ah_t"
_AH_HERMETIC_FILE="${BASH_SOURCE[1]:-$0}"
unset _ah_t

AH_HERMETIC_EXIT_CMDS=()
hermetic_on_exit() { AH_HERMETIC_EXIT_CMDS+=("$1"); }

_hermetic_exit() {
  local _hx_rc=$? _hx_cmd _hx_sock _hx_leaked=0
  trap - EXIT TERM INT HUP
  set +e
  for _hx_cmd in ${AH_HERMETIC_EXIT_CMDS[@]+"${AH_HERMETIC_EXIT_CMDS[@]}"}; do
    eval "$_hx_cmd"
  done
  if [ -n "$AH_REAL_TMUX" ] && [ -d "$_AH_HERMETIC_DIR" ]; then
    while IFS= read -r _hx_sock; do
      if "$AH_REAL_TMUX" -S "$_hx_sock" kill-server >/dev/null 2>&1; then
        echo "ah: test hermeticity: $_AH_HERMETIC_FILE left a tmux server running on $_hx_sock; it was killed" >&2
        _hx_leaked=1
      fi
    done < <(find "$_AH_HERMETIC_DIR" -type s 2>/dev/null)
  fi
  case "$_AH_HERMETIC_DIR" in /tmp/ahtt.?*) rm -rf "$_AH_HERMETIC_DIR" ;; esac
  [ "$_hx_leaked" = 1 ] && _hx_rc=1
  exit "$_hx_rc"
}
trap _hermetic_exit EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
trap 'exit 129' HUP
