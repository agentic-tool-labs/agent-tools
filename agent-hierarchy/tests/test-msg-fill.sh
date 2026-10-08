#!/bin/bash
# agent-hierarchy — spec 0090: `msg.mjs fill` writes a report body into the response file `new --type response` made, keeping the
# frontmatter byte for byte. A valid fill, a repeat, the trailing newline, the body encoding (`\n`, `'`), every refusal with
# nothing written, the 64 KiB edge, and a worktree --cwd against a main-checkout request. Each refusal case also checks the `fill:`
# message, since an unknown verb exits 2 as well.
# HOME-redirected; real state untouched.
# Usage: bash tests/test-msg-fill.sh   (exits 0 iff all cases pass)

. "$(dirname "$0")/lib-hermetic.sh"
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
unset AH_TEAM_FILE  # every session roster.mjs launches carries one; a test must not inherit it
unset CLAUDE_PID  # every Claude session exports one; a test must not inherit it
H="$PLUGIN/hooks"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-fill-test.XXXXXX")"
[ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] || { echo "mktemp failed"; exit 1; }
hermetic_on_exit 'rm -rf "$SANDBOX"'
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKEHOME="$SANDBOX/home"
mkdir -p "$FAKEHOME/.claude"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:500})"; fi
}

MAIN="$SANDBOX/main"; WT="$SANDBOX/wt"
mkdir -p "$MAIN/.claude"
(cd "$MAIN" && git init -q && git config user.email t@t.com && git config user.name t && git commit -q --allow-empty -m init)
git -C "$MAIN" worktree add -q "$WT" -b wt-branch >/dev/null
mkdir -p "$WT/.claude"
MSGS="$MAIN/.claude/hierarchy/msgs"

mcli() { # <cwd> <msg.mjs argv...>: stdout and stderr together in OUT
  local at=$1; shift
  OUT=$(HOME="$FAKEHOME" node "$H/msg.mjs" "$@" --cwd "$at" 2>&1); RC=$?
}
json_path() { node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{const l=s.split("\n").find(x=>x.startsWith("{"));process.stdout.write(JSON.parse(l).path)})'; }
jstr() { printf %s "$1" | node -e 'process.stdout.write(JSON.stringify(require("fs").readFileSync(0, "utf8")))'; }
# <slug>: a request to the reviewer and the response `new` made for it. Sets REQ, ID, RESP.
mint() {
  mcli "$MAIN" new --to reviewer --from orchestrator --slug "$1"
  REQ=$(printf '%s' "$OUT" | json_path); ID=$(basename "$REQ" | cut -d- -f1-3)
  mcli "$MAIN" new --type response --id "$ID" --from reviewer --req "$REQ"
  RESP="$MSGS/$ID--orchestrator--$1--response.md"
}
# The frontmatter block of a response: through its closing fence.
fm_of() { awk 'NR==1 && $0=="---" {print; infm=1; next} infm {print} infm && $0=="---" {exit}' "$1"; }
fill() { # <body text> [extra fill args...]: fill RESP's request with the JSON string of the text
  local text=$1; shift
  mcli "$MAIN" fill --id "$ID" --from reviewer --req "$REQ" --body "$(jstr "$text")" "$@"
}
BODY=$'## [0] tldr\n- [1] status: PASS\n\n## [1] findings\n- none\n'

# ---- F1: a valid fill on a response made by `new`.
mint f1
fm_of "$RESP" > "$SANDBOX/fm.before"
fill "$BODY"
check "F1: a valid fill exits 0 and prints {id, path, bytes} in that order" '[ $RC = 0 ] && [ "$(printf %s "$OUT" | node -e "const o=JSON.parse(require(\"fs\").readFileSync(0,\"utf8\"));process.stdout.write(Object.keys(o).join())")" = "id,path,bytes" ]'
check "F1: the path is the response beside the request, and bytes is the size of the file written" '[ "$(printf %s "$OUT" | node -e "process.stdout.write(JSON.parse(require(\"fs\").readFileSync(0,\"utf8\")).path)")" = "$RESP" ] && [ "$(printf %s "$OUT" | node -e "process.stdout.write(String(JSON.parse(require(\"fs\").readFileSync(0,\"utf8\")).bytes))")" = "$(wc -c < "$RESP" | tr -d " ")" ]'
fm_of "$RESP" > "$SANDBOX/fm.after"
check "F1: the frontmatter bytes are identical before and after (cmp)" 'cmp -s "$SANDBOX/fm.before" "$SANDBOX/fm.after" && [ -s "$SANDBOX/fm.before" ]'
check "F1 (r2): the line after the closing fence is empty when the body starts with ## [0], as new's skeleton has it" '[ -z "$(sed -n "$(( $(wc -l < "$SANDBOX/fm.after") + 1 ))p" "$RESP")" ] && [ "$(sed -n "$(( $(wc -l < "$SANDBOX/fm.after") + 2 ))p" "$RESP")" = "## [0] tldr" ]'
check "F1: everything after that empty line is the body, and the skeleton's empty sections are gone" '[ "$(tail -n +$(( $(wc -l < "$SANDBOX/fm.after") + 2 )) "$RESP")" = "${BODY%$'"'"'\n'"'"'}" ] && ! grep -q "^## \[2\]" "$RESP"'
check "F1: no temporary file is left in the msgs dir" '[ -z "$(ls -a "$MSGS" | grep "\.tmp$")" ]'

