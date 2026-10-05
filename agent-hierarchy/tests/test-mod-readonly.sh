#!/bin/bash
# agent-hierarchy — the mod acts only through an allow-list: module source under mod/ (its tests and
# types aside) calls only the allowed `$` methods, registers only the allowed events with a literal
# name, never reaches `$` indirectly, and `claude plugin validate` reports nothing beyond the lists.
# Planted cases in a scratch copy show each forbidden form is caught and each allowed form is not.
# Usage: bash tests/test-mod-readonly.sh   (exits 0 iff all cases pass)

PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/agent-hierarchy-mod-readonly-test.XXXXXX")"
[ -n "$SANDBOX" ] && [ -d "$SANDBOX" ] || { echo "mktemp failed"; exit 1; }
trap 'rm -rf "$SANDBOX"' EXIT
PASS=0; FAIL=0

check() {
  local name=$1; shift
  if eval "$@"; then PASS=$((PASS+1)); echo "PASS: $name"; else FAIL=$((FAIL+1)); echo "FAIL: $name (OUT=${OUT:0:400})"; fi
}

# The one copy of what the mod may do. Calls are `$.<noun>.<method>`; events are what `on(...)` may name.
ALLOWED_CALLS="session.cwd session.id fs.stat fs.read fs.exists clock.every clock.now state.get state.set ui.status ui.toast ui.open ui.resolve command.register"
ALLOWED_EVENTS="session.start ui.close command.run ui.render"

# <mod dir>: every guard violation in the module source under it, as file:line: reason; empty when clean.
violations() {
  node - "$1" "$ALLOWED_CALLS" "$ALLOWED_EVENTS" <<'JS'
const fs = require("fs"), path = require("path");
const [dir, callsArg, eventsArg] = process.argv.slice(2);
const CALLS = new Set(callsArg.split(" ")), EVENTS = new Set(eventsArg.split(" "));
const files = [];
(function walk(d, top) {
  for (const ent of fs.readdirSync(d, { withFileTypes: true })) {
    const p = path.join(d, ent.name);
    if (ent.isDirectory()) { if (!(top && (ent.name === "tests" || ent.name === "types"))) walk(p, false); }
    else if (/\.(ts|tsx|jsx|js|mjs|cjs|mts|cts)$/.test(ent.name)) files.push(p);
  }
})(dir, true);

// The source with comments dropped and literal text blanked, same length and lines, so offsets match;
// `${…}` code inside a template stays. String literals are kept by their opening offset.
// ponytail: no regex-literal handling; a regex holding a quote or `//` would confuse it. A real tokenizer if one ever does.
function lex(src) {
  const sp = (s) => s.replace(/[^\n]/g, " ");
  const strings = new Map(), tpl = [];
  let out = "", i = 0, depth = 0, inTpl = false;
  while (i < src.length) {
    const c = src[i], n = src[i + 1];
    if (inTpl) {
      if (c === "\\") { out += sp(src.slice(i, i + 2)); i += 2; }
      else if (c === "`") { out += c; i++; inTpl = false; }
      else if (c === "$" && n === "{") { out += "  "; i += 2; tpl.push(depth); inTpl = false; }
      else { out += sp(c); i++; }
      continue;
    }
    if (c === "/" && n === "/") { let e = src.indexOf("\n", i); if (e < 0) e = src.length; out += sp(src.slice(i, e)); i = e; continue; }
    if (c === "/" && n === "*") { let e = src.indexOf("*/", i + 2); e = e < 0 ? src.length : e + 2; out += sp(src.slice(i, e)); i = e; continue; }
    if (c === "'" || c === '"') {
      let j = i + 1, val = "";
      while (j < src.length && src[j] !== c && src[j] !== "\n") { if (src[j] === "\\") { val += src[j + 1] || ""; j += 2; } else val += src[j++]; }
      const closed = src[j] === c;
      strings.set(i, val);
      out += c + sp(src.slice(i + 1, j)) + (closed ? c : "");
      i = closed ? j + 1 : j;
      continue;
    }
    if (c === "`") { out += c; i++; inTpl = true; continue; }
    if (c === "}" && tpl.length && tpl[tpl.length - 1] === depth) { tpl.pop(); out += " "; i++; inTpl = true; continue; }
    if (c === "{") depth++;
    else if (c === "}") depth--;
    out += c; i++;
  }
  return { code: out, strings };
}

// `$` or `on` at i is a parameter: first in a parenthesised list that is not a call, closing into `=>`, `{` or a return type.
function isParam(code, i, rest) {
  if (!/^\s*[,:)]/.test(rest)) return false;
  const before = code.slice(0, i).replace(/\s+$/, "");
  if (!before.endsWith("(")) return false;
  const pre = before.slice(0, -1).replace(/\s+$/, "");
  if (!(pre === "" || /[^\w$)\].]$/.test(pre) || /\basync$/.test(pre) || /\bfunction(\s+[\w$]+)?$/.test(pre))) return false;
  let d = 0;
  for (let k = before.length - 1; k < code.length; k++) {
    if (code[k] === "(") d++;
    else if (code[k] === ")" && --d === 0) return /^\s*(=>|\{|:)/.test(code.slice(k + 1));
  }
  return false;
}

