/**
 * agent-hierarchy — the one place a terminal multiplexer binary (herdr, tmux) is executed, and the guard for the
 * shell strings that launch a member.
 *
 * Outside the test suite this is exactly `execFileSync` and `/bin/sh -c`. A test file sets AH_TEST_HERMETIC=1
 * (tests/lib-hermetic.sh), and then one of the GUARDED_BINARIES is only run when it resolves, on the PATH the call
 * would use, to a file inside one of the directories the test lists in AH_TEST_FAKE_BIN. A binary that resolves
 * anywhere else is the user's real herdr, tmux, claude or codex: the call is recorded in AH_TEST_TRIPWIRE, reported
 * on stderr, the test process (AH_TEST_PID) is sent SIGTERM, and the call throws without running anything. A binary
 * that is on no PATH entry at all fails as it always did.
 */

import { execFileSync } from "node:child_process";
import { accessSync, appendFileSync, constants, realpathSync, statSync } from "node:fs";
import { basename, delimiter, join, sep } from "node:path";

/** Binaries a test must never reach for real. One list, used by `muxExec` and `guardShellCommand`. */
export const GUARDED_BINARIES = ["herdr", "tmux", "claude", "codex"];

function resolveOnPath(binary, pathVar) {
  if (binary.includes("/")) {
    try {
      if (!statSync(binary).isFile()) return null;
      accessSync(binary, constants.X_OK);
      return binary;
    } catch {
      return null;
    }
  }
  for (const dir of String(pathVar || "").split(delimiter)) {
    if (!dir) continue;
    const candidate = join(dir, binary);
    try {
      if (!statSync(candidate).isFile()) continue;
      accessSync(candidate, constants.X_OK);
      return candidate;
    } catch {
      // not here
    }
  }
  return null;
}

function listedDirs() {
  const dirs = [];
  for (const d of String(process.env.AH_TEST_FAKE_BIN || "").split(":")) {
    if (!d) continue;
    try {
      dirs.push(realpathSync(d));
    } catch {
      // a listed directory that does not exist lists nothing
    }
  }
  return dirs;
}

function tripwire(binaryPath, args) {
  const binary = basename(binaryPath);
  const line = `${binary} ${args.join(" ")} pid=${process.pid}`;
  try {
    if (process.env.AH_TEST_TRIPWIRE) appendFileSync(process.env.AH_TEST_TRIPWIRE, line + "\n");
  } catch {
    // the stderr line and the kill below still happen
  }
  const message = `ah: test hermeticity: a test reached the real ${binary} (${args.join(" ")}). Put a fake in a directory listed in AH_TEST_FAKE_BIN.`;
  try {
    process.stderr.write(message + "\n");
  } catch {
    // closed stderr
  }
  const pid = Number(process.env.AH_TEST_PID);
  if (Number.isInteger(pid) && pid > 0) {
    try {
      process.kill(pid, "SIGTERM");
    } catch {
      // the test file is already gone
    }
  }
  throw new Error(message);
}

function guard(binary, args, options) {
  if (!GUARDED_BINARIES.includes(basename(binary))) return;
  const pathVar = options && options.env && options.env.PATH !== undefined ? options.env.PATH : process.env.PATH;
  const found = resolveOnPath(binary, pathVar);
  if (!found) return;
  let real;
  try {
    real = realpathSync(found);
  } catch {
    real = found;
  }
  if (listedDirs().some((d) => real === d || real.startsWith(d + sep))) return;
  tripwire(binary, args);
}

/** Run a multiplexer binary. Same signature and result as `execFileSync(binary, args, options)`. */
export function muxExec(binary, args, options) {
  if (process.env.AH_TEST_HERMETIC === "1") guard(binary, args, options);
  return execFileSync(binary, args, options);
}

/** Split a shell string into simple commands (at unquoted `;`, `&`, `&&`, `|`, `||` and newlines), each a list of words. */
function simpleCommands(text) {
  const commands = [];
  let words = [];
  let word = "";
  let inWord = false;
  let quote = null;
  const endWord = () => {
    if (inWord) words.push(word);
    word = "";
    inWord = false;
  };
  const endCommand = () => {
    endWord();
    if (words.length) commands.push(words);
    words = [];
  };
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (quote) {
      if (c === quote) quote = null;
      else if (c === "\\" && quote === '"' && i + 1 < text.length) word += text[++i];
      else word += c;
    } else if (c === "'" || c === '"') {
      quote = c;
      inWord = true;
    } else if (c === "\\" && i + 1 < text.length) {
      word += text[++i];
      inWord = true;
    } else if (c === ";" || c === "\n" || c === "|" || c === "&") {
      endCommand();
      if ((c === "|" || c === "&") && text[i + 1] === c) i++;
    } else if (/\s/.test(c)) {
      endWord();
    } else {
      word += c;
      inWord = true;
    }
  }
  endCommand();
  return commands;
}

/** Index of the command-position word of one simple command: after leading VAR=value words and an optional exec, env or command. */
function commandPosition(words) {
  const assignment = /^[A-Za-z_][A-Za-z0-9_]*=/;
  let i = 0;
  while (i < words.length) {
    const w = words[i];
    if (assignment.test(w) || w === "exec" || w === "command") i++;
    else if (w === "env") {
      i++;
      while (i < words.length && (assignment.test(words[i]) || words[i].startsWith("-"))) i += words[i] === "-u" ? 2 : 1;
    } else break;
  }
  return i < words.length ? i : -1;
}

/**
 * Guard a shell command string the product is about to run (`runShell`, which launches a member). In a test, each
 * simple command whose command-position word is a guarded binary gets the same check as `muxExec`. Words in argument
 * position (`--kind claude`) are never checked, and `$(…)` and backticks are not parsed. Outside a test: nothing.
 */
export function guardShellCommand(commandString, env) {
  if (process.env.AH_TEST_HERMETIC !== "1") return;
  for (const words of simpleCommands(String(commandString))) {
    const at = commandPosition(words);
    if (at < 0 || !GUARDED_BINARIES.includes(basename(words[at]))) continue;
    guard(words[at], words.slice(at + 1), { env });
  }
}
