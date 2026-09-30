#!/usr/bin/env node
/**
 * agent-hierarchy — PreToolUse gate: the mutating roster CLI verbs must go
 * through the `ah:agent-team` skill at least once per session (spec 0042
 * §1.3). Keyed on the parsed Bash command since 0048 §2.4.3 — the ah CLIs
 * are invoked through the Bash tool and the MCP tool names are gone. The
 * gated verb set lives here alone and tests/check-gate-name-agreement.mjs
 * asserts it against hooks.json's matcher.
 *
 * Gated verbs: create, adopt, move, dismiss, disband, untrack — the
 * team-side lifecycle verbs. NOT gated: the single-member
 * spawn verbs (spawn-one, spawn-ad-hoc — one role-specified member is a
 * direct call whose safety checks live in the CLI itself), the read-only
 * verbs (show, teams, history, reap, resync, layout-splits), the
 * roster-TEMPLATE CRUD verbs, and layout / alias (only ever
 * called internally by the skill's own flow) are deliberately NOT in this
 * set. Nor is anything in msg.mjs.
 *
 * One-shot per session, recorded at DENY time: the immediate identical
 * retry always proceeds, whether or not the skill was actually consulted.
 * This gate's job is to make the skill unmissable once, not to police
 * compliance — a gate re-enterable indefinitely would deadlock a session
 * where the skill genuinely does not apply. Its `deny` outranks
 * pretooluse-ah-cli.mjs's `allow` (documented precedence, 0048 §2.4.4).
 *
 * A second rule, apart from the one-shot one: a role-pack trust commit (`role set … --from …` or
 * `role trust`, not a dry run) is asked of the user, or denied outside their own top-level session;
 * see `judgeTrustCommit`. It is checked on every call and fails closed.
 *
 * No subagent context: only an orchestrator session stands up Teams. Fails
 * OPEN (allow) on any parse/state-read error — the opposite of the
 * disband-close gate's fail-closed choice, because that gate guards an
 * irreversible destructive act and this one guards a procedural miss; a
 * crashing hook must never make roster operations unusable.
 */

import { isSubagent, logHookError, readHookInput, resolveHierarchyRole, ROSTER_CLI } from "./lib-config.mjs";
import { appendGate, hierarchyDir, pipelineRunLive, readGates } from "./lib-hier.mjs";
import { dirname, join } from "node:path";
import { isTrustCommit, parseAhCommand } from "./lib-ah-cli.mjs";

const VERBS = ["create", "adopt", "move", "dismiss", "disband", "untrack"];
const GATED_VERBS = new Set(VERBS);

function deny(reason, systemMessage) {
  process.stdout.write(
    JSON.stringify({
      systemMessage,
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "deny",
        permissionDecisionReason: reason,
      },
    })
  );
  process.exit(0);
}

function ask(reason) {
  process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "ask", permissionDecisionReason: reason } }));
  process.exit(0);
}

/**
 * The second rule: a commit that trusts role-pack content (`role set … --from …` or `role trust`,
 * without `--dry-run`) is the user's to approve, in Claude Code's own prompt, which a model can't
 * answer. Every such commit is judged, nothing is recorded, and it runs before the subagent exit.
 * The permission modes are those in which that prompt was seen to reach the user; a payload that
 * carries none is asked, and Claude Code decides.
 */
const ASK_MODES = new Set(["default", "acceptEdits", "auto", "plan", "dontAsk", "bypassPermissions"]);
const TRUST_REFUSED = "ah: BLOCKED — trusting role-pack content is the user's decision, made in their own top-level session.";

/** `cwds` are the command's `--cwd` and the session's own: a live run at either one denies, so a
    `--cwd` pointed elsewhere doesn't hide the run the session is in. */
