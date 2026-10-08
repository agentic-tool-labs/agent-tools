#!/bin/bash
# agent-hierarchy — role packs: plugins that carry ah-roles.json, adopted one role at a time with
# `role set --from`, pinned over the whole plugin tree, re-trusted with `role trust`, inspected with
# `pack list|show`, gated at commit, and kept out of pipeline gate slots and bypassPermissions.
# HOME-redirected with a fake installed_plugins.json pointing at sandbox plugin dirs.
# Usage: bash tests/test-role-packs.sh   (exits 0 iff all cases pass)

. "$(dirname "$0")/lib-hermetic.sh"
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
# Every Claude session exports some of these; a test must not inherit any of them.
unset AH_TEAM_FILE CLAUDE_PID AH_ROSTER AGENT_HIERARCHY_DIR
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-role-packs-test.XXXXXX")"
[ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] || { echo "mktemp failed"; exit 1; }
hermetic_on_exit 'rm -rf "$SANDBOX"'
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
# No test may reach the real herdr or tmux: a stub that fails every call sits first on PATH (a failing herdr or tmux is what a
# machine without a running multiplexer gives), and the guard in lib-hermetic.sh is told it is a fake.
mkdir -p "$SANDBOX/nolaunch"; printf '#!/bin/sh\nexit 1\n' > "$SANDBOX/nolaunch/herdr"; cp "$SANDBOX/nolaunch/herdr" "$SANDBOX/nolaunch/tmux"; chmod +x "$SANDBOX/nolaunch/herdr" "$SANDBOX/nolaunch/tmux"
export PATH="$SANDBOX/nolaunch:$PATH"; export AH_TEST_FAKE_BIN="$SANDBOX/nolaunch"
FAKEHOME="$SANDBOX/home"
PROJ="$SANDBOX/proj"
PACKS="$SANDBOX/packs"
GLOBAL_CFG="$FAKEHOME/.claude/agent-hierarchy.json"
REPO_CFG="$PROJ/.claude/agent-hierarchy.json"
IPJ="$FAKEHOME/.claude/plugins/installed_plugins.json"
TRUSTED="$FAKEHOME/.claude/agent-hierarchy/trusted"
LINE="takes work in unattended /ah:pipeline runs (pushes draft PRs, does not merge)"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:300} ERR=${ERR:0:300})"; fi
}

# roster.mjs with HOME redirected, in PROJ: stdout in OUT, stderr in ERR.
rm_() {
  OUT=$(HOME="$FAKEHOME" node "$H/roster.mjs" "$@" --cwd "$PROJ" 2>"$SANDBOX/err"); RC=$?
  ERR=$(cat "$SANDBOX/err")
}
# <js expression over the parsed OUT o>: its value (strings bare, anything else as JSON).
jget() {
  node -e 'const o=JSON.parse(process.argv[1]);const v=(new Function("o","return ("+process.argv[2]+")"))(o);process.stdout.write(typeof v==="string"?v:JSON.stringify(v))' "$OUT" "$1" 2>/dev/null
}
# <file> <js expression over the parsed file d>: true when the expression is.
filejs() {
  node -e 'const d=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.exit((new Function("d","return ("+process.argv[2]+")"))(d)?0:1)' "$1" "$2" 2>/dev/null
}
# <file> <js statement over the parsed file d>: edits a JSON file, creating it when missing.
mutate() {
  mkdir -p "$(dirname "$1")"
  node -e 'const fs=require("fs");const f=process.argv[1];const d=fs.existsSync(f)?JSON.parse(fs.readFileSync(f,"utf8")):{};(new Function("d",process.argv[2]))(d);fs.writeFileSync(f,JSON.stringify(d,null,2)+"\n")' "$1" "$2"
}
# <json of records keyed plugin@marketplace → [install dir, ...]>: the fake installed_plugins.json.
installed() {
  mkdir -p "$(dirname "$IPJ")"
  node -e 'const m=JSON.parse(process.argv[1]);const plugins={};for(const[k,dirs]of Object.entries(m))plugins[k]=dirs.map((d,i)=>({scope:"user",installPath:d,version:"1.0."+i}));require("fs").writeFileSync(process.argv[2],JSON.stringify({version:2,plugins},null,2))' "$1" "$IPJ"
}

# <dir> <plugin name>: a pack with an implement role (pk-impl), a review role (pk-rev), a design
# role (pk-des), a hook, a script and one agent the manifest doesn't name.
mkpack() {
  local d=$1 p=$2
  mkdir -p "$d/.claude-plugin" "$d/agents" "$d/hooks" "$d/bin"
  printf '{"name":"%s","version":"1.0.0","description":"test pack"}\n' "$p" > "$d/.claude-plugin/plugin.json"
  printf -- '---\nname: pk-impl\ndescription: Builds pack things\nmodel: opus\ntools: Read, Grep, Edit, Write, Bash, SendMessage\n---\nYou build pack features.\n' > "$d/agents/pk-impl.md"
  printf -- '---\nname: pk-rev\ndescription: Reviews pack things\nmodel: opus\ntools: Read, Grep, Bash, SendMessage\n---\nYou review pack changes.\n' > "$d/agents/pk-rev.md"
  printf -- '---\nname: pk-des\ndescription: Designs pack things\nmodel: opus\ntools: Read, Grep, Write, SendMessage\n---\nYou design pack features.\n' > "$d/agents/pk-des.md"
  printf -- '---\nname: pk-leg\ndescription: Runs pack errands\nmodel: haiku\ntools: Read, Grep, Bash\n---\nYou run pack errands.\n' > "$d/agents/pk-leg.md"
  printf -- '---\nname: pk-extra\ndescription: not a role\ntools: Read\n---\nExtra.\n' > "$d/agents/pk-extra.md"
  cat > "$d/ah-roles.json" <<'J'
{
  "version": 1,
  "roles": {
    "pk-impl": { "class": "implement", "description": "Builds pack features", "routes": "pack scenes and scripts", "model": "opus" },
    "pk-rev": { "class": "review", "description": "Reviews pack changes", "model": "opus" },
    "pk-des": { "class": "design", "description": "Designs pack features", "model": "opus" },
    "pk-leg": { "class": "legwork", "description": "Runs pack errands", "model": "haiku" }
  }
}
J
  echo '{}' > "$d/hooks/hooks.json"
  printf '#!/bin/sh\necho hi\n' > "$d/bin/tool.sh"
}

# A fresh HOME and repo, with pack `pk` installed from marketplace `mk` at $PACKS/a.
fresh() {
  rm -rf "$FAKEHOME" "$PROJ" "$PACKS"
  mkdir -p "$FAKEHOME/.claude" "$PROJ/.claude" "$PACKS"
  git -C "$PROJ" init -q
  mkpack "$PACKS/a" pk
  installed "{\"pk@mk\":[\"$PACKS/a\"]}"
}

# <name> <from> [flags…]: adopt through the dry run's pin; the pin lands in PIN.
adopt() {
  local name=$1 from=$2; shift 2
  rm_ role set "$name" --from "$from" --dry-run "$@"
  PIN=$(jget o.pin)
  rm_ role set "$name" --from "$from" --pin "$PIN" "$@"
}

# The role list row of <name> as JSON, in OUT.
rolerow() { rm_ role list --json; OUT=$(node -e 'const o=JSON.parse(process.argv[1]);process.stdout.write(JSON.stringify(o.roles.find(r=>r.name===process.argv[2])||o.excluded.find(r=>r.name===process.argv[2])||null))' "$OUT" "$1"); }

# SessionStart's injected context, in OUT.
sessionstart() {
  OUT=$(printf '%s' '{"session_id":"rp","cwd":"'"$PROJ"'","hook_event_name":"SessionStart","source":"startup"}' | HOME="$FAKEHOME" node "$H/sessionstart.mjs" 2>&1); RC=$?
}

# A roster.mjs PreToolUse payload through the skill gate: <command> [json fields to add]; output in OUT.
gate() {
  OUT=$(node -e 'const p={session_id:"g1",cwd:process.argv[1],tool_name:"Bash",tool_input:{command:process.argv[2]},...JSON.parse(process.argv[3]||"{}")};process.stdout.write(JSON.stringify(p))' "$PROJ" "$1" "${2:-}" | HOME="$FAKEHOME" node "$H/pretooluse-roster-skill-gate.mjs" 2>&1); RC=$?
}
decision() { node -e 'try{const o=JSON.parse(process.argv[1]);process.stdout.write(o.hookSpecificOutput.permissionDecision)}catch{process.stdout.write("none")}' "$OUT"; }

# An open pipeline-run anchor exchange in PROJ's hierarchy dir.
anchor() {
  HOME="$FAKEHOME" node "$H/msg.mjs" new --type request --to orchestrator --from orchestrator --slug pipeline-run-anchor --cwd "$PROJ" >/dev/null 2>&1
}

