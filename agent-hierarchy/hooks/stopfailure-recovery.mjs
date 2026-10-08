#!/usr/bin/env node
/**
 * agent-hierarchy — StopFailure: a turn ended on an API error. Records it as the session's
 * activity `failed` (docs/status-file.md) so the dispatch watcher can resume the session after a
 * backoff, or escalate. Recorded for every non-subagent session in a checkout with a hierarchy
 * dir, with or without a role: the Orchestrator is often a plain session, and the watcher must
 * see its own failure.
 *
 * For an Orchestrator whose failure will not be resumed (a non-retryable error, a spent retry
 * budget, or no watcher alive), it also asks the terminal for a desktop notification, since
 * waking a session whose API is failing only fails again.
 *
 * Never blocks, never writes anything but that output, fails open: any error exits 0 silently.
 */

import { basename } from "node:path";

import { hierarchyDir, isSubagent, logHookError, readHookInput } from "./lib-config.mjs";
import { readPeerRecords, watcherAlive } from "./lib-peer.mjs";
import { errorKind, MAX_RESUMES, oneLine, RETRYABLE, SAME_FAILURE_MS, streakFor, transcriptPathOk } from "./lib-recovery.mjs";
import { ownedTeams } from "./lib-roster.mjs";
import { readSessionRole } from "./lib-session-role.mjs";
import { readActivityRecord, recordActivity } from "./lib-status.mjs";

try {
  const input = await readHookInput();
  if (input && input.hook_event_name === "StopFailure" && !isSubagent(input) && typeof input.session_id === "string" && input.session_id) {
    const sessionId = input.session_id;
    const cwd = typeof input.cwd === "string" && input.cwd ? input.cwd : process.cwd();
    const dir = hierarchyDir(cwd);
    // The payload names the kind `error` in the types and `error_type` in the docs.
    const error = errorKind(input.error ?? input.error_type);
    const details = oneLine(input.error_details ?? input.error_message, 300);
    const code = oneLine(typeof input.error_code === "string" ? input.error_code : "", 40);
    const nowMs = Date.now();
    const current = readActivityRecord(dir, sessionId);
    const failedMs = current && current.activity === "failed" ? Date.parse(current.failed_at) : NaN;
    let failedAt = new Date(nowMs).toISOString();
    // The streak is the resumes already emitted for this session, not a counter an end of turn could reset.
    let streak = streakFor(readPeerRecords(), sessionId, nowMs);
    if (current && current.activity === "failed" && current.source === "transcript" && Math.abs(nowMs - failedMs) <= SAME_FAILURE_MS) {
      // The transcript detector saw this same end first: one failure, seen twice.
      streak = Number.isInteger(current.streak) && current.streak > 0 ? current.streak : streak;
      failedAt = current.failed_at;
    }
    const transcript = transcriptPathOk(input.transcript_path);
    recordActivity(dir, sessionId, {
      activity: "failed",
      extra: { error, error_details: details || null, error_code: code || null, source: "stopfailure", failed_at: failedAt, streak, transcript_path: transcript },
    });

    const orchestrator = ownedTeams(dir, { pid: Number(process.env.CLAUDE_PID) || process.ppid, sessionId }).length > 0 || readSessionRole(sessionId) === "orchestrator";
    if (orchestrator && (!RETRYABLE.has(error) || streak > MAX_RESUMES || !watcherAlive(sessionId))) {
      const label = oneLine(basename(cwd), 40).replace(/[^\x20-\x7e]/g, "").replace(/;/g, "") || "session";
      const text = `ah: ${label} stopped on an API error (${error.replace(/[^A-Za-z0-9_]/g, "")})${streak > MAX_RESUMES ? `, after ${MAX_RESUMES} retries` : ""}. Open it to continue.`.slice(0, 120);
      // OSC 9 desktop notification, then BEL.
      process.stdout.write(JSON.stringify({ terminalSequence: `\u001b]9;${text}\u0007\u0007` }));
    }
  }
} catch (err) {
  logHookError("stopfailure-recovery.mjs", err);
}
process.exit(0);
