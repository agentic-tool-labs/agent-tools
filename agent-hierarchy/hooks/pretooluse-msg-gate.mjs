#!/usr/bin/env node
/**
 * agent-hierarchy — PreToolUse dispatch gate: role briefs travel as files.
 *
 * A role dispatch — an Agent/Task spawn of architect / implementor / reviewer
 * / ultra-advisor, or a SendMessage carrying the `[hierarchy-peer-brief`
 * sentinel (a peer tasking) — must carry `[hierarchy-msg <abs request path>]`
 * naming an existing `--request.md` under `<dir>/msgs/` whose frontmatter is
 * `type: request` and whose `to:` matches the dispatched role. Otherwise the
 * call is DENIED with the exact steps to write the file and re-issue.
 *
 * Exempt: task-runner / task-gopher (errands stay inline), any subagent
 * context (`agent_id` set — nested dispatches are 0.30.0 territory), pings /
 * chat / replies (SendMessage without the sentinel), a disabled hierarchy,
 * and `msgs:"off"` in agent-hierarchy.json. Any internal error allows.
 *
 * Review-class intent check: a request whose `to:` is a review-class role must state its goal and
 * acceptance. It runs after every check above passes, and also on a SendMessage without the sentinel
 * that names a `--request.md` first, since peer briefs usually carry no sentinel.
 */

import { chainRoles, classProp, isSubagent, lookupRole, logHookError, MSG_CLI, readHookInput, resolveConfig, resolvedPeerTargets, resolveHierarchyRole, teamPrefix } from "./lib-config.mjs";
import { existsSync } from "node:fs";
import { isAbsolute } from "node:path";

import { extractMsgToken, hierarchyDir, parseMsgFilename, reviewIntentGap, reviewIntentReason, validateRequestToken } from "./lib-hier.mjs";
import { appendPeerRecord, parseSentinel, readPeerRecords, stripRef } from "./lib-peer.mjs";

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

function denyReason(role, why) {
  return [
    "ah: role dispatches carry their brief as a message file, not inline prose.",
    `1. node "${MSG_CLI}" new --to ${role || "<role>"} --from orchestrator --slug <slug> [--to-name <peer-or-agent name>] [--parent <id>] [--reason context|second-opinion|parallel]`,
    "2. Fill every section (bullets, no prose; keep every constraint verbatim; [0] tldr indexes the rest).",
    "3. Re-issue this exact dispatch with first line: [hierarchy-msg <path>] then ≤3 TL;DR lines. Peer briefs keep the [hierarchy-peer-brief ...] sentinel too.",
    `Reason this call was denied: ${why}.`,
  ].join("\n");
}

const NOTIFY_REASON = (id) =>
  `ah: dispatch with \`notify_when_idle: true\`, so that a peer going idle wakes you even if it never reports. Re-send this exact SendMessage with \`notify_when_idle: true\` added. If the tool rejects that field for this target, re-send without it; request ${id} will not be asked about again.`;

/** A request dispatch to a peer carries `notify_when_idle: true`; denied once per (session, request id), then it passes either way. */
function denyWithoutIdleNotice(input, toolInput) {
  const sessionId = typeof input.session_id === "string" ? input.session_id : "";
  const to = typeof toolInput.to === "string" ? stripRef(toolInput.to.trim()) : "";
  if (!sessionId || !to || to === "main" || toolInput.notify_when_idle === true) return;
  const path = extractMsgToken(typeof toolInput.message === "string" ? toolInput.message : "");
  const meta = path && path.endsWith("--request.md") ? parseMsgFilename(path) : null;
  if (!meta || meta.type !== "request") return;
  if (readPeerRecords().some((r) => r && r.type === "notify-deny" && r.session_id === sessionId && r.request_id === meta.id)) return;
  appendPeerRecord({ type: "notify-deny", session_id: sessionId, request_id: meta.id, ts: new Date().toISOString() });
  decide("deny", NOTIFY_REASON(meta.id));
}

/** Holds the dispatch when the request it names is a review-class brief without its intent; otherwise returns. */
function denyWithoutIntent(path, resolved) {
  const missing = reviewIntentGap(path, resolved);
  if (missing) decide("deny", reviewIntentReason(path, missing, "re-issue this dispatch"), "ah: held a Reviewer dispatch until its brief states the intent; it will be re-sent.");
}

try {
  const input = await readHookInput();
  if (isSubagent(input)) decide(null);

  // Spec 0028 §3.2 primary fix: this gate is Orchestrator-only. A caller
  // positively attributed (§3.7) as a subordinate hierarchy role is not the
  // Orchestrator, so the gate must not fire for it — role agents never spawn
  // other gated roles in the first place (see agents/orchestrator.md).
  {
    const { role: callerRole, direct: callerDirect } = resolveHierarchyRole(input);
    if (callerDirect && callerRole) decide(null);
  }

  const toolName = input.tool_name;
  const isDispatch = toolName === "Agent" || toolName === "Task";
  const isSend = toolName === "SendMessage";
  if (!isDispatch && !isSend) decide(null);

  const toolInput = input.tool_input && typeof input.tool_input === "object" ? input.tool_input : {};
  const cwd = typeof input.cwd === "string" && input.cwd ? input.cwd : process.cwd();

  if (isSend) denyWithoutIdleNotice(input, toolInput);

  let role = null;
  let text = "";
  let sentinel = true;
  if (isDispatch) {
    const hit = lookupRole(toolInput.subagent_type, cwd);
    role = hit.role;
    if (!role || classProp(role, hit.resolved, "chain") !== true) decide(null);
    text = typeof toolInput.prompt === "string" ? toolInput.prompt : "";
  } else {
    text = typeof toolInput.message === "string" ? toolInput.message : "";
    sentinel = Boolean(parseSentinel(text));
  }

  const sessionId = typeof input.session_id === "string" && input.session_id ? input.session_id : "__nosession__";
  const resolved = resolveConfig(cwd, { sessionId: sessionId !== "__nosession__" ? sessionId : undefined });
  if (!resolved.enabled || resolved.msgs === "off") decide(null);

  // Not a peer tasking, so only the intent check applies, and only to a send whose first token names a request file.
  if (isSend && !sentinel) {
    const named = extractMsgToken(text);
    if (named && named.endsWith("--request.md") && isAbsolute(named) && existsSync(named)) denyWithoutIntent(named, resolved);
    decide(null);
  }

  if (isSend) {
    const to = typeof toolInput.to === "string" ? stripRef(toolInput.to.trim()) : "";
    // A session that owns several live teams matches the name against each team's prefix.
    const teams = resolved.ownedTeams && resolved.ownedTeams.length > 1 ? resolved.ownedTeams : [resolved.team];
    const prefixes = teams.map((t) => teamPrefix(cwd, t));
    role = chainRoles(resolved).find((r) => prefixes.some((p) => resolvedPeerTargets(r, resolved.roles[r], p).includes(to))) || null;
  }

  const dir = hierarchyDir(cwd);
  const check = validateRequestToken(text, dir, role);
  if (check.ok) {
    denyWithoutIntent(check.path, resolved);
    decide(null);
  }
  decide("deny", denyReason(role, check.why), "ah: held a role dispatch until its brief is written as a message file; it will be re-sent.");
} catch (err) {
  logHookError("pretooluse-msg-gate.mjs", err);
  decide(null);
}
