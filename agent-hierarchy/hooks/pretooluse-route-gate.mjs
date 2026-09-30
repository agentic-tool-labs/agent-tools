#!/usr/bin/env node
/**
 * agent-hierarchy — PreToolUse route gate: who may dispatch an ah role, and how + tier rule.
 *
 * Role sessions and subagents (Agent/Task, and SendMessage peer briefs): a subordinate role
 * session (its own `up` row carries a role other than orchestrator) or any subagent (hook input
 * with `agent_id`) never dispatches a peer-eligible ah role — an Agent/Task spawn of one, or a
 * sentinel-bearing SendMessage brief to one, is DENIED EVERY TIME with route-back text: the need
 * goes back to the Orchestrator as NEEDS-<ROLE> / NEEDS-EVIDENCE. Legwork (`ah:task-runner`,
 * `task-gopher:*`), non-ah agent types, replies, and every other subagent tool call pass
 * untouched. A session whose own identity cannot be resolved (no session_id) is treated as the
 * Orchestrator: `__nosession__` never matches sessionstart.mjs's `session_id: null` row, so
 * `upRecordFor` finds nothing and `selfRole` is null — the safe direction.
 *
 * `ah:orchestrator` as a subagent: denied for every caller. The Orchestrator is the top-level
 * session. A bare `orchestrator` agent ref is not ours and passes.
 *
 * Orchestrator, Agent/Task spawning a chain role: a chain role runs only as a peer, so this is a
 * wall, denied every time, and the reason is the whole instruction:
 *   - a live instance exists → SendMessage it (free ones first) with this brief;
 *   - none live, the role has a roster member → the exact `spawn-one` command;
 *   - none live, no roster member for the role → the exact `spawn-ad-hoc` command.
 * Legwork roles pass: they are the only roles that run as subagents. The hook never spawns:
 * launching panes from here would sidestep the session's own Bash permission prompts and race
 * the hook timeout.
 *
 * Orchestrator, SendMessage peer brief: passes the route gate. The brief's role resolves from
 * team records first (all teams, then the team file its request names), then config peer
 * targets, then the roster, then the name's role token.
 *
 * Orchestrator, any SendMessage, brief or not: a `to` with no `[ref]` that equals the name a
 * member of the session's own team was renamed away from (`renamed_from`) is DENIED, naming the
 * member's real name: another session holds that name. A name one of the team's records holds
 * is never denied.
 *
 * Any SendMessage whose `to` is a recorded non-claude pane member is DENIED with that member's
 * `roster.mjs deliver` command: SendMessage cannot reach it, and a Claude session that happens to
 * hold the same name must not receive its brief.
 *
 * Tier gate (Agent/Task, and SendMessage peer briefs carrying the sentinel +
 * `[hierarchy-msg`): when the session model is known, the target is architect
 * or ultra-advisor, that role's tier ≤ the session tier, and the request file
 * carries no `reason:` — DENIED ONCE per (session, role) with
 * `{type:"tier-deny", session_id, role}`. Second attempt passes. With
 * `msgs:"off"` there is no request file to carry `reason:`, so the denial
 * text drops the `reason:` instruction.
 *
 * Role packs: in bypassPermissions mode, an Agent/Task dispatch of the agent an adopted pack role
 * resolves to (a `from` row's, or a built-in's agent a pack overrides) is DENIED, available or not:
 * a pack role never runs with permission checks off.
 *
 * Fails open on an internal error, except that a dispatch of a built-in chain ref is denied: the
 * gate could not check it. So is a `<plugin>:<agent>` outside `ah:` in bypassPermissions mode, which
 * might be a pack role's. Runs after the ultra approval gate and the msg gate, which are
 * independent.
 */

import { chainRoles, classProp, hierarchyRoleOf, HOOK_ERROR_LOG, isSubagent, KIND_DEFAULT, logHookError, ownedTeamConfigs, packAgentRefs, readHookInput, resolveConfig, resolvedPeerTargets, resolveKind, ROLE_LABELS, roleLabel, ROSTER_CLI, roleFromName, rosterMemberFor, teamPrefix, tierOf } from "./lib-config.mjs";
import {
  appendGate,
  describeInstance,
  extractMsgToken,
  hasGate,
  hierarchyDir,
  messageHome,
  readMsgFile,
  roleTier,
  roster,
  sessionModel,
  upRecordFor,
} from "./lib-hier.mjs";
import { ownedTeams, resolveMemberTeam, teamArgName, teamMemberByName, teamMemberRenamedFrom } from "./lib-roster.mjs";
import { parseSentinel, stripRef } from "./lib-peer.mjs";

