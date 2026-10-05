#!/usr/bin/env node
/**
 * agent-hierarchy — Stop hook: Orchestrator-side liveness check-in (spec 0028
 * §5). A Stop hook that refuses to let the Orchestrator go quiet while it is
 * still owed a report from a peer it dispatched.
 *
 * "Is this the Orchestrator" is resolved the same way `pretooluse-route-gate.mjs`
 * already does (and the same direction `pretooluse-*-gate.mjs` now do via
 * `resolveHierarchyRole`, §3.2): a caller positively attributed as a
 * SUBORDINATE hierarchy role is definitely not the Orchestrator and is
 * skipped; everything else (no attribution at all — the common case for a
 * plain top-level session) proceeds, on the same fail-open-toward-enforcement
 * direction used throughout this plugin.
 *
 * §5.3 (r4, finding 3): outstanding dispatches are this session's own
 * `type:"dispatch"` records (lib-peer.mjs, written by
 * posttooluse-peer-resolve.mjs the moment this session sends a request
 * token) cross-referenced against the messages directory — NOT the
 * peer-pending obligation store, which is keyed on the RECIPIENT's
 * session_id and so cannot answer "did THIS session dispatch this", and
 * would miss a peer that died before ever receiving the brief.
 *
 * §5.5: mutually exclusive with `stop-peer-nudge.mjs` by role — a session
 * that itself OWES a report takes precedence over one that is OWED one;
 * this hook cedes whenever the session has ANY pending peer obligation,
 * regardless of turn-marker state. An armed-marker precondition check was
 * tried first and rejected as order-dependent on hooks.json's array order,
 * which nothing here can rely on holding. Ceding on `pendingFor().length > 0`
 * alone has no such dependency: it is a superset of the cases where peer-nudge
 * would actually block, and this hook staying silent on the rest costs
 * nothing.
 */

import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { hierarchyDir, isPaneMember, isSubagent, logHookError, readHookInput, resolveConfig, resolveHierarchyRole } from "./lib-config.mjs";
import { appendGate, CHECKIN_CADENCE, etaOf, openExchanges, readGates, readMsgFile, thresholdFor } from "./lib-hier.mjs";
import { dispatchOrigin, dispatchRecordsFor, pendingFor } from "./lib-peer.mjs";
import { readTeam, teamMemberByName } from "./lib-roster.mjs";

const ROSTER = join(dirname(fileURLToPath(import.meta.url)), "roster.mjs");

function allow() {
  process.exit(0);
}

function block(reason) {
  process.stdout.write(JSON.stringify({ decision: "block", reason }));
  process.exit(0);
}

/**
 * §5.3 (r4): open exchanges THIS session dispatched on the peer route — a
 * dispatch record for the exchange's id exists among this session's own
 * (§5.3's header comment) — past their `eta` threshold (§5.6, T13). A
 * subagent dispatch never goes through SendMessage, so it never gets a
 * dispatch record either — that alone is what excludes it here (T14), no
 * separate check needed.
 */
function outstandingDispatches(dir, resolved, sessionId, now) {
  const myDispatches = new Map(dispatchRecordsFor(sessionId).map((r) => [r.request_id, r]));
  const candidates = [];
  // A session that owns several live teams owes check-ins on each team's exchanges.
  const teams = resolved.ownedTeams && resolved.ownedTeams.length > 1 ? resolved.ownedTeams : [resolved.team];
  for (const e of teams.flatMap((team) => openExchanges(dir, team))) {
    if (!myDispatches.has(e.id)) continue; // no dispatch record from THIS session for this id (T14, T28)
    const parsed = readMsgFile(e.request.path);
    const fm = parsed && parsed.fm;
    if (fm && fm.from === "orchestrator") candidates.push({ e, fm });
  }
  const origins = dispatchOrigin(candidates.map(({ e, fm }) => ({ id: e.id, created: fm.created })));
  const out = [];
  for (const { e, fm } of candidates) {
    const origin = Date.parse(origins.get(e.id));
    if (!Number.isFinite(origin)) continue;
    const ageSec = Math.max(0, (now - origin) / 1000);
    const eta = etaOf(fm.eta);
    if (ageSec < thresholdFor(eta) * CHECKIN_CADENCE[0]) continue; // too young to flag (T13)
    out.push({ id: e.id, role: e.to, to_name: fm.to_name || "(unnamed)", path: e.request.path, ageSec, created: fm.created, eta, pane: paneMemberName(dir, fm, e.to) });
  }
  return out;
}

/** The name of the pane-driven member a request is addressed to (by to_name, then by role), else null. */
function paneMemberName(dir, fm, role) {
  const team = fm.team || null;
  const t = readTeam(dir, team);
  const member = teamMemberByName(dir, fm.to_name, team) || (t ? t.members.find((m) => m && m.role === role) : null);
  return isPaneMember(member) ? member.name : null;
}