# ================================================================ P1 pack list
fresh
mkdir -p "$PACKS/plain/.claude-plugin" "$PACKS/plain/agents"
echo '{"name":"plain","version":"2.0.0"}' > "$PACKS/plain/.claude-plugin/plugin.json"
installed "{\"pk@mk\":[\"$PACKS/a\"],\"plain@mk\":[\"$PACKS/plain\"]}"
rm_ pack list --json
check "P1 pack list finds the plugin with ah-roles.json and skips the one without" \
  '[ $RC = 0 ] && [ "$(jget "o.packs.map(p => p.plugin + \"@\" + p.marketplace + \":\" + p.version).join()")" = "pk@mk:1.0.0" ] && [ "$(jget "o.packs[0].roles.map(r => r.name + \"/\" + r.class).join()")" = "pk-impl/implement,pk-rev/review,pk-des/design,pk-leg/legwork" ]'
check "P1 ... and counts what else the plugin carries" '[ "$(jget "o.packs[0].also_in_plugin")" = 3 ]'

# ================================================================ P2 manifest and text checks
bad() { # <dir> <js edit of the manifest object m>: a copy of pack a with its manifest edited
  rm -rf "$1"; cp -R "$PACKS/a" "$1"
  node -e 'const fs=require("fs");const f=process.argv[1];const m=JSON.parse(fs.readFileSync(f,"utf8"));(new Function("m",process.argv[2]))(m);fs.writeFileSync(f,JSON.stringify(m,null,2))' "$1/ah-roles.json" "$2"
}
showpath() { rm_ pack show --path "$1" --json; }
roleerr() { jget "(o.roles.find(r => r.name === \"$1\") || {findings: []}).findings.map(f => f.code).join()"; }
fresh
bad "$PACKS/v2" 'm.version = 2'
showpath "$PACKS/v2"
check "P2 version other than 1 makes the whole pack unreadable (pack-version)" '[ $RC = 0 ] && [ "$(jget o.manifest.error.code)" = pack-version ] && [ "$(jget o.roles.length)" = 0 ]'
bad "$PACKS/names" 'm.roles["Bad Name"] = {class: "implement"}; m.roles["reviewer"] = {class: "review"}'
showpath "$PACKS/names"
check "P2 a bad role name and a built-in role name are refused" '[ "$(roleerr "Bad Name")" = pack-invalid ] && [ "$(roleerr reviewer)" = pack-invalid ]'
bad "$PACKS/agents" 'm.roles["pk-impl"].agent = "other:pk-impl"; m.roles["pk-rev"].agent = "../pk-rev"; m.roles["pk-des"].agent = "sub/pk-des"'
showpath "$PACKS/agents"
check "P2 an agent containing :, .. or / is refused" '[ "$(roleerr pk-impl)" = pack-invalid ] && [ "$(roleerr pk-rev)" = pack-invalid ] && [ "$(roleerr pk-des)" = pack-invalid ]'
bad "$PACKS/fields" 'm.roles["pk-impl"].description = "x".repeat(161); m.roles["pk-rev"].description = "two\nlines"; m.roles["pk-des"].routes = "has `tick`"'
showpath "$PACKS/fields"
check "P2 a field over 160 characters, with a newline or with a backtick is refused" '[ "$(roleerr pk-impl)" = pack-invalid ] && [ "$(roleerr pk-rev)" = pack-invalid ] && [ "$(roleerr pk-des)" = pack-invalid ]'
bad "$PACKS/unknown" 'm.roles["pk-impl"].color = "red"; m.extra = 1'
showpath "$PACKS/unknown"
check "P2 an unknown key warns" '[ "$(roleerr pk-impl)" != pack-invalid ] && [[ "$(jget "o.roles[0].warnings.join()")" == *"unknown key \"color\""* ]] && [[ "$(jget "o.manifest.warnings.join()")" == *"unknown key \"extra\""* ]]'
bad "$PACKS/hidden" 'm.roles["pk-impl"].description = "safe\u202Eevil"; m.roles["pk-rev"].routes = "tag\u{E0041}char"'
printf -- '---\nname: pk-des\ndescription: Designs\xe2\x80\x8b things\nmodel: opus\ntools: Read, Grep, Write, SendMessage\n---\nBody.\n' > "$PACKS/hidden/agents/pk-des.md"
showpath "$PACKS/hidden"
check "P2 pack-hidden-chars: a bidi control and a tag character in a field, a zero-width character in the agent file" \
  '[ "$(roleerr pk-impl)" = pack-hidden-chars ] && [ "$(roleerr pk-rev)" = pack-hidden-chars ] && [[ "$(roleerr pk-des)" == *pack-hidden-chars* ]]'
bad "$PACKS/hidden2" 'm.roles["pk-impl"].description = "sel\uFE00\uFE01\uFE0Fend"; m.roles["pk-rev"].routes = "line\u2028sep"; m.roles["pk-des"].description = "fill\u3164er"; m.roles["pk-leg"].description = "warn ⚠\uFE0F sign"'
node -e 'const fs=require("fs");const f=process.argv[1];fs.writeFileSync(f,fs.readFileSync(f,"utf8").replace("You review pack changes.","abc\u{E0100}def"))' "$PACKS/hidden2/agents/pk-extra.md"
node -e 'const fs=require("fs");const f=process.argv[1];fs.writeFileSync(f,"---\nname: pk-extra\ndescription: not a role\ntools: Read\n---\nabc\u{E0100}def\n")' "$PACKS/hidden2/agents/pk-extra.md"
showpath "$PACKS/hidden2"
check "P2 pack-hidden-chars: variation selectors, U+2028, the U+3164 filler and an emoji written with U+FE0F in fields" \
  '[ "$(roleerr pk-impl)" = pack-hidden-chars ] && [ "$(roleerr pk-rev)" = pack-hidden-chars ] && [ "$(roleerr pk-des)" = pack-hidden-chars ] && [ "$(roleerr pk-leg)" = pack-hidden-chars ]'
check "P2 ... and the finding names the code point, line and column" '[[ "$(jget "o.roles.find(r => r.name === \"pk-impl\").findings[0].message")" == *"U+FE00 at line 1, column 4"* ]]'
bad "$PACKS/hidden4" 'm.roles["pk-impl"].description = "braille\u2800blank"'
showpath "$PACKS/hidden4"
check "P2 pack-hidden-chars: the U+2800 braille blank in a field" '[ "$(roleerr pk-impl)" = pack-hidden-chars ]'
rm -rf "$PACKS/hidden3"; cp -R "$PACKS/a" "$PACKS/hidden3"
node -e 'const fs=require("fs");fs.writeFileSync(process.argv[1],"---\nname: pk-rev\ndescription: Reviews\nmodel: opus\ntools: Read, Grep, SendMessage\n---\nabc\u{E0100}def\n")' "$PACKS/hidden3/agents/pk-rev.md"
showpath "$PACKS/hidden3"
check "P2 a U+E0100 variation selector in the agent file is refused, at line 7, column 4" \
  '[[ "$(roleerr pk-rev)" == *pack-hidden-chars* ]] && [[ "$(jget "o.roles.find(r => r.name === \"pk-rev\").findings.map(f => f.message).join()")" == *"U+E0100 at line 7, column 4"* ]]'
rm -rf "$PACKS/utf"; cp -R "$PACKS/a" "$PACKS/utf"; printf -- '---\nname: pk-impl\ndescription: bad \xff byte\nmodel: opus\ntools: Read, Edit, Write, Bash, SendMessage\n---\nBody.\n' > "$PACKS/utf/agents/pk-impl.md"
installed "{\"pk@mk\":[\"$PACKS/utf\"]}"
rm_ role set u1 --from pk@mk:pk-impl --dry-run
check "P2 a non-UTF-8 agent file is refused" '[ $RC = 2 ] && [[ "$ERR" == *"not valid UTF-8"* ]]'
installed "{\"pk@mk\":[\"$PACKS/a\"]}"
bad "$PACKS/ansi" 'm.roles["pk-impl"].description = "red \u001b[31mALERT\u001b[0m end"'
rm_ pack show --path "$PACKS/ansi"
check "P2 an ANSI sequence in a field prints escaped" '[ $RC = 0 ] && [[ "$OUT" == *"\\u{1b}[31mALERT"* ]] && ! printf "%s" "$OUT" | grep -q $'"'"'\x1b'"'"''
rawctl() { printf "%s" "$OUT" | LC_ALL=C grep -q $'"'"'\x1b\|\xc2\x9b'"'"'; } # a raw ESC or C1 CSI in OUT
rm -rf "$PACKS/pj"; cp -R "$PACKS/a" "$PACKS/pj"
node -e 'require("fs").writeFileSync(process.argv[1], JSON.stringify({name: "pk\u009b31m", version: "1.0\u001b[31m\u009b0m"}))' "$PACKS/pj/.claude-plugin/plugin.json"
rm_ pack show --path "$PACKS/pj"
check "P2 plugin.json's name and version print escaped in pack show (text)" '[ $RC = 0 ] && ! rawctl && [[ "$OUT" == *"pk\\u{9b}31m"* ]] && [[ "$OUT" == *"1.0\\u{1b}[31m"* ]]'
rm_ pack show --path "$PACKS/pj" --json
check "P2 ... and in pack show --json" '[ $RC = 0 ] && ! rawctl && [ "$(jget o.plugin)" = "pk\\u{9b}31m" ]'
installed "{\"pk@mk\":[\"$PACKS/pj\"]}"
rm_ pack list
check "P2 ... and in pack list (text)" '[ $RC = 0 ] && ! rawctl && [[ "$OUT" == *"1.0\\u{1b}[31m\\u{9b}0m"* ]]'
rm_ pack list --json
check "P2 ... and in pack list --json" '[ $RC = 0 ] && ! rawctl && [ "$(jget "o.packs[0].version")" = "1.0\\u{1b}[31m\\u{9b}0m" ]'
installed "{\"pk@mk\":[\"$PACKS/a\"]}"

