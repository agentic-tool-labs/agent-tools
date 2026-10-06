#!/bin/bash
# agent-hierarchy — the mod acts only through an allow-list. Module source under mod/ (its tests and
# types aside) calls only the allowed `$` methods; names `on` only as register's first parameter and as
# the callee of on('<event>', …), each event with its exact matcher and an inline hook whose first
# parameter is `$`; imports values only from ./view; and holds none of the banned words that would let a
# return answer a prompt, send a message or draw an input. `claude plugin validate` must report nothing
# beyond the lists. Planted cases in a scratch copy show each forbidden form caught by the lexer alone,
# and each allowed form passed.
#
# THE INVARIANT: the mod runs nothing without a user press. Exactly one process may run: the pinned focus helper
# (HELPER below, matched whole in mod/register.tsx and the only place the word `process` may appear in mod/). A
# second exec site, or any change to the pinned argv or init, needs a new security ruling, not a guard edit.
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
BANNED_TOKENS="globalThis eval Reflect Proxy arguments this prototype"
# The one process the mod may run (spec: the focus helper). Held whole: any edit to the helper means editing this text, so
# both always show in one diff. Matched once in mod/register.tsx on the comment-blanked source (strings kept), then cut out
# by offset before the rest of the lexer reads the file; `process.run` is deliberately not in ALLOWED_CALLS.
PINNED_NAME="focusMember"
# What validate prints for the pinned helper once a hook calls it. Only the validate net accepts it, and only in exactly this form;
# the lexer allows the exec by the pinned text alone (process.run is not in ALLOWED_CALLS).
NET_EXTRA_CALL="process.run (via focusMember)"
read -r -d '' HELPER <<'HELPER_END'
export const focusMember = async ($: any, name: unknown): Promise<boolean> => {
  if (typeof name !== 'string' || !/^[a-z][a-z0-9_-]{0,31}$/.test(name)) {
    await $.ui.toast('Could not focus that member.')
    return false
  }
  try {
    const run = await $.process.run(['herdr', 'agent', 'focus', name], { timeoutMs: 5000 })
    if (run.exitCode === 0) return true
  } catch {
  }
  await $.ui.toast(`Could not focus ${name}.`)
  return false
}
HELPER_END

