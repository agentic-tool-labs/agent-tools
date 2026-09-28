#!/usr/bin/env node
/**
 * task-gopher — PreToolUse gate. Two independent jobs:
 *
 * RELAY (active whenever the plugin is ON): subagents inherit neither the
 * parent's context nor the SessionStart/UserPromptSubmit injections — the
 * dispatch prompt is the only channel that reaches them at spawn. So this hook
 * REWRITES the dispatch in flight: it returns `updatedInput` with the directive
 * prepended to the subagent's prompt. The parent never sees it, spends no
 * output tokens copying it, and there is no bounce — the harness hands the
 * spawned subagent a prompt that already carries the directive. (Verified live:
 * a probe agent dispatched with a 300-char prompt reported receiving a
 * 7300-char one opening with the tier gate.)
 *
 * Because PreToolUse also fires inside a subagent's own loop, a subagent
 * dispatching a grandchild gets the same rewrite — the chain is automatic and
 * needs no cooperation from any model.
 *
 * Skipped: dispatches to task-gopher itself (they ARE the delegation), agents
 * that cannot dispatch and so can do nothing with the directive — builtins by
 * name (Explore, Plan, statusline-setup, output-style-setup), anything the user
 * listed in RELAY_EXEMPT_FILE, and anything whose definition declares a `tools:`
 * allow-list without Agent/Task (see agent-tools.mjs) — and any prompt that
 * already carries the sentinel near the top, so a parent that pasted the
 * directive by hand is not made to carry it twice. The sentinel check is
 * top-anchored so a mid-prompt *mention* of it does not count as a relay.
 *
 * STRICT CHECKPOINT (requires strict mode on top of ON): nudges the agent to
 * consider dispatching to task-gopher before it does retrieval work itself.
 * This is the "double-check gate": a conscious, deliberate beat, not a hard
 * wall — re-running the same call proceeds.
 *
 * ESCALATION: rather than nudging only once per turn, it tracks CONSECUTIVE
 * bypasses. It blocks the first retrieval of a turn, then lets the next two
 * direct retrievals through silently, then RE-BLOCKS on the 3rd consecutive
 * bypass (and every 3rd after that). Dispatching to task-gopher resets the
 * streak — good behavior buys a clean slate. So an agent that keeps pulling
 * things into its own context gets re-checkpointed; an agent that delegates is
 * left alone.
 *
 * SCOPE: one streak per (session, agent, turn) — see `contextKey`. Each
 * subagent therefore gets its own checkpoint rather than spending the parent's
 * budget, which is deliberate: the directive applies to subagents too, and a
 * subagent that shares the parent's counter is almost never checkpointed at all
 * (the parent has usually spent the turn-start block before the subagent runs).
 * The cost is one extra round trip per retrieval-doing subagent; dispatches to
 * task-gopher itself are exempt at the top of the script, so the runner never
 * pays it.
 *
 * SMART-GOPHER GATE (active whenever the plugin is ON): each DISTINCT
 * smart-gopher dispatch prompt is checkpointed once per session — denied with
 * a nudge to reconsider whether task-gopher could do it instead — then the
 * IDENTICAL retry of that exact prompt goes straight through permanently. Any
 * OTHER smart-gopher prompt, even later in the same session, gets its own
 * fresh checkpoint: passing the gate buys trust for that one exact request,
 * not a blanket pass for the rest of the session. Keyed on a hash of the
 * prompt text, not the raw text, to keep the state log compact regardless of
 * order length. Unlike strict mode's checkpoint this needs no strict flag,
 * and unlike the turn-scoped checkpoint it never re-fires on the SAME request
 * once passed. Dispatches TO task-gopher are never gated this way; only
 * smart-gopher escalations are.
 *
 * DESTRUCTIVE GUARD (active whenever the plugin is INSTALLED, on or off): the
 * runner's own Bash calls are classified, and any stage that destroys local
 * state or leaves the machine raises a permission prompt so a PERSON accepts
 * the risk. It asks every time — including when the lead pre-authorized the
 * command with an `ALLOW-DESTRUCTIVE:` line, which appears IN the prompt as
 * context rather than skipping it, because one model vouching for another is
 * not informed consent. Where no prompt can reach a human (guard set to
 * `block`, or a permission mode like bypassPermissions/dontAsk/auto), it falls
 * back to denying unless that written authorization exists.
 *
 * Unlike everything else here it does not respect the ON toggle, because the
 * agent stays dispatchable when the delegation directive is off — and a runner
 * with unrestricted `rm -rf` is exactly as dangerous either way. See
 * destructive.mjs.
 *
 * HONEST LIMITS: neither the strict checkpoint nor the smart-gopher gate can
 * verify the agent *genuinely* reconsidered — a re-run always passes, and for
 * the smart-gopher gate that pass is permanent for that EXACT prompt text.
 * Matching is exact, not fuzzy: a trivially reworded retry (whitespace, a
 * changed word) is a different request and gets its own checkpoint — that
 * fails toward MORE checkpointing, never less, so it is a nuisance rather
 * than a hole. The gate also fails open with no session_id to scope it (same
 * convention as the strict checkpoint's turn key). And the relay depends on the harness
 * honoring `updatedInput` on the Agent tool; if a future version stops doing
 * so, delivery fails SILENTLY (the dispatch still succeeds, the subagent just
 * never sees the directive). None of the three ever fire inside either gopher
 * itself.
 *
 * Fails open on any error, unknown shape, or unwritable state — a broken gate
 * must never brick tools or block a dispatch.
 */

