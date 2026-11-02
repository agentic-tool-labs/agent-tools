/**
 * Strict-mode helpers for Bash commands, used by pretooluse-nudge.mjs.
 *
 * isExempt(command): true when every part of the command is a listed action
 * (writing its own input, herdr pane/tab/workspace control, git and gh writes,
 * plugin updates, cd and sleep) or belongs to the one allowed bounded pane
 * peek (`herdr pane read --lines N`, N from 1 to 60, piped only through
 * grep/head/tail stdin filters). It parses a small shell grammar and answers
 * false for anything outside it (loops, subshells, braces, a background `&`,
 * comments, input redirection, any command substitution other than the
 * commit-message heredoc idiom), so an unusual command falls back to the
 * ordinary checkpoint rules instead of slipping past them.
 *
 * nestedLookup(command, isLookup): true when a command nested inside this one
 * is a lookup: the text of a `$(…)` or backtick span that is not inside single
 * quotes or a quoted-delimiter heredoc body, the script given to
 * `bash|sh|zsh|dash|ksh -c`, or the arguments of `eval`. `isLookup` judges one
 * command's text; nesting is followed recursively. A `$(` or backtick that
 * never closes counts as a lookup, and so does nesting deeper than MAX_DEPTH.
 *
 * Importing this module has no side effects, so tests can load it directly.
 */

