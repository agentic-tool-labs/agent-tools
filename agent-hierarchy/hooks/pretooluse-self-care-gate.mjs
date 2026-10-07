#!/usr/bin/env node
/**
 * agent-hierarchy — PreToolUse Bash gate for roles that have a shell only for self-care.
 *
 * A gated role (the built-in architect, and any custom role whose registry row says
 * `shell: "self-care"`) may run exactly the ah CLI commands that look after the agent itself:
 * `roster.mjs checkin|whoami|status` and `msg.mjs new --type response` for its own brief, plus the
 * read-only msg listings. Everything else is refused, whatever the user's permission settings say
 * about it. This is a role-discipline tripwire, not a security boundary: the user's permission
 * settings stay the boundary, and the gate is fail-open if hooks are off or this file cannot load.
 *
 * The gate only ever refuses or stays silent. It never emits an approving decision: that would
 * skip the user's own permission prompt for a command this gate merely did not object to.
 *
 * Attribution: a main-thread call belongs to the direct role, else the session's persisted one.
 * A subagent call belongs to its direct role only, so an architect's own legwork subagents are
 * untouched while an architect-role subagent has no shell at all.
 */

import { existsSync, realpathSync } from "node:fs";
import { basename, dirname, join, resolve } from "node:path";

import {
  hierarchyDir,
  isBuiltinRole,
  isSubagent,
  isTeamAliasShape,
  logHookError,
  MSG_CLI,
  readHookInput,
  resolveConfig,
  resolveHierarchyRole,
  responseCommand,
  ROSTER_CLI,
  SELF_CARE_BUILTIN_ROLES,
  SELF_CARE_TOKEN_RE,
  SHELL_SELF_CARE,
} from "./lib-config.mjs";
import { readRoster } from "./lib-hier.mjs";
import { teamHomeDir } from "./lib-roster.mjs";

const TOKEN_RE = SELF_CARE_TOKEN_RE;
const MAX_COMMAND = 1024;

/** verb → allowed flags, per CLI. */
const VERBS = {
  roster: {
    checkin: ["cwd", "team"],
    whoami: ["cwd", "team"],
    status: ["cwd"],
  },
  msg: {
    new: ["type", "id", "to", "from", "req", "cwd", "to-name", "from-name"],
    list: ["cwd"],
    index: ["cwd"],
    downstream: ["cwd"],
    roster: ["cwd"],
  },
};

function deny(reason) {
  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: reason },
    })
  );
  process.exit(0);
}

function denyReason(extra, role) {
  return (
    `ah: your role has a shell for self-care only, so this command did not run${extra ? ` (${extra})` : ""}. Allowed: ` +
    `\`node ${ROSTER_CLI} checkin|whoami|status [--cwd <cwd>]\`, ` +
    `\`${responseCommand({ role })} [--cwd <cwd>]\`, ` +
    `\`node ${MSG_CLI} list|index|downstream|roster [--cwd <cwd>]\`; ` +
    "one plain command, no quotes, pipes or `=`, and every flag followed by its value. Anything else: delegate or report it."
  );
}

/** The gated role for this call, or null when the call is not the gate's business. */
function gatedRole(input) {
  const cwd = typeof input.cwd === "string" && input.cwd ? input.cwd : process.cwd();
  const hit = resolveHierarchyRole(input);
  const role = hit.role;
  if (!role) return null;
  if (isSubagent(input) && !hit.direct) return null;
  if (isBuiltinRole(role)) return SELF_CARE_BUILTIN_ROLES.has(role) ? role : null;
  const resolved = hit.resolved || resolveConfig(cwd);
  const entry = resolved && resolved.roles ? resolved.roles[role] : null;
  return entry && entry.shell === SHELL_SELF_CARE ? role : null;
}

const real = (p) => {
  try {
    return realpathSync(p);
  } catch {
    return null;
  }
};

/** The `team` of this session's latest roster row that carries one, or null. */
function sessionTeam(input, cwd) {
  const rows = readRoster(hierarchyDir(cwd)).filter((r) => r.session_id === input.session_id && typeof r.team === "string" && r.team);
  return rows.length ? rows[rows.length - 1].team : null;
}

/** A request path the response may answer: an existing `*--request.md` whose real directory is a msgs dir of this pool or its team home. */
function reqOk(req, cwd) {
  if (!req.endsWith("--request.md")) return false;
  const file = real(resolve(cwd, req));
  if (!file) return false;
  const pool = hierarchyDir(cwd);
  const dirs = [join(pool, "msgs"), join(teamHomeDir(pool), "msgs")].map(real).filter(Boolean);
  return dirs.includes(dirname(file));
}

/** Returns null when the command is a permitted self-care command, else a short reason. */
function refusal(input, role) {
  const cmd = input.tool_input.command;
  // A subagent's CLAUDE_PID is its parent session's, so no command is self-care for it.
  if (isSubagent(input)) return "";
  const cwd = typeof input.cwd === "string" && input.cwd ? input.cwd : process.cwd();
  if (typeof cmd !== "string" || cmd.length < 1 || cmd.length > MAX_COMMAND || /[\r\n]/.test(cmd) || cmd !== cmd.trim()) return "";
  const tok = cmd.split(/[ \t]+/);
  if (tok.some((t) => !TOKEN_RE.test(t))) return "";
  if (tok[0] !== "node") return "";
  const cli = tok[1] === ROSTER_CLI ? "roster" : tok[1] === MSG_CLI ? "msg" : null;
  if (!cli) return "";
  const allowed = VERBS[cli][tok[2]];
  if (!Object.prototype.hasOwnProperty.call(VERBS[cli], tok[2] || "") || !allowed) return "";
  const flags = new Map();
  for (let i = 3; i < tok.length; i += 2) {
    const name = tok[i].startsWith("--") ? tok[i].slice(2) : null;
    const value = tok[i + 1];
    if (!name || !allowed.includes(name) || flags.has(name) || value === undefined || value.startsWith("-")) return "";
    flags.set(name, value);
  }
  if (flags.has("cwd") && flags.get("cwd") !== input.cwd && flags.get("cwd") !== real(input.cwd)) return "";
  const verb = tok[2];
  if (cli === "roster" && flags.has("team")) {
    if (!isTeamAliasShape(flags.get("team"))) return "";
    if (verb === "checkin" && flags.get("team") !== sessionTeam(input, cwd)) return "";
  }
  if (cli === "msg" && verb === "new") {
    if (flags.get("type") !== "response" || flags.get("from") !== role || !flags.has("req")) return "";
    if (!reqOk(flags.get("req"), cwd)) return "";
  }
  return null;
}

let input = null;
let role = null;
try {
  input = await readHookInput();
  if (input && (!input.tool_name || input.tool_name === "Bash")) role = gatedRole(input);
} catch (err) {
  logHookError("pretooluse-self-care-gate.mjs", err);
}
if (!role) process.exit(0);

try {
  const why = refusal(input, role);
  if (why !== null) deny(denyReason(why, role));
} catch (err) {
  logHookError("pretooluse-self-care-gate.mjs", err);
  deny(denyReason("internal error", role));
}
process.exit(0);
