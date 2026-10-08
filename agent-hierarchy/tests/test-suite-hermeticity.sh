#!/bin/bash
# agent-hierarchy — suites never inherit the invoking session's CLAUDE_PID: every tests/*.sh that
# unsets AH_TEAM_FILE also unsets CLAUDE_PID, so a check that needs an orchestrator pid sets it
# itself and the suite passes the same inside and outside a Claude session.
# It also lints that every suite sources tests/lib-hermetic.sh first and declares its fake herdr/tmux
# directories in AH_TEST_FAKE_BIN, and proves the guard in hooks/lib-mux.mjs fires (spec 0091).
# Usage: bash tests/test-suite-hermeticity.sh   (exits 0 iff all cases pass)

. "$(dirname "$0")/lib-hermetic.sh"
unset AH_TEAM_FILE  # every session roster.mjs launches carries one; a test must not inherit it
unset CLAUDE_PID  # every Claude session exports one; a test must not inherit it

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-suite-hermeticity-test.XXXXXX")"
hermetic_on_exit 'rm -rf "$SANDBOX"'
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (OUT=${OUT:0:500})"; fi
}

# Each *.sh in <dir> that unsets AH_TEAM_FILE but never CLAUDE_PID, one per line.
lint() {
  local f
  for f in "$1"/*.sh; do
    grep -qE '^[[:space:]]*(export PATH=[^;]*;[[:space:]]*)?unset[[:space:]]([^#]*[[:space:]])?AH_TEAM_FILE([[:space:];]|$)' "$f" || continue
    grep -qE '^[[:space:]]*(export PATH=[^;]*;[[:space:]]*)?unset[[:space:]]([^#]*[[:space:]])?CLAUDE_PID([[:space:];]|$)' "$f" || basename "$f"
  done
}

OUT=$(lint "$PLUGIN/tests")
check "T-H3: every suite that unsets AH_TEAM_FILE also unsets CLAUDE_PID" '[ -z "$OUT" ]'

mkdir -p "$SANDBOX/scratch"
printf '#!/bin/bash\nunset AH_TEAM_FILE  # x\necho hi\n' > "$SANDBOX/scratch/test-only-team-file.sh"
printf '#!/bin/bash\nunset AH_TEAM_FILE  # x\nunset CLAUDE_PID  # x\n' > "$SANDBOX/scratch/test-both-lines.sh"
printf '#!/bin/bash\nexport PATH="/x:$PATH"; unset HERDR_ENV AH_TEAM_FILE CLAUDE_PID\n' > "$SANDBOX/scratch/test-both-one-line.sh"
printf '#!/bin/bash\nunset AH_TEAM_FILE\n# unset CLAUDE_PID only in a comment\n' > "$SANDBOX/scratch/test-comment-only.sh"
printf '#!/bin/bash\necho no unsets here\n' > "$SANDBOX/scratch/test-neither.sh"
OUT=$(lint "$SANDBOX/scratch" | sort | tr '\n' ' ')
check "T-H3: the lint names a suite that unsets only AH_TEAM_FILE, or names CLAUDE_PID only in a comment, and nothing else" \
  '[ "$OUT" = "test-comment-only.sh test-only-team-file.sh " ]'

# ---- H1 / H2: every suite runs under the shared guard (spec 0091 section 3.3).
# H1: the first line that is not blank, a comment or a `set` line sources lib-hermetic.sh.
lint_h1() {
  local f first
  for f in "$1"/test-*.sh; do
    first=$(grep -vE '^[[:space:]]*($|#|set[[:space:]])' "$f" | head -1)
    case "$first" in
      '. "$(dirname "$0")/lib-hermetic.sh"') ;;
      *) basename "$f" ;;
    esac
  done
}
# H2: every directory a suite writes an executable herdr, tmux, claude or codex into appears in an AH_TEST_FAKE_BIN export of that suite.
lint_h2() {
  local f exports dirs d
  for f in "$1"/test-*.sh; do
    dirs=$(grep -E '(>|tee |cp |ln -s |chmod \+x )[^|;&]*/(herdr|tmux|claude|codex)("|[[:space:]]|<|;|&|$)' "$f" |
      sed -nE 's#.*[ ">]"?(\$\{?[A-Za-z_][A-Za-z0-9_]*\}?[A-Za-z0-9_./${}-]*)/(herdr|tmux|claude|codex)("|[[:space:]]|<|;|&|$).*#\1#p' | sort -u)
    [ -n "$dirs" ] || continue
    exports=$(grep -E '(^|;)[[:space:]]*export AH_TEST_FAKE_BIN=' "$f")
    for d in $dirs; do
      case "$exports" in *"$d"*) ;; *) echo "$(basename "$f"):$d" ;; esac
    done
  done
}