import { createHash } from "node:crypto";
import { appendFileSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { heredocSpans, isExempt, isHeredocWrite, nestedLookup } from "./action-exempt.mjs";
import { cannotDispatch } from "./agent-tools.mjs";
import { askMessage, classify, denyMessage, isAllowed, recordAllowances, sandboxEscape } from "./destructive.mjs";
import {
  FULL_DIRECTIVE,
  LOG_FILE,
  NUDGE_FILE,
  SENTINEL,
  agentGopherKind,
  canAskHuman,
  gopherKind,
  guardMode,
  isEnabled,
  isStrict,
  readRelayExempt,
  AH_ROLE_AGENTS,
  verbatimDenyMessage,
  verbatimReadHit,
} from "./directive.mjs";

// Re-block on the Nth consecutive bypass within a turn (N-1 pass silently).
const RENUDGE_AFTER = 3;

// A relayed directive leads the prompt, so the sentinel must appear this early;
// anywhere later is a mention, not a relay.
const SENTINEL_WINDOW = 200;

// Built-in subagents without the Agent tool: they can't act on the directive,
// so rewriting their prompt would only cost tokens. Built-ins ship with no
// definition file, so they are the one group that has to be named outright —
// everything else is decided from the agent's own `tools:` list or the user's
// exempt file. The hierarchy roles join them for a different reason: each
// role's md already carries the delegation rule, so the relay would only pay
// for it twice.
const RELAY_EXEMPT = new Set([
  "Explore",
  "Plan",
  "statusline-setup",
  "output-style-setup",
  ...AH_ROLE_AGENTS,
]);

/**
 * Why this dispatch must not be stamped, or "" to stamp it. Ordered cheapest
 * first: a name match, then a small file read, then resolving the agent's
 * definition off disk.
 */
function relaySkipReason(subagentType, cwd) {
  if (RELAY_EXEMPT.has(subagentType)) return "builtin";
  if (readRelayExempt().includes(subagentType)) return "user-exempt";
  if (cannotDispatch(subagentType, cwd)) return "no-dispatch-tool";
  return "";
}

const allow = () => process.exit(0);

/**
 * Rewrite the dispatch in flight. Passes the whole tool_input back with only
 * `prompt` changed, so it is correct whether the harness merges or replaces.
 */
const injectDirective = (toolInput) => {
  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        updatedInput: { ...toolInput, prompt: FULL_DIRECTIVE + "\n\n" + toolInput.prompt },
      },
    })
  );
  process.exit(0);
};

