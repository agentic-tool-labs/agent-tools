/**
 * task-gopher — shared state + directive text.
 *
 * Enabled state is a single marker file at ~/.claude/task-gopher.enabled.
 * Existence = ON. It lives in the user's home (not the plugin cache, which is
 * wiped on update) so the toggle survives plugin upgrades. Default is OFF:
 * this materially changes how the main agent works, so it is opt-in.
 */

import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export const STATE_FILE = join(homedir(), ".claude", "task-gopher.enabled");

export function isEnabled() {
  return existsSync(STATE_FILE);
}

/**
 * Strict mode — an optional enforcement layer ON TOP of `enabled`. When both are
 * set, a PreToolUse hook blocks the FIRST direct retrieval of each turn once, so
 * the agent has to consciously decide "should this go to task-gopher?" before
 * doing tool work itself. It's a speed-bump, not a hard block: re-running the
 * same call proceeds, and the gate stays quiet for the rest of that turn.
 */
export const STRICT_FILE = join(homedir(), ".claude", "task-gopher.strict");

/** Records {pid, n} for the current turn, so the checkpoint escalates by bypass count. */
export const NUDGE_FILE = join(homedir(), ".claude", "task-gopher.nudge");

/**
 * Optional user-maintained list of `subagent_type`s the relay must never stamp —
 * one per line, `#` comments and blank lines ignored, missing file means nothing
 * is exempt. It exists because the automatic tool-less check in agent-tools.mjs
 * can only read definitions that are ON DISK: an agent defined through the SDK
 * has no file to parse, so no amount of frontmatter reading will ever classify
 * it. Managed with `/task-gopher relay-exempt`.
 */
export const RELAY_EXEMPT_FILE = join(homedir(), ".claude", "task-gopher.relay-exempt");