OUT=$(lint_h1 "$PLUGIN/tests")
check "H1: every tests/test-*.sh sources lib-hermetic.sh before anything else runs" '[ -z "$OUT" ]'
OUT=$(lint_h2 "$PLUGIN/tests")
check "H2: every suite that writes a fake herdr or tmux lists its directory in AH_TEST_FAKE_BIN" '[ -z "$OUT" ]'

mkdir -p "$SANDBOX/h1" "$SANDBOX/h2"
printf '#!/bin/bash\n# header\nset -u\n. "$(dirname "$0")/lib-hermetic.sh"\necho ok\n' > "$SANDBOX/h1/test-good.sh"
printf '#!/bin/bash\nPLUGIN=x\n. "$(dirname "$0")/lib-hermetic.sh"\n' > "$SANDBOX/h1/test-late.sh"
printf '#!/bin/bash\necho no source line\n' > "$SANDBOX/h1/test-none.sh"
OUT=$(lint_h1 "$SANDBOX/h1" | sort | tr '\n' ' ')
check "H1: a file whose first executable line is not the source line fails, a file that sources it first passes" '[ "$OUT" = "test-late.sh test-none.sh " ]'

printf '#!/bin/bash\nSANDBOX=x\nmkdir -p "$SANDBOX/bin"\ncat > "$SANDBOX/bin/%s" <<EOF\nexit 1\nEOF\nexport AH_TEST_FAKE_BIN="$SANDBOX/bin"\n' herdr > "$SANDBOX/h2/test-listed.sh"
printf '#!/bin/bash\nSANDBOX=x\nmkdir -p "$SANDBOX/bin"\ncat > "$SANDBOX/bin/%s" <<EOF\nexit 1\nEOF\n' herdr > "$SANDBOX/h2/test-unlisted.sh"
printf '#!/bin/bash\nSANDBOX=x\nprintf x > "$SANDBOX/fake/%s"\nexport AH_TEST_FAKE_BIN="$SANDBOX/bin"\n' tmux > "$SANDBOX/h2/test-wrongdir.sh"
printf '#!/bin/bash\necho nothing here\n' > "$SANDBOX/h2/test-nofake.sh"
OUT=$(lint_h2 "$SANDBOX/h2" | sort | tr '\n' ' ')
check "H2: a suite that writes a fake without listing its directory fails; listed and no-fake suites pass" \
  '[ "$OUT" = "test-unlisted.sh:\$SANDBOX/bin test-wrongdir.sh:\$SANDBOX/fake " ]'

# H3: no suite sets its own trap on EXIT, TERM, INT or HUP; the shared exit path in lib-hermetic.sh owns them, and a suite
# registers cleanup with hermetic_on_exit.
lint_h3() {
  local f
  for f in "$1"/test-*.sh; do
    grep -qE '^[[:space:]]*trap[[:space:]].*(EXIT|TERM|INT|HUP)' "$f" && basename "$f"
  done
}
# H4: no suite passes tmux -S a literal absolute path, or assigns one ending in .sock; sockets live under $TMUX_TMPDIR.
lint_h4() {
  local f
  for f in "$1"/test-*.sh; do
    grep -qE -e '-S[[:space:]]+"?/' -e '="?/[^" ]*\.sock' "$f" && basename "$f"
  done
}