const found = [];
for (const f of files) {
  const rel = path.relative(dir, f);
  const { code, strings } = lex(fs.readFileSync(f, "utf8"));
  const at = (i, why) => found.push(`${rel}:${code.slice(0, i).split("\n").length}: ${why}`);
  for (const m of code.matchAll(/(?<![\w$])\$(?![\w$])/g)) {
    const i = m.index, rest = code.slice(i + 1);
    if (rel === "view.ts") { at(i, "view.ts holds a $"); continue; }
    const call = /^\s*\.\s*([A-Za-z_$][\w$]*)\s*\.\s*([A-Za-z_$][\w$]*)/.exec(rest);
    if (call) { if (!CALLS.has(`${call[1]}.${call[2]}`)) at(i, `$.${call[1]}.${call[2]} is not an allowed call`); continue; }
    if (/^\s*\./.test(rest)) { at(i, "$.<noun> without a method"); continue; }
    if (!isParam(code, i, rest)) at(i, "$ used other than as a handler parameter or $.<noun>.<method>");
  }
  for (const m of code.matchAll(/\b(?:globalThis|eval|Reflect|Proxy)\b|\bFunction\s*\(/g)) at(m.index, `banned token ${m[0]}`);
  for (const m of code.matchAll(/(?<![\w$.])on(?![\w$])/g)) {
    const i = m.index, rest = code.slice(i + 2), open = /^\s*\(\s*/.exec(rest);
    if (open) {
      const arg = i + 2 + open[0].length;
      if (!strings.has(arg)) at(i, "on( with an event that is not a string literal");
      else if (!EVENTS.has(strings.get(arg))) at(i, `on('${strings.get(arg)}') is not an allowed registration`);
      continue;
    }
    if (!/^\s*=>/.test(rest) && !isParam(code, i, rest)) at(i, "on used other than as on('<event>', …) or register's parameter");
  }
}
process.stdout.write(found.join("\n"));
JS
}

check "the mod's hooks module exists, so the guard has source to read" '[ -f "$PLUGIN/mod/register.tsx" ]'
OUT=$(violations "$PLUGIN/mod")
check "the module source passes the allow-list" '[ -z "$OUT" ]'

# Second net: validate's own account of what the module registers and calls.
mkdir -p "$SANDBOX/home/.claude"
VAL=$(cd "$SANDBOX" && HOME="$SANDBOX/home" CLAUDE_CONFIG_DIR="$SANDBOX/home/.claude" perl -e 'alarm shift; exec @ARGV' 120 claude plugin validate "$PLUGIN" 2>&1); VRC=$?
OUT=$VAL
check "claude plugin validate passes" '[ "$VRC" = 0 ]'
HOOKS=$(printf '%s\n' "$VAL" | sed -nE 's/.* \.\/[^ ]* hooks: (.*)$/\1/p' | tr ',' ' ')
CALLS=$(printf '%s\n' "$VAL" | sed -nE 's/.* \.\/[^ ]* calls: (.*)$/\1/p' | grep -v '^nothing on \$$' | tr ',' ' ' | sed 's/\$\.//g')
OUT="hooks: $HOOKS | calls: $CALLS"
outside() { local w; for w in $1; do case " $2 " in *" $w "*) ;; *) echo "$w";; esac; done; }
check "validate reports hooks, all of them allowed events" '[ -n "$HOOKS" ] && [ -z "$(outside "$HOOKS" "$ALLOWED_EVENTS")" ]'
check "every call validate reports is an allowed call" '[ -z "$(outside "$CALLS" "$ALLOWED_CALLS")" ]'

# <line>...: the guard's verdict on a scratch copy of mod/ with those lines appended to register.tsx.
planted() {
  rm -rf "${SANDBOX:?}/mod"; cp -R "$PLUGIN/mod" "$SANDBOX/mod"
  printf '%s\n' "$@" >> "$SANDBOX/mod/register.tsx"
  violations "$SANDBOX/mod"
}
while IFS= read -r line; do
  OUT=$(planted "$line")
  check "guard catches: $line" '[ -n "$OUT" ]'
done <<'EOF'
$.session.authorize()
$.session.append()
$.prompt.fill()
$.turn.abort()
$.mcp.call()
$.command.run()
$.config.set()
$.http.fetch()
$.store.set()
$.ui.copy()
$.process.run(['herdr','agent','get'])
const { session } = $
const s = $.session
$['session']
f($)
globalThis
on('classic.PermissionRequest', ($, e, next) => next(e))
on('*', ($, e, next) => next(e))
on('tool.check', ($, e, next) => next(e))
on('fs.write', ($, e, next) => next(e))
on(name, ($, e, next) => next(e))
EOF
OUT=$(planted 'const r = ($, e, next) => $.fs.read(p)' '$.ui.status(t)' 'const t = `${x}`')
check "guard passes the allowed forms: \$.fs.read(p), \$.ui.status(t), (\$, e, next) =>, \`\${x}\`" '[ -z "$OUT" ]'
rm -rf "${SANDBOX:?}/mod"; cp -R "$PLUGIN/mod" "$SANDBOX/mod"; mkdir -p "$SANDBOX/mod/tests"
printf '%s\n' '$.fs.write(p, t)' "on('fs.write', (\$, e, next) => next(e))" > "$SANDBOX/mod/tests/x.test.ts"
OUT=$(violations "$SANDBOX/mod")
check "guard ignores anything under tests/" '[ -z "$OUT" ]'
printf '%s\n' 'export const pure = (s: string) => `${s}`' 'const x = $' > "$SANDBOX/mod/view.ts"
OUT=$(violations "$SANDBOX/mod")
check "view.ts may hold no \$ at all" '[ -n "$OUT" ] && printf "%s" "$OUT" | grep -q "^view.ts:"'

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