# ---- F2: a repeat replaces the body.
fill $'## [0] tldr\n- [1] status: CHANGES REQUIRED\n'
check "F2: the second fill replaces the first body, frontmatter still identical" '[ $RC = 0 ] && grep -q "CHANGES REQUIRED" "$RESP" && ! grep -q "status: PASS" "$RESP" && fm_of "$RESP" | cmp -s - "$SANDBOX/fm.before"'

# ---- F3: the single quote, the encoding of newlines, and the trailing newline.
QUOTED=$'- it\'s fine\n- a "quoted" word and a \\ backslash'
fill "$QUOTED"
check "F3: a body containing it's lands as it's, with the double quote and the backslash" '[ $RC = 0 ] && grep -qF -- "- it'"'"'s fine" "$RESP" && grep -qF -- "a \"quoted\" word and a \\ backslash" "$RESP"'
check "F3: a body without a trailing newline is written with exactly one" '[ "$(tail -c 1 "$RESP" | od -An -c | tr -d " ")" = "\\n" ] && [ "$(tail -c 2 "$RESP" | od -An -c | tr -d " ")" != "\\n\\n" ]'
# The form the Reviewer sends: a newline is backslash-n, a single quote is backslash-u0027 (a literal one cannot sit inside the shell's single quotes).
BS=$(printf '\134')
mcli "$MAIN" fill --id "$ID" --from reviewer --req "$REQ" --body "\"line one${BS}nline two${BS}u0027s${BS}n\""
WANT=$(printf 'line one\nline two'"'"'s')
check "F3: the escaped form decodes (newline, single quote), and a body already ending in a newline gets no second one" '[ $RC = 0 ] && [ "$(tail -n 2 "$RESP")" = "$WANT" ] && [ "$(tail -c 2 "$RESP" | od -An -c | tr -d " ")" != "\\n\\n" ]'
mcli "$MAIN" fill --id "$ID" --from reviewer --req "$REQ" --body "$(jstr "$QUOTED")"
check "F3: ...and the same text as a plain JSON string with a raw single quote lands the same way" '[ $RC = 0 ] && grep -qF -- "- it'"'"'s fine" "$RESP"'
mcli "$MAIN" fill --id "$ID" --from reviewer --req "$REQ" --body "$(jstr "$BODY")" --plain
check "F3: --plain prints <id>  <path>" '[ $RC = 0 ] && [ "$OUT" = "$ID  $RESP" ]'

