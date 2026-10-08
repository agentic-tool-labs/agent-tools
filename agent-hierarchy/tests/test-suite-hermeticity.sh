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
trap 'rm -rf "$SANDBOX"' EXIT
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
# H2: every directory a suite writes an executable herdr or tmux into appears in an AH_TEST_FAKE_BIN export of that suite.
lint_h2() {
  local f exports dirs d
  for f in "$1"/test-*.sh; do
    dirs=$(grep -E '(>|tee |cp |ln -s |chmod \+x )[^|;&]*/(herdr|tmux)("|[[:space:]]|<|;|&|$)' "$f" |
      sed -nE 's#.*[ ">]"?(\$\{?[A-Za-z_][A-Za-z0-9_]*\}?[A-Za-z0-9_./${}-]*)/(herdr|tmux)("|[[:space:]]|<|;|&|$).*#\1#p' | sort -u)
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
echo "${AH_TEST_TRIPWIRE:-}" > "$G_OUT/tripwire-path"
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
  rm -f "$G/real.log" "$G/tripwire-path"
  env -u AH_TEST_HERMETIC -u AH_TEST_FAKE_BIN -u AH_TEST_PID -u AH_TEST_TRIPWIRE -u TMUX_TMPDIR \
    G_LIB="$PLUGIN/tests" G_H="$H" G_OUT="$G" G_HOME="$G/home" G_PROJ="$GPROJ" "$@" bash "$G/child.sh" >"$G/out" 2>"$G/err"
  GRC=$?
  GERR=$(cat "$G/err")
  GTRIP=$(cat "$(cat "$G/tripwire-path" 2>/dev/null)" 2>/dev/null)
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

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