OUT=$(lint_h3 "$PLUGIN/tests")
check "H3: no tests/test-*.sh sets a trap on EXIT, TERM, INT or HUP (they use hermetic_on_exit)" '[ -z "$OUT" ]'
OUT=$(lint_h4 "$PLUGIN/tests")
check "H4: no tests/test-*.sh puts a tmux socket at a literal absolute path" '[ -z "$OUT" ]'

mkdir -p "$SANDBOX/h3" "$SANDBOX/h4"
S_FLAG=-S
printf '#!/bin/bash\ntra%s rm_all EXIT\n' p > "$SANDBOX/h3/test-trap-exit.sh"
printf '#!/bin/bash\n  tra%s cleanup INT\n' p > "$SANDBOX/h3/test-trap-int.sh"
printf '#!/bin/bash\nhermetic_on_exit rm_all\n# a comment about a trap\n' > "$SANDBOX/h3/test-clean.sh"
OUT=$(lint_h3 "$SANDBOX/h3" | sort | tr '\n' ' ')
check "H3: a suite that sets a trap on EXIT or INT fails, one that uses hermetic_on_exit passes" '[ "$OUT" = "test-trap-exit.sh test-trap-int.sh " ]'
printf '#!/bin/bash\ntmux %s /tm%s/x.sock new-session\n' "$S_FLAG" p > "$SANDBOX/h4/test-literal-flag.sh"
printf '#!/bin/bash\nSOCK="%s"\n' "/tm$(printf p)/y.sock" > "$SANDBOX/h4/test-literal-assign.sh"
printf '#!/bin/bash\nSOCK="$TMUX_TMPDIR/z.sock"\ntmux %s "$SOCK" new-session\n' "$S_FLAG" > "$SANDBOX/h4/test-under-tmpdir.sh"
OUT=$(lint_h4 "$SANDBOX/h4" | sort | tr '\n' ' ')
check "H4: a literal /tmp socket path fails; a socket under TMUX_TMPDIR passes" '[ "$OUT" = "test-literal-assign.sh test-literal-flag.sh " ]'

# ---- G1-G7: the guard in hooks/lib-mux.mjs, against the real roster.mjs.
G="$SANDBOX/g"
H="$PLUGIN/hooks"
NODE_DIR="$(dirname "$(command -v node)")"
mkdir -p "$G/realbin" "$G/linkbin" "$G/home"
mkfake() { # <dir> <name>: a binary that logs its argv to $G/real.log and fails
  printf '#!/bin/sh\necho "%s $*" >> "%s"\nexit 1\n' "$2" "$G/real.log" > "$1/$2"
  chmod +x "$1/$2"
}
mkfake "$G/realbin" herdr
mkfake "$G/realbin" tmux
LINK_NAME=herdr
ln -s "$G/realbin/$LINK_NAME" "$G/linkbin/$LINK_NAME"
cat > "$G/child.sh" <<'CHILD'
#!/bin/bash
[ -n "${G_NOLIB:-}" ] || . "$G_LIB/lib-hermetic.sh"
[ -n "${G_LIST+x}" ] && export AH_TEST_FAKE_BIN="$G_LIST"
[ -n "${G_NOPID:-}" ] && unset AH_TEST_PID
[ -n "${G_NOLIB:-}" ] || hermetic_on_exit 'cp "$AH_TEST_TRIPWIRE" "$G_OUT/tripwire.copy" 2>/dev/null'
export PATH="$G_PATH" HOME="$G_HOME" CLAUDE_PID=$$
[ -n "${G_HERDR_ENV:-}" ] && export HERDR_ENV=1 HERDR_PANE_ID=w1:p0 HERDR_WORKSPACE_ID=w1
node "$G_H/roster.mjs" stream-open sx --no-worktree --cwd "$G_PROJ"
CHILD
# run_g <env assignments...>: one child bash; GRC its exit status, GERR its stderr, GTRIP its tripwire file.
GRUN=0
run_g() {
  GRUN=$((GRUN + 1))
  GPROJ="$G/proj$GRUN"
  mkdir -p "$GPROJ"
  git -C "$GPROJ" init -q -b main
  git -C "$GPROJ" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
  rm -f "$G/real.log" "$G/tripwire.copy"
  env -u AH_TEST_HERMETIC -u AH_TEST_FAKE_BIN -u AH_TEST_PID -u AH_TEST_TRIPWIRE -u TMUX_TMPDIR \
    G_LIB="$PLUGIN/tests" G_H="$H" G_OUT="$G" G_HOME="$G/home" G_PROJ="$GPROJ" "$@" bash "$G/child.sh" >"$G/out" 2>"$G/err"
  GRC=$?
  GERR=$(cat "$G/err")
  GTRIP=$(cat "$G/tripwire.copy" 2>/dev/null)
}
PATH_REAL="$G/realbin:$NODE_DIR:/usr/bin:/bin"