/** The registry this call resolved; labels for custom roles come from it. */
let registry = null;
const label = (role) => roleLabel(role, registry);

function decide(decision, reason, systemMessage) {
  if (decision || systemMessage) {
    const payload = {};
    if (decision) {
      payload.hookSpecificOutput = { hookEventName: "PreToolUse", permissionDecision: decision };
      if (reason) payload.hookSpecificOutput.permissionDecisionReason = reason;
    }
    if (systemMessage) payload.systemMessage = systemMessage;
    process.stdout.write(JSON.stringify(payload));
  }
  process.exit(0);
}

const PANE_SEND_CALM = "ah: held a SendMessage to a pane-run member; it will be briefed through the roster instead.";

const needsLabel = (role) => `NEEDS-${role.toUpperCase()}`;

function routeBackReason(role, subagent) {
  const where = subagent
    ? "Put it in your final report to the session that spawned you."
    : "Put it in your report: your response file, or your reply to the brief's reply-to.";
  return [
    `ah: role sessions and subagents do not dispatch ah roles (${label(role)} here) — only the Orchestrator does.`,
    `Route it back to your Orchestrator as ${needsLabel(role)} — or NEEDS-EVIDENCE when what you need is a run or a measurement — saying what is needed and why. ${where}`,
    "Legwork stays available: task-gopher:* and ah:task-runner.",
  ].join("\n");
}

const ORCHESTRATOR_REASON = "ah: The Orchestrator is the top-level session and never runs as a subagent. Do this orchestration here.";

/** The built-in chain refs, known without reading config — the only ones the gate can still
    recognise after it has failed. */
const BUILTIN_CHAIN_REFS = ["ah:orchestrator", "ah:ultra-advisor", "ah:architect", "ah:reviewer", "ah:implementor"];

/** A gate that failed has not checked the dispatch, and passing it would run a chain role as a
    subagent, so a built-in chain ref is denied. Built from the input alone: nothing here reads
    config or can throw again. Null for anything else, which stays fail-open. */
function failClosedReason(input) {
  const tool = input && input.tool_name;
  const ref = input && input.tool_input && typeof input.tool_input.subagent_type === "string" ? input.tool_input.subagent_type.trim() : "";
  if ((tool !== "Agent" && tool !== "Task") || !BUILTIN_CHAIN_REFS.includes(ref)) return null;
  const head = `ah: the route gate hit an internal error and could not check this dispatch (logged to ${HOOK_ERROR_LOG}).`;
  if (ref === "ah:orchestrator") return `${head} The Orchestrator never runs as a subagent.`;
  const role = ref.slice("ah:".length);
  const cwd = typeof input.cwd === "string" && input.cwd ? input.cwd : "<abs cwd>";
  // The owner rule alone still names each team when the session owns several, even though the
  // config around it could not be resolved.
  let owned = [];
  try {
    if (input.cwd) owned = ownedTeams(hierarchyDir(cwd), { pid: process.ppid, sessionId: typeof input.session_id === "string" ? input.session_id : null });
  } catch {
    owned = [];
  }
  const start = owned.length > 1
    ? `${owned.map((t) => `\`node "${ROSTER_CLI}" spawn-one ${role} --team ${teamArgName(t)} --cwd ${cwd}\``).join(" or ")}, the one for the team that owns this work`
    : `\`node "${ROSTER_CLI}" spawn-one ${role} --cwd ${cwd}\``;
  return `${head} ${ROLE_LABELS[role]} never runs as a subagent: SendMessage its live peer, or start one with ${start}.`;
}

/** Why a dispatch of pack role agent `ref` is held: the session runs with permission checks off. */
function packBypassReason(ref) {
  return `ah: ${ref} is the agent of a role adopted from a role pack, and a pack role never runs with permission checks off — this session is in bypassPermissions mode. Switch the session to another mode, or dispatch the built-in role instead.`;
}

/** When the gate failed: a `<plugin>:<agent>` outside `ah:` dispatched in bypassPermissions might be
    a pack role's, so it is held. Built from the input alone. Null for anything else. */
function packBypassFailClosedReason(input) {
  const tool = input && input.tool_name;
  const ref = input && input.tool_input && typeof input.tool_input.subagent_type === "string" ? input.tool_input.subagent_type.trim() : "";
  if ((tool !== "Agent" && tool !== "Task") || input.permission_mode !== "bypassPermissions") return null;
  if (!/^[^:\s]+:[^:\s]+$/.test(ref) || ref.startsWith("ah:")) return null;
  return `ah: the route gate hit an internal error and could not check this dispatch (logged to ${HOOK_ERROR_LOG}). ${packBypassReason(ref)}`;
}

