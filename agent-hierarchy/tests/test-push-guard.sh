#!/bin/bash
# agent-hierarchy — PreToolUse push guard: the deny table, detection through shell syntax, the
# conventions read from origin's default branch (never the working tree), and the `check` CLI mode.
# HOME-redirected; every repo lives in a throwaway sandbox and every setup push runs outside the hook.
# Usage: bash tests/test-push-guard.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
unset AH_TEAM_FILE  # every session roster.mjs launches carries one; a test must not inherit it
unset CLAUDE_PID  # every Claude session exports one; a test must not inherit it
HOOK="$PLUGIN/hooks/pretooluse-push-guard.mjs"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-pushguard-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
export HOME="$SANDBOX/home"
mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
git config --global init.defaultBranch main
git config --global advice.detachedHead false
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (RC=$RC OUT=${OUT:0:400})"; fi
}

# ---- setup: an opted-in clone, a non-opted repo, and a repo whose committed conventions are invalid
mkrepo() { # <name> <conventions text, or empty for none>
  git init -q --bare "$SANDBOX/$1-origin.git"
  git clone -q "$SANDBOX/$1-origin.git" "$SANDBOX/$1" 2>/dev/null
  mkdir -p "$SANDBOX/$1/sub"
  echo readme > "$SANDBOX/$1/README"
  [ -n "$2" ] && { mkdir -p "$SANDBOX/$1/.claude"; printf '%s' "$2" > "$SANDBOX/$1/.claude/ah-conventions.json"; }
  git -C "$SANDBOX/$1" add -A && git -C "$SANDBOX/$1" commit -qm init && git -C "$SANDBOX/$1" push -q origin main
  git -C "$SANDBOX/$1" remote set-head origin main
}
mkrepo clone '{"version":1,"protected_paths":["docs/secret/**"],"protected_branches":["release/*"]}'
mkrepo other ''
mkrepo bad '{"version":1,'
CLONE="$SANDBOX/clone"; OTHER="$SANDBOX/other"; BAD="$SANDBOX/bad"
mkdir -p "$CLONE/plugins/p/.claude-plugin"
echo '{}' > "$CLONE/plugins/p/.claude-plugin/plugin.json"
echo x > "$CLONE/.claude/x"
git -C "$CLONE" add -A && git -C "$CLONE" commit -qm plugin && git -C "$CLONE" push -q origin main
git -C "$CLONE" remote add upstream "$SANDBOX/clone-origin.git"