/** The sandbox guard's deny, written at the runner: rewrite pinned, or stop. */
function sandboxDenyMessage({ toplevel, stages, unset = [] }) {
  const shown = stages.slice(0, 5).map((s) => `  ${s}`);
  if (stages.length > 5) shown.push(`  …and ${stages.length - 5} more`);
  if (unset.length) {
    shown.push(
      `Unset here (each Bash call is a fresh shell, and this command never assigns them): ${unset.map((n) => `$${n}`).join(", ")}`
    );
  }
  return [
    `Sandbox guard (task-gopher): this command builds or uses a scratch repo, but these git writes name no scratch path. If any cd or mktemp in it fails, they run in the current directory, which is the real repository ${toplevel}:`,
    ...shown,
    "Nothing ran. Rewrite the command so it is self-contained and pinned:",
    "- Assign every variable inside this same command. Each Bash call is a fresh shell, so a path given only in your order's prose is NOT set.",
    '- Create the sandbox and stop if that failed: T=$(mktemp -d) && [ -n "$T" ] && [ -d "$T" ] || { echo "ABORT: no sandbox" >&2; exit 1; }',
    '- Name the scratch repo in every git write: git init -q "$T/r", then git -C "$T/r" <subcommand>. No bare git, no cd-then-git, and no git config user.* (export GIT_AUTHOR_NAME/EMAIL and GIT_COMMITTER_NAME/EMAIL instead).',
    "Do not rely on set -e. If you cannot tell what the sandbox path should be, stop and report that to your lead instead of guessing.",
  ].join("\n");
}

/**
 * Block the call. The user sees only `calm` (one grey line); the model gets
 * `reason` in full as the hook error.
 */
const deny = (reason, calm) => {
  process.stdout.write(
    JSON.stringify({
      systemMessage: calm,
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: reason,
      },
    })
  );
  process.exit(0);
};

/** Hand the decision to the user. The reason text is what they see in the dialog. */
const ask = (reason) => {
  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "ask",
        permissionDecisionReason: reason,
      },
    })
  );
  process.exit(0);
};

// Bash commands that are retrieval/search/read/heavy — the delegatable kind.
// (Plain state changes like git add/commit, mkdir, cd, echo are intentionally
// NOT gated: they aren't what floods context and aren't task-gopher's job.)
const RETRIEVAL_ANY = [
  /\b(grep|rg|ack|ag)\b/,
  /\bfind\b/,
  /\bgit\s+(diff|log|show|blame|grep)\b/,
  /\b(npm|yarn|pnpm|bun)\s+(test|run\s+build|run\s+lint)\b/,
  /\b(pytest|jest|vitest|tox|nox)\b/,
  /\b(cargo|go)\s+(test|build)\b/,
  /\b(make|gradle|gradlew|mvn)\b/,
];

/**
 * These count ONLY when they lead the command. `tail -50 app.log` reads a file;
 * `git push | tail -10` TRIMS output — which is the habit this plugin exists to
 * encourage, so gating it was backwards. Same for `cmd | head`, `... | less`.
 */
const READER_LEADING = [/\b(cat|head|tail|bat|less)\b/];

/**
 * A retrieval word inside a quoted span is text, not a command:
 * `git commit -m "add tail support"` is not a read, and neither is
 * `git commit -m "$(cat <<'EOF' ...)"`. Both were being blocked.
 */
function stripQuoted(cmd) {
  return cmd.replace(/'[^']*'/g, " ").replace(/"[^"]*"/g, " ");
}

/**
 * Match per pipeline/sequence stage rather than against the raw string, so a
 * word's POSITION decides what it means.
 */
