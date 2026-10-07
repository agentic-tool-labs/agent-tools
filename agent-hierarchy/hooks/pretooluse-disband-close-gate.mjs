#!/usr/bin/env node
/**
 * agent-hierarchy — PreToolUse gate for `roster.mjs disband --close` (spec 0016 §4.5.1) and
 * `roster.mjs dismiss <name> --close` (spec 0020 §4.1) — whole-team close and single-member close,
 * the only two operations that execute `herdr pane close`/`tmux kill-pane`.
 *
 * Keyed on the PARSED Bash command (spec 0048 §2.4.2), not on a tool name: the ah CLIs are
 * invoked through the Bash tool now. `--close` presence is the mode — a plan call (no `--close`)
 * destroys nothing and is not gated. The matcher in hooks.json is `Bash`, so this hook sees every
 * Bash call and decides for itself; the gated verb set lives here alone, and
 * tests/check-gate-name-agreement.mjs asserts it against hooks.json's matcher.
 * Always asks: no caching, no allowlist, no "don't ask again" — closing live sessions is exactly
 * the operation that should re-prompt every time. pretooluse-ah-cli.mjs deliberately stays silent
 * on close commands so this `ask` is the only decision in play.
 *
 * Enriches the prompt with the live member list via `readTeam` when it can; if that read fails
 * for any reason, it still asks, with a generic message — never skips the prompt because
 * enrichment failed.
 */

import { askDecision, logHookError, readHookInput } from "./lib-config.mjs";
import { hierarchyDir } from "./lib-hier.mjs";
import { DEFAULT_TEAM_ARG, readTeam } from "./lib-roster.mjs";
import { isCloseCommand, parseAhCommand } from "./lib-ah-cli.mjs";

function ask(reason) {
  const d = askDecision(reason);
  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: d.decision,
        permissionDecisionReason: d.reason,
      },
    })
  );
  process.exit(0);
}

/**
 * The parser reads only a command that begins `node <abs>/roster.mjs`. A `cd … &&` or env prefix,
 * a relative script path, a `;` chain, `sh -c "…"`, a backslash continuation, a runtime option
 * (`node --no-warnings`) or another runtime (`bun`, `tsx`, `deno run -A`) is a shape it cannot read,
 * and the close would then run unasked. Such a command is scanned here, as command text only.
 *
 * Excluded from the scan: heredoc bodies, quoted text and comments, since text that merely mentions
 * `node roster.mjs disband --close` (a message being written, a commit message, an echo) runs nothing.
 * Scanned all the same, because they are code: a heredoc whose command is a shell (or feeds one, or is a
 * runtime reading its program from stdin), the argument of `sh -c`, the arguments of `eval`, and
 * `$( )` and backtick spans, also inside double quotes. A close is a runtime word followed by a
 * `roster.mjs` word — past any number of `-` options and at most two other words (`run`, an option's
 * value) — and, after it, a `dismiss`/`disband` word and a `--close` word, all in one simple command
 * (simple commands end at `;`, `&`, `|`, a newline, a parenthesis or a brace). Text the scanner cannot
 * classify (an unterminated quote or heredoc, nesting deeper than three levels) counts as a close.
 *
 * Known misses, accepted: `xargs`, `env -S`, a function defined earlier in the same command and `$VAR`
 * expansion. This gate is a confirmation step, not the security boundary: a close still needs a valid
 * plan token, and in a member session a close is denied.
 */