# <mod dir>: every lexer violation in the module source under it, as file:line: reason; empty when clean.
violations() {
  local out rc
  out=$(node - "$1" "$ALLOWED_CALLS" "$ALLOWED_EVENTS" "$MATCHERS" "$RENDER_ELEMENTS" "$DRAWABLE" "$RETURN_KEYS" "$BANNED_TOKENS" "$BAND_DRAWABLE" "$PINNED_NAME" "$HELPER" 2>&1 <<'JS'
const fs = require("fs"), path = require("path");
const [dir, callsArg, eventsArg, matchersArg, elementsArg, drawableArg, keysArg, tokensArg, bandDrawableArg, pinnedName, helperText] = process.argv.slice(2);
const set = (s) => new Set(s.split(" "));
const CALLS = set(callsArg), EVENTS = set(eventsArg), TOKENS = set(tokensArg), DRAWABLE = set(drawableArg), BAND_DRAWABLE = set(bandDrawableArg);
const BAND_MATCHER = "component=AbovePrompt", PANE_MATCHER = "component=Pane,requestId=ah-status";
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
  let out = "", kept = "", i = 0, depth = 0, inTpl = false;
  while (i < src.length) {
    const c = src[i], n = src[i + 1];
    if (inTpl) {
      const f = frames[frames.length - 1];
      if (c === "\\") { f.text += src[i + 1] || ""; out += sp(src.slice(i, i + 2)); kept += src.slice(i, i + 2); i += 2; }
      else if (c === "`") { frames.pop(); if (!f.sub) strings.set(f.start, f.text); out += c; kept += c; i++; inTpl = false; }
      else if (c === "$" && n === "{") { f.sub = true; out += "  "; kept += "${"; i += 2; tpl.push(depth); inTpl = false; }
      else { f.text += c; out += sp(c); kept += c; i++; }
      continue;
    }
    if (c === "/" && n === "/") { let e = src.indexOf("\n", i); if (e < 0) e = src.length; out += sp(src.slice(i, e)); kept += sp(src.slice(i, e)); i = e; continue; }
    if (c === "/" && n === "*") { let e = src.indexOf("*/", i + 2); e = e < 0 ? src.length : e + 2; out += sp(src.slice(i, e)); kept += sp(src.slice(i, e)); i = e; continue; }
    if (c === "'" || c === '"') {
      let j = i + 1, val = "";
      while (j < src.length && src[j] !== c && src[j] !== "\n") { if (src[j] === "\\") { val += src[j + 1] || ""; j += 2; } else val += src[j++]; }
      const closed = src[j] === c;
      strings.set(i, val);
      out += c + sp(src.slice(i + 1, j)) + (closed ? c : "");
      kept += src.slice(i, closed ? j + 1 : j);
      i = closed ? j + 1 : j;
      continue;
    }
    if (c === "`") { frames.push({ start: i, text: "", sub: false }); out += c; kept += c; i++; inTpl = true; continue; }
    if (c === "}" && tpl.length && tpl[tpl.length - 1] === depth) { tpl.pop(); out += " "; kept += "}"; i++; inTpl = true; continue; }
    if (c === "{") depth++;
    else if (c === "}") depth--;
    out += c; kept += c; i++;
  }
  return { code: out, strings, kept };
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
  let { code, strings, kept } = lex(src);
  const at = (i, why) => found.push(`${rel}:${code.slice(0, i).split("\n").length}: ${why}`);
  // The pinned focus helper: found whole in the comment-blanked source, counted only where it is live code (not inside a
  // string), then cut out by offset so nothing else in this file is read as part of it. A copy elsewhere than register.tsx,
  // or a count other than one there, is a violation.
  let pinnedLive = false;
  {
    const pinned = new RegExp(helperText.split("\n").map((l) => l.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join("[ \\t]*\\r?\\n"), "g");
    const hits = [...kept.matchAll(pinned)].filter((h) => code.slice(h.index, h.index + 24) === kept.slice(h.index, h.index + 24));
    if (rel === "register.tsx") {
      if (hits.length !== 1) at(0, hits.length ? "the pinned focus helper appears more than once" : "the pinned focus helper text is missing or altered");
    } else if (hits.length) at(hits[0].index, "the pinned focus helper outside register.tsx");
    if (rel === "register.tsx" && hits.length === 1) {
      const s0 = hits[0].index, e0 = s0 + hits[0][0].length, blank = (t) => t.replace(/[^\n]/g, " ");
      code = code.slice(0, s0) + blank(code.slice(s0, e0)) + code.slice(e0);
      kept = kept.slice(0, s0) + blank(kept.slice(s0, e0)) + kept.slice(e0);
      for (const k of [...strings.keys()]) if (k >= s0 && k < e0) strings.delete(k);
      pinnedLive = true;
    }
    for (const m of kept.matchAll(/(?<![\w$])process(?![\w$])/g)) at(m.index, "the word process outside the pinned focus helper");
    for (const m of kept.matchAll(/(?<![\w$])prototype(?![\w$])/g)) at(m.index, "banned token prototype");
  }
  // The value of the string literal that is the whole argument span, else null.
  const literalAt = ([s, e]) => { const k = s + /^\s*/.exec(code.slice(s))[0].length; return strings.has(k) && /^(['"])\s*\1$/.test(code.slice(k, e).trim()) ? strings.get(k) : null; };

  // A matcher object's canonical form (k=v pairs, keys sorted), or null when it is not plain string pairs.
  const canonOf = ([ms, me]) => {
    const body = /^\s*\{([\s\S]*)\}\s*$/.exec(src.slice(ms, me));
    const pairs = body ? body[1].split(",").map((x) => x.trim()).filter(Boolean).map((x) => /^(?:(['"])(\w+)\1|(\w+))\s*:\s*(['"])([^'"]*)\4$/.exec(x)) : [null];
    return pairs.every(Boolean) ? pairs.map((p) => `${p[2] || p[3]}=${p[5]}`).sort().join(",") : null;
  };
  // The hook spans of the on('ui.render', { component: 'AbovePrompt' }, hook) registrations: the only place BAND_DRAWABLE may be drawn.
  const bandSpans = [], paneSpans = [];
  for (const m of code.matchAll(/(?<![\w$.])on\s*\(/g)) {
    const a = callArgs(code, m.index + m[0].length - 1);
    if (a && a.list.length === 3 && literalAt(a.list[0]) === "ui.render" && canonOf(a.list[1]) === BAND_MATCHER) bandSpans.push(a.list[2]);
    if (a && a.list.length === 3 && literalAt(a.list[0]) === "ui.render" && canonOf(a.list[1]) === PANE_MATCHER) paneSpans.push(a.list[2]);
  }
  // Every on(...) call's span, so a registration nested inside the band hook does not inherit its exemption.
  const onSpans = [];
  for (const m of code.matchAll(/(?<![\w$.])on\s*\(/g)) { const a = callArgs(code, m.index + m[0].length - 1); if (a) onSpans.push([m.index, a.close]); }
  const inSpans = (spans, i) => spans.some(([s, e]) => i >= s && i < e && !onSpans.some(([os, oe]) => os >= s && os < e && i >= os && i <= oe));
  const inBand = (i) => inSpans(bandSpans, i) || inSpans(paneSpans, i);

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
  for (const [hs, he, isPane] of [...bandSpans.map((x) => [...x, false]), ...paneSpans.map((x) => [...x, true])]) {
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
      if (!(isPane ? inSpans(paneSpans, i) : inSpans(bandSpans, i))) continue;
      const before = code.slice(0, i), rest = code.slice(i + 6), tag = /<(\/?)\s*$/.exec(before);
      if (!tag) {
        const pat = /\bconst\s*\{[^{}]*$/.exec(before), end = rest.indexOf("}");
        const ok = pat && own(pat.index) && /[{,]\s*$/.test(before) && /^\s*[,}]/.test(rest) && end >= 0 &&
          /^\s*=\s*\$\s*\.\s*ui\s*\.\s*resolve\s*\(\s*[\w$]+\s*\)/.test(rest.slice(end + 1));
        if (!ok) at(i, "Button outside an unrenamed $.ui.resolve destructure at the band hook's own depth, or a JSX tag in its own return");
        continue;
      }
      const tpos = i - tag[0].length, r = returns.filter((x) => x < tpos).pop();
      let why = null, innermost = null;
      if (r === undefined || tpos >= argEnd(r)) why = "tag is not inside the band hook's own return";
      else {
        const seg = code.slice(argStart(r), tpos), open = [];
        for (let k = 0; k < seg.length; k++) { if (seg[k] === "(") open.push(k); else if (seg[k] === ")") open.pop(); }
        // The Pane hook alone: function literals before the tag may be at most two expression-bodied arrow callbacks, each the sole
        // argument of a literal `.map(` call, with no `$` in its parameters. mapParens holds the "(" of each such call.
        const mapParens = new Set();
        let fnWhy = null;
        if (tag[1] !== "/" && isPane) {
          const base = argStart(r);
          if (/\bfunction\b/.test(seg)) fnWhy = "tag sits behind a function keyword callback";
          const arrows = [...seg.matchAll(/=>/g)];
          if (!fnWhy && arrows.length > 2) fnWhy = "more than two callbacks before the tag";
          for (const ar of arrows) {
            if (fnWhy) break;
            const before = seg.slice(0, ar.index).replace(/\s+$/, "");
            const ps = before.endsWith(")") ? matchOpen(base + before.length - 1) - base : (() => { const w = /([\w$]+)$/.exec(before); return w ? before.length - w[1].length : -1; })();
            const paramsText = before.endsWith(")") ? before.slice(ps) : before.slice(ps);
            const head = seg.slice(0, ps).replace(/\s+$/, "");
            if (ps < 0 || !head.endsWith(".map(") || seg.slice(0, ps).length !== head.length) fnWhy = "a callback before the tag is not the first thing in a literal .map( call";
            else if (/\$/.test(paramsText)) fnWhy = "a map callback's parameters contain $";
            else if (/^\s*\{/.test(seg.slice(ar.index + 2))) fnWhy = "a map callback has a block body";
            else {
              const open = base + head.length - 1, call = callArgs(code, open);
              if (!call || call.list.length !== 1) fnWhy = "a map callback is not the sole argument of its .map( call";
              else { mapParens.add(head.length - 1); innermost = paramsText; }
            }
          }
        }
        if (tag[1] !== "/" && !isPane && /=>|\bfunction\b/.test(seg)) why = "tag sits inside a function literal";
        else if (fnWhy) why = fnWhy;
        else if (open.some((k) => { if (mapParens.has(k)) return false; const pre = seg.slice(0, k).replace(/\s+$/, ""), w = /([\w$]+)$/.exec(pre); return w ? !GROUP.has(w[1]) : /[)\]]$/.test(pre) || /\?\.$/.test(pre) || /[\w$>]>$/.test(pre); })) why = "tag sits inside a call's arguments";
        else if ((seg.match(/`/g) || []).length % 2) why = "tag sits inside a template literal";
        else if (hasAssign(code.slice(argStart(r), argEnd(r)))) why = "the return holds an assignment";
      }
      if (why) at(i, `Button ${why}`);
      else if (isPane && tag[1] !== "/") {
        // W3: the Pane Button is plain, labels with a bare identifier the innermost map callback destructures, and its onPress is
        // exactly one call of the focus helper with that same identifier.
        let end = -1, d = 0;
        for (let k = i + 6; k < code.length; k++) { const ch = code[k]; if (ch === "{") d++; else if (ch === "}") d--; else if (d === 0 && ch === ">" && code[k - 1] !== "=") { end = k; break; } }
        const attrs = end < 0 ? "" : code.slice(i + 6, end).replace(/\/\s*$/, "");
        let flat = attrs; for (let g = 0; g < 8; g++) flat = flat.replace(/\{[^{}]*\}/g, "{}");
        const labels = [...attrs.matchAll(/(?:^|\s)label\s*=\s*\{\s*([A-Za-z_$][\w$]*)\s*\}/g)], labelCount = (flat.match(/(?:^|\s)label\s*=/g) || []).length;
        const press = /(?:^|\s)onPress\s*=\s*\{/.exec(attrs);
        let pressText = null;
        if (press) { let dd = 0; for (let k = press.index + press[0].length - 1; k < attrs.length; k++) { if (attrs[k] === "{") dd++; else if (attrs[k] === "}" && --dd === 0) { pressText = attrs.slice(press.index + press[0].length, k); break; } } }
        const id = labels.length === 1 && labelCount === 1 ? labels[0][1] : null, esc = (x) => x.replace(/\$/g, "\\$");
        const call = id === null ? null : new RegExp(`^\\s*(?:async\\s*)?\\(\\s*\\)\\s*=>\\s*(?:\\{\\s*(?:try\\s*\\{\\s*)?(?:await\\s+)?${pinnedName}\\(\\s*\\$\\s*,\\s*${esc(id)}\\s*\\)\\s*;?\\s*(?:\\}\\s*catch\\s*(?:\\(\\s*[\\w$]*\\s*\\))?\\s*\\{\\s*\\}\\s*)?\\}|(?:await\\s+)?${pinnedName}\\(\\s*\\$\\s*,\\s*${esc(id)}\\s*\\))\\s*$`);
        if (!/(?:^|\s)plain(?=\s|=|$)/.test(flat)) at(i, "a Pane Button without plain");
        else if (id === null) at(i, "a Pane Button whose label is not a bare identifier");
        else if (pressText === null || !call.test(pressText)) at(i, `a Pane Button onPress that is not exactly one ${pinnedName}($, <label>) call`);
        else if (!(innermost !== null && new RegExp(`^\\(\\s*\\{[^}]*(?<![\\w$])${esc(id)}(?![\\w$])[^}]*\\}\\s*\\)$`).test(innermost.replace(/\s+/g, " ")))) at(i, "a Pane Button label the innermost map callback does not destructure");
      }
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
    if (name === pinnedName) return pinnedLive && decls === 0 && other === 0;
    return decls === 1 && other === 0;
  };
  // The pinned helper's name is bound once, inside the cut-out text: any other binding of it is a violation, call or no call.
  if (pinnedLive) {
    const pn = pinnedName.replace(/\$/g, "\\$");
    for (const h of code.matchAll(new RegExp(`(?<![\\w$])${pn}(?![\\w$])`, "g"))) {
      const before = code.slice(0, h.index), after = code.slice(h.index + pinnedName.length);
      if (isMember(before)) continue;
      const binds = /(?<![\w$.])(?:const|let|var|function\*?|class)\s+$/.test(before) || /^\s*(?::[^=;]+)?=(?!=)/.test(after) || /^\s*\(/.test(after) && (() => { const a = callArgs(code, h.index + pinnedName.length + /^\s*/.exec(after)[0].length); return !a || /^\s*(?::[^;{}=]*)?\{/.test(code.slice(a.close + 1)); })();
      if (binds) at(h.index, "the pinned focus helper's name is bound again");
    }
  }

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
  ); rc=$?
  if [ "$rc" != 0 ]; then echo "the lexer crashed (exit $rc): ${out:0:300}"; else printf '%s' "$out"; fi
}

# <plugin dir>: the validate net's verdict on it: each printed registration or call outside the lists,
# or why validate failed; empty when clean. A registration prints as `event` or `event{k=v, …}`.
valnet() {
  local out rc
  mkdir -p "$SANDBOX/home/.claude"
  out=$(cd "$SANDBOX" && HOME="$SANDBOX/home" CLAUDE_CONFIG_DIR="$SANDBOX/home/.claude" perl -e 'alarm shift; exec @ARGV' 120 claude plugin validate "$1" 2>&1); rc=$?
  if [ "$rc" != 0 ]; then echo "validate failed (exit $rc): ${out:0:300}"; return; fi
  printf '%s\n' "$out" | node -e '
    const [calls, events, matchers] = process.argv.slice(1, 4).map((s) => s.split(" "));
    const net = [process.argv[4]];
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
      if (c && c[1].trim() !== "nothing on $") for (const x of c[1].split(",").map((s) => s.trim().replace(/^\$\./, "")).filter(Boolean)) if (!calls.includes(x) && !net.includes(x)) bad.push(`call ${x}: not an allowed call`);
    }
    if (!hooks) bad.push("validate printed no hooks");
    process.stdout.write(bad.join("\n"));
  ' "$ALLOWED_CALLS" "$ALLOWED_EVENTS" "$MATCHERS" "$NET_EXTRA_CALL"
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
let s; const keep = (q, x) => { s = x; return x }; on('ui.render', { component: 'AbovePrompt' }, ($, e, next) => { const { Button } = $.ui.resolve(e); return keep`${<Button />}` }); on('ui.render', { component: 'Pane', requestId: 'ah-status' }, ($, e, next) => s)
EOF

# The pinned focus helper (W4): the one process, matched whole. Each planted form must fail the lexer on its own.
while IFS= read -r line; do
  [ -n "$line" ] || continue
  OUT=$(planted "$line")
  check "lexer alone catches: $line  [${OUT%%$'\n'*}]" '[ -n "$OUT" ]'
done <<'EOF'
$.process.spawn(['herdr'])
await $.process.run(['herdr', 'agent', 'focus', 'x'])
const openPane2 = async ($) => { await $.process.run(['herdr']) }
on('ui.render', { component: 'Pane', requestId: 'ah-status' }, async ($, e, next) => { await $.process.run(['herdr', 'agent', 'focus', 'x']); return next(e) })
const p = $.process
const { run } = $.process
$['process']
const q = "process"
RegExp.prototype.test = () => true
const focusMember = ($) => 0
function focusMember(x) { return x }
let focusMember = 1
focusMember = null
EOF
# <from> <to> [line...]: the lexer's verdict on a scratch copy whose pinned helper has <from> replaced by <to>, with the lines appended.
altered() {
  copy_mod
  node -e 'const fs = require("fs"), p = process.argv[1], [from, to] = [process.argv[2], process.argv[3]]; const t = fs.readFileSync(p, "utf8"); const i = t.indexOf("export const focusMember"); if (i < 0 || !t.slice(i).includes(from)) { console.error("no such text in the helper"); process.exit(2); } fs.writeFileSync(p, t.slice(0, i) + t.slice(i).replace(from, () => to));' "$SANDBOX/mod/register.tsx" "$1" "$2" || { echo "scratch edit failed"; return; }
  shift 2; [ $# -gt 0 ] && printf '%s\n' "$@" >> "$SANDBOX/mod/register.tsx"
  violations "$SANDBOX/mod"
}
altcase() { # <label> <from> <to> [line...]
  local label=$1; shift
  OUT=$(altered "$@")
  check "lexer alone catches a changed helper: $label  [${OUT%%$'\n'*}]" '[ -n "$OUT" ] && [ "$OUT" != "scratch edit failed" ]'
}
altcase "3a argv element changed" "'focus'" "'get'"
altcase "3b a fifth argv element" "'focus', name]" "'focus', name, 'x']"
altcase "3c a spread" "['herdr', 'agent', 'focus', name]" "[...['herdr', 'agent', 'focus'], name]"
altcase "3d a template string" "'focus'" '`focus`'
altcase "3e sh -c" "['herdr', 'agent', 'focus', name]" "['sh', '-c', name]"
altcase "3f a second init key" "{ timeoutMs: 5000 }" "{ timeoutMs: 5000, cwd: '/' }"
altcase "3g the pattern check removed" "typeof name !== 'string' || !/^[a-z][a-z0-9_-]{0,31}\$/.test(name)" "typeof name !== 'string'"
altcase "3h success on any exit" "run.exitCode === 0" "run.exitCode >= 0"
altcase "3i the timeout changed" "5000" "600000"
altcase "8 the pattern as a constant outside the pinned text" "/^[a-z][a-z0-9_-]{0,31}\$/.test(name)" "NAME_RE.test(name)" "const NAME_RE = /.*/"
OUT=$(planted "$HELPER")
check "lexer alone catches: the helper text present twice  [${OUT%%$'\n'*}]" 'printf "%s" "$OUT" | grep -q "more than once"'
OUT=$(altered "'focus'" "'get'" "/* $HELPER */")
check "lexer alone catches: an altered live helper with the pinned text in a comment  [${OUT%%$'\n'*}]" '[ -n "$OUT" ] && printf "%s" "$OUT" | grep -q "altered"'
copy_mod; sed -i.bak "s#^export const focusMember#const focusMember#" "$SANDBOX/mod/register.tsx"; rm -f "$SANDBOX/mod/register.tsx.bak"
OUT=$(violations "$SANDBOX/mod")
check "lexer alone catches: the helper without its export (a changed text)  [${OUT%%$'\n'*}]" '[ -n "$OUT" ]'
copy_mod; printf '%s\n' "$HELPER" > "$SANDBOX/mod/other.ts"
OUT=$(violations "$SANDBOX/mod")
check "lexer alone catches: the pinned text in a file other than register.tsx  [${OUT%%$'\n'*}]" 'printf "%s" "$OUT" | grep -q "outside register.tsx"'
OUT=$(violations "$PLUGIN/mod")
check "the repo's own register.tsx holds the helper exactly once and the word process nowhere else" '[ -z "$OUT" ] && [ "$(grep -c "export const focusMember" "$PLUGIN/mod/register.tsx")" = 1 ]'

# The Pane hook may draw a Button per row (W3): plain, labelled by a bare identifier the innermost .map callback destructures, and
# an onPress that is exactly one focus-helper call with that identifier. Each other form must fail the lexer on its own.
while IFS= read -r line; do
  [ -n "$line" ] || continue
  OUT=$(planted "$line")
  check "lexer alone catches: $line  [${OUT%%$'\n'*}]" '[ -n "$OUT" ]'
done <<'EOF'
on('ui.render', { component: 'Pane', requestId: 'ah-status' }, async ($, e, next) => { const { Box, Button } = $.ui.resolve(e); return <Box>{e.props.rows.map(({ a, b }) => <Button plain label={a} onPress={() => focusMember($, b)} />)}</Box> })
on('ui.render', { component: 'Pane', requestId: 'ah-status' }, async ($, e, next) => { const { Box, Button } = $.ui.resolve(e); return <Box>{e.props.rows.map(({ name }) => <Button label={name} onPress={() => focusMember($, name)} />)}</Box> })
on('ui.render', { component: 'Pane', requestId: 'ah-status' }, async ($, e, next) => { const { Box, Button } = $.ui.resolve(e); return <Box>{e.props.rows.map(({ name }) => <Button plain label={String(name)} onPress={() => focusMember($, name)} />)}</Box> })
on('ui.render', { component: 'Pane', requestId: 'ah-status' }, async ($, e, next) => { const { Box, Button } = $.ui.resolve(e); return <Box>{e.props.rows.map(({ name }) => <Button plain label={`x`} onPress={() => focusMember($, name)} />)}</Box> })
on('ui.render', { component: 'Pane', requestId: 'ah-status' }, async ($, e, next) => { const { Box, Button } = $.ui.resolve(e); return <Box>{e.props.rows.map(({ name }) => <Button plain label="x" onPress={() => focusMember($, name)} />)}</Box> })
on('ui.render', { component: 'Pane', requestId: 'ah-status' }, async ($, e, next) => { const { Box, Button } = $.ui.resolve(e); return <Box>{e.props.rows.map(({ name }) => <Button plain label={name} onPress={() => { focusMember($, name); other() }} />)}</Box> })
on('ui.render', { component: 'Pane', requestId: 'ah-status' }, async ($, e, next) => { const { Box, Button } = $.ui.resolve(e); return <Box>{e.props.rows.map(({ name }) => <Button plain label={name} onPress={() => focusMember($, name, $)} />)}</Box> })
on('ui.render', { component: 'Pane', requestId: 'ah-status' }, async ($, e, next) => { const { Box, Button } = $.ui.resolve(e); return <Box>{e.props.rows.map(({ name }) => <Button plain label={name} onPress={() => x.focusMember($, name)} />)}</Box> })
on('ui.render', { component: 'Pane', requestId: 'ah-status' }, async ($, e, next) => { const { Box, Button } = $.ui.resolve(e); return <Box>{e.props.rows.map(({ name }) => <Button plain label={name} onPress={() => $.ui.toast(name)} />)}</Box> })
on('ui.render', { component: 'Pane', requestId: 'ah-status' }, async ($, e, next) => { const { Box, Button } = $.ui.resolve(e); return <Box>{e.props.rows.map((r) => <Button plain label={r} onPress={() => focusMember($, r)} />)}</Box> })
on('session.start', async ($, e, next) => { const { Box, Button } = $.ui.resolve(e); return <Box>{e.props.rows.map(({ name }) => <Button plain label={name} onPress={() => focusMember($, name)} />)}</Box> })
on('ui.render', { component: 'Pane', requestId: 'ah-status' }, async ($, e, next) => { const { Box, Button } = $.ui.resolve(e); const draw = ({ name }) => <Button plain label={name} onPress={() => focusMember($, name)} />; return <Box>{e.props.rows.map(draw)}</Box> })
on('ui.render', { component: 'Pane', requestId: 'ah-status' }, async ($, e, next) => { const { Box, Button } = $.ui.resolve(e); return <Box>{e.props.a.map((s) => e.props.b.map((t) => e.props.c.map(({ name }) => <Button plain label={name} onPress={() => focusMember($, name)} />)))}</Box> })
on('ui.render', { component: 'Pane', requestId: 'ah-status' }, async ($, e, next) => { const { Box, Button } = $.ui.resolve(e); return <Box>{e.props.rows.filter(({ name }) => <Button plain label={name} onPress={() => focusMember($, name)} />)}</Box> })
on('ui.render', { component: 'Pane', requestId: 'ah-status' }, async ($, e, next) => { const { Box, Button } = $.ui.resolve(e); return <Box>{e.props.rows.flatMap(({ name }) => <Button plain label={name} onPress={() => focusMember($, name)} />)}</Box> })
on('ui.render', { component: 'Pane', requestId: 'ah-status' }, async ($, e, next) => { const { Box, Button } = $.ui.resolve(e); return <Box>{e.props.rows.forEach(({ name }) => <Button plain label={name} onPress={() => focusMember($, name)} />)}</Box> })
on('ui.render', { component: 'Pane', requestId: 'ah-status' }, async ($, e, next) => { const { Box, Button } = $.ui.resolve(e); const name = 'x'; return <Box>{(() => <Button plain label={name} onPress={() => focusMember($, name)} />)()}</Box> })
on('ui.render', { component: 'Pane', requestId: 'ah-status' }, async ($, e, next) => { const { Box, Button } = $.ui.resolve(e); return <Box>{e.props.rows.map(function ({ name }) { return <Button plain label={name} onPress={() => focusMember($, name)} /> })}</Box> })
on('ui.render', { component: 'Pane', requestId: 'ah-status' }, async ($, e, next) => { const { Box, Button } = $.ui.resolve(e); return <Box>{e.props.rows.map(({ name }) => { return <Button plain label={name} onPress={() => focusMember($, name)} /> })}</Box> })
on('ui.render', { component: 'Pane', requestId: 'ah-status' }, async ($, e, next) => { const { Box, Button } = $.ui.resolve(e); return <Box>{e.props.rows['map'](({ name }) => <Button plain label={name} onPress={() => focusMember($, name)} />)}</Box> })
on('ui.render', { component: 'Pane', requestId: 'ah-status' }, async ($, e, next) => { const { Box, Button } = $.ui.resolve(e); return <Box>{e.props.rows.map(($) => <Button plain label={$} onPress={() => focusMember($, $)} />)}</Box> })
on('ui.render', { component: 'Pane', requestId: 'ah-status' }, async ($, e, next) => { const { Box, Button } = $.ui.resolve(e); return <Box>{e.props.rows.map(({ $x, name }) => <Button plain label={name} onPress={() => focusMember($, name)} />)}</Box> })
on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => { const { Box, Button } = $.ui.resolve(e); return <Box>{e.props.rows.map(({ name }) => <Button plain label={name} onPress={() => focusMember($, name)} />)}</Box> })
on('ui.render', { component: 'Pane', requestId: 'ah-status' }, async ($, e, next) => { const { Box, Button } = $.ui.resolve(e); return <Box>{e.props.rows.map(({ name }) => drawRow(Button, name))}</Box> })
let B; on('ui.render', { component: 'Pane', requestId: 'ah-status' }, async ($, e, next) => { const { Box, Button } = $.ui.resolve(e); B = Button; return <Box /> })
on('ui.render', { component: 'Pane', requestId: 'ah-status' }, async ($, e, next) => { const { Box, Button } = $.ui.resolve(e); const B = Button; return <Box>{e.props.rows.map(({ name }) => <B plain label={name} onPress={() => focusMember($, name)} />)}</Box> })
on('ui.render', { component: 'Pane', requestId: 'ah-status' }, async ($, e, next) => { const { Box, Button } = $.ui.resolve(e); return <Box>{e.props.rows.map(({ name }) => <Button plain label={name} onPress={() => focusMember($, name)} />).concat(e.props.more.map(({ name }) => <Button plain label={name} onPress={() => focusMember($, name)} />))}</Box> })
EOF

# The same hook, in the allowed form, passes: nested maps (sections, then rows), a keyed Box around the Button, plain, a bare label identifier destructured by the
# innermost callback, and an onPress that is one helper call, awaited or wrapped in a try with an empty catch.
OUT=$(planted "on('ui.render', { component: 'Pane', requestId: 'ah-status' }, async (\$, e, next) => { const { Box, Button, Text } = \$.ui.resolve(e); return (<Box>{e.props.sections.map((s) => <Box key={s.key}>{s.rows.map(({ name, text }) => <Box key={name}><Button plain label={name} hover={{ underline: true }} onPress={() => focusMember(\$, name)} /><Text>{text}</Text></Box>)}</Box>)}</Box>) })")
check "lexer passes the Pane Button form: nested .map callbacks, a keyed Box, plain, a destructured label, one focus call" '[ -z "$OUT" ]'
OUT=$(planted "on('ui.render', { component: 'Pane', requestId: 'ah-status' }, async (\$, e, next) => { const { Box, Button } = \$.ui.resolve(e); return (<Box>{e.props.rows.map(({ name }) => <Box key={name}><Button plain label={name} onPress={async () => { try { await focusMember(\$, name) } catch {} }} /></Box>)}</Box>) })")
check "lexer passes a Pane Button whose onPress awaits the focus call inside a try with an empty catch" '[ -z "$OUT" ]'
OUT=$(planted "on('ui.render', { component: 'Pane', requestId: 'ah-status' }, async (\$, e, next) => { const { Box, Button } = \$.ui.resolve(e); return (<Box>{e.props.rows.map(({ name }) => <Box key={name}><Button plain label={name} onPress={() => focusMember(\$, name)} /></Box>)}</Box>) })")
check "lexer passes a one-level .map Pane Button" '[ -z "$OUT" ]'

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
  { echo "import type { Register } from 'claude-code'"; echo "export const register: Register = (on, options) => {"; printf '  %s\n' "$@"; echo "}"; printf '%s\n' "$HELPER"; } > "$SANDBOX/p3/mod/register.tsx"
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