function isRetrieval(payload) {
  const tool = payload.tool_name;
  if (tool === "Read" || tool === "Grep" || tool === "Glob") return true;
  if (tool !== "Bash") return false;

  const cmd = payload?.tool_input?.command;
  if (typeof cmd !== "string") return false;

  const stages = stripQuoted(cmd).split(/\|\||&&|[|;\n]/);
  if (
    stages.some(
      (stage, i) =>
        RETRIEVAL_ANY.some((re) => re.test(stage)) ||
        (i === 0 && READER_LEADING.some((re) => re.test(stage)))
    )
  ) {
    return true;
  }
  // Heredoc bodies no shell runs are blanked, keeping offsets, so each part
  // found in the masked text can be read back from `cmd` with its bodies.
  const spans = heredocSpans(cmd);
  let text = cmd;
  for (const h of spans) {
    if (h.data) text = text.slice(0, h.start) + text.slice(h.start, h.end).replace(/[^\n]/g, " ") + text.slice(h.end);
  }
  text = maskQuoted(text);
  return commandStarts(text).some(([from, to], n) => {
    if (!READER_LEADING.some((re) => re.test(text.slice(from, to)))) return false;
    if (n === 0) return true;
    // A later `cat` that only writes its own heredoc or here-string is not a reader.
    const bodies = spans.filter((h) => h.at >= from && h.at < to).map((h) => cmd.slice(h.start, h.end));
    return !isHeredocWrite(cmd.slice(from, to) + "\n" + bodies.join(""));
  });
}

/** stripQuoted's masking, with every quoted span blanked in place so offsets survive. */
const maskQuoted = (cmd) =>
  cmd.replace(/'[^']*'/g, (m) => " ".repeat(m.length)).replace(/"[^"]*"/g, (m) => " ".repeat(m.length));

/**
 * The [from, to) offsets of the parts that start a new command: the first, and each one
 * after `;`, `&&`, `||`, a newline, or a lone background `&`. A part after `|`
 * or `|&` is a pipe stage, where a reader only trims output. The `&` in `&&`,
 * `&>`, `>&`, `N>&M`, `<&` and `|&` is not a lone `&`.
 */
function commandStarts(text) {
  const starts = [];
  let from = 0;
  let startsCommand = true;
  const cut = (at, next, nextStarts) => {
    if (startsCommand) starts.push([from, at]);
    from = next;
    startsCommand = nextStarts;
  };
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    const next = text[i + 1];
    const prev = text[i - 1];
    if ((c === "|" && next === "|") || (c === "&" && next === "&")) { cut(i, i + 2, true); i++; continue; }
    if (c === "|" && next === "&") { cut(i, i + 2, false); i++; continue; }
    if (c === "|") { cut(i, i + 1, false); continue; }
    if (c === ";" || c === "\n") { cut(i, i + 1, true); continue; }
    if (c === "&" && next !== ">" && prev !== ">" && prev !== "<") { cut(i, i + 1, true); continue; }
  }
  cut(text.length, text.length, true);
  return starts;
}

const bashLooksUp = (command) => isRetrieval({ tool_name: "Bash", tool_input: { command } });

// A short description of WHAT the agent ran directly, for the audit log.
function detailOf(payload) {
  const t = payload.tool_input || {};
  switch (payload.tool_name) {
    case "Bash":
      return String(t.command || "").slice(0, 160);
    case "Read":
      return String(t.file_path || "");
    case "Grep":
      return String(t.pattern || "");
    case "Glob":
      return String(t.pattern || t.glob || "");
    default:
      return "";
  }
}

// Append one audit line. Never throws — logging must not break the tool.
function logEvent(entry) {
  try {
    let ts = "";
    try {
      ts = new Date().toISOString();
    } catch {
      ts = "";
    }
    appendFileSync(LOG_FILE, JSON.stringify({ ts, ...entry }) + "\n");
  } catch {
    // best-effort; drop on failure
  }
}

