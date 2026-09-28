/**
 * task-gopher — destructive-action guard.
 *
 * Covers BOTH bundled runners, task-gopher and smart-gopher, identically. For
 * task-gopher — a Haiku runner with no Edit or Write tool — `Bash` is the only
 * channel through which it can destroy anything, and it is also, by design,
 * the agent LEAST equipped to judge whether destroying something is correct:
 * the whole contract is "execute the order, make no decisions". An order that
 * merely fails is the dangerous case — the runner reaches for a bigger hammer
 * to make it succeed, and `git worktree remove` becomes
 * `git worktree remove --force`.
 *
 * smart-gopher CAN reason, but reasoning ability is not authority over an
 * irreversible or outward-facing action — that risk is still not the runner's
 * to accept on someone's behalf, so the same guard applies to it unchanged.
 * Note smart-gopher also has `Edit`/`Write`, which this guard does NOT cover —
 * `hooks.json`'s PreToolUse matcher is `Read|Grep|Glob|Bash|Agent|Task`, so an
 * Edit/Write call never reaches this hook at all. That gap is accepted for v1
 * (see the smart-gopher spec §11); it means a tracked file can be overwritten
 * or truncated with no guard involvement, though `git reset --hard` /
 * `git checkout --` — the recovery path's own undo — are still guarded.
 *
 * So the guard is mechanical rather than advisory: a stage of a Bash command
 * that destroys local state, or that leaves this machine (push, publish, PR,
 * write-request), is DENIED when the caller is task-gopher or smart-gopher,
 * whatever the prompt talked it into.
 *
 * AUTHORIZATION. The lead can pre-authorize a specific command by putting a
 * marker line in the dispatch prompt:
 *
 *     ALLOW-DESTRUCTIVE: rm -rf /abs/path/node_modules
 *
 * The relay hook reads those lines when the dispatch goes out and records them
 * against the session; a denied stage is released only if it matches one
 * VERBATIM (whitespace-normalized). That keeps a legitimate `rm -rf
 * node_modules && npm install` delegable while forcing the expensive reasoner —
 * the only agent in the chain qualified to — to name the destructive command
 * itself.
 *
 * FALSE POSITIVES ARE THE REAL DESIGN CONSTRAINT. A guard that blocks ordinary
 * legwork gets switched off, and then it guards nothing. So bare utility names
 * (`rm`, `truncate`, `shred`, `dd`) match only at COMMAND POSITION — otherwise
 * `grep -rn truncate src/` reads as a destructive command — and quoted spans are
 * masked before matching, because `rm -rf` inside a commit message is prose.
 *
 * HONEST LIMITS:
 * - Allowances are keyed by session, not by the individual runner (the child's
 *   agent_id does not exist yet when the dispatch is stamped). Two gophers in
 *   one session share the pool: authorizing a command for one authorizes it for
 *   any of them, for the rest of the session.
 * - Pattern matching is not a shell parser. Obfuscation defeats it (a variable
 *   holding the command, base64, a script file that does the deleting). This
 *   stops improvisation, not an adversary.
 * - Writing files via `cat > f <<EOF` is NOT gated. It is out of scope here —
 *   the runner producing files is an over-reach problem, not a destruction one.
 */