# ---- R: refusals. Exit 2, the `fill:` message, and the response untouched.
mint r1
cp "$RESP" "$SANDBOX/r1.before"
refused() { # <label> <expected text in the message>
  local label=$1 want=$2
  check "R: $label is refused (exit 2, '$want'), the response untouched" '[ $RC = 2 ] && printf %s "$OUT" | grep -qF -- "$want" && printf %s "$OUT" | grep -q "fill:" && cmp -s "$RESP" "$SANDBOX/r1.before"'
}
mcli "$MAIN" fill --id "$ID" --from architect --req "$REQ" --body "$(jstr "$BODY")"
refused "--from architect on a from: reviewer response" 'is from "reviewer", not "architect"'
mcli "$MAIN" fill --id 20200101-000000-aaaa --from reviewer --req "$REQ" --body "$(jstr "$BODY")"
refused "an --id that differs from the request's" 'does not match --id'
mcli "$MAIN" fill --id "$ID" --from reviewer --req "relative/$(basename "$REQ")" --body "$(jstr "$BODY")"
refused "a relative --req" 'must be an absolute path'
mcli "$MAIN" fill --id "$ID" --from reviewer --req "$MSGS/20200101-000000-aaaa--reviewer--nope--request.md" --body "$(jstr "$BODY")"
refused "a --req that does not exist" 'no such file'
mcli "$MAIN" fill --id "$ID" --from reviewer --req "$RESP" --body "$(jstr "$BODY")"
refused "a --response.md given as --req" 'is not a request file'
mcli "$MAIN" fill --id "$ID" --from reviewer --req "$REQ"
refused "a missing --body" '--body is required'
mcli "$MAIN" fill --id "$ID" --from reviewer --req "$REQ" --body 'not json'
refused "a --body that is not JSON" '--body must be a JSON string'
mcli "$MAIN" fill --id "$ID" --from reviewer --req "$REQ" --body '42'
refused "a JSON number" 'not another JSON value'
mcli "$MAIN" fill --id "$ID" --from reviewer --req "$REQ" --body '{"a":1}'
refused "a JSON object" 'not another JSON value'
mcli "$MAIN" fill --id "$ID" --from reviewer --req "$REQ" --body '"   "'
refused "a body of only spaces" '--body is empty'
mcli "$MAIN" fill --id "$ID" --from reviewer --req "$REQ" --body '"\n \n"'
refused "a body of only newlines and spaces" '--body is empty'
mcli "$MAIN" fill --id "$ID" --from reviewer --req "$REQ" --body "$(jstr $'## [0] tldr\n---\n- [1] status: PASS\n')"
refused "a body with a line that is exactly ---" 'exactly ---'
BIG=$(node -e 'process.stdout.write(JSON.stringify("a".repeat(65537)))')
mcli "$MAIN" fill --id "$ID" --from reviewer --req "$REQ" --body "$BIG"
refused "a body of 65537 bytes" 'over 65536 bytes'
BIGMB=$(node -e 'process.stdout.write(JSON.stringify("é".repeat(32769)))')
mcli "$MAIN" fill --id "$ID" --from reviewer --req "$REQ" --body "$BIGMB"
refused "a body of 32769 two-byte characters (65538 bytes: the size is bytes, not characters)" 'over 65536 bytes'

# ---- N: the nearest inputs that must still work.
fill $'| a | b |\n|---|---|\n----\n--- x\n- ok\n'
check "N: a table separator, a four-dash line and '--- x' are not a bare --- line: written" '[ $RC = 0 ] && grep -qF "|---|---|" "$RESP" && grep -qxF -- "----" "$RESP" && grep -qxF -- "--- x" "$RESP"'
mcli "$MAIN" fill --id "$ID" --from reviewer --req "$REQ" --body "$(node -e 'process.stdout.write(JSON.stringify("a".repeat(65536)))')"
check "N: a body of exactly 65536 bytes is written" '[ $RC = 0 ] && [ "$(wc -c < "$RESP" | tr -d " ")" -gt 65536 ]'
check "N: ...and the frontmatter is still the one new wrote" '[ -s "$SANDBOX/r1.before" ] && [ "$(fm_of "$RESP")" = "$(fm_of "$SANDBOX/r1.before")" ]'

# ---- no response yet: fill never creates one.
mcli "$MAIN" new --to reviewer --from orchestrator --slug r2
REQ2=$(printf '%s' "$OUT" | json_path); ID2=$(basename "$REQ2" | cut -d- -f1-3)
RESP2="$MSGS/$ID2--orchestrator--r2--response.md"
mcli "$MAIN" fill --id "$ID2" --from reviewer --req "$REQ2" --body "$(jstr "$BODY")"
check "R: no response file yet: exit 2, 'no response … run new first', nothing created" '[ $RC = 2 ] && printf %s "$OUT" | grep -q "no response" && printf %s "$OUT" | grep -q "run new first" && [ ! -e "$RESP2" ]'
mcli "$MAIN" new --type response --id "$ID2" --from reviewer --req "$REQ2"
mcli "$MAIN" fill --id "$ID2" --from reviewer --req "$REQ2" --body "$(jstr "$BODY")"
check "R: ...whereas after new the same fill works (nearest non-match)" '[ $RC = 0 ] && grep -q "status: PASS" "$RESP2"'

