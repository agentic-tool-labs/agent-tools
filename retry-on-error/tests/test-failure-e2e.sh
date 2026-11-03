#!/bin/bash
# A failed request, end to end: a real interactive `claude` in tmux against tests/mock-failing-api.mjs, HOME under a
# throwaway dir. Every assertion counts nudges in the requests the model would have been sent. Needs `claude`, `tmux`, `node`.
# "no classic" is a copy of the plugin with its classic.StopFailure hook cut out: what a session hears where those events
# pass over the plugin. No setting or policy is involved. The last case also cuts the turn.complete trigger and must see no nudge.
# Usage: bash tests/test-failure-e2e.sh [plugin dir]   (exits 0 iff all cases pass)

HERE="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="${1:-$(cd "$HERE/.." && pwd)}"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/retry-e2e.XXXXXX")"
[ -n "$SANDBOX" ] || exit 1
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
H="$SANDBOX/home"; R="$SANDBOX/reqs"; PROJ="$SANDBOX/proj"; TM="retrye2e$$"
mkdir -p "$H/.claude" "$R" "$PROJ"
node "$HERE/mock-failing-api.mjs" "$R" & MOCK=$!
trap 'tmux -L "$TM" kill-server 2>/dev/null; kill "$MOCK" 2>/dev/null; rm -rf "$SANDBOX"' EXIT
for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$R/port" ] && break; sleep 1; done
PORT=$(cat "$R/port")
PASS=0; FAIL=0

printf '%s' "{\"hasCompletedOnboarding\":true,\"bypassPermissionsModeAccepted\":true,\"customApiKeyResponses\":{\"approved\":[\"sk-probe\"],\"rejected\":[]},\"projects\":{\"$PROJ\":{\"hasTrustDialogAccepted\":true}}}" > "$H/.claude.json"
echo '{"skipDangerousModePermissionPrompt":true,"theme":"dark"}' > "$H/.claude/settings.json"

# variant <name> <node replace-expressions>: a copy of the plugin whose hooks module went through them; each must change it
variant() {
  cp -R "$PLUGIN" "$SANDBOX/$1"
  node -e '
    const fs = require("fs"), f = process.argv[1] + "/hooks/register.tsx";
    let s = fs.readFileSync(f, "utf8");
    for (const [re, to] of JSON.parse(process.argv[2])) {
      const t = s.replace(new RegExp(re), to);
      if (t === s) { console.error("variant: no match for " + re); process.exit(1); }
      s = t;
    }
    fs.writeFileSync(f, s);
  ' "$SANDBOX/$1" "$2" || exit 1
}
CUT_CLASSIC='["on\\(.classic\\.StopFailure.[\\s\\S]*?\\n  }\\)\\n",""]'
variant noclassic "[$CUT_CLASSIC]"
variant notrigger "[$CUT_CLASSIC,[\"e\\\\.reason === .error.\\\\) \\\\{\",\"false) {\"]]"

check() { # check <name> <actual> <expected>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "PASS: $1"; else FAIL=$((FAIL+1)); echo "FAIL: $1 (got '$2', want '$3')"; fi
}
# nudges: "<requests holding a nudge since the case began> <the kind in the first>"
nudges() {
  node -e '
    const fs = require("fs"), dir = process.argv[1], from = +process.argv[2];
    const hits = fs.readdirSync(dir).filter(f => f.startsWith("req-")).sort().slice(from)
      .map(f => fs.readFileSync(dir + "/" + f, "utf8")).filter(s => s.includes("The previous turn ended on an API error"));
    console.log(hits.length, hits.length ? hits[0].match(/ended on an API error \((\w+)\)/)[1] : "-");
  ' "$R" "$FROM"
}
open_case() { # open_case <plugin dir> <code>: start a session, send the failing prompt
  FROM=$(ls "$R" | grep -c '^req-')
  tmux -L "$TM" new-session -d -s p -x 160 -y 50 -c "$PROJ" \
    "env -i PATH='$PATH' TERM=xterm-256color HOME='$H' TMPDIR='${TMPDIR:-/tmp}' ANTHROPIC_API_KEY=sk-probe ANTHROPIC_BASE_URL=http://127.0.0.1:$PORT CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 CLAUDE_CODE_MAX_RETRIES=0 claude --plugin-dir '$1' --dangerously-skip-permissions --model claude-sonnet-4-5"
  sleep 8
  tmux -L "$TM" send-keys -t p -l "FAIL$2"; sleep 1; tmux -L "$TM" send-keys -t p Enter
}
close_case() { tmux -L "$TM" kill-server 2>/dev/null; sleep 1; }

# ---- classic events run: the kind is real
open_case "$PLUGIN" 529; sleep 12
check "classic: a 529 nudges once, kind from StopFailure" "$(nudges)" "1 server_error"
sleep 15
check "classic: and only once" "$(nudges)" "1 server_error"
close_case

open_case "$PLUGIN" 400; sleep 15
check "classic: a 400 is not retried" "$(nudges)" "0 -"
close_case

open_case "$PLUGIN" 429; sleep 15
check "classic: a 429 waits past the generic delay" "$(nudges)" "0 -"
sleep 22
check "classic: then nudges once, kind rate_limit" "$(nudges)" "1 rate_limit"
close_case

# ---- no classic events: every failure retries once under the generic kind
open_case "$SANDBOX/noclassic" 529; sleep 12
check "no classic: a 529 nudges once, generic kind" "$(nudges)" "1 api_error"
sleep 15
check "no classic: and only once" "$(nudges)" "1 api_error"
close_case

open_case "$SANDBOX/noclassic" 400; sleep 12
check "no classic: a 400 cannot be told apart, so it retries too" "$(nudges)" "1 api_error"
close_case

# ---- this suite can see the trigger's absence
open_case "$SANDBOX/notrigger" 529; sleep 15
check "no classic and no turn.complete trigger: no nudge" "$(nudges)" "0 -"
close_case

echo "---- $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