function judgeTrustCommit(input, cwds) {
  if (isSubagent(input)) return { deny: `${TRUST_REFUSED} A subagent can't commit it; tell the user to run the command themselves.` };
  const { role } = resolveHierarchyRole(input);
  if (role && role !== "orchestrator") return { deny: `${TRUST_REFUSED} This is a ${role} session; tell your orchestrator, and the user runs it.` };
  if (process.env.AH_TEAM_FILE) return { deny: `${TRUST_REFUSED} This session is a team member; tell your orchestrator, and the user runs it.` };
  if (cwds.some((cwd) => pipelineRunLive(cwd))) return { deny: `${TRUST_REFUSED} A pipeline run is live in this checkout; adopt or trust pack roles once it has finished.` };
  const mode = input.permission_mode;
  if (typeof mode === "string" && !ASK_MODES.has(mode)) return { deny: `${TRUST_REFUSED} In permission mode ${JSON.stringify(mode)} the approval prompt isn't known to reach the user; switch to the default mode and run it again.` };
  return { ask: "ah: trusting role-pack content — approve only if you reviewed this role's dry run (its fields, tools and pin) yourself." };
}

const DENY_REASON = [
  "ah: BLOCKED — this command did not run.",
  "Team lifecycle operations (create/adopt/move/dismiss/disband/untrack on `hooks/roster.mjs`) are owned by the `ah:agent-team` skill, which encodes the roster levels, spawn layout, the team file check-in registry, and relocation rules that a raw CLI call skips. The `ah:agent-roster` skill covers the other half — editing the roster TEMPLATE (init/add/edit/remove/layout/alias) — and does not stand up or tear down anything.",
  'Invoke it: Skill with skill: "ah:agent-team". The skill may resolve this request differently than the command you were about to run — follow the skill, do not resume the original command by reflex.',
  `If Skill reports it is already loaded but its body is not in your context, Read ${join(dirname(dirname(ROSTER_CLI)), "skills", "agent-team", "SKILL.md")} instead.`,
  "Re-running the same command will proceed after that — this gate is one-shot per session.",
].join(" ");

/**
 * A session is un-denied when it has no gate record at all, or when its most recent one is a reset.
 * Compaction drops the skill body out of context while the old deny record still says the session
 * was told once, which would leave the agent with neither the body nor a way back to it.
 */
function alreadyDenied(dir, sessionId) {
  const mine = readGates(dir).filter((r) => r && r.type === "roster-skill-gate" && r.session_id === sessionId);
  const last = mine[mine.length - 1];
  return !!last && last.reset !== true;
}

try {
  const input = await readHookInput();
  if (input.tool_name !== "Bash") process.exit(0);
  const toolInput = input.tool_input && typeof input.tool_input === "object" ? input.tool_input : {};
  const parsed = parseAhCommand(toolInput.command);
  const cwdOf = () => (typeof parsed.flags.cwd === "string" && parsed.flags.cwd ? parsed.flags.cwd : typeof input.cwd === "string" && input.cwd ? input.cwd : process.cwd());
  if (isTrustCommit(parsed)) {
    // Fails closed, unlike the skill rule below: an error while judging denies.
    let verdict;
    try {
      const own = typeof input.cwd === "string" && input.cwd ? input.cwd : process.cwd();
      verdict = judgeTrustCommit(input, [...new Set([cwdOf(), own])]);
    } catch (err) {
      logHookError("pretooluse-roster-skill-gate.mjs", err);
      verdict = { deny: `${TRUST_REFUSED} The gate couldn't judge this command (${err && err.message ? err.message : String(err)}), so it is refused.` };
    }
    if (verdict.ask) ask(verdict.ask);
    deny(verdict.deny, "ah: refused a role-pack trust commit outside the user's own session.");
  }
  if (isSubagent(input)) process.exit(0);
  if (!parsed || parsed.script !== "roster" || !GATED_VERBS.has(parsed.verb)) process.exit(0);

  const cwd = cwdOf();
  const sessionId = typeof input.session_id === "string" && input.session_id ? input.session_id : "__nosession__";
  const dir = hierarchyDir(cwd);

  if (alreadyDenied(dir, sessionId)) process.exit(0);

  appendGate(dir, { type: "roster-skill-gate", session_id: sessionId });
  deny(DENY_REASON, "ah: held a team lifecycle command until the agent-team skill is loaded; it reruns after.");
} catch (err) {
  logHookError("pretooluse-roster-skill-gate.mjs", err);
  process.exit(0);
}
