#!/usr/bin/env node
/**
 * agent-hierarchy — SubagentStart/SubagentStop/PostToolUse(TaskStop, Bash,
 * Monitor)/UserPromptSubmit recorder for this session's in-flight background
 * work: subagents, background Bash tasks and Monitors.
 *
 * A peer that starts background work and ends its turn is waiting, not
 * finished; stop-peer-nudge.mjs reads these records (`hasInflightSubagent`)
 * to tell the two apart. Every kind is stored as a `subagent` record, with a
 * background Bash or Monitor task id in the `agent_id` field. The Subagent
 * events fire in the parent's hook set with the PARENT's session_id and the
 * subagent's agent_id, so those branches must not early-return on
 * `isSubagent` — agent_id is the id being recorded.
 *
 * - SubagentStart: append `started` only while the session owes a peer report,
 *   which keeps the store (every hook reads it whole) bounded to obligation
 *   windows.
 * - SubagentStop: append `stopped` only over a latest `started` for the same
 *   (session_id, agent_id), whether or not the obligation is still pending.
 * - PostToolUse(TaskStop): a subagent killed with TaskStop fires no
 *   SubagentStop, so its `started` would be orphaned. Candidate ids are
 *   `tool_response.task_id` (the harness's resolved id) then
 *   `tool_input.task_id` (which may be a name). When a candidate has records
 *   in this session, each such candidate still `started` is closed. A
 *   resolved `tool_response.task_id` with no record names an agent this
 *   session never counted (e.g. spawned before the obligation), so nothing is
 *   written and its recorded siblings stay in flight. Only when the response
 *   carries no `task_id` and the stopped task is or may be an agent
 *   (`task_type` absent, not a string, or "local_agent") is it unidentifiable;
 *   then every `started` agent of the session is closed, failing toward
 *   enforcement at the cost of a still-running sibling's exemption. In that
 *   no-id case, any other `task_type` (a background Bash task) writes nothing.
 * - PostToolUse(Bash, Monitor): a background Bash (`run_in_background: true`,
 *   id `tool_response.backgroundTaskId`) or a Monitor (id
 *   `tool_response.taskId`) started by the session itself, not a subagent,
 *   is recorded `started` under the same obligation-window rule as
 *   SubagentStart. A subagent's own task notifies the subagent, so its end
 *   would never reach this session. Foreground Bash returns before any store
 *   read, since this now runs on every Bash call.
 * - UserPromptSubmit: the `<task-notification>` that re-invokes the session
 *   marks a task's end. A block with status completed/failed/killed, or a
 *   Monitor event starting `[Monitor timed out` or `[Monitor expired` (a
 *   timeout with no output, which sends no status block), closes that id if it is still
 *   `started`; a mid-stream Monitor event or any other status leaves it open.
 *   This also closes a background subagent that ends with no SubagentStop.
 *   A prompt with no notification returns before any store read.
 *
 * Not gated on the hierarchy being enabled, because stop-peer-nudge.mjs is not
 * and the two must agree. Silent, never blocks, fails open.
 */

import { isSubagent, logHookError, readHookInput } from "./lib-config.mjs";
import { appendSubagentRecord, latestSubagentRecords, pendingFor } from "./lib-peer.mjs";

function closeStarted(sessionId, latest, agentIds) {
  for (const id of agentIds) {
    if (latest.get(id)?.status === "started") appendSubagentRecord(sessionId, id, "stopped");
  }
}

function onTaskStop(sessionId, input) {
  const request = input.tool_input && typeof input.tool_input === "object" ? input.tool_input : {};
  const response = input.tool_response && typeof input.tool_response === "object" ? input.tool_response : {};
  const candidates = [...new Set([response.task_id, request.task_id].filter((id) => typeof id === "string" && id))];
  if (candidates.length === 0) return;
  const latest = latestSubagentRecords(sessionId);
  const known = candidates.filter((id) => latest.has(id));
  if (known.length > 0) return closeStarted(sessionId, latest, known);
  const resolved = typeof response.task_id === "string" && response.task_id;
  const maybeAgent = typeof response.task_type !== "string" || response.task_type === "local_agent";
  if (!resolved && maybeAgent) closeStarted(sessionId, latest, latest.keys());
}

function backgroundTaskId(input) {
  const request = input.tool_input && typeof input.tool_input === "object" ? input.tool_input : {};
  const response = input.tool_response && typeof input.tool_response === "object" ? input.tool_response : {};
  let id = null;
  if (input.tool_name === "Bash") id = request.run_in_background === true ? response.backgroundTaskId : null;
  else if (input.tool_name === "Monitor") id = response.taskId;
  return typeof id === "string" && id ? id : null;
}

const TERMINAL_STATUSES = new Set(["completed", "failed", "killed"]);

function endedTaskIds(prompt) {
  const ended = new Set();
  for (const [, block] of prompt.matchAll(/<task-notification>([\s\S]*?)<\/task-notification>/g)) {
    const id = /<task-id>([\s\S]*?)<\/task-id>/.exec(block)?.[1].trim();
    if (!id) continue;
    const status = /<status>([\s\S]*?)<\/status>/.exec(block)?.[1].trim();
    const event = /<event>([\s\S]*?)<\/event>/.exec(block)?.[1];
    const monitorEnded = event?.startsWith("[Monitor timed out") || event?.startsWith("[Monitor expired");
    if (TERMINAL_STATUSES.has(status) || monitorEnded) ended.add(id);
  }
  return ended;
}

try {
  const input = await readHookInput();
  const sessionId = input.session_id;
  const event = input.hook_event_name;
  const agentId = input.agent_id;
  if (typeof sessionId === "string" && sessionId) {
    if (event === "PostToolUse") {
      if (input.tool_name === "TaskStop") onTaskStop(sessionId, input);
      else {
        const taskId = backgroundTaskId(input);
        if (taskId && !isSubagent(input) && pendingFor(sessionId).length > 0) appendSubagentRecord(sessionId, taskId, "started");
      }
    } else if (event === "UserPromptSubmit") {
      if (typeof input.prompt === "string" && input.prompt.includes("<task-notification>")) {
        const ended = endedTaskIds(input.prompt);
        if (ended.size > 0) closeStarted(sessionId, latestSubagentRecords(sessionId), ended);
      }
    } else if (typeof agentId === "string" && agentId) {
      if (event === "SubagentStart") {
        if (pendingFor(sessionId).length > 0) appendSubagentRecord(sessionId, agentId, "started");
      } else if (event === "SubagentStop") {
        closeStarted(sessionId, latestSubagentRecords(sessionId), [agentId]);
      }
    }
  }
} catch (err) {
  logHookError("subagent-inflight.mjs", err);
}
process.exit(0);