/**
 * Identifies ONE agent's streak within ONE turn. All three parts are load-
 * bearing: `prompt_id` alone is a turn but not a context, so the main agent and
 * every subagent it spawns shared a single counter — and `session_id` is what
 * keeps concurrent Claude Code sessions off each other's state, since
 * NUDGE_FILE is shared by every session under this HOME.
 *
 * Empty `agent_id` means the main session, which is a context like any other.
 */
function contextKey(payload) {
  const p = typeof payload.prompt_id === "string" ? payload.prompt_id : "";
  if (!p) return ""; // can't scope a turn -> caller fails open
  const s = typeof payload.session_id === "string" ? payload.session_id : "";
  const a = typeof payload.agent_id === "string" ? payload.agent_id : "";
  return `${s}|${a}|${p}`;
}

/**
 * Streak state is an append-only line log, NOT a single {pid, n} slot rewritten
 * in place. The slot was the bug: one shared record for the whole machine meant
 * any other context writing its own id made the next reader see a foreign turn
 * and re-fire the turn-start checkpoint — so the "just RE-RUN to proceed"
 * escape hatch this gate advertises did not actually work. Measured over five
 * days: 76% of turn-start checkpoints fired on a turn already in progress,
 * median 2.7 seconds after that turn's previous event.
 *
 * An O_APPEND write of a short line is atomic, so concurrent contexts queue
 * instead of clobbering. A bare key line is one bypass; `key\tR` resets the
 * streak to zero. Resets are markers rather than deletions because the log
 * cannot be rewritten safely, and because "seen but reset to 0" must stay
 * distinguishable from "never seen" — that distinction is exactly what tells a
 * re-run apart from a fresh turn.
 */
const RESET = "\tR";
const NUDGE_MAX_LINES = 400;

function readLines() {
  try {
    return readFileSync(NUDGE_FILE, "utf8").split("\n").filter(Boolean);
  } catch {
    return []; // absent or unreadable -> nothing seen yet
  }
}

/** Replay one context's lines: has it been checkpointed, and how many bypasses since its last reset. */
function readStreak(lines, key) {
  const reset = key + RESET;
  let seen = false;
  let n = 0;
  for (const line of lines) {
    if (line === key) {
      seen = true;
      n++;
    } else if (line === reset) {
      seen = true;
      n = 0;
    }
  }
  return { seen, n };
}

/** Compact once the log has grown well past what any live turn needs. */
function pruneIfLarge() {
  try {
    const lines = readLines();
    if (lines.length <= NUDGE_MAX_LINES * 2) return;
    const tmp = `${NUDGE_FILE}.${process.pid}.tmp`;
    writeFileSync(tmp, lines.slice(-NUDGE_MAX_LINES).join("\n") + "\n");
    renameSync(tmp, NUDGE_FILE); // rename is atomic; readers never see a partial file
  } catch {
    // best-effort: a skipped prune only costs disk
  }
}

function appendState(line) {
  try {
    mkdirSync(dirname(NUDGE_FILE), { recursive: true });
    appendFileSync(NUDGE_FILE, line + "\n");
    pruneIfLarge();
    return true;
  } catch {
    return false;
  }
}

/**
 * Per-request one-shot key for the smart-gopher escalation gate, in the same
 * NUDGE_FILE log as the turn-scoped checkpoint keys. Scoped to (session,
 * exact prompt text) via a hash, not the raw prompt, so one long order
 * doesn't bloat the log and two DIFFERENT prompts never collide by prefix.
 * The leading "SMARTGATE|" tag guarantees no collision with a `contextKey`
 * triple regardless of pipe count — a turn key never starts with that tag.
 */
function smartGateKey(sid, prompt) {
  const digest = createHash("sha256")
    .update(typeof prompt === "string" ? prompt : "")
    .digest("hex")
    .slice(0, 16);
  return `SMARTGATE|${sid}|${digest}`;
}

