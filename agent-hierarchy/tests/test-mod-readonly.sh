#!/bin/bash
# agent-hierarchy — the mod acts only through an allow-list. Module source under mod/ (its tests and
# types aside) calls only the allowed `$` methods; registers only the allowed events, each with its exact
# matcher and an inline hook whose first parameter is `$`; never reaches the environment under another
# name; and returns nothing that answers a prompt, sends a message or draws an input. `claude plugin
# validate` must report nothing beyond the lists. Planted cases in a scratch copy show each forbidden form
# caught by the lexer alone, and each allowed form passed.
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

# The one copy of what the mod may do, from the 2.1.289 types. Calls are `$.<noun>.<method>`; events are
# what `on(...)` may name; an event listed in MATCHERS must carry exactly one of its matchers (key=value,
# keys sorted), any other takes none. RENDER_ELEMENTS is every RenderElement type; only Box and Text may be drawn.
ALLOWED_CALLS="session.cwd session.id fs.stat fs.read fs.exists clock.every clock.now state.get state.set ui.status ui.toast ui.open ui.resolve command.register"
ALLOWED_EVENTS="session.start ui.close command.run ui.render"
MATCHERS="command.run:command=hierarchy-pane ui.render:component=Pane,requestId=ah-status ui.render:component=AbovePrompt"
RENDER_ELEMENTS="Box Text Button Input Select Link Code Markdown Client Svg Raster Image"
DRAWABLE="Box Text"
BANNED_KEYS="context exitCode press client raster"
BANNED_TOKENS="globalThis eval Reflect Proxy arguments this"

