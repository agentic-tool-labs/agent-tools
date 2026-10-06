#!/bin/bash
# agent-hierarchy — a level file that exists but isn't a JSON object (invalid JSON, an empty file,
# an array): every roster.mjs verb that writes it refuses and writes nothing at all; a missing file
# is still created; untrack's config removal warns and leaves the file; read verbs are unchanged.
# HOME-redirected; real state untouched.
# Usage: bash tests/test-config-unparsable.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
# Every Claude session exports some of these; a test must not inherit any of them.
unset AH_TEAM_FILE CLAUDE_PID AH_ROSTER HERDR_ENV HERDR_PANE_ID TMUX_PANE AGENT_HIERARCHY_DIR
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-config-unparsable-test.XXXXXX")"
[ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/myrepo"
REPO_CFG="$PROJ/.claude/agent-hierarchy.json"
GLOBAL_CFG="$FAKEHOME/.claude/agent-hierarchy.json"
REPO_USER_CFG="$FAKEHOME/.claude/agent-hierarchy/projects/$(echo "$PROJ" | sed 's,/,-,g')/agent-hierarchy.json"
TRUNC='{"version": 1,'
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:300} ERR=${ERR:0:300})"; fi
}

# An empty HOME and a fresh repo whose repo-level file holds a default block and a named roster.
fresh() {
  rm -rf "$FAKEHOME" "$PROJ"
  mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude"
  git -C "$PROJ" init -q
  cat > "$REPO_CFG" <<'EOF'
{"version":1,"roster":{"route":"peer","members":[{"role":"architect","model":"opus"}]},
 "rosters":{"game":{"route":"peer","members":[{"role":"reviewer","model":"sonnet"}]}}}
EOF
}

# roster.mjs with HOME redirected: stdout in OUT, stderr in ERR. The stderr file sits outside the
# trees that `snap` lists.
rm_() {
  OUT=$(HOME="$FAKEHOME" node "$H/roster.mjs" "$@" 2>"$SANDBOX/err"); RC=$?
  ERR=$(cat "$SANDBOX/err")
}

# <js expression over the parsed OUT o>: its value (strings bare, anything else as JSON).
jget() {
  node -e 'const o=JSON.parse(process.argv[1]);const v=(new Function("o","return ("+process.argv[2]+")"))(o);process.stdout.write(typeof v==="string"?v:JSON.stringify(v))' "$OUT" "$1" 2>/dev/null
}

# Every file under HOME and the repo, with a content hash.
snap() {
  (cd "$SANDBOX" && find home myrepo -type f -print0 | sort -z | xargs -0 shasum)
}

# <file> <trunc|array|empty>: makes <file> unparsable that way.
spoil() {
  mkdir -p "$(dirname "$1")"
  case $2 in
    trunc) printf '%s' "$TRUNC" > "$1" ;;
    array) printf '[]' > "$1" ;;
    empty) : > "$1" ;;
  esac
}

# <label> <file> <trunc|array|empty> <roster.mjs args…>: the verb exits 2, names the path, the
# reason and `nothing was written`, and leaves every file under HOME and the repo as it was.
refuses() {
  local label=$1 file=$2 kind=$3; shift 3
  spoil "$file" "$kind"
  cp "$file" "$SANDBOX/before"
  local before; before=$(snap)
  rm_ "$@"
  local why='is not valid JSON ('
  [ "$kind" = array ] && why='is not a JSON object'
  WHY=$why FILE=$file
  check "U1 $label ($kind) refuses" '[ $RC = 2 ] && [[ "$ERR" == *"$FILE"* ]] && [[ "$ERR" == *"$WHY"* ]] && [[ "$ERR" == *"nothing was written"* ]]'
  check "U1 $label ($kind) leaves the file's bytes" 'cmp -s "$FILE" "$SANDBOX/before"'
  AFTER=$(snap) BEFORE=$before
  check "U1 $label ($kind) changes no other file" '[ "$AFTER" = "$BEFORE" ]'
}