function smartGateMessage(prompt) {
  const preview = typeof prompt === "string" ? prompt.slice(0, 120) : "";
  return [
    "task-gopher: smart-gopher gate — new request, first attempt.",
    "",
    `You're about to dispatch smart-gopher for: "${preview}". Before you do: could task-gopher (Haiku) do this instead?`,
    "",
    "Reach for smart-gopher only when you cannot write a decision-free order for task-gopher, or when task-gopher already stopped on a genuine judgment gap — not because it seems more capable or the task merely touches several files.",
    "",
    "If you've considered that and smart-gopher is still the right call, RE-RUN the IDENTICAL dispatch to proceed. This checkpoints per distinct request, not per session: the exact same prompt goes straight through from here on, but any OTHER smart-gopher dispatch — even later in this same session — gets its own fresh checkpoint.",
  ].join("\n");
}

function nudgeMessage(payload, bypasses) {
  const what =
    payload.tool_name === "Bash"
      ? "this command (`" + String(payload?.tool_input?.command || "").slice(0, 80) + "`)"
      : "a " + payload.tool_name;
  if (bypasses >= RENUDGE_AFTER) {
    return [
      `task-gopher (strict) — checkpoint again: ${RENUDGE_AFTER} direct retrievals in a row this turn without dispatching.`,
      "",
      `You're about to run ${what}. You've been pulling tool output into your own context repeatedly — that's the drift this guards against. Batch the retrievals you still need into ONE task-gopher order instead of continuing.`,
      "",
      "If you genuinely must keep doing these yourself, RE-RUN to proceed. Dispatching to task-gopher clears this streak so the checkpoint stops recurring. (Haiku-tier: re-run; this isn't for you.)",
    ].join("\n");
  }
  return [
    "task-gopher (strict) — checkpoint for this turn.",
    "",
    `You're about to run ${what} directly. If you're Sonnet-tier or higher: could task-gopher do this retrieval instead? Bundle it with any other reads/greps/diffs you need this turn into ONE dispatched order and keep your own context clean.`,
    "",
    "If you've considered that and still want to do it yourself — it needs YOUR judgment, or it's a single trivial peek — just RE-RUN the exact same call. This won't ask again until you've done a few more direct retrievals. (Haiku-tier: this isn't for you — re-run.)",
  ].join("\n");
}

