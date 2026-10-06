#!/bin/bash
# agent-hierarchy — the mod acts only through an allow-list. Module source under mod/ (its tests and
# types aside) calls only the allowed `$` methods; names `on` only as register's first parameter and as
# the callee of on('<event>', …), each event with its exact matcher and an inline hook whose first
# parameter is `$`; imports values only from ./view; and holds none of the banned words that would let a
# return answer a prompt, send a message or draw an input. `claude plugin validate` must report nothing
# beyond the lists. Planted cases in a scratch copy show each forbidden form caught by the lexer alone,
# and each allowed form passed.
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
# what `on(...)` may name; an event listed in MATCHERS must carry exactly one of its matchers (k=v pairs,
# keys sorted), any other takes none. RENDER_ELEMENTS is every RenderElement type; the banned words are
# RETURN_KEYS plus every element type not in DRAWABLE. BAND_DRAWABLE is also drawable, but only inside the
# ui.render hook matched by component=AbovePrompt, and only with an inline arrow onPress.
ALLOWED_CALLS="session.cwd session.id fs.stat fs.read fs.exists clock.every clock.now state.get state.set ui.status ui.toast ui.open ui.resolve command.register"
ALLOWED_EVENTS="session.start ui.close command.run ui.render"
MATCHERS="command.run:command=hierarchy-pane ui.render:component=Pane,requestId=ah-status ui.render:component=AbovePrompt ui.close:id=ah-status"
RENDER_ELEMENTS="Box Text engine Button Input Select Link Code Markdown Client Svg Raster Image"
DRAWABLE="Box Text engine"
BAND_DRAWABLE="Button"
RETURN_KEYS="context exitCode press client raster deny"
BANNED_TOKENS="globalThis eval Reflect Proxy arguments this"