run_g G_PATH="$PATH_REAL" G_HERDR_ENV=1
check "G1: an unlisted herdr first on PATH: the child is killed, the binary never ran, the tripwire names it, stderr names it" \
  '[ "$GRC" -ne 0 ] && [ ! -e "$G/real.log" ] && printf "%s" "$GTRIP" | grep -q "^herdr " && printf "%s" "$GERR" | grep -q "real herdr"'

run_g G_PATH="$PATH_REAL" G_HERDR_ENV=1 G_LIST="$G/realbin"
check "G2: the same fake listed in AH_TEST_FAKE_BIN runs, nothing trips, the child completes" \
  '[ "$GRC" -eq 0 ] && grep -q "^herdr tab create" "$G/real.log" && [ -z "$GTRIP" ]'

run_g G_PATH="$PATH_REAL"
check "G3: tmux, unlisted: detectTransport reaches list-sessions, tripwire, killed, binary never ran" \
  '[ "$GRC" -ne 0 ] && [ ! -e "$G/real.log" ] && printf "%s" "$GTRIP" | grep -q "^tmux list-sessions" && printf "%s" "$GERR" | grep -q "real tmux"'
run_g G_PATH="$PATH_REAL" G_LIST="$G/realbin"
check "G3: tmux, listed: the fake runs and the child completes" '[ "$GRC" -eq 0 ] && grep -q "^tmux list-sessions" "$G/real.log" && [ -z "$GTRIP" ]'

run_g G_PATH="$PATH_REAL" G_HERDR_ENV=1 G_NOLIB=1
check "G4: no guard (AH_TEST_HERMETIC unset): the product path is unchanged and the fake runs" \
  '[ "$GRC" -eq 0 ] && grep -q "^herdr tab create" "$G/real.log"'

run_g G_PATH="$G/linkbin:$NODE_DIR:/usr/bin:/bin" G_HERDR_ENV=1 G_LIST="$G/linkbin"
check "G5: a listed directory holding a symlink to a binary outside it: tripwire, killed, binary never ran" \
  '[ "$GRC" -ne 0 ] && [ ! -e "$G/real.log" ] && printf "%s" "$GTRIP" | grep -q "^herdr "'

run_g G_PATH="$PATH_REAL" G_HERDR_ENV=1 G_NOPID=1
check "G6: AH_TEST_PID unset: no kill, but the tripwire line and the refusal still happen and the binary never ran" \
  '[ ! -e "$G/real.log" ] && printf "%s" "$GTRIP" | grep -q "^herdr " && printf "%s" "$GERR" | grep -q "real herdr"'

run_g G_PATH="$NODE_DIR:/usr/bin:/bin" G_HERDR_ENV=1
check "G7: no herdr anywhere on PATH: the failure is the same as today, no tripwire, no kill" \
  '[ "$GRC" -eq 0 ] && [ -z "$GTRIP" ] && [ ! -e "$G/real.log" ]'

