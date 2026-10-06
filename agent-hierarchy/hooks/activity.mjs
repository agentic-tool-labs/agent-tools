#!/usr/bin/env node
// agent-hierarchy — records a Claude role session's own activity for the hierarchy status file
// (docs/status-file.md), in <hier>/activity/<session_id>.json: UserPromptSubmit → working, Stop →
// idle, a permission prompt (Notification, matcher permission_prompt) → blocked, and PostToolUse →
// working again when the record says anything else. PostToolUse also records the tool's name (never its
// input) at most every TOOL_WRITE_INTERVAL_SEC, so the Pane can show the last finished tool. Every activity change refreshes status.json.
//
// UserPromptSubmit and Stop also refresh status.json in sessions that record nothing: a Claude peer
// files its report with the Write tool, which no ah hook sees, so its turn ending is what surfaces it.
//
// Role sessions only (the role sessionstart.mjs persisted for this session id), never a subagent.
// UserPromptSubmit and Stop also re-register a session whose latest roster row is a false `down` (healFalseDown).
// Never writes stdout, never blocks, always exits 0.
//
// ponytail: PostToolUse runs async, so it and the sync Stop are two writers for one record and the last
// rename wins. PostToolUse lands ~35 ms after its tool, long before the turn ends, so Stop lands last.

import { hierarchyDir, isSubagent, logHookError, readHookInput } from "./lib-config.mjs";
import { healFalseDown, SELF_STATE } from "./lib-hier.mjs";
import { readSessionRole } from "./lib-session-role.mjs";
import { recordActivity, statusChanged } from "./lib-status.mjs";

try {
  const input = await readHookInput();
  if (input && !isSubagent(input)) {
    const event = input.hook_event_name;
    const cwd = typeof input.cwd === "string" && input.cwd ? input.cwd : process.cwd();
    const dir = hierarchyDir(cwd);
    const sessionId = typeof input.session_id === "string" ? input.session_id : "";
    let recorded = false;
    if (sessionId && readSessionRole(sessionId)) {
      // PostToolUse means working again; recordActivity leaves a record already in that state alone.
      const activity = event === "PostToolUse" ? "working" : SELF_STATE[event];
      // A running member whose latest roster row is a false `down` re-registers at its next prompt or stop.
      if (event === "UserPromptSubmit" || event === "Stop") healFalseDown(dir, sessionId, process.ppid);
      if (activity) recorded = recordActivity(dir, sessionId, { activity, blocked_by: event === "Notification" ? "permission" : null, tool: event === "PostToolUse" ? input.tool_name : null });
    }
    if (!recorded && (event === "UserPromptSubmit" || event === "Stop")) statusChanged(dir);
  }
} catch (err) {
  logHookError("activity.mjs", err);
}
process.exit(0);
