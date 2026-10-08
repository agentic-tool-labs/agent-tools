#!/bin/bash
# agent-hierarchy — issue-intake.mjs: the eligibility gate, the two-phase fetch, sanitizing and the
# snapshot. A fake `gh` (tests/fixtures/issue-intake/gh) goes first on PATH, answers from the fixtures
# beside it and logs every request, so "never fetched" is checked against what was actually asked for.
# HOME-redirected; the conventions repos live in a throwaway sandbox and nothing touches the network.
# Usage: bash tests/test-issue-intake.sh   (exits 0 iff all cases pass)

. "$(dirname "$0")/lib-hermetic.sh"
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
unset AH_TEAM_FILE  # every session roster.mjs launches carries one; a test must not inherit it
unset CLAUDE_PID  # every Claude session exports one; a test must not inherit it
INTAKE="$PLUGIN/hooks/issue-intake.mjs"
FIX="$PLUGIN/tests/fixtures/issue-intake"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-intake-test.XXXXXX")"
[ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] || { echo "mktemp failed"; exit 1; }
hermetic_on_exit 'rm -rf "$SANDBOX"'
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
export HOME="$SANDBOX/home"
mkdir -p "$HOME"
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig" GIT_CONFIG_NOSYSTEM=1 GIT_CEILING_DIRECTORIES="$SANDBOX"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git config --global init.defaultBranch main
export PATH="$FIX:$PATH" FAKE_GH_LOG="$SANDBOX/gh.log"
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:400})"; fi
}

# ---- setup: conventions committed on main, pushed to a bare origin, origin/HEAD set; then origin's URL
# is pointed at github.com — the loader reads the remote-tracking refs and never fetches.
mkrepo() { # <name> <conventions text> <github origin url>
  git init -q --bare "$SANDBOX/$1-origin.git"
  git init -q "$SANDBOX/$1"
  mkdir -p "$SANDBOX/$1/.claude"
  printf '%s' "$2" > "$SANDBOX/$1/.claude/ah-conventions.json"
  git -C "$SANDBOX/$1" add -A && git -C "$SANDBOX/$1" commit -qm init
  git -C "$SANDBOX/$1" remote add origin "$SANDBOX/$1-origin.git"
  git -C "$SANDBOX/$1" push -q origin main
  git -C "$SANDBOX/$1" remote set-head origin main
  git -C "$SANDBOX/$1" remote set-url origin "$3"
}
mkrepo proj '{"version":1,"issues":{"trigger_label":"ready-for-agent"}}' https://github.com/alice/proj.git
mkrepo nolabel '{"version":1,"issues":{"trusted_actors":["alice"]}}' https://github.com/alice/nolabel.git
REPO="$SANDBOX/proj"

run() { # <cwd> <intake args...> — a fresh gh log and out dir (holding a stale $SEED file if set); sets OUT, RC, OUTDIR
  local cwd=$1; shift
  : > "$FAKE_GH_LOG"
  OUTDIR="$(mktemp -d "$SANDBOX/out.XXXXXX")"
  [ -z "$SEED" ] || echo stale > "$OUTDIR/$SEED"
  OUT=$(node "$INTAKE" --cwd "$cwd" --out-dir "$OUTDIR" "$@" 2>&1); RC=$?
}
j() { # <JS expression over the parsed output o>
  printf '%s' "$OUT" | node -e 'const o=JSON.parse(require("fs").readFileSync(0,"utf8"));process.stdout.write(String(eval(process.argv[1])))' "$1" 2>/dev/null
}
verdicts() { j 'o.items.map(i=>`${i.issue}:${i.eligible?"eligible":i.reason}`).join(" ")'; }
calls() { # <operation> — the variables of every logged GraphQL request to it, one JSON line each
  node -e '
    const [log, op] = process.argv.slice(1);
    for (const line of require("fs").readFileSync(log, "utf8").split("\n").filter(Boolean)) {
      const { stdin } = JSON.parse(line);
      if (!stdin) continue;
      const req = JSON.parse(stdin);
      if (new RegExp(`query ${op}\\b`).test(req.query)) console.log(JSON.stringify(req.variables));
    }' "$FAKE_GH_LOG" "$1"
}
fetched() { calls IntakeFetch | grep -q "\"number\":$1[,}]"; }
fx() { # <issue> <JS expression over that issue's fixture i>
  node -e 'const i=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))[process.argv[2]];process.stdout.write(String(eval(process.argv[3])))' "$FIX/issues.json" "$1" "$2"
}
expect_body() { # <issue> [line...] — the snapshot's BODY lines are exactly these
  [ "$(awk 'f && /^COMMENT [^ ]+ [^ ]+:$/ { exit } f; /^BODY:$/ { f = 1 }' "$OUTDIR/issue-$1.md")" = "$(shift; [ $# -eq 0 ] || printf '%s\n' "$@")" ]
}
fetch_selects_html_only() { # every logged IntakeFetch selects bodyHTML and never a bare body field
  node -e '
    const reqs = require("fs").readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean)
      .map((l) => JSON.parse(l).stdin).filter(Boolean).map((s) => JSON.parse(s).query).filter((q) => /query IntakeFetch\b/.test(q));
    process.exit(reqs.length && reqs.every((q) => /\bbodyHTML\b/.test(q) && !/\bbody\b/.test(q)) ? 0 : 1);' "$FAKE_GH_LOG"
}
gutter_only() { # <snapshot> — every line after BODY: is gutter content or a comment header
  awk 'NR > 5 && !/^\|( |$)/ && !/^COMMENT [^ ]+ [^ ]+:$/ { bad = 1 } END { exit bad }' "$1"
}
sha() { node -e 'process.stdout.write(require("crypto").createHash("sha256").update(require("fs").readFileSync(process.argv[1])).digest("hex"))' "$1"; }