# ---- G8-G12 (r2): member launch strings, and test-owned tmux servers.
mkdir -p "$G/notmux" "$G/herdronly" "$G/specproj"
mkfail() { printf '#!/bin/sh\nexit 1\n' > "$1/$2"; chmod +x "$1/$2"; }
mkfail "$G/notmux" tmux
mkfake "$G/realbin" claude
mkfake "$G/herdronly" herdr
# the launch strings roster.mjs builds for the herdr and tmux transports
LAUNCH_HERDR='herdr agent start x --kind claude --pane p1 -- --agent ah:implementor'
LAUNCH_TMUX='tmux send-keys -t p1 "claude --agent ah:implementor" Enter'
cat > "$G/child-sh.sh" <<'CHILD'
#!/bin/bash
. "$G_LIB/lib-hermetic.sh"
hermetic_on_exit 'cp "$AH_TEST_TRIPWIRE" "$G_OUT/tripwire.copy" 2>/dev/null'
[ -n "${G_LIST+x}" ] && export AH_TEST_FAKE_BIN="$G_LIST"
export PATH="$G_PATH"
# what runShell does with a launch string: the guard, then /bin/sh -c
node --input-type=module -e 'const { guardShellCommand } = await import(process.argv[1]); const { execFileSync } = await import("node:child_process"); guardShellCommand(process.argv[2]); execFileSync("/bin/sh", ["-c", process.argv[2]]);' "$G_H/lib-mux.mjs" "$G_CMD"
CHILD
cat > "$G/child-spawn.sh" <<'CHILD'
#!/bin/bash
. "$G_LIB/lib-hermetic.sh"
hermetic_on_exit 'cp "$AH_TEST_TRIPWIRE" "$G_OUT/tripwire.copy" 2>/dev/null'
export AH_TEST_FAKE_BIN="$G_LIST"
export PATH="$G_PATH" HOME="$G_HOME" CLAUDE_PID=$$
node "$G_H/roster.mjs" create --spawn --mode auto --cwd "$G_PROJ"
CHILD
cat > "$G/child-leak.sh" <<'CHILD'
#!/bin/bash
. "$G_LIB/lib-hermetic.sh"
hermetic_on_exit 'cp "$AH_TEST_TRIPWIRE" "$G_OUT/tripwire.copy" 2>/dev/null'
[ -n "$AH_REAL_TMUX" ] || exit 77
echo "$TMUX_TMPDIR" > "$G_OUT/leak-dir"
"$AH_REAL_TMUX" -S "$TMUX_TMPDIR/leak.sock" new-session -d -s leak || exit 78
case "$G_MODE" in
  leak) exit 0 ;;
  term) kill -TERM $$; sleep 3; exit 0 ;;
  tidy) "$AH_REAL_TMUX" -S "$TMUX_TMPDIR/leak.sock" kill-server; exit 0 ;;
esac
CHILD

# run_sh <child script> <env assignments...>: one child bash; GRC, GERR, and GTRIP from the copy the child saves on exit.
run_sh() {
  local child=$1; shift
  rm -f "$G/real.log" "$G/tripwire.copy" "$G/leak-dir"
  env -u AH_TEST_HERMETIC -u AH_TEST_FAKE_BIN -u AH_TEST_PID -u AH_TEST_TRIPWIRE -u TMUX_TMPDIR \
    G_LIB="$PLUGIN/tests" G_H="$H" G_OUT="$G" G_HOME="$G/home" "$@" bash "$G/$child" >"$G/out" 2>"$G/err"
  GRC=$?
  GERR=$(cat "$G/err")
  GTRIP=$(cat "$G/tripwire.copy" 2>/dev/null)
}

run_sh child-sh.sh G_PATH="$PATH_REAL" G_CMD="$LAUNCH_HERDR"
check "G8: member launch, herdr template, herdr not listed: tripwire names herdr agent start, the binary never ran" \
  '[ "$GRC" -ne 0 ] && [ ! -e "$G/real.log" ] && printf "%s" "$GTRIP" | grep -q "^herdr agent start "'