# ---- a response whose frontmatter is not the one the request says
mint r3
sed -i.bak 's/^from: reviewer$/from: implementor/' "$RESP" && rm -f "$RESP.bak"
cp "$RESP" "$SANDBOX/r3.before"
mcli "$MAIN" fill --id "$ID" --from reviewer --req "$REQ" --body "$(jstr "$BODY")"
check "R: a response whose frontmatter names another sender is not filled for the reviewer" '[ $RC = 2 ] && printf %s "$OUT" | grep -q "fill:" && cmp -s "$RESP" "$SANDBOX/r3.before"'
sed -i.bak 's/^from: implementor$/from: reviewer/; s/^type: response$/type: request/' "$RESP" && rm -f "$RESP.bak"
cp "$RESP" "$SANDBOX/r3.before"
mcli "$MAIN" fill --id "$ID" --from reviewer --req "$REQ" --body "$(jstr "$BODY")"
check "R: a file whose frontmatter type is not response is not filled" '[ $RC = 2 ] && printf %s "$OUT" | grep -q "is not a response" && cmp -s "$RESP" "$SANDBOX/r3.before"'

# ---- W: the request is in the main checkout's msgs, --cwd is a worktree.
mint w1
fm_of "$RESP" > "$SANDBOX/w1.fm"
mcli "$WT" fill --id "$ID" --from reviewer --req "$REQ" --body "$(jstr "$BODY")"
check "W: with --cwd a worktree and the request in the main checkout, fill writes the response beside the request" '[ $RC = 0 ] && grep -q "status: PASS" "$RESP" && fm_of "$RESP" | cmp -s - "$SANDBOX/w1.fm" && [ -z "$(find "$WT" -name "*--response.md")" ]'

# ---- r2: a body that already starts with an empty line gets no second one.
mint b1
fill $'\n## [0] tldr\n- ok\n'
check "N (r2): a body that starts with an empty line is written as is: exactly one empty line after the closing fence" '[ $RC = 0 ] && [ -z "$(sed -n "$(( $(fm_of "$RESP" | wc -l) + 1 ))p" "$RESP")" ] && [ "$(sed -n "$(( $(fm_of "$RESP" | wc -l) + 2 ))p" "$RESP")" = "## [0] tldr" ]'

# ---- r2: the hints that told the Reviewer to fill with Edit now name fill.
check "H (r2): neither pretooluse-sendmessage-response.mjs nor pretooluse-reviewer-write-gate.mjs says 'with Edit' any more, and both build their hint with fillCommand" '! grep -q "with Edit" "$H/pretooluse-sendmessage-response.mjs" "$H/pretooluse-reviewer-write-gate.mjs" && grep -q "fillCommand" "$H/pretooluse-sendmessage-response.mjs" && grep -q "fillCommand" "$H/pretooluse-reviewer-write-gate.mjs"'
OUT=$(node -e 'process.stdout.write(JSON.stringify({ session_id: "sh", cwd: process.argv[1], agent_type: "ah:reviewer", tool_name: "Write", tool_input: { file_path: "/tmp/not-a-response.txt", content: "x" } }))' "$MAIN" | HOME="$FAKEHOME" node "$H/pretooluse-reviewer-write-gate.mjs" 2>&1); RC=$?
check "H (r2): the Reviewer write gate's denial text names msg.mjs fill and keeps Write and Edit as a fallback; the decision is still deny" '[ $RC = 0 ] && printf %s "$OUT" | grep -q "\"permissionDecision\":\"deny\"" && printf %s "$OUT" | grep -q "msg.mjs fill --id" && printf %s "$OUT" | grep -q "fallback"'
OUT=$(HOME="$FAKEHOME" node --input-type=module -e "const C = await import('$H/lib-config.mjs'); process.stdout.write(JSON.stringify({ rev: C.buildRoleSessionNotice('reviewer', 'ah:reviewer').includes('msg.mjs fill'), impl: C.buildRoleSessionNotice('implementor', 'ah:implementor').includes('msg.mjs fill') }))" 2>&1)
check "H (r2): the reviewer's role-session notice names msg.mjs fill, the implementor's does not" '[ "$OUT" = "{\"rev\":true,\"impl\":false}" ]'

# ---- the verb is listed in the usage text
mcli "$MAIN" --help
check "U: --help documents fill" 'printf %s "$OUT" | grep -q "msg.mjs fill --id"'
mcli "$MAIN" bogus
check "U: an unknown verb's usage line lists fill" '[ $RC = 2 ] && printf %s "$OUT" | grep -q "new|fill|list"'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