# ---- 1: a clean eligible issue
run "$REPO" --issues 1
SNAP="$OUTDIR/issue-1.md"
check '1: eligible' '[ "$RC" -eq 0 ] && [ "$(verdicts)" = 1:eligible ]'
check '1: repo, trigger label, and the User owner as the trusted actor' \
  '[ "$(j "[o.repo, o.trigger_label, o.trusted_actors].join(\" \")")" = "alice/proj ready-for-agent alice" ]'
check '1: snapshot at <out-dir>/issue-1.md' '[ "$(j "o.items[0].snapshot")" = "$SNAP" ] && [ -f "$SNAP" ]'
check '1: snapshot matches the golden file' 'diff <(sed -E "1s/fetched=[^ ]+$/fetched=<FETCHED>/" "$SNAP") "$FIX/issue-1.md"'
check '1: fetched= is an ISO time' 'head -1 "$SNAP" | grep -qE "fetched=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]+Z$"'
check '1: sha256 is over the whole file' '[ "$(j "o.items[0].sha256")" = "$(sha "$SNAP")" ]'
check '1: lines is the file'"'"'s line count' '[ "$(j "o.items[0].lines")" = "$(wc -l < "$SNAP" | tr -d " ")" ]'

# ---- 2-5, 13: ineligible from metadata alone; 18: none of them had its text fetched
for c in '2 no-trigger-label label absent' \
  '3 untrusted-labeler latest label event untrusted, an earlier one trusted' \
  '4 edited-after-label body edited after the label' \
  '5 edited-after-label title renamed after the label' \
  '13 closed closed issue'; do
  set -- $c; N=$1; WANT=$2; shift 2
  run "$REPO" --issues "$N"
  check "$N: $* → $WANT" '[ "$RC" -eq 0 ] && [ "$(verdicts)" = "$N:$WANT" ]'
  check "18: #$N ineligible — its phase-2 query never ran" '[ -n "$(calls IntakeMeta)" ] && ! fetched "$N"'
done

# ---- 6-7: which comments are input
run "$REPO" --issues 6
check '6: eligible' '[ "$RC" -eq 0 ] && [ "$(verdicts)" = 6:eligible ]'
check '6: the untrusted comment is not in the snapshot; the trusted one is' \
  '! grep -q -e mallory -e "push to main" "$OUTDIR/issue-6.md" && grep -q "Trusted note." "$OUTDIR/issue-6.md"'
check '6: the untrusted comment'"'"'s body was never requested' \
  'fetched 6 && ! grep -q IC_6a "$FAKE_GH_LOG" && calls IntakeFetch | grep -q "\"ids\":\[\"IC_6b\"\]"'
run "$REPO" --issues 7
check '7: eligible, the trusted comment edited after the label excluded' \
  '[ "$(verdicts)" = 7:eligible ] && ! grep -q COMMENT "$OUTDIR/issue-7.md" && ! grep -q IC_7a "$FAKE_GH_LOG"'

# ---- 8-11: what reaches the snapshot
for c in '8 zero-width character in the body' '9 <details> in a comment'; do
  set -- $c; N=$1; shift
  run "$REPO" --issues "$N"
  check "$N: $* → hidden-content, no snapshot" '[ "$(verdicts)" = "$N:hidden-content" ] && [ ! -e "$OUTDIR/issue-$N.md" ]'