export function readRelayExempt() {
  try {
    return readFileSync(RELAY_EXEMPT_FILE, "utf8")
      .split("\n")
      .map((line) => line.replace(/#.*$/, "").trim())
      .filter(Boolean);
  } catch {
    return []; // absent or unreadable -> nothing exempt, current behavior
  }
}


/**
 * How the destructive guard resolves a destructive or outward-facing command
 * from the runner. File contents, not existence — three states need three
 * values, and the marker-file idiom only carries two.
 *
 * - `ask` (DEFAULT, and what the plugin exists to do): raise a permission
 *   prompt so a PERSON decides. The runner cannot judge the risk and neither
 *   can its lead — an agent authorizing an agent is not informed consent.
 * - `block`: hard-deny, releasable only by the lead's written
 *   ALLOW-DESTRUCTIVE line. Correct for unattended runs where no one is at the
 *   keyboard to answer a prompt.
 * - `off`: no guard at all.
 */
export const GUARD_FILE = join(homedir(), ".claude", "task-gopher.guard");

export function guardMode() {
  try {
    const v = readFileSync(GUARD_FILE, "utf8").trim().toLowerCase();
    if (v === "block" || v === "off" || v === "ask") return v;
  } catch {
    // absent or unreadable -> the default
  }
  return "ask";
}

/**
 * Permission modes in which a prompt actually reaches a human. `auto`,
 * `dontAsk`, and `bypassPermissions` all exist precisely to stop asking, and
 * the hook docs do not say what becomes of an `ask` decision inside them — an
 * `ask` that is silently auto-approved would be the exact failure this guard
 * exists to prevent, so those modes fall back to denying instead.
 *
 * An ABSENT mode is treated as unaskable for the same reason: if the payload
 * cannot tell us a person is reachable, we do not gamble that one is.
 * (Modes per the hook docs: default, plan, acceptEdits, auto, dontAsk,
 * bypassPermissions.)
 */
const ASKABLE_PERMISSION_MODES = new Set(["default", "acceptEdits", "plan"]);

export function canAskHuman(input) {
  const mode = input && input.permission_mode;
  return typeof mode === "string" && ASKABLE_PERMISSION_MODES.has(mode);
}

/**
 * Commands the lead has explicitly authorized the runner to execute despite the
 * destructive guard, one `sessionId\tcommand` per line. Written when a dispatch
 * carrying `ALLOW-DESTRUCTIVE:` lines goes out; read when the runner's Bash call
 * is classified. See destructive.mjs.
 */
export const ALLOW_FILE = join(homedir(), ".claude", "task-gopher.allow");

/**
 * Append-only JSONL audit log. Checkpoint/bypass lines require strict mode;
 * dispatch, relay-ok/relay-injected, and destructive-guard lines are written
 * whenever the plugin is installed.
 */
export const LOG_FILE = join(homedir(), ".claude", "task-gopher.log");

export function isStrict() {
  return existsSync(STRICT_FILE);
}

/** Read the hook's stdin JSON payload; returns {} if absent or unparseable. */
export async function readHookInput() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  const raw = Buffer.concat(chunks).toString("utf8").trim();
  if (!raw) return {};
  try {
    return JSON.parse(raw);
  } catch {
    return {};
  }
}

/**
 * Who may delegate is gated by MODEL TIER, not by orchestrator-vs-subagent: any
 * Sonnet-tier-or-higher agent (main OR subagent) may dispatch to the Haiku
 * task-gopher; a Haiku-tier agent may not. Crucially, the hook payload exposes
 * NO model field (verified against the Claude Code CLI: the base hook input is
 * session_id/transcript_path/cwd/prompt_id/permission_mode/agent_id/agent_type/
 * effort — `effort` is the thinking level low|medium|high, not a capability
 * tier). So the hook cannot read the tier; the tier gate lives in the directive
 * text itself, where each agent self-excludes if it is Haiku-tier.
 *
 * The one thing the hooks CAN do reliably is skip either gopher itself by name
 * (`agent_type` carries the subagent's name), so no gate ever fires inside a
 * recursion-prone runner. Substring match tolerates the plugin-scoped form
 * (e.g. "task-gopher:task-gopher"). Note the injection hooks (SessionStart,
 * UserPromptSubmit) only ever run for the MAIN session — they never fire for
 * subagents. Subagents receive the directive solely via the relay gate in
 * pretooluse-nudge.mjs, which makes parents copy it into dispatch prompts.
 *
 * TODO(hard-gate): the tier gate is currently SOFT — the directive asks each
 * agent to self-exclude if it is Haiku-tier, which the hook cannot enforce
 * because no model/tier field exists in the hook payload (as of Claude Code
 * v2.1.211). If a future version adds one (e.g. `model` or a capability tier
 * to the SessionStart/UserPromptSubmit payload), convert this to a HARD gate:
 * read the field here and suppress injection for any Haiku-tier agent, so the
 * gate no longer relies on the model recognizing its own tier. Re-check the
 * payload shape in the CLI (function `Uf`, the base hook-input builder) when
 * upgrading. Track: https://code.claude.com/docs/en/hooks
 */

/**
 * The runner agents this plugin ships, and which one a name refers to.
 *
 * ORDER IS LOAD-BEARING. The plugin-scoped form of the reasoning runner is
 * "task-gopher:smart-gopher" — the PLUGIN half is literally "task-gopher", so a
 * task-gopher-first test classifies every smart-gopher as the Haiku runner. That
 * is invisible for a boolean gate and wrong where it matters most: the
 * permission dialog, which names the agent asking to destroy something. Most
 * specific name first.
 *
 * Substring rather than equality, matching the existing convention: the harness
 * may hand us the bare name or the plugin-scoped one, and both must match.
 * Known looseness (accept, do not fix): a user agent named
 * `my-smart-gopher-helper` would match. This is exactly the looseness the
 * existing code already had with `task-gopher`, it fails toward *more* guarding
 * rather than less, and tightening it would break the bare-vs-namespaced
 * tolerance this depends on.
 */
const GOPHER_KINDS = ["smart-gopher", "task-gopher"];

/** "smart-gopher" | "task-gopher" | null */
export function gopherKind(name) {
  if (typeof name !== "string" || !name) return null;
  for (const kind of GOPHER_KINDS) if (name.includes(kind)) return kind;
  return null;
}

/** Which runner is this hook firing inside, if any? Reads `agent_type`. */
export function agentGopherKind(input) {
  return gopherKind(input && input.agent_type);
}

/** Is this hook firing inside either runner? */
export function isGopherAgent(input) {
  return agentGopherKind(input) !== null;
}

/**
 * agent-hierarchy roles. Each one's own md already carries the delegation rule,
 * so paying for the directive again — relayed into a dispatch, injected into a
 * `--agent ah:<role>` session at start and on every compact, or reminded each
 * turn — buys nothing. Exact names, not an `ah:` prefix test: the set is small
 * and a prefix rule would silently swallow future non-role `ah:` agents.
 */
export const AH_ROLE_AGENTS = new Set([
  "ah:architect",
  "ah:implementor",
  "ah:orchestrator",
  "ah:reviewer",
  "ah:ultra-advisor",
  "ah:task-runner",
]);

/** Is this hook firing inside a `--agent ah:<role>` session? Reads `agent_type`. */
export function isHierarchyRoleAgent(input) {
  return AH_ROLE_AGENTS.has(input && input.agent_type);
}

/**
 * A range this long or longer is a whole-file hand-back in disguise: ~4 KB, one
 * Read chunk. Below it, batching a few small ranges into one dispatch is a
 * defensible trade against N tool round trips. Tuning knob (spec 0001 §2).
 */
export const LARGE_RANGE_LINES = 80;

/**
 * A match is a MENTION, not an order, when the text just before it negates it
 * ("don't dump the whole file") or frames it as something being described:
 * a spec, a test case, a labelling rule, a regex. Both live FPs this guard was
 * widened for were orders ABOUT the gate — describing the phrase is exactly
 * what spec- and test-writing work does, and under a hard deny there is no
 * workaround but to reword a description whose point is to name the phrase.
 *
 * The quote rule tests the QUALIFIER, never the path: paths are routinely
 * backticked in legitimate orders.
 */
const GUARD_WINDOW = 60;
const NEGATION = /\b(not|never|no|don'?t|do not|without|unless|instead of|rather than|avoid)\b/i;
const META =
  /\b(deny|denies|denied|denial|refuse[sd]?|reject[sd]?|block[sed]?|gate[sd]?|flag[sged]*|detect[sed]?|forbid[s]?|pattern|regex|test case|assert|counts? as|true positive|false positive|TP|FP|label[sled]*|classif\w*|definition|defined?|means|i\.e\.|e\.g\.)\b/i;

/**
 * A path token names a file: it holds a directory separator, or ends in an
 * extension whose first character is a letter. A trailing slash makes it a
 * directory ("docs/"), and a version string ("v0.16.0") has digits where an
 * extension's letters would be — neither is a file.
 */
const PATH_TOKEN =
  /(?<![\w./~-])[`"']?((?:[\w.~@+-]*\/[\w.~@/+-]*[\w~+-])|(?:[\w-]+\.[A-Za-z]\w{0,4}(?![\w-]|\.\w)))[`"']?(?![\w/~-])/g;

/** Glue may run this far between the qualifier and the path before they stop being one breath. */
const GLUE_MAX = 40;
const GLUE_WORDS = /^(?:[\s:,(—–]|\b(?:of|for|from|in|at|and|the|this|these|those|each|both|files?)\b)*$/i;

/**
 * Is the text between a qualifier and a path token nothing but glue? Any other
 * word breaks adjacency — that is what keeps "full text of the section
 * beginning ## Scope in docs/a.md" out. One newline is allowed, optionally
 * followed by a list marker, so "these files:\n- path" still reads as adjacent.
 */
function glueOk(between) {
  if (between.length > GLUE_MAX) return false;
  const flattened = between.replace(/\n[ \t]*(?:[-*]|\d+\.)?[ \t]*/, " ");
  if (flattened.includes("\n")) return false;
  return GLUE_WORDS.test(flattened);
}

function pathTokens(text) {
  PATH_TOKEN.lastIndex = 0;
  const out = [];
  let m;
  while ((m = PATH_TOKEN.exec(text)) !== null) {
    out.push({ start: m.index, end: m.index + m[0].length, text: m[1] });
  }
  return out;
}

/** Is [start,end) inside a `…` or "…" span? Quotes are paired left to right. */
function quoted(text, start, end) {
  for (const q of ["`", '"']) {
    let open = -1;
    for (let i = 0; i < text.length; i++) {
      if (text[i] !== q) continue;
      if (open < 0) open = i;
      else {
        if (start > open && end <= i) return true;
        open = -1;
      }
    }
  }
  return false;
}

function mentioned(text, index, end) {
  const before = text.slice(Math.max(0, index - GUARD_WINDOW), index);
  return NEGATION.test(before) || META.test(before) || quoted(text, index, end);
}

// The object is the discriminator, never the word "verbatim": 70% of real
// gopher orders contain it and mean "don't paraphrase" (spec 0001 §2).
const H1_QUALIFIERS = [
  /\b(full|entire|whole|complete)\b,?(?:\s+\w+){0,2}\s+(file|files|contents?|text|source)\b/gi,
  /\b(full|entire|whole|complete)\b[^.\n]{0,20}\bcontents?\s+of\b/gi,
];
/**
 * Path-first accepts only a TERMINAL whole-file qualifier. `verbatim` is not
 * one: it means "do not paraphrase", and 21 of r8's 33 false positives were
 * bounded excerpts and grep output that happened to say it after a path.
 * `full source` / `full text` / `complete text` stay qualifier-first only, and
 * a trailing `of` means the object is something inside the file, not the file.
 */
const H1_MIRROR =
  /\bin full\b|\bin (its )?entirety\b|\bentirely\b|\b(full|entire|whole|complete)\s+(file|files|contents?)\b(?!\s+of\b)/gi;
const READ_WHOLE = [/\bread\s+(the\s+)?(whole|entire|full)\s+(file|thing)\b/i, /\bin (its )?entirety\b/i];

/**
 * The order names a file but the object is not the file: a search filters it, a
 * listing names it, and "read it in full and report back compactly" asks for a
 * distillation. `report` alone is NOT a distil signal — "report back VERBATIM,
 * the entire file" is the order this gate exists for.
 */
const SEARCH_VERB = /\b(search|grep|scan|find)\b/i;
const LISTING_NOUN = /^.{0,3}\b(list|listing|names?|paths?|count|size|tree)\b/i;
const DISTIL = /\b(compact\w*|summar\w*|answer\w*)\b/i;

/** A distil word inside a filename (/tmp/rh-summary.log) is not a distil instruction. */
function blankPaths(s) {
  return s.replace(PATH_TOKEN, (m) => " ".repeat(m.length));
}

function targetGuarded(text, start, end) {
  if (SEARCH_VERB.test(text.slice(Math.max(0, start - 40), start))) return true;
  if (LISTING_NOUN.test(text.slice(end, end + 20))) return true;
  if (DISTIL.test(blankPaths(text.slice(end, end + 60)))) return true;
  return false;
}

/** Qualifier-first: the qualifier names the object, the path follows through glue. */
function pathAdjacent(text, paths, start, end) {
  return paths.some((p) => p.start >= end && glueOk(text.slice(end, p.start)));
}

/** H3 names a range, and a range reads the same on either side of its file. */
function pathEitherSide(text, paths, start, end) {
  return paths.some(
    (p) =>
      (p.start >= end && glueOk(text.slice(end, p.start))) ||
      (p.end <= start && glueOk(text.slice(p.end, start))),
  );
}

function pathBefore(text, paths, start) {
  return paths.some((p) => p.end <= start && glueOk(text.slice(p.end, start)));
}

const RANGE_TOOLS = [
  { re: /sed\s+-n\s+'?(\d+),(\d+)p'?/gi, span: (m) => Number(m[2]) - Number(m[1]) + 1 },
  { re: /head\s+(?:-n\s*|-)(\d+)/gi, span: (m) => Number(m[1]) },
  { re: /tail\s+(?:-n\s*|-)(\d+)/gi, span: (m) => Number(m[1]) },
];
const LINES_RANGE = /lines?\s+(\d+)\s*(?:-|–|—|to|through)\s*(\d+)/gi;
const READ_CALL = /Read\(([^)]*)\)/gi;

/** Only flags and whitespace may sit between the tool and its file. */
const TOOL_ARG_SKIP = /^(?:\s|-{1,2}\w+\s*)*/;

/**
 * A shell filter reads a stream, not a file, and a redirect sends the bytes to
 * disk instead of into the runner's context. Either way nothing is handed back.
 */
function pipedOrRedirected(text, toolStart, pathEnd) {
  const lineStart = text.lastIndexOf("\n", toolStart - 1) + 1;
  const before = text.slice(Math.max(lineStart, toolStart - 40), toolStart);
  let after = text.slice(pathEnd, pathEnd + 20);
  const nl = after.indexOf("\n");
  if (nl >= 0) after = after.slice(0, nl);
  return before.includes("|") || after.includes("|") || after.includes(">");
}

function h3Hit(text, paths) {
  for (const { re, span } of RANGE_TOOLS) {
    re.lastIndex = 0;
    let m;
    while ((m = re.exec(text)) !== null) {
      const end = m.index + m[0].length;
      const skip = TOOL_ARG_SKIP.exec(text.slice(end))[0].length;
      const p = paths.find((t) => t.start === end + skip);
      if (!p) continue;
      if (pipedOrRedirected(text, m.index, p.end)) continue;
      if (span(m) >= LARGE_RANGE_LINES) return m[0];
    }
  }
  READ_CALL.lastIndex = 0;
  let r;
  while ((r = READ_CALL.exec(text)) !== null) {
    const limit = /limit\D*(\d+)/i.exec(r[1]);
    if (!limit || Number(limit[1]) < LARGE_RANGE_LINES) continue;
    if (paths.some((p) => p.start > r.index && p.end < r.index + r[0].length)) return r[0];
  }
  LINES_RANGE.lastIndex = 0;
  let l;
  while ((l = LINES_RANGE.exec(text)) !== null) {
    if (Number(l[2]) - Number(l[1]) + 1 < LARGE_RANGE_LINES) continue;
    if (pathEitherSide(text, paths, l.index, l.index + l[0].length)) return l[0];
  }
  return null;
}

/**
 * Does this dispatch prompt order the runner to hand back a file whole?
 * Returns null, or {rule, text} where rule is "H1" (a whole-file qualifier
 * naming an explicit path), "H2" (read-the-whole-thing) or "H3" (a range tool
 * applied directly to a path, LARGE_RANGE_LINES or more).
 *
 * r8 NARROW (user ruling): deny only when the order names an explicit file AND
 * asks for it whole in the same breath. Whole-file orders whose path sits
 * further off are accepted misses — see spec 0001 §2 and §6 case 14.
 */
export function verbatimReadHit(prompt) {
  if (typeof prompt !== "string" || !prompt) return null;
  const paths = pathTokens(prompt);

  for (const re of H1_QUALIFIERS) {
    re.lastIndex = 0;
    let m;
    while ((m = re.exec(prompt)) !== null) {
      const end = m.index + m[0].length;
      if (mentioned(prompt, m.index, end)) continue;
      if (targetGuarded(prompt, m.index, end)) continue;
      if (pathAdjacent(prompt, paths, m.index, end)) return { rule: "H1", text: m[0] };
    }
  }
  H1_MIRROR.lastIndex = 0;
  let mm;
  while ((mm = H1_MIRROR.exec(prompt)) !== null) {
    const end = mm.index + mm[0].length;
    if (mentioned(prompt, mm.index, end)) continue;
    if (targetGuarded(prompt, mm.index, end)) continue;
    if (pathBefore(prompt, paths, mm.index)) return { rule: "H1", text: mm[0] };
  }

  for (const re of READ_WHOLE) {
    const m = re.exec(prompt);
    if (m && !mentioned(prompt, m.index, m.index + m[0].length)) return { rule: "H2", text: m[0] };
  }

  const h3 = h3Hit(prompt, paths);
  if (h3) return { rule: "H3", text: h3 };
  return null;
}

/**
 * Denial for a verbatim hand-back order. States the cost argument once so the
 * dispatcher learns the rule rather than rewording the order: there is no retry
 * pass, so the only ways forward are a narrower order or a direct Read.
 */
export function verbatimDenyMessage(prompt, hit) {
  const first = pathTokens(typeof prompt === "string" ? prompt : "")[0];
  const path = first ? first.text : "<path>";
  return (
    `task-gopher: this order asks the runner to hand a file back whole (matched: \`${hit.text}\`). ` +
    `That costs MORE than reading it yourself: Haiku reads it (input), re-emits it (output), and you read it again (input) — ` +
    `three times the bytes plus a dispatch. Read(${path}[, offset, limit]) directly. ` +
    `Dispatch gopher only when the answer is SMALLER than the source: grep → file:line + a few lines of context, the one function, ` +
    `a summary, a count, the first N matches. Rewrite the order that way, or read the file yourself; ` +
    `this dispatch will not be allowed as written.`
  );
}

/**
 * Marker the relay gate looks for at the top of Agent dispatch prompts, to tell
 * an already-stamped dispatch from one that still needs the directive. The
 * directive and the per-turn tick both open with it.
 */
export const SENTINEL = "[task-gopher: ON]";

/**
 * The directive: injected at SessionStart (and again after compaction) and
 * stamped onto dispatch prompts by the relay. The relay leaves it off prompts
 * to either gopher and to any agent with no Agent/Task tool, which could not
 * act on it. Its legwork list is built from the same words as CATEGORIES.
 */
export const DIRECTIVE = `[task-gopher: ON] PURPOSE: keep tool output out of your context; only the RESULT comes back. For Sonnet-tier and above, top-level or subagent. Haiku-tier, or no Agent tool: ignore this and work directly.

DEFAULT, not a preference: legwork goes to a gopher. Legwork = reading files to learn what is in them (Read, cat/head/tail/sed -n); searching (grep/rg/find); git log/diff/show/blame; test, build and lint runs; scripts (python3/node/perl/sed) that print data; any command likely to print over 40 lines; anything touching 3+ files.

PICK THE RUNNER:
- The order can be written with no decisions in it -> task-gopher:task-gopher (Haiku). E.g. "run the suite, report failures only".
- The answer needs picking among candidates, reconciling disagreeing evidence, a summary with an editorial cut, or later steps depend on earlier findings -> task-gopher:smart-gopher (Sonnet). E.g. "which of these call sites is the real entry point, and why".
- Neither -> do it yourself.

START with the order. If you have made 2 direct retrieval calls in a row, the next one goes to a gopher: bundle everything you still need into ONE order.

ORDER, 3 lines: WHERE (paths/branch). HOW (exact commands or method). BACK (what to return and the bar: "counts + file:line, at most 30 lines"). Never order a file back whole.

DO IT YOURSELF: reading a file you are about to Edit; one trivial peek; anything that needs your judgment. Gophers never decide design, security or scope.

A gate checkpoint means you did something listed above. Re-run only for an exception.`;

/** The line injected every turn: purpose, the runner selector, the counter. */
export const TICK =
  "[task-gopher: ON] Keep tool output out of your context (Haiku-tier or no Agent tool: ignore). Legwork goes to task-gopher:task-gopher when the order has no decisions in it, task-gopher:smart-gopher when it needs judging. After 2 direct retrieval calls, bundle the rest into ONE order.";

/** Closes every checkpoint reason: what the model may do when the checkpoint does not apply. */
export const EXCEPTION_LINE =
  "Re-run this exact call to proceed if it is an exception (a file you will Edit, one trivial peek, or a step that needs your judgment).";

/** Opens the reason of the checkpoint raised on every third direct call. */
export const ESCALATED_LEAD = "That is 3 direct calls this turn; bundle what you still need into ONE order.";

const ORDER_PARTS = "Order = WHERE / HOW / BACK.";
const READ_TEXT =
  'task-gopher checkpoint: you are reading files to learn what is in them. Order it instead: task-gopher:task-gopher if you can name the question ("where is X defined, file:line"); task-gopher:smart-gopher if it needs judging or summarising. ' +
  ORDER_PARTS;
const SEARCH_TEXT =
  'task-gopher checkpoint: you are searching code. Order it: task-gopher:task-gopher for a known pattern ("every caller of f, file:line"); task-gopher:smart-gopher to decide which of several candidates is the right one. ' +
  ORDER_PARTS;
const RUN_TEXT =
  'task-gopher checkpoint: a test, build or lint run. task-gopher:task-gopher: "run <cmd>, report failures only, at most 30 lines". ' +
  ORDER_PARTS;
const DATA_TEXT =
  'task-gopher checkpoint: a command likely to print data. task-gopher:task-gopher: "run <cmd>, return <what>". ' +
  ORDER_PARTS;

/**
 * One row per kind of direct retrieval the strict gate can fire on. The gate
 * classifies with `patterns` (a stage of the command matches any of them; `view`
 * has `leadPatterns`, matched only by a stage that starts the command; `read` is
 * a tool and `script` a `leads` interpreter), the directive's legwork list must contain `words`, and
 * `deny` is the checkpoint reason shown for that kind. `runner` is the agent
 * the reason recommends first.
 */
export const CATEGORIES = [
  { id: "read", words: "Read", runner: "task-gopher:task-gopher", deny: READ_TEXT, patterns: [] },
  { id: "search", words: "grep/rg", runner: "task-gopher:task-gopher", deny: SEARCH_TEXT, patterns: [/\b(grep|rg|ack|ag)\b/] },
  { id: "find", words: "rg/find", runner: "task-gopher:task-gopher", deny: SEARCH_TEXT, patterns: [/\bfind\b/] },
  {
    id: "git-read",
    words: "git log/diff/show/blame",
    runner: "task-gopher:task-gopher",
    deny:
      'task-gopher checkpoint: you are reading history or a diff. task-gopher:task-gopher for "list commits touching P since D"; task-gopher:smart-gopher for "what changed here and does it matter". ' +
      ORDER_PARTS,
    patterns: [/\bgit\s+(diff|log|show|blame|grep)\b/],
  },
  {
    id: "test",
    words: "test, build",
    runner: "task-gopher:task-gopher",
    deny: RUN_TEXT,
    patterns: [/\b(npm|yarn|pnpm|bun)\s+test\b/, /\b(pytest|jest|vitest|tox|nox)\b/, /\b(cargo|go)\s+test\b/],
  },
  {
    id: "build",
    words: "build and lint runs",
    runner: "task-gopher:task-gopher",
    deny: RUN_TEXT,
    patterns: [/\b(npm|yarn|pnpm|bun)\s+run\s+(build|lint)\b/, /\b(cargo|go)\s+build\b/, /\b(make|gradle|gradlew|mvn)\b/],
  },
  {
    id: "view",
    words: "cat/head/tail",
    runner: "task-gopher:task-gopher",
    deny: DATA_TEXT,
    patterns: [],
    // a reader counts only as the first command of a stage list: `git push | tail` trims output, `tail FILE` reads it
    leadPatterns: [/\b(cat|head|tail|bat|less)\b/],
  },
  {
    id: "script",
    words: "scripts (python3/node/perl/sed)",
    runner: "task-gopher:task-gopher",
    deny: DATA_TEXT,
    patterns: [],
    // a command whose first word is one of these is labelled script, whichever stage fired the gate
    leads: ["python", "python3", "node", "perl", "ruby", "sed", "awk"],
  },
];

/** The mod's one-or-two-line checkpoint for a category id; an unknown id gets the generic data text. */
export function checkpointShort(id, escalated) {
  const row = CATEGORIES.find((c) => c.id === id) || CATEGORIES.find((c) => c.id === "script");
  const lead = row.deny.split(/(?<=[.!?])\s+/).slice(0, 2).join(" ");
  return `${escalated ? "That is 3 direct calls this turn. " : ""}${lead} Re-run the same call to proceed.`;
}

/** The checkpoint reason for a category id; an unknown id gets the generic data text. */
export function checkpointReason(id, escalated) {
  const row = CATEGORIES.find((c) => c.id === id) || CATEGORIES.find((c) => c.id === "script");
  return `${escalated ? ESCALATED_LEAD + " " : ""}${row.deny} ${EXCEPTION_LINE}`;
}