# <mod dir>: every lexer violation in the module source under it, as file:line: reason; empty when clean.
violations() {
  node - "$1" "$ALLOWED_CALLS" "$ALLOWED_EVENTS" "$MATCHERS" "$RENDER_ELEMENTS" "$DRAWABLE" "$RETURN_KEYS" "$BANNED_TOKENS" "$BAND_DRAWABLE" <<'JS'
const fs = require("fs"), path = require("path");
const [dir, callsArg, eventsArg, matchersArg, elementsArg, drawableArg, keysArg, tokensArg, bandDrawableArg] = process.argv.slice(2);
const set = (s) => new Set(s.split(" "));
const CALLS = set(callsArg), EVENTS = set(eventsArg), TOKENS = set(tokensArg), DRAWABLE = set(drawableArg), BAND_DRAWABLE = set(bandDrawableArg);
const BAND_MATCHER = "component=AbovePrompt";
const BANNED = new Set([...set(keysArg), ...[...set(elementsArg)].filter((x) => !DRAWABLE.has(x))]);
const MATCHERS = {};
for (const m of matchersArg.split(" ")) { const [ev, canon] = m.split(/:(.*)/s); (MATCHERS[ev] = MATCHERS[ev] || []).push(canon); }
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
// `${…}` code inside a template stays. String literals, and templates without a `${…}`, are kept by
// their opening offset.
// ponytail: no regex-literal or JSX-text handling; a quote or `//` in either can mis-blank code, and words in JSX
// text are read as code (write such text as a {'…'} string). A real tokenizer if mod code ever needs one.
function lex(src) {
  const sp = (s) => s.replace(/[^\n]/g, " ");
  const strings = new Map(), tpl = [], frames = [];
  let out = "", i = 0, depth = 0, inTpl = false;
  while (i < src.length) {
    const c = src[i], n = src[i + 1];
    if (inTpl) {
      const f = frames[frames.length - 1];
      if (c === "\\") { f.text += src[i + 1] || ""; out += sp(src.slice(i, i + 2)); i += 2; }
      else if (c === "`") { frames.pop(); if (!f.sub) strings.set(f.start, f.text); out += c; i++; inTpl = false; }
      else if (c === "$" && n === "{") { f.sub = true; out += "  "; i += 2; tpl.push(depth); inTpl = false; }
      else { f.text += c; out += sp(c); i++; }
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
    if (c === "`") { frames.push({ start: i, text: "", sub: false }); out += c; i++; inTpl = true; continue; }
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

// The parameters of a function literal beginning at `s`, as [text, offset] pairs, or null when none begins there.
function fnParams(code, s) {
  const lead = /^\s*/.exec(code.slice(s))[0].length, t = code.slice(s + lead);
  const fn = /^(?:async\s+)?function\b[^(]*\(/.exec(t), arrow = /^(?:async\s*)?\(/.exec(t);
  const m = fn || arrow;
  if (m) {
    const a = callArgs(code, s + lead + m[0].length - 1);
    if (!a) return null;
    if (!fn && !/^\s*(?::[^=;]*)?=>/.test(code.slice(a.close + 1))) return null;
    return a.list.map(([x, y]) => { const w = /^\s*/.exec(code.slice(x, y))[0].length; return [code.slice(x, y).trim(), x + w]; });
  }
  const one = /^((?:async\s+)?)([A-Za-z_$][\w$]*)\s*=>/.exec(t);
  return one ? [[one[2], s + lead + one[1].length]] : null;
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

  // A matcher object's canonical form (k=v pairs, keys sorted), or null when it is not plain string pairs.
  const canonOf = ([ms, me]) => {
    const body = /^\s*\{([\s\S]*)\}\s*$/.exec(src.slice(ms, me));
    const pairs = body ? body[1].split(",").map((x) => x.trim()).filter(Boolean).map((x) => /^(?:(['"])(\w+)\1|(\w+))\s*:\s*(['"])([^'"]*)\4$/.exec(x)) : [null];
    return pairs.every(Boolean) ? pairs.map((p) => `${p[2] || p[3]}=${p[5]}`).sort().join(",") : null;
  };
  // The hook spans of the on('ui.render', { component: 'AbovePrompt' }, hook) registrations: the only place BAND_DRAWABLE may be drawn.
  const bandSpans = [];
  for (const m of code.matchAll(/(?<![\w$.])on\s*\(/g)) {
    const a = callArgs(code, m.index + m[0].length - 1);
    if (a && a.list.length === 3 && literalAt(a.list[0]) === "ui.render" && canonOf(a.list[1]) === BAND_MATCHER) bandSpans.push(a.list[2]);
  }
  // Every on(...) call's span, so a registration nested inside the band hook does not inherit its exemption.
  const onSpans = [];
  for (const m of code.matchAll(/(?<![\w$.])on\s*\(/g)) { const a = callArgs(code, m.index + m[0].length - 1); if (a) onSpans.push([m.index, a.close]); }
  const inBand = (i) => bandSpans.some(([s, e]) => i >= s && i < e && !onSpans.some(([os, oe]) => os >= s && os < e && i >= os && i <= oe));

  for (const m of src.matchAll(/\\u/g)) at(m.index, "a \\u escape");
  for (const m of code.matchAll(/(?<![\w$.])[A-Za-z_$][\w$]*/g)) if (TOKENS.has(m[0])) at(m.index, `banned token ${m[0]}`);
  for (const m of code.matchAll(/\bFunction\s*\(/g)) at(m.index, "banned token Function(");
  // The banned words, by token: identifiers, property names and JSX tags here; strings and plain templates below.
  for (const m of code.matchAll(/(?<![\w$])[A-Za-z_$][\w$]*(?![\w$])/g)) if (BANNED.has(m[0]) && !(BAND_DRAWABLE.has(m[0]) && inBand(m.index))) at(m.index, `banned word ${m[0]}`);
  for (const [k, v] of strings) if (BANNED.has(v)) at(k, `banned word '${v}'`);

  // Imports: register.tsx takes values only from ./view; any other import is `import type`, from
  // 'claude-code' or ./types/; nothing comes from ./tests/.
  for (const m of code.matchAll(/\b(import|export)\b(\s+type\b)?[^;'"]*?(['"])/g)) {
    const kw = m[1], typeOnly = Boolean(m[2]), spec = strings.get(m.index + m[0].length - 1);
    if (spec === undefined) continue;
    const head = code.slice(m.index, m.index + m[0].length);
    if (kw === "export" && !/\bfrom\s*['"]$/.test(head)) continue;
    const local = spec.replace(/\.(ts|tsx)$/, "");
    if (/(^|\/)tests(\/|$)/.test(local)) at(m.index, `an import from ${spec}`);
    else if (typeOnly) { if (!(spec === "claude-code" || local.startsWith("./types/"))) at(m.index, `a type import from ${spec}, not 'claude-code' or ./types/`); }
    else if (!(rel === "register.tsx" && local === "./view")) at(m.index, `a value ${kw} from ${spec}${rel === "register.tsx" ? ", not ./view" : ""}`);
  }

  // Functions with parameters, by name, so one passed to a `$` call by name is caught too.
  const withParams = new Set();
  for (const m of code.matchAll(/(?<![\w$.])(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*(?::[^=;]+)?=(?!=)/g)) { const p = fnParams(code, m.index + m[0].length); if (p && p.length) withParams.add(m[1]); }
  for (const m of code.matchAll(/\bfunction\s+([A-Za-z_$][\w$]*)\s*\(/g)) { const a = callArgs(code, m.index + m[0].length - 1); if (a && a.list.length) withParams.add(m[1]); }

  // Position rule: in a band hook, Button stands only as an unrenamed `const { … } = $.ui.resolve(x)` property at the hook's own
  // function depth, or as a JSX tag in the hook's own return (or expression body) with no function literal before it, no call paren
  // open around it and no assignment in that return. So a Button value or element cannot leave the hook by a binding.
  const GROUP = new Set(["return", "if", "while", "for", "switch", "typeof", "await", "void"]);
  const CTRL = new Set(["if", "for", "while", "switch", "catch", "with"]);
  const matchOpen = (close) => { let d = 0; for (let k = close; k >= 0; k--) { const ch = code[k]; if (")]}".includes(ch)) d++; else if ("([{".includes(ch) && --d === 0) return k; } return -1; };
  const isFnBlock = (b) => {
    const before = code.slice(0, b).replace(/\s+$/, "");
    if (before.endsWith("=>") || /\)\s*:\s*[\w$.<>[\], |&]*$/.test(before)) return true;
    if (!before.endsWith(")")) return false;
    const open = matchOpen(before.length - 1);
    if (open < 0) return false;
    const pre = code.slice(0, open).replace(/\s+$/, ""), w = /([\w$]+)$/.exec(pre);
    return pre.endsWith("*") || !(w && CTRL.has(w[1]));
  };
  const hookBody = (hs) => {
    const k = hs + /^\s*/.exec(code.slice(hs))[0].length, t = code.slice(k);
    const m = /^(?:async\s+)?function\b[^(]*\(/.exec(t) || /^(?:async\s*)?\(/.exec(t);
    const after = m ? callArgs(code, k + m[0].length - 1).close + 1 : k + /^(?:async\s+)?[A-Za-z_$][\w$]*\s*/.exec(t)[0].length;
    const bs = after + /^\s*(?::[^=;{]*)?(?:=>)?\s*/.exec(code.slice(after))[0].length;
    return { bs, block: code[bs] === "{" };
  };
  // Whether an operand may start after `prefix`: a `<` there opens a JSX tag, anywhere else it is the less-than operator.
  const startsOperand = (prefix) => {
    const t = prefix.replace(/\s+$/, "");
    return t === "" || /[(,{}?:>&|=[;!]$/.test(t) || /(?:^|[^\w$.])(?:return|typeof|await|void|yield|case|else)$/.test(t);
  };
  // Whether `text` assigns outside a JSX attribute name= and outside an onPress body.
  const hasAssign = (text) => {
    let inTag = false, bd = 0;
    for (let k = 0; k < text.length; k++) {
      const ch = text[k], nx = text[k + 1], pv = text[k - 1] || "";
      if (inTag) {
        if (ch === "{") {
          if (bd === 0 && /onPress\s*=\s*$/.test(text.slice(0, k))) { let d = 0; for (; k < text.length; k++) { if (text[k] === "{") d++; else if (text[k] === "}" && --d === 0) break; } continue; }
          bd++; continue;
        }
        if (ch === "}") { bd--; continue; }
        if (bd === 0 && ch === ">") { inTag = false; continue; }
        if (bd === 0 && ch === "=") continue;
      } else if (ch === "<" && /[A-Za-z]/.test(nx || "") && startsOperand(text.slice(0, k))) { inTag = true; bd = 0; continue; }
      if (ch !== "=") continue;
      if (nx === "=") { k++; if (text[k + 1] === "=") k++; continue; }
      if (nx === ">") continue;
      if (/[!<>]/.test(pv) && !/<<|>>/.test(text.slice(k - 2, k))) continue;
      return true;
    }
    return false;
  };
  for (const [hs, he] of bandSpans) {
    const { bs, block } = hookBody(hs);
    const fnRegions = [];
    for (let k = bs + (block ? 1 : 0); k < he; k++) if (code[k] === "{" && isFnBlock(k)) { const a = callArgs(code, k); if (a) fnRegions.push([k, a.close]); }
    const own = (i) => !fnRegions.some(([x, y]) => i > x && i < y);
    const returns = block ? [...code.slice(bs, he).matchAll(/(?<![\w$.])return(?![\w$])/g)].map((r) => bs + r.index).filter(own) : [bs];
    const argStart = (r) => (block ? r + 6 : r);
    const argEnd = (r) => {
      if (!block) return he;
      let d = 0;
      for (let k = r + 6; k < he; k++) { const ch = code[k]; if ("([{".includes(ch)) d++; else if (")]}".includes(ch)) { if (--d < 0) return k; } else if (ch === ";" && d === 0) return k; }
      return he;
    };
    for (const m of code.slice(hs, he).matchAll(/(?<![\w$.])Button(?![\w$])/g)) {
      const i = hs + m.index;
      if (!inBand(i)) continue;
      const before = code.slice(0, i), rest = code.slice(i + 6), tag = /<(\/?)\s*$/.exec(before);
      if (!tag) {
        const pat = /\bconst\s*\{[^{}]*$/.exec(before), end = rest.indexOf("}");
        const ok = pat && own(pat.index) && /[{,]\s*$/.test(before) && /^\s*[,}]/.test(rest) && end >= 0 &&
          /^\s*=\s*\$\s*\.\s*ui\s*\.\s*resolve\s*\(\s*[\w$]+\s*\)/.test(rest.slice(end + 1));
        if (!ok) at(i, "Button outside an unrenamed $.ui.resolve destructure at the band hook's own depth, or a JSX tag in its own return");
        continue;
      }
      const tpos = i - tag[0].length, r = returns.filter((x) => x < tpos).pop();
      let why = null;
      if (r === undefined || tpos >= argEnd(r)) why = "tag is not inside the band hook's own return";
      else {
        const seg = code.slice(argStart(r), tpos), open = [];
        for (let k = 0; k < seg.length; k++) { if (seg[k] === "(") open.push(k); else if (seg[k] === ")") open.pop(); }
        if (tag[1] !== "/" && /=>|\bfunction\b/.test(seg)) why = "tag sits inside a function literal";
        else if (open.some((k) => { const pre = seg.slice(0, k).replace(/\s+$/, ""), w = /([\w$]+)$/.exec(pre); return w ? !GROUP.has(w[1]) : /[)\]]$/.test(pre) || /\?\.$/.test(pre) || /[\w$>]>$/.test(pre); })) why = "tag sits inside a call's arguments";
        else if (hasAssign(code.slice(argStart(r), argEnd(r)))) why = "the return holds an assignment";
      }
      if (why) at(i, `Button ${why}`);
    }
  }

  // A Button's onPress is an inline arrow whose parameter, if any, is not named $; its body is lexed like any other code.
  for (const m of code.matchAll(/(?<![\w$.])onPress\s*(?:=\s*\{|:)\s*/g)) {
    const s = m.index + m[0].length, p = fnParams(code, s);
    if (!p || /^\s*(?:async\s+)?function\b/.test(code.slice(s))) at(m.index, "onPress is not an inline arrow function");
    else if (p.some(([t]) => paramName(t) === "$")) at(m.index, "onPress takes a parameter named $");
  }

  // A same-file helper that may be handed $: declared exactly once, as const <name> = (async)? ($ …) => …, and never bound again.
  // `before` ends in a member access, whatever whitespace sits between the dot and the name.
  const isMember = (before) => /(?<!\.\.)\??\.\s*$/.test(before) && !/\.\.\.\s*$/.test(before);
  const helperOk = (name) => {
    let decls = 0, other = 0;
    for (const h of code.matchAll(new RegExp(`(?<![\\w$])${name.replace(/\$/g, "\\$")}(?![\\w$])`, "g"))) {
      const before = code.slice(0, h.index), after = code.slice(h.index + name.length);
      if (isMember(before)) continue;
      const eq = /(?<![\w$.])const\s+$/.test(before) ? /^\s*(?::[^=;]+)?=(?!=)/.exec(after) : null;
      if (eq) {
        const at0 = h.index + name.length + eq[0].length, p = fnParams(code, at0);
        if (p && p.length && paramName(p[0][0]) === "$" && !/^\s*(?:async\s+)?function\b/.test(code.slice(at0))) decls++; else other++;
      } else if (/^\s*\(/.test(after)) {
        // A call site, unless the parenthesis closes into a body: a function, generator or method declaration binds the name.
        const a = callArgs(code, h.index + name.length + /^\s*/.exec(after)[0].length);
        if (!a || /^\s*(?::[^;{}=]*)?\{/.test(code.slice(a.close + 1)) || /\bfunction\s*\*?\s*$/.test(before)) other++;
      } else other++;
    }
    return decls === 1 && other === 0;
  };

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
    if (isParam(code, i, rest)) continue;
    // name($ …): $ is the first argument of a call to a once-declared, $-first helper of this file.
    const callee = /^\s*[,)]/.test(rest) ? /(?<![\w$])([A-Za-z_$][\w$]*)\s*\(\s*$/.exec(code.slice(0, i)) : null;
    if (callee && !isMember(code.slice(0, callee.index)) && !/\b(?:new|function)\s+$/.test(code.slice(0, callee.index)) && helperOk(callee[1])) continue;
    at(i, "$ used other than as a first parameter, $.<noun>.<method> or the first argument of a $-first helper of this file");
  }

  // register's definitions: (on) or (on, options). Their `on` is the one place `on` may stand other than as a callee.
  const onParams = new Set();
  let registers = 0;
  for (const m of code.matchAll(/(?<![\w$.])register\b/g)) {
    const i = m.index, after = code.slice(i + "register".length);
    const def = /^\s*(?::\s*[\w$.<>[\], ]+)?\s*=(?!=)\s*/.exec(after), decl = /\bfunction\s*$/.test(code.slice(0, i));
    if (!def && !decl) continue;
    registers++;
    const p = def ? fnParams(code, i + "register".length + def[0].length) : fnParams(code, code.slice(0, i).search(/\bfunction\s*$/));
    if (!p) { at(i, "register is not defined as a function literal"); continue; }
    if (p.length >= 1 && paramName(p[0][0]) === "on") onParams.add(p[0][1]);
    if (paramName((p[0] || [""])[0]) !== "on" || p.length > 2 || (p.length === 2 && paramName(p[1][0]) !== "options")) at(i, "register's parameters must be (on) or (on, options)");
  }
  if (modules.includes(path.normalize(rel)) && !registers) at(0, "the hooks module defines no register");

  for (const m of code.matchAll(/(?<![\w$.])on(?![\w$])/g)) {
    const i = m.index;
    if (onParams.has(i)) continue;
    const open = /^\s*\(/.exec(code.slice(i + 2));
    if (!open) { at(i, "on used other than as register's first parameter or the callee of on('<event>', …)"); continue; }
    const a = callArgs(code, i + 2 + open[0].length - 1);
    if (!a || !a.list.length) { at(i, "on( without arguments"); continue; }
    const ev = literalAt(a.list[0]);
    if (ev === null) { at(i, "on( with an event that is not a string literal"); continue; }
    if (!EVENTS.has(ev)) at(i, `on('${ev}') is not an allowed registration`);
    const wants = MATCHERS[ev] ? 3 : 2;
    if (a.list.length !== wants) { at(i, `on('${ev}') takes ${MATCHERS[ev] ? "exactly one of its matchers and" : "no matcher, only"} an inline hook`); continue; }
    if (MATCHERS[ev]) {
      const canon = canonOf(a.list[1]);
      if (!MATCHERS[ev].includes(canon)) at(a.list[1][0], `on('${ev}') matcher is not one of ${MATCHERS[ev].join(" | ")}`);
    }
    const hook = a.list[a.list.length - 1], p = fnParams(code, hook[0]);
    if (!p) at(hook[0], `on('${ev}') hook is not an inline arrow or function literal`);
    else if (p.length && paramName(p[0][0]) !== "$") at(hook[0], `on('${ev}') hook's first parameter must be $ (or none)`);
  }
}
process.stdout.write(found.join("\n"));
JS
}

# <plugin dir>: the validate net's verdict on it: each printed registration or call outside the lists,
# or why validate failed; empty when clean. A registration prints as `event` or `event{k=v, …}`.
valnet() {
  local out rc
  mkdir -p "$SANDBOX/home/.claude"
  out=$(cd "$SANDBOX" && HOME="$SANDBOX/home" CLAUDE_CONFIG_DIR="$SANDBOX/home/.claude" perl -e 'alarm shift; exec @ARGV' 120 claude plugin validate "$1" 2>&1); rc=$?
  if [ "$rc" != 0 ]; then echo "validate failed (exit $rc): ${out:0:300}"; return; fi
  printf '%s\n' "$out" | node -e '
    const [calls, events, matchers] = process.argv.slice(1).map((s) => s.split(" "));
    const M = {};
    for (const m of matchers) { const [ev, canon] = m.split(/:(.*)/s); (M[ev] = M[ev] || []).push(canon); }
    const lines = require("fs").readFileSync(0, "utf8").split("\n");
    const bad = [];
    let hooks = 0;
    for (const line of lines) {
      const h = / \.\/\S+ hooks: (.*)$/.exec(line), c = / \.\/\S+ calls: (.*)$/.exec(line);
      if (h) {
        const items = []; let d = 0, cur = "";
        for (const ch of h[1]) { if (ch === "{") d++; if (ch === "}") d--; if (ch === "," && d === 0) { items.push(cur); cur = ""; } else cur += ch; }
        items.push(cur);
        for (const item of items.map((x) => x.trim()).filter(Boolean)) {
          hooks++;
          const m = /^([^{]+?)(?:\{(.*)\})?$/.exec(item), ev = m[1].trim();
          if (!events.includes(ev)) { bad.push(`hook ${item}: not an allowed event`); continue; }
          if (m[2] === undefined) { if (M[ev]) bad.push(`hook ${item}: needs one of its matchers`); continue; }
          const canon = m[2].split(",").map((x) => x.trim()).filter(Boolean).sort().join(",");
          if (!(M[ev] || []).includes(canon)) bad.push(`hook ${item}: matcher is not one of ${(M[ev] || ["(none)"]).join(" | ")}`);
        }
      }
      if (c && c[1].trim() !== "nothing on $") for (const x of c[1].split(",").map((s) => s.trim().replace(/^\$\./, "")).filter(Boolean)) if (!calls.includes(x)) bad.push(`call ${x}: not an allowed call`);
    }
    if (!hooks) bad.push("validate printed no hooks");
    process.stdout.write(bad.join("\n"));
  ' "$ALLOWED_CALLS" "$ALLOWED_EVENTS" "$MATCHERS"
}

check "the mod's hooks module exists, so the guard has source to read" '[ -f "$PLUGIN/mod/register.tsx" ]'
OUT=$(violations "$PLUGIN/mod")
check "the module source passes the lexer" '[ -z "$OUT" ]'
OUT=$(valnet "$PLUGIN")
check "validate passes, and every hook and call it reports is on the lists, matchers included" '[ -z "$OUT" ]'

# <line>...: the lexer's verdict on a scratch copy of mod/ with those lines appended to register.tsx.
copy_mod() { rm -rf "${SANDBOX:?}/mod"; cp -R "$PLUGIN/mod" "$SANDBOX/mod"; }
planted() { copy_mod; printf '%s\n' "$@" >> "$SANDBOX/mod/register.tsx"; violations "$SANDBOX/mod"; }
# Each planted case must fail the lexer on its own; validate never runs on these copies.
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
on('\u0074ool.check', ($, e, next) => next(e))
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
const extra = (r) => r('tool.check', ($, e, next) => next(e)); extra(on)
const pass = (x, r) => 0; pass(1, on)
import { fixtures } from './tests/fixtures.ts'
on('ui.render', { component: 'Pane', requestId: 'ah-status' }, ($, e, next) => h(els.Link, { url: 'x' }, 'y'))
on('session.start', async ($, e, next) => { const { Button } = $.ui.resolve(e); return next(e) })
on('command.run', { command: 'hierarchy-pane' }, ($, e, next) => ({ text: 'ok', [`context`]: ['x'] }))
on('ui.close', ($, e, next) => ({ deny: 'x' }))
on('ui.close', ($, e, next) => next(e))
on('ui.close', { id: 'other' }, ($, e, next) => next(e))
import { update } from 'claude-code'
on('ui.render', { component: 'Pane', requestId: 'other' }, ($, e, next) => next(e))
on('command.run', { command: 'hierarchy-pane' }, async ($, e, next) => { const { Button } = $.ui.resolve(e); return ({ text: 'ok' }) })
on('ui.render', { component: 'AbovePrompt' }, ($, e, next) => <Button onPress={() => $.session.authorize()}>x</Button>)
on('ui.render', { component: 'AbovePrompt' }, ($, e, next) => <Button onPress={($) => $.ui.toast('x')}>x</Button>)
on('ui.render', { component: 'AbovePrompt' }, ($, e, next) => <Button onPress={go}>x</Button>)
on('ui.render', { component: 'AbovePrompt' }, ($, e, next) => <Input />)
JSON.stringify($)
x.f($)
const f = ($) => 1; const f = ($) => 2; f($)
const f = ($) => 1; const g = (f) => f; f($)
const f = (env) => env.session.authorize(); f($)
const f = ($, e) => 1; f(e, $)
const h = ($) => 0; const x = { h(env) { return env.session.authorize() } }; x. h($)
const h = ($) => 0; class K { h(env) { return env.session.authorize() } }; new K(). h($)
const h = ($) => 0; { function* h(env) { env.session.authorize() } h($).next() }
const h = ($) => 0; { function *h(env) { env.session.authorize() } h($).next() }
const h = ($) => 0; { async function* h(env) { env.session.authorize() } h($).next() }
on('ui.render', { component: 'AbovePrompt' }, ($, e, next) => { on('ui.render', { component: 'Pane', requestId: 'ah-status' }, ($, e, next) => <Button onPress={() => 0} />); return next(e) })
let B; on('ui.render', { component: 'AbovePrompt' }, ($, e, next) => { const { Button } = $.ui.resolve(e); B = Button; return next(e) }); on('ui.render', { component: 'Pane', requestId: 'ah-status' }, ($, e, next) => <B onPress={() => 0} />)
let mk; on('ui.render', { component: 'AbovePrompt' }, ($, e, next) => { const { Button } = $.ui.resolve(e); mk = () => <Button onPress={() => 0} />; return next(e) }); on('ui.render', { component: 'Pane', requestId: 'ah-status' }, ($, e, next) => mk())
let el; on('ui.render', { component: 'AbovePrompt' }, ($, e, next) => { const { Button } = $.ui.resolve(e); el = <Button onPress={() => 0} />; return next(e) }); on('ui.render', { component: 'Pane', requestId: 'ah-status' }, ($, e, next) => el)
let el; on('ui.render', { component: 'AbovePrompt' }, ($, e, next) => { const { Button } = $.ui.resolve(e); return (el = <Box><Button onPress={() => 0} /></Box>) }); on('ui.render', { component: 'Pane', requestId: 'ah-status' }, ($, e, next) => el)
const keep = (x) => x; on('ui.render', { component: 'AbovePrompt' }, ($, e, next) => { const { Button } = $.ui.resolve(e); return keep(<Box><Button onPress={() => 0} /></Box>) })
let B; on('ui.render', { component: 'AbovePrompt' }, ($, e, next) => { const { Button: B } = $.ui.resolve(e); return <B onPress={() => 0} /> })
let x; on('ui.render', { component: 'AbovePrompt' }, ($, e, next) => { const { Button } = $.ui.resolve(e); return <Button onPress={() => { x = <Button onPress={() => 0} /> }} /> })
let s; on('ui.render', { component: 'AbovePrompt' }, ($, e, next) => { const { Button } = $.ui.resolve(e); const q = 1, w = 2; return (q <w, s = <Button onPress={() => 0} />) }); on('ui.render', { component: 'Pane', requestId: 'ah-status' }, ($, e, next) => s)
EOF

# The band hook may draw a Button with an inline arrow onPress; a $-first helper declared once may be called with $ from two hooks.
OUT=$(planted "const help = async (\$, x) => { await \$.state.set(x, 1) }" \
  "on('ui.render', { component: 'AbovePrompt' }, async (\$, e, next) => { const { Box, Button, Text } = \$.ui.resolve(e); return <Box><Text>x</Text><Button key=\"k\" label=\"L\" onPress={async () => { await help(\$, 1); await \$.ui.toast('x') }} /></Box> })" \
  "on('command.run', { command: 'hierarchy-pane' }, async (\$, e, next) => { await help(\$, 2); return ({ text: 'ok' }) })")
check "lexer passes a band Button with an inline arrow onPress and a \$-first helper called from two hooks" '[ -z "$OUT" ]'

# The position rule still passes a band Button with children, in a conditional return, after an early return.
OUT=$(planted "on('ui.render', { component: 'AbovePrompt' }, async (\$, e, next) => { if (e.props.hasSurvey) return next(e); const { Box, Button } = \$.ui.resolve(e); return (<Box>{e.props.ok ? (<Button onPress={() => \$.ui.toast('x')}>Go</Button>) : null}</Box>) })" \
  "on('ui.render', { component: 'AbovePrompt' }, async (\$, e, next) => { const { Button } = \$.ui.resolve(e); return <Button onPress={() => \$.ui.toast('x')}>Go</Button> })")
check "lexer passes a band Button with children, in a conditional return, after an early return" '[ -z "$OUT" ]'

# The import rule closes a helper kept outside the scan: mod/types/ is not scanned, so a value import from
# it is the violation.
copy_mod
printf '%s\n' "export const extra = (r: any) => r('tool.check', (\$: any, e: any, next: any) => next(e))" > "$SANDBOX/mod/types/extra.ts"
printf '%s\n' "import { extra } from './types/extra.ts'" >> "$SANDBOX/mod/register.tsx"
OUT=$(violations "$SANDBOX/mod")
check "lexer alone catches: a helper in mod/types/extra.ts imported as a value  [${OUT%%$'\n'*}]" '[ -n "$OUT" ]'

# The \u cases must hold the escape itself; a decoded character would plant a different case.
OUT=$(grep -c '^\\u0024\.session\|^\\u006fn(\|^on(.\\u0074ool' "$0")
check "the three \\u planted cases hold a literal backslash-u in this file" '[ "$OUT" = 3 ]'

OUT=$(planted 'const r = ($, e, next) => $.fs.read(p)' '$.ui.status(t)' 'const t = `${x}`' \
  "export const register: Register = (on, options) => { on('session.start', (\$, e, next) => next(e)) }" \
  "on('command.run', { command: 'hierarchy-pane' }, (\$, e, next) => ({ text: 'ok' }))" \
  "on('ui.render', { component: 'Pane', requestId: 'ah-status' }, (\$, e, next) => <Box><Text>x</Text></Box>)" \
  '$.clock.every(2000, () => tick())' \
  'const strip = /[\x00-\x1f\x7f-\x9f]/g')
check "lexer passes the allowed forms: \$.fs.read(p), \$.ui.status(t), (\$, e, next) =>, \`\${x}\`, (on, options), the matched command.run {text}, a Box/Text Pane, a parameterless every callback, \\x escapes" '[ -z "$OUT" ]'

# A module with every P3 matcher passes the lexer and the validate net; one without its matcher fails the net.
p3() {
  rm -rf "${SANDBOX:?}/p3"; mkdir -p "$SANDBOX/p3"; cp -R "$PLUGIN/.claude-plugin" "$SANDBOX/p3/"; copy_mod; cp -R "$SANDBOX/mod" "$SANDBOX/p3/mod"
  { echo "import type { Register } from 'claude-code'"; echo "export const register: Register = (on, options) => {"; printf '  %s\n' "$@"; echo "}"; } > "$SANDBOX/p3/mod/register.tsx"
}
p3 "on('session.start', (\$, e, next) => next(e))" \
   "on('command.run', { command: 'hierarchy-pane' }, (\$, e, next) => ({ text: 'ok' }))" \
   "on('ui.render', { component: 'Pane', requestId: 'ah-status' }, (\$, e, next) => next(e))" \
   "on('ui.render', { component: 'AbovePrompt' }, (\$, e, next) => next(e))" \
   "on('ui.close', { id: 'ah-status' }, (\$, e, next) => next(e))"
OUT="$(violations "$SANDBOX/p3/mod")$(valnet "$SANDBOX/p3")"
check "a register with the ui.close matcher, both ui.render matchers and the command.run matcher passes the lexer and the validate net" '[ -z "$OUT" ]'
p3 "on('session.start', (\$, e, next) => next(e))" "on('ui.render', (\$, e, next) => next(e))"
OUT=$(valnet "$SANDBOX/p3")
check "the validate net rejects ui.render printed with no matcher" 'printf "%s" "$OUT" | grep -q "needs one of its matchers"'

copy_mod; mkdir -p "$SANDBOX/mod/tests"
printf '%s\n' '$.fs.write(p, t)' "on('fs.write', (env, e, next) => env.prompt.fill())" > "$SANDBOX/mod/tests/x.test.ts"
OUT=$(violations "$SANDBOX/mod")
check "lexer ignores anything under tests/" '[ -z "$OUT" ]'
printf '%s\n' 'export const pure = (s: string) => `${s}`' 'const x = $' > "$SANDBOX/mod/view.ts"
OUT=$(violations "$SANDBOX/mod")
check "view.ts may hold no \$ at all" '[ -n "$OUT" ] && printf "%s" "$OUT" | grep -q "^view.ts:"'

echo "---"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