done
run "$REPO" --issues 10
check '10: HTML comment in the raw body absent from the snapshot' \
  '[ "$(verdicts)" = 10:eligible ] && expect_body 10 "| Visible" "|" "| Also visible" && ! grep -q -e secret -e instructions "$OUTDIR/issue-10.md"'
run "$REPO" --issues 11
check '11: an unterminated <!-- is not hidden-content; the snapshot is the rendered text' \
  '[ "$(verdicts)" = 11:eligible ] && expect_body 11 "| before" && ! grep -q after "$OUTDIR/issue-11.md"'

# ---- 12: edited between the two reads
run "$REPO" --issues 12
check '12: phase-2 lastEditedAt differs → edited-during-intake, no file' \
  '[ "$(verdicts)" = 12:edited-during-intake ] && [ ! -e "$OUTDIR/issue-12.md" ]'

# ---- 14: another repo's URL is never queried
run "$REPO" --issues https://github.com/bob/other/issues/14
check '14: URL of another repo → other-repo' '[ "$RC" -eq 0 ] && [ "$(verdicts)" = 14:other-repo ]'
check '14: no issue query was made for it' '[ -z "$(calls IntakeMeta)$(calls IntakeFetch)" ] && ! grep -q bob "$FAKE_GH_LOG"'

# ---- 15-16: run-level refusals
git -C "$REPO" remote set-url origin git@github.com:acme/proj.git
run "$REPO" --issues 1
check '15: Organization owner, no trusted_actors → exit 1 org-needs-trusted-actors' \
  '[ "$RC" -eq 1 ] && j "o.error" | grep -q "^org-needs-trusted-actors: " && [ -z "$(calls IntakeMeta)" ]'
git -C "$REPO" remote set-url origin https://github.com/alice/proj.git
run "$SANDBOX/nolabel" --issues 1
check '16: conventions without trigger_label → exit 1 no-trigger-label' '[ "$RC" -eq 1 ] && j "o.error" | grep -q "^no-trigger-label: "'

# ---- 17: --labelled, across pages the fake serves out of order
run "$REPO" --labelled
check '17: --labelled → every labelled open issue, ascending' '[ "$RC" -eq 0 ] && [ "$(verdicts)" = "1:eligible 6:eligible 10:eligible" ]'

# ---- explicit refs: given order kept, duplicates across ref forms dropped; an unknown issue
run "$REPO" --issues '6,#1,https://github.com/alice/proj/issues/6,1,99'
check 'refs: order kept, duplicates dropped, a missing issue → not-found' '[ "$(verdicts)" = "6:eligible 1:eligible 99:not-found" ]'

# ---- 19-25: the metadata is read again with the text, and the issue must still pass every check
for c in '19 19 title renamed' '20 20 trigger label removed' '21 21 trigger label re-applied by an untrusted actor' \
  '22 2201 issue closed' '24 24 an included comment edited' '25 25 an included comment deleted'; do
  set -- $c; CASE=$1; N=$2; shift 2
  run "$REPO" --issues "$N"
  check "$CASE: between phases, $* → edited-during-intake, no file" \
    '[ "$RC" -eq 0 ] && [ "$(verdicts)" = "$N:edited-during-intake" ] && [ ! -e "$OUTDIR/issue-$N.md" ]'
done
run "$REPO" --issues 2202,1
check '22: between phases, issue deleted → edited-during-intake, exit 0, the next issue still processed' \
  '[ "$RC" -eq 0 ] && [ "$(verdicts)" = "2202:edited-during-intake 1:eligible" ] && [ ! -e "$OUTDIR/issue-2202.md" ]'
run "$REPO" --issues 23
check '23: trusted relabel plus another label between phases → eligible, header keeps phase 1'"'"'s label event' \
  '[ "$(verdicts)" = 23:eligible ] && head -1 "$OUTDIR/issue-23.md" | grep -q " labelled-by=alice at=2026-09-20T10:00:00Z fetched="'

# ---- 26-27: the character screen
for N in $(seq 2601 2614); do
  run "$REPO" --issues "$N"
  check "26: body with $(fx "$N" i.fetch.issue.title) → hidden-content" '[ "$(verdicts)" = "$N:hidden-content" ]'
