#!/usr/bin/env node
/**
 * agent-hierarchy — PreToolUse gate on EnterWorktree for hierarchy roles.
 *
 * EnterWorktree moves a session's root. For a role session that splits ah's
 * state: its peer tracking then reads the worktree's own .claude/hierarchy
 * while its team keeps writing to the main checkout's. And if the worktree is
 * removed later, the session is stranded, because only the user can
 * ExitWorktree. A role works in a worktree by absolute path instead.
 *
 * One call is let through: a misplaced peer relocating to its team's
 * `expected_root`, which sessionstart.mjs's misplaced notice asks for. The
 * root is resolved with the same attributeSessionTeam call sessionstart.mjs
 * makes, so the gate and the notice never disagree.
 *
 * Enforced only on positive direct attribution, like the conduit gate: the
 * Orchestrator and unattributed sessions are always allowed. Any error outside
 * the relocation check fails open.
 */

import { realpathSync } from "node:fs";
import { logHookError, mainHierarchyDir, readHookInput, resolveHierarchyRole } from "./lib-config.mjs";
import { ensureHierarchyDir } from "./lib-hier.mjs";
import { attributeSessionTeam } from "./lib-roster.mjs";

function decide(decision, reason, systemMessage) {
  if (decision) {
    process.stdout.write(
      JSON.stringify({
        ...(systemMessage && { systemMessage }),
        hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: decision, permissionDecisionReason: reason },
      })
    );
  }
  process.exit(0);
}

const CALM = "ah: kept a role session out of a worktree; it works there by path instead.";

const REASON =
  "ah: hierarchy roles do not use EnterWorktree. It would move this session's root: ah's peer tracking would then read the worktree's own .claude/hierarchy, and if the worktree is removed later this session is stranded (only the user can ExitWorktree). This call was BLOCKED and did not run. Stay where you are and work in the worktree by absolute path: `cd <abs worktree> || exit 1; <cmd>` inside each Bash call, `git -C <abs worktree> …` for git, and absolute paths for Read, Edit and Write.";

function isRelocation(input, role) {
  try {
    const path = input.tool_input && input.tool_input.path;
    if (typeof path !== "string" || !path) return false;
    const cwd = typeof input.cwd === "string" && input.cwd ? input.cwd : process.cwd();
    const dir = ensureHierarchyDir(cwd);
    const resolved = attributeSessionTeam(dir, role, { paneId: process.env.HERDR_PANE_ID || process.env.TMUX_PANE || null, homes: [dir, mainHierarchyDir(cwd)] });
    const expectedRoot = resolved && resolved.team && resolved.team.expected_root;
    if (!expectedRoot) return false;
    return realpathSync(path) === expectedRoot;
  } catch {
    return false;
  }
}

try {
  const input = await readHookInput();
  if (input.tool_name !== "EnterWorktree") decide(null);
  const { role, direct } = resolveHierarchyRole(input);
  if (!direct || !role) decide(null);
  if (isRelocation(input, role)) decide(null);
  decide("deny", REASON, CALM);
} catch (err) {
  logHookError("pretooluse-worktree-gate.mjs", err);
  decide(null);
}