function peersDenyReason(role, live, resolved, cwd) {
  const ordered = [...live.filter((i) => !i.busy), ...live.filter((i) => i.busy)];
  return [
    `ah: live ${label(role)} peer(s): ${ordered.map(describeInstance).join("; ")}.`,
    `ah roles are dispatched as peers: SendMessage "${ordered[0].name}" (set to_name) with the brief this Agent call carried, instead of spawning.`,
    ...paneLine(resolved, rosterMemberFor(resolved, role), cwd),
  ].join("\n");
}

/** Live peers of `role` across several owned teams, each named with its team. */
function teamPeersDenyReason(role, liveByTeam, cwd) {
  const named = liveByTeam.flatMap(({ team, live }) => live.map((i) => `${i.name} (team ${teamArgName(team)})`));
  return [
    `ah: live ${label(role)} peer(s): ${named.join(", ")}: SendMessage the one whose team owns this work (set to_name), with the brief this Agent call carried, instead of spawning.`,
    ...[...new Set(liveByTeam.flatMap(({ resolved }) => paneLine(resolved, rosterMemberFor(resolved, role), cwd)))],
  ].join("\n");
}

/** The command that starts `role`; `team` (null for the default team) adds that team's `--team`. */
function spawnCommand(role, member, cwd, team) {
  const scope = team === undefined ? "" : ` --team ${teamArgName(team)}`;
  if (member) return `node "${ROSTER_CLI}" spawn-one ${role}${scope} --cwd ${cwd}`;
  return `node "${ROSTER_CLI}" spawn-ad-hoc ${role}${scope} --cwd ${cwd}`;
}

function deliverCommand(name, reqPath, cwd) {
  return `node "${ROSTER_CLI}" deliver ${name} --req ${reqPath || "<request path>"} --cwd ${cwd}`;
}

function paneLine(resolved, member, cwd) {
  // A non-Claude member never appears in peers.jsonl, so it is never among the live instances this
  // gate lists; spawn-one is what reports it live.
  return member && (member.route || resolved.roster.route) === "pane"
    ? [`This member's route is pane: brief it with \`${deliverCommand("<name>", null, cwd)}\`, run in the background, not SendMessage — <name> is the name the spawn command prints, including when spawn-one reports it already live.`]
    : [];
}

/** A `to` that names a non-claude pane member: SendMessage cannot reach it, and a Claude session holding the same name must not get its brief. */
function paneSendReason(member, text, cwd) {
  return `ah: \`${member.name}\` runs in \`${resolveKind(member)}\` and cannot receive SendMessage. Brief it with \`${deliverCommand(member.name, extractMsgToken(text), cwd)}\`, run in the background.`;
}

const isPaneMember = (m) => Boolean(m) && resolveKind(m) !== KIND_DEFAULT && m.route === "pane";

function renamedReason(to, member) {
  return `${to} is not in your team; its ${label(member.role)} is ${member.name}. SendMessage "${member.name}". To reach the other session on purpose, address it with its [ref].`;
}

/** What the no-live-peer deny says after its spawn command. */
const SPAWN_FOLLOW_UP = [
  "Then SendMessage the `name` the command prints, with the brief you gave this Agent call. The session takes a few seconds to boot: if the name is not in ListAgents yet, wait until it is (`roster.mjs teams` reports it live).",
  "If the command reports the member already exists or is already live, SendMessage the name it reports.",
  'If the command refuses with `refused: "team-name-unusable"`, follow its `message`: ask the user for the team name, then re-run with `--team`. That is not a launch failure.',
  "If the command fails to launch, follow agent-team's 'When a role can't take the work'.",
];

function spawnReason(role, resolved, member, cwd, prefix) {
  return [
    `ah: no live ${label(role)} peer. ah chain roles run as peers, never subagents.`,
    `Run: ${spawnCommand(role, member, cwd)}`,
    `Before running it, run ListAgents and add \`--names-in-use <name>\` for every live name that starts with \`${prefix}-\`.`,
    ...SPAWN_FOLLOW_UP,
    ...paneLine(resolved, member, cwd),
  ].join("\n");
}

/** The no-live-peer deny for a session that owns several teams: each team's own spawn command. */
function teamSpawnReason(role, teamConfigs, cwd) {
  return [
    `ah: no live ${label(role)} peer. ah chain roles run as peers, never subagents.`,
    ...teamConfigs.map(
      ({ team, resolved }) =>
        `Team ${teamArgName(team)}: ${spawnCommand(role, rosterMemberFor(resolved, role), cwd, team)} — before running it, run ListAgents and add \`--names-in-use <name>\` for every live name that starts with \`${teamPrefix(cwd, team)}-\`.`
    ),
    "Run the one for the team that owns this work.",
    ...SPAWN_FOLLOW_UP,
    ...new Set(teamConfigs.flatMap(({ resolved }) => paneLine(resolved, rosterMemberFor(resolved, role), cwd))),
  ].join("\n");
}