try {
  const raw = readFileSync(0, "utf8");
  if (!raw.trim()) allow();

  const payload = JSON.parse(raw);
  const pid = typeof payload.prompt_id === "string" ? payload.prompt_id : "";
  const aid = typeof payload.agent_id === "string" ? payload.agent_id : "";
  const sid = typeof payload.session_id === "string" ? payload.session_id : "";

  // Runs before the ON check: the guard protects against the agent, not against
  // the directive, and both agents exist whenever the plugin is installed.
  const runnerKind = agentGopherKind(payload);
  if (runnerKind) {
    const mode = guardMode();
    if (payload.tool_name === "Bash" && mode !== "off") {
      // Before the destructive path, and never an ask: the fix is always to pin
      // the write, so neither a human nor an ALLOW-DESTRUCTIVE line releases it.
      const escape = sandboxEscape(payload?.tool_input?.command, payload.cwd);
      if (escape) {
        logEvent({
          pid,
          aid,
          event: "destructive-blocked",
          agent: runnerKind,
          tool: "Bash",
          detail: escape.stages.join(" ; ").slice(0, 300),
          labels: ["unpinned scratch-repo git write"],
          why: "sandbox",
        });
        deny(
          sandboxDenyMessage(escape),
          "task-gopher: held a runner's scratch-repo git write that could have hit a real repo."
        );
      }

      const hits = classify(payload?.tool_input?.command);
      if (hits.length) {
        const detail = hits.map((h) => h.stage).join(" ; ").slice(0, 300);
        const labels = hits.map((h) => h.label);
        const preauthorized = hits.every((h) => isAllowed(sid, h.stage));

        // ASK, even when the lead pre-authorized. A lead's ALLOW-DESTRUCTIVE
        // line is one model vouching for another; the risk is the user's to
        // accept, so the authorization becomes CONTEXT IN the prompt rather
        // than a way around it.
        if (mode === "ask" && canAskHuman(payload)) {
          logEvent({ pid, aid, event: "destructive-ask", agent: runnerKind, tool: "Bash", detail, labels, preauthorized });
          ask(askMessage(hits, preauthorized, runnerKind));
        }

        // Either the guard is set to block outright, or the session runs in a
        // permission mode where no prompt reaches anyone. Both fall back to the
        // lead's written authorization as the only remaining release.
        if (!preauthorized) {
          const unaskable = mode === "ask" ? payload.permission_mode || "unknown" : "";
          logEvent({
            pid,
            aid,
            event: "destructive-blocked",
            agent: runnerKind,
            tool: "Bash",
            detail,
            labels,
            why: unaskable ? `no-human:${unaskable}` : "guard-mode:block",
          });
          deny(
            denyMessage(hits, unaskable, runnerKind),
            "task-gopher: held a destructive or outward-facing command from a delegated runner; it reports back instead."
          );
        }
        logEvent({ pid, aid, event: "destructive-allowed", agent: runnerKind, tool: "Bash", detail });
      }
    }
    allow(); // otherwise never gate either runner's own tool use
  }

  // Authorization is recorded before the ON check for the same reason the guard
  // runs there — a guard that is live while the plugin is off needs a release
  // valve that is live too.
  //
  // HONEST LIMIT: allowances are session-keyed, not agent-keyed (destructive.mjs
  // documents why — the child's agent_id does not exist yet when the dispatch is
  // stamped). An ALLOW-DESTRUCTIVE line written for one gopher releases the same
  // command for the OTHER gopher too, for the rest of the session. Fixing that
  // needs per-agent keying, which is impossible at stamp time.
  if (payload.tool_name === "Agent" || payload.tool_name === "Task") {
    const t = payload.tool_input || {};
    const st = typeof t.subagent_type === "string" ? t.subagent_type : "";
    const kind = gopherKind(st);
    if (kind) {
      const authorized = recordAllowances(sid, t.prompt);
      if (authorized.length) {
        logEvent({
          pid,
          aid,
          event: "destructive-allowance",
          agent: kind,
          tool: payload.tool_name,
          detail: authorized.join(" ; ").slice(0, 300),
        });
      }
    }
  }

  if (!isEnabled()) allow();

  const key = contextKey(payload);

  if (payload.tool_name === "Agent" || payload.tool_name === "Task") {
    const t = payload.tool_input || {};
    const st = typeof t.subagent_type === "string" ? t.subagent_type : "";

    // A dispatch to either gopher is the desired outcome: never rewritten (they
    // cannot dispatch onward, so the directive would be pure waste), and it
    // resets the strict-mode consecutive-bypass streak (reward good behavior).
    const target = gopherKind(st);
    if (target) {
      // Runs before the smart-gate checkpoint: an order that cannot be allowed
      // at all should not first spend a checkpoint deciding which runner gets
      // it. Stateless and unconditional — a hit is denied every time, in every
      // session, because a retry pass would teach rewording rather than
      // narrowing (spec 0001 §3, user ruling).
      const verbatim = verbatimReadHit(t.prompt);
      if (verbatim) {
        logEvent({
          pid,
          aid,
          event: "verbatim-deny",
          agent: target,
          tool: payload.tool_name,
          detail: `${verbatim.rule}: ${verbatim.text.slice(0, 120)}`,
        });
        deny(
          verbatimDenyMessage(t.prompt, verbatim),
          "task-gopher: held a dispatch that asks a gopher to copy whole files; the order will be narrowed."
        );
      }

      // Least-privilege-first: each DISTINCT smart-gopher prompt gets a
      // one-shot checkpoint, same speed-bump philosophy as the strict
      // retrieval checkpoint but scoped to (session, exact prompt), not the
      // turn, and independent of strict mode. task-gopher is never gated
      // this way. A different prompt is a different request — no blanket
      // session-wide pass.
      if (target === "smart-gopher" && sid) {
        const gateKey = smartGateKey(sid, t.prompt);
        if (!readLines().includes(gateKey)) {
          if (appendState(gateKey)) {
            logEvent({
              pid,
              aid,
              event: "smart-gate-checkpoint",
              tool: payload.tool_name,
              detail: typeof t.prompt === "string" ? t.prompt.slice(0, 160) : "",
            });
            deny(
              smartGateMessage(t.prompt),
              "task-gopher: paused a smart-gopher dispatch to check a cheaper runner fits; re-running proceeds."
            );
          }
          // appendState failed (unwritable state) -> fail open, fall through
        }
      }
      if (key) {
        appendState(key + RESET);
        logEvent({ pid, aid, event: "dispatch", agent: target, tool: payload.tool_name, detail: st });
      }
      allow();
    }

    // Logged rather than silent: a skip that fires wrongly is invisible from the
    // outside — the dispatch still succeeds, the subagent just never sees the
    // directive — so the audit log is the only place it can be caught.
    const skip = relaySkipReason(st, payload.cwd);
    if (skip) {
      logEvent({ pid, aid, event: "relay-skip", tool: payload.tool_name, detail: st, reason: skip });
      allow();
    }

    if (typeof t.prompt !== "string") allow(); // unexpected payload shape -> fail open
    if (t.prompt.slice(0, SENTINEL_WINDOW).includes(SENTINEL)) {
      logEvent({ pid, aid, event: "relay-ok", tool: payload.tool_name, detail: st });
      allow(); // already carries it — don't double up
    }

    logEvent({ pid, aid, event: "relay-injected", tool: payload.tool_name, detail: st });
    injectDirective(t);
  }

  if (!isStrict()) allow();
  // A lookup nested inside a command (a substitution, `bash -c`, `eval`) counts
  // too. An exempt command is then passed like any non-retrieval: nothing is
  // added to the streak state, but a use the patterns flagged is logged.
  const flagged = isRetrieval(payload);
  const command = payload?.tool_input?.command;
  if (!flagged && !(payload.tool_name === "Bash" && nestedLookup(command, bashLooksUp))) allow();
  if (payload.tool_name === "Bash" && isExempt(command)) {
    if (flagged) logEvent({ pid, aid, event: "exempt", tool: "Bash", detail: detailOf(payload) });
    allow();
  }
  // Its advice is to dispatch, which an agent without Agent/Task can't do; the deny would only cost it a turn.
  if (cannotDispatch(payload.agent_type, payload.cwd)) allow();
  if (!key) allow(); // can't scope a turn -> fail open

  const { seen, n } = readStreak(readLines(), key);
  const tool = payload.tool_name;
  const detail = detailOf(payload);

  // First retrieval by THIS agent in this turn: the checkpoint. Only block if
  // the mark persists, else the re-run would re-trigger forever.
  if (!seen) {
    if (!appendState(key + RESET)) allow();
    logEvent({ pid, aid, event: "checkpoint", kind: "turn-start", tool, detail });
    deny(
      nudgeMessage(payload, 0),
      "task-gopher: paused one direct lookup to suggest delegating it; re-running proceeds."
    );
  }

  // Already checkpointed this turn: this retrieval is a bypass.
  const next = n + 1;
  if (next >= RENUDGE_AFTER) {
    if (!appendState(key + RESET)) allow(); // reset streak; re-block once
    logEvent({ pid, aid, event: "checkpoint", kind: "escalated", bypasses: next, tool, detail });
    deny(
      nudgeMessage(payload, next),
      "task-gopher: paused again after several direct lookups in a row; re-running proceeds."
    );
  }

  if (!appendState(key)) allow(); // record the bypass and allow
  logEvent({ pid, aid, event: "bypass", n: next, tool, detail });
  allow();
} catch {
  allow(); // fail open, always
}