const RUNTIME_WORD = /^["']?(.*\/)?(node|nodejs|bun|deno|tsx)$/;
const SHELL_WORDS = new Set(["sh", "bash", "zsh", "dash", "ksh", "fish", "source", "."]);
const MAX_NESTING = 3;
/** Commands that run the command after them: a shell or `eval` behind one of these is still a shell or `eval`. */
const WRAPPERS = new Set(["env", "timeout", "sudo", "doas", "nohup", "command", "exec", "nice", "ionice", "time", "builtin", "stdbuf", "setsid"]);
const baseOf = (w) => w.text.replace(/^.*\//, "");
class Unclassified extends Error {}

/** The index of the word that is the command proper: past `VAR=x` assignments and wrapper words (with their options). */
function headIndex(words) {
  let i = 0;
  while (i < words.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(words[i].text)) i++;
  if (i < words.length && WRAPPERS.has(baseOf(words[i]))) {
    for (let j = i + 1; j < Math.min(words.length, i + 9); j++) {
      if (SHELL_WORDS.has(baseOf(words[j])) || baseOf(words[j]) === "eval" || RUNTIME_WORD.test(words[j].text)) return j;
    }
  }
  return i;
}

/** Whether a command in this group hands its standard input to a shell, or to a runtime reading its program from stdin. */
const readsStdinAsCode = (members) =>
  members.some((x) => {
    const k = headIndex(x.words);
    const head = x.words[k];
    return Boolean(head) && (SHELL_WORDS.has(baseOf(head)) || (RUNTIME_WORD.test(head.text) && x.words.slice(k + 1).every((w) => w.text.startsWith("-"))));
  });

/** The simple commands in `text`, each as `{ words: [{ text, raws }], group }`; words of one pipeline share a group. */
function commandsOf(text, depth) {
  if (depth > MAX_NESTING) throw new Unclassified("nested too deep");
  const src = text.replace(/\\\n/g, " ");
  const cmds = [];
  const pending = [];
  const hereStrings = [];
  let group = 0;
  // Commands found inside a nested span ($( ), a backtick, -c, eval, a heredoc body) get ids of their own, so a
  // pipeline's group id never moves on account of them.
  let nested = 0;
  const nestedId = () => --nested;
  let cur = { words: [], group };
  let buf = "";
  let raws = [];
  let hasWord = false;
  const endWord = () => {
    if (hasWord) cur.words.push({ text: buf, raws });
    buf = "";
    raws = [];
    hasWord = false;
  };
  const endCmd = (newGroup) => {
    endWord();
    if (cur.words.length) cmds.push(cur);
    if (newGroup) group++;
    cur = { words: [], group };
  };
  // A quoted piece joins the word's text only when it is one plain token, so a message with spaces never does.
  const piece = (raw) => {
    raws.push(raw);
    if (/^[^\s;&|()<>`'"\\]+$/.test(raw)) buf += raw;
    hasWord = true;
  };
  const closeParen = (from) => {
    for (let d = 1, k = from; k < src.length; k++) {
      if (src[k] === "\\") k++;
      else if (src[k] === "(") d++;
      else if (src[k] === ")" && --d === 0) return k;
    }
    throw new Unclassified("unterminated $(");
  };
  for (let i = 0; i < src.length; i++) {
    const c = src[i];
    if (c === "\\") {
      if (i + 1 < src.length) { buf += src[++i]; hasWord = true; }
    } else if (c === "'") {
      const e = src.indexOf("'", i + 1);
      if (e < 0) throw new Unclassified("unterminated quote");
      piece(src.slice(i + 1, e));
      i = e;
    } else if (c === '"') {
      let raw = "";
      let k = i + 1;
      for (; k < src.length && src[k] !== '"'; k++) {
        if (src[k] === "\\" && k + 1 < src.length) {
          k++;
          raw += /[\\"$`]/.test(src[k]) ? src[k] : "\\" + src[k];
        } else if (src[k] === "$" && src[k + 1] === "(") {
          const e = closeParen(k + 2);
          for (const inner of commandsOf(src.slice(k + 2, e), depth + 1)) cmds.push({ words: inner.words, group: nestedId() });
          raw += src.slice(k, e + 1);
          k = e;
        } else if (src[k] === "`") {
          const e = src.indexOf("`", k + 1);
          if (e < 0) throw new Unclassified("unterminated backtick");
          for (const inner of commandsOf(src.slice(k + 1, e), depth + 1)) cmds.push({ words: inner.words, group: nestedId() });
          raw += src.slice(k, e + 1);
          k = e;
        } else raw += src[k];
      }
      if (k >= src.length) throw new Unclassified("unterminated quote");
      piece(raw);
      i = k;
    } else if (c === "#" && !hasWord && (i === 0 || /[\s;&|()]/.test(src[i - 1]))) {
      while (i + 1 < src.length && src[i + 1] !== "\n") i++;
    } else if (c === " " || c === "\t" || c === "\r") {
      endWord();
    } else if (c === "\n") {
      endCmd(true);
      for (const h of pending.splice(0)) {
        const lines = [];
        let closed = false;
        let at = i + 1;
        while (at <= src.length && !closed) {
          const eol = src.indexOf("\n", at);
          const line = src.slice(at, eol < 0 ? src.length : eol);
          if ((h.strip ? line.replace(/^\t+/, "") : line) === h.delim) closed = true;
          else lines.push(line);
          if (eol < 0) { at = src.length + 1; break; }
          at = eol + 1;
        }
        if (!closed) throw new Unclassified("unterminated heredoc");
        i = at - 1;
        const reads = readsStdinAsCode(cmds.filter((x) => x.group === h.group));
        if (reads) for (const inner of commandsOf(lines.join("\n"), depth)) cmds.push({ words: inner.words, group: nestedId() });
      }
    } else if (c === "<" || c === ">") {
      if (c === "<" && src[i + 1] === "<" && src[i + 2] === "<") {
        // A here-string: the word after it is the command's standard input.
        endWord();
        i += 3;
        while (src[i] === " " || src[i] === "\t") i++;
        let raw = "";
        if (src[i] === "'" || src[i] === '"') {
          const q = src[i];
          let k = i + 1;
          for (; k < src.length && src[k] !== q; k++) {
            if (q === '"' && src[k] === "\\" && k + 1 < src.length) { k++; raw += /[\\"$`]/.test(src[k]) ? src[k] : "\\" + src[k]; } else raw += src[k];
          }
          if (k >= src.length) throw new Unclassified("unterminated here-string");
          i = k;
        } else {
          while (i < src.length && !/[\s;&|()<>]/.test(src[i])) raw += src[i++];
          i--;
        }
        hereStrings.push({ raw, group: cur.group });
      } else if (c === "<" && src[i + 1] === "<") {
        endWord();
        i += 2;
        const strip = src[i] === "-";
        if (strip) i++;
        while (src[i] === " " || src[i] === "\t") i++;
        let delim = "";
        if (src[i] === "'" || src[i] === '"') {
          const e = src.indexOf(src[i], i + 1);
          if (e < 0) throw new Unclassified("unterminated heredoc word");
          delim = src.slice(i + 1, e);
          i = e;
        } else {
          while (i < src.length && !/[\s;&|()<>]/.test(src[i])) delim += src[i++];
          i--;
        }
        if (!delim) throw new Unclassified("heredoc without a word");
        pending.push({ delim, strip, group: cur.group });
      } else endWord();
    } else if (c === ";" || c === "(" || c === ")" || c === "`") {
      endCmd(true);
    } else if ((c === "{" || c === "}") && !hasWord && (i + 1 >= src.length || /[\s;&|()<>]/.test(src[i + 1]))) {
      // A brace group's `{` and `}` stand alone; inside a word (`${VAR}`, `a{b,c}`) they are part of it.
      endCmd(true);
    } else if (c === "&") {
      // `2>&1`, `>&2` and `&>` are redirections and `|&` is a pipe, not the end of a command.
      if (src[i - 1] === ">" || src[i - 1] === "<" || src[i - 1] === "|" || src[i + 1] === ">") continue;
      if (src[i + 1] === "&") i++;
      endCmd(true);
    } else if (c === "|") {
      if (src[i + 1] === "|") { i++; endCmd(true); } else endCmd(false);
    } else {
      buf += c;
      hasWord = true;
    }
  }
  endCmd(true);
  if (pending.length) throw new Unclassified("heredoc without a body");
  for (const hs of hereStrings) {
    if (readsStdinAsCode(cmds.filter((x) => x.group === hs.group))) for (const inner of commandsOf(hs.raw, depth + 1)) cmds.push({ words: inner.words, group: nestedId() });
  }
  // The argument of `sh -c` and the arguments of `eval` are code, so their quoted text is scanned.
  for (const cmd of [...cmds]) {
    const w = cmd.words;
    const at = headIndex(w);
    if (!w[at]) continue;
    const head = baseOf(w[at]);
    const code = [];
    if (SHELL_WORDS.has(head)) {
      for (let k = at + 1; k + 1 < w.length; k++) if (/^-[A-Za-z]*c[A-Za-z]*$/.test(w[k].text)) code.push(...w[k + 1].raws);
    } else if (head === "eval") for (const word of w.slice(at + 1)) code.push(...word.raws);
    for (const raw of code) for (const inner of commandsOf(raw, depth + 1)) cmds.push({ words: inner.words, group: nestedId() });
  }
  return cmds;
}

function isCloseWords(words) {
  const texts = words.map((w) => w.text);
  let at = -1;
  for (let i = 0; i < texts.length && at < 0; i++) {
    if (!RUNTIME_WORD.test(texts[i])) continue;
    for (let j = i + 1, other = 0; j < texts.length; j++) {
      if (/(^|\/)roster\.mjs["']?$/.test(texts[j])) { at = j; break; }
      if (!texts[j].startsWith("-") && ++other > 2) break;
    }
  }
  if (at < 0) return false;
  // Past the roster script, a quoted argument is the CLI's own argument, so its words count.
  const rest = words.slice(at + 1).flatMap((w) => [w.text, ...w.raws.flatMap((r) => r.split(/\s+/))]);
  return rest.some((w) => w === "dismiss" || w === "disband") && rest.includes("--close");
}

function unparsedClose(command) {
  if (typeof command !== "string" || !command.includes("roster.mjs") || !command.includes("--close")) return false;
  try {
    return commandsOf(command, 0).some((cmd) => isCloseWords(cmd.words));
  } catch {
    return true;
  }
}

let recognised = false;
try {
  const input = await readHookInput();
  if (input.tool_name !== "Bash") process.exit(0);
  const toolInput = input.tool_input && typeof input.tool_input === "object" ? input.tool_input : {};
  const parsed = parseAhCommand(toolInput.command);
  if (!parsed && unparsedClose(toolInput.command)) {
    recognised = true;
    ask("ah: close the live sessions of this Team? This is destructive and cannot be undone from here.");
  }
  if (!isCloseCommand(parsed)) process.exit(0);
  recognised = true;

  const singleMemberName = parsed.verb === "dismiss" && typeof parsed.positional[0] === "string" ? parsed.positional[0] : null;
  let names = singleMemberName;
  if (!names) {
    try {
      const cwd = typeof parsed.flags.cwd === "string" && parsed.flags.cwd ? parsed.flags.cwd : null;
      if (cwd) {
        // `--team @default` is the default team, team.json.
        const flag = typeof parsed.flags.team === "string" ? parsed.flags.team : null;
        const team = readTeam(hierarchyDir(cwd), flag === DEFAULT_TEAM_ARG ? null : flag);
        if (team && Array.isArray(team.members)) names = team.members.map((m) => m.name).filter(Boolean).join(", ") || null;
      }
    } catch {
      names = null;
    }
  }
  ask(
    names
      ? `ah: close the live session(s) of team member(s) ${names}? This is destructive and cannot be undone from here.`
      : "ah: close the live sessions of this Team? This is destructive and cannot be undone from here."
  );
} catch (err) {
  logHookError("pretooluse-disband-close-gate.mjs", err);
  // Once the command is known to be a close command, any later throw still fails closed with the
  // generic prompt rather than letting a destructive call through unprompted (0016 §4.5.1,
  // 0020 §4.1). Before that point the hook cannot know the call is ah's at all — the matcher is
  // now every Bash call — so it stays out of the way.
  if (recognised) ask("ah: close the live sessions of this Team? This is destructive and cannot be undone from here.");
  process.exit(0);
}