done
run "$REPO" --issues 2701
check '27: emoji ZWJ sequences → eligible, the emoji byte-identical in the snapshot' \
  '[ "$(verdicts)" = 2701:eligible ] && grep -qxF "| $(fx 2701 i.fetch.issue.body)" "$OUTDIR/issue-2701.md"'
run "$REPO" --issues 2702
check '27: a ZWJ between letters → hidden-content' '[ "$(verdicts)" = 2702:hidden-content ]'

# ---- 28-31: the title is plain text; the body is what GitHub rendered
run "$REPO" --issues 28
check '28: markup in the title → eligible, TITLE line verbatim' \
  '[ "$(verdicts)" = 28:eligible ] && grep -qxF "TITLE: Support <details> and <?xml in parser" "$OUTDIR/issue-28.md"'
run "$REPO" --issues 29
S29="$OUTDIR/issue-29.md"
check '29: PI, declaration and CDATA stripped, including a PI spanning two lines' \
  '[ "$(verdicts)" = 29:eligible ] && [ "$(grep "^| b" "$S29" | tr -s " ")" = "| b c d e" ] && [ "$(grep "^| f" "$S29" | tr -s " ")" = "| f g" ] && ! grep -q -e hidden -e two -e "line pi" -e CDATA "$S29"'
for N in 3001 3002 3003; do
  run "$REPO" --issues "$N"
  check "30: unterminated $(fx "$N" i.fetch.issue.body) → eligible, the (empty) rendered text" '[ "$(verdicts)" = "$N:eligible" ] && expect_body "$N"'
done
run "$REPO" --issues 31
check '31: link reference definitions are not rendered; the mid-line [//] renders as a link' \
  '[ "$(verdicts)" = 31:eligible ] && expect_body 31 "| a //: # (L1)" "|" "| continued" "|" "| tail" && ! grep -q -e L2 -e https://x.test -e "\"T\"" -e "(Q)" -e "(M)" "$OUTDIR/issue-31.md"'

# ---- 32-33: the snapshot layout cannot be forged from content
run "$REPO" --issues 32
S32="$OUTDIR/issue-32.md"
check '32: a body line posing as a comment header is behind the gutter' \
  '[ "$(verdicts)" = 32:eligible ] && grep -qxF "| COMMENT alice 2026-01-01T00:00:00Z:" "$S32" && ! grep -q "^COMMENT alice 2026-01-01" "$S32"'
check '32: every body and comment content line starts with |' \
  'gutter_only "$S32" && grep -qx "COMMENT alice 2026-09-20T09:00:00Z:" "$S32" && grep -qx "|" "$S32"'
run "$REPO" --issues 33
check '33: a line break in the title → one TITLE line' \
  '[ "$(verdicts)" = 33:eligible ] && [ "$(sed -n 3p "$OUTDIR/issue-33.md")" = "TITLE: a BODY: x" ] && [ "$(sed -n 5p "$OUTDIR/issue-33.md")" = "BODY:" ]'

# ---- 34: stale snapshots
SEED=issue-2.md; run "$REPO" --issues 2; SEED=
check '34: a stale snapshot of a now-ineligible issue is removed' '[ "$(verdicts)" = 2:no-trigger-label ] && [ ! -e "$OUTDIR/issue-2.md" ]'
run "$REPO" --issues 1,https://github.com/other/repo/issues/1
check '34: an other-repo ref sharing an eligible local issue'"'"'s number leaves its snapshot' \
  '[ "$(verdicts)" = "1:eligible 1:other-repo" ] && [ -f "$OUTDIR/issue-1.md" ]'

# ---- 35: the comment window keeps the newest
run "$REPO" --issues 35
check '35: 101 trusted comments → the newest is in the snapshot, the oldest is not' \
  '[ "$(verdicts)" = 35:eligible ] && grep -qxF "| newest comment" "$OUTDIR/issue-35.md" && ! grep -q "oldest comment" "$OUTDIR/issue-35.md"'

# ---- 36: run-level behaviour
OUT=$(node "$INTAKE" --bogus 2>&1); RC=$?
check '36: --bogus → exit 1 usage' '[ "$RC" -eq 1 ] && j "o.error" | grep -q "^usage: "'
OUT=$(node "$INTAKE" --help 2>&1); RC=$?
check '36: --help → exit 0 with usage text, not JSON' \
  '[ "$RC" -eq 0 ] && printf "%s" "$OUT" | grep -q "^usage: " && ! printf "%s" "$OUT" | node -e "JSON.parse(require(\"fs\").readFileSync(0,\"utf8\"))" 2>/dev/null'