const ASSIGN_RE = /^[A-Za-z_][A-Za-z0-9_]*=/;
const PARAM_RE = /^\$\{(?:[A-Za-z_][A-Za-z0-9_]*|[0-9]+|[@*#?$!-])\}/;
const KEYWORDS = new Set([
  "if", "then", "elif", "else", "fi", "for", "while", "until", "do", "done",
  "case", "esac", "select", "function", "time", "coproc", "[[", "{", "}",
]);
const SHELLS = new Set(["bash", "sh", "zsh", "dash", "ksh"]);
const MAX_DEPTH = 16;

// `$(cat <<'D'` … a line equal to D … `)`, with only whitespace around the
// heredoc inside the parentheses. Returns the index just past `)`, or -1.
function matchCommitIdiom(s, i) {
  const head = /^\$\(\s*cat[ \t]+<<(-?)[ \t]*(['"])([^'"\s]+)\2[ \t]*\n/.exec(s.slice(i));
  if (!head) return -1;
  const strip = head[1] === "-";
  const delim = head[3];
  let k = i + head[0].length;
  while (k < s.length) {
    const e = s.indexOf("\n", k);
    const line = s.slice(k, e < 0 ? s.length : e);
    if ((strip ? line.replace(/^\t+/, "") : line) === delim) {
      if (e < 0) return -1;
      const tail = /^\s*\)/.exec(s.slice(e + 1));
      return tail ? e + 1 + tail[0].length : -1;
    }
    if (e < 0) return -1;
    k = e + 1;
  }
  return -1;
}

/** Index of the closing backtick, or -1. `k` is just past the opening one. */
function backtickEnd(s, k) {
  while (k < s.length) {
    if (s[k] === "\\") { k += 2; continue; }
    if (s[k] === "`") return k;
    k++;
  }
  return -1;
}

/** Index just past the closing double quote, or -1. `k` is just past the opening one. */
function doubleQuoteEnd(s, k, depth) {
  while (k < s.length) {
    const c = s[k];
    if (c === "\\") { k += 2; continue; }
    if (c === '"') return k + 1;
    if (c === "`") { const e = backtickEnd(s, k + 1); if (e < 0) return -1; k = e + 1; continue; }
    if (c === "$" && s[k + 1] === "(") { const e = substitutionEnd(s, k + 2, depth + 1); if (e < 0) return -1; k = e + 1; continue; }
    k++;
  }
  return -1;
}

/** Parse a heredoc operator's delimiter; `k` is just past `<<`. */
function heredocHead(s, k) {
  let strip = false;
  if (s[k] === "-") { strip = true; k++; }
  while (s[k] === " " || s[k] === "\t") k++;
  const m = /^[^\s;|&<>()]+/.exec(s.slice(k));
  if (!m) return null;
  return { delim: m[0].replace(/['"\\]/g, ""), strip, next: k + m[0].length };
}

/** Skip the bodies of pending heredocs; `k` is the start of the line after the operator. */
function skipBodies(s, k, pending) {
  while (pending.length) {
    const h = pending.shift();
    while (k < s.length) {
      const e = s.indexOf("\n", k);
      const line = s.slice(k, e < 0 ? s.length : e);
      k = e < 0 ? s.length : e + 1;
      if ((h.strip ? line.replace(/^\t+/, "") : line) === h.delim) break;
    }
  }
  return k;
}

/** Index of the `)` closing a `$(`, or -1. `k` is just past `$(`. */
function substitutionEnd(s, k, depth = 0) {
  if (depth > MAX_DEPTH) return -1;
  let open = 1;
  const pending = [];
  while (k < s.length) {
    const c = s[k];
    if (c === "\\") { k += 2; continue; }
    if (c === "'") { const e = s.indexOf("'", k + 1); if (e < 0) return -1; k = e + 1; continue; }
    if (c === '"') { const e = doubleQuoteEnd(s, k + 1, depth); if (e < 0) return -1; k = e; continue; }
    if (c === "`") { const e = backtickEnd(s, k + 1); if (e < 0) return -1; k = e + 1; continue; }
    if (c === "$" && s[k + 1] === "(") { const e = substitutionEnd(s, k + 2, depth + 1); if (e < 0) return -1; k = e + 1; continue; }
    if (c === "<" && s[k + 1] === "<" && s[k + 2] !== "<") {
      const h = heredocHead(s, k + 2);
      if (h) { pending.push(h); k = h.next; continue; }
    }
    if (c === "\n" && pending.length) { k = skipBodies(s, k + 1, pending); continue; }
    if (c === "(") open++;
    else if (c === ")" && --open === 0) return k;
    k++;
  }
  return -1;
}

const newCommand = () => ({ words: [], redirs: [], heredocs: [], herestrings: 0, input: false });
const isEmptyCommand = (c) =>
  !c.words.length && !c.redirs.length && !c.heredocs.length && !c.herestrings && !c.input;

/**
 * Tokenize a command into pipelines of simple commands. Never throws. Anything
 * outside the accepted grammar sets `reject` (the command cannot be exempt) but
 * lexing continues, so nestedLookup still sees every word and substitution.
 */
function lex(src) {
  const out = { pipelines: [], substs: [], unbalanced: false, reject: "" };
  const rej = (why) => { if (!out.reject) out.reject = why; };
  const n = src.length;
  let i = 0;
  let pipeline = [];
  let cmd = newCommand();
  let word = null;
  let expect = null;
  let needCommand = false;
  const pending = [];

  const startWord = () => { if (!word) word = { text: "", plain: true, start: i }; };
  const finishWord = () => {
    if (!word) return;
    const w = { text: word.text, plain: word.plain, raw: src.slice(word.start, i) };
    word = null;
    if (expect) {
      const e = expect;
      expect = null;
      if (e.kind === "redir") cmd.redirs.push({ op: e.op, target: w.text, fd: e.fd || "" });
      else if (e.kind === "heredoc") pending.push({ delim: w.text, quoted: !w.plain, strip: e.strip, cmd, at: e.at });
      else cmd.herestrings++;
      return;
    }
    if (!cmd.words.length && KEYWORDS.has(w.text)) rej(`keyword ${w.text}`);
    cmd.words.push(w);
  };
  const endCommand = (sep) => {
    finishWord();
    if (expect) { rej("missing redirection target"); expect = null; }
    const empty = isEmptyCommand(cmd);
    if (empty && needCommand && sep === "\n") return;
    if (empty && sep !== "\n" && sep !== "" && sep !== "(") rej("empty command");
    if (!empty) { pipeline.push(cmd); needCommand = false; }
    if (sep === "|" || sep === "&&" || sep === "||") needCommand = true;
    if (sep !== "|") { if (pipeline.length) out.pipelines.push(pipeline); pipeline = []; }
    cmd = newCommand();
  };
  const scanBody = (body) => {
    if (/\$\(|`/.test(body)) rej("substitution in a heredoc body");
    let k = 0;
    while (k < body.length) {
      const c = body[k];
      if (c === "\\") { k += 2; continue; }
      if (c === "$" && body[k + 1] === "(") {
        const e = substitutionEnd(body, k + 2);
        if (e < 0) { out.unbalanced = true; return; }
        out.substs.push(body.slice(k + 2, e));
        k = e + 1;
        continue;
      }
      if (c === "`") {
        const e = backtickEnd(body, k + 1);
        if (e < 0) { out.unbalanced = true; return; }
        out.substs.push(body.slice(k + 1, e));
        k = e + 1;
        continue;
      }
      k++;
    }
  };
  const readBodies = (k) => {
    while (pending.length) {
      const h = pending.shift();
      const start = k;
      let body = "";
      let found = false;
      while (k < n) {
        const e = src.indexOf("\n", k);
        const line = src.slice(k, e < 0 ? n : e);
        k = e < 0 ? n : e + 1;
        if ((h.strip ? line.replace(/^\t+/, "") : line) === h.delim) { found = true; break; }
        body += line + "\n";
      }
      if (!found) rej("unterminated heredoc");
      // `at` is the operator's index; start/end span the body and its
      // terminator line in `src`.
      h.cmd.heredocs.push({ quoted: h.quoted, body, found, at: h.at, start, end: k });
      if (!h.quoted) scanBody(body);
    }
    return k;
  };
  // Returns the index just past the closing quote.
  const readDouble = (k) => {
    while (k < n) {
      const c = src[k];
      if (c === '"') return k + 1;
      if (c === "\\") {
        const d = src[k + 1];
        if (d === "\n") { k += 2; continue; }
        if (d === '"' || d === "\\" || d === "$" || d === "`") { word.text += d; k += 2; continue; }
        word.text += c;
        k++;
        continue;
      }
      if (c === "$" && src[k + 1] === "(") {
        const idiom = matchCommitIdiom(src, k);
        if (idiom > 0) {
          if (pending.length) rej("newline in quotes with a pending heredoc");
          word.text += src.slice(k, idiom);
          k = idiom;
          continue;
        }
        rej("command substitution");
        const e = substitutionEnd(src, k + 2);
        if (e < 0) { out.unbalanced = true; return n; }
        out.substs.push(src.slice(k + 2, e));
        word.text += src.slice(k, e + 1);
        k = e + 1;
        continue;
      }
      if (c === "`") {
        rej("backtick");
        const e = backtickEnd(src, k + 1);
        if (e < 0) { out.unbalanced = true; return n; }
        out.substs.push(src.slice(k + 1, e));
        word.text += src.slice(k, e + 1);
        k = e + 1;
        continue;
      }
      if (c === "$" && src[k + 1] === "{" && !PARAM_RE.test(src.slice(k))) rej("parameter expansion");
      if (c === "\n" && pending.length) rej("newline in quotes with a pending heredoc");
      word.text += c;
      k++;
    }
    rej("unterminated quote");
    return n;
  };

  while (i < n) {
    const c = src[i];

    if (c === "\\") {
      if (src[i + 1] === "\n") { i += 2; continue; }
      startWord();
      word.plain = false;
      word.text += src[i + 1] ?? "\\";
      i += 2;
      continue;
    }
    if (c === "'") {
      startWord();
      word.plain = false;
      const e = src.indexOf("'", i + 1);
      if (e < 0) { rej("unterminated quote"); i = n; break; }
      if (pending.length && src.slice(i + 1, e).includes("\n")) rej("newline in quotes with a pending heredoc");
      word.text += src.slice(i + 1, e);
      i = e + 1;
      continue;
    }
    if (c === '"') {
      startWord();
      word.plain = false;
      i = readDouble(i + 1);
      continue;
    }
    if (c === "`") {
      startWord();
      word.plain = false;
      rej("backtick");
      const e = backtickEnd(src, i + 1);
      if (e < 0) { out.unbalanced = true; i = n; break; }
      out.substs.push(src.slice(i + 1, e));
      word.text += src.slice(i, e + 1);
      i = e + 1;
      continue;
    }
    if (c === "$") {
      const d = src[i + 1];
      startWord();
      if (d === "(") {
        word.plain = false;
        rej("command substitution");
        const e = substitutionEnd(src, i + 2);
        if (e < 0) { out.unbalanced = true; i = n; break; }
        out.substs.push(src.slice(i + 2, e));
        word.text += src.slice(i, e + 1);
        i = e + 1;
        continue;
      }
      if (d === "'") {
        word.plain = false;
        rej("ANSI-C quoting");
        let k = i + 2;
        while (k < n && src[k] !== "'") k += src[k] === "\\" ? 2 : 1;
        if (k >= n) { rej("unterminated quote"); i = n; break; }
        word.text += src.slice(i + 2, k);
        i = k + 1;
        continue;
      }
      if (d === '"') { rej("locale quoting"); i++; continue; }
      if (d === "{" && !PARAM_RE.test(src.slice(i))) rej("parameter expansion");
      word.text += "$";
      i++;
      continue;
    }
    if (c === " " || c === "\t") { finishWord(); i++; continue; }
    if (c === "\n") { endCommand("\n"); i = readBodies(i + 1); continue; }
    if (c === "#" && !word) {
      rej("comment");
      const e = src.indexOf("\n", i);
      i = e < 0 ? n : e;
      continue;
    }
    if (c === ";") {
      if (src[i + 1] === ";" || src[i + 1] === "&") { rej("case terminator"); i++; }
      endCommand(";");
      i++;
      continue;
    }
    if (c === "&") {
      if (src[i + 1] === "&") { endCommand("&&"); i += 2; continue; }
      if (src[i + 1] === ">") {
        finishWord();
        const op = src[i + 2] === ">" ? "&>>" : "&>";
        expect = { kind: "redir", op };
        i += op.length;
        continue;
      }
      rej("background &");
      endCommand("&");
      i++;
      continue;
    }
    if (c === "|") {
      if (src[i + 1] === "|") { endCommand("||"); i += 2; continue; }
      endCommand("|");
      i += src[i + 1] === "&" ? 2 : 1;
      continue;
    }
    if (c === "(" || c === ")") {
      rej("subshell or grouping");
      endCommand("(");
      i++;
      continue;
    }
    if (c === "<") {
      if (src.startsWith("<<<", i)) { finishWord(); expect = { kind: "herestring" }; i += 3; continue; }
      if (src.startsWith("<<", i)) {
        finishWord();
        const strip = src[i + 2] === "-";
        expect = { kind: "heredoc", strip, at: i };
        i += strip ? 3 : 2;
        continue;
      }
      if (src[i + 1] === "(") { rej("process substitution"); i++; continue; }
      if (word && word.plain && /^\d+$/.test(word.text)) word = null;
      else finishWord();
      rej("input redirection");
      cmd.input = true;
      if (src[i + 1] === "&") { i += 2; continue; }
      expect = { kind: "redir", op: "<" };
      i += src[i + 1] === ">" ? 2 : 1;
      continue;
    }
    if (c === ">") {
      if (src[i + 1] === "(") { rej("process substitution"); i++; continue; }
      // A plain run of digits right before `>` is the file descriptor, not a word.
      const fd = word && word.plain && /^\d+$/.test(word.text) ? word.text : "";
      if (fd) word = null;
      else finishWord();
      if (src[i + 1] === "&") {
        const m = /^\d+/.exec(src.slice(i + 2));
        if (!m) { rej("unsupported redirection"); i += 2; continue; }
        cmd.redirs.push({ op: ">&", target: m[0], fd });
        i += 2 + m[0].length;
        continue;
      }
      const op = src[i + 1] === ">" ? ">>" : src[i + 1] === "|" ? ">|" : ">";
      expect = { kind: "redir", op, fd };
      i += op.length;
      continue;
    }

    startWord();
    word.text += c;
    i++;
  }

  endCommand("");
  if (pending.length) { rej("unterminated heredoc"); pending.length = 0; }
  if (needCommand) rej("command missing after an operator");
  return out;
}

/** A simple command's words after quote removal, leading assignments skipped. */
function argvOf(c) {
  let j = 0;
  while (j < c.words.length && ASSIGN_RE.test(c.words[j].raw)) j++;
  return c.words.slice(j).map((w) => w.text);
}

const HERDR = new Map([
  ["pane", ["send-text", "send-keys", "run", "close"]],
  ["tab", ["create", "rename", "close"]],
  ["workspace", ["create", "rename", "close"]],
]);
const GH = new Map([
  ["pr", ["create", "merge", "edit", "comment"]],
  ["issue", ["create", "edit", "comment"]],
]);
const GH_API_VALUE_FLAGS = new Set([
  "-X", "--method", "-f", "--raw-field", "-F", "--field", "-H", "--header", "-q", "--jq",
  "-t", "--template", "--input", "--hostname", "--cache", "-p", "--preview",
]);
const GH_API_BOOL_FLAGS = new Set(["--paginate", "--slurp", "-i", "--include", "--silent", "--verbose"]);

function gitBranchAction(rest) {
  const opts = rest.filter((x) => x.startsWith("-"));
  const names = rest.filter((x) => !x.startsWith("-"));
  if (!names.length) return false;
  if (!opts.length) return names.length <= 2;
  return opts.every((o) => o === "-d" || o === "-D" || o === "--delete");
}

function gitAction(a) {
  let k = 1;
  while (a[k] === "-C" || a[k] === "-c") k += 2;
  const sub = a[k];
  const rest = a.slice(k + 1);
  switch (sub) {
    case "commit":
    case "push":
    case "pull":
    case "fetch":
    case "add":
      return true;
    case "worktree":
      return rest[0] === "add" || rest[0] === "remove";
    case "remote":
      return rest[0] === "set-url";
    case "branch":
      return gitBranchAction(rest);
    default:
      return false;
  }
}

// A GraphQL call is always a POST and is a query, so it is never an action.
function ghApiWrite(args) {
  let method = "";
  let endpoint = null;
  for (let k = 0; k < args.length; k++) {
    const x = args[k];
    if (x === "-X" || x === "--method") { method = args[++k] ?? ""; continue; }
    if (x.startsWith("--method=")) { method = x.slice(9); continue; }
    if (/^-X./.test(x)) { method = x.slice(2); continue; }
    if (GH_API_VALUE_FLAGS.has(x)) { k++; continue; }
    if (x.startsWith("--") && x.includes("=")) {
      if (!GH_API_VALUE_FLAGS.has(x.slice(0, x.indexOf("=")))) return false;
      continue;
    }
    if (GH_API_BOOL_FLAGS.has(x)) continue;
    if (x.startsWith("-")) return false;
    if (endpoint !== null) return false;
    endpoint = x;
  }
  if (endpoint === null || /^\/?graphql$/i.test(endpoint)) return false;
  return ["POST", "PUT", "PATCH", "DELETE"].includes(method.toUpperCase());
}

// `cat` with no operand other than `-`, reading only a heredoc or here-string.
function catWritesOwnInput(c) {
  const a = argvOf(c);
  return !c.input && a[0] === "cat" && (c.heredocs.length > 0 || c.herestrings > 0) &&
    a.slice(1).every((x) => x === "-" || (x.startsWith("-") && x !== "--"));
}

function isAction(c) {
  if (c.input) return false;
  const a = argvOf(c);
  switch (a[0]) {
    case "echo":
    case "printf":
    case "tee":
      return true;
    case "cat":
      return catWritesOwnInput(c);
    case "herdr":
      return (HERDR.get(a[1]) || []).includes(a[2]);
    case "git":
      return gitAction(a);
    case "gh":
      return a[1] === "api" ? ghApiWrite(a.slice(2)) : (GH.get(a[1]) || []).includes(a[2]);
    case "claude":
      return a[1] === "plugin" &&
        ((a[2] === "marketplace" && a[3] === "update") || a[2] === "update" || a[2] === "install");
    case "cd":
      return a.length === 2;
    case "sleep":
      return a.length === 2 && /^\d+(\.\d+)?$/.test(a[1]);
    default:
      return false;
  }
}

const GREP_LONG_FORBIDDEN = new Set([
  "--file", "--recursive", "--dereference-recursive", "--include", "--exclude", "--exclude-from",
  "--directories",
]);
const GREP_LONG_VALUE = new Set([
  "--regexp", "--max-count", "--after-context", "--before-context", "--context", "--label",
  "--binary-files", "--devices", "--exclude-dir", "--group-separator",
]);

// grep reading stdin only: one pattern (or only -e patterns), no file operand,
// no pattern file, no recursion. `-d` is refused too, since `-d recurse` is -r.
function grepFilter(args) {
  let operands = 0;
  let eGiven = false;
  for (let k = 0; k < args.length; k++) {
    const x = args[k];
    if (x === "--") { operands += args.length - k - 1; break; }
    if (x.startsWith("--")) {
      const name = x.includes("=") ? x.slice(0, x.indexOf("=")) : x;
      if (GREP_LONG_FORBIDDEN.has(name)) return false;
      if (name === "--regexp") eGiven = true;
      if (GREP_LONG_VALUE.has(name) && !x.includes("=")) k++;
      continue;
    }
    if (x.startsWith("-") && x.length > 1) {
      for (let m = 1; m < x.length; m++) {
        const ch = x[m];
        if ("frRd".includes(ch)) return false;
        if ("emABCD".includes(ch)) {
          if (ch === "e") eGiven = true;
          if (m === x.length - 1) k++;
          break;
        }
      }
      continue;
    }
    operands++;
  }
  return eGiven ? operands === 0 : operands === 1;
}

function headTailFilter(args) {
  for (let k = 0; k < args.length; k++) {
    const x = args[k];
    if ((x === "-n" || x === "-c") && /^\d+$/.test(args[k + 1] ?? "")) { k++; continue; }
    if (/^-\d+$/.test(x) || /^--lines=\d+$/.test(x)) continue;
    return false;
  }
  return true;
}

function isStdinFilter(c) {
  if (c.input || c.heredocs.length || c.herestrings) return false;
  const a = argvOf(c);
  if (a[0] === "grep") return grepFilter(a.slice(1));
  if (a[0] === "head" || a[0] === "tail") return headTailFilter(a.slice(1));
  return false;
}

function isPeek(pipeline) {
  const [first, ...rest] = pipeline;
  if (first.input) return false;
  const a = argvOf(first);
  if (a[0] !== "herdr" || a[1] !== "pane" || a[2] !== "read") return false;
  const lines = [];
  for (let k = 3; k < a.length; k++) {
    if (a[k] === "--lines") lines.push(a[++k] ?? "");
    else if (a[k].startsWith("--lines=")) lines.push(a[k].slice(8));
  }
  if (lines.length !== 1 || !/^[1-9][0-9]*$/.test(lines[0]) || Number(lines[0]) > 60) return false;
  return rest.every(isStdinFilter);
}

/** The command word after leading assignments and shell keywords, or "". */
function commandWord(c) {
  let j = 0;
  while (j < c.words.length && (ASSIGN_RE.test(c.words[j].raw) || KEYWORDS.has(c.words[j].text))) j++;
  return c.words[j] ? c.words[j].text : "";
}
const isShell = (c) => SHELLS.has(commandWord(c).split("/").pop());

/**
 * Every terminated heredoc in the command, in order: `at` is the index of its
 * `<<`, and [start, end) spans its body and terminator line. `data` is false
 * when a shell runs the body: its own command is a shell, or its command
 * pipes into one later in the same pipeline, since there the body lines are
 * commands. An unterminated heredoc is left out.
 */
export function heredocSpans(command) {
  if (typeof command !== "string") return [];
  const spans = [];
  for (const pipeline of lex(command).pipelines) {
    pipeline.forEach((c, idx) => {
      const data = !pipeline.slice(idx).some(isShell);
      for (const h of c.heredocs) if (h.found) spans.push({ at: h.at, start: h.start, end: h.end, data });
    });
  }
  return spans.sort((x, y) => x.start - y.start);
}

/**
 * True when `text` is one simple command, inside the accepted grammar, that
 * is a `cat` writing only its own heredoc or here-string. Anything that can't
 * be judged that way answers false.
 */
export function isHeredocWrite(text) {
  if (typeof text !== "string") return false;
  const lx = lex(text);
  if (lx.reject || lx.unbalanced || lx.pipelines.length !== 1 || lx.pipelines[0].length !== 1) return false;
  return catWritesOwnInput(lx.pipelines[0][0]);
}

export function isExempt(command) {
  if (typeof command !== "string") return false;
  const lx = lex(command);
  if (lx.reject || lx.unbalanced || !lx.pipelines.length) return false;
  let peeks = 0;
  for (const pipeline of lx.pipelines) {
    if (isPeek(pipeline)) {
      if (++peeks > 1) return false;
      continue;
    }
    if (!pipeline.every(isAction)) return false;
  }
  return true;
}

export function nestedLookup(command, isLookup, depth = 0) {
  if (typeof command !== "string") return false;
  if (depth > MAX_DEPTH) return true;
  const lx = lex(command);
  if (lx.unbalanced) return true;
  const judge = (text) => isLookup(text) || nestedLookup(text, isLookup, depth + 1);
  if (lx.substs.some(judge)) return true;
  for (const pipeline of lx.pipelines) {
    for (const c of pipeline) {
      let j = 0;
      while (j < c.words.length && (ASSIGN_RE.test(c.words[j].raw) || KEYWORDS.has(c.words[j].text))) j++;
      const a = c.words.slice(j).map((w) => w.text);
      if (!a.length) continue;
      if (SHELLS.has(a[0].split("/").pop())) {
        const flag = a.findIndex((x, k) => k > 0 && /^-[A-Za-z]*c$/.test(x));
        if (flag > 0 && flag + 1 < a.length && judge(a[flag + 1])) return true;
      } else if (a[0] === "eval" && a.length > 1 && judge(a.slice(1).join(" "))) {
        return true;
      }
    }
  }
  return false;
}

const MAX_LINES = 60;
const nonFlags = (args) => args.filter((x) => !x.startsWith("-"));

// One sed command that only prints, deletes or substitutes: no r/w/e, no w or e substitution flag.
const SAFE_SED = /^(?:(?:\d+|\$|\/[^/]*\/)(?:,(?:\d+|\$|\/[^/]*\/))?[pd]|s(.)(?:(?!\1).)*\1(?:(?!\1).)*\1[gpiI0-9]*)$/;

/**
 * A read-only filter of its own stdin: no file operand, no recursion, nothing that
 * runs a command or touches a file (awk system/getline, sed r/w/e or -i).
 */
function isFilter(c) {
  if (c.input || c.heredocs.length || c.herestrings) return false;
  const [w, ...args] = argvOf(c);
  switch (w) {
    case "grep": {
      const g = grepArgs(args);
      return !g.recursive && !g.patternFile && g.files.length === 0;
    }
    case "head":
    case "tail":
      return headTailFilter(args);
    case "wc":
    case "sort":
    case "uniq":
    case "column":
      return nonFlags(args).length === 0 && !args.some((x) => x === "-o" || x.startsWith("--output") || x.startsWith("--files0-from"));
    case "cut":
      return nonFlags(args).length === 0;
    case "tr":
      return nonFlags(args).length <= 2;
    case "jq":
      return nonFlags(args).length <= 1 && args.every((x) => !x.startsWith("-") || /^-[rcSejn]+$/.test(x));
    case "awk": {
      if (args.some((x) => x.startsWith("-"))) return false;
      return args.length === 1 && !/\b(system|getline)\b|[|>]/.test(args[0]);
    }
    case "sed": {
      const script = nonFlags(args);
      return script.length === 1 && args.every((x) => !x.startsWith("-") || /^-[nEr]+$/.test(x)) && SAFE_SED.test(script[0]);
    }
    default:
      return false;
  }
}

// Format flags that keep `git log`/`git show` output small; anything else makes the call ordinary.
const GIT_FORMAT_FLAG = /^(--oneline|--stat|--format=.*|--pretty=.*|--max-count=\d+|-n\d+|-\d+)$/;

/** `git log` naming a compact format and a count of at most MAX_LINES commits, with only allow-listed flags. */
function smallGitLog(rest) {
  let count = Infinity;
  let compact = false;
  for (let k = 0; k < rest.length; k++) {
    const x = rest[k];
    if (x === "-n" && /^\d+$/.test(rest[k + 1] ?? "")) { count = Number(rest[++k]); continue; }
    if (!x.startsWith("-")) continue;
    if (!GIT_FORMAT_FLAG.test(x) || x === "--stat") return false;
    const m = /^(?:--max-count=|-n|-)(\d+)$/.exec(x);
    if (m) count = Number(m[1]);
    else compact = true;
  }
  return compact && count <= MAX_LINES;
}

function smallGit(a) {
  let k = 1;
  while (a[k] === "-C") k += 2;
  if (a[k] === "-c" || (a[k] || "").startsWith("-")) return false;
  const [sub, ...rest] = a.slice(k);
  switch (sub) {
    case "status":
    case "rev-parse":
    case "merge-base":
      return true;
    case "branch":
      return rest.length === 1 && rest[0] === "--show-current";
    case "worktree":
      return rest[0] === "list";
    case "show":
      return rest.includes("--stat") && rest.every((x) => !x.startsWith("-") || GIT_FORMAT_FLAG.test(x));
    case "log":
      return smallGitLog(rest);
    default:
      return false;
  }
}

// `herdr pane read` stays under isExempt's capped peek: a whole pane is real output.
function isCoordination(c) {
  const a = argvOf(c);
  const w = a[0] || "";
  if (w === "ah" || w.endsWith("/bin/ah")) return true;
  if (w === "herdr") return !(a[1] === "pane" && a[2] === "read");
  if (SHELLS.has(w.split("/").pop())) return (a[1] || "").endsWith(".claude/ah2-ops/ship.sh");
  return w === "git" && smallGit(a);
}

/** grep's flags and file operands. */
function grepArgs(args) {
  let count = false;
  let recursive = false;
  let invert = false;
  let patternFile = false;
  const patterns = [];
  const operands = [];
  for (let k = 0; k < args.length; k++) {
    const x = args[k];
    if (x === "--") { operands.push(...args.slice(k + 1)); break; }
    if (x.startsWith("--")) {
      const name = x.includes("=") ? x.slice(0, x.indexOf("=")) : x;
      if (name === "--count") count = true;
      if (name === "--invert-match") invert = true;
      if (name === "--recursive" || name === "--dereference-recursive" || name === "--directories") recursive = true;
      if (name === "--file") patternFile = true;
      if (name === "--regexp") patterns.push(x.includes("=") ? x.slice(x.indexOf("=") + 1) : args[k + 1] ?? "");
      if ((GREP_LONG_VALUE.has(name) || name === "--file" || name === "--directories") && !x.includes("=")) k++;
      continue;
    }
    if (x.startsWith("-") && x.length > 1) {
      for (let m = 1; m < x.length; m++) {
        const ch = x[m];
        if (ch === "c") count = true;
        if (ch === "v") invert = true;
        if ("rRd".includes(ch)) recursive = true;
        if ("efmdABCD".includes(ch)) {
          const value = m === x.length - 1 ? args[++k] ?? "" : x.slice(m + 1);
          if (ch === "e") patterns.push(value);
          if (ch === "f") patternFile = true;
          break;
        }
      }
      continue;
    }
    operands.push(x);
  }
  if (!patterns.length && !patternFile) patterns.push(operands.shift() ?? "");
  return { count, recursive, invert, patternFile, patterns, files: operands };
}

/** head/tail trimming its stdin to at most MAX_LINES lines; a file operand makes it a reader. */
function boundedHeadTail(args) {
  let n = 10;
  for (let k = 0; k < args.length; k++) {
    const x = args[k];
    let m;
    if (x === "-n" && /^\d+$/.test(args[k + 1] ?? "")) { n = Number(args[++k]); continue; }
    if ((m = /^-n?(\d+)$/.exec(x) || /^--lines=(\d+)$/.exec(x))) { n = Number(m[1]); continue; }
    return false;
  }
  return n <= MAX_LINES;
}

/** The stage's output is a count or a capped number of lines. */
function boundsOutput(c) {
  const a = argvOf(c);
  if (a[0] === "wc") return true;
  if (a[0] === "head" || a[0] === "tail") return boundedHeadTail(a.slice(1));
  if (a[0] === "grep") {
    const g = grepArgs(a.slice(1));
    return g.count && !g.recursive;
  }
  return false;
}

const TERMINAL = "";
const toFile = (target) => (/^\/dev\/(stdout|stderr|tty|fd\/)/.test(target) ? TERMINAL : target);

/** Replays the command's redirections in order: true when stdout finally lands in a file. */
function stdoutToFile(c) {
  const fds = { 1: TERMINAL, 2: TERMINAL };
  for (const r of c.redirs) {
    const fd = r.fd || "1";
    if (r.op === "&>" || r.op === "&>>") fds[1] = fds[2] = toFile(r.target);
    else if (r.op === ">&") fds[fd] = fds[r.target] ?? TERMINAL;
    else if (r.op === ">" || r.op === ">>" || r.op === ">|") fds[fd] = toFile(r.target);
  }
  return fds[1] !== TERMINAL;
}

/** Files this command truncates and writes, which a later grep in it may read as its own log. */
const writtenBy = (c) => c.redirs.filter((r) => (r.op === ">" || r.op === ">|") && toFile(r.target)).map((r) => r.target);

/** A path a log lives at: a temp dir, a scratchpad, or a file this same command wrote. */
function isLogPath(f, written) {
  if (written.has(f)) return true;
  if (f.includes("..")) return false;
  const roots = ["/tmp/", "/private/tmp/", "$TMPDIR/", "${TMPDIR}/"];
  const tmp = process.env.TMPDIR || "";
  if (tmp.length > 1) roots.push(tmp.endsWith("/") ? tmp : tmp + "/");
  return roots.some((r) => f.startsWith(r)) || f.includes("/scratchpad/");
}

function isLogGrep(c, written) {
  const a = argvOf(c);
  if (a[0] !== "grep" || c.input) return false;
  const g = grepArgs(a.slice(1));
  // A pattern that matches every line, or -v, turns the grep into a cat of the log.
  const selective = !g.invert && !g.patternFile && g.patterns.every((p) => !/^\^?(\.\*?)?\$?$/.test(p));
  return selective && !g.recursive && g.files.length > 0 && g.files.every((f) => isLogPath(f, written));
}

function lightPipeline(p, written, isLookup, isRun) {
  const [first, ...rest] = p;
  const last = p[p.length - 1];
  const text = p.map((c) => c.words.map((w) => w.raw).join(" ")).join(" | ");
  if (isCoordination(first) && rest.every(isFilter)) return true;
  // A test or build run costs its runtime whatever it prints, so capping its output does not make it light.
  if (!isRun(text) && (boundsOutput(last) || stdoutToFile(last))) return true;
  if (isLogGrep(first, written) && rest.every(isFilter)) return true;
  if (p.length === 1 && isAction(first)) return true;
  return !isLookup(text) && !nestedLookup(text, isLookup);
}

/**
 * True when no part of the command is legwork: each pipeline coordinates
 * agents (ah, herdr, ship.sh), asks git a small question (status, rev-parse,
 * a counted log...), bounds its own output (a final head/tail of at most 60
 * lines, wc, grep -c, or stdout sent to a file), greps a log in a temp dir,
 * a scratchpad, or a file the command itself wrote, or is not a lookup at all
 * by `isLookup`. `isRun` names test and build runs, which stay legwork however
 * their output is capped. Anything outside the lexer's grammar, or a heredoc a
 * shell runs, answers false.
 */
export function isLight(command, isLookup, isRun = () => false) {
  if (typeof command !== "string") return false;
  const lx = lex(command);
  if (lx.reject || lx.unbalanced || !lx.pipelines.length) return false;
  if (heredocSpans(command).some((h) => !h.data)) return false;
  const written = new Set();
  return lx.pipelines.every((p) => {
    const ok = lightPipeline(p, written, isLookup, isRun);
    for (const c of p) for (const f of writtenBy(c)) written.add(f);
    return ok;
  });
}