# ---------------------------------------------------------------- U1 writers refuse
fresh
for k in trunc array empty; do
  refuses "init" "$REPO_USER_CFG" $k init --level repo-user --route peer --cwd "$PROJ"
  refuses "add" "$REPO_USER_CFG" $k add --level repo-user --role reviewer --model sonnet --cwd "$PROJ"
  refuses "roster use" "$REPO_USER_CFG" $k roster use game --cwd "$PROJ"
done
refuses "edit" "$REPO_USER_CFG" trunc edit --level repo-user --member reviewer --model opus --cwd "$PROJ"
refuses "remove" "$REPO_USER_CFG" trunc remove --level repo-user --member reviewer --cwd "$PROJ"
refuses "tier set" "$GLOBAL_CFG" trunc tier set codex gpt-5 opus --cwd "$PROJ"
refuses "tier remove" "$GLOBAL_CFG" trunc tier remove codex gpt-5 --cwd "$PROJ"
refuses "role set" "$REPO_USER_CFG" trunc role set reviewer --model sonnet --level repo-user --cwd "$PROJ"
# A pack `pk` from marketplace `mk` offering one implement role, pk-impl.
PK="$SANDBOX/packs/a"
mkdir -p "$PK/.claude-plugin" "$PK/agents" "$FAKEHOME/.claude/plugins"
printf '{"name":"pk","version":"1.0.0","description":"test pack"}\n' > "$PK/.claude-plugin/plugin.json"
printf -- '---\nname: pk-impl\ndescription: Builds pack things\nmodel: opus\ntools: Read, Grep, Edit, Write, Bash, SendMessage\n---\nYou build pack features.\n' > "$PK/agents/pk-impl.md"
printf '{"version":1,"roles":{"pk-impl":{"class":"implement","description":"Builds pack features","model":"opus"}}}\n' > "$PK/ah-roles.json"
printf '{"version":2,"plugins":{"pk@mk":[{"scope":"user","installPath":"%s","version":"1.0.0"}]}}\n' "$PK" > "$FAKEHOME/.claude/plugins/installed_plugins.json"
refuses "role set --from" "$REPO_USER_CFG" trunc role set impl --from pk@mk:pk-impl --pin sha256:00 --level repo-user --cwd "$PROJ"
refuses "role trust" "$REPO_USER_CFG" trunc role trust reviewer --pin sha256:00 --level repo-user --cwd "$PROJ"
refuses "role remove" "$REPO_USER_CFG" trunc role remove reviewer --level repo-user --cwd "$PROJ"
refuses "roster copy" "$REPO_USER_CFG" trunc roster copy game g2 --level repo-user --cwd "$PROJ"
refuses "roster delete" "$REPO_USER_CFG" trunc roster delete game --level repo-user --cwd "$PROJ"

# ---------------------------------------------------------------- U2 a missing file is still created
fresh
rm_ init --level repo-user --route peer --cwd "$PROJ"
check "U2 init creates a missing repo-user file" '[ $RC = 0 ] && [ -f "$REPO_USER_CFG" ]'

# ---------------------------------------------------------------- U3 side-effect writers
# untrack --also-config: the team row goes, the unparsable config file stays as it was.
cat > "$SANDBOX/team.json" <<'EOF'
{ "version": 1, "team_id": "t3", "created": "2026-01-01T00:00:00Z", "roster_level": "repo",
  "transport": "terminal", "orchestrator": { "session_id": null, "pid": null },
  "members": [
    {"role": "implementor", "name": "myrepo-implementor", "route": "peer", "model": "sonnet"},
    {"role": "implementor", "name": "myrepo-implementor-2", "route": "peer", "model": "sonnet"}
  ], "partial": false }