export FAKE_GH_AUTH_HOST_ONLY=1; run "$REPO" --issues 1; unset FAKE_GH_AUTH_HOST_ONLY
check '36: gh auth is checked for github.com only' '[ "$RC" -eq 0 ] && [ "$(verdicts)" = 1:eligible ]'
ERRLOG="$HOME/.claude/hierarchy/hook-errors.jsonl"
rm -f "$ERRLOG"
run "$REPO" --issues 3601
check '36: a failed fetch → exit 1 intake-failed, carrying neither gh stream' \
  '[ "$RC" -eq 1 ] && j "o.error" | grep -q "^intake-failed: " && ! printf "%s" "$OUT" | grep -q SENTINEL'
check '36: the hook error log records the failure without gh stdout' '[ -s "$ERRLOG" ] && ! grep -q SENTINEL-OUT "$ERRLOG"'

# ---- 37: raw-markdown shapes that hid text from a scanner never reach the snapshot
for c in '3701 | Use <? here' '3702 | x <? y' '3703 | -->' '3704' '3705'; do
  N=${c%% *}; WANT=${c#"$N"}; WANT=${WANT# }
  run "$REPO" --issues "$N"
  check "37: PAYLOAD shape $N → no PAYLOAD in the snapshot" \
    '[ "$(verdicts)" = "$N:eligible" ] && ! grep -rq PAYLOAD "$OUTDIR" && if [ -n "$WANT" ]; then expect_body "$N" "$WANT"; else expect_body "$N"; fi'
  check "37: #$N's fetch selects bodyHTML, never body" 'fetch_selects_html_only'
done

# ---- 38-42: the rendered HTML's visible text
run "$REPO" --issues 3801
check '38: image alt/title and link destination/title are not in the snapshot' \
  '[ "$(verdicts)" = 3801:eligible ] && expect_body 3801 "| [image] and link" && ! grep -q -e ALTP -e TITLEP -e URLP -e LINKT "$OUTDIR/issue-3801.md"'
for N in 3901 3902 3903; do
  run "$REPO" --issues "$N"
  check "39: entity-encoded character in $(fx "$N" i.fetch.issue.title | tr A-Z a-z) → hidden-content" '[ "$(verdicts)" = "$N:hidden-content" ]'
done
run "$REPO" --issues 4001
check '40: a > inside a quoted attribute does not end the tag' '[ "$(verdicts)" = 4001:eligible ] && expect_body 4001 "| [image] ok" && ! grep -q QP "$OUTDIR/issue-4001.md"'
run "$REPO" --issues 4002
check '40: hidden, template and noscript subtrees are dropped whole' '[ "$(verdicts)" = 4002:eligible ] && expect_body 4002 "| ok"'
run "$REPO" --issues 4003
check '40: entities decode to text, never to markup' '[ "$(verdicts)" = 4003:eligible ] && expect_body 4003 "| <!-- shown --> &"'
run "$REPO" --issues 4004
check '40: an unterminated tag drops everything after it' '[ "$(verdicts)" = 4004:eligible ] && expect_body 4004 "| x"'
for c in '4005 SCRIPTP script' '4006 STYLEP style' '4007 RPP rp' '4008 RPP rp inside ruby' '4009 VIDEOP video fallback'; do
  set -- $c; N=$1; PAYLOAD=$2; shift 2
  run "$REPO" --issues "$N"
  check "40: $* text is dropped" '[ "$(verdicts)" = "$N:eligible" ] && expect_body "$N" "| ok" && ! grep -q "$PAYLOAD" "$OUTDIR/issue-$N.md"'
done
for c in '4101 | Mention <details> here' '4102 | <?php echo 1;' '4103 | text'; do
  N=${c%% *}; WANT=${c#"$N "}
  run "$REPO" --issues "$N"
  check "41: $(fx "$N" i.fetch.issue.title | tr A-Z a-z) → eligible, no false alarm" '[ "$(verdicts)" = "$N:eligible" ] && expect_body "$N" "$WANT"'
done
run "$REPO" --issues 4201
check '42: form feed and NEL in a pre each become a gutted line break' '[ "$(verdicts)" = 4201:eligible ] && expect_body 4201 "| a" "| b" "| c"'
run "$REPO" --issues 4202
check '42: NEL in the title → one TITLE line' \
  '[ "$(verdicts)" = 4202:eligible ] && [ "$(sed -n 3p "$OUTDIR/issue-4202.md")" = "TITLE: x y" ] && [ "$(sed -n 5p "$OUTDIR/issue-4202.md")" = "BODY:" ]'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