function tierReason(model, tier, role, roleModel, roleTierN, msgsOff) {
  const escape = msgsOff
    ? "Do it inline, or re-issue this exact dispatch to proceed."
    : "Do it inline, or set reason: context|second-opinion|parallel in the request file and re-issue.";
  return `tier rule: you are ${model}(${tier}) ≥ ${label(role)} ${roleModel}(${roleTierN}). ${escape}`;
}

let input = null;
try {
  input = await readHookInput();
  const toolName = input.tool_name;
  const isDispatch = toolName === "Agent" || toolName === "Task";
  const isSend = toolName === "SendMessage";
  if (!isDispatch && !isSend) decide(null);

  const toolInput = input.tool_input && typeof input.tool_input === "object" ? input.tool_input : {};
  const subagentType = typeof toolInput.subagent_type === "string" ? toolInput.subagent_type.trim() : "";
  const cwd = typeof input.cwd === "string" && input.cwd ? input.cwd : process.cwd();
  const sessionId = typeof input.session_id === "string" && input.session_id ? input.session_id : "__nosession__";
  const resolved = resolveConfig(cwd, { sessionId: sessionId !== "__nosession__" ? sessionId : undefined });
  // A pack role never runs with permission checks off: dispatching an adopted role's agent, or a
  // built-in's agent a pack overrides, available or not, is held in bypassPermissions mode.
  if (isDispatch && input.permission_mode === "bypassPermissions" && packAgentRefs(resolved).has(subagentType)) {
    decide("deny", packBypassReason(subagentType), "ah: held a pack role's dispatch in bypassPermissions mode.");
  }
  if (!resolved.enabled) decide(null);
  if (isDispatch && subagentType === "ah:orchestrator") decide("deny", ORCHESTRATOR_REASON, "ah: the Orchestrator does not run as a subagent; this work stays in this session.");
  registry = resolved;
  const repoBasename = teamPrefix(cwd, resolved.team);
  const dir = hierarchyDir(cwd);
  // A session that owns several live teams: every lookup and check covers each of them.
  const teamConfigs = ownedTeamConfigs(resolved);
  const myTeams = teamConfigs ? teamConfigs.map((t) => t.team) : [resolved.team];
  const myPrefixes = teamConfigs ? teamConfigs.map((t) => teamPrefix(cwd, t.team)) : [repoBasename];

  const subagent = isSubagent(input);
  const selfRole = subagent ? null : (upRecordFor(dir, sessionId) || {}).role || null;
  const isSubordinateSession = selfRole !== null && selfRole !== "orchestrator";

  let rosterCache = null;
  const getRoster = () => rosterCache || (rosterCache = roster(dir, resolved, repoBasename));

  let role = null;
  let text = "";
  if (isDispatch) {
    role = hierarchyRoleOf(subagentType, { resolved });
    text = typeof toolInput.prompt === "string" ? toolInput.prompt : "";
  } else {
    text = typeof toolInput.message === "string" ? toolInput.message : "";
    const rawTo = typeof toolInput.to === "string" ? toolInput.to.trim() : "";
    const to = stripRef(rawTo);
    // The name a member was renamed away from belongs to another session, unless one of the team's
    // own records holds it too; only a `[ref]` says the sender means that other session.
    if (!subagent && !isSubordinateSession && to && to === rawTo && !myTeams.some((t) => teamMemberByName(dir, to, t))) {
      const renamed = myTeams.map((t) => teamMemberRenamedFrom(dir, to, t)).find(Boolean);
      if (renamed) decide("deny", renamedReason(to, renamed), "ah: held a message to a session outside your team; it goes to your team's member instead.");
    }
    if (to) {
      const anyTeam = resolveMemberTeam(dir, to);
      const named = anyTeam.found ? teamMemberByName(dir, to, anyTeam.team) : null;
      if (isPaneMember(named)) decide("deny", paneSendReason(named, text, cwd), PANE_SEND_CALM);
    }
    if (!parseSentinel(text)) decide(null);
    // Mechanism (A) — spec 0011 §4.4.1/§9.1: "what role is this name" is
    // answered by an all-teams name search, independent of `resolved.team` —
    // the team-scoped form has a silent-null failure mode when rung 2 misses.
    let teamDir = dir;
    let membership = to ? resolveMemberTeam(dir, to) : { found: false, team: null };
    if (to && !membership.found) {
      // The brief's request file names its team file by absolute path, so a session whose cwd
      // moved away from the checkout it spawned the teammate from still finds the record.
      const reqPath = extractMsgToken(text);
      const req = reqPath ? readMsgFile(reqPath) : null;
      const home = req ? messageHome(reqPath, req.fm) : null;
      if (home) {
        teamDir = home;
        membership = resolveMemberTeam(home, to);
      }
    }
    const teamMember = membership.found ? teamMemberByName(teamDir, to, membership.team) : null;
    if (isPaneMember(teamMember)) decide("deny", paneSendReason(teamMember, text, cwd), PANE_SEND_CALM);
    role = teamMember ? teamMember.role : null;
    if (!role) role = chainRoles(resolved).find((r) => myPrefixes.some((p) => resolvedPeerTargets(r, resolved.roles[r], p).includes(to))) || null;
    if (!role && to) {
      const rosters = teamConfigs ? teamConfigs.map((t) => roster(dir, t.resolved, teamPrefix(cwd, t.team))) : [getRoster()];
      role = chainRoles(resolved).find((r) => rosters.some((ros) => (ros[r] || []).some((i) => i.name === to))) || null;
    }
    if (!role && to) role = roleFromName(to, resolved);
  }
  const peerEligible = !!role && classProp(role, resolved, "chain") === true;

  // ---- role sessions and subagents: never dispatch an ah role, whatever the route or config
  if (subagent || isSubordinateSession) {
    if (peerEligible) decide("deny", routeBackReason(role, subagent), "ah: role sessions do not dispatch ah roles; the need goes back to the Orchestrator.");
    decide(null);
  }

  // ---- Orchestrator: a chain role runs only as a peer — the live one gets the brief, or one is spawned
  if (peerEligible && isDispatch) {
    if (teamConfigs) {
      const liveByTeam = teamConfigs
        .map((t) => ({ ...t, live: (roster(dir, t.resolved, teamPrefix(cwd, t.team))[role] || []).filter((i) => i.live) }))
        .filter((t) => t.live.length);
      if (liveByTeam.length) decide("deny", teamPeersDenyReason(role, liveByTeam, cwd), "ah: held a subagent dispatch of a chain role; it goes to a live peer instead.");
    }
    const live = teamConfigs ? [] : (getRoster()[role] || []).filter((i) => i.live);
    if (live.length) decide("deny", peersDenyReason(role, live, resolved, cwd), "ah: held a subagent dispatch of a chain role; it goes to the live peer instead.");
    const reason = teamConfigs ? teamSpawnReason(role, teamConfigs, cwd) : spawnReason(role, resolved, rosterMemberFor(resolved, role), cwd, repoBasename);
    decide("deny", reason, "ah: held a subagent dispatch of a chain role; a peer session will be started instead.");
  }

  // ---- tier gate: same-or-lower-tier Architect / Ultra-Advisor without a reason
  if (role && classProp(role, resolved, "tier") === true) {
    const model = sessionModel(input, dir);
    const tier = tierOf(model);
    if (tier !== null) {
      // Evaluated per owned team; the first team whose role model trips the rule decides, and is named.
      const scopes = teamConfigs || [{ team: resolved.team, resolved }];
      const hit = scopes.find((s) => {
        const t = roleTier(role, s.resolved, tier);
        return t !== null && t <= tier;
      });
      const rt = hit ? roleTier(role, hit.resolved, tier) : null;
      if (rt !== null && rt <= tier) {
        const path = extractMsgToken(text);
        const parsed = path ? readMsgFile(path) : null;
        const reason = parsed && parsed.fm ? parsed.fm.reason : null;
        if (!reason && !hasGate(dir, (r) => r.type === "tier-deny" && r.session_id === sessionId && r.role === role)) {
          appendGate(dir, { type: "tier-deny", session_id: sessionId, role });
          const from = teamConfigs ? ` (team ${teamArgName(hit.team)})` : "";
          decide("deny", tierReason(model, tier, role, hit.resolved.roles[role].model, rt, resolved.msgs === "off") + from, "ah: held a dispatch to a role at or below this session's tier; it will be justified or done here.");
        }
      }
    }
  }

  decide(null);
} catch (err) {
  logHookError("pretooluse-route-gate.mjs", err);
  const reason = packBypassFailClosedReason(input) || failClosedReason(input);
  decide(reason ? "deny" : null, reason, reason && "ah: the route gate could not check this dispatch, so it was held; see the hook error log.");
}
