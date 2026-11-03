#!/bin/bash
# The mod's injection, end to end: a real `claude` against tests/mock-messages-api.mjs, with HOME under a throwaway dir.
# Every assertion counts the text in a request the model would have been sent. Needs `claude` and `tmux` (for /clear).
# Usage: bash tests/test-mod-injection.sh [plugin dir]   (exits 0 iff all cases pass)
# Given a copy of the plugin with its mod removed, the injection cases must FAIL; the last case below does that itself.

HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="${1:-$(cd "$HERE/.." && pwd)}"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/task-gopher-mod-test.XXXXXX")"
[ -n "$SANDBOX" ] || exit 1
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
H="$SANDBOX/home"; R="$SANDBOX/reqs"; PROJ="$SANDBOX/proj"; TM="tgmod$$"
mkdir -p "$H/.claude" "$R" "$PROJ"
touch "$H/.claude/task-gopher.enabled"
node "$HERE/mock-messages-api.mjs" "$R" & MOCK=$!
trap 'tmux -L "$TM" kill-server 2>/dev/null; kill "$MOCK" 2>/dev/null; rm -rf "$SANDBOX"' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$R/port" ] && break; sleep 1; done
PORT=$(cat "$R/port")
PASS=0; FAIL=0

ENVV=(env -i "PATH=$PATH" "TERM=xterm-256color" "HOME=$H" "TMPDIR=${TMPDIR:-/tmp}" ANTHROPIC_API_KEY=sk-probe
  "ANTHROPIC_BASE_URL=http://127.0.0.1:$PORT" CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1)
FLAGS=(--dangerously-skip-permissions --model claude-sonnet-4-5)

