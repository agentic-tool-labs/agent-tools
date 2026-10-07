#!/usr/bin/env node
/**
 * agent-hierarchy — SessionEnd roster writer.
 *
 * A top-level `--agent <hierarchy role>` peer session recorded `{status:"up"}`
 * at SessionStart; this appends the matching `{status:"down"}` when it ends.
 * The SessionEnd payload carries no `agent_type` (verified on v2.1.233:
 * session_id, transcript_path, cwd, prompt_id, hook_event_name, reason), so
 * the branch is: `agent_type` names a role, OR the roster's latest record for
 * this session_id is `up`. Anything else — an ordinary session, a subagent —
 * writes nothing. Fail-open.
 */

import { isSubagent, isTopLevelAgentSession, logHookError, lookupRole, readHookInput } from "./lib-config.mjs";
import { appendRosterRecord, hierarchyDir, pidAlive, upRecordFor } from "./lib-hier.mjs";
import { clearActivity } from "./lib-status.mjs";

try {
  const input = await readHookInput();
  if (!isSubagent(input)) {
    const cwd = typeof input.cwd === "string" && input.cwd ? input.cwd : process.cwd();
    const dir = hierarchyDir(cwd);
    const sessionId = typeof input.session_id === "string" ? input.session_id : "";
    let role = isTopLevelAgentSession(input) ? lookupRole(input.agent_type, cwd).role : null;
    const up = sessionId ? upRecordFor(dir, sessionId) : null;
    if (!role && up) role = up.role || null;
    // A session id can be resumed by a second process (a restored copy); only the registered
    // process, or any process once the registered one is dead, may mark the member down.
    const ender = process.ppid;
    const foreignEnd = up && up.pid !== ender && pidAlive(up.pid);
    if (!foreignEnd && sessionId) clearActivity(dir, sessionId);
    if (role && !foreignEnd) {
      appendRosterRecord(dir, { status: "down", role, session_id: sessionId || null, pid: ender, pane_id: (up && up.pane_id) || process.env.HERDR_PANE_ID || null, cwd });
    }
  }
} catch (err) {
  logHookError("sessionend-roster.mjs", err);
  // fail open
}
process.exit(0);