# <mod dir>: every guard violation in the module source under it, as file:line: reason; empty when clean.
violations() {
  node - "$1" "$ALLOWED_CALLS" "$ALLOWED_EVENTS" "$MATCHERS" "$RENDER_ELEMENTS" "$DRAWABLE" "$BANNED_KEYS" "$BANNED_TOKENS" <<'JS'
const fs = require("fs"), path = require("path");
const [dir, ...lists] = process.argv.slice(2);
const [CALLS, EVENTS, , ELEMENTS, DRAWABLE, KEYS, TOKENS] = lists.map((l) => new Set(l.split(" ")));
const MATCHERS = {};
for (const m of lists[2].split(" ")) { const [ev, canon] = m.split(/:(.*)/s); (MATCHERS[ev] = MATCHERS[ev] || []).push(canon); }
let modules = [];
try { modules = JSON.parse(fs.readFileSync(path.join(dir, "hooks.json"), "utf8")).modules || []; } catch {}
modules = modules.map((m) => path.normalize(m));
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
// ponytail: no regex-literal or JSX-text handling; a quote or `//` in either can mis-blank code, and words in JSX
// text are read as code (write such text as a {'…'} string). A real tokenizer if mod code ever needs one.
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

// The top-level argument spans of the call whose "(" is at `open`, and the index of its ")"; null if unclosed.
function callArgs(code, open) {
  const list = []; let d = 0, start = open + 1;
  for (let k = open; k < code.length; k++) {
    const ch = code[k];
    if (ch === "(" || ch === "[" || ch === "{") d++;
    else if (ch === ")" || ch === "]" || ch === "}") {
      if (--d === 0) { if (code.slice(start, k).trim()) list.push([start, k]); return { list, close: k }; }
    } else if (ch === "," && d === 1) { list.push([start, k]); start = k + 1; }
  }
  return null;
}

// The parameter list of a function literal beginning at `s`, or null when none begins there.
function fnParams(code, s) {
  const lead = /^\s*/.exec(code.slice(s))[0].length, t = code.slice(s + lead);
  const fn = /^(?:async\s+)?function\b[^(]*\(/.exec(t), arrow = /^(?:async\s*)?\(/.exec(t);
  const m = fn || arrow;
  if (m) {
    const a = callArgs(code, s + lead + m[0].length - 1);
    if (!a) return null;
    if (!fn && !/^\s*(?::[^=;]*)?=>/.test(code.slice(a.close + 1))) return null;
    return a.list.map(([x, y]) => code.slice(x, y).trim());
  }
  const one = /^(?:async\s+)?([A-Za-z_$][\w$]*)\s*=>/.exec(t);
  return one ? [one[1]] : null;
}
const paramName = (p) => p.replace(/\s*[:=][\s\S]*$/, "").trim();

// `$` at i is a first parameter: first in a parenthesised list that is not a call, closing into `=>`, `{` or a return type.
function isParam(code, i, rest) {
  if (!/^\s*[,:)]/.test(rest)) return false;
  const before = code.slice(0, i).replace(/\s+$/, "");
  if (!before.endsWith("(")) return false;
  const pre = before.slice(0, -1).replace(/\s+$/, "");
  if (!(pre === "" || /[^\w$)\].]$/.test(pre) || /\basync$/.test(pre) || /\bfunction(\s+[\w$]+)?$/.test(pre))) return false;
  const a = callArgs(code, before.length - 1);
  return Boolean(a) && /^\s*(=>|\{|:)/.test(code.slice(a.close + 1));
}

const found = [];
for (const f of files) {
  const rel = path.relative(dir, f), src = fs.readFileSync(f, "utf8");
  const { code, strings } = lex(src);
  const at = (i, why) => found.push(`${rel}:${code.slice(0, i).split("\n").length}: ${why}`);
  // The value of the string literal that is the whole argument span, else null.
  const literalAt = ([s, e]) => { const k = s + /^\s*/.exec(code.slice(s))[0].length; return strings.has(k) && /^(['"])\s*\1$/.test(code.slice(k, e).trim()) ? strings.get(k) : null; };

  for (const m of src.matchAll(/\\u/g)) at(m.index, "a \\u escape");
  for (const m of code.matchAll(/(?<![\w$.])[A-Za-z_$][\w$]*/g)) if (TOKENS.has(m[0])) at(m.index, `banned token ${m[0]}`);
  for (const m of code.matchAll(/\bFunction\s*\(/g)) at(m.index, "banned token Function(");
  for (const m of code.matchAll(/(?<![\w$])[A-Za-z_$][\w$]*(?![\w$])/g)) if (KEYS.has(m[0])) at(m.index, `${m[0]} as an identifier or key`);
  for (const [k, v] of strings) {
    if (KEYS.has(v)) at(k, `'${v}' as a string key`);
    if (ELEMENTS.has(v) && !DRAWABLE.has(v)) at(k, `'${v}' names an element other than Box or Text`);
  }
  for (const m of code.matchAll(/<\s*([A-Za-z_$][\w$.]*)/g)) {
    const before = code.slice(0, m.index).replace(/\s+$/, ""), word = /[\w$]+$/.exec(before);
    if ((word && !/^(?:return|yield|await|default|case|else|do)$/.test(word[0])) || /[)\]]$/.test(before)) continue;
    if (!DRAWABLE.has(m[1])) at(m.index, `JSX <${m[1]}> is not Box or Text`);
  }

  // Functions with parameters, by name, so one passed to a `$` call by name is caught too.
  const withParams = new Set();
  for (const m of code.matchAll(/(?<![\w$.])(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*(?::[^=;]+)?=(?!=)/g)) { const p = fnParams(code, m.index + m[0].length); if (p && p.length) withParams.add(m[1]); }
  for (const m of code.matchAll(/\bfunction\s+([A-Za-z_$][\w$]*)\s*\(/g)) { const a = callArgs(code, m.index + m[0].length - 1); if (a && a.list.length) withParams.add(m[1]); }

  for (const m of code.matchAll(/(?<![\w$])\$(?![\w$])/g)) {
    const i = m.index, rest = code.slice(i + 1);
    if (rel === "view.ts") { at(i, "view.ts holds a $"); continue; }
    const call = /^\s*\.\s*([A-Za-z_$][\w$]*)\s*\.\s*([A-Za-z_$][\w$]*)\s*/.exec(rest);
    if (call) {
      if (!CALLS.has(`${call[1]}.${call[2]}`)) at(i, `$.${call[1]}.${call[2]} is not an allowed call`);
      const open = i + 1 + call[0].length;
      const a = code[open] === "(" ? callArgs(code, open) : null;
      for (const span of a ? a.list : []) {
        const p = fnParams(code, span[0]), id = code.slice(...span).trim();
        if ((p && p.length) || withParams.has(id)) at(span[0], `a callback given to $.${call[1]}.${call[2]} declares parameters`);
      }
      continue;
    }
    if (/^\s*\./.test(rest)) { at(i, "$.<noun> without a method"); continue; }
    if (!isParam(code, i, rest)) at(i, "$ used other than as a first parameter or $.<noun>.<method>");
  }

  let registers = 0;
  for (const m of code.matchAll(/(?<![\w$.])register\b/g)) {
    const i = m.index, after = code.slice(i + "register".length);
    const def = /^\s*(?::\s*[\w$.<>[\], ]+)?\s*=(?!=)\s*/.exec(after), decl = /\bfunction\s*$/.test(code.slice(0, i));
    if (!def && !decl) continue;
    registers++;
    const p = def ? fnParams(code, i + "register".length + def[0].length) : (() => { const a = callArgs(code, code.indexOf("(", i)); return a ? a.list.map(([x, y]) => code.slice(x, y).trim()) : null; })();
    if (!p) { at(i, "register is not defined as a function literal"); continue; }
    if (paramName(p[0] || "") !== "on" || p.length > 2 || (p.length === 2 && paramName(p[1]) !== "options")) at(i, "register's parameters must be (on) or (on, options)");
  }
  if (modules.includes(path.normalize(rel)) && !registers) at(0, "the hooks module defines no register");

  for (const m of code.matchAll(/(?<![\w$.])on(?![\w$])/g)) {
    const i = m.index, rest = code.slice(i + 2), open = /^\s*\(/.exec(rest);
    if (!open) {
      if (!/^\s*=>/.test(rest) && !/^\s*[,):]/.test(rest)) at(i, "on used other than as on('<event>', …) or register's parameter");
      continue;
    }
    const a = callArgs(code, i + 2 + open[0].length - 1);
    if (!a || !a.list.length) { at(i, "on( without arguments"); continue; }
    const ev = literalAt(a.list[0]);
    if (ev === null) { at(i, "on( with an event that is not a string literal"); continue; }
    if (!EVENTS.has(ev)) at(i, `on('${ev}') is not an allowed registration`);
    const wants = MATCHERS[ev] ? 3 : 2;
    if (a.list.length !== wants) { at(i, `on('${ev}') takes ${MATCHERS[ev] ? "exactly one of its matchers and" : "no matcher, only"} an inline hook`); continue; }
    if (MATCHERS[ev]) {
      const [ms, me] = a.list[1], body = /^\s*\{([\s\S]*)\}\s*$/.exec(src.slice(ms, me));
      const pairs = body ? body[1].split(",").map((x) => x.trim()).filter(Boolean).map((x) => /^(?:(['"])(\w+)\1|(\w+))\s*:\s*(['"])([^'"]*)\4$/.exec(x)) : [null];
      const canon = pairs.every(Boolean) ? pairs.map((p) => `${p[2] || p[3]}=${p[5]}`).sort().join(",") : null;
      if (!MATCHERS[ev].includes(canon)) at(ms, `on('${ev}') matcher is not one of ${MATCHERS[ev].join(" | ")}`);
    }
    const hook = a.list[a.list.length - 1], p = fnParams(code, hook[0]);
    if (!p) at(hook[0], `on('${ev}') hook is not an inline arrow or function literal`);
    else if (p.length && paramName(p[0]) !== "$") at(hook[0], `on('${ev}') hook's first parameter must be $ (or none)`);
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

# <line>...: the lexer's verdict on a scratch copy of mod/ with those lines appended to register.tsx.
planted() {
  rm -rf "${SANDBOX:?}/mod"; cp -R "$PLUGIN/mod" "$SANDBOX/mod"
  printf '%s\n' "$@" >> "$SANDBOX/mod/register.tsx"
  violations "$SANDBOX/mod"
}
# Each planted case must fail the lexer on its own; validate is never run on these copies.
while IFS= read -r line; do
  [ -n "$line" ] || continue
  OUT=$(planted "$line")
  check "lexer alone catches: $line  [${OUT%%$'\n'*}]" '[ -n "$OUT" ]'
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
on('session.start', (env, e, next) => env.session.authorize())
on('session.start', ({ session }, e, next) => session.authorize())
const help = (x) => x.prompt.fill(); on('session.start', (env, e, next) => help(env))
export const register = r => { r('tool.check', ($, e, next) => next(e)) }
on('session.start', (env, e, next) => (env.session as any)[k]())
on('session.start', (env, e, next) => env['session']['append']())
on('session.start', (env, e, next) => { const s = env.session; s.authorize() })
\u0024.session.authorize()
\u006fn('tool.check', ($, e, next) => next(e))
on('tool\u002echeck', ($, e, next) => next(e))
on('session.start', h)
$.clock.every(2000, (env) => env.prompt.fill())
const tick = (env) => env.prompt.fill(); on('session.start', ($, e, next) => { $.clock.every(2000, tick); return next(e) })
on('session.start', function ($, e, next) { return arguments[0].prompt.fill() })
on('session.start', function ($, e, next) { return this.prompt.fill() })
on('command.run', ($, e, next) => ({ text: 'ok' }))
on('command.run', { command: 'hierarchy-pane' }, ($, e, next) => ({ text: 'ok', context: ['x'] }))
on('command.run', { command: 'hierarchy-pane' }, ($, e, next) => ({ text: 'ok', exitCode: 0 }))
on('command.run', { command: 'other' }, ($, e, next) => ({ text: 'ok' }))
on('ui.render', ($, e, next) => next(e))
on('ui.render', { component: 'Pane', requestId: 'ah-status' }, ($, e, next) => <Link url="x">y</Link>)
on('ui.render', { component: 'Pane', requestId: 'ah-status' }, ($, e, next) => <Button>b</Button>)
on('ui.render', { component: 'Pane', requestId: 'ah-status' }, ($, e, next) => ({ type: 'Link', url: 'x' }))
EOF
OUT=$(planted 'const r = ($, e, next) => $.fs.read(p)' '$.ui.status(t)' 'const t = `${x}`' \
  "export const register: Register = (on, options) => { on('session.start', (\$, e, next) => next(e)) }" \
  "on('command.run', { command: 'hierarchy-pane' }, (\$, e, next) => ({ text: 'ok' }))" \
  "on('ui.render', { component: 'Pane', requestId: 'ah-status' }, (\$, e, next) => <Box><Text>x</Text></Box>)" \
  '$.clock.every(2000, () => tick())' \
  'const strip = /[\x00-\x1f\x7f-\x9f]/g')
check "lexer passes the allowed forms: \$.fs.read(p), \$.ui.status(t), (\$, e, next) =>, \`\${x}\`, (on, options), the matched command.run {text}, a Box/Text Pane, a parameterless every callback, \\x escapes" '[ -z "$OUT" ]'
rm -rf "${SANDBOX:?}/mod"; cp -R "$PLUGIN/mod" "$SANDBOX/mod"; mkdir -p "$SANDBOX/mod/tests"
printf '%s\n' '$.fs.write(p, t)' "on('fs.write', (env, e, next) => env.prompt.fill())" > "$SANDBOX/mod/tests/x.test.ts"
OUT=$(violations "$SANDBOX/mod")
check "lexer ignores anything under tests/" '[ -z "$OUT" ]'
printf '%s\n' 'export const pure = (s: string) => `${s}`' 'const x = $' > "$SANDBOX/mod/view.ts"
OUT=$(violations "$SANDBOX/mod")
check "view.ts may hold no \$ at all" '[ -n "$OUT" ] && printf "%s" "$OUT" | grep -q "^view.ts:"'

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