run_sh child-sh.sh G_PATH="$PATH_REAL" G_CMD="$LAUNCH_TMUX"
check "G9: member launch, tmux send-keys template, tmux not listed: tripwire, the binary never ran" \
  '[ "$GRC" -ne 0 ] && [ ! -e "$G/real.log" ] && printf "%s" "$GTRIP" | grep -q "^tmux send-keys "'

# G10 is the whole product path: create --spawn on the terminal transport launches "claude ... --bg" through runShell.
# Setup runs with a failing tmux listed, so detectTransport has nothing real to reach.
SP="$G/specproj"
git -C "$SP" init -q -b main
git -C "$SP" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
env HOME="$G/home" PATH="$G/notmux:$PATH" AH_TEST_FAKE_BIN="$G/notmux" node "$H/roster.mjs" init --level repo --route peer --cwd "$SP" >/dev/null 2>&1
env HOME="$G/home" PATH="$G/notmux:$PATH" AH_TEST_FAKE_BIN="$G/notmux" node "$H/roster.mjs" add --no-spawn --level repo --role implementor --model inherit --cwd "$SP" >/dev/null 2>&1
run_sh child-spawn.sh G_PROJ="$SP" G_LIST="$G/notmux" G_PATH="$G/notmux:$G/realbin:$NODE_DIR:/usr/bin:/bin"
check "G10: terminal transport launch (claude ... --bg), claude not listed: tripwire names claude, no real session starts" \
  '[ "$GRC" -ne 0 ] && [ ! -e "$G/real.log" ] && printf "%s" "$GTRIP" | grep -q "^claude "'

run_sh child-sh.sh G_PATH="$G/herdronly:$G/realbin:$NODE_DIR:/usr/bin:/bin" G_LIST="$G/herdronly" G_CMD="$LAUNCH_HERDR"
check "G11: a listed fake herdr with --kind claude and an unlisted claude: the launch runs, claude as an argument is not checked" \
  '[ -z "$GTRIP" ] && grep -q "^herdr agent start x --kind claude" "$G/real.log"'

# The skip depends on a lookup that is independent of the variable under test: a lib-hermetic.sh that stopped finding tmux
# must fail here, not switch the leak cases off.
PROBE_TMUX=$(PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin" command -v tmux 2>/dev/null)
if [ -z "$PROBE_TMUX" ]; then
  echo "SKIP: G12 leak detection needs a real tmux; none found on PATH or in the usual install directories"
else
  check "G12: lib-hermetic.sh found the real tmux: AH_REAL_TMUX is set and equals an independent lookup" '[ -n "$AH_REAL_TMUX" ] && [ "$AH_REAL_TMUX" = "$PROBE_TMUX" ]'
  run_sh child-leak.sh G_MODE=leak
  check "G12: a test that exits 0 with a live tmux server: exit 1, stderr names the socket, server and directory gone" \
    '[ "$GRC" -eq 1 ] && printf "%s" "$GERR" | grep -q "leak.sock" && [ ! -e "$(cat "$G/leak-dir")" ] && ! "$PROBE_TMUX" -S "$(cat "$G/leak-dir")/leak.sock" list-sessions >/dev/null 2>&1'
  run_sh child-leak.sh G_MODE=term
  check "G12: the same when the test is sent SIGTERM mid-way: non-zero exit, the socket named, server and directory gone" \
    '[ "$GRC" -ne 0 ] && printf "%s" "$GERR" | grep -q "leak.sock" && [ ! -e "$(cat "$G/leak-dir")" ] && ! "$PROBE_TMUX" -S "$(cat "$G/leak-dir")/leak.sock" list-sessions >/dev/null 2>&1'
  run_sh child-leak.sh G_MODE=tidy
  check "G12: a test that kills its own server: exit 0, no leak reported, directory gone" \
    '[ "$GRC" -eq 0 ] && ! printf "%s" "$GERR" | grep -q "left a tmux server" && [ ! -e "$(cat "$G/leak-dir")" ]'
fi

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