reqs() { ls "$R" | grep -c '^req-'; }
# facts <req index, 1-based; negative from the end> -> "<directive copies> <reminder copies> <message count> <is subagent>"
facts() {
  node -e '
    const fs = require("fs"), dir = process.argv[1], i = +process.argv[2];
    const files = fs.readdirSync(dir).filter(f => f.startsWith("req-")).sort();
    const s = fs.readFileSync(dir + "/" + files.at(i > 0 ? i - 1 : i), "utf8"), b = JSON.parse(s);
    const count = re => (s.match(re) || []).length;
    console.log(count(/PURPOSE: keep tool output/g), count(/Keep tool output out of your context \(Haiku/g), b.messages.length, s.includes("cc_is_subagent") ? 1 : 0);
  ' "$R" "$1"
}
check() { # check <name> <actual> <expected>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "PASS: $1"; else FAIL=$((FAIL+1)); echo "FAIL: $1 (got '$2', want '$3')"; fi
}
copies() { facts "$1" | cut -d' ' -f1; }
ticks() { facts "$1" | cut -d' ' -f2; }
run() { # run <plugin dir> <extra env or ""> <claude args...>; a 60 s alarm kills a hang
  local dir=$1 extra=$2; shift 2
  (cd "$PROJ" && perl -e 'alarm 60; exec @ARGV' "${ENVV[@]}" $extra claude --plugin-dir "$dir" "${FLAGS[@]}" "$@" < /dev/null > "$SANDBOX/out.txt" 2>&1)
}

# ---- /clear and /compact need the interactive session: -p /clear does not clear what a later --resume reads
SEED="{\"hasCompletedOnboarding\":true,\"bypassPermissionsModeAccepted\":true,\"customApiKeyResponses\":{\"approved\":[\"sk-probe\"],\"rejected\":[]},\"projects\":{\"$PROJ\":{\"hasTrustDialogAccepted\":true}}}"
printf '%s' "$SEED" > "$H/.claude.json"
echo '{"skipDangerousModePermissionPrompt":true,"theme":"dark"}' > "$H/.claude/settings.json"
tmux -L "$TM" new-session -d -s p -x 160 -y 50 -c "$PROJ" "${ENVV[*]} claude --plugin-dir '$PLUGIN' ${FLAGS[*]}"
say() { # say <text>: type it, then wait for the session to go quiet
  tmux -L "$TM" send-keys -t p -l "$1"; sleep 1; tmux -L "$TM" send-keys -t p Enter; sleep "${2:-4}"
}
sleep 8
say first
check "startup: the first request holds the directive once" "$(copies -1)" 1
check "startup: and the reminder" "$(ticks -1)" 1
say second
check "next prompt: still exactly one directive, the reminder again" "$(copies -1) $(ticks -1)" "1 2"
say /compact 8
SCREEN=$(tmux -L "$TM" capture-pane -pt p -S -200)
check "/compact: the person is not shown the directive" "$(printf '%s' "$SCREEN" | grep -c 'PURPOSE: keep tool output')" 0
say aftercompact
check "after /compact: exactly one directive" "$(copies -1)" 1
say /clear 3
say afterclear
check "after /clear: a fresh conversation holds one directive" "$(copies -1) $(facts -1 | cut -d' ' -f3)" "1 1"
say again
check "after /clear, next prompt: still one" "$(copies -1)" 1
tmux -L "$TM" kill-server 2>/dev/null

# ---- a compaction in the middle of a turn: no prompt comes after it
SID=11111111-2222-4333-8444-555555555555
run "$PLUGIN" "CLAUDE_CODE_AUTO_COMPACT_WINDOW=100000" -p AUTOCOMPACT --session-id "$SID"
check "auto-compact mid-turn: the turn's next request holds one directive" "$(copies -1)" 1
LAST_REQ="$R/$(ls "$R" | grep '^req-' | tail -1)"
check "auto-compact mid-turn: that request is after the compaction" "$(grep -c 'continued from a previous conversation' "$LAST_REQ")" 1

# ---- resume: never a second copy
run "$PLUGIN" "" -p one --session-id 22222222-2222-4333-8444-555555555555
run "$PLUGIN" "" -p two --resume 22222222-2222-4333-8444-555555555555
check "resume: one directive across the resumed conversation" "$(copies -1)" 1

# ---- a gopher subagent gets neither; the main loop keeps its own
N=$(reqs)
run "$PLUGIN" "" -p "SPAWN:task-gopher:task-gopher go"
SUB=""
for i in $(seq $((N+1)) "$(reqs)"); do
  [ "$(facts "$i" | cut -d' ' -f4)" = 1 ] && SUB=$i
done
check "gopher subagent: a subagent request was made" "$([ -n "$SUB" ] && echo yes)" yes
check "gopher subagent: neither directive nor reminder" "$(copies "${SUB:-1}") $(ticks "${SUB:-1}")" "0 0"

# ---- an --agent session of a gopher or a hierarchy role gets neither; another agent still does
ROLE='{"ah:architect":{"description":"role","prompt":"role"},"plain-agent":{"description":"plain","prompt":"plain"}}'
run "$PLUGIN" "" -p hi --agent task-gopher:task-gopher
check "--agent gopher: neither" "$(copies -1) $(ticks -1)" "0 0"
run "$PLUGIN" "" -p hi --agents "$ROLE" --agent ah:architect
check "--agent hierarchy role: neither" "$(copies -1) $(ticks -1)" "0 0"
run "$PLUGIN" "" -p hi --agents "$ROLE" --agent plain-agent
check "--agent of any other type: injected (nearest input that must still match)" "$(copies -1) $(ticks -1)" "1 1"
echo '{"agent":"task-gopher:task-gopher"}' > "$SANDBOX/agent-settings.json"
run "$PLUGIN" "" -p hi --settings "$SANDBOX/agent-settings.json"
check "agent setting naming a gopher: neither" "$(copies -1) $(ticks -1)" "0 0"

# ---- OFF gets neither
rm "$H/.claude/task-gopher.enabled"
run "$PLUGIN" "" -p hi
check "OFF: neither" "$(copies -1) $(ticks -1)" "0 0"
touch "$H/.claude/task-gopher.enabled"

# ---- this suite can see the mod's absence, and nothing else injects
NOMOD="$SANDBOX/nomod"
cp -R "$PLUGIN" "$NOMOD"
node -e 'const fs=require("fs"),f=process.argv[1],j=JSON.parse(fs.readFileSync(f));delete j.modules;fs.writeFileSync(f,JSON.stringify(j))' "$NOMOD/hooks/hooks.json"
run "$NOMOD" "" -p hi
check "mod removed: nothing injects (no command hook left behind)" "$(copies -1) $(ticks -1)" "0 0"

echo "---- $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