feat() { # <repo> [path...] — reset feat to main, then one commit touching each path
  local r=$1; shift
  git -C "$r" checkout -qB feat main
  local p
  for p in "$@"; do mkdir -p "$r/$(dirname "$p")"; echo "$RANDOM" >> "$r/$p"; git -C "$r" add "$p"; done
  [ $# -eq 0 ] || git -C "$r" commit -qm "touch $*"
}
guard() { # <cwd> <command>
  OUT=$(node -e 'const [d,c]=process.argv.slice(1);process.stdout.write(JSON.stringify({session_id:"s",hook_event_name:"PreToolUse",cwd:d,tool_name:"Bash",tool_input:{command:c}}))' "$1" "$2" | node "$HOOK" 2>&1); RC=$?
}
allowed() { [ "$RC" -eq 0 ] && [ -z "$OUT" ]; }
denied() { # <rule> [text the model-facing reason must also carry]
  [ "$RC" -eq 0 ] && printf '%s' "$OUT" | node -e '
    const [rule, extra] = process.argv.slice(1);
    const o = JSON.parse(require("fs").readFileSync(0, "utf8"));
    const h = o.hookSpecificOutput || {};
    const r = h.permissionDecisionReason || "";
    process.exit(h.permissionDecision === "deny" && r.includes(`ah-push-guard:${rule} `) && (!extra || r.includes(extra)) ? 0 : 1);
  ' "$1" "$2"
}
expect_allow() { # <label> <command> [cwd]
  guard "${3:-$CLONE}" "$2"; check "$1: allow — $2" 'allowed'
}
expect_deny() { # <label> <rule> <command> [cwd]
  guard "${4:-$CLONE}" "$3"; check "$1: deny $2 — $3" "denied $2"
}
calm_has() { # <text> — the user-facing systemMessage contains it
  printf '%s' "$OUT" | node -e 'process.exit((JSON.parse(require("fs").readFileSync(0,"utf8")).systemMessage||"").includes(process.argv[1])?0:1)' "$1"
}

# ---- 1-4: ordinary commands and ordinary pushes pass
feat "$CLONE" src/a.js
expect_allow 1 'ls -la'
expect_allow 2 'git status'
expect_allow 3 'git push origin feat'
feat "$CLONE"
expect_allow 4 'git push -u origin HEAD'

# ---- 5-11: the flag, remote and branch rules
expect_deny 5 PG-FORCE 'git push --force origin feat'
for c in 'git push -uf origin feat' 'git push origin +feat' 'git push --force-with-lease origin feat'; do
  expect_deny 6 PG-FORCE "$c"
done
expect_deny 7 PG-NOVERIFY 'git push --no-verify origin feat'
for c in 'git push origin --delete feat' 'git push origin :feat' 'git push --prune origin'; do
  expect_deny 8 PG-DELETE "$c"
done
for c in 'git push --all origin' 'git push --tags origin' 'git push origin refs/tags/v1' "git push origin 'refs/heads/*:refs/heads/*'"; do
  expect_deny 9 PG-BULK "$c"
done
for c in 'git push upstream feat' 'git push https://example.com/x.git feat'; do
  expect_deny 10 PG-REMOTE "$c"
done
for c in 'git push origin main' 'git push origin HEAD:main' 'git push origin feat:release/1'; do
  expect_deny 11 PG-BRANCH "$c"
done

# ---- 12: a detached HEAD has no destination to check
git -C "$CLONE" checkout -q --detach main
expect_deny 12 PG-BRANCH 'git push origin HEAD'
check '42: detached HEAD — the calm line says unresolved destination, not protected branch HEAD' \
  'calm_has "unresolved destination" && ! calm_has "protected branch HEAD"'
git -C "$CLONE" checkout -q feat

# ---- 13-18: protected paths in the pushed range
feat "$CLONE" .github/workflows/ci.yml
expect_deny 13 PG-PATHS 'git push origin feat'
feat "$CLONE" docs/secret/k.txt
expect_deny 14 PG-PATHS 'git push origin feat'
feat "$CLONE" plugins/p/hooks/x.mjs
expect_deny 15 PG-PATHS 'git push origin feat'
feat "$CLONE" src/hooks/useThing.ts
expect_allow 16 'git push origin feat'
feat "$CLONE"
mkdir -p "$CLONE/other" && git -C "$CLONE" mv .claude/x other/x && git -C "$CLONE" commit -qm rename
guard "$CLONE" 'git push origin feat'
check '17: deny PG-PATHS on the old side of a rename' 'denied PG-PATHS .claude/x'
feat "$CLONE"
printf '%s' '{"version":1}' > "$CLONE/.claude/ah-conventions.json"
mkdir -p "$CLONE/docs/secret" && echo k > "$CLONE/docs/secret/k.txt"
git -C "$CLONE" add -A && git -C "$CLONE" commit -qm loosen
guard "$CLONE" 'git push origin feat'
check '18: conventions loosened on feat only — origin/main'"'"'s extension still enforced' 'denied PG-PATHS docs/secret/k.txt'

# ---- 19-20: remote configuration
feat "$CLONE"
for c in 'git remote add evil https://e.x/r.git' 'git remote set-url origin X' 'git remote set-head origin feat' \
  'git config remote.origin.url X' 'git config url.X.pushInsteadOf Y' 'git -c remote.origin.url=X push origin feat' \
  'git update-ref refs/remotes/origin/main HEAD'; do
  expect_deny 19 PG-REMOTECFG "$c"
done
expect_allow 20 'git config --get remote.origin.url'
expect_allow 20 'git remote -v'

# ---- 21-22: detection follows shell syntax
expect_allow 21 'git commit -m "never git push --force"'
expect_allow 21 'echo git push -f'
for c in "bash -c 'git push --force origin feat'" 'echo $(git push -f origin feat)' 'cd sub && git push -f origin feat'; do
  expect_deny 22 PG-FORCE "$c"
done

# ---- 23-24: repos that never opted in are untouched
expect_allow 23 "git -C $OTHER push --force origin main"
expect_allow 24 'git push --force origin main' "$OTHER"

# ---- 25-26: invalid committed conventions — opted in, baseline only
feat "$BAD" docs/secret/k.txt
expect_allow 25 'git push origin feat' "$BAD"
feat "$BAD" .github/x
expect_deny 26 PG-PATHS 'git push origin feat' "$BAD"

# ---- 27: the bootstrap probe — a dry run is evaluated like a real push
expect_deny 27 PG-FORCE 'git push --dry-run --force origin ah-push-guard-probe'

# ---- 28-29: check mode
feat "$CLONE" .github/x src/a.js
OUT=$(node "$HOOK" check --branch feat --cwd "$CLONE" 2>&1); RC=$?
check '28: check --branch feat reports the protected hit' '[ $RC -eq 0 ] && node -e '"'"'const o=JSON.parse(process.argv[1]);process.exit(o.opted_in===true&&JSON.stringify(o.protected_hits)==="[\".github/x\"]"?0:1)'"'"' "$OUT"'
feat "$CLONE"
OUT=$(node "$HOOK" check --branch feat --cwd "$CLONE" 2>&1); RC=$?
check '29: check --branch feat on a clean feat reports no hits' '[ $RC -eq 0 ] && node -e '"'"'const o=JSON.parse(process.argv[1]);process.exit(o.opted_in===true&&Array.isArray(o.protected_hits)&&o.protected_hits.length===0?0:1)'"'"' "$OUT"'

# ---- 30: deny output shape — the calm user line carries no marker; the marker reaches the model
calm_ok() { # <expected calm prefix>
  printf '%s' "$OUT" | node -e '
    const o = JSON.parse(require("fs").readFileSync(0, "utf8"));
    const m = o.systemMessage || "";
    const r = (o.hookSpecificOutput || {}).permissionDecisionReason || "";
    process.exit(o.hookSpecificOutput.permissionDecision === "deny" && m.startsWith(process.argv[1]) && !m.includes("ah-push-guard:")
      && !m.includes("\n") && /^ah-push-guard:PG-[A-Z]+ /.test(r) ? 0 : 1);
  ' "$1"
}
guard "$CLONE" 'git push --force origin feat'
check '30: deny output — systemMessage is the calm line, reason carries the marker' 'calm_ok "ah push-guard stopped a git push (force push). Nothing was sent."'
guard "$CLONE" 'git remote add evil https://e.x/r.git'
check '30: remote-change deny output — calm line, marker in the reason' 'calm_ok "ah push-guard stopped a git remote change (remote config change)."'

# ---- 31-35: globs, push option arguments, text that is not a command
feat "$CLONE" src/a.js
expect_allow 31 'git push origin feat:release/1/x'
expect_deny 32 PG-DELETE 'git push -ud origin feat'
expect_allow 33 'git push -o ci.skip origin feat'
expect_allow 33 'git push --push-option ci.skip origin feat'
expect_deny 34 PG-REMOTE 'git push --repo upstream feat'
expect_allow 35 'git push origin feat 2>&1 | tail -5'
expect_allow 35 "git commit -F - <<'EOF'
git push --force
EOF"
expect_allow 35 '# git push -f'

# ---- 36-38: reserved words, wrappers, shells with bundled -c, unlisted global options
for c in 'if git push -f origin feat; then echo ok; fi' '{ git push -f origin feat; }' '! git push -f origin feat' \
  'time git push -f origin feat' 'timeout 60 git push -f origin feat' 'env A=1 git push -f origin feat' \
  'sudo -n git push -f origin feat' 'nohup git push -f origin feat'; do
  expect_deny 36 PG-FORCE "$c"
done
for c in "bash -lc 'git push -f origin feat'" '/bin/sh -ec "git push -f origin feat"'; do
  expect_deny 37 PG-FORCE "$c"
done
for c in 'git --no-optional-locks push -f origin feat' 'git --namespace foo push -f origin feat'; do
  expect_deny 38 PG-FORCE "$c"
done

# ---- 39: --git-dir / --work-tree / GIT_DIR choose the repo
expect_allow 39a "git --git-dir=$OTHER/.git --work-tree=$OTHER push --force origin main"
expect_deny 39b PG-FORCE "git --git-dir=$CLONE/.git --work-tree=$CLONE push --force origin feat" "$OTHER"
expect_deny 39c PG-FORCE "GIT_DIR=$CLONE/.git git push -f origin feat" "$OTHER"

# ---- 40-41: git config reads pass; writes to a protected key or section are denied
for c in 'git config remote.origin.url' 'git config get remote.origin.url' "git config --get-regexp '^remote\\.'" \
  'git config list' 'git config user.name remote.x'; do
  expect_allow 40 "$c"
done
for c in 'git config set remote.origin.url X' 'git config --unset remote.origin.pushurl' 'git config unset url.X.insteadOf' \
  'git config --remove-section remote.origin' 'git config rename-section remote.origin remote.y' \
  'git config --global url.X.pushInsteadOf Y' 'git config --add remote.origin.push HEAD' 'git config Remote.Origin.URL X' \
  'git config --edit' 'git config edit' 'git --config-env=remote.origin.url=V push origin feat'; do
  expect_deny 41 PG-REMOTECFG "$c"
done

# ---- 43: check mode outside an opted-in repo
OUT=$(node "$HOOK" check --branch feat --cwd "$OTHER" 2>&1); RC=$?
check '43: check in a non-opted repo reports the inert values' '[ $RC -eq 0 ] && node -e '"'"'const o=JSON.parse(process.argv[1]);process.exit(o.opted_in===false&&o.range===null&&Array.isArray(o.protected_hits)&&o.protected_hits.length===0&&o.branch_protected===false?0:1)'"'"' "$OUT"'
mkdir -p "$SANDBOX/norepo"
OUT=$(GIT_CEILING_DIRECTORIES="$SANDBOX" node "$HOOK" check --branch feat --cwd "$SANDBOX/norepo" 2>&1); RC=$?
check '43: check outside a repo exits 1 with an error' '[ $RC -eq 1 ] && node -e '"'"'process.exit(typeof JSON.parse(process.argv[1]).error==="string"?0:1)'"'"' "$OUT"'

# ---- 44: what the model-facing detail carries
feat "$CLONE" .github/workflows/ci.yml
guard "$CLONE" 'git push origin feat'
check '44: the PG-PATHS reason carries the range' 'denied PG-PATHS "range refs/remotes/origin/main..feat"'
guard "$CLONE" 'git push --force origin feat'
check '44: the PG-FORCE reason names the flag and the conventions source' \
  'denied PG-FORCE "flag --force" && denied PG-FORCE "conventions refs/remotes/origin/main"'

# ---- r3 setup: a tag, a non-default branch carrying a protected path, and a way to advance origin/main
git -C "$CLONE" tag v9 feat
git -C "$CLONE" checkout -qb x main
mkdir -p "$CLONE/.github" && echo x > "$CLONE/.github/x" && git -C "$CLONE" add .github/x && git -C "$CLONE" commit -qm x
git clone -q "$SANDBOX/clone-origin.git" "$SANDBOX/adv" 2>/dev/null
advance_main() { # origin/main gains a commit touching .github/ci.yml; the clone fetches it
  git -C "$SANDBOX/adv" pull -q --ff-only origin main
  mkdir -p "$SANDBOX/adv/.github" && echo "$RANDOM" >> "$SANDBOX/adv/.github/ci.yml"
  git -C "$SANDBOX/adv" add -A && git -C "$SANDBOX/adv" commit -qm advance && git -C "$SANDBOX/adv" push -q origin main
  git -C "$CLONE" fetch -q origin
}

# ---- 45-48: commits already on the default branch are not this push's changes; merges count dense
feat "$CLONE" src/a.js
git -C "$CLONE" push -q -f origin feat
advance_main
git -C "$CLONE" merge -q --no-edit origin/main
expect_allow 45 'git push origin feat'
git -C "$CLONE" checkout -qb feat2 main
mkdir -p "$CLONE/src" && echo b > "$CLONE/src/b.js" && git -C "$CLONE" add src/b.js && git -C "$CLONE" commit -qm b
advance_main
git -C "$CLONE" merge -q --no-edit origin/main
expect_allow 46 'git push origin feat2'
OUT=$(node "$HOOK" check --branch feat2 --cwd "$CLONE" 2>&1); RC=$?
check '46: check --branch feat2 after merging main reports no hits' '[ $RC -eq 0 ] && node -e '"'"'const o=JSON.parse(process.argv[1]);process.exit(Array.isArray(o.protected_hits)&&o.protected_hits.length===0?0:1)'"'"' "$OUT"'
feat "$CLONE" src/a.js
git -C "$CLONE" push -q -f origin feat
advance_main
git -C "$CLONE" merge -q --no-commit origin/main >/dev/null 2>&1
echo evil > "$CLONE/.github/ci.yml" && git -C "$CLONE" add .github/ci.yml && git -C "$CLONE" commit -qm evil
expect_deny 47 PG-PATHS 'git push origin feat'
feat "$CLONE" src/a.js
git -C "$CLONE" merge -q --no-edit x
expect_deny 48 PG-PATHS 'git push origin feat'

# ---- 49-52: a push with no refspec goes where git would send it
git -C "$CLONE" checkout -qb feat3 origin/main
mkdir -p "$CLONE/src" && echo c > "$CLONE/src/c.js" && git -C "$CLONE" add src/c.js && git -C "$CLONE" commit -qm c
expect_allow 49 'git push'
git -C "$CLONE" config push.default upstream
expect_deny 50 PG-BRANCH 'git push'
git -C "$CLONE" config push.default matching
expect_deny 51 PG-BULK 'git push'
git -C "$CLONE" config push.default nothing
expect_allow 51 'git push'
git -C "$CLONE" config --unset push.default
feat "$CLONE" src/a.js
git -C "$CLONE" config remote.origin.push refs/heads/feat:refs/heads/main
expect_deny 52 PG-BRANCH 'git push'
git -C "$CLONE" config --unset remote.origin.push

# ---- 53-55: @, tags, hooksPath
expect_allow 53 'git push origin @'
expect_deny 53 PG-BRANCH 'git push origin @:main'
expect_deny 54 PG-BULK 'git push origin v9'
expect_deny 54 PG-BULK 'git push origin tag v9'
expect_allow 54 'git push origin feat'
expect_deny 55 PG-NOVERIFY 'git -c core.hooksPath=/dev/null push origin feat'
expect_allow 55 'git -c core.hooksPath=/dev/null commit -m x'
expect_allow 55 'git config core.hooksPath .husky'
expect_deny 55 PG-NOVERIFY 'git --config-env=core.hooksPath=HP push origin feat'
expect_deny 55 PG-NOVERIFY 'git --config-env core.hooksPath=HP push origin feat'

# ---- 56-58: wrapper and shell options that take a value
expect_deny 56 PG-FORCE 'env -u FOO git push -f origin feat'
expect_deny 56 PG-FORCE "env -C $CLONE git push -f origin feat" "$OTHER"
expect_allow 56 "env -C $OTHER git push --force origin main"
expect_deny 56 PG-NOVERIFY 'env --unset GIT_DIR git push --no-verify origin feat'
expect_deny 56 PG-NOVERIFY "env --chdir $CLONE git push --no-verify origin feat" "$OTHER"
expect_deny 56 PG-NOVERIFY "env --chdir=$CLONE git push --no-verify origin feat" "$OTHER"
for c in 'nice -n 10 git push -f origin feat' 'command -p git push -f origin feat' 'exec -a x git push -f origin feat'; do
  expect_deny 57 PG-FORCE "$c"
done
expect_allow 57 'command -v git'
for c in "bash -euo pipefail -c 'git push -f origin feat'" 'bash -o pipefail -c "git push -f origin feat"' \
  "bash --rcfile /dev/null -c 'git push -f origin feat'"; do
  expect_deny 58 PG-FORCE "$c"
done

# ---- 59: config sections
for c in 'git config rename-section foo.bar remote.origin' 'git config --rename-section foo.bar remote.x' 'git config --remove-section remote'; do
  expect_deny 59 PG-REMOTECFG "$c"
done
expect_allow 59 'git config --remove-section foo.bar'

# ---- 60: pushd / popd move the effective repo
expect_deny 60 PG-FORCE "pushd $CLONE && git push -f origin feat" "$OTHER"
expect_allow 60 "pushd $OTHER && git push --force origin main; popd"
expect_deny 60 PG-FORCE "pushd $OTHER; popd; git push -f origin feat"

# ---- 61-67: check's settings — the committed file's team settings with defaults applied, else null
BASE_CONV='{"version":1,"protected_paths":["docs/secret/**"],"protected_branches":["release/*"]}'
BASE_SETTINGS='{"pr":{"draft":true,"issue_link":"refs","reviewers":[]},"ci_secrets":"none-on-branches","protected_paths":["docs/secret/**"],"protected_branches":["release/*"],"on_item_done":null}'
set_main_conventions() { # <text> — origin/main's committed conventions become <text>; the clone fetches them
  git -C "$SANDBOX/adv" pull -q --ff-only origin main
  printf '%s' "$1" > "$SANDBOX/adv/.claude/ah-conventions.json"
  git -C "$SANDBOX/adv" add -A && git -C "$SANDBOX/adv" commit -qm conventions && git -C "$SANDBOX/adv" push -q origin main
  git -C "$CLONE" fetch -q origin
}
run_check() { # <cwd> <branch>
  OUT=$(node "$HOOK" check --branch "$2" --cwd "$1" 2>&1); RC=$?
}
settings_is() { # <expected settings JSON> — deep equality, key order aside
  node -e 'const [o, e] = process.argv.slice(1).map((s) => JSON.parse(s)); require("assert").deepStrictEqual(o.settings, e)' "$OUT" "$1" 2>/dev/null
}
out_ok() { # <JS predicate over o, the check output>
  node -e 'const o = JSON.parse(process.argv[1]); process.exit(eval(process.argv[2]) ? 0 : 1)' "$OUT" "$1"
}
feat "$CLONE"
run_check "$CLONE" feat
check '61: check reports the committed settings with defaults' '[ $RC -eq 0 ] && settings_is "$BASE_SETTINGS"'
set_main_conventions '{"version":1,"issues":{"trigger_label":"go","trusted_actors":["a"]},"pr":{"draft":false,"issue_link":"closes","reviewers":["u1","org/t"]},"ci_secrets":"skip-ci","protected_paths":["x/**"],"protected_branches":[],"on_item_done":"team:sync"}'
run_check "$CLONE" feat
check '62: every declared setting is reported; version and issues are not' \
  '[ $RC -eq 0 ] && settings_is '"'"'{"pr":{"draft":false,"issue_link":"closes","reviewers":["u1","org/t"]},"ci_secrets":"skip-ci","protected_paths":["x/**"],"protected_branches":[],"on_item_done":"team:sync"}'"'"' && out_ok '"'"'!("version" in o.settings) && !("issues" in o.settings)'"'"
set_main_conventions '{"version":1,"pr":{"draft":false}}'
run_check "$CLONE" feat
check '63: defaults apply per key' \
  '[ $RC -eq 0 ] && settings_is '"'"'{"pr":{"draft":false,"issue_link":"refs","reviewers":[]},"ci_secrets":"none-on-branches","protected_paths":[],"protected_branches":[],"on_item_done":null}'"'"
set_main_conventions "$BASE_CONV"
git -C "$CLONE" checkout -q --detach main
run_check "$CLONE" HEAD
check '64: detached HEAD — no range, settings still reported' '[ $RC -eq 0 ] && out_ok "o.range === null" && settings_is "$BASE_SETTINGS"'
git -C "$CLONE" checkout -q feat
run_check "$BAD" feat
check '65: invalid committed conventions — settings is null' '[ $RC -eq 0 ] && out_ok "o.conventions.startsWith(\"invalid:\") && o.settings === null"'
run_check "$OTHER" feat
check '66: a repo that never opted in — settings is null' '[ $RC -eq 0 ] && out_ok "o.settings === null"'
feat "$CLONE"
printf '%s' '{"version":1}' > "$CLONE/.claude/ah-conventions.json"
mkdir -p "$CLONE/docs/secret" && echo k > "$CLONE/docs/secret/k.txt"
git -C "$CLONE" add -A && git -C "$CLONE" commit -qm loosen
run_check "$CLONE" feat
check '67: conventions loosened on feat only — settings come from origin/main' '[ $RC -eq 0 ] && settings_is "$BASE_SETTINGS"'

# ---- tokenizer edges beyond the table: redirections, heredoc bodies, option arguments, wrappers
feat "$CLONE"
expect_allow x 'git push origin feat 2>&1 | tail -3'
expect_allow x "git commit -m \"\$(cat <<'EOF'
It's done
git push --force origin main
EOF
)\""
expect_allow x 'git push -o ci.skip origin feat'
for c in '(cd sub; git push -f origin feat)' 'FOO=1 env BAR=2 /usr/bin/git -c a=b --no-pager push --force origin feat' \
  'echo `git push -f origin feat`' 'eval git push --force origin feat' "# it's a comment
git push -f origin feat"; do
  expect_deny x PG-FORCE "$c"
done
expect_deny x PG-ERROR 'git push origin no-such-branch'

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