import { appendFileSync, existsSync, mkdirSync, readFileSync, realpathSync, renameSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { basename, dirname, join, resolve } from "node:path";
import { ALLOW_FILE } from "./directive.mjs";

/**
 * Command position: the head of a stage, past any env assignments and `sudo`.
 * Anchoring here is what separates running `rm` from merely mentioning it.
 */
const HEAD = String.raw`^\s*(?:[A-Za-z_][A-Za-z0-9_]*=\S*\s+)*(?:sudo\s+(?:-\S+\s+)*)?`;

/** `git`, plus the global flags that can sit between it and the subcommand. */
const GIT = HEAD + String.raw`git\s+(?:-[A-Za-z]\s*\S+\s+)*`;

const rule = (kind) => (body, label) => [new RegExp(body), label, kind];
const destructive = rule("destructive");
const outward = rule("outward");

/**
 * Irreversible local damage. `.*` is safe inside these because matching runs
 * per pipeline stage, so a pattern can never reach across a `;` or `&&`.
 */
const DESTRUCTIVE = [
  destructive(HEAD + String.raw`(?:git\s+)?rm\s+(?:-\S*[rfR]\S*|--force\b|--recursive\b)`, "forced or recursive rm"),
  destructive(HEAD + String.raw`(?:git\s+)?rm\s[^\n]*\*`, "rm with a glob"),
  destructive(GIT + String.raw`reset\b.*--hard`, "git reset --hard"),
  destructive(GIT + String.raw`clean\b.*\s-\S*[fdx]`, "git clean"),
  destructive(GIT + String.raw`worktree\s+(?:remove|prune)\b`, "git worktree remove/prune"),
  destructive(GIT + String.raw`branch\b.*\s-D\b`, "git branch -D"),
  destructive(GIT + String.raw`branch\b.*--delete.*--force`, "git branch --delete --force"),
  destructive(GIT + String.raw`stash\s+(?:drop|clear)\b`, "git stash drop/clear"),
  destructive(GIT + String.raw`checkout\s+(?:-f\b|--force\b|--\s)`, "git checkout discarding changes"),
  destructive(GIT + String.raw`restore\b`, "git restore (discards working-tree changes)"),
  destructive(GIT + String.raw`rebase\b`, "git rebase"),
  destructive(GIT + String.raw`commit\b.*--amend`, "git commit --amend"),
  destructive(GIT + String.raw`(?:filter-branch|filter-repo)\b`, "git history rewrite"),
  destructive(GIT + String.raw`reflog\s+expire\b`, "git reflog expire"),
  destructive(GIT + String.raw`update-ref\b.*\s-d\b`, "git update-ref -d"),
  destructive(GIT + String.raw`gc\b.*--prune`, "git gc --prune"),
  destructive(HEAD + String.raw`find\b.*(?:\s-delete\b|-exec\s+rm\b)`, "find -delete / -exec rm"),
  destructive(HEAD + String.raw`(?:shred|truncate)\b`, "shred/truncate"),
  destructive(HEAD + String.raw`dd\s+if=`, "dd"),
  destructive(HEAD + String.raw`mkfs`, "mkfs"),
  destructive(HEAD + String.raw`(?:shutdown|reboot|halt)\b`, "shutdown/reboot"),
  destructive(HEAD + String.raw`chmod\s+-\S*R`, "recursive chmod"),
  destructive(HEAD + String.raw`chown\s+-\S*R`, "recursive chown"),
  destructive(HEAD + String.raw`sed\s+(?:-\S*i|--in-place)`, "in-place sed edit"),
  destructive(HEAD + String.raw`perl\s+-\S*i`, "in-place perl edit"),
  destructive(HEAD + String.raw`rsync\b.*--delete`, "rsync --delete"),
  destructive(HEAD + String.raw`docker(?:-compose)?\b.*\b(?:rm|rmi|prune)\b`, "docker removal/prune"),
  destructive(HEAD + String.raw`docker-compose\b.*\bdown\b.*-v`, "docker-compose down -v"),
  destructive(HEAD + String.raw`kubectl\b.*\bdelete\b`, "kubectl delete"),
  destructive(HEAD + String.raw`helm\s+(?:uninstall|delete)\b`, "helm uninstall"),
  destructive(HEAD + String.raw`(?:terraform|tofu|pulumi)\s+(?:destroy|apply)\b`, "infrastructure apply/destroy"),
  destructive(HEAD + String.raw`aws\b.*\b(?:delete-\S+|terminate-\S+|rm)\b`, "aws delete/terminate"),
  destructive(HEAD + String.raw`gcloud\b.*\bdelete\b`, "gcloud delete"),
  destructive(HEAD + String.raw`dropdb\b`, "dropdb"),
  destructive(String.raw`^\s*(?:drop|truncate)\s+(?:table|database|schema)\b`, "SQL DROP/TRUNCATE"),
];

/** Leaves this machine. Publishing is a decision, and decisions are the lead's. */
const OUTWARD = [
  outward(GIT + String.raw`push\b`, "git push"),
  outward(GIT + String.raw`send-email\b`, "git send-email"),
  outward(
    HEAD + String.raw`gh\s+(?:pr|issue|release|repo|gist)\s+(?:create|merge|close|comment|delete|edit|review|upload)\b`,
    "gh write action"
  ),
  outward(HEAD + String.raw`gh\s+api\b.*(?:-X|--method)\s*(?:POST|PUT|PATCH|DELETE)`, "gh api write request"),
  outward(HEAD + String.raw`(?:npm|yarn|pnpm|bun)\s+publish\b`, "package publish"),
  outward(HEAD + String.raw`cargo\s+publish\b`, "cargo publish"),
  outward(HEAD + String.raw`twine\s+upload\b`, "twine upload"),
  outward(HEAD + String.raw`gem\s+push\b`, "gem push"),
  outward(HEAD + String.raw`poetry\s+publish\b`, "poetry publish"),
  outward(
    HEAD + String.raw`curl\b.*(?:-X\s*(?:POST|PUT|PATCH|DELETE)|--data\b|\s-d\s|\s-F\s|--upload-file\b|\s-T\s)`,
    "curl write request"
  ),
  outward(HEAD + String.raw`wget\b.*--post-`, "wget POST"),
];

const RULES = [...DESTRUCTIVE, ...OUTWARD];

// The SQL rule is the one case-insensitive matcher: `DROP TABLE` is shouted far
// more often than it is whispered, and shell commands are not.
const SQL = new RegExp(String.raw`^\s*(?:drop|truncate)\s+(?:table|database|schema)\b`, "i");

/**
 * Commands that carry another command inside a quoted argument. Quoted spans
 * are normally masked before matching (an `rm -rf` inside a commit message is
 * prose, not a deletion) — for these, the quoted span IS a command, so it is
 * unwrapped and classified in its own right.
 */
const CARRIES_NESTED_COMMAND = /\b(?:eval|xargs|(?:ba|z|k)?sh\s+-\S*c|psql|mysql|sqlite3|mongosh?)\b/;

/**
 * Blank out quoted spans while PRESERVING LENGTH, so offsets into the masked
 * string still index the original. That is what lets stages be matched on the
 * masked text but compared against the raw text for authorization.
 */
function maskQuoted(cmd) {
  let out = "";
  let quote = null;
  for (const ch of cmd) {
    if (quote) {
      out += ch === "\n" ? "\n" : " ".repeat(ch.length);
      if (ch === quote) quote = null;
    } else if (ch === "'" || ch === '"') {
      quote = ch;
      out += " ";
    } else {
      out += ch;
    }
  }
  return out;
}

/** The contents of each quoted span, which is where a carrier hides its payload. */
function quotedSpans(cmd) {
  const out = [];
  let quote = null;
  let buf = "";
  for (const ch of cmd) {
    if (quote) {
      if (ch === quote) {
        out.push(buf);
        buf = "";
        quote = null;
      } else buf += ch;
    } else if (ch === "'" || ch === '"') quote = ch;
  }
  if (quote && buf) out.push(buf); // unterminated quote: take what there is
  return out;
}

/** Split into pipeline/sequence stages, returning {raw, masked} for each. */
function stagesOf(cmd) {
  const masked = maskQuoted(cmd);
  const out = [];
  const sep = /\|\||&&|[|;\n]/g;
  let start = 0;
  let m;
  while ((m = sep.exec(masked)) !== null) {
    out.push({ raw: cmd.slice(start, m.index), masked: masked.slice(start, m.index) });
    start = m.index + m[0].length;
  }
  out.push({ raw: cmd.slice(start), masked: masked.slice(start) });
  return out;
}

/** Whitespace-normalized form — the unit an ALLOW-DESTRUCTIVE line authorizes. */
export function normalizeStage(stage) {
  return String(stage).trim().replace(/\s+/g, " ");
}

function matchRules(stage) {
  if (SQL.test(stage)) return { label: "SQL DROP/TRUNCATE", kind: "destructive" };
  for (const [re, label, kind] of RULES) {
    if (re.test(stage)) return { label, kind };
  }
  return null;
}

function findHits(cmd, depth) {
  const hits = [];
  for (const { raw, masked } of stagesOf(cmd)) {
    let hit = matchRules(masked);
    if (!hit && depth < 1 && CARRIES_NESTED_COMMAND.test(masked)) {
      for (const inner of quotedSpans(raw)) {
        const nested = findHits(inner, depth + 1);
        if (nested.length) {
          hit = nested[0];
          break;
        }
      }
    }
    if (hit) hits.push({ stage: normalizeStage(raw), label: hit.label, kind: hit.kind });
  }
  return hits;
}

/**
 * Every stage of `cmd` that is destructive or outward-facing:
 * [{ stage, label, kind }]. Empty means nothing was matched.
 */
export function classify(cmd) {
  if (typeof cmd !== "string" || !cmd.trim()) return [];
  return findHits(cmd, 0);
}

/**
 * SANDBOX GUARD. A runner's experiment builds scratch repos under a temp path
 * held in a variable. When that variable turns out empty (it was defined only in
 * the order's prose, and every Bash call is a fresh shell), `cd "$T/up"` fails
 * and every bare `git` after it writes into whatever repository the runner is
 * standing in. Forms that NAME the scratch path per write (`git -C "$T/r" …`,
 * `git init "$T/r"`) fail closed instead: with T empty they point at `/r`.
 *
 * So a command that is certainly broken (it uses a path variable no one set:
 * each Bash call is a fresh shell) or that writes a local git identity may only
 * write git state through a pinned path. Control flow is not analysed (`set -e`
 * and `&&` both proved unreliable: `cd ""` succeeds), so pinning is the only
 * accepted form.
 */

// Leading tokens that sit before a command word without being one. HEAD itself
// is left alone because the rule tables are built from it.
const CMD_HEAD = new RegExp(
  String.raw`^(?:\s*(?:[{!]\s|\(|(?:then|do|else|if|elif|while|until|time|command|env)\s))*` + HEAD.slice(1)
);

// Names bash or the Bash tool's shell sets itself, so the hook's own env says
// nothing about whether they are empty where the command runs.
const SHELL_SET_NAMES = new Set(
  "PWD OLDPWD REPLY RANDOM SRANDOM SECONDS LINENO BASHPID PPID UID EUID HOSTNAME OPTARG OPTIND BASH_REMATCH PIPESTATUS".split(
    " "
  )
);
// The harness's own names, listed one by one: any other CLAUDE_ name was made
// up by the command and counts as unbound like any other name.
const HARNESS_SET_NAMES = new Set(
  "CLAUDE_JOB_DIR CLAUDE_PROJECT_DIR CLAUDE_PLUGIN_ROOT CLAUDE_PLUGIN_DATA CLAUDE_ENV_FILE CLAUDE_CONFIG_DIR".split(" ")
);
const isShellSet = (name) => SHELL_SET_NAMES.has(name) || HARNESS_SET_NAMES.has(name);

// Shell words, keeping their quotes: unquoted runs and quoted spans glued together.
const WORD = /(?:[^\s'"]+|'[^']*'|"(?:\\.|[^"\\])*")+/g;

const GIT_READS = new Set(
  "status log diff show rev-parse ls-files ls-tree ls-remote cat-file describe blame shortlog grep for-each-ref merge-base name-rev rev-list count-objects check-ignore check-attr var version help archive".split(
    " "
  )
);
const GIT_GLOBAL_FLAGS = new Set(["--no-pager", "-P", "--bare", "--no-optional-locks"]);
const CONFIG_WRITE_FLAGS = ["--unset", "--unset-all", "--add", "--replace-all", "--rename-section", "--remove-section", "-e", "--edit"];
const CONFIG_OFF_REPO = ["--global", "--system", "--file", "-f", "--blob"];

const unquote = (w) => (/^(['"])[\s\S]*\1$/.test(w) ? w.slice(1, -1) : w);
const hasFlag = (args, flags) => args.some((a) => flags.some((f) => a === f || (f.startsWith("--") && a.startsWith(f + "="))));

function tempRoots() {
  const roots = [];
  for (const p of [tmpdir(), "/tmp", "/var/tmp"]) {
    try {
      roots.push(realpathSync(p));
    } catch {
      // a root that does not exist is skipped
    }
  }
  return roots;
}

const isUnder = (p, roots) => roots.some((r) => p === r || p.startsWith(r + "/"));

/** realpath of `p`, or of its deepest existing ancestor with the rest appended. */
function realpathDeep(p) {
  const rest = [];
  let cur = resolve(p);
  for (;;) {
    try {
      return join(realpathSync(cur), ...rest);
    } catch {
      const up = dirname(cur);
      if (up === cur) return cur;
      rest.unshift(basename(cur));
      cur = up;
    }
  }
}

/** The work tree the runner is standing in, or null when it is not in a real one. */
function realToplevel(cwd, roots) {
  if (typeof cwd !== "string" || !cwd) return null;
  let dir = realpathSync(cwd);
  if (isUnder(dir, roots)) return null;
  for (;;) {
    if (existsSync(join(dir, ".git"))) return dir;
    const up = dirname(dir);
    if (up === dir) return null;
    dir = up;
  }
}

/**
 * A path that points into a sandbox: an unset variable plus a sub-path (empty,
 * it fails closed at `/sub`), or a literal path under a temp root. A bare `$T`
 * is not one — empty, it means the cwd.
 */
function isScratchPath(word, roots) {
  if (typeof word !== "string" || word.includes("'")) return false;
  let p = word.replaceAll('"', "");
  const v = /^\$(?:\{([A-Za-z_][A-Za-z0-9_]*)(:\?[^}]*)?\}|([A-Za-z_][A-Za-z0-9_]*))([\s\S]*)$/.exec(p);
  if (v) {
    if (v[2] !== undefined) return true;
    const value = process.env[v[1] || v[3]];
    if (!v[4]) return false;
    if (!value) return /^\/./.test(v[4]);
    p = value + v[4];
  } else if (p === "~" || p.startsWith("~/")) {
    p = (process.env.HOME || "") + p.slice(1);
  }
  if (!p.startsWith("/")) return false;
  return isUnder(realpathDeep(p), roots);
}

/**
 * Top-level stages plus, one level down, the stages carried inside sh -c / eval
 * quotes; `payloads` is the carried text itself.
 */
function expandStages(cmd) {
  const stages = [];
  const payloads = [];
  for (const s of stagesOf(cmd)) {
    stages.push(s);
    if (!CARRIES_NESTED_COMMAND.test(s.masked)) continue;
    for (const inner of quotedSpans(s.raw)) {
      payloads.push(inner);
      stages.push(...stagesOf(inner));
    }
  }
  return { stages, payloads };
}

const NAME = String.raw`[A-Za-z_][A-Za-z0-9_]*`;
const IS_NAME = new RegExp(`^${NAME}$`);
const STARTS_ASSIGN = new RegExp(`^${NAME}=`);
// Only the plain forms: `${T:-x}` and friends carry their own fallback.
const REF_AT = new RegExp(String.raw`\$(?:\{(${NAME})\}|(${NAME}))`, "y");
const WHOLE_REF = new RegExp(String.raw`^\$(?:\{(${NAME})\}|(${NAME}))$`);
const ASSIGNS = [
  new RegExp(String.raw`(?:^|[\s;&|(){}\x60])(${NAME})=`, "g"),
  new RegExp(String.raw`\b(?:for|select)\s+(${NAME})\s+in\b`, "g"),
  new RegExp(String.raw`\$\{(${NAME}):?=`, "g"),
];

/**
 * Plain `$NAME` / `${NAME}` references outside single quotes, in order, each
 * marked `slash` when a `/` follows it (past at most one `"`).
 */
function references(text) {
  const out = [];
  let inDouble = false;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    if (ch === "\\") {
      i++;
    } else if (ch === '"') {
      inDouble = !inDouble;
    } else if (ch === "'" && !inDouble) {
      const end = text.indexOf("'", i + 1);
      if (end < 0) break;
      i = end;
    } else if (ch === "$") {
      REF_AT.lastIndex = i;
      const m = REF_AT.exec(text);
      if (!m) continue;
      let j = i + m[0].length;
      if (text[j] === '"') j++;
      out.push({ name: m[1] || m[2], slash: text[j] === "/" });
    }
  }
  return out;
}

/** The variable a cd / -C target word consists of, or null. */
function targetName(word) {
  if (typeof word !== "string" || word.includes("'")) return null;
  const m = WHOLE_REF.exec(word.replaceAll('"', ""));
  return m ? m[1] || m[2] : null;
}

/** Names a `read` or `getopts` stage assigns (a leading while/until/if is looked past). */
function readAssigns(words) {
  let k = 0;
  while (k < words.length && (/^(?:while|until|if|elif|!)$/.test(words[k]) || STARTS_ASSIGN.test(words[k]))) k++;
  if (words[k] === "read") return words.slice(k + 1).filter((w) => IS_NAME.test(w));
  if (words[k] === "getopts" && IS_NAME.test(words[k + 2] ?? "")) return [words[k + 2]];
  return [];
}

function parseGit(args) {
  let dir = null;
  let i = 0;
  while (i < args.length) {
    const a = args[i];
    if (a === "-C") {
      dir = args[i + 1] ?? "";
      i += 2;
    } else if (a === "-c") i += 2;
    else if (GIT_GLOBAL_FLAGS.has(a) || a.startsWith("--git-dir=") || a.startsWith("--work-tree=")) i += 1;
    else break;
  }
  return { dir, sub: args[i], rest: args.slice(i + 1) };
}

/** null for a read; "repo" for a write to the repository; "off-repo" for a config write that never touches it. */
function gitWriteKind(sub, rest) {
  if (GIT_READS.has(sub)) return null;
  if (sub === "worktree" && rest.find((a) => !a.startsWith("-")) === "list") return null;
  if (sub !== "config") return "repo";
  const operands = rest.filter((a) => !a.startsWith("-"));
  const write =
    hasFlag(rest, CONFIG_WRITE_FLAGS) || (operands[0] !== "get" && operands[0] !== "list" && operands.length >= 2);
  if (!write) return null;
  return hasFlag(rest, CONFIG_OFF_REPO) ? "off-repo" : "repo";
}

/**
 * The sandbox verdict for one runner Bash call. Returns null when nothing
 * escapes; otherwise { toplevel, stages, evidence, unset }: the real work tree
 * the runner is standing in, each unpinned git write (normalized), which
 * evidence the command carried ("E3" a local identity write, "U" a path built
 * on an unbound variable), and the unbound variable names in first-seen order.
 * Fails open: any error means null.
 */
export function sandboxEscape(command, cwd) {
  try {
    if (typeof command !== "string" || !command.trim()) return null;
    const roots = tempRoots();
    const toplevel = realToplevel(cwd, roots);
    if (!toplevel) return null;

    const { stages, payloads } = expandStages(command);
    const evidence = new Set();
    const unpinned = [];
    const targets = new Set();
    const assigned = new Set();
    for (const { raw, masked } of stages) {
      const head = CMD_HEAD.exec(masked);
      const words = raw.slice(head ? head[0].length : 0).match(WORD) || [];
      for (const n of readAssigns(words)) assigned.add(n);
      const [cmdWord, ...args] = words;
      if (cmdWord === "cd" || cmdWord === "pushd") {
        const n = targetName(args.find((a) => !a.startsWith("-")));
        if (n) targets.add(n);
        continue;
      }
      if (cmdWord !== "git") continue;

      const { dir, sub, rest } = parseGit(args);
      const n = targetName(dir);
      if (n) targets.add(n);
      const kind = gitWriteKind(sub, rest);
      if (kind !== "repo") continue;
      if (sub === "config" && rest.some((a) => unquote(a).startsWith("user."))) evidence.add("E3");

      const pinned =
        (dir !== null && isScratchPath(dir, roots)) ||
        ((sub === "init" || sub === "clone") && isScratchPath(words[words.length - 1], roots)) ||
        (sub === "worktree" && rest.some((a) => isScratchPath(a, roots)));
      if (!pinned) unpinned.push(normalizeStage(raw));
    }
    if (!unpinned.length) return null;

    const texts = [command, ...payloads];
    for (const text of texts) {
      for (const re of ASSIGNS) for (const m of text.matchAll(re)) assigned.add(m[1]);
    }
    const unset = [];
    for (const text of texts) {
      for (const { name, slash } of references(text)) {
        if (
          (slash || targets.has(name)) &&
          !isShellSet(name) &&
          !process.env[name] &&
          !assigned.has(name) &&
          !unset.includes(name)
        ) {
          unset.push(name);
        }
      }
    }
    if (unset.length) evidence.add("U");
    if (!evidence.size) return null;
    return { toplevel, stages: unpinned, evidence: [...evidence].sort(), unset };
  } catch {
    return null;
  }
}

export const ALLOW_MARKER = "ALLOW-DESTRUCTIVE:";

// Tolerates list bullets and blockquote markers, since the marker is written
// inside prose orders.
const ALLOW_LINE = /^[ \t>*+-]*ALLOW-DESTRUCTIVE:[ \t]*(\S[^\n]*?)[ \t]*$/gm;

const ALLOW_MAX_LINES = 400;

function readAllowLines() {
  try {
    return readFileSync(ALLOW_FILE, "utf8").split("\n").filter(Boolean);
  } catch {
    return [];
  }
}

function pruneIfLarge() {
  try {
    const lines = readAllowLines();
    if (lines.length <= ALLOW_MAX_LINES * 2) return;
    const tmp = `${ALLOW_FILE}.${process.pid}.tmp`;
    writeFileSync(tmp, lines.slice(-ALLOW_MAX_LINES).join("\n") + "\n");
    renameSync(tmp, ALLOW_FILE);
  } catch {
    // best-effort: a skipped prune only costs disk
  }
}

/**
 * Record the ALLOW-DESTRUCTIVE lines carried by a dispatch prompt. Append-only
 * for the same reason the nudge state is: concurrent sessions share the file
 * under one HOME, and an O_APPEND write of a short line does not clobber.
 * Returns the commands recorded.
 */
export function recordAllowances(sessionId, prompt) {
  if (typeof sessionId !== "string" || !sessionId) return [];
  if (typeof prompt !== "string" || !prompt.includes(ALLOW_MARKER)) return [];
  const found = [];
  let m;
  ALLOW_LINE.lastIndex = 0;
  while ((m = ALLOW_LINE.exec(prompt)) !== null) found.push(normalizeStage(m[1]));
  if (!found.length) return [];
  try {
    mkdirSync(dirname(ALLOW_FILE), { recursive: true });
    appendFileSync(ALLOW_FILE, found.map((c) => `${sessionId}\t${c}\n`).join(""));
    pruneIfLarge();
  } catch {
    return []; // unwritable -> nothing is authorized, which fails safe
  }
  return found;
}

/** Was this exact stage authorized for this session? */
export function isAllowed(sessionId, stage) {
  if (typeof sessionId !== "string" || !sessionId) return false;
  const want = `${sessionId}\t${normalizeStage(stage)}`;
  return readAllowLines().includes(want);
}

/**
 * How each runner is described to the human in the permission dialog. The
 * second line is the load-bearing one: task-gopher genuinely cannot judge, while
 * smart-gopher can — and telling the user otherwise at the moment they accept an
 * irreversible risk would be a lie in the worst possible place. What is true of
 * BOTH is that neither has the authority to accept the risk on the user's
 * behalf, and that is what the smart-gopher line says instead.
 */
const RUNNER = {
  "task-gopher": {
    who: "the Haiku runner",
    caveat:
      "task-gopher is a task-runner that makes no judgments — it cannot tell whether this is correct here, and it may have reached for it to make a failing command succeed.",
  },
  "smart-gopher": {
    who: "the reasoning runner",
    caveat:
      "smart-gopher can reason about a task, but reasoning ability is not authority: it cannot accept an irreversible or outward-facing risk on your behalf, and it may have concluded this was necessary from a partial view of your work.",
  },
};

const runnerInfo = (kind) => RUNNER[kind] || RUNNER["task-gopher"];

/**
 * The permission-prompt text. Written AT THE HUMAN, and it has one job: make
 * the risk legible in the two seconds someone spends on a dialog. So it leads
 * with the command, names who wants to run it, and says plainly that no model
 * in the chain is qualified to vouch for it.
 */
export function askMessage(hits, preauthorized, kind = "task-gopher") {
  const { who, caveat } = runnerInfo(kind);
  const destructiveHit = hits.some((h) => h.kind === "destructive");
  const what = hits.map((h) => `${h.stage}   (${h.label})`).join("\n");
  const lines = [
    `${kind} — ${who} wants to run a ${destructiveHit ? "DESTRUCTIVE" : "an outward-facing"} command:`,
    "",
    what,
    "",
    destructiveHit
      ? "This can destroy work that is not recoverable."
      : "This sends something off this machine.",
    caveat,
  ];
  if (preauthorized) {
    lines.push(
      "",
      "Its lead pre-authorized this exact command with an ALLOW-DESTRUCTIVE line. That is one model vouching for another — you are still the only one who can actually accept this risk."
    );
  }
  lines.push("", "Approve only if you want this to happen now.");
  return lines.join("\n");
}

/**
 * The deny text. Written AT the runner: it must not improvise.
 * `unaskableMode` is set when the guard WANTED to ask a human and could not,
 * which is a different situation from a deliberate hard block and has to read
 * that way to whoever finds it in the transcript.
 */
export function denyMessage(hits, unaskableMode, kind = "task-gopher") {
  const destructiveHit = hits.some((h) => h.kind === "destructive");
  const what = hits.map((h) => `- \`${h.stage}\` — ${h.label}`).join("\n");
  const why = unaskableMode
    ? [
        "",
        `(The guard would normally ask the user to approve this, but the session is in \`${unaskableMode}\` permission mode, where no prompt reaches a person. With nobody able to accept the risk, it denies instead.)`,
      ]
    : [];
  return [
    `${kind} — BLOCKED: ${destructiveHit ? "destructive" : "outward-facing"} command.`,
    "",
    "You are the runner, not the decision-maker, and this command " +
      (destructiveHit
        ? "destroys state that may not be recoverable:"
        : "sends something off this machine:"),
    what,
    ...why,
    "",
    "STOP here. Do NOT retry it, do NOT reach for a different flag or a bigger hammer (`--force`, `-f`, `sudo`, a rewritten path), and do NOT route around it with another tool. Escalating a command to make it succeed is exactly the decision you are not allowed to make.",
    "",
    "Report back to your lead now: quote the exact command above, say it was blocked by the task-gopher destructive guard, and state what you had completed before it. That is a correct, complete outcome — not a failure to hide.",
    "",
    `Your lead can authorize it, if they judge it right, by re-dispatching with a line reading "${ALLOW_MARKER} <the exact command>" in the order.`,
  ].join("\n");
}