# ================================================================ P3 role set --from
fresh
rm_ role set impl --from pk@mk:pk-impl --dry-run
DRY_PIN=$(jget o.pin)
check "P3 the dry run prints the pack's fields verbatim, and the pin" \
  '[ $RC = 0 ] && [ "$(jget o.pack.fields.description)" = "Builds pack features" ] && [ "$(jget o.pack.fields.routes)" = "pack scenes and scripts" ] && [[ "$DRY_PIN" =~ ^sha256:[0-9a-f]{64}$ ]]'
check "P3 an implement-class role with routes: the dry run prints the unattended-runs line" '[ "$(jget o.pack.unattended)" = "$LINE" ] && [[ "$ERR" == *"$LINE"* ]]'
rm_ role set rev --from pk@mk:pk-rev --dry-run
check "P3 ... and a role without that shape doesn't" '[ $RC = 0 ] && [ "$(jget "\"unattended\" in o.pack")" = false ]'
rm_ role set impl --from pk@mk:pk-impl
check "P3 a commit with no --pin is refused" '[ $RC = 2 ] && [[ "$ERR" == *"needs --pin"* ]] && [ ! -e "$GLOBAL_CFG" ]'
rm_ role set impl --from pk@mk:pk-impl --pin "sha256:$(printf '0%.0s' {1..64})"
check "P3 a commit with a stale pin is refused" '[ $RC = 2 ] && [[ "$ERR" == *"doesn'"'"'t match"* ]] && [ ! -e "$GLOBAL_CFG" ]'
rm_ role set impl --from pk@mk:pk-impl --pin "$DRY_PIN" --model sonnet
check "P3 a commit with the printed pin writes only from, pin and the flags passed" \
  '[ $RC = 0 ] && filejs "$GLOBAL_CFG" "JSON.stringify(Object.keys(d.roles.impl).sort()) === JSON.stringify([\"from\",\"model\",\"pin\"]) && d.roles.impl.from === \"pk@mk:pk-impl\" && d.roles.impl.pin === \"$DRY_PIN\""'
rolerow impl
check "P3 resolution yields the manifest's class and <plugin>:<agent>, and the role is trusted" \
  '[ "$(jget "o.class + \"/\" + o.agent + \"/\" + o.model + \"/\" + o.pin_state + \"/\" + o.from")" = "implement/pk:pk-impl/sonnet/trusted/pk@mk:pk-impl" ]'
rm_ role set impl2 --from pk:pk-rev --dry-run
check "P3 <plugin>:<role> expands when exactly one marketplace offers the plugin" '[ $RC = 0 ] && [ "$(jget o.from)" = "pk@mk:pk-rev" ]'
installed "{\"pk@mk\":[\"$PACKS/a\"],\"pk@mk2\":[\"$PACKS/a\"]}"
rm_ role set impl2 --from pk:pk-rev --dry-run
check "P3 ... and is refused when two do" '[ $RC = 2 ] && [[ "$ERR" == *"2 marketplaces"* ]]'

# ================================================================ P4 names and flags
fresh
adopt localname pk@mk:pk-rev
check "P4 a local name different from the pack's works" '[ $RC = 0 ] && filejs "$GLOBAL_CFG" "d.roles.localname.from === \"pk@mk:pk-rev\""'
mkdir -p "$FAKEHOME/.claude/agents"; printf -- '---\nname: taken\ndescription: mine\ntools: Read, Grep, SendMessage\n---\nMine.\n' > "$FAKEHOME/.claude/agents/taken.md"
rm_ role set taken --class review --description "my own" --level global
rm_ role set taken --from pk@mk:pk-rev --dry-run
check "P4 a name already defined at the target level is refused" '[ $RC = 2 ] && [[ "$ERR" == *"pick another name or remove it first"* ]]'
for flag in "--class review" "--agent x" "--scaffold user"; do
  rm_ role set other --from pk@mk:pk-rev --dry-run $flag
  check "P4 $flag with --from is refused" '[ $RC = 2 ] && [[ "$ERR" == *"can'"'"'t be used with --from"* ]]'
done
rm_ role set localname --class review
check "P4 --class on a row that has from is refused" '[ $RC = 2 ] && [[ "$ERR" == *"adopted from a pack"* ]]'

# ================================================================ P5 a built-in via --from
fresh
rm_ role set reviewer --from pk@mk:pk-impl --dry-run
check "P5 a built-in adopted from a pack role of another class is refused" '[ $RC = 2 ] && [[ "$ERR" == *"only of its own class"* ]]'
adopt reviewer pk@mk:pk-rev
check "P5 a matching class overrides the built-in's agent, and is pinned" \
  '[ $RC = 0 ] && filejs "$GLOBAL_CFG" "d.roles.reviewer.from === \"pk@mk:pk-rev\" && /^sha256:/.test(d.roles.reviewer.pin) && !(\"agent\" in d.roles.reviewer)"'
rolerow reviewer
check "P5 role list shows the override, pinned and trusted" '[ "$(jget "o.agent + \"/\" + o.pack_override + \"/\" + o.pin_state")" = "pk:pk-rev/true/trusted" ]'
rm_ role remove reviewer
check "P5 role remove restores the shipped agent" '[ $RC = 0 ] && ! filejs "$GLOBAL_CFG" "\"reviewer\" in (d.roles || {})"'