/**
 * A dispatch is due for a check-in when it has never been nudged, or when the
 * gap CHECKIN_CADENCE gives for its next check-in has passed since its last
 * nudge: half a threshold before the second, a full one before each later one.
 *
 * This replaces a flat two-nudges-ever cap. That cap meant an Orchestrator
 * stopped being asked about a dispatch after the second check-in no matter how
 * long the peer had been silent — a peer that died on minute three was never
 * mentioned again, which is the opposite of what a liveness check is for. The
 * interval keeps asking for as long as the exchange stays open, while spacing
 * the asks so an Orchestrator mid-conversation is not blocked every turn.
 *
 * An unparseable or absent `ts` counts as due — nudging one extra time is the
 * harmless direction.
 */
function dueForNudge(gates, sessionId, item, now) {
  let lastTs = 0;
  let count = 0;
  for (const r of gates) {
    if (r.type !== "liveness-nudge" || r.session_id !== sessionId || r.request_id !== item.id) continue;
    const t = Date.parse(r.ts);
    if (!Number.isFinite(t)) return true;
    count++;
    if (t > lastTs) lastTs = t;
  }
  if (count === 0) return true;
  const gap = CHECKIN_CADENCE[Math.min(count, CHECKIN_CADENCE.length - 1)];
  return now - lastTs >= thresholdFor(item.eta) * gap * 1000;
}

function fmtAge(sec) {
  if (sec < 3600) return `${Math.floor(sec / 60)}m`;
  if (sec < 86400) return `${Math.floor(sec / 3600)}h`;
  return `${Math.floor(sec / 86400)}d`;
}

function checkInReason(items, cwd) {
  const panes = items.filter((it) => it.pane).length;
  const lines = [
    "ah: you have outstanding peer dispatch(es) past their eta threshold — check in before stopping:",
    ...items.map((it) => {
      const line = `- ${it.role} "${it.to_name}", request ${it.id}, sent ${fmtAge(it.ageSec)} ago (${it.path})`;
      if (!it.pane) return line;
      return `${line} — a pane member: check it with \`node "${ROSTER}" deliver ${it.pane} --req "${it.path}" --wait-only --timeout 10 --cwd "${cwd}"\` and act on its \`status\`: \`blocked\` → relay the prompt through AskUserQuestion and \`answer\`; \`not-live\` → surface it to the user; \`busy\` or \`timeout\` → it is still working; \`no-report\` → the member is idle with no report: re-deliver the brief or ping it; \`not-sent\` → the brief never arrived: send it with \`deliver\`; any other status → act as the returned \`message\` says.`;
    }),
    ...(panes === items.length ? [] : [`For each${panes ? " of the others" : ""}: call ListAgents to confirm the peer session is still alive, then SendMessage it a short status query.`]),
    "If it answers, work continues — nothing more to do here. If it is gone or silent after checking, that is a fact you (the conduit) should surface to the user.",
    "You will be asked again about anything still open after half an eta interval the first time, then every eta interval. To stop being asked, close the exchange: get the response, or park the dispatch by telling the user it is abandoned and writing its response file yourself.",
  ];
  return lines.join("\n");
}

try {
  const input = await readHookInput();
  if (isSubagent(input)) allow();

  const { role: callerRole, direct: callerDirect } = resolveHierarchyRole(input);
  if (callerDirect && callerRole) allow(); // positively a subordinate role — not the Orchestrator

  if (input.stop_hook_active === true) allow();

  const sessionId = typeof input.session_id === "string" ? input.session_id : "";
  // §5.5: the obligation this session OWES takes precedence — but spec 0031
  // §4.1a: a record armed by the widened msg-token path must NOT cede this
  // check, or a session receiving any msg-file request (including one
  // addressed to "orchestrator") would silently stop being held to its own
  // outstanding dispatches. A record with no `armed_by` predates the field
  // and is treated as sentinel-armed (existing behaviour), not msg-token.
  if (sessionId && pendingFor(sessionId).some((r) => r.armed_by !== "msg-token")) allow();

  const cwd = typeof input.cwd === "string" && input.cwd ? input.cwd : process.cwd();
  const resolved = resolveConfig(cwd, { sessionId: sessionId || undefined });
  if (!resolved.enabled) allow();

  const dir = hierarchyDir(cwd);
  const now = Date.now();
  const outstanding = outstandingDispatches(dir, resolved, sessionId, now);
  if (outstanding.length === 0) allow();

  const gates = readGates(dir);
  const toBlockOn = [];
  for (const item of outstanding) {
    if (!dueForNudge(gates, sessionId, item, now)) continue;
    appendGate(dir, { type: "liveness-nudge", session_id: sessionId, request_id: item.id });
    toBlockOn.push(item);
  }
  if (toBlockOn.length === 0) allow(); // nothing outstanding is due for a check-in yet

  block(checkInReason(toBlockOn, cwd));
} catch (err) {
  logHookError("stop-orchestrator-liveness.mjs", err);
  allow();
}