EOF
fresh
mkdir -p "$PROJ/.claude/hierarchy"
cp "$SANDBOX/team.json" "$PROJ/.claude/hierarchy/team.json"
spoil "$REPO_CFG" trunc
cp "$REPO_CFG" "$SANDBOX/before"
rm_ untrack myrepo-implementor-2 --commit --keep-sessions --also-config --level repo --cwd "$PROJ"
check "U3 untrack on an unparsable config file completes" '[ $RC = 0 ]'
check "U3 ... the team row is gone" '! grep -q "myrepo-implementor-2" "$PROJ/.claude/hierarchy/team.json"'
check "U3 ... the config file's bytes are unchanged" 'cmp -s "$REPO_CFG" "$SANDBOX/before"'
check "U3 ... stderr names the path" '[[ "$ERR" == *"$REPO_CFG"* ]]'
check "U3 ... its output shows the member not removed, with the reason" '[ "$(jget o.config.removed)" = false ] && [[ "$(jget o.config.reason)" == "$REPO_CFG is not valid JSON ("* ]]'

# untrack with no --level, when the only file that could define the roster won't parse: no level
# resolves, and that is reported, not fatal.
fresh
rm -f "$REPO_CFG"
mkdir -p "$PROJ/.claude/hierarchy"
cp "$SANDBOX/team.json" "$PROJ/.claude/hierarchy/team.json"
spoil "$REPO_USER_CFG" trunc
cp "$REPO_USER_CFG" "$SANDBOX/before"
rm_ untrack myrepo-implementor-2 --commit --keep-sessions --also-config --cwd "$PROJ"
check "U3 untrack with no level resolving completes" '[ $RC = 0 ]'
check "U3 ... the team row is gone" '! grep -q "myrepo-implementor-2" "$PROJ/.claude/hierarchy/team.json"'
check "U3 ... the config file's bytes are unchanged" 'cmp -s "$REPO_USER_CFG" "$SANDBOX/before"'
check "U3 ... the warning gives the reason and names the skipped file" '[[ "$ERR" == *"no roster resolves at any level ($REPO_USER_CFG is not valid JSON ("* ]]'
check "U3 ... its output shows the member not removed, with the reason" '[ "$(jget o.config.removed)" = false ] && [[ "$(jget o.config.reason)" == "no roster resolves at any level"* ]]'

# untrack when the config file can't be written: reported, not fatal.
fresh
mkdir -p "$PROJ/.claude/hierarchy"
sed 's/myrepo-implementor-2/myrepo-architect/' "$SANDBOX/team.json" > "$PROJ/.claude/hierarchy/team.json"
chmod 444 "$REPO_CFG"
cp "$REPO_CFG" "$SANDBOX/before"
rm_ untrack myrepo-architect --commit --keep-sessions --also-config --cwd "$PROJ"
chmod 644 "$REPO_CFG"
check "U3 untrack with an unwritable config file completes" '[ $RC = 0 ]'
check "U3 ... the team row is gone" '! grep -q "myrepo-architect" "$PROJ/.claude/hierarchy/team.json"'
check "U3 ... the config file's bytes are unchanged" 'cmp -s "$REPO_CFG" "$SANDBOX/before"'
check "U3 ... its output shows the member not removed, with the reason" '[ "$(jget o.config.removed)" = false ] && [[ "$(jget o.config.reason)" == "$REPO_CFG could not be written ("* ]] && [[ "$ERR" == *"could not be written"* ]]'