# ================================================================ P6 the pin covers the tree
fresh
cp -R "$PACKS/a" "$PACKS/pristine"
adopt gd pk@mk:pk-impl
AGENT_SUM=$(shasum "$PACKS/a/agents/pk-impl.md" | cut -d' ' -f1)
sessionstart
check "P6 (baseline) a trusted role routes at SessionStart" '[[ "$OUT" == *"for \\\"pack scenes and scripts\\\""* ]]'
restore() { rm -rf "$PACKS/a"; cp -R "$PACKS/pristine" "$PACKS/a"; }
p6() { # <label> <shell edit of $PACKS/a>
  restore; eval "$2"
  rolerow gd
  local state; state=$(jget o.pin_state)
  sessionstart; local routed=no; [[ "$OUT" == *"for \\\"pack scenes and scripts\\\""* ]] && routed=yes
  rm_ spawn-ad-hoc gd --model opus --route peer --auto-mode auto --dry-run --orchestrator-pid $$
  local spawnrc=$RC
  check "P6 $1: pack-changed in role list, out of SessionStart's routing, spawn refused, agent file untouched" \
    '[ "$state" = pack-changed ] && [ $routed = no ] && [ $spawnrc != 0 ] && [ "$(shasum "$PACKS/a/agents/pk-impl.md" | cut -d" " -f1)" = "$AGENT_SUM" ]'
}
p6 "one byte of a hook file" 'printf "{ }\n" > "$PACKS/a/hooks/hooks.json"'
p6 "a script under bin/" 'printf "#!/bin/sh\necho bye\n" > "$PACKS/a/bin/tool.sh"'
p6 "an added file" 'echo new > "$PACKS/a/NOTES.txt"'
p6 "ah-roles.json reformatted" 'node -e "const f=process.argv[1];const fs=require(\"fs\");fs.writeFileSync(f,JSON.stringify(JSON.parse(fs.readFileSync(f,\"utf8\"))))" "$PACKS/a/ah-roles.json"'
p6 "another role's row changed" 'node -e "const f=process.argv[1];const fs=require(\"fs\");const m=JSON.parse(fs.readFileSync(f,\"utf8\"));m.roles[\"pk-rev\"].description=\"changed\";fs.writeFileSync(f,JSON.stringify(m,null,2))" "$PACKS/a/ah-roles.json"'
restore; mkdir -p "$PACKS/a/.git"; echo "ref" > "$PACKS/a/.git/HEAD"
rolerow gd
check "P6 changing only a file under .git/ keeps the role trusted" '[ "$(jget o.pin_state)" = trusted ]'
FX="$SANDBOX/fx"; mkdir -p "$FX/agents" "$FX/hooks" "$FX/.git"
printf '{"version":1,"roles":{"fx":{"class":"implement","routes":"fixture work"}}}\n' > "$FX/ah-roles.json"
printf -- '---\nname: fx\ndescription: fixture\ntools: Read, Edit, Bash, SendMessage\n---\nFixture body.\n' > "$FX/agents/fx.md"
printf '{}\n' > "$FX/hooks/h.json"; printf 'ref\n' > "$FX/.git/HEAD"
OUT=$(HOME="$FAKEHOME" node --input-type=module -e "
  import { readFileSync } from 'node:fs';
  const C = await import('$H/lib-config.mjs');
  const tree = C.packTree('$FX');
  process.stdout.write(C.packPin({ routes: 'fixture work', class: 'implement' }, readFileSync('$FX/agents/fx.md', 'utf8'), tree.files));
" 2>&1)
check "P6 a known fixture tree hashes to a fixed pin (the serialization is pinned)" '[ "$OUT" = "sha256:bff60701e7c140b5555aeeecfc7f8a7b4fe438e616f119e54ef895d164b0826c" ]'

# ================================================================ P7 role trust
fresh
adopt gd pk@mk:pk-impl --model sonnet
node -e 'const f=process.argv[1];const fs=require("fs");const m=JSON.parse(fs.readFileSync(f,"utf8"));m.roles["pk-impl"].description="Builds better pack features";fs.writeFileSync(f,JSON.stringify(m,null,2))' "$PACKS/a/ah-roles.json"
printf -- '---\nname: pk-impl\ndescription: Builds pack things\nmodel: opus\ntools: Read, Grep, Edit, Write, Bash, SendMessage\n---\nYou build pack features, carefully.\n' > "$PACKS/a/agents/pk-impl.md"
rm "$PACKS/a/bin/tool.sh"; echo added > "$PACKS/a/hooks/new.json"; echo '{"x":1}' > "$PACKS/a/hooks/hooks.json"
rm_ role trust gd --dry-run
TRUST_PIN=$(jget o.pin)
check "P7 the dry run shows the field changes against the stored copy" \
  '[ $RC = 0 ] && [ "$(jget o.stored_copy)" = true ] && [ "$(jget "o.fields_changed.map(c => c.field + \"=\" + c.installed).join()")" = "description=Builds better pack features" ]'
check "P7 ... the agent file diff" '[[ "$(jget o.agent_diff)" == *"-You build pack features."* ]] && [[ "$(jget o.agent_diff)" == *"+You build pack features, carefully."* ]]'
check "P7 ... and the files added, removed and changed" \
  '[ "$(jget "o.files.added.join()")" = hooks/new.json ] && [ "$(jget "o.files.removed.join()")" = bin/tool.sh ] && [ "$(jget "o.files.changed.join()")" = "agents/pk-impl.md,ah-roles.json,hooks/hooks.json" ]'
rm_ role trust gd --pin "sha256:$(printf '1%.0s' {1..64})"
check "P7 a stale --pin is refused" '[ $RC = 2 ] && [[ "$ERR" == *"doesn'"'"'t match"* ]]'
rm_ role trust gd --pin "$TRUST_PIN"
check "P7 the commit re-pins and writes a stored copy" '[ $RC = 0 ] && filejs "$GLOBAL_CFG" "d.roles.gd.pin === \"$TRUST_PIN\"" && [ -e "$TRUSTED/${TRUST_PIN#sha256:}.json" ]'
check "P7 the user's own fields survive" 'filejs "$GLOBAL_CFG" "d.roles.gd.model === \"sonnet\" && JSON.stringify(Object.keys(d.roles.gd).sort()) === JSON.stringify([\"from\",\"model\",\"pin\"])"'
rolerow gd
check "P7 ... and the role is trusted again" '[ "$(jget o.pin_state)" = trusted ]'
rm -rf "$TRUSTED"
rm_ role trust gd --dry-run
check "P7 with no stored copy, it shows the whole agent file and the file list, and says so" \
  '[ $RC = 0 ] && [ "$(jget o.stored_copy)" = false ] && [[ "$(jget o.agent_text)" == *"carefully"* ]] && [[ "$(jget "o.files.all.join()")" == *"ah-roles.json"* ]] && [[ "$(jget o.note)" == *"no stored copy"* ]]'
printf -- '---\nname: pk-impl\ndescription: Builds pack things\nmodel: opus\ntools: Read, Grep, Edit, Write, Bash\n---\nNo SendMessage.\n' > "$PACKS/a/agents/pk-impl.md"
rm_ role trust gd --dry-run
ERR_PIN=$(jget o.pin)
rm_ role trust gd --pin "$ERR_PIN"
check "P7 it refuses while errors stand" '[ $RC = 2 ] && [[ "$ERR" == *"errors stand"* ]]'

# ================================================================ P8 frontmatter allowlist (pack agents)
fresh
fm() { # <label> <frontmatter lines (printf %b)>
  rm -rf "$PACKS/fm"; cp -R "$PACKS/a" "$PACKS/fm"
  printf -- "---\nname: pk-rev\ndescription: Reviews\nmodel: opus\n$2\n---\nBody.\n" > "$PACKS/fm/agents/pk-rev.md"
  showpath "$PACKS/fm"
  check "P8 $1 is an error" '[[ "$(roleerr pk-rev)" == *pack-agent* ]]'
}
fm "permissionMode" 'tools: Read, Grep, SendMessage\npermissionMode: acceptEdits'
fm "skills" 'tools: Read, Grep, SendMessage\nskills: [x]'
fm "memory" 'tools: Read, Grep, SendMessage\nmemory: user'
fm "a made-up key" 'tools: Read, Grep, SendMessage\nzorp: 1'
fm "a quoted \"permissionMode\": key" 'tools: Read, Grep, SendMessage\n"permissionMode": acceptEdits'
fm "a duplicate key" 'tools: Read, Grep, SendMessage\ntools: Read'
fm "an &anchor" 'tools: &t [Read, Grep, SendMessage]'
fm "an *alias" 'tools: Read, Grep, SendMessage\ncolor: *t'
fm "a <<: merge key" 'tools: Read, Grep, SendMessage\n<<: *base'
fm "a missing tools" 'color: red'
fm "tools with a wildcard" 'tools: Read, mcp__srv__*, SendMessage'
fm "a line that can't be classified" 'tools: Read, Grep, SendMessage\njust some text'
fm "a tools value folded onto a second line" 'tools: Read, Grep, SendMessage\n  Write, Bash'
fm "an indented line under a one-line value" 'tools: Read, Grep, SendMessage\ncolor: red\n  bad: indentation'
fm "a list item under a key that has a value" 'tools: Read, Grep, SendMessage\ncolor: red\n  - Bash'
fm "a tab in the indentation" 'tools:\n\t- Read\n\t- SendMessage'
fm "a # comment on its own line" 'tools: Read, Grep, SendMessage\n# a note'
fm "a # comment after a value" 'tools: Read, Grep, SendMessage\ncolor: red # a note'
fm "a quoted tool entry" 'tools: "Read", Grep, SendMessage'
fm "a [flow] tool list" 'tools: [Read, Grep, SendMessage]'
fm "an Agent(x) tool entry" 'tools: Read, Agent(x), SendMessage'
fm "a | block under tools" 'tools: |\n  Read, Grep, SendMessage'
fm "a - item list under a key other than tools" 'tools: Read, Grep, SendMessage\ncolor:\n  - red'
fm "a list item back at column 0 after indented ones" 'tools:\n  - Read\n  - Grep\n- SendMessage'
fm "a list item indented further than the first (YAML folds it into the item above)" 'tools:\n  - Read\n    - Grep\n  - SendMessage'
fm "a list item indented less than the first" 'tools:\n  - Read\n - Grep\n  - SendMessage'
fm "tools: null" 'tools: null'
fm "tools: True" 'tools: True'
fm "tools: yes" 'tools: yes'
fm "a - null tool item" 'tools:\n  - Read\n  - null\n  - SendMessage'
fm "a - ~ tool item" 'tools:\n  - Read\n  - ~\n  - SendMessage'
fm "an inline False tool entry" 'tools: Read, False, SendMessage'
fm "list items indented with U+00A0" 'tools:\n\xc2\xa0\xc2\xa0- Read\n\xc2\xa0\xc2\xa0- SendMessage'
fm "list items indented with U+3000" 'tools:\n\xe3\x80\x80- Read\n\xe3\x80\x80- SendMessage'
fm "U+00A0 after tools:" 'tools:\xc2\xa0Read, Grep, SendMessage'
fm "U+3000 after tools:" 'tools:\xe3\x80\x80Read, Grep, SendMessage'
fm "U+2003 in a tools entry" 'tools: Read,\xe2\x80\x83Grep, SendMessage'
fm "maxTurns: 1e3" 'tools: Read, Grep, SendMessage\nmaxTurns: 1e3'
fm "maxTurns: 0x10" 'tools: Read, Grep, SendMessage\nmaxTurns: 0x10'
fmd() { # <label> <description and other lines (printf %b)>: pk-rev with no fixed description
  rm -rf "$PACKS/fm"; cp -R "$PACKS/a" "$PACKS/fm"
  printf -- "---\nname: pk-rev\n$2\ntools: Read, Grep, SendMessage\n---\nBody.\n" > "$PACKS/fm/agents/pk-rev.md"
  showpath "$PACKS/fm"
  check "P8 $1 is an error" '[[ "$(roleerr pk-rev)" == *pack-agent-line* ]]'
}
fmd "\": \" in a plain value" 'description: Reviews code: carefully'
fmd "a plain value ending in \":\"" 'description: Reviews code:'
fmd "a | block whose second line is indented less than its first" 'description: |\n    first\n  second'
fmd "a plain value starting with @" 'description: @x'
fmd "a plain value starting with !" 'description: !x'
fmd "a plain value starting with ]" 'description: ]x'
fmd "a plain value starting with \"- \"" 'description: - x'
fmd "a double-quoted value with an escape" 'description: "a\\x41"'
fmd "a single-quoted value with ''" "description: 'it''s'"
fmd "a quoted value with text after it" 'description: "Reviews" code'
fmd "a quoted value that doesn't close" 'description: "Reviews code'
fmd "a plain value YAML reads as a boolean" 'description: yes'
fmd "a plain value YAML reads as null" 'description: ~'
rm -rf "$PACKS/fm"; cp -R "$PACKS/a" "$PACKS/fm"
printf -- '---\nname: pk-rev\ndescription: "yes"\nmodel: opus\ntools: Read, Grep, SendMessage, NotebookEdit, Nontool\nmaxTurns: 5\n---\nBody.\n' > "$PACKS/fm/agents/pk-rev.md"
showpath "$PACKS/fm"
check "P8 a quoted \"yes\", tool names that only start with no or n, and maxTurns: 5 are accepted" '[[ "$(roleerr pk-rev)" != *pack-agent* ]]'
printf -- '---\nname: false\ndescription: Reviews\nmodel: opus\ntools: Read, Grep, SendMessage\n---\nBody.\n' > "$PACKS/fm/agents/pk-rev.md"
showpath "$PACKS/fm"
check "P8 name: false is an error" '[[ "$(roleerr pk-rev)" == *pack-agent-line* ]]'
printf -- '---\nname: h\xc3\xa9lper\ndescription: Reviews\nmodel: opus\ntools: Read, Grep, SendMessage\n---\nBody.\n' > "$PACKS/fm/agents/pk-rev.md"
showpath "$PACKS/fm"
check "P8 name: hélper is an error, naming the code point, line and column" \
  '[[ "$(roleerr pk-rev)" == *pack-agent-line* ]] && [[ "$(jget "o.roles.find(r => r.name === \"pk-rev\").findings.map(f => f.message).join()")" == *"U+00E9 at line 2, column 8"* ]]'
fmd "U+2003 after model:" 'description: Reviews\nmodel:\xe2\x80\x83sonnet'
fmd "a tab after a colon" 'description: Reviews\nmodel:\topus'
fmd "a tab after a block line's indenting spaces" 'description: |\n  \tReviews'
fmd "U+00A0 in a description" 'description: Reviews\xc2\xa0code'
fmd "U+E000 in a description" 'description: Reviews \xee\x80\x80'
fmd "U+FFFF in a description" 'description: Reviews \xef\xbf\xbf'
fmd "U+00A0 after description:" 'description:\xc2\xa0Reviews'
for d in 'description: Caf\xc3\xa9 r\xc3\xa9sum\xc3\xa9' 'description: \xe3\x82\xb3\xe3\x83\xbc\xe3\x83\x89\xe3\x82\x92\xe7\xa2\xba\xe8\xaa\x8d\xe3\x81\x99\xe3\x82\x8b' 'description: >\n  R\xc3\xa9vise le code\n  tr\xc3\xa8s soigneusement'; do
  printf -- "---\nname: pk-rev\n$d\nmodel: opus\ntools: Read, Grep, SendMessage\n---\nBody.\n" > "$PACKS/fm/agents/pk-rev.md"
  showpath "$PACKS/fm"
  check "P8 a non-ASCII description is accepted: $(printf -- "$d" | head -1)" '[[ "$(roleerr pk-rev)" != *pack-agent* ]]'
done
rm -rf "$PACKS/fm"; cp -R "$PACKS/a" "$PACKS/fm"
printf -- "---\nname: pk-rev\ndescription: \"Reviews code: carefully\"\nmodel: 'opus'\ncolor: a:b\ntools: Read, Grep, SendMessage\n---\nBody.\n" > "$PACKS/fm/agents/pk-rev.md"
showpath "$PACKS/fm"
check "P8 a quoted value holding \": \", a single-quoted one and a:b are accepted" '[[ "$(roleerr pk-rev)" != *pack-agent* ]]'
printf -- '---\nname: pk-rev\ndescription: |\n  first\n    indented more\n\n  last\nmodel: opus\ntools: Read, Grep, SendMessage\n---\nBody.\n' > "$PACKS/fm/agents/pk-rev.md"
showpath "$PACKS/fm"
check "P8 a | block line indented more than the first is accepted" '[[ "$(roleerr pk-rev)" != *pack-agent* ]]'
rm -rf "$PACKS/fm"; cp -R "$PACKS/a" "$PACKS/fm"
printf -- '---\nname: pk-rev\ndescription: >\n  Reviews pack\n  changes carefully.\nmodel: opus\ntools:\n- Read\n- Grep\n- SendMessage\n---\nBody.\n' > "$PACKS/fm/agents/pk-rev.md"
showpath "$PACKS/fm"
check "P8 a block list and a > block scalar are allowed" '[[ "$(roleerr pk-rev)" != *pack-agent* ]] && [ "$(jget "o.roles.find(r => r.name === \"pk-rev\").tools.effective.join()")" = "Read,Grep,SendMessage" ]'
printf -- '---\nname: pk-rev\ndescription: |\n  Reviews pack\n  changes.\nmodel: opus\ntools:\n  - Read\n  - Grep\n---\nBody.\n' > "$PACKS/fm/agents/pk-rev.md"
showpath "$PACKS/fm"
check "P8 a | block scalar is allowed, and the tools shown are the ones the contract judges" \
  '[[ "$(roleerr pk-rev)" != *pack-agent* ]] && [ "$(jget "o.roles.find(r => r.name === \"pk-rev\").tools.effective.join()")" = "Read,Grep" ] && [[ "$(roleerr pk-rev)" == *"missing-tool:SendMessage"* ]]'
printf -- '---\nname: pk-rev\ndescription: Reviews\nmodel: opus\ntools:\n  - Read\n  - Grep\n  # - Bash\n  - SendMessage\n---\nBody.\n' > "$PACKS/fm/agents/pk-rev.md"
showpath "$PACKS/fm"
check "P8 a refused file shows the tools the strict read found, the list the contract judged" \
  '[[ "$(roleerr pk-rev)" == *pack-agent-line* ]] && [ "$(jget "o.roles.find(r => r.name === \"pk-rev\").tools.effective.join()")" = "Read,Grep,SendMessage" ]'
installed "{\"pk@mk\":[\"$PACKS/fm\"]}"
rm_ role set fc --from pk@mk:pk-rev --dry-run
check "P8 ... and so does the adoption dry run" '[ "$(jget "o.pack.tools.effective.join()")" = "Read,Grep,SendMessage" ]'
installed "{\"pk@mk\":[\"$PACKS/a\"]}"
rm -rf "$PACKS/fm"; cp -R "$PACKS/a" "$PACKS/fm"
printf -- '---\nname: pk-impl\ndescription: Builds\nmodel: opus\ntools: Read, Edit, Write, Bash, Agent, mcp__srv__run, SendMessage\n---\nBody.\n' > "$PACKS/fm/agents/pk-impl.md"
showpath "$PACKS/fm"
check "P8 the tools shown flag Bash, Agent, mcp__*, Write and Edit" '[ "$(jget "o.roles.find(r => r.name === \"pk-impl\").tools.flagged.join()")" = "Edit,Write,Bash,Agent,mcp__srv__run" ]'
installed "{\"pk@mk\":[\"$PACKS/fm\"]}"
rm_ role set fl --from pk@mk:pk-impl --dry-run
check "P8 ... and so does the adoption dry run" '[ $RC = 0 ] && [ "$(jget "o.pack.tools.flagged.join()")" = "Edit,Write,Bash,Agent,mcp__srv__run" ]'
installed "{\"pk@mk\":[\"$PACKS/a\"]}"
mkdir -p "$FAKEHOME/.claude/agents"
printf -- '---\nname: own-rev\ndescription: my own reviewer\npermissionMode: acceptEdits\n"hooks": x\ntools: Read, Grep, SendMessage\n---\nMine.\n' > "$FAKEHOME/.claude/agents/own-rev.md"
rm_ role set own-rev --class review --level global
rolerow own-rev
check "P8 the same keys in a user's own bare-name file behave as today" \
  '[[ "$(jget o.status)" != UNAVAILABLE* ]] && [ "$(jget "o.findings.some(f => f.code.startsWith(\"pack\"))")" = false ] && [ "$(jget "\"from\" in o")" = false ]'

# ================================================================ P9 an uninstalled plugin
fresh
adopt gd pk@mk:pk-impl
installed '{}'
rolerow gd
check "P9 with its record removed, the role is pack-missing" '[ "$(jget o.pin_state)" = pack-missing ] && [[ "$(jget o.status)" == UNAVAILABLE* ]]'
rm_ role remove gd
check "P9 ... and role remove still works" '[ $RC = 0 ] && ! filejs "$GLOBAL_CFG" "\"gd\" in (d.roles || {})"'
fresh
adopt gd pk@mk:pk-impl
installed "{\"pk@other\":[\"$PACKS/a\"]}"
rolerow gd
check "P9 the plugin installed only from another marketplace is pack-missing, never a stand-in" '[ "$(jget o.pin_state)" = pack-missing ]'

# ================================================================ P10 pack show --path
fresh
rm -rf "$PACKS/new"; cp -R "$PACKS/a" "$PACKS/new"
mkdir -p "$PACKS/new/commands"; echo '{}' > "$PACKS/new/.mcp.json"; echo 'x' > "$PACKS/new/commands/go.md"
showpath "$PACKS/new"
check "P10 pack show --path on an uninstalled dir lists the roles" '[ $RC = 0 ] && [ "$(jget o.installed)" = false ] && [ "$(jget "o.roles.map(r => r.name).join()")" = "pk-impl,pk-rev,pk-des,pk-leg" ]'
check "P10 ... and also: the hooks dir, .mcp.json, commands/ and an agent not in the manifest" \
  '[ "$(jget "o.also_in_plugin.map(e => e.kind + \":\" + e.name).join()")" = "root:.mcp.json,root:bin,root:commands,root:hooks,agent:agents/pk-extra.md" ]'

# ================================================================ P12 symbolic links
fresh
adopt gd pk@mk:pk-impl
ln -s /etc/hosts "$PACKS/a/bin/link"
rolerow gd
check "P12 a symbolic link anywhere in the pack tree gives pack-symlink" '[ "$(jget o.pin_state)" = pack-symlink ]'

# ================================================================ P13 ambiguous installs
fresh
adopt gd pk@mk:pk-impl
cp -R "$PACKS/a" "$PACKS/b"
installed "{\"pk@mk\":[\"$PACKS/a\"],\"pk@other\":[\"$PACKS/b\"]}"
rolerow gd
check "P13 two install records with identical content stay available" '[ "$(jget o.pin_state)" = trusted ]'
echo changed > "$PACKS/b/bin/tool.sh"
rolerow gd
check "P13 two marketplaces with different content give pack-ambiguous" '[ "$(jget o.pin_state)" = pack-ambiguous ]'
installed "{\"pk@mk\":[\"$PACKS/a\",\"$PACKS/b\"]}"
rolerow gd
check "P13 ... and so do two versions" '[ "$(jget o.pin_state)" = pack-ambiguous ]'

# ================================================================ P14 stored copies
fresh
adopt gd pk@mk:pk-impl
GD_PIN=$PIN
rm -rf "$TRUSTED"
rolerow gd
check "P14 a row whose pin matches the installed content but with no stored copy is pack-untrusted-here" '[ "$(jget o.pin_state)" = pack-untrusted-here ]'
adopt gd pk@mk:pk-impl
COPY="$TRUSTED/${GD_PIN#sha256:}.json"
mutate "$COPY" 'd.agentText = d.agentText + "tampered"'
rolerow gd
check "P14 so does a stored copy edited so it no longer re-hashes to its name" '[ "$(jget o.pin_state)" = pack-untrusted-here ]'
mutate "$REPO_CFG" "d.roles = {rp: {from: \"pk@mk:pk-impl\", pin: \"$GD_PIN\"}}"
rm -rf "$FAKEHOME/.claude/agent-hierarchy" "$GLOBAL_CFG"
rolerow rp
check "P14 a committed repo-level row on a fresh HOME is pack-untrusted-here too" '[ "$(jget o.pin_state)" = pack-untrusted-here ] && [ "$(jget o.level)" = repo ]'

# ================================================================ P15 the commit gate
fresh
ROSTER="node $H/roster.mjs"
SET="$ROSTER role set gd --from pk@mk:pk-impl --pin sha256:abc --cwd $PROJ"
TRUST="$ROSTER role trust gd --pin sha256:abc --cwd $PROJ"
for c in "$SET" "$TRUST"; do
  label=${c#*role }; label=${label%% *}
  gate "$c"
  check "P15 role $label commit: a top-level interactive payload is asked" '[ "$(decision)" = ask ]'
  gate "$c" '{"agent_id":"sub1","agent_type":"general-purpose"}'
  check "P15 role $label commit: a subagent is denied" '[ "$(decision)" = deny ]'
  gate "$c" '{"agent_type":"ah:reviewer"}'
  check "P15 role $label commit: a non-Orchestrator role session is denied" '[ "$(decision)" = deny ]'
  OUT=$(node -e 'process.stdout.write(JSON.stringify({session_id:"g1",cwd:process.argv[1],tool_name:"Bash",tool_input:{command:process.argv[2]}}))' "$PROJ" "$c" | AH_TEAM_FILE="$PROJ/.claude/hierarchy/teams/t.json" HOME="$FAKEHOME" node "$H/pretooluse-roster-skill-gate.mjs" 2>&1)
  check "P15 role $label commit: AH_TEAM_FILE set is denied" '[ "$(decision)" = deny ]'
  gate "$c" '{"permission_mode":"someFutureMode"}'
  check "P15 role $label commit: a permission mode not seen to reach the user is denied" '[ "$(decision)" = deny ]'
  gate "$c" '{"permission_mode":"acceptEdits"}'
  check "P15 role $label commit: acceptEdits is asked" '[ "$(decision)" = ask ]'
done
anchor
gate "$SET"
check "P15 a live pipeline run denies the commit" '[ "$(decision)" = deny ] && [[ "$OUT" == *"pipeline run is live"* ]]'
mkdir -p "$SANDBOX/elsewhere"
gate "$ROSTER role trust gd --pin sha256:abc --cwd $SANDBOX/elsewhere"
check "P15 a --cwd pointed elsewhere doesn't hide the session's own live run" '[ "$(decision)" = deny ] && [[ "$OUT" == *"pipeline run is live"* ]]'
fresh
mkdir -p "$SANDBOX/badhier"; echo "not a dir" > "$SANDBOX/badhier/msgs"
OUT=$(node -e 'process.stdout.write(JSON.stringify({session_id:"g1",cwd:process.argv[1],tool_name:"Bash",tool_input:{command:process.argv[2]}}))' "$PROJ" "$SET" | AGENT_HIERARCHY_DIR="$SANDBOX/badhier" HOME="$FAKEHOME" node "$H/pretooluse-roster-skill-gate.mjs" 2>&1)
check "P15 an error while judging denies (fails closed)" '[ "$(decision)" = deny ] && [[ "$OUT" == *"couldn'"'"'t judge"* ]]'
# Commands the ah grammar can't parse whose text names a commit are judged as one, --dry-run or not.
ahcli() { OUT=$(node -e 'process.stdout.write(JSON.stringify({session_id:"g1",cwd:process.argv[1],tool_name:"Bash",tool_input:{command:process.argv[2]}}))' "$PROJ" "$1" | HOME="$FAKEHOME" node "$H/pretooluse-ah-cli.mjs" 2>&1); }
for verb in "role trust gd --pin sha256:abc" "role set gd --from pk@mk:pk-impl --pin sha256:abc"; do
  label=${verb%% --*}
  forms=(
    "$ROSTER $verb --cwd $PROJ # --dry-run"
    "cd /tmp && $ROSTER $verb --cwd $PROJ"
    "FOO=1 $ROSTER $verb --cwd $PROJ"
    "node hooks/roster.mjs $verb --cwd $PROJ"
    "node \$ROOT/hooks/roster.mjs $verb --cwd $PROJ"
    "bash -c \"$ROSTER $verb --cwd $PROJ\""
    "bash <<'EOF'
$ROSTER $verb --cwd $PROJ
EOF"
  )
  names=("a trailing # --dry-run" "cd … &&" "an env prefix" "a relative script path" "\$ROOT" "bash -c" "a heredoc")
  for i in "${!forms[@]}"; do
    c=${forms[$i]}; short=${names[$i]}
    gate "$c"
    check "P15 unparsed $label [$short…]: asked in a top-level session" '[ "$(decision)" = ask ] && [[ "$OUT" == *"one plain command"* ]]'
    gate "$c" '{"agent_id":"sub1","agent_type":"general-purpose"}'
    check "P15 unparsed $label [$short…]: denied in a subagent" '[ "$(decision)" = deny ]'
    ahcli "$c"
    check "P15 unparsed $label [$short…]: the allow hook stays silent" '[ -z "$OUT" ]'
  done
done
gate "grep -n 'role trust' $H/roster.mjs"
check "P15 the order rule: grep -n 'role trust' hooks/roster.mjs passes" '[ -z "$OUT" ]'
gate "$ROSTER role set gd --from pk@mk:pk-impl --description \"has # inside\" --dry-run --cwd $PROJ"
check "P15 a quoted # stays literal: a dry run that says \"…#…\" parses and passes" '[ -z "$OUT" ]'
for c in "$ROSTER role set gd --from pk@mk:pk-impl --dry-run --cwd $PROJ" "$ROSTER role trust gd --dry-run --cwd $PROJ" "$ROSTER role list --cwd $PROJ" "$ROSTER pack list --cwd $PROJ" "$ROSTER pack show pk --cwd $PROJ"; do
  gate "$c"
  check "P15 passes: ${c#node $H/roster.mjs }" '[ -z "$OUT" ]'
done
gate "$ROSTER create --plan --cwd $PROJ"
check "P15 the one-shot skill rule is unchanged: create is held the first time" '[ "$(decision)" = deny ] && [[ "$OUT" == *"agent-team"* ]]'
gate "$ROSTER create --plan --cwd $PROJ"
check "P15 ... and passes after" '[ -z "$OUT" ]'
OUT=$(node -e 'process.stdout.write(JSON.stringify({session_id:"g1",cwd:process.argv[1],tool_name:"Bash",tool_input:{command:process.argv[2]}}))' "$PROJ" "$SET" | HOME="$FAKEHOME" node "$H/pretooluse-ah-cli.mjs" 2>&1)
check "P15 the allow hook stays silent on a trust commit, so the gate's ask stands alone" '[ -z "$OUT" ]'

# ================================================================ P15b the in-process refusal
fresh
adopt gd pk@mk:pk-impl
TRUST_CFG=$(cat "$GLOBAL_CFG")
echo "more" >> "$PACKS/a/bin/tool.sh"
rm_ role trust gd --dry-run
NEW_PIN=$(jget o.pin)
AH_TEAM_FILE="$PROJ/.claude/hierarchy/teams/t.json" rm_ role trust gd --pin "$NEW_PIN"
check "P15b role trust with AH_TEAM_FILE set is refused, and nothing is written" '[ $RC != 0 ] && [[ "$ERR" == *"team member"* ]] && [ "$(cat "$GLOBAL_CFG")" = "$TRUST_CFG" ]'
rm_ role set g2 --from pk@mk:pk-rev --dry-run
G2_PIN=$(jget o.pin)
AH_TEAM_FILE="$PROJ/.claude/hierarchy/teams/t.json" rm_ role set g2 --from pk@mk:pk-rev --pin "$G2_PIN"
check "P15b role set --from with AH_TEAM_FILE set is refused, and nothing is written" '[ $RC != 0 ] && [[ "$ERR" == *"team member"* ]] && [ "$(cat "$GLOBAL_CFG")" = "$TRUST_CFG" ]'
AH_TEAM_FILE="$PROJ/.claude/hierarchy/teams/t.json" rm_ role trust gd --dry-run
check "P15b ... the dry run still works with AH_TEAM_FILE set" '[ $RC = 0 ] && [ "$(jget o.pin)" = "$NEW_PIN" ]'
anchor
rm_ role trust gd --pin "$NEW_PIN"
check "P15b a live anchor for the --cwd checkout refuses the commit" '[ $RC != 0 ] && [[ "$ERR" == *"pipeline run is live"* ]] && [ "$(cat "$GLOBAL_CFG")" = "$TRUST_CFG" ]'
rm_ role trust gd --dry-run
check "P15b ... the dry run still works during the run" '[ $RC = 0 ]'
mkdir -p "$SANDBOX/other"; git -C "$SANDBOX/other" init -q
OUT=$(cd "$PROJ" && HOME="$FAKEHOME" node "$H/roster.mjs" role trust gd --pin "$NEW_PIN" --cwd "$SANDBOX/other" 2>"$SANDBOX/err"); RC=$?; ERR=$(cat "$SANDBOX/err")
check "P15b a live anchor at the process's own cwd refuses too, when --cwd names another checkout" '[ $RC != 0 ] && [[ "$ERR" == *"pipeline run is live"* ]] && [ "$(cat "$GLOBAL_CFG")" = "$TRUST_CFG" ]'
fresh
adopt gd pk@mk:pk-impl
echo "more" >> "$PACKS/a/bin/tool.sh"
rm_ role trust gd --dry-run
NEW_PIN=$(jget o.pin)
AH_TEAM_FILE= rm_ role trust gd --pin "$NEW_PIN"
check "P15b AH_TEAM_FILE=\"\" counts as unset" '[ $RC = 0 ] && filejs "$GLOBAL_CFG" "d.roles.gd.pin === \"$NEW_PIN\""'

# ================================================================ P16 pipeline spawn backstop
fresh
adopt prv pk@mk:pk-rev
adopt pdes pk@mk:pk-des
adopt pimpl pk@mk:pk-impl
# The built-in's override comes from a second plugin: one agent maps to exactly one role.
mkpack "$PACKS/c" pk2
installed "{\"pk@mk\":[\"$PACKS/a\"],\"pk2@mk\":[\"$PACKS/c\"]}"
adopt reviewer pk2@mk:pk-rev --level repo
check "P16 (setup) the built-in reviewer is overridden by a pack role" 'filejs "$REPO_CFG" "d.roles.reviewer.from === \"pk2@mk:pk-rev\""'
mutate "$REPO_CFG" 'd.roster = {route: "peer", members: [{role: "reviewer", model: "opus", autoMode: "auto"}, {role: "pimpl", model: "opus", autoMode: "auto"}]}'
spawnall() { # <expect: refused|spawned> <label>
  for r in prv pdes reviewer; do
    rm_ spawn-ad-hoc $r --model opus --route peer --auto-mode auto --dry-run --orchestrator-pid $$
    if [ "$1" = refused ]; then check "P16 $2: spawn-ad-hoc $r is refused" '[ $RC != 0 ] && [[ "$ERR" == *"pipeline run is live"* ]]'
    else check "P16 $2: spawn-ad-hoc $r spawns" '[ $RC = 0 ]'; fi
  done
  rm_ spawn-one reviewer --dry-run --orchestrator-pid $$
  if [ "$1" = refused ]; then check "P16 $2: spawn-one reviewer (overridden by a pack) is refused" '[ $RC != 0 ] && [[ "$ERR$OUT" == *"pipeline run is live"* ]]'
  else check "P16 $2: spawn-one reviewer spawns" '[ $RC = 0 ]'; fi
}
spawnall spawned "without a live run"
anchor
spawnall refused "with a live run"
rm_ spawn-ad-hoc pimpl --model opus --route peer --auto-mode auto --dry-run --orchestrator-pid $$
check "P16 with a live run: an implement-class pack role spawns" '[ $RC = 0 ]'
rm_ spawn-one pimpl --dry-run --orchestrator-pid $$
check "P16 with a live run: spawn-one of an implement-class pack role spawns" '[ $RC = 0 ]'

# ================================================================ P17 no bypassPermissions
fresh
adopt pimpl pk@mk:pk-impl
mkdir -p "$FAKEHOME/.claude/agents"; printf -- '---\nname: own-impl\ndescription: mine\ntools: Read, Edit, Write, Bash, SendMessage\n---\nMine.\n' > "$FAKEHOME/.claude/agents/own-impl.md"
rm_ role set own-impl --class implement --level global
refused() { [[ "$ERR$OUT" == *"never runs with permission checks off"* ]] && [[ "$ERR$OUT" == *"edit --member"*"--auto-mode"* ]]; }
for mode in bypassPermissions unset; do
  if [ $mode = unset ]; then pm='{role: "pimpl", model: "opus"}'; om='{role: "own-impl", model: "opus"}'; flag=""
  else pm='{role: "pimpl", model: "opus", autoMode: "bypassPermissions"}'; om='{role: "own-impl", model: "opus", autoMode: "bypassPermissions"}'; flag="--auto-mode bypassPermissions"; fi
  mutate "$REPO_CFG" "d.roster = {route: \"peer\", members: [$pm, $om]}"
  rm_ spawn-ad-hoc pimpl --model opus --route peer $flag --dry-run --orchestrator-pid $$
  check "P17 ($mode) spawn-ad-hoc refuses a pack role, with the fix" '[ $RC != 0 ] && refused'
  rm_ spawn-one pimpl --dry-run --orchestrator-pid $$
  check "P17 ($mode) spawn-one refuses it" '[ $RC != 0 ] && refused'
  rm_ create --plan --orchestrator-pid $$
  check "P17 ($mode) create refuses it" 'refused'
  rm_ spawn-one own-impl --dry-run --orchestrator-pid $$
  check "P17 ($mode) a non-pack member behaves as today" '[ $RC = 0 ] && ! refused'
done
mutate "$REPO_CFG" 'd.roster = {route: "peer", members: [{role: "pimpl", model: "opus", autoMode: "auto"}]}'
rm_ spawn-one pimpl --dry-run --orchestrator-pid $$
check "P17 a pack member with auto spawns with --permission-mode auto" '[ $RC = 0 ] && [[ "$OUT" == *"--permission-mode auto"* ]]'

# ================================================================ P17b the route gate
fresh
adopt pimpl pk@mk:pk-impl
adopt pleg pk@mk:pk-leg
mkpack "$PACKS/c" pk2
installed "{\"pk@mk\":[\"$PACKS/a\"],\"pk2@mk\":[\"$PACKS/c\"]}"
adopt reviewer pk2@mk:pk-rev
route() { # <subagent_type> <permission_mode> [node --import module]
  OUT=$(node -e 'process.stdout.write(JSON.stringify({session_id:"rg",cwd:process.argv[1],tool_name:"Agent",permission_mode:process.argv[3],tool_input:{subagent_type:process.argv[2],prompt:"x"}}))' "$PROJ" "$1" "$2" | HOME="$FAKEHOME" node ${3:+--import "$3"} "$H/pretooluse-route-gate.mjs" 2>&1); RC=$?
}
packheld() { [ "$(decision)" = deny ] && [[ "$OUT" == *"permission checks off"* ]]; }
for ref in pk:pk-leg pk:pk-impl pk2:pk-rev; do
  route "$ref" bypassPermissions
  check "P17b an Agent dispatch of pack agent $ref in bypassPermissions is denied" 'packheld'
done
for mode in auto acceptEdits default; do
  route pk:pk-leg "$mode"
  check "P17b the same legwork dispatch in $mode passes" '[ -z "$OUT" ]'
  route pk2:pk-rev "$mode"
  check "P17b the overridden built-in's agent in $mode isn't held by the pack rule" '! packheld'
done
route other:agent bypassPermissions
check "P17b a non-pack agent in bypassPermissions passes" '[ -z "$OUT" ]'
THROWS="$PLUGIN/tests/fixtures/resolve-config-throws.mjs"
route pk:pk-leg bypassPermissions "$THROWS"
check "P17b a forced throw denies a <plugin>:<agent> outside ah: in bypassPermissions" 'packheld && [[ "$OUT" == *"internal error"* ]]'
route ah:task-runner bypassPermissions "$THROWS"
check "P17b ... and leaves an ah: legwork agent to the existing error handling (passes)" '[ -z "$OUT" ]'
route ah:architect bypassPermissions "$THROWS"
check "P17b ... and an ah: chain agent to it too (held as a chain ref, not as a pack role)" '[ "$(decision)" = deny ] && [[ "$OUT" != *"permission checks off"* ]]'

# ================================================================ P18 the content digest
fresh
rm_ pack show pk --json
D1=$(jget o.digest)
rm_ pack show pk --json
D2=$(jget o.digest)
rm -rf "$PACKS/copy"; cp -R "$PACKS/a" "$PACKS/copy"
showpath "$PACKS/copy"
D3=$(jget o.digest)
echo more >> "$PACKS/a/bin/tool.sh"
rm_ pack show pk --json
D4=$(jget o.digest)
check "P18 pack show's digest is stable for the same tree, installed or not, and changes with it" '[[ "$D1" =~ ^sha256:[0-9a-f]{64}$ ]] && [ "$D1" = "$D2" ] && [ "$D1" = "$D3" ] && [ "$D1" != "$D4" ]'

# ================================================================ P20 name claims
mkhelper() { # pack hp at $PACKS/h: one role, helper, with a strict agents/helper.md
  rm -rf "$PACKS/h"; mkdir -p "$PACKS/h/.claude-plugin" "$PACKS/h/agents"
  printf '{"name":"hp","version":"1.0.0","description":"helper pack"}\n' > "$PACKS/h/.claude-plugin/plugin.json"
  printf '{"version":1,"roles":{"helper":{"class":"implement","description":"Helps with pack work"}}}\n' > "$PACKS/h/ah-roles.json"
  printf -- '---\nname: helper\ndescription: Helps\nmodel: opus\ntools: Read, Grep, Edit, Write, Bash, SendMessage\n---\nHelp.\n' > "$PACKS/h/agents/helper.md"
}
FX20="$SANDBOX/fx20"; mkdir -p "$FX20"
cat > "$FX20/dq.md" <<'EOF'
---
"name": helper
---
x
EOF
cat > "$FX20/sq.md" <<'EOF'
---
'name': "helper"
---
x
EOF
cat > "$FX20/esc.md" <<'EOF'
---
"na\x6de": helper
---
x
EOF
cat > "$FX20/merge.md" <<'EOF'
---
name: other
<<: {name: helper}
---
x
EOF
cat > "$FX20/anchor.md" <<'EOF'
---
name: other
color: &a red
---
x
EOF
fresh
mkhelper
installed "{\"hp@mk\":[\"$PACKS/h\"]}"
adopt hl hp@mk:helper
rolerow hl
check "P20 (baseline) the helper role adopts and is trusted" '[ "$(jget o.pin_state)" = trusted ]'
p20() { # <label> <path the finding names> <shell edit of $PACKS/h> [claims marked in pack show, as JSON]
  mkhelper; eval "$3"
  showpath "$PACKS/h"
  local codes msg marked
  codes=$(roleerr helper)
  msg=$(jget '(o.roles.find(r => r.name === "helper").findings.find(f => f.code === "pack-invalid") || {}).message')
  marked=$(jget "(o.also_in_plugin.find(e => e.name === \"$2\") || {}).claims || null")
  local want=${4-'["helper"]'} where=$2
  rolerow hl
  check "P20 $1: pack-invalid naming $2, marked in pack show, and the adopted role unavailable" \
    '[[ "$codes" == *pack-invalid* ]] && [[ "$msg" == *"$where"* ]] && [ "$marked" = "$want" ] && [ "$(jget o.pin_state)" = pack-invalid ]'
}
p20 "another file declaring name: helper, with no tools" agents/zz.md 'printf -- "---\nname: helper\ndescription: sneaky\n---\nSneaky.\n" > "$PACKS/h/agents/zz.md"'
p20 "a file in a subdirectory of agents/ declaring it" agents/sub/zz.md 'mkdir -p "$PACKS/h/agents/sub"; printf -- "---\nname: helper\n---\nx\n" > "$PACKS/h/agents/sub/zz.md"'
p20 "a file named helper.md in a subdirectory, with no name" agents/sub/helper.md 'mkdir -p "$PACKS/h/agents/sub"; printf -- "---\ndescription: no name\n---\nx\n" > "$PACKS/h/agents/sub/helper.md"'
p20 "a double-quoted \"name\" key" agents/zz.md 'cp "$FX20/dq.md" "$PACKS/h/agents/zz.md"'
p20 "a single-quoted name key with a double-quoted value" agents/zz.md 'cp "$FX20/sq.md" "$PACKS/h/agents/zz.md"'
p20 "a quoted key with an escape in it" agents/zz.md 'cp "$FX20/esc.md" "$PACKS/h/agents/zz.md"'
p20 "a <<: merge key" agents/zz.md 'cp "$FX20/merge.md" "$PACKS/h/agents/zz.md"'
p20 "an &a anchor" agents/zz.md 'cp "$FX20/anchor.md" "$PACKS/h/agents/zz.md"'
p20 "another file declaring name: Helper" agents/zz.md 'printf -- "---\nname: Helper\n---\nx\n" > "$PACKS/h/agents/zz.md"'
p20 "another file declaring name: HELPER" agents/zz.md 'printf -- "---\nname: HELPER\n---\nx\n" > "$PACKS/h/agents/zz.md"'
p20 "agents/sub/HELPER.md with no name" agents/sub/HELPER.md 'mkdir -p "$PACKS/h/agents/sub"; printf -- "---\ndescription: no name\n---\nx\n" > "$PACKS/h/agents/sub/HELPER.md"'
p20 "an agent under a path in plugin.json's agents key" extra/zz.md 'mkdir -p "$PACKS/h/extra"; printf -- "---\nname: helper\n---\nx\n" > "$PACKS/h/extra/zz.md"; printf "{\"name\":\"hp\",\"version\":\"1.0.0\",\"agents\":[\"./extra/\"]}\n" > "$PACKS/h/.claude-plugin/plugin.json"'
p20 "an agents path outside the install path" ../elsewhere 'printf "{\"name\":\"hp\",\"version\":\"1.0.0\",\"agents\":\"../elsewhere\"}\n" > "$PACKS/h/.claude-plugin/plugin.json"' null
p20 "an agents value that isn't a path or a list of paths" agents 'printf "{\"name\":\"hp\",\"version\":\"1.0.0\",\"agents\":{\"a\":1}}\n" > "$PACKS/h/.claude-plugin/plugin.json"' null
mkhelper
printf -- '---\nname: other\ndescription: unrestricted\npermissionMode: bypassPermissions\nhooks: x\n---\nx\n' > "$PACKS/h/agents/other.md"
mkdir -p "$PACKS/h/skills/helper"; printf -- '---\nname: helper\ndescription: a skill\n---\nx\n' > "$PACKS/h/skills/helper/SKILL.md"
showpath "$PACKS/h"
C20=$(roleerr helper)
rolerow hl
check "P20 an unrestricted agent named other and a skill named helper leave the role valid (only the tree changed)" \
  '[[ "$C20" != *pack-invalid* ]] && [ "$(jget o.pin_state)" = pack-changed ]'

echo
echo "SUMMARY: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
