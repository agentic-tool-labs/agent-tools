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
// A normal end of turn (Stop) clears the record's API-error streak; every other event carries it. The record also keeps
// the session's transcript path, for the watcher's backup detection of an API-error end (lib-recovery.mjs).
//
// Role sessions (the role sessionstart.mjs persisted for this session id), and any other session that already has a
// record (the StopFailure hook writes one for a plain session, which must then follow its next events), never a subagent.
// UserPromptSubmit and Stop also re-register a session whose latest roster row is a false `down` (healFalseDown).
// Never writes stdout, never blocks, always exits 0.
//
// ponytail: PostToolUse runs async, so it and the sync Stop are two writers for one record and the last
// rename wins. PostToolUse lands ~35 ms after its tool, long before the turn ends, so Stop lands last.

import { hierarchyDir, isSubagent, logHookError, mainHierarchyDir, readHookInput } from "./lib-config.mjs";
import { healFalseDown, SELF_STATE } from "./lib-hier.mjs";
import { readSessionRole } from "./lib-session-role.mjs";
import { transcriptPathOk } from "./lib-recovery.mjs";
import { appendSessionPid, readActivityRecord, recordActivity, statusChanged } from "./lib-status.mjs";

try {
  const input = await readHookInput();
  if (input && !isSubagent(input)) {
    const event = input.hook_event_name;
    const cwd = typeof input.cwd === "string" && input.cwd ? input.cwd : process.cwd();
    const dir = hierarchyDir(cwd);
    const sessionId = typeof input.session_id === "string" ? input.session_id : "";
    let recorded = false;
    // A prompt registers the session with its Claude process in the pool and in the main checkout, before the
    // refresh below, so a session that never had a SessionStart row is already listed as an owner.
    if (event === "UserPromptSubmit") {
      appendSessionPid(dir, sessionId, process.ppid);
      const mainDir = mainHierarchyDir(cwd);
      if (mainDir && mainDir !== dir) {
        appendSessionPid(mainDir, sessionId, process.ppid);
        statusChanged(mainDir);
      }
    }
    // A role session, or any session the StopFailure hook has already recorded: its failed record must follow what it does next.
    const role = sessionId ? readSessionRole(sessionId) : null;
    if (sessionId && (role || readActivityRecord(dir, sessionId))) {
      // PostToolUse means working again; recordActivity leaves a record already in that state alone.
      const activity = event === "PostToolUse" ? "working" : SELF_STATE[event];
      // A running member whose latest roster row is a false `down` re-registers at its next prompt or stop.
      if (role && (event === "UserPromptSubmit" || event === "Stop")) healFalseDown(dir, sessionId, process.ppid);
      // The transcript path lets the watcher read an API-error end the StopFailure hook missed; a normal end clears the failure streak.
      const transcript = transcriptPathOk(input.transcript_path);
      if (activity) recorded = recordActivity(dir, sessionId, { activity, blocked_by: event === "Notification" ? "permission" : null, tool: event === "PostToolUse" ? input.tool_name : null, extra: transcript ? { transcript_path: transcript } : null, resetStreak: event === "Stop" });
    }
    if (!recorded && (event === "UserPromptSubmit" || event === "Stop")) statusChanged(dir);
  }
} catch (err) {
  logHookError("activity.mjs", err);
}
process.exit(0);