# dismiss --close --also-config: the pane closes and the row goes; the config file stays.
NODE_DIR="$(dirname "$(command -v node)")"
mkdir -p "$SANDBOX/closebin"
printf '#!/bin/sh\n[ "$1" = "kill-pane" ] && exit 0\n[ "$1" = "list-panes" ] && exit 0\nexit 1\n' > "$SANDBOX/closebin/tmux"; chmod +x "$SANDBOX/closebin/tmux"
# <roster.mjs flags for the close> : dismisses hotfix-implementor through its plan's close token.
dismiss_close() {
  mkdir -p "$PROJ/.claude/hierarchy/teams"
  printf '{"version":1,"team_id":"T-hotfix","created":"2026-01-01T00:00:00Z","roster_level":"repo","transport":"tmux","orchestrator":{"session_id":null,"pid":%s},"members":[{"role":"implementor","name":"hotfix-implementor","route":"peer","transport_id":"%%9"},{"role":"reviewer","name":"hotfix-reviewer","route":"peer","transport_id":"%%8"}],"partial":false,"roster":"hotfix"}' $$ > "$PROJ/.claude/hierarchy/teams/hotfix.json"
  TOK=$(env -u HERDR_ENV PATH="$SANDBOX/closebin:$NODE_DIR" HOME="$FAKEHOME" node "$H/roster.mjs" dismiss hotfix-implementor --team hotfix --cwd "$PROJ" 2>/dev/null | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{process.stdout.write(JSON.parse(s).close_token||"")}catch{}})')
  OUT=$(env -u HERDR_ENV PATH="$SANDBOX/closebin:$NODE_DIR" HOME="$FAKEHOME" node "$H/roster.mjs" dismiss hotfix-implementor --close --confirm --plan-token "$TOK" --also-config "$@" --team hotfix --cwd "$PROJ" 2>"$SANDBOX/err"); RC=$?
  ERR=$(cat "$SANDBOX/err")
}
fresh
spoil "$REPO_CFG" trunc
cp "$REPO_CFG" "$SANDBOX/before"
dismiss_close --level repo
check "U3 dismiss --close --also-config on an unparsable config file completes" '[ -n "$TOK" ] && [ $RC = 0 ] && [ "$(jget o.closed)" = true ]'
check "U3 ... the team row is gone" '! grep -q "hotfix-implementor" "$PROJ/.claude/hierarchy/teams/hotfix.json"'
check "U3 ... the config file's bytes are unchanged" 'cmp -s "$REPO_CFG" "$SANDBOX/before"'
check "U3 ... stderr names the path" '[[ "$ERR" == *"$REPO_CFG"* ]]'
check "U3 ... its output shows the member not removed, with the reason" '[ "$(jget o.config.removed)" = false ] && [[ "$(jget o.config.reason)" == "$REPO_CFG is not valid JSON ("* ]]'

fresh
rm -f "$REPO_CFG"
spoil "$REPO_USER_CFG" trunc
cp "$REPO_USER_CFG" "$SANDBOX/before"
dismiss_close
check "U3 dismiss with no level resolving completes" '[ -n "$TOK" ] && [ $RC = 0 ] && [ "$(jget o.closed)" = true ]'
check "U3 ... the team row is gone" '! grep -q "hotfix-implementor" "$PROJ/.claude/hierarchy/teams/hotfix.json"'
check "U3 ... the config file's bytes are unchanged" 'cmp -s "$REPO_USER_CFG" "$SANDBOX/before"'
check "U3 ... the warning gives the reason and names the skipped file" '[[ "$ERR" == *"no roster resolves at any level ($REPO_USER_CFG is not valid JSON ("* ]]'
check "U3 ... its output shows the member not removed, with the reason" '[ "$(jget o.config.removed)" = false ] && [[ "$(jget o.config.reason)" == "no roster resolves at any level"* ]]'

# ---------------------------------------------------------------- U4 reads unchanged
fresh
rm_ show --level repo-user --cwd "$PROJ"
MISSING_OUT=$OUT
spoil "$REPO_USER_CFG" trunc
rm_ show --level repo-user --cwd "$PROJ"
check "U4 show --level on an unparsable file prints what it prints for a missing one" '[ $RC = 0 ] && [ -n "$OUT" ] && [ "$OUT" = "$MISSING_OUT" ]'
rm_ show --cwd "$PROJ"
check "U4 show with no --level still runs" '[ $RC = 0 ]'

echo
echo "SUMMARY: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
