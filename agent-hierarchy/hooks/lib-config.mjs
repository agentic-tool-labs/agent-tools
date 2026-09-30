#!/usr/bin/env node
/**
 * agent-hierarchy — config resolution + injected directive text.
 *
 * Two config scopes, both plain JSON at `.claude/agent-hierarchy.json`:
 *   - user:    ~/.claude/agent-hierarchy.json          (all repos)
 *   - project: <cwd>/.claude/agent-hierarchy.json      (committable)
 *
 * Resolution rules (from the design spec):
 *   - Merge is SHALLOW per role: a role object present in the project config
 *     replaces the user-scope role object entirely — no key-level deep merge.
 *   - `enabled`: most-specific scope wins (project overrides user).
 *   - `inherit` is a legal CONFIG value meaning "omit the `model` parameter on
 *     the Agent call". It is never emitted as a literal model value.
 *   - Invalid model → fall back to the role default + a one-line warning.
 *   - Missing `version` → treat as 1. A version newer than this plugin
 *     understands → that scope is ignored (with a note); if nothing valid is
 *     left, the session is treated as unconfigured.
 *   - Peer-eligible roles: missing `dispatch` → "peer" (preserves pre-dispatch-field
 *     behavior for every config written before it existed). Missing `peer` when
 *     dispatch is "peer" → "auto" (the "<repo>-<role>" convention). Invalid
 *     values for either → fall back the same way, with a warning.
 *
 * Run directly (`node lib-config.mjs`) to print the resolved status table for
 * the current working directory — that is what `/hierarchy status` uses.
 */

import { createHash } from "node:crypto";
import { appendFileSync, closeSync, existsSync, lstatSync, mkdirSync, openSync, readdirSync, readFileSync, readSync, renameSync, statSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";

// Cycle with lib-roster.mjs (which imports ROLES/VALID_MODELS_BY_ROLE from here): safe only
// because neither module touches the other's export at module top-level, only inside function
// bodies called later (statusReport here; validateMember/validateRosterBlock there). Keep it that
// way — a top-level use on either side would risk the top-level-await deadlock class documented
// in lib-roster.mjs's header.
import { legacyTeamPrefix, listTeamNames, memberTeam, readTeam, ROSTER_LAYOUT_VALUES, teamRosterEntry, teamRosterKey } from "./lib-roster.mjs";
import { normalizeSessionId } from "./lib-gate.mjs";
import { readSessionRole } from "./lib-session-role.mjs";

/** Absolute path to the escalation-gate CLI, resolved from this file so it survives wherever the plugin is installed. */
const GATE_CLI = join(dirname(fileURLToPath(import.meta.url)), "gate.mjs");
/** Absolute path to the message-file CLI, same resolution as GATE_CLI. */
export const MSG_CLI = join(dirname(fileURLToPath(import.meta.url)), "msg.mjs");
/** Absolute path to the roster CLI, same resolution as GATE_CLI/MSG_CLI. */
export const ROSTER_CLI = join(dirname(fileURLToPath(import.meta.url)), "roster.mjs");

let lastHookInput = null;

/** Where hook failures are recorded. Global, not per-repo: resolving a repo can itself be what threw. */
export const HOOK_ERROR_LOG = join(homedir(), ".claude", "hierarchy", "hook-errors.jsonl");
const HOOK_ERROR_CAP = 1024 * 1024;

/**
 * Append one line about a hook failure. Hooks decide nothing on this path and keep whatever
 * fail-open behaviour they had; without it a crashed hook and a hook that chose to stay silent look
 * identical, and Claude Code surfaces neither outside `--debug`.
 *
 * @param {string} hook basename of the entrypoint.
 * @param {unknown} err the thrown value.
 * @param {{session_id?: string, hook_event_name?: string}} [input] the parsed payload, when there is one.
 */
export function logHookError(hook, err, input = lastHookInput) {
  try {
    const line = {
      ts: new Date().toISOString(),
      hook,
      event: input && typeof input.hook_event_name === "string" ? input.hook_event_name : null,
      session_id: input && typeof input.session_id === "string" ? input.session_id : null,
      message: err instanceof Error ? err.message : String(err),
      stack: err instanceof Error && err.stack ? err.stack.split("\n").slice(1, 4).map((f) => f.trim()) : [],
    };
    mkdirSync(dirname(HOOK_ERROR_LOG), { recursive: true });
    try {
      if (statSync(HOOK_ERROR_LOG).size > HOOK_ERROR_CAP) renameSync(HOOK_ERROR_LOG, `${HOOK_ERROR_LOG}.1`);
    } catch {}
    appendFileSync(HOOK_ERROR_LOG, `${JSON.stringify(line)}\n`, "utf8");
  } catch {
    // The logger is the last link in the chain: if it throws, there is nowhere left to report to.
  }
}

/** Entries from the last `hours`, newest last. Unreadable or absent log reads as empty. */
export function recentHookErrors(hours = 24) {
  try {
    const cutoff = Date.now() - hours * 3600 * 1000;
    return readFileSync(HOOK_ERROR_LOG, "utf8")
      .split("\n")
      .filter(Boolean)
      .map((l) => { try { return JSON.parse(l); } catch { return null; } })
      .filter((e) => e && Date.parse(e.ts) >= cutoff);
  } catch {
    return [];
  }
}

let cachedVersion;

/** This plugin's version, or "?" when plugin.json cannot be read. Two roots in one context are told apart by it. */
export function pluginVersion() {
  if (cachedVersion === undefined) {
    try {
      cachedVersion = JSON.parse(
        readFileSync(join(dirname(dirname(ROSTER_CLI)), ".claude-plugin", "plugin.json"), "utf8")
      ).version || "?";
    } catch {
      cachedVersion = "?";
    }
  }
  return cachedVersion;
}

/** The `ah CLI root:` line appended to every SessionStart injection (spec 0048 §2.1): the absolute CLI paths, which only a hook can resolve. */
export function cliRootLine() {
  return (
    `ah CLI root (v${pluginVersion()}): ${dirname(dirname(ROSTER_CLI))} — roster: \`node ${ROSTER_CLI} <verb> --cwd <abs cwd>\`, ` +
    `messages: \`node ${MSG_CLI} <verb> --cwd <abs cwd>\` (verbs: agent-hierarchy/docs/cli-tools.md)`
  );
}

/** Message-file enforcement: "required" gates role dispatches and responses on message files; "off" disables both gates (CLI and listing stay). */
export const MSGS_MODES = ["required", "off"];

/**
 * Session dispatch-routing for chain roles: "peers" only — a chain role never runs as a subagent,
 * and with no live peer the gate's deny carries the spawn command. `resolveConfig` returns
 * `route: null` when no layer sets it; `effectiveRoute` then reads "peers". A "subagents" or
 * "prefer-peers" left in config or gates.jsonl from before is ignored.
 */
export const ROUTE_VALUES = ["peers"];
/** Route values that once opted chain roles into subagents: read as "peers", reported as stale. */
export const STALE_ROUTE_VALUES = ["subagents", "prefer-peers"];

/** Config schema version this plugin understands. */
export const CONFIG_VERSION = 1;

/**
 * Accepted model values, per class. `inherit` is accepted here and converted at
 * render time into "omit the model parameter" — it is NOT a legal Agent-tool
 * value and must never be passed through literally.
 *
 * design, review and implement are REASONING classes: haiku is never valid for
 * them — a Haiku-tier model cannot carry design, review, or implementation
 * judgment. Only legwork (no reasoning) may run on haiku.
 *
 * advise is the escalation apex: it exists only to bring MORE reasoning than
 * the design class already applied, so it takes top-tier models only and never
 * `inherit` — inheriting a Sonnet session would make the tier decorative, which
 * is the same argument that keeps haiku out of the reasoning classes. Its model
 * is always explicit.
 */
export const REASONING_MODELS = ["opus", "sonnet", "fable", "inherit"];
export const TOP_TIER_MODELS = ["fable", "opus"];

/**
 * The class table: the one place class behaviour lives. Every gate, the
 * directive, spawn and the validator read a role's behaviour from its class,
 * never from its name.
 *
 * - `chain`: peer-eligible, message-file gated, SubagentStop-nudged, handoff-confirmed.
 * - `tier`: the tier rule applies. `owesResponse`: a session of this class owes a response file.
 * - `ultraGate`: dispatches need the user's per-session approval.
 * - `roleDispatchable`: a role session may dispatch it (legwork only).
 * - `contract`: the tool contract the validator enforces on custom and overridden agents.
 *   `required` entries are a tool name or an array meaning "any one of these".
 *   `missingRecommended` names tools whose absence is a warning.
 */
export const CLASSES = {
  advise: {
    builtin: "ultra-advisor", step: "Escalate", models: TOP_TIER_MODELS,
    chain: true, tier: true, owesResponse: false, ultraGate: true, roleDispatchable: false,
    contract: { required: ["Read", "SendMessage"], forbidden: [], discouraged: ["Edit", "NotebookEdit", "advisor"], missingRecommended: [] },
  },
  design: {
    builtin: "architect", step: "Design", models: REASONING_MODELS,
    chain: true, tier: true, owesResponse: true, ultraGate: false, roleDispatchable: false,
    contract: { required: ["Read", "SendMessage", "Write"], forbidden: [], discouraged: ["Bash", "NotebookEdit", "advisor"], missingRecommended: [] },
  },
  review: {
    builtin: "reviewer", step: "Review", models: REASONING_MODELS,
    chain: true, tier: false, owesResponse: false, ultraGate: false, roleDispatchable: false,
    contract: { required: ["Read", "SendMessage"], forbidden: ["Edit", "Write", "NotebookEdit"], discouraged: ["advisor"], missingRecommended: ["Bash"] },
  },
  implement: {
    builtin: "implementor", step: "Implement", models: REASONING_MODELS,
    chain: true, tier: false, owesResponse: true, ultraGate: false, roleDispatchable: false,
    contract: { required: ["Read", "SendMessage", ["Edit", "Write"], ["Write", "Bash"]], forbidden: [], discouraged: ["advisor"], missingRecommended: ["Bash"] },
  },
  legwork: {
    builtin: "task-runner", step: null, models: [...REASONING_MODELS, "haiku"],
    chain: false, tier: false, owesResponse: false, ultraGate: false, roleDispatchable: true,
    contract: null,
  },
};
export const CLASS_NAMES = Object.keys(CLASSES);

/** The shipped built-in rows, in display order. Defaults mirror the agent-file frontmatter (implementor has no `model:` key). */
const BUILTIN_ROWS = [
  { name: "ultra-advisor", class: "advise", label: "Ultra-Advisor", defaults: { model: "fable" } },
  { name: "architect", class: "design", label: "Architect", defaults: { model: "opus" } },
  { name: "reviewer", class: "review", label: "Reviewer", defaults: { model: "opus" } },
  { name: "implementor", class: "implement", label: "Implementor", defaults: { model: "inherit" } },
  { name: "task-runner", class: "legwork", label: "Task-Runner", defaults: { model: "haiku", delegate: "task-gopher" } },
];

/** Built-in roles, in display order. Orchestrator is the session agent and is not configurable. */
export const ROLES = BUILTIN_ROWS.map((r) => r.name);
export const ROLE_LABELS = Object.fromEntries(BUILTIN_ROWS.map((r) => [r.name, r.label]));
export const ROLE_DEFAULTS = Object.fromEntries(BUILTIN_ROWS.map((r) => [r.name, { ...r.defaults }]));
export const VALID_MODELS_BY_ROLE = Object.fromEntries(BUILTIN_ROWS.map((r) => [r.name, CLASSES[r.class].models]));
const BUILTIN_CLASS = Object.fromEntries(BUILTIN_ROWS.map((r) => [r.name, r.class]));

/**
 * A roster member's agent kind (spec 0043 §1.1/§1.2) — which CLI Herdr starts
 * for it. Absent or null means `claude`; the default is total, so no consumer
 * may treat absent-kind as its own case.
 *
 * Shape-only validation, deliberately: Herdr owns the installed-kind list, it
 * is install- and version-specific, and an allowlist compiled in here would be
 * wrong the day a new kind ships. An unrecognized kind fails at spawn time,
 * where Herdr produces the authoritative error (§1.2).
 *
 * Lives here rather than in lib-roster.mjs (where the rest of the member
 * schema lives) because lib-config.mjs is the leaf: lib-roster.mjs imports
 * from it, so the reverse import would close the cycle documented at
 * lib-roster.mjs:22-26. lib-roster.mjs re-exports these for callers that read
 * the member schema from there.
 */
export const KIND_DEFAULT = "claude";
export const KIND_RE = /^[a-z][a-z0-9-]*$/;

/** A member's effective kind: absent/null resolves to `claude` (§1.1). Applied once, at the read seam. */
export function resolveKind(m) {
  const k = m && m.kind;
  if (k === undefined || k === null) return KIND_DEFAULT;
  return k;
}

/**
 * True when a member's route means "this member occupies a pane": `peer` (a
 * Claude session in a pane) and `pane` (spec 0043 §1.5 — driven through Herdr
 * agent-control rather than SendMessage). `subagent` members have no pane.
 *
 * Every pane-bearing decision — layout counts, launch, close, move, resync —
 * asks this, so adding a third pane-bearing route did not have to be spelled
 * out at each of those sites.
 */
export function routeHasPane(route) {
  return route === "peer" || route === "pane";
}

/**
 * Herdr's agent-name rule (spec 0043 §1.7, F6): `[a-z][a-z0-9_-]{0,31}`,
 * i.e. at most 32 characters. Returns `{ok: true}` or `{ok: false, why}`.
 *
 * Checked against the DERIVED name, at add/edit — not inside
 * `rosterMemberNames`, which runs on every roster read (SessionStart, the
 * route gate, `show`) where throwing would break reads that have nothing to
 * do with spawning.
 */
export function validateHerdrName(name) {
  if (typeof name !== "string" || !name) return { ok: false, why: "name must be a non-empty string" };
  if (!/^[a-z][a-z0-9_-]{0,31}$/.test(name)) {
    return {
      ok: false,
      why: `derived name ${JSON.stringify(name)} (${name.length} chars) does not match Herdr's agent-name rule [a-z][a-z0-9_-]{0,31} (max 32 characters) — create the team with a shorter \`--team <name>\`, or use a shorter role or --member name`,
    };
  }
  return { ok: true };
}

export const CONFIG_BASENAME = "agent-hierarchy.json";

/** Roster levels, in resolution precedence order (highest first). */
export const ROSTER_LEVELS = ["repo-user", "repo", "global"];

/** Model families ranked for the tier rule: a role at or below the session's own tier buys no extra reasoning. */
export const TIER = { haiku: 1, sonnet: 2, opus: 3, fable: 4 };

/** Family tier from `claude-<family>-…` or a bare family name; unknown → null. */
export function tierOf(model) {
  if (typeof model !== "string" || !model) return null;
  const m = model.toLowerCase().match(/(?:^|[^a-z])(haiku|sonnet|opus|fable)(?:[^a-z]|$)/);
  return m ? TIER[m[1]] : null;
}

/**
 * The tiers the user declared for non-Claude models: top-level `modelTiers` in the global config
 * only, `{"<kind>": {"<model>": "<haiku|sonnet|opus|fable>"}}`, because a model's strength does not
 * vary by repo. An entry for kind `claude`, or one naming no tier on `TIER`'s scale, is ignored with
 * a warning: a Claude model carries its own tier. Returns `{tiers, warnings}`.
 */
export function declaredModelTiers() {
  const warnings = [];
  const tiers = {};
  const path = userConfigPath();
  let data = null;
  try {
    const parsed = existsSync(path) ? JSON.parse(readFileSync(path, "utf8")) : null;
    data = parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : null;
  } catch {
    data = null;
  }
  const raw = data ? data.modelTiers : undefined;
  if (raw === undefined || raw === null) return { tiers, warnings };
  if (typeof raw !== "object" || Array.isArray(raw)) {
    warnings.push(`ah: modelTiers in ${path} is not an object of {"<kind>": {"<model>": "<tier>"}} — ignoring it.`);
    return { tiers, warnings };
  }
  for (const [kind, models] of Object.entries(raw)) {
    if (kind === KIND_DEFAULT) {
      warnings.push(`ah: modelTiers.claude in ${path} is ignored — a Claude model carries its own tier.`);
      continue;
    }
    if (!KIND_RE.test(kind) || !models || typeof models !== "object" || Array.isArray(models)) {
      warnings.push(`ah: modelTiers.${kind} in ${path} is not an object of {"<model>": "<tier>"} — ignoring it.`);
      continue;
    }
    for (const [model, tier] of Object.entries(models)) {
      if (typeof tier !== "string" || !Object.hasOwn(TIER, tier)) {
        warnings.push(`ah: modelTiers.${kind}.${model} in ${path} is ${JSON.stringify(tier)}, not a tier (${Object.keys(TIER).join(", ")}) — ignoring it.`);
        continue;
      }
      (tiers[kind] ||= {})[model] = tier;
    }
  }
  return { tiers, warnings };
}

/** The tier name declared for `model` of `kind`, or null. Never read from the model's name. */
export function declaredTier(kind, model) {
  const byModel = declaredModelTiers().tiers[kind];
  return byModel && typeof model === "string" && Object.hasOwn(byModel, model) ? byModel[model] : null;
}

/** A non-Claude member's model as status shows it: `<kind>:<model>(<declared tier>|?)`. */
export function nonClaudeModelText(m) {
  const kind = resolveKind(m);
  return `${kind}:${(m && m.model) || "?"}(${declaredTier(kind, m && m.model) || "?"})`;
}

/**
 * Flow control: who advances the chain. `auto` (default) — the Orchestrator
 * performs handoffs itself and reports. `confirm` — the Orchestrator asks the
 * user before each reasoning-role dispatch, so every handoff is a decision the
 * user makes. Legwork dispatches (Task-Runner / task-gopher) are exempt in
 * both modes: errands are not handoffs.
 */
export const HANDOFF_MODES = ["auto", "confirm"];

/**
 * Roles the Orchestrator dispatches as a named peer session (SendMessage),
 * never as a subagent unless the user opted in (`subagentOptIn`). Ultra-Advisor is included
 * because pretooluse-ultra-gate.mjs also watches SendMessage calls addressed
 * to its named peer, so the peer route is gated exactly like the subagent
 * route — see that file. Task-Runner is excluded: task-gopher is already its
 * dedicated fast path.
 */
export const PEER_ELIGIBLE_ROLES = ROLES.filter((r) => CLASSES[BUILTIN_CLASS[r]].chain);

/** The class of a role: a built-in's from the table (never from config), a custom row's from its resolved entry; null when unknown. */
export function roleClass(role, resolved) {
  if (BUILTIN_CLASS[role]) return BUILTIN_CLASS[role];
  const entry = resolved && resolved.roles && resolved.roles[role];
  return entry && CLASSES[entry.class] ? entry.class : null;
}

/** One class property of a role (see CLASSES), or undefined when the role is unknown. */
export function classProp(role, resolved, prop) {
  const c = roleClass(role, resolved);
  return c ? CLASSES[c][prop] : undefined;
}

export function isBuiltinRole(role) {
  return Object.prototype.hasOwnProperty.call(BUILTIN_CLASS, role);
}

/** Custom role names in the resolved registry, sorted by name. */
export function customRoleNames(resolved) {
  return resolved && resolved.roles ? Object.keys(resolved.roles).filter((r) => !isBuiltinRole(r)).sort() : [];
}

/** Every registry role: the built-ins in display order, then custom roles by name. */
export function registryRoles(resolved) {
  return [...ROLES, ...customRoleNames(resolved)];
}

/** Registry roles of a chain class (peer-eligible, gated, nudged), same order as registryRoles. */
export function chainRoles(resolved) {
  return registryRoles(resolved).filter((r) => classProp(r, resolved, "chain") === true);
}

export function roleLabel(role, resolved) {
  if (ROLE_LABELS[role]) return ROLE_LABELS[role];
  const entry = resolved && resolved.roles && resolved.roles[role];
  return (entry && entry.label) || role;
}

/**
 * The agent a role launches (`--agent`) and the name its sessions report as `agent_type`: a custom
 * row's `agent`, a built-in's validated override, else `ah:<role>`. Unlike `subagentType`, never the
 * task-runner delegate — a delegate is a dispatch substitution, not the role's identity.
 */
export function roleAgent(role, entry) {
  return entry && typeof entry.agent === "string" && entry.agent ? entry.agent : `ah:${role}`;
}

/** True when a built-in's entry names an agent other than its shipped `ah:<role>`. */
export function isOverride(role, entry) {
  return isBuiltinRole(role) && roleAgent(role, entry) !== `ah:${role}`;
}

/** The step's built-in for a class, e.g. `implement` → `implementor`. */
export function classBuiltin(cls) {
  return CLASSES[cls] ? CLASSES[cls].builtin : null;
}

/** Per-role dispatch route: "peer" dispatches to a peer session, spawning one when none is live; "model" always spawns a subagent. */
export const DISPATCH_MODES = ["peer", "model"];

/** The named-peer-session convention shared by the injected directive and the Ultra-Advisor gate: "<repo-basename>-<role>". */
export function peerName(repoBasename, role) {
  return `${repoBasename}-${role}`;
}

/**
 * Role tokens a peer session name may carry; `advisor` alone reads as
 * ultra-advisor. Lives here (not lib-hier.mjs) so `validateTeamAlias` below
 * can consult it without a circular import — lib-hier.mjs imports
 * `roleFromName` from here instead (spec 0010 §4.4 amendment (e)).
 */
const ROLE_TOKENS = [
  ["ultra-advisor", "ultra-advisor"],
  ["architect", "architect"],
  ["reviewer", "reviewer"],
  ["implementor", "implementor"],
  ["advisor", "ultra-advisor"],
];

/**
 * Peer-name parsing, pass 1: the longest registry role `r` (built-in or custom) such that `name`
 * ends with `-r` or `-r-<digits>` — returned only when it is a custom role. A built-in longest
 * match, or none, leaves the name to the built-in scan (pass 2), unchanged. Custom names never
 * take part in a substring match, so a custom `imp` cannot capture `repo-implementor`.
 */
export function customRoleFromSuffix(name, resolved) {
  if (typeof name !== "string" || !customRoleNames(resolved).length) return null;
  const base = name.replace(/-\d+$/, "");
  let best = null;
  for (const role of registryRoles(resolved)) {
    if (base.endsWith(`-${role}`) && (!best || role.length > best.length)) best = role;
  }
  return best && !isBuiltinRole(best) ? best : null;
}

/** The role a session name implies, or null: a suffix-anchored custom role, else a built-in role token (substring, in token order). */
export function roleFromName(name, resolved = null) {
  if (typeof name !== "string") return null;
  const custom = customRoleFromSuffix(name, resolved);
  if (custom) return custom;
  for (const [token, role] of ROLE_TOKENS) if (name.includes(token)) return role;
  return null;
}

/** Roles a hierarchy session name can carry in the built-in scan: the built-ins plus `orchestrator`, which owns a pane of its own even though it is never a roster member. */
const HIERARCHY_NAME_ROLES = [...ROLES, "orchestrator"];

/**
 * Split `<prefix>-<role>` / `<prefix>-<role>-<n>` into its parts, or null when the name is not one
 * a hierarchy session carries. Parsed from the RIGHT: a prefix may itself contain hyphens, so only
 * a trailing ordinal and the role token can be stripped, and what remains is the whole prefix.
 * A suffix-anchored custom role wins (see `customRoleFromSuffix`); otherwise the built-in scan.
 */
export function hierarchyNameParts(name, resolved = null) {
  if (typeof name !== "string" || !name) return null;
  const ordinal = name.match(/-(\d+)$/);
  const base = ordinal ? name.slice(0, -ordinal[0].length) : name;
  const custom = customRoleFromSuffix(name, resolved);
  const role = custom || HIERARCHY_NAME_ROLES.find((r) => base.endsWith(`-${r}`));
  if (!role) return null;
  const prefix = base.slice(0, -(role.length + 1));
  return prefix ? { prefix, role } : null;
}

/**
 * Every peer session name this role's config resolves to — `peer` may be a
 * single name or an array of names (several peers for one role). Empty when
 * the resolved `dispatch` is "model" (never route to a peer) or the role isn't
 * peer-eligible at all.
 */
export function resolvedPeerTargets(role, entry, repoBasename) {
  const cls = isBuiltinRole(role) ? BUILTIN_CLASS[role] : entry && entry.class;
  if (!CLASSES[cls] || !CLASSES[cls].chain) return [];
  if (!entry || entry.dispatch === "model") return [];
  if (Array.isArray(entry.peer)) return entry.peer.filter((p) => typeof p === "string" && p.trim());
  if (entry.peer && entry.peer !== "auto") return [entry.peer];
  return [peerName(repoBasename, role)];
}

/** The first roster member for `role`, in roster order, or null. */
export function rosterMemberFor(resolved, role) {
  const r = resolved && resolved.roster;
  return r && Array.isArray(r.members) ? r.members.find((m) => m && m.role === role) || null : null;
}

/** One-name convenience wrapper over `resolvedPeerTargets`: the first target, or null when there is none. */
export function resolvedPeerTarget(role, entry, repoBasename) {
  const targets = resolvedPeerTargets(role, entry, repoBasename);
  return targets.length ? targets[0] : null;
}

/** Read the hook's stdin JSON payload; returns {} if absent or unparseable. */
export async function readHookInput() {
  const chunks = [];
  for await (const chunk of process.stdin) chunks.push(chunk);
  const raw = Buffer.concat(chunks).toString("utf8").trim();
  if (!raw) return {};
  try {
    lastHookInput = JSON.parse(raw);
    return lastHookInput;
  } catch (err) {
    // Empty stdin is ordinary; stdin that arrived and would not parse is not, and the {} it
    // degrades to is indistinguishable from a plain main session.
    // 40 bytes is enough to recognise the shape; a longer prefix starts capturing the session id
    // and the transcript path a real payload carries.
    err.message = `${err.message} — unparseable payload, ${raw.length} bytes: ${raw.slice(0, 40)}`;
    logHookError("readHookInput", err, {});
    return {};
  }
}

/**
 * True for any subagent session.
 *
 * The discriminator is `agent_id`, which only a subagent carries. `agent_type`
 * is NOT usable for this: a top-level `claude --agent <plugin:name>` session
 * sets it too (verified on v2.1.223 — its SessionStart payload was
 * `session_id, transcript_path, cwd, agent_type, hook_event_name, source`,
 * with no `agent_id`), so testing `agent_type` classifies a genuine main
 * session as a subagent and suppresses the injection it should receive.
 *
 * Both subagent cases suppress every injection: an `ah:*` role
 * (hard recursion suppression, since subagents can nest up to three layers)
 * and any foreign subagent such as `task-gopher:task-gopher`.
 */
export function isSubagent(input) {
  const id = input && input.agent_id;
  return typeof id === "string" && id.length > 0;
}

/**
 * True for a session that carries an agent identity but is NOT a subagent —
 * i.e. the main session of a `claude --agent <name>` invocation.
 */
export function isTopLevelAgentSession(input) {
  const type = input && input.agent_type;
  return typeof type === "string" && type.length > 0 && !isSubagent(input);
}

/**
 * The identity lookup: the registry role an `agent_type` or `subagent_type` names, or null.
 *
 *   1. exactly `ah:<builtin>` → that built-in, with no config read;
 *   2. an exact match on a registry row's agent (`roleAgent`) → that row — a custom role, or a
 *      built-in whose agent is overridden. Claude Code reports a bare agent's name with no level
 *      marker, so which file a bare name denotes follows Claude Code's own project-over-user order;
 *   3. `<builtin>` or `*:<builtin>` → that built-in. A foreign `someplugin:architect` therefore
 *      reads as `architect`; that imprecision is accepted, because the text it selects is generic
 *      enough for the false positive to be harmless;
 *   4. otherwise null.
 *
 * Step 2 needs the registry: `opts.resolved` when the caller holds it, else it is resolved from
 * `opts.cwd` — lazily, only once step 1 has missed. With neither, step 2 is skipped.
 */
export function hierarchyRoleOf(agentType, opts = {}) {
  if (typeof agentType !== "string" || !agentType) return null;
  if (agentType.startsWith("ah:") && isBuiltinRole(agentType.slice(3))) return agentType.slice(3);
  let resolved = (opts && opts.resolved) || null;
  if (!resolved && opts && typeof opts.cwd === "string" && opts.cwd) {
    try {
      resolved = resolveConfig(opts.cwd);
    } catch {
      resolved = null;
    }
  }
  if (resolved && resolved.roles) {
    const hit = registryRoles(resolved).find((role) => roleAgent(role, resolved.roles[role]) === agentType);
    if (hit) return hit;
  }
  return ROLES.find((role) => agentType === role || agentType.endsWith(`:${role}`)) || null;
}

/**
 * `hierarchyRoleOf` for a hook that does not already hold the config: `{role, resolved}`, where
 * `resolved` is read only when the type is not `ah:<builtin>` (null otherwise, and whenever the
 * read fails). `classProp(role, resolved, …)` works on the result either way.
 */
export function lookupRole(agentType, cwd) {
  if (typeof agentType !== "string" || !agentType) return { role: null, resolved: null };
  if (agentType.startsWith("ah:") && isBuiltinRole(agentType.slice(3))) return { role: agentType.slice(3), resolved: null };
  let resolved = null;
  try {
    resolved = resolveConfig(cwd || process.cwd());
  } catch {
    resolved = null;
  }
  return { role: hierarchyRoleOf(agentType, { resolved }), resolved };
}

/**
 * Resolve the calling session's hierarchy role — spec 0028 §3.3/§3.7.
 * Returns `{ role, direct }`: `direct: true` only when the payload itself
 * identifies the caller (`agent_type`); otherwise falls back to the
 * session-id-keyed persisted map, with `direct: false`.
 *
 * A subagent shares its parent's session_id, so the persisted half answers
 * "what role is this session", not "what role is this caller" — a caller
 * that enforces policy MUST check `direct` and act only when it is true. Do
 * not collapse this to a bare role string; hiding `direct` invites the exact
 * defect §3.7 describes.
 */
export function resolveHierarchyRole(input, resolved = null) {
  const cwd = input && typeof input.cwd === "string" && input.cwd ? input.cwd : process.cwd();
  let direct = null;
  if (input && input.agent_type) {
    if (resolved) direct = hierarchyRoleOf(input.agent_type, { resolved });
    else ({ role: direct, resolved } = lookupRole(input.agent_type, cwd));
  }
  if (direct) return resolved ? { role: direct, direct: true, resolved } : { role: direct, direct: true };
  const persisted = readSessionRole(normalizeSessionId(input && input.session_id));
  return { role: persisted, direct: false };
}

export function userConfigPath() {
  return join(homedir(), ".claude", CONFIG_BASENAME);
}

/**
 * The layout a new team gets when its create names none: top-level `teamLayout` in the global
 * config file. It is a user preference, not repo config — a repo-level copy is one of
 * `staleTeamKeys` — and an invalid value is ignored. Returns `{layout, warnings}`; `layout` is null
 * when nothing usable is stored.
 */
export function teamLayoutPreference() {
  const warnings = [];
  const globalPath = userConfigPath();
  let data = null;
  try {
    const parsed = existsSync(globalPath) ? JSON.parse(readFileSync(globalPath, "utf8")) : null;
    data = parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : null;
  } catch {
    data = null;
  }
  if (!data || data.teamLayout === undefined) return { layout: null, warnings };
  if (!ROSTER_LAYOUT_VALUES.includes(data.teamLayout)) {
    warnings.push(`ah: teamLayout ${JSON.stringify(data.teamLayout)} in ${globalPath} is not a layout (allowed: ${ROSTER_LAYOUT_VALUES.join(", ")}) — ignoring it.`);
    return { layout: null, warnings };
  }
  return { layout: data.teamLayout, warnings };
}

/** Keys a global config file holds when all it records is user preferences: the stored team
    layout, declared model tiers and the selected roster. Such a file configures no hierarchy. */
const PREFERENCE_ONLY_KEYS = new Set(["version", "teamLayout", "modelTiers", "activeRoster"]);

export function projectConfigPath(cwd) {
  if (typeof cwd !== "string" || !cwd) return null;
  return join(resolve(cwd), ".claude", CONFIG_BASENAME);
}

/** Walk up from `start` to the nearest enclosing `.git`; null if none. Shared by hierarchyDir and the roster levels below so all three agree on "this repo". */
export function findGitRoot(start) {
  let dir = resolve(start);
  for (;;) {
    if (existsSync(join(dir, ".git"))) return dir;
    const parent = dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
}

/**
 * The hierarchy runtime dir for a cwd. `AGENT_HIERARCHY_DIR` env wins; else
 * the enclosing git checkout's `.claude/hierarchy/`; else
 * `~/.claude/hierarchy/<basename(cwd)>/`. Lives here (not lib-hier.mjs, which
 * re-exports it) so lib-config.mjs can resolve a team.json path for
 * `statusReport` without a runtime import cycle.
 */
export function hierarchyDir(cwd) {
  const env = process.env.AGENT_HIERARCHY_DIR;
  if (typeof env === "string" && env.trim()) return resolve(env.trim());
  const base = typeof cwd === "string" && cwd ? cwd : process.cwd();
  const root = findGitRoot(base);
  if (root) return join(root, ".claude", "hierarchy");
  return join(homedir(), ".claude", "hierarchy", basename(resolve(base)));
}

/**
 * The main checkout's hierarchy dir when `cwd` is inside a linked worktree, else null. A
 * worktree keeps its own hierarchy dir; this is only where to look for a Team that was stood
 * up from the main checkout before the session's cwd moved into the worktree.
 */
export function mainHierarchyDir(cwd) {
  const env = process.env.AGENT_HIERARCHY_DIR;
  if (typeof env === "string" && env.trim()) return null;
  const root = findGitRoot(typeof cwd === "string" && cwd ? cwd : process.cwd());
  const main = root ? mainCheckoutRoot(root) : null;
  return main ? join(main, ".claude", "hierarchy") : null;
}

/**
 * The checkout `cwd` is in: a linked worktree's main checkout, else the enclosing git checkout,
 * else null. The same resolution `mainHierarchyDir` uses, read from the filesystem with no git call.
 */
export function checkoutRoot(cwd) {
  const root = findGitRoot(typeof cwd === "string" && cwd ? cwd : process.cwd());
  return root ? mainCheckoutRoot(root) || root : null;
}

/** `"-Users-jimcline-git-repos-claudetools"` style slug of an absolute path — every `/` becomes `-`, leading `-` preserved. */
export function pathSlug(absPath) {
  return resolve(absPath).replace(/\//g, "-");
}

/** Absolute path of each roster level's config file for a cwd. */
export function rosterLevelPaths(cwd) {
  const resolvedCwd = resolve(typeof cwd === "string" && cwd ? cwd : process.cwd());
  const repoRoot = findGitRoot(resolvedCwd) || resolvedCwd;
  return {
    global: userConfigPath(),
    repo: join(repoRoot, ".claude", CONFIG_BASENAME),
    "repo-user": join(homedir(), ".claude", "agent-hierarchy", "projects", pathSlug(repoRoot), CONFIG_BASENAME),
  };
}

/**
 * Main checkout root when `worktreeRoot` is a linked worktree, else null.
 * A worktree's `.git` is a FILE holding `gitdir: <main>/.git/worktrees/<name>`;
 * that dir's `commondir` file points back at the main `.git`. A submodule uses
 * the same `.git`-file mechanism but resolves under `.git/modules/`, so the
 * `worktrees` check below is what keeps submodules out.
 */
function mainCheckoutRoot(worktreeRoot) {
  const dotgit = join(worktreeRoot, ".git");
  let raw;
  try {
    if (!statSync(dotgit).isFile()) return null; // normal checkout: .git is a dir
    raw = readFileSync(dotgit, "utf8");
  } catch {
    return null;
  }
  const m = /^gitdir:\s*(.+)$/m.exec(raw);
  if (!m) return null;
  const gitdir = resolve(worktreeRoot, m[1].trim()); // pointer may be relative
  if (basename(dirname(gitdir)) !== "worktrees") return null; // submodule, or unknown layout
  let commonDir;
  try {
    commonDir = resolve(gitdir, readFileSync(join(gitdir, "commondir"), "utf8").trim());
  } catch {
    commonDir = dirname(dirname(gitdir)); // .../.git/worktrees/<n> -> .../.git
  }
  // Only a `<root>/.git` common dir implies a working tree at `<root>`. A bare
  // repo's is `<name>.git` and `--separate-git-dir`'s is an arbitrary path;
  // deriving a root from either names a directory that is not a checkout.
  if (basename(commonDir) !== ".git") return null;
  const root = dirname(commonDir);
  return root && root !== worktreeRoot ? root : null;
}

/** Candidate config paths per roster level, most specific first. */
export function rosterLevelCandidates(cwd) {
  const resolvedCwd = resolve(typeof cwd === "string" && cwd ? cwd : process.cwd());
  const repoRoot = findGitRoot(resolvedCwd) || resolvedCwd;
  const roots = [repoRoot];
  const main = mainCheckoutRoot(repoRoot);
  if (main) roots.push(main); // empty for a normal checkout
  return {
    "repo-user": roots.map((r) => join(homedir(), ".claude", "agent-hierarchy", "projects", pathSlug(r), CONFIG_BASENAME)),
    repo: roots.map((r) => join(r, ".claude", CONFIG_BASENAME)),
    global: [userConfigPath()],
  };
}

/**
 * Derive each member's dispatch name (§3.4): first member of a role gets
 * `peerName(repoBasename, role)`, later same-role members get `-2`, `-3`, ...
 * in array order. `peerName` stays the ordinal-1 case of this function.
 *
 * Also the single read seam where a member's `kind` default is applied (spec
 * 0043 §1.1): every consumer downstream of a roster read — `spawnShape`,
 * `memberIsLive`, `show`, `history`, the `team.json` writers — sees an
 * explicit `kind` and none of them re-applies the default. The value is
 * resolved, never written back to the config file.
 */
export function rosterMemberNames(members, repoBasename) {
  const seen = {};
  return members.map((m) => {
    const role = m.role;
    const ordinal = (seen[role] = (seen[role] || 0) + 1);
    const base = peerName(repoBasename, role);
    return { ...m, kind: resolveKind(m), name: ordinal === 1 ? base : `${base}-${ordinal}` };
  });
}

/**
 * Character-set + role-collision rule for a team name or roster key (spec 0010 §4.4,
 * amendment (d)): starts alphanumeric, 1-32 chars of letters/digits/`-`
 * thereafter, and must not derive a peer name that `roleFromName`'s
 * unanchored substring match resolves to the wrong role, for any chain-class
 * role in `resolved`'s registry (e.g. alias `architect` yields peer name
 * `architect-reviewer`, which resolves to role `architect`, not `reviewer`).
 * Stated behaviorally against the real functions, not a hardcoded token
 * list, so it stays correct if `ROLE_TOKENS` ever changes — a blacklist
 * would wrongly reject `advisor`, which is genuinely safe. Returns
 * `{ok: true}` or `{ok: false, why}`.
 */
export function validateTeamAlias(alias, resolved = null) {
  if (typeof alias !== "string" || !alias) return { ok: false, why: "alias must be a non-empty string" };
  if (!/^[A-Za-z0-9][A-Za-z0-9-]{0,31}$/.test(alias)) {
    return {
      ok: false,
      why: "alias must start with a letter or digit, be 1-32 characters, and contain only letters, digits, and -",
    };
  }
  const collidesWith = chainRoles(resolved).find((role) => roleFromName(peerName(alias, role), resolved) !== role);
  if (collidesWith) {
    return {
      ok: false,
      why: `alias collides with role-token matching: a "${collidesWith}" peer name derived from it would not resolve back to role "${collidesWith}"`,
    };
  }
  return { ok: true };
}

/** Convenience boolean wrapper over `validateTeamAlias`. */
export function isValidTeamAlias(alias) {
  return validateTeamAlias(alias).ok;
}

/**
 * A team name to OFFER when the one a create would use cannot be used — only ever offered: a team
 * is created under it only when it comes back as an explicit `--team`. Without context, or for a
 * transport other than herdr, the rule is sanitize-so-it-still-resembles-the-repo, `team` as the
 * last resort (also the answer when the name is legal but role-token-colliding, e.g. `architect`).
 *
 * Under herdr (`{transport: "herdr", suffixes, resolved}`, where `suffixes` are the `-<role>[-N]`
 * tails of every pane-routed member the team will derive), each `<name><suffix>` must also pass
 * Herdr's agent-name rule, so the name is lowercased, reduced to `[a-z0-9-]` starting with a
 * letter, and cut to leave room for the longest suffix. Null when no name can fit.
 */
export function suggestTeamAlias(raw, context = null) {
  if (!context || context.transport !== "herdr") {
    const sanitized = String(raw == null ? "" : raw)
      .replace(/[^A-Za-z0-9-]/g, "-")
      .replace(/^[^A-Za-z0-9]+/, "")
      .slice(0, 32)
      .replace(/-+$/, "");
    return [sanitized, `team-${sanitized}`.slice(0, 32).replace(/-+$/, "")].find((c) => validateTeamAlias(c).ok) || "team";
  }
  const suffixes = context.suffixes || [];
  if (suffixes.some((suffix) => !/^-[a-z0-9_-]+$/.test(suffix))) return null;
  const budget = 32 - Math.max(0, ...suffixes.map((suffix) => suffix.length));
  if (budget < 1) return null;
  const fit = (name) => name.slice(0, budget).replace(/-+$/, "");
  const base = fit(
    String(raw == null ? "" : raw)
      .toLowerCase()
      .replace(/[^a-z0-9-]/g, "-")
      .replace(/-+/g, "-")
      .replace(/^[^a-z]+/, "")
  );
  const candidates = [base, fit(`team-${base}`), ...(budget >= 4 ? ["team"] : [])];
  return candidates.find((c) => validateTeamAlias(c, context.resolved || null).ok && suffixes.every((suffix) => validateHerdrName(`${c}${suffix}`).ok)) || null;
}

/**
 * The prefix a team's members are named under (`<prefix>-<role>[-N]`). `team`, when a non-empty
 * string, is that prefix — a named team's name is its identity. Otherwise the default team's: a
 * legacy `team.json`'s frozen prefix, inferred from its own members so it cannot drift, else the
 * git-root basename (cwd basename outside a checkout). Reads no config. Returns `{prefix, source}`
 * with source `team`, `legacy-team` or `default`. `teamPrefix` is a thin wrapper over this — keep
 * it that way, one implementation.
 */
export function teamPrefixInfo(cwd, team) {
  if (typeof team === "string" && team) return { prefix: team, source: "team" };
  const resolvedCwd = resolve(typeof cwd === "string" && cwd ? cwd : process.cwd());
  const legacy = legacyTeamPrefix(hierarchyDir(resolvedCwd));
  if (legacy) return { prefix: legacy, source: "legacy-team" };
  return { prefix: basename(findGitRoot(resolvedCwd) || resolvedCwd), source: "default" };
}

/** The naming prefix — see `teamPrefixInfo`. */
export function teamPrefix(cwd, team) {
  return teamPrefixInfo(cwd, team).prefix;
}

/** The `rosters[key]` block at one level, or null. */
function pickTeamRoster(data, key) {
  const map = data.rosters;
  if (!map || typeof map !== "object" || Array.isArray(map)) return null;
  return Object.prototype.hasOwnProperty.call(map, key) ? map[key] : null;
}

/**
 * Resolve a roster block: repo-user → repo → global, first level whose block is present with at
 * least one member wins IN ITS ENTIRETY (no merging across levels). Returns `{level, route,
 * members: [...withNames], path, teamKey}` or null when no level has one.
 *
 * Two-pass (spec 0032 §3.2): with `rosterKey`, pass 1 walks every level for a `rosters[rosterKey]`
 * block (key-specificity outranks location); pass 2, always run, reads the default `roster` block.
 * `teamKey` is the key the WINNING pass matched on — `rosterKey` for a pass-1 hit, else null.
 *
 * Members are named under `namingPrefix`, which a caller takes from the TEAM, never from the key;
 * absent, the default team's prefix. A roster has no name of its own. The block is returned
 * through `normalizeRosterBlock`, with custom roles classified by `registry`.
 */
/**
 * A roster block as it reads while the subagent opt-ins written before are ignored: only legwork
 * runs as a subagent, and onMissing is always "auto". A chain member's route "subagent" gives way to
 * the block's; a block route "subagent" reads as "peer", with each legwork member that inherited it
 * keeping "subagent" as its own. A member whose role `registry` cannot classify is left as it is.
 */
export function normalizeRosterBlock(block, registry = null) {
  const staleBlock = block.route === "subagent";
  const members = (Array.isArray(block.members) ? block.members : []).map((m) => {
    const cls = m && typeof m === "object" ? roleClass(m.role, registry) : null;
    if (!cls) return m;
    const out = { ...m };
    if (out.onMissing === "never" || out.onMissing === "prompt") delete out.onMissing;
    if (cls === "legwork") {
      if (staleBlock && out.route === undefined) out.route = "subagent";
    } else if (out.route === "subagent") {
      delete out.route;
    }
    return out;
  });
  return { ...block, route: staleBlock ? "peer" : block.route, members };
}

/**
 * Drops, in place, every roster `members` element of a parsed level file that is not a plain
 * object — null, an array, a string, a number, a boolean — and returns what it dropped as
 * `{label, index, type, value}`, `index` being the element's position in the file. Every reader of
 * a level file calls this first, so each consumer sees only objects. The survivors keep their
 * order, and a dropped element has no role, so same-role ordinals and derived names do not shift.
 * Skipped rather than rejected: one bad row must not disable a team, and a hook must never crash
 * on config — in the route gate a crash fails closed for the built-in chain refs.
 */
export function dropNonObjectMembers(data) {
  const dropped = [];
  for (const [label, , block] of rosterBlocksOf(data)) {
    if (!block || typeof block !== "object" || Array.isArray(block) || !Array.isArray(block.members)) continue;
    const kept = [];
    block.members.forEach((m, index) => {
      if (m && typeof m === "object" && !Array.isArray(m)) kept.push(m);
      else dropped.push({ label, index, type: m === null ? "null" : Array.isArray(m) ? "array" : typeof m, value: m });
    });
    if (kept.length !== block.members.length) block.members = kept;
  }
  return dropped;
}

export function resolveRoster(cwd, rosterKey, namingPrefix = null, registry = null) {
  const candidates = rosterLevelCandidates(cwd);
  const prefix = typeof namingPrefix === "string" && namingPrefix ? namingPrefix : teamPrefix(cwd, null);
  const passes = rosterKey ? [rosterKey, null] : [null];
  for (const teamKey of passes) {
    for (const level of ROSTER_LEVELS) {
      for (const path of candidates[level]) {
        if (!existsSync(path)) continue;
        let data;
        try {
          data = JSON.parse(readFileSync(path, "utf8"));
        } catch {
          continue;
        }
        if (!data || typeof data !== "object" || Array.isArray(data)) continue;
        dropNonObjectMembers(data);
        const r = teamKey ? pickTeamRoster(data, teamKey) : data.roster;
        if (!r || typeof r !== "object" || Array.isArray(r) || !Array.isArray(r.members) || r.members.length === 0) continue;
        const block = normalizeRosterBlock(r, registry);
        return { level, route: block.route, members: rosterMemberNames(block.members, prefix), path, teamKey };
      }
    }
  }
  return null;
}

/** Every roster block one level file holds, as `[label, key, block]`: the default `roster` (key
    null), then each `rosters.<key>`. */
export function rosterBlocksOf(data) {
  const map = data && data.rosters;
  const named = map && typeof map === "object" && !Array.isArray(map) ? Object.entries(map).map(([key, block]) => [`rosters.${key}`, key, block]) : [];
  return [["roster", null, data ? data.roster : undefined], ...named];
}

/**
 * The `rosters.*` keys a create can be pointed at, across every level `resolveRoster` reads:
 * sorted, de-duplicated, and only names that pass `validateTeamAlias` (no other can be selected).
 */
export function namedRosterKeys(cwd) {
  const keys = new Set();
  const candidates = rosterLevelCandidates(cwd);
  for (const level of ROSTER_LEVELS) {
    for (const path of candidates[level]) {
      if (!existsSync(path)) continue;
      let data;
      try {
        data = JSON.parse(readFileSync(path, "utf8"));
      } catch {
        continue;
      }
      if (!data || typeof data !== "object" || Array.isArray(data)) continue;
      for (const [, key] of rosterBlocksOf(data)) if (key !== null && isValidTeamAlias(key)) keys.add(key);
    }
  }
  return [...keys].sort();
}

/** The roster name that means the unnamed `roster` block wherever a roster is selected. A team's
    recorded key is never read this way, so a legacy `rosters.default` block keeps serving its team. */
export const DEFAULT_ROSTER = "default";

/**
 * The `activeRoster` that applies: the first one set, most specific level first, across the same
 * candidate paths `resolveRoster` reads — so a main checkout's repo-level value also applies in its
 * linked worktrees. `{value, level, path}`, or null when none is set. A JSON null counts as unset.
 */
export function activeRosterSetting(cwd) {
  const candidates = rosterLevelCandidates(cwd);
  for (const level of ROSTER_LEVELS) {
    for (const path of candidates[level]) {
      if (!existsSync(path)) continue;
      let data;
      try {
        data = JSON.parse(readFileSync(path, "utf8"));
      } catch {
        continue;
      }
      if (!data || typeof data !== "object" || Array.isArray(data)) continue;
      if (data.activeRoster !== undefined && data.activeRoster !== null) return { value: data.activeRoster, level, path };
    }
  }
  return null;
}

/**
 * Which roster block a command uses, and why — the one selection rule, for roster.mjs's template
 * verbs and `create`, and for `resolveConfig`. The first match wins: `flag`; with `team` given
 * (`{dir, name}`), the key that team's file records when the file exists; a non-empty `AH_ROSTER`;
 * `activeRoster`; else the default block. `default` from any source but a team file means the
 * unnamed block. Returns `{roster, key, source, level, path}`: `roster` is the name or "default",
 * `key` the `rosters.*` key or null for the unnamed block, and `level`/`path` are set only for
 * source `activeRoster`.
 */
export function rosterSelection(cwd, { flag = null, team = null } = {}) {
  const chosen = (value, source, level = null, path = null) => {
    const key = value === DEFAULT_ROSTER ? null : value;
    return { roster: key === null ? DEFAULT_ROSTER : key, key, source, level, path };
  };
  if (typeof flag === "string" && flag) return chosen(flag, "flag");
  if (team) {
    const recorded = teamRosterEntry(team.dir, team.name);
    if (recorded !== undefined) return { roster: recorded === null ? DEFAULT_ROSTER : recorded, key: recorded, source: "team", level: null, path: null };
  }
  const env = process.env.AH_ROSTER;
  if (typeof env === "string" && env !== "") return chosen(env, "env");
  const active = activeRosterSetting(cwd);
  if (active) return chosen(active.value, "activeRoster", active.level, active.path);
  return chosen(DEFAULT_ROSTER, "default");
}

/** The named rosters a selection can name: every `rosters.<name>` key some visible level holds,
    even with no members, less a legacy `rosters.default`, which the name `default` never reaches. */
export function selectableRosters(cwd) {
  return namedRosterKeys(cwd).filter((k) => k !== DEFAULT_ROSTER);
}

/** The `selection` object CLI output carries. */
export function selectionView(selection) {
  const { roster, source, level, path } = selection;
  return { roster, source, level, path };
}

/**
 * Null when `selection` is usable, else why not: a flag, `AH_ROSTER` or `activeRoster` naming a
 * roster that no visible level defines — a `rosters.<name>` key, even one with no members. The
 * message names the source, the defined rosters and the fixes. The verbs refuse with it, except
 * `init`, which is how a missing roster gets made; `resolveConfig` warns with it and uses the
 * default block; `doctor` reports it red.
 */
export function rosterSelectionProblem(cwd, selection) {
  if (!["flag", "env", "activeRoster"].includes(selection.source) || selection.key === null) return null;
  if (typeof selection.key !== "string" || selection.key === "") {
    return (
      `activeRoster at ${selection.level} in ${selection.path} must be a roster name, got ${JSON.stringify(selection.key)}. ` +
      `Fix with \`roster.mjs roster use <name> --level ${selection.level}\` or \`roster.mjs roster use --clear --level ${selection.level}\`.`
    );
  }
  const defined = selectableRosters(cwd);
  if (defined.includes(selection.key)) return null;
  const source =
    selection.source === "flag" ? "--roster" : selection.source === "env" ? "AH_ROSTER" : `activeRoster at ${selection.level} in ${selection.path}`;
  const name = selection.key;
  return (
    `${source} selects roster "${name}", but there is no rosters.${name} block at any level (defined: ${defined.join(", ") || "none"}). ` +
    `Fix with \`roster.mjs roster use default\`, \`roster.mjs roster use <other>\`, or \`roster.mjs init --roster ${name}\`.`
  );
}

/**
 * Config keys that do nothing any more. Some name or lay out a team from the wrong place:
 * `teamAlias` (any level), a roster block's `layout`, and a `teamLayout` outside the global file.
 * Others opt a chain role into running as a subagent, which only legwork does now: a roster route
 * "subagent", onMissing "never"/"prompt", a chain role's dispatch "model", and a top-level route
 * other than "peers". Invalid global `modelTiers` entries, and roster `members` elements that are not objects, are reported here too; the latter are
 * ignored by every reader (`dropNonObjectMembers`). They are reported only in CLI output a person reads (`status`, `doctor`,
 * `create`), never in hook-injected context, where they would repeat in every session; never acted
 * on; removed only by the next CLI write to their file. `registry` classifies custom roles. Returns
 * `{warnings, aliases}` — `aliases` are the stale names still configured, so a create can say how
 * to keep the member names they used to produce.
 */
export function staleTeamKeys(cwd, registry = null) {
  const warnings = [...declaredModelTiers().warnings];
  const aliases = [];
  const candidates = rosterLevelCandidates(cwd);
  for (const path of new Set([...candidates["repo-user"], ...candidates.repo, ...candidates.global])) {
    if (!existsSync(path)) continue;
    let data;
    try {
      data = JSON.parse(readFileSync(path, "utf8"));
    } catch {
      continue;
    }
    if (!data || typeof data !== "object" || Array.isArray(data)) continue;
    for (const d of dropNonObjectMembers(data)) warnings.push(`roster \`${path}\`: \`members[${d.index}]\` is not an object (\`${d.type}\`); ignored`);
    const alias = data.teamAlias;
    if (alias !== undefined) {
      warnings.push(`ah: teamAlias in ${path} is ignored — a team's name is chosen when it is created (\`roster.mjs create --team <name>\`). It has no effect; delete it from ${path} to drop this warning, or it is removed at the next CLI write to that file.`);
      if (typeof alias === "string" && alias) aliases.push(alias);
    }
    for (const [label, , block] of rosterBlocksOf(data)) {
      if (block && typeof block === "object" && block.layout !== undefined) {
        warnings.push(`ah: ${label}.layout in ${path} is ignored — a team's layout is chosen when it is created (\`roster.mjs create --mode <auto|columns|grid>\`), and an explicit --mode becomes the default for future teams. It has no effect; delete it from ${path} to drop this warning, or it is removed at the next CLI write to that file.`);
      }
    }
    if (path !== userConfigPath() && data.teamLayout !== undefined) {
      warnings.push(`ah: teamLayout in ${path} is ignored — the default team layout is read from the global config (${userConfigPath()}) only, and an explicit \`create --mode <m>\` sets it. It has no effect; delete it from ${path} to drop this warning, or it is removed at the next CLI write to that file.`);
    }
    const subagentOnly = (what) =>
      `ah: ${what} in ${path} is ignored — only legwork roles run as subagents. It is migrated at the next CLI write to that file, or delete it by hand.`;
    if (STALE_ROUTE_VALUES.includes(data.route)) warnings.push(subagentOnly(`route ${JSON.stringify(data.route)}`));
    const roleRows = data.roles && typeof data.roles === "object" && !Array.isArray(data.roles) ? data.roles : {};
    for (const [role, row] of Object.entries(roleRows)) {
      const cls = roleClass(role, registry);
      if (cls && cls !== "legwork" && row && row.dispatch === "model") warnings.push(subagentOnly(`roles.${role}.dispatch "model"`));
    }
    for (const [label, , block] of rosterBlocksOf(data)) {
      if (!block || typeof block !== "object" || Array.isArray(block)) continue;
      if (block.route === "subagent") warnings.push(subagentOnly(`${label}.route "subagent"`));
      (Array.isArray(block.members) ? block.members : []).forEach((m, i) => {
        const cls = m && typeof m === "object" ? roleClass(m.role, registry) : null;
        if (!cls) return;
        if (cls !== "legwork" && m.route === "subagent") warnings.push(subagentOnly(`${label}.members[${i}] (${m.role}) route "subagent"`));
        if (m.onMissing === "never" || m.onMissing === "prompt") warnings.push(subagentOnly(`${label}.members[${i}] (${m.role}) onMissing ${JSON.stringify(m.onMissing)}`));
      });
    }
  }
  return { warnings, aliases };
}

/** Row keys a built-in cannot change: present in config → a warning, ignored. */
const BUILTIN_FIXED_KEYS = ["class", "label", "description", "routes"];

export const ROLE_NAME_RE = /^[a-z][a-z0-9-]{0,30}$/;
/**
 * An agent reference is interpolated into shell strings (spawn commands and the directive's spawn
 * lines), so this charset is a security boundary: checked when a row is read or written, and again
 * at the spawn seam.
 */
export const AGENT_REF_RE = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}(:[A-Za-z0-9][A-Za-z0-9_.-]{0,63})?$/;
export const LABEL_RE = /^[A-Za-z0-9][A-Za-z0-9 -]{0,31}$/;
const RESERVED_ROLE_NAMES = ["orchestrator", "advisor", "other"];
/** Cap on `description` and `routes`: they are pasted verbatim into injected prose. */
export const ONE_LINE_MAX = 160;

export function roleNameError(name) {
  if (typeof name !== "string" || !ROLE_NAME_RE.test(name)) return `name must match ${ROLE_NAME_RE}`;
  if (/-$|-\d+$/.test(name)) return "name must not end in - or -<digits> (that suffix is a peer instance ordinal)";
  if (isBuiltinRole(name) || RESERVED_ROLE_NAMES.includes(name)) return `name ${JSON.stringify(name)} is reserved`;
  return null;
}

export function agentRefError(agent) {
  if (typeof agent !== "string" || !AGENT_REF_RE.test(agent)) return `agent ${JSON.stringify(agent)} must match ${AGENT_REF_RE}`;
  return null;
}

export function oneLineError(field, value) {
  if (typeof value !== "string" || !value.trim()) return `${field} must be a non-empty string`;
  if (value.length > ONE_LINE_MAX) return `${field} must be at most ${ONE_LINE_MAX} characters`;
  if (/[\n\r`]/.test(value)) return `${field} must be one line with no backticks`;
  return null;
}

/** `ui-implementor` → `Ui-Implementor`. */
export function defaultLabel(name) {
  return name.split("-").map((w) => (w ? w[0].toUpperCase() + w.slice(1) : w)).join("-");
}

function builtinAgentError(role, agent) {
  const why = agentRefError(agent);
  if (why) return why;
  if (agent.startsWith("ah:") && agent !== `ah:${role}`) return "ah:* agents belong to the built-ins";
  return null;
}

/**
 * The row checks for one custom role (name, class, agent, label, description, routes, model):
 * `{row, warnings}` with defaults applied, or `{error}`. Never throws.
 */
export function checkCustomRow(name, raw) {
  const nameErr = roleNameError(name);
  if (nameErr) return { error: nameErr };
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return { error: "row must be an object" };
  if (!CLASSES[raw.class]) return { error: `class is required, one of ${CLASS_NAMES.join(", ")}` };
  const cls = CLASSES[raw.class];
  const warnings = [];
  const agent = raw.agent === undefined ? name : raw.agent;
  const agentErr = agentRefError(agent);
  if (agentErr) return { error: agentErr };
  if (agent.startsWith("ah:")) return { error: "ah:* agents belong to the built-ins" };
  const label = raw.label === undefined ? defaultLabel(name) : raw.label;
  if (typeof label !== "string" || !LABEL_RE.test(label)) return { error: `label must match ${LABEL_RE}` };
  const row = { class: raw.class, agent, label };
  if (raw.description !== undefined) {
    const e = oneLineError("description", raw.description);
    if (e) return { error: e };
    row.description = raw.description;
  }
  if (raw.routes !== undefined) {
    const e = oneLineError("routes", raw.routes);
    if (e) return { error: e };
    if (cls.chain) row.routes = raw.routes;
    else warnings.push("routes is ignored on a legwork role — legwork is never routed within the chain");
  }
  if (raw.class === "advise" && (raw.model === undefined || raw.model === "inherit")) {
    return { error: `an advise-class role needs an explicit model (${cls.models.join(", ")})` };
  }
  const model = raw.model === undefined ? "inherit" : raw.model;
  if (typeof model !== "string" || !cls.models.includes(model)) {
    return { error: `model ${JSON.stringify(model)} is not allowed for class ${raw.class} (allowed: ${cls.models.join(", ")})` };
  }
  row.model = model;
  if (cls.chain) {
    if (raw.dispatch !== undefined) row.dispatch = raw.dispatch;
    if (raw.peer !== undefined) row.peer = raw.peer;
  }
  return { row, warnings };
}

/** Default and validate a chain role's `dispatch` and `peer` in place, warning on a bad value. A
    chain role never runs as a subagent, so a "model" left from before reads as "peer" — silently,
    since these warnings reach session context and the CLI's stale-key report already names it. */
function normalizeDispatch(role, roles, warnings) {
  const rawDispatch = roles[role].dispatch;
  let dispatch = rawDispatch === undefined || rawDispatch === "model" ? "peer" : rawDispatch;
  if (!DISPATCH_MODES.includes(dispatch)) {
    warnings.push(
      `ah: dispatch ${JSON.stringify(rawDispatch)} is not valid for role "${role}" (allowed: ${DISPATCH_MODES.join(", ")}) — using "peer".`
    );
    dispatch = "peer";
  }
  roles[role] = { ...roles[role], dispatch };
  if (dispatch === "peer") {
    const rawPeer = roles[role].peer;
    let peer = rawPeer === undefined ? "auto" : rawPeer;
    const validArray = Array.isArray(peer) && peer.length > 0 && peer.every((p) => typeof p === "string" && p.trim());
    if (!validArray && (typeof peer !== "string" || !peer.trim())) {
      warnings.push(`ah: peer value for role "${role}" must be a non-empty string or array of names — using "auto".`);
      peer = "auto";
    }
    roles[role] = { ...roles[role], peer };
  }
}

/** Load one scope. Returns null when absent/unreadable/not an object. */
function loadScope(path, scope, warnings) {
  if (!path || !existsSync(path)) return null;
  let data;
  try {
    data = JSON.parse(readFileSync(path, "utf8"));
  } catch {
    warnings.push(`ah: ${scope}-scope config at ${path} is not valid JSON — ignoring it.`);
    return null;
  }
  if (!data || typeof data !== "object" || Array.isArray(data)) {
    warnings.push(`ah: ${scope}-scope config at ${path} is not a JSON object — ignoring it.`);
    return null;
  }
  const version = data.version === undefined ? CONFIG_VERSION : data.version;
  if (!Number.isInteger(version) || version > CONFIG_VERSION) {
    warnings.push(
      `ah: ${scope}-scope config at ${path} declares version ${JSON.stringify(data.version)}, which this plugin (v${CONFIG_VERSION}) does not understand — ignoring it.`
    );
    return null;
  }
  return { scope, path, data };
}

/**
 * The active team scope (spec 0011 §4.4): (1) `opts.team` if given —
 * trusted as-is, the CLI layer validates it with `validateTeamAlias` before
 * we ever see it; (2) the team (default or named) whose `team.json` binds
 * `orchestrator.session_id === opts.sessionId`, letting an orchestrator omit
 * `--team` after `create`; (3) the team whose `orchestrator.session_id` is
 * unset and whose `orchestrator.pid` is the calling Claude session's pid —
 * `spawn-one`/`spawn-ad-hoc` record only the pid, so without this the
 * session that spawned a team cannot see it; (4) for a session that owns none, the team it was
 * launched into (`AH_TEAM_FILE`), else the live team whose member row holds its pane — the
 * orchestrator steps come first so an owner always resolves to its own team; (5) `null`, the
 * default team.
 * The caller pid is `opts.pid`, else `process.ppid` (a hook's parent is the
 * Claude process). A CLI's parent is a shell, so CLI callers pass the pid
 * spawn-* records (`--orchestrator-pid`, else `CLAUDE_PID`); a non-integer
 * pid skips (3). A team with a session_id is
 * never adopted by pid. Any read failure (missing team file, unreadable
 * member list) degrades to `null` rather than throwing — 0009 §8.12's
 * fail-open catch, extended to team resolution.
 *
 * Returns `{name, home, via}`: `home` is the hierarchy dir holding that team's file (null when not
 * known — an explicit `opts.team` without `opts.teamHome`, or no team); `via` is the step that
 * answered — `team`, `session`, `pid` (the session's own team), `env` or `pane` (a team it was only
 * attributed to, which may be read but never cleared or rewritten), or null.
 */
function resolveTeamScope(cwd, opts) {
  if (opts && typeof opts.team === "string" && opts.team) return { name: opts.team, home: opts.teamHome || null, via: "team" };
  const pid = opts && opts.pid !== undefined ? opts.pid : process.ppid;
  try {
    const dir = hierarchyDir(cwd);
    const teams = [null, ...listTeamNames(dir)].map((name) => ({ name, orch: (readTeam(dir, name) || {}).orchestrator }));
    if (opts && opts.sessionId) {
      const hit = teams.find((t) => t.orch && t.orch.session_id === opts.sessionId);
      if (hit) return { name: hit.name, home: dir, via: "session" };
    }
    if (Number.isInteger(pid) && pid > 0) {
      const hit = teams.find((t) => t.orch && !t.orch.session_id && t.orch.pid === pid);
      if (hit) return { name: hit.name, home: dir, via: "pid" };
    }
    // A session that owns no team: the team it was launched into, else the live team holding its pane.
    const member = memberTeam(dir, [dir, mainHierarchyDir(cwd)], process.env.HERDR_PANE_ID || process.env.TMUX_PANE || null);
    if (member) return { name: member.teamName, home: member.home, via: member.via };
  } catch {
    // fail-open to default — see doc comment above.
  }
  return { name: null, home: null, via: null };
}

/**
 * A built-in's `from` row: the pack supplies only its agent (the row keeps its own `model`,
 * `dispatch` and `peer`), and the pack role's class must be the built-in's. When nothing on this
 * machine says what the role is, the agent is guessed from `from` so the override still shows, and
 * fails, as unavailable.
 */
function builtinFromRow(role, entry) {
  const expanded = expandFromRow(entry);
  const f = parseFrom(entry.from);
  const guess = f ? `${f.plugin}:${f.role}` : `ah:${role}`;
  if (expanded.error) {
    const status = expanded.error.slice(0, expanded.error.indexOf(":"));
    return { ...entry, agent: guess, pack: { status, message: expanded.error.slice(status.length + 2), subcode: null, from: entry.from, agentText: null, agentPath: null, pinNow: null } };
  }
  const pack = expanded.raw.class === BUILTIN_CLASS[role]
    ? expanded.pack
    : { ...expanded.pack, status: "pack-invalid", message: `the pack role's class, ${expanded.raw.class}, isn't the ${role}'s class, ${BUILTIN_CLASS[role]}` };
  return { ...entry, agent: expanded.raw.agent, pack };
}

/** The selection for a session whose team scope is `team` (null: the default team) in `teamHome`. */
function scopedRosterSelection(resolvedCwd, opts, team, teamHome) {
  return rosterSelection(resolvedCwd, {
    flag: opts.roster === null ? DEFAULT_ROSTER : opts.roster,
    team: { dir: teamHome || hierarchyDir(resolvedCwd), name: team },
  });
}

/** The roster selection `resolveConfig(cwd, opts)` uses, with the session's team scope resolved the
    same way, so a CLI report (doctor) and the hooks agree on it. */
export function sessionRosterSelection(cwd, opts = {}) {
  const resolvedCwd = resolve(typeof cwd === "string" && cwd ? cwd : process.cwd());
  const { name: team, home: teamHome } = resolveTeamScope(resolvedCwd, opts);
  return scopedRosterSelection(resolvedCwd, opts, team, teamHome);
}

/**
 * Resolve the effective hierarchy for a session.
 *
 * @returns {{configured: boolean, enabled: boolean, roles: object, sources: object,
 *            shadowed: string[], layers: object[], warnings: string[], team: string|null}}
 */
export function resolveConfig(cwd, opts = {}) {
  const warnings = [];
  const resolvedCwd = resolve(typeof cwd === "string" && cwd ? cwd : process.cwd());
  // `teamHome` is the hierarchy dir the team's file lives in — a worktree peer's team is the main
  // checkout's, which is not `hierarchyDir(cwd)`.
  const { name: team, home: teamHome, via: teamVia } = resolveTeamScope(resolvedCwd, opts);
  const userPath = userConfigPath();
  // Fix 2 (spec 0032 §4): worktree-aware candidate lists, matching resolveRoster — first
  // existing path per scope, never merged across candidates within a level (§4 rationale:
  // `shadowed` counts scopes, and a merge would change what it means).
  const candidates = rosterLevelCandidates(resolvedCwd);
  // `global`/`repo`/`repo-user` here map to resolveConfig's `user`/`project`/`repo-user`
  // scope names. Names differ for historical reasons (spec 0001); the files are the same.
  const firstExisting = (paths) => paths.find((p) => existsSync(p)) || null;
  const projectPath = firstExisting(candidates.repo);
  const repoUserPath = firstExisting(candidates["repo-user"]);
  const user = loadScope(userPath, "user", warnings);
  // When the session's cwd IS the home directory the two scopes are the same
  // file; loading it twice would report every role as shadowed by itself.
  const project = !projectPath || projectPath === userPath ? null : loadScope(projectPath, "project", warnings);
  const repoUser = !repoUserPath || repoUserPath === userPath || repoUserPath === projectPath ? null : loadScope(repoUserPath, "repo-user", warnings);

  // Least specific first: repo-user is the new highest-precedence layer. A global file holding only
  // the stored team layout is a create's side effect, not hierarchy config, so it configures nothing.
  // Choosing a roster never makes a setup look configured either: a repo or repo-user file holding
  // only `activeRoster` (and `version`) configures nothing, though its selection still applies.
  const preferenceOnly = (layer) => {
    const keys = Object.keys(layer.data);
    if (layer.scope === "user") return keys.every((k) => PREFERENCE_ONLY_KEYS.has(k));
    return keys.includes("activeRoster") && keys.every((k) => k === "version" || k === "activeRoster");
  };
  const layers = [user, project, repoUser].filter(Boolean).filter((layer) => !preferenceOnly(layer));
  warnings.push(...teamLayoutPreference().warnings);

  const roles = {};
  const sources = {};
  for (const role of ROLES) {
    roles[role] = { ...ROLE_DEFAULTS[role] };
    sources[role] = "default";
  }

  if (layers.length === 0) {
    return {
      configured: false,
      enabled: true,
      handoffs: "auto",
      handoffsSource: "default",
      msgs: "required",
      route: null,
      routeSource: null,
      roles,
      sources,
      shadowed: [],
      excludedRoles: [],
      layers,
      warnings,
      cwd: resolvedCwd,
      roster: null,
      rosterLevel: null,
      team,
      teamVia,
    };
  }

  let enabled = true;
  for (const layer of layers) {
    if (typeof layer.data.enabled === "boolean") enabled = layer.data.enabled;
  }

  // Most-specific scope wins, same rule as `enabled`.
  let handoffs = "auto";
  let handoffsSource = "default";
  for (const layer of layers) {
    if (typeof layer.data.handoffs === "string") {
      handoffs = layer.data.handoffs;
      handoffsSource = layer.scope;
    }
  }
  if (!HANDOFF_MODES.includes(handoffs)) {
    warnings.push(
      `ah: handoffs ${JSON.stringify(handoffs)} is not a mode (allowed: ${HANDOFF_MODES.join(", ")}) — using "auto".`
    );
    handoffs = "auto";
    handoffsSource = "default";
  }

  // Most-specific scope wins, same rule as `enabled`.
  let msgs = "required";
  for (const layer of layers) {
    if (typeof layer.data.msgs === "string") msgs = layer.data.msgs;
  }
  if (!MSGS_MODES.includes(msgs)) {
    warnings.push(`ah: msgs ${JSON.stringify(msgs)} is not a mode (allowed: ${MSGS_MODES.join(", ")}) — using "required".`);
    msgs = "required";
  }

  // Most-specific scope wins, same rule as `enabled`. Unset stays null — see ROUTE_VALUES doc comment.
  let route = null;
  let routeSource = null;
  for (const layer of layers) {
    if (typeof layer.data.route === "string") {
      route = layer.data.route;
      routeSource = layer.scope;
    }
  }
  if (route !== null && !ROUTE_VALUES.includes(route)) {
    // A stale opt-in is reported by the CLI's stale-key report, never in session context.
    if (!STALE_ROUTE_VALUES.includes(route)) warnings.push(`ah: route ${JSON.stringify(route)} is not a mode (allowed: ${ROUTE_VALUES.join(", ")}) — ignoring it.`);
    route = null;
    routeSource = null;
  }

  const definedBy = {};
  const customRaw = {};
  for (const layer of layers) {
    const layerRoles = layer.data.roles;
    if (!layerRoles || typeof layerRoles !== "object" || Array.isArray(layerRoles)) continue;
    for (const role of Object.keys(layerRoles)) {
      const entry = layerRoles[role];
      if (!isBuiltinRole(role)) {
        // Whole-row precedence, as for built-ins: the most specific layer's row wins as written,
        // and an invalid one is excluded rather than falling back to a wider layer.
        customRaw[role] = { raw: entry, scope: layer.scope, path: layer.path };
        (definedBy[role] ||= []).push(layer.scope);
        continue;
      }
      if (!entry || typeof entry !== "object" || Array.isArray(entry)) continue;
      // Shallow replacement: the whole role object is swapped, not merged key-by-key.
      roles[role] = isFromRow(entry) ? builtinFromRow(role, entry) : { ...entry };
      sources[role] = layer.scope;
      (definedBy[role] ||= []).push(layer.scope);
    }
  }

  // A user-scope role value that a project config also defines is shadowed.
  const shadowed = [...ROLES, ...Object.keys(customRaw).sort()].filter((role) => (definedBy[role] || []).length > 1);

  for (const role of ROLES) {
    const model = roles[role].model;
    const valid = VALID_MODELS_BY_ROLE[role];
    if (typeof model !== "string" || !valid.includes(model)) {
      warnings.push(
        `ah: model ${JSON.stringify(model)} is not allowed for role "${role}" (allowed: ${valid.join(", ")}) — using the default "${ROLE_DEFAULTS[role].model}".`
      );
      roles[role] = { ...roles[role], model: ROLE_DEFAULTS[role].model };
    }
    if (!PEER_ELIGIBLE_ROLES.includes(role)) continue;
    normalizeDispatch(role, roles, warnings);
  }

  for (const role of ROLES) {
    for (const key of BUILTIN_FIXED_KEYS) {
      if (roles[role][key] !== undefined) warnings.push(`ah: roles.${role}.${key} is ignored — a built-in role's ${key} cannot be changed (only agent, model, dispatch and peer).`);
    }
    if (roles[role].agent === undefined) continue;
    const why = builtinAgentError(role, roles[role].agent);
    if (why) {
      warnings.push(`ah: roles.${role}.agent ${JSON.stringify(roles[role].agent)} is invalid (${why}) — using ah:${role}.`);
      const { agent, ...rest } = roles[role];
      roles[role] = rest;
    }
  }

  const excludedRoles = [];
  const exclude = (name, info, reason) => {
    excludedRoles.push({ name, scope: info.scope, path: info.path, reason });
    warnings.push(`ah: custom role "${name}" at ${info.scope}-scope config (${info.path}) is invalid (${reason}) — ignoring it.`);
  };
  const customRows = {};
  for (const name of Object.keys(customRaw).sort()) {
    const info = customRaw[name];
    const expanded = isFromRow(info.raw) ? expandFromRow(info.raw) : null;
    if (expanded && expanded.error) {
      exclude(name, info, expanded.error);
      continue;
    }
    const checked = checkCustomRow(name, expanded ? expanded.raw : info.raw);
    if (checked.error) {
      exclude(name, info, checked.error);
      continue;
    }
    for (const w of checked.warnings) warnings.push(`ah: custom role "${name}": ${w}`);
    customRows[name] = expanded ? { ...checked.row, from: info.raw.from, pin: info.raw.pin, pack: expanded.pack } : checked.row;
  }
  // An agent maps to exactly one role: a custom row whose agent a built-in already owns is invalid
  // (built-ins win), and custom rows sharing one agent are all invalid — neither can own it.
  const builtinAgents = new Map(ROLES.map((r) => [roleAgent(r, roles[r]), r]));
  const agentUsers = {};
  for (const [name, row] of Object.entries(customRows)) (agentUsers[row.agent] ||= []).push(name);
  for (const [name, row] of Object.entries(customRows)) {
    const owner = builtinAgents.get(row.agent);
    if (owner) {
      exclude(name, customRaw[name], `agent ${JSON.stringify(row.agent)} is already the ${owner} role's agent`);
      continue;
    }
    if (agentUsers[row.agent].length > 1) {
      exclude(name, customRaw[name], `agent ${JSON.stringify(row.agent)} is also used by ${agentUsers[row.agent].filter((n) => n !== name).join(", ")}`);
      continue;
    }
    roles[name] = row;
    sources[name] = customRaw[name].scope;
    if (CLASSES[row.class].chain) normalizeDispatch(name, roles, warnings);
  }

  // The block is the team's recorded template (or an explicit `opts.roster`, else the selection);
  // the names are the team's own. A selection naming no defined roster is warned about, never thrown.
  const selection = scopedRosterSelection(resolvedCwd, opts, team, teamHome);
  const selectionProblem = rosterSelectionProblem(resolvedCwd, selection);
  if (selectionProblem) warnings.push(`ah: ${selectionProblem} Using the default roster block until then.`);
  const rosterKey = selectionProblem ? null : selection.key;
  const rosterResult = resolveRoster(cwd, rosterKey, teamPrefix(resolvedCwd, team), { roles });
  return {
    configured: true,
    enabled,
    handoffs,
    handoffsSource,
    msgs,
    route,
    routeSource,
    roles,
    sources,
    shadowed,
    excludedRoles,
    layers,
    warnings,
    cwd: resolvedCwd,
    roster: rosterResult,
    rosterLevel: rosterResult ? rosterResult.level : null,
    team,
    teamVia,
  };
}

// ---------------------------------------------------------------- agent files (read, validate)

/** Only this much of an agent file is read: frontmatter sits at the top, and a huge body is not ah's to parse. */
export const AGENT_READ_CAP = 16 * 1024;

function readHead(path, cap = AGENT_READ_CAP) {
  const fd = openSync(path, "r");
  try {
    const buf = Buffer.alloc(cap);
    const n = readSync(fd, buf, 0, cap, 0);
    return buf.subarray(0, n).toString("utf8");
  } finally {
    closeSync(fd);
  }
}

function installedPluginsPath() {
  return join(homedir(), ".claude", "plugins", "installed_plugins.json");
}

export const TASK_GOPHER = "task-gopher:task-gopher";

/** A claude-kind legwork member with no model is not launched while task-gopher is installed: its
    legwork goes to task-gopher subagents instead. `handoff` answers whether task-gopher is
    installed, and is asked last, only for such a member. */
export function legworkHandedOff(m, registry, handoff) {
  return resolveKind(m) === KIND_DEFAULT && !m.model && roleClass(m.role, registry) === "legwork" && handoff();
}

/**
 * Whether a team is partial: some roster member that `create` would launch — a pane-route member,
 * less one handed off to task-gopher — has no record, matched by its derived name or by a record's
 * `renamed_from`. Derived from the team's recorded roster block at read time, so a roster edit
 * changes the answer with no team write; records beyond the roster (ad hoc members) never change
 * it. Null when that block no longer resolves: either answer would be a guess.
 */
export function teamIsPartial(dir, cwd, teamName, team, registry = null) {
  if (!team || !Array.isArray(team.members) || !cwd) return null;
  const rosterKey = teamRosterKey(dir, teamName);
  const r = resolveRoster(cwd, rosterKey, teamPrefix(cwd, teamName), registry);
  if (!r || (r.teamKey || null) !== (rosterKey || null)) return null;
  let installed;
  const handoff = () => (installed ??= Boolean(locateAgentFile(TASK_GOPHER, cwd).path));
  const launched = r.members.filter((m) => routeHasPane(m.route || r.route) && !legworkHandedOff(m, registry, handoff));
  return launched.some((m) => !team.members.some((rec) => rec && (rec.name === m.name || rec.renamed_from === m.name)));
}

/**
 * Where an agent ref's file is: `{kind, path, level, shadowed, error}`. A bare name is looked up in
 * `<repoRoot>/.claude/agents/` then `~/.claude/agents/` — Claude Code's own project-over-user
 * order — and `shadowed` names the user file when both exist. `plugin:agent` goes through
 * `installed_plugins.json`: the first install record whose `agents/<agent>.md` exists. `error` is
 * `agent-not-found` or `plugin-unresolvable`.
 */
export function locateAgentFile(ref, cwd) {
  const colon = typeof ref === "string" ? ref.indexOf(":") : -1;
  if (colon === -1) {
    const root = findGitRoot(resolve(cwd || process.cwd())) || resolve(cwd || process.cwd());
    const repo = join(root, ".claude", "agents", `${ref}.md`);
    const user = join(homedir(), ".claude", "agents", `${ref}.md`);
    const inRepo = existsSync(repo);
    const inUser = existsSync(user);
    if (inRepo) return { kind: "bare", path: repo, level: "repo", shadowed: inUser ? user : null, error: null, candidates: [repo, user] };
    if (inUser) return { kind: "bare", path: user, level: "user", shadowed: null, error: null, candidates: [repo, user] };
    return { kind: "bare", path: null, level: null, shadowed: null, error: "agent-not-found", candidates: [repo, user] };
  }
  const plugin = ref.slice(0, colon);
  const agent = ref.slice(colon + 1);
  const records = [];
  for (const [key, list] of installedPluginEntries()) {
    if (key.split("@")[0] === plugin) records.push(...list);
  }
  const candidates = records.filter((r) => r && typeof r.installPath === "string").map((r) => join(r.installPath, "agents", `${agent}.md`));
  const path = candidates.find((p) => existsSync(p)) || null;
  return { kind: "plugin", path, level: path ? "plugin" : null, shadowed: null, error: path ? null : "plugin-unresolvable", records: records.length, candidates };
}

/** installed_plugins.json's `plugins` entries as `[key, records]`, each record list an array: the one
    reader of that file here. Empty when it can't be read. */
function installedPluginEntries() {
  try {
    const data = JSON.parse(readFileSync(installedPluginsPath(), "utf8"));
    const plugins = data && data.plugins && typeof data.plugins === "object" ? data.plugins : {};
    return Object.entries(plugins).filter(([, list]) => Array.isArray(list));
  } catch {
    return [];
  }
}

// ---------------------------------------------------------------- role packs

/**
 * A role pack is an installed Claude Code plugin whose root holds `ah-roles.json`. Nothing from a pack
 * reaches the registry until a user adopts one of its roles with `role set <name> --from
 * <plugin>@<marketplace>:<role>`, which stores only `from`, `pin` and the user's own fields; the
 * rest is read from the pack each time the row resolves. The pin covers the whole plugin tree, and
 * a role is available only while the installed tree still hashes to it and this machine holds a
 * stored copy of what the user trusted.
 */
export const PACK_MANIFEST = "ah-roles.json";
const PACK_ROLE_FIELDS = ["class", "agent", "label", "description", "routes", "model", "dispatch"];
/** The frontmatter keys a pack agent may use. Anything else could grant more than its tools do. */
export const PACK_AGENT_KEYS = ["name", "description", "model", "tools", "disallowedTools", "color", "effort", "maxTurns"];
/** Keys a pack's plugin.json may hold without being listed among what else the plugin carries. */
const PLUGIN_JSON_PLAIN_KEYS = ["name", "version", "description", "author", "homepage", "repository", "license", "keywords"];
/** The dry run's line for an implement-class pack role that routes work. */
export const UNATTENDED_LINE = "takes work in unattended /ah:pipeline runs (pushes draft PRs, does not merge)";
/** Tools the dry runs flag in a pack agent's effective list, besides every MCP tool. */
const FLAGGED_TOOLS = ["Bash", "Agent", "Write", "Edit"];
/** The name prefix Claude Code gives a tool an MCP server provides. The no-MCP check exempts this
    one line, by its exact text, so every MCP-tool check must go through it. */
const MCP_TOOL_PREFIX = "mcp__";
export const PIN_RE = /^sha256:[0-9a-f]{64}$/;
const FROM_RE = /^([A-Za-z0-9][A-Za-z0-9_.-]*)(?:@([^:@\s]+))?:([^:@\s]+)$/;
/** A word YAML (1.1 or 1.2) reads as null or a boolean rather than a string, in any case. */
const YAML_NULL_BOOL_RE = /^(~|null|true|false|yes|no|on|off|y|n)$/i;
/** A pack agent's tool entry: a plain name, so no quoting, flow list or `Tool(scope)` form. */
const PACK_TOOL_NAME_RE = /^[A-Za-z][A-Za-z0-9_-]*$/;
const isPackToolName = (e) => PACK_TOOL_NAME_RE.test(e) && !YAML_NULL_BOOL_RE.test(e);
/** Characters that hide text: control characters other than newline and tab, Unicode format
    characters (category Cf: the bidirectional controls and zero-width characters among them), the
    tag block, variation selectors (a known way to carry an invisible payload, so an emoji written
    with U+FE0F is refused too), the line and paragraph separators, and the invisible fillers. */
const HIDDEN_CHAR_RE = /[\u0000-\u0008\u000B-\u001F\u007F-\u009F\p{Cf}\u{E0000}-\u{E007F}\uFE00-\uFE0F\u{E0100}-\u{E01EF}\u2028\u2029\u034F\u115F\u1160\u3164\uFFA0]/u;
const HIDDEN_CHAR_RE_G = new RegExp(HIDDEN_CHAR_RE.source, "gu");

/** Every install record with an install path: `{key, plugin, marketplace, installPath, version, scope}`. */
export function installRecords() {
  const out = [];
  for (const [key, list] of installedPluginEntries()) {
    const at = key.indexOf("@");
    const plugin = at === -1 ? key : key.slice(0, at);
    const marketplace = at === -1 ? null : key.slice(at + 1);
    for (const r of list) {
      if (!r || typeof r.installPath !== "string") continue;
      out.push({ key, plugin, marketplace, installPath: r.installPath, version: typeof r.version === "string" ? r.version : null, scope: typeof r.scope === "string" ? r.scope : null });
    }
  }
  return out;
}

/** Install records whose install path holds a pack manifest. */
export function packRecords() {
  return installRecords().filter((r) => existsSync(join(r.installPath, PACK_MANIFEST)));
}

/** `<plugin>@<marketplace>:<role>` (marketplace optional) → `{plugin, marketplace, role}`, or null. */
export function parseFrom(from) {
  const m = typeof from === "string" ? FROM_RE.exec(from) : null;
  return m ? { plugin: m[1], marketplace: m[2] || null, role: m[3] } : null;
}

/** Whether a config row adopts a pack role. */
export function isFromRow(raw) {
  return !!raw && typeof raw === "object" && !Array.isArray(raw) && typeof raw.from === "string";
}

/** The first hidden character in `text`, as `U+XXXX at line L, column C` (1-based, columns in
    code points), or null. */
export function hiddenCharAt(text) {
  const s = String(text);
  const m = HIDDEN_CHAR_RE.exec(s);
  if (!m) return null;
  const before = s.slice(0, m.index);
  const line = before.split("\n").length;
  const column = [...before.slice(before.lastIndexOf("\n") + 1)].length + 1;
  return `U+${m[0].codePointAt(0).toString(16).toUpperCase().padStart(4, "0")} at line ${line}, column ${column}`;
}

/** Pack text made safe to print: every hidden character (ANSI escapes included) shown as `\u{…}`. */
export function escapeTerminal(text) {
  return String(text).replace(HIDDEN_CHAR_RE_G, (c) => `\\u{${c.codePointAt(0).toString(16)}}`);
}

function sha256Hex(data) {
  return createHash("sha256").update(data).digest("hex");
}

/** UTF-8 text of `buf`, keeping a byte-order mark as text; null when the bytes aren't valid UTF-8. */
function decodeUtf8(buf) {
  try {
    return new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(buf);
  } catch {
    return null;
  }
}

/** A plugin's name at `dir`: its plugin.json `name`, else the directory's basename. */
export function pluginNameAt(dir) {
  try {
    const pj = JSON.parse(readFileSync(join(dir, ".claude-plugin", "plugin.json"), "utf8"));
    if (pj && typeof pj.name === "string" && pj.name) return pj.name;
  } catch {}
  return basename(resolve(dir));
}

function checkPackRole(name, raw, plugin) {
  const warnings = [];
  const bad = (code, message) => ({ raw, agent: null, row: null, error: { code, message }, warnings });
  const nameErr = roleNameError(name);
  if (nameErr) return bad("pack-invalid", `role ${JSON.stringify(name)}: ${nameErr}`);
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) return bad("pack-invalid", `role ${name}: must be an object`);
  if (raw.peer !== undefined) return bad("pack-invalid", `role ${name}: peer is a local setting, not allowed in a pack`);
  for (const k of Object.keys(raw)) if (!PACK_ROLE_FIELDS.includes(k)) warnings.push(`role ${name}: unknown key ${JSON.stringify(k)} is ignored`);
  for (const k of PACK_ROLE_FIELDS) {
    const at = typeof raw[k] === "string" ? hiddenCharAt(raw[k]) : null;
    if (at) return bad("pack-hidden-chars", `role ${name}: ${k} holds a hidden character (${at})`);
  }
  const agent = raw.agent === undefined ? name : raw.agent;
  if (typeof agent !== "string" || !agent || /[:/\\]|\.\./.test(agent)) {
    return bad("pack-invalid", `role ${name}: agent ${JSON.stringify(agent)} must name an agent in this plugin, with no ":", "/", "\\" or ".."`);
  }
  const fields = Object.fromEntries(PACK_ROLE_FIELDS.filter((k) => raw[k] !== undefined).map((k) => [k, raw[k]]));
  const checked = checkCustomRow(name, { ...fields, agent: `${plugin}:${agent}` });
  if (checked.error) return bad("pack-invalid", `role ${name}: ${checked.error}`);
  warnings.push(...checked.warnings.map((w) => `role ${name}: ${w}`));
  return { raw, agent, row: checked.row, error: null, warnings };
}

/**
 * A pack's `ah-roles.json` at `dir`, read and checked. Never throws. `{error, warnings, roles}`:
 * `error` (`{code, message}`) when the whole pack is unreadable — code `pack-missing`, `pack-invalid`
 * or `pack-version`. Each role is `{raw, agent, row, error, warnings}`: `raw` the row as written,
 * `agent` its agent's name in the plugin, `row` the checked custom row (agent `<plugin>:<agent>`),
 * `error` a `{code, message}` when the role can't be used.
 */
export function readPackManifest(dir, plugin) {
  const path = join(dir, PACK_MANIFEST);
  const unreadable = (code, message) => ({ error: { code, message }, warnings: [], roles: {} });
  let text;
  try {
    text = readFileSync(path, "utf8");
  } catch {
    return unreadable("pack-missing", `no ${PACK_MANIFEST} in ${dir}`);
  }
  let data;
  try {
    data = JSON.parse(text);
  } catch {
    return unreadable("pack-invalid", `${path} is not valid JSON`);
  }
  if (!data || typeof data !== "object" || Array.isArray(data)) return unreadable("pack-invalid", `${path} must hold a JSON object`);
  if (data.version !== 1) return unreadable("pack-version", `${path}: version must be 1, got ${JSON.stringify(data.version)}`);
  if (!data.roles || typeof data.roles !== "object" || Array.isArray(data.roles)) return unreadable("pack-invalid", `${path}: roles must be an object`);
  const warnings = Object.keys(data).filter((k) => k !== "version" && k !== "roles").map((k) => `unknown key ${JSON.stringify(k)} is ignored`);
  const roles = {};
  for (const [name, raw] of Object.entries(data.roles)) roles[name] = checkPackRole(name, raw, plugin);
  return { error: null, warnings, roles };
}

const packTreeCache = new Map();

/**
 * Every regular file under `root` as `[relpath, sha256hex]` pairs sorted by path (`/` separators, a
 * top-level .git skipped), with the first symbolic link met (never followed) as `symlink`. Cached
 * for the life of the process, since every adopted role from one plugin reads the same tree.
 */
export function packTree(root) {
  if (packTreeCache.has(root)) return packTreeCache.get(root);
  const files = [];
  let symlink = null;
  const walk = (dir, rel) => {
    for (const name of readdirSync(dir)) {
      if (!rel && name === ".git") continue;
      const p = join(dir, name);
      const r = rel ? `${rel}/${name}` : name;
      const st = lstatSync(p);
      if (st.isSymbolicLink()) symlink ||= r;
      else if (st.isDirectory()) walk(p, r);
      else if (st.isFile()) files.push([r, sha256Hex(readFileSync(p))]);
    }
  };
  let result;
  try {
    walk(root, "");
    files.sort((a, b) => (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0));
    result = { files, symlink, error: null };
  } catch (err) {
    result = { files: [], symlink: null, error: err && err.message ? err.message : String(err) };
  }
  packTreeCache.set(root, result);
  return result;
}

/** The pin: `sha256:` over `JSON.stringify([1, row, agentText, files])`, `row`'s keys sorted. This
    form is permanent: every stored pin depends on it. */
export function packPin(row, agentText, files) {
  const sorted = Object.fromEntries(Object.keys(row).sort().map((k) => [k, row[k]]));
  return `sha256:${sha256Hex(Buffer.from(JSON.stringify([1, sorted, agentText, files]), "utf8"))}`;
}

/** A tree's content digest: `sha256:` over `JSON.stringify(files)`. */
export function packDigest(files) {
  return `sha256:${sha256Hex(Buffer.from(JSON.stringify(files), "utf8"))}`;
}

function storedCopyPath(pin) {
  return join(homedir(), ".claude", "agent-hierarchy", "trusted", `${pin.slice("sha256:".length)}.json`);
}

/** This machine's stored copy for `pin` — `{row, agentText, files}` — only when it re-hashes to `pin`. */
export function readStoredCopy(pin) {
  if (typeof pin !== "string" || !PIN_RE.test(pin)) return null;
  try {
    const c = JSON.parse(readFileSync(storedCopyPath(pin), "utf8"));
    if (c && c.row && typeof c.row === "object" && typeof c.agentText === "string" && Array.isArray(c.files) && packPin(c.row, c.agentText, c.files) === pin) return c;
  } catch {}
  return null;
}

/** Store what `pin` was computed from, keyed by the pin so every repo on this machine shares it. */
export function writeStoredCopy(pin, { row, agentText, files }) {
  const path = storedCopyPath(pin);
  mkdirSync(dirname(path), { recursive: true });
  const sorted = Object.fromEntries(Object.keys(row).sort().map((k) => [k, row[k]]));
  writeFileSync(path, `${JSON.stringify({ row: sorted, agentText, files })}\n`, "utf8");
  return path;
}

/**
 * The agent name a (non-pack-checked) agent file declares, read as YAML would: `{name}`, `{none}`
 * (no `name`, or a null one, or no frontmatter) or `{unsure}` when ah can't be sure — an escape in a
 * quoted key, a YAML tag, anchor, alias or merge key, a complex or flow key at the top level, more
 * than one `name` key, or a `name` value that spans lines, is a flow collection or doesn't decode.
 */
function declaredAgentName(text) {
  const lines = text.split(/\r?\n/);
  if (lines[0].replace(/^﻿/, "").trim() !== "---") return { none: true };
  const end = lines.findIndex((l, i) => i > 0 && l.trim() === "---");
  if (end === -1) return { none: true };
  const unsure = { unsure: true };
  let value;
  let count = 0;
  for (let i = 1; i < end; i++) {
    const line = lines[i];
    if (!line.trim() || /^\s*#/.test(line)) continue;
    const node = line.replace(/^\s*(?:-\s+)*/, "");
    if (/^[&*!]/.test(node) || /^(?:"(?:[^"\\]|\\.)*"|'(?:[^']|'')*'|[^\s"'#][^:]*?)\s*:\s+[&*!]/.test(node) || /^<<\s*:/.test(node)) return unsure;
    if (/^\s/.test(line) || /^-(\s|$)/.test(line)) continue;
    if (/^(\?|[{[])/.test(line)) return unsure;
    let m;
    let key;
    let rest;
    if ((m = /^"((?:[^"\\]|\\.)*)"\s*:(?:\s+(.*))?$/.exec(line))) {
      if (m[1].includes("\\")) return unsure;
      [key, rest] = [m[1], m[2]];
    } else if ((m = /^'((?:[^']|'')*)'\s*:(?:\s+(.*))?$/.exec(line))) {
      if (m[1].includes("''")) return unsure;
      [key, rest] = [m[1], m[2]];
    } else if ((m = /^(.*?)\s*:(?:\s+(.*))?$/.exec(line))) [key, rest] = [m[1], m[2]];
    else continue;
    if (key !== "name") continue;
    count += 1;
    const next = lines.slice(i + 1, end).find((l) => l.trim() && !/^\s*#/.test(l));
    if (next !== undefined && /^\s/.test(next)) return unsure;
    const v = (rest || "").trim();
    if (v[0] === '"') {
      try {
        value = JSON.parse(v.replace(/\s+#.*$/, ""));
      } catch {
        return unsure;
      }
    } else if (v[0] === "'") {
      const q = /^'((?:[^']|'')*)'(?:\s+#.*)?$/.exec(v);
      if (!q) return unsure;
      value = q[1].replace(/''/g, "'");
    } else if (/^[|>[{]/.test(v)) return unsure;
    else {
      const plain = v.replace(/\s+#.*$/, "");
      value = plain === "" || /^(~|null|Null|NULL)$/.test(plain) ? null : plain;
    }
  }
  if (count > 1) return unsure;
  return value === null || value === undefined ? { none: true } : { name: String(value) };
}

/** The finding for agent files that take pack agent `agent`'s name. */
export function packClaimMessage(plugin, agent, files) {
  return `${files.map(escapeTerminal).join(", ")} also ${files.length > 1 ? "take" : "takes"} the agent name ${agent}, so Claude Code might launch ${files.length > 1 ? "one of them" : "it"} as ${escapeTerminal(plugin)}:${agent} instead of agents/${agent}.md`;
}

const packClaimsCache = new Map();

/**
 * Agent files that take a pack role's agent name. Claude Code registers a plugin agent under its
 * frontmatter `name`, so any `.md` (any case, any depth) under `agents/` or under a path in
 * plugin.json's `agents` could be what `<plugin>:<agent>` launches. A file other than the role's own
 * claims the role when it declares that name, when it declares none and its file name is that name
 * (both compared ignoring case, since whether Claude Code does isn't known), or when ah can't be
 * sure what it declares (then it claims every role). `{error, byRole, files}`:
 * `error` is a message when plugin.json's `agents` isn't a path or a list of paths, or one resolves
 * outside `dir`; `byRole` maps a role to the claiming files, and `files` a file to the roles it
 * claims, both by `/`-separated path relative to `dir`.
 */
export function packNameClaims(dir, manifest) {
  if (packClaimsCache.has(dir)) return packClaimsCache.get(dir);
  const result = { error: null, byRole: new Map(), files: new Map() };
  packClaimsCache.set(dir, result);
  const found = new Set();
  const walk = (p) => {
    let st;
    try {
      st = lstatSync(p);
    } catch {
      return;
    }
    if (st.isDirectory()) for (const n of readdirSync(p)) walk(join(p, n));
    else if (st.isFile() && /\.md$/i.test(p)) found.add(p);
  };
  walk(join(dir, "agents"));
  let pj = null;
  try {
    pj = JSON.parse(readFileSync(join(dir, ".claude-plugin", "plugin.json"), "utf8"));
  } catch {}
  if (pj && typeof pj === "object" && !Array.isArray(pj) && pj.agents !== undefined) {
    const paths = typeof pj.agents === "string" ? [pj.agents] : Array.isArray(pj.agents) && pj.agents.every((p) => typeof p === "string") ? pj.agents : null;
    if (!paths) {
      result.error = "plugin.json's agents must be a path or a list of paths";
      return result;
    }
    for (const p of paths) {
      const rel = relative(dir, resolve(dir, p));
      if (rel === ".." || rel.startsWith(`..${sep}`) || isAbsolute(rel)) {
        result.error = `plugin.json's agents path ${escapeTerminal(JSON.stringify(p))} resolves outside the plugin`;
        return result;
      }
      walk(resolve(dir, p));
    }
  }
  const sameFile = (a, b) => {
    try {
      const x = statSync(a);
      const y = statSync(b);
      return x.ino === y.ino && x.dev === y.dev;
    } catch {
      return false;
    }
  };
  const roles = Object.entries((manifest && manifest.roles) || {}).filter(([, m]) => m && m.agent && !m.error);
  for (const abs of [...found].sort()) {
    let decl;
    try {
      const text = decodeUtf8(readFileSync(abs));
      decl = text === null ? { unsure: true } : declaredAgentName(text);
    } catch {
      decl = { unsure: true };
    }
    const rel = relative(dir, abs).split(sep).join("/");
    for (const [role, m] of roles) {
      if (sameFile(abs, join(dir, "agents", `${m.agent}.md`))) continue;
      const agent = m.agent.toLowerCase();
      if (!(decl.unsure || (decl.name !== undefined && decl.name.toLowerCase() === agent) || (decl.none && basename(abs).replace(/\.md$/i, "").toLowerCase() === agent))) continue;
      if (!result.byRole.has(role)) result.byRole.set(role, []);
      result.byRole.get(role).push(rel);
      if (!result.files.has(rel)) result.files.set(rel, []);
      result.files.get(rel).push(role);
    }
  }
  return result;
}

/** One install record's view of pack role `role`: status "ok" with the pin, or the reason it can't be used. */
function packCandidate(record, role) {
  const base = { record, status: "ok", message: null, subcode: null, manifestRole: null, agentText: null, agentPath: null, files: null, pin: null };
  const manifest = readPackManifest(record.installPath, record.plugin);
  if (manifest.error) {
    return { ...base, status: manifest.error.code === "pack-missing" ? "pack-missing" : "pack-invalid", subcode: manifest.error.code, message: manifest.error.message };
  }
  const r = manifest.roles[role];
  if (!r) return { ...base, status: "pack-missing", message: `${record.key} offers no role ${role}` };
  if (r.error) return { ...base, status: "pack-invalid", subcode: r.error.code, message: r.error.message, manifestRole: r };
  const agentPath = join(record.installPath, "agents", `${r.agent}.md`);
  let buf;
  try {
    buf = readFileSync(agentPath);
  } catch {
    return { ...base, status: "pack-invalid", message: `${record.key} has no agents/${r.agent}.md`, manifestRole: r, agentPath };
  }
  const agentText = decodeUtf8(buf);
  if (agentText === null) return { ...base, status: "pack-invalid", message: `${agentPath} is not valid UTF-8`, manifestRole: r, agentPath };
  const hidden = hiddenCharAt(agentText);
  if (hidden) return { ...base, status: "pack-invalid", subcode: "pack-hidden-chars", message: `${agentPath} holds a hidden character (${hidden})`, manifestRole: r, agentPath };
  const claims = packNameClaims(record.installPath, manifest);
  if (claims.error) return { ...base, status: "pack-invalid", message: `${record.key}: ${claims.error}`, manifestRole: r, agentText, agentPath };
  const claimedBy = claims.byRole.get(role);
  if (claimedBy) return { ...base, status: "pack-invalid", message: packClaimMessage(record.plugin, r.agent, claimedBy), manifestRole: r, agentText, agentPath };
  const tree = packTree(record.installPath);
  if (tree.error) return { ...base, status: "pack-invalid", message: `${record.installPath} could not be read: ${tree.error}`, manifestRole: r, agentText, agentPath };
  if (tree.symlink) return { ...base, status: "pack-symlink", message: `${record.installPath} holds a symbolic link, ${tree.symlink}, and what it points at isn't pinned`, manifestRole: r, agentText, agentPath };
  return { ...base, manifestRole: r, agentText, agentPath, files: tree.files, pin: packPin(r.raw, agentText, tree.files) };
}

/**
 * Pack role `from` as installed now, checked against `pin` (null skips the pin and stored-copy
 * checks, for a first adoption). Every install record of the plugin's name is a candidate, since
 * Claude Code resolves `<plugin>:<agent>` by that name alone. `status` is "ok" or the first that
 * applies of: pack-missing, pack-invalid, pack-ambiguous, pack-symlink, pack-changed,
 * pack-untrusted-here. The rest is the candidate for the recorded marketplace (else the first).
 */
export function packRoleState(from, pin = null) {
  const f = parseFrom(from);
  if (!f || !f.marketplace) return { status: "pack-invalid", message: `from ${JSON.stringify(from)} must be <plugin>@<marketplace>:<role>`, from: f, records: [] };
  const records = installRecords().filter((r) => r.plugin === f.plugin);
  if (!records.length) return { status: "pack-missing", message: `plugin ${f.plugin} is not installed`, from: f, records: [] };
  const listed = records.map((r) => `${r.key} (${r.installPath})`);
  // Only the recorded marketplace's install counts as this pack: another marketplace's plugin of the
  // same name is someone else's content, never a stand-in for it.
  if (!records.some((r) => r.marketplace === f.marketplace)) {
    return { status: "pack-missing", message: `${f.plugin}@${f.marketplace} is not installed (installed under that name: ${listed.join(", ")})`, from: f, records: listed };
  }
  const candidates = records.map((r) => packCandidate(r, f.role));
  const chosen = candidates.find((c) => c.record.marketplace === f.marketplace);
  const state = { ...chosen, from: f, records: listed };
  if (chosen.status === "pack-missing" || chosen.status === "pack-invalid") return state;
  if (new Set(candidates.map((c) => c.pin || c.status)).size > 1) {
    return { ...state, status: "pack-ambiguous", message: `${records.length} install records of ${f.plugin} differ, and which one Claude Code loads can't be known: ${state.records.join(", ")}` };
  }
  if (chosen.status !== "ok" || pin === null) return state;
  if (chosen.pin !== pin) return { ...state, status: "pack-changed", message: `${f.plugin} changed since this role was trusted (pinned ${String(pin).slice(0, 19)}…, now ${chosen.pin.slice(0, 19)}…)` };
  if (!readStoredCopy(pin)) return { ...state, status: "pack-untrusted-here", message: `this machine holds no stored copy of what ${pin.slice(0, 19)}… pinned, so nobody here has trusted it` };
  return state;
}

/**
 * A `from` row expanded into the full row resolution checks: the pack's own fields (from the
 * installed manifest, else from this machine's stored copy for the row's pin), with the row's own
 * `label`, `description`, `routes`, `model` and `dispatch` laid over them; an empty `routes` or
 * `description` removes the field, so `--routes ""` makes a side role. `{raw, pack}`, or `{error}`
 * when nothing on this machine says what the role is.
 */
export function expandFromRow(entry) {
  const state = packRoleState(entry.from, typeof entry.pin === "string" ? entry.pin : "");
  const f = state.from;
  let source = state.manifestRole && !state.manifestRole.error ? state.manifestRole.raw : null;
  if (!source) {
    const copy = readStoredCopy(entry.pin);
    if (copy) source = copy.row;
  }
  if (!f || !source) return { error: `${state.status}: ${state.message}` };
  const raw = {};
  for (const k of PACK_ROLE_FIELDS) if (source[k] !== undefined) raw[k] = source[k];
  raw.agent = `${f.plugin}:${source.agent === undefined ? f.role : source.agent}`;
  for (const k of ["label", "description", "routes", "model", "dispatch"]) {
    if (entry[k] === undefined) continue;
    if (entry[k] === "" && (k === "routes" || k === "description")) delete raw[k];
    else raw[k] = entry[k];
  }
  const pack = {
    status: state.status,
    message: state.message,
    subcode: state.subcode || null,
    from: entry.from,
    agentText: state.agentText,
    agentPath: state.agentPath,
    pinNow: state.pin,
  };
  return { raw, pack };
}

const indentOf = (line) => line.length - line.trimStart().length;

/**
 * Why YAML would refuse a one-line value, or read it as something other than its text; null when
 * it reads as written. A quoted value must close at the end of the line with no escape inside. A
 * plain one can't hold `: `, end in `:`, or start with a YAML indicator (`&`, `*` and `#` have
 * their own findings).
 */
function yamlValueProblem(value) {
  if (value[0] === '"' || value[0] === "'") {
    return /^"[^"\\]*"$|^'[^']*'$/.test(value) ? null : "a quoted value must close at the end of the line, with no escape inside (no \\ or '')";
  }
  if (/:(\s|$)/.test(value)) return 'a plain value can\'t hold ": " or end in ":" (quote it)';
  if (YAML_NULL_BOOL_RE.test(value)) return "a plain value YAML reads as null or a boolean (quote it)";
  if (/^([@`%!|>[\]{},?]|-(\s|$))/.test(value)) return "a plain value can't start with a YAML indicator (quote it)";
  return null;
}

/**
 * The one reader of a pack agent's frontmatter, strict so that it reads exactly what YAML would:
 * only `PACK_AGENT_KEYS`, each written once as an unquoted top-level key; a continuation only as a
 * `- item` under an empty-valued `tools` or `disallowedTools`, or as a line of a `|` / `>` block
 * scalar under `description`, list items at the first item's indentation and block lines at least
 * at the first line's; a one-line value that YAML reads as written; no tab in indentation, no `#` comment, no YAML anchor, alias or merge
 * key, no line that can't be classified; `tools` required and non-empty, and every tool entry a
 * plain name. `{findings, fm}`: every finding is an error, and `fm` (the shape
 * `parseAgentFrontmatter` returns) is what the dry run shows and the class contract judges. It fails
 * closed: a quoted `"permissionMode":` is valid YAML to Claude Code even though ah's lenient reader
 * skips it. A user's own files aren't held to it.
 */
export function packAgentParse(text, path = null) {
  const findings = [];
  const fm = { frontmatter: false, name: null, description: null, model: null, tools: null, disallowedTools: null, parseErrors: [] };
  const err = (code, message) =>
    findings.push(finding("error", code, path, null, message, [{ kind: "edit-frontmatter", detail: `a pack agent's frontmatter may hold only ${PACK_AGENT_KEYS.join(", ")}, as plain unquoted keys` }]));
  const lines = String(text).split("\n");
  const end = lines[0] === "---" ? lines.findIndex((l, i) => i > 0 && l === "---") : -1;
  if (end === -1) {
    err("pack-agent-frontmatter", "no --- frontmatter block");
    return { findings, fm };
  }
  fm.frontmatter = true;
  const seen = new Set();
  // The key whose continuation lines may follow: kind "list" (an empty tools or disallowedTools:
  // `- item` lines), "block" (description's `|` or `>` block: indented text) or "none".
  let cur = null;
  const toolEntries = (key, entries) => {
    const bad = entries.filter((e) => !isPackToolName(e));
    for (const e of bad) err("pack-agent-tools", `${key} entry ${JSON.stringify(e)} isn't a plain tool name (letters, digits, _ and -, and not a word YAML reads as null or a boolean)`);
    fm[key] = entries.filter(isPackToolName);
  };
  const finish = () => {
    if (!cur) return;
    const { key, kind } = cur;
    if (key === "tools" || key === "disallowedTools") toolEntries(key, kind === "list" ? cur.items : cur.value.split(",").map((e) => e.trim()));
    else if (key === "description") {
      if (kind === "block") {
        const block = [...cur.block];
        while (block.length && !block[block.length - 1]) block.pop();
        fm.description = cur.style[0] === "|" ? block.join("\n") : block.filter((l) => l).join(" ");
      } else fm.description = unquote(cur.value) || null;
    } else if (key === "name" || key === "model") fm[key] = unquote(cur.value) || null;
    cur = null;
  };
  for (const line of lines.slice(1, end)) {
    if (!line.trim()) {
      if (cur && cur.kind === "block") cur.block.push("");
      continue;
    }
    if (/^[ ]*\t/.test(line)) {
      err("pack-agent-line", `line ${JSON.stringify(line)} is indented with a tab`);
      continue;
    }
    if (/(^|\s)#/.test(line)) {
      err("pack-agent-line", `line ${JSON.stringify(line)} holds a # comment, which YAML would drop`);
      continue;
    }
    if (/^\s/.test(line) || /^-(\s|$)/.test(line)) {
      if (!cur) err("pack-agent-line", `line ${JSON.stringify(line)} continues no key`);
      else if (cur.kind === "list") {
        const item = /^\s*-\s+(\S.*)$/.exec(line);
        if (item) cur.indent ??= indentOf(line);
        if (!item) err("pack-agent-line", `line ${JSON.stringify(line)} isn't a "- item" of the list above`);
        else if (indentOf(line) !== cur.indent) err("pack-agent-line", `line ${JSON.stringify(line)} isn't indented like the list's first item`);
        else if (/^[&*]/.test(item[1]) || /<<\s*:/.test(item[1])) err("pack-agent-yaml", `YAML anchor, alias or merge key: ${JSON.stringify(line.trim())}`);
        else cur.items.push(item[1].trim());
      } else if (cur.kind === "block") {
        if (/^\s/.test(line)) cur.indent ??= indentOf(line);
        if (!/^\s/.test(line)) err("pack-agent-line", `line ${JSON.stringify(line)} isn't indented inside the block above`);
        else if (indentOf(line) < cur.indent) err("pack-agent-line", `line ${JSON.stringify(line)} is indented less than the block's first line, which ends the block, yet it isn't a key`);
        else cur.block.push(line.slice(cur.indent));
      } else {
        err("pack-agent-line", `line ${JSON.stringify(line)} continues a one-line value — use "- item" lines under an empty tools or disallowedTools, or a | or > block under description`);
      }
      continue;
    }
    finish();
    if (/^<<\s*:/.test(line)) {
      err("pack-agent-yaml", `YAML merge key: ${JSON.stringify(line)}`);
      continue;
    }
    if (/^["']/.test(line)) {
      err("pack-agent-quoted-key", `quoted key: ${JSON.stringify(line)}`);
      continue;
    }
    const m = /^([A-Za-z][A-Za-z0-9_-]*):(?:\s(.*)|$)/.exec(line);
    if (!m) {
      err("pack-agent-line", `line ${JSON.stringify(line)} can't be classified`);
      continue;
    }
    const key = m[1];
    const value = (m[2] || "").trim();
    if (!PACK_AGENT_KEYS.includes(key)) err("pack-agent-key", `key ${key} isn't allowed in a pack agent`);
    if (seen.has(key)) err("pack-agent-duplicate-key", `key ${key} appears twice`);
    seen.add(key);
    if (/^[&*]/.test(value)) err("pack-agent-yaml", `YAML anchor or alias: ${JSON.stringify(line)}`);
    const toolKey = key === "tools" || key === "disallowedTools";
    if (/^[|>][-+]?$/.test(value)) {
      if (key === "description") cur = { key, kind: "block", style: value, block: [] };
      else {
        err("pack-agent-line", `only description may use a | or > block, not ${key}`);
        cur = { key, kind: "none", value: "" };
      }
    } else if (value === "" && toolKey) cur = { key, kind: "list", items: [] };
    else {
      let why = value ? yamlValueProblem(value) : null;
      if (!why && key === "maxTurns" && !/^-?(0|[1-9][0-9]*)$/.test(value)) why = "maxTurns must be a plain decimal integer";
      if (why) err("pack-agent-line", `line ${JSON.stringify(line)}: ${why}`);
      cur = { key, kind: "none", value };
    }
  }
  finish();
  if (!seen.has("tools")) err("pack-agent-tools", "tools is required: without it the agent inherits every tool, MCP tools and Agent included");
  else if (!fm.tools || !fm.tools.length) err("pack-agent-tools", "tools must be a non-empty list");
  return { findings, fm };
}

/** The pack-agent frontmatter findings — `packAgentParse`'s. */
export function packAgentFindings(text, path = null) {
  return packAgentParse(text, path).findings;
}

/** A pack agent's effective tools (its `tools` less `disallowedTools`) and the ones worth flagging,
    from `fm`, the frontmatter `packAgentParse` read. */
export function packToolReport(fm) {
  const disallowed = fm.disallowedTools || [];
  const effective = (fm.tools || []).filter((t) => !disallowed.includes(t));
  const flagged = effective.filter((t) => FLAGGED_TOOLS.includes(t) || t.startsWith(MCP_TOOL_PREFIX));
  return { effective, flagged };
}

/**
 * What a plugin at `dir` carries besides its roles, found by exclusion so a new kind of component is
 * listed without a code change: root entries other than the manifest, `agents/`, `.claude-plugin/`
 * and README, LICENSE or CHANGELOG files; plugin.json keys beyond the descriptive ones; and agent
 * files the manifest doesn't name.
 */
export function packExtras(dir, manifest) {
  const extras = [];
  let entries = [];
  try {
    entries = readdirSync(dir).sort();
  } catch {}
  for (const name of entries) {
    if ([PACK_MANIFEST, "agents", ".claude-plugin"].includes(name) || /^(README|LICENSE|CHANGELOG)(\..*)?$/i.test(name)) continue;
    extras.push({ kind: "root", name });
  }
  try {
    const pj = JSON.parse(readFileSync(join(dir, ".claude-plugin", "plugin.json"), "utf8"));
    if (pj && typeof pj === "object" && !Array.isArray(pj)) {
      for (const k of Object.keys(pj)) if (!PLUGIN_JSON_PLAIN_KEYS.includes(k)) extras.push({ kind: "plugin.json", name: k });
    }
  } catch {}
  const named = new Set(Object.values((manifest && manifest.roles) || {}).map((r) => r.agent).filter(Boolean));
  let agents = [];
  try {
    agents = readdirSync(join(dir, "agents")).filter((n) => n.endsWith(".md")).sort();
  } catch {}
  for (const n of agents) if (!named.has(n.slice(0, -3))) extras.push({ kind: "agent", name: `agents/${n}` });
  const claims = packNameClaims(dir, manifest).files;
  for (const e of extras) if (e.kind === "agent" && claims.has(e.name)) e.claims = claims.get(e.name);
  for (const [rel, roles] of claims) if (!extras.some((e) => e.kind === "agent" && e.name === rel)) extras.push({ kind: "agent", name: rel, claims: roles });
  return extras;
}

const TOOL_TOKEN_RE = /^(\*|[A-Za-z_][A-Za-z0-9_.-]*(\([^()]*\))?)$/;

function unquote(v) {
  const t = v.trim();
  if (t.length >= 2 && t[0] === '"' && t[t.length - 1] === '"') {
    return t.slice(1, -1).replace(/\\(["\\nt])/g, (_, c) => (c === "n" ? "\n" : c === "t" ? "\t" : c));
  }
  if (t.length >= 2 && t[0] === "'" && t[t.length - 1] === "'") return t.slice(1, -1).replace(/''/g, "'");
  return t;
}

/** A tools field value → array of entries, or null when it is not one of the three list forms. */
function parseToolList(value, blockItems) {
  if (blockItems) {
    const items = blockItems.map(unquote);
    return items.every((i) => TOOL_TOKEN_RE.test(i)) ? items : null;
  }
  let t = value.trim();
  if (t.startsWith("[")) {
    if (!t.endsWith("]")) return null;
    t = t.slice(1, -1);
    if (!t.trim()) return [];
  } else if (/^["']/.test(t)) {
    t = unquote(t);
  }
  const items = t.split(",").map((i) => unquote(i)).filter((i) => i !== "");
  return items.length && items.every((i) => TOOL_TOKEN_RE.test(i)) ? items : null;
}

/**
 * Parse an agent file's frontmatter without a YAML dependency. Reads only `name`, `description`,
 * `model`, `tools` and `disallowedTools`. Never throws: fields that are present but unparseable are
 * named in `parseErrors`.
 */
export function parseAgentFrontmatter(text) {
  const out = { frontmatter: false, name: null, description: null, model: null, tools: null, disallowedTools: null, parseErrors: [] };
  const lines = String(text).split(/\r?\n/);
  if (lines[0].trim() !== "---") return out;
  const end = lines.findIndex((l, i) => i > 0 && l.trim() === "---");
  if (end === -1) return out;
  out.frontmatter = true;
  const body = lines.slice(1, end);
  const wanted = { name: "name", description: "description", model: "model", tools: "tools", disallowedTools: "disallowedTools" };
  for (let i = 0; i < body.length; i++) {
    const m = /^([A-Za-z][A-Za-z0-9_-]*):(?:\s(.*)|$)/.exec(body[i]);
    if (!m) continue;
    const key = m[1];
    const raw = m[2] === undefined ? "" : m[2];
    // Continuation lines: anything indented, or a `- ` list item, up to the next top-level key.
    const cont = [];
    let j = i + 1;
    while (j < body.length && (/^\s/.test(body[j]) || /^-(\s|$)/.test(body[j]) || body[j].trim() === "")) cont.push(body[j++]);
    i = j - 1;
    if (!wanted[key]) continue;
    const field = wanted[key];
    const v = raw.trim();
    if (field === "tools" || field === "disallowedTools") {
      const items = cont.filter((l) => l.trim());
      const isBlock = v === "" && items.length && items.every((l) => /^\s*-\s+\S/.test(l));
      const list = v === "" && !items.length ? null : parseToolList(v, isBlock ? items.map((l) => l.replace(/^\s*-\s+/, "")) : null);
      if (list === null) out.parseErrors.push(field);
      else out[field] = list;
      continue;
    }
    if (field === "description") {
      // Never a parse error: block scalars keep their form, a multi-line plain scalar is folded.
      if (/^[|>][-+]?$/.test(v)) {
        const block = cont.map((l) => l.replace(/^\s+/, ""));
        while (block.length && !block[block.length - 1]) block.pop();
        out.description = v[0] === "|" ? block.join("\n") : block.filter((l) => l).join(" ");
      } else {
        const folded = [unquote(v), ...cont.map((l) => l.trim())].filter((l) => l).join(" ");
        out.description = folded || null;
      }
      continue;
    }
    if (/^[|>][-+]?$/.test(v)) {
      const block = cont.map((l) => l.replace(/^\s+/, ""));
      while (block.length && !block[block.length - 1]) block.pop();
      out[field] = v[0] === "|" ? block.join("\n") : block.filter((l) => l).join(" ");
      continue;
    }
    if (v === "" || /^[[{]/.test(v) || /[\s,]/.test(unquote(v))) {
      out.parseErrors.push(field);
      continue;
    }
    out[field] = unquote(v);
  }
  return out;
}

/**
 * The frontmatter reader: locate an agent ref's file and parse it. Never throws. Returns
 * `{found, frontmatter, name, description, model, tools, disallowedTools, parseErrors, location}`.
 * Callers are SessionStart, SubagentStart-free CLI paths and spawn — never a per-tool-call hook.
 */
export function readAgentFile(ref, cwd) {
  let location;
  try {
    location = locateAgentFile(ref, cwd);
  } catch {
    location = { kind: "bare", path: null, level: null, shadowed: null, error: "agent-not-found", candidates: [] };
  }
  const empty = { found: null, frontmatter: false, name: null, description: null, model: null, tools: null, disallowedTools: null, parseErrors: [], location };
  if (!location.path) return empty;
  try {
    return { ...parseAgentFrontmatter(readHead(location.path)), found: location.path, location };
  } catch {
    return { ...empty, found: location.path, unreadable: true };
  }
}

/** Frontmatter description → one directive-safe line (≤160 chars). Null when there is nothing left. */
export function normalizeDescription(text) {
  if (typeof text !== "string") return null;
  let t = text.replace(/<example>[\s\S]*?<\/example>/gi, " ").replace(/\\n/g, " ").replace(/`/g, "").replace(/\s+/g, " ").trim();
  if (!t) return null;
  const first = /^(.*?[.!?])(\s|$)/.exec(t);
  if (first && first[1].length <= ONE_LINE_MAX) return first[1];
  return t.length <= ONE_LINE_MAX ? t : `${t.slice(0, ONE_LINE_MAX - 3)}…`;
}

/** A model value's family alias (`claude-opus-5-5` → `opus`); `inherit` and aliases map to themselves. */
function modelAlias(model) {
  if (typeof model !== "string") return null;
  if (model === "inherit") return model;
  const m = model.toLowerCase().match(/(?:^|[^a-z])(haiku|sonnet|opus|fable)(?:[^a-z]|$)/);
  return m ? m[1] : model;
}

function finding(level, code, path, field, message, fix) {
  return { level, code, path: path || null, field: field || null, message, fix };
}

/**
 * The class-contract validator. Checks one custom row, or one built-in override, against its
 * class's contract: the agent file exists and has frontmatter, its `name` matches, its model is in
 * the class allowlist, its effective tools meet the required/forbidden/discouraged table, and it
 * is not shadowed. Returns `{findings, file, description}`; `description` is the effective one
 * (config first, else the normalised frontmatter description) with its `source`.
 *
 * `inMemory` (`{path, text}`) validates text that is not on disk yet — a scaffold under `--dry-run`.
 *
 * @param {{role: string, cls: string, agent: string, description?: string|null, builtin?: boolean, cwd: string, inMemory?: {path: string, text: string}|null}} spec
 */
export function validateAgentContract({ role, cls, agent, description = null, builtin = false, cwd, inMemory = null }) {
  const findings = [];
  // `inMemory.fm`, when given, is frontmatter already read (a pack agent's strict parse): it is
  // judged as it is, so the contract and the dry run read one parse.
  const file = inMemory
    ? { ...(inMemory.fm || parseAgentFrontmatter(inMemory.text)), found: inMemory.path, location: { kind: "bare", path: inMemory.path, level: null, shadowed: null, error: null, candidates: [inMemory.path] } }
    : readAgentFile(agent, cwd);
  const loc = file.location;
  const scaffoldFix = [
    { kind: "scaffold", detail: `roster.mjs role set ${role} --scaffold repo (or --scaffold user) writes a template that passes the ${cls} contract` },
  ];
  const effDescription = description
    ? { text: description, source: "config" }
    : file.description && normalizeDescription(file.description)
      ? { text: normalizeDescription(file.description), source: "frontmatter" }
      : { text: null, source: null };
  if (loc.error === "agent-not-found") {
    findings.push(finding("error", "agent-not-found", null, null, `No agent file for ${JSON.stringify(agent)}: looked in ${loc.candidates.join(" and ")}.`, [
      ...(builtin ? [] : scaffoldFix),
      ...loc.candidates.map((p) => ({ kind: "create-file", detail: p })),
    ]));
    return { findings, file, description: effDescription };
  }
  if (loc.error === "plugin-unresolvable") {
    const why = loc.records ? `no agents/${agent.split(":")[1]}.md under its install path(s)` : "the plugin has no install record in ~/.claude/plugins/installed_plugins.json";
    findings.push(finding("error", "plugin-unresolvable", null, null, `Cannot validate ${JSON.stringify(agent)}: ${why}.`, [
      { kind: "copy-agent", detail: `copy the agent into .claude/agents/${role}.md as a user-owned file, then point the role at the bare name ${role}` },
    ]));
    return { findings, file, description: effDescription };
  }
  const path = file.found;
  if (file.unreadable) {
    findings.push(finding("error", "no-frontmatter", path, null, `${path} could not be read.`, [{ kind: "edit-frontmatter", detail: `make ${path} readable, with a --- frontmatter block` }]));
    return { findings, file, description: effDescription };
  }
  if (!file.frontmatter) {
    findings.push(finding("error", "no-frontmatter", path, null, `${path} has no --- frontmatter block, so Claude Code cannot load it as an agent.`, [
      { kind: "edit-frontmatter", detail: `add a --- block at the top with name: ${agent.split(":").pop()} and a description` },
    ]));
    return { findings, file, description: effDescription };
  }
  for (const field of file.parseErrors) {
    findings.push(finding("error", "unparseable-field", path, field, `Frontmatter ${field} is present but cannot be parsed.`, [
      { kind: "edit-frontmatter", detail: field === "tools" || field === "disallowedTools" ? `write ${field} as a comma list (Read, Grep), a [flow, list] or a block list of - items` : `write ${field} as a plain one-line value` },
    ]));
  }
  const expectedName = agent.split(":").pop();
  if (!file.parseErrors.includes("name") && file.name !== expectedName) {
    findings.push(finding("error", "name-mismatch", path, "name", `Frontmatter name is ${JSON.stringify(file.name)}, but Claude Code loads this agent by name ${JSON.stringify(expectedName)}.`, [
      { kind: "edit-frontmatter", detail: `set name: ${expectedName}` },
    ]));
  }
  const allowed = CLASSES[cls].models;
  if (file.model !== null && !file.parseErrors.includes("model") && !allowed.includes(modelAlias(file.model))) {
    findings.push(finding("error", "model-not-allowed", path, "model", `Frontmatter model ${JSON.stringify(file.model)} is outside the ${cls} allowlist (${allowed.join(", ")}); it runs whenever the row is inherit or a subagent is dispatched without a model.`, [
      { kind: "edit-frontmatter", detail: "remove model: from the agent file (the row's model then governs)" },
      { kind: "edit-frontmatter", detail: `set model: to one of ${allowed.join(", ")}` },
    ]));
  }
  const contract = CLASSES[cls].contract;
  if (contract && !file.parseErrors.includes("tools") && !file.parseErrors.includes("disallowedTools")) {
    const tools = file.tools;
    const disallowed = file.disallowedTools || [];
    const allowlist = Array.isArray(tools) && !tools.includes("*");
    const lists = (list, t) => list.some((e) => e === t || e.startsWith(`${t}(`));
    const present = (t) => (!allowlist || lists(tools, t)) && !lists(disallowed, t);
    const addFix = (t) =>
      lists(disallowed, t)
        ? { kind: "edit-frontmatter", detail: `remove ${t} from disallowedTools` }
        : { kind: "edit-frontmatter", detail: `add ${t} to tools (you use an allowlist)` };
    const removeFix = (t) =>
      allowlist ? { kind: "edit-frontmatter", detail: `remove ${t} from tools` } : { kind: "edit-frontmatter", detail: `add ${t} to disallowedTools` };
    for (const req of contract.required) {
      const alts = Array.isArray(req) ? req : [req];
      if (alts.some(present)) continue;
      findings.push(finding("error", `missing-tool:${alts.join("|")}`, path, "tools", `The ${cls} contract needs ${alts.join(" or ")}, and this agent's effective tools lack ${alts.length > 1 ? "all of them" : "it"}.`, alts.map(addFix)));
    }
    for (const t of contract.forbidden) {
      if (!present(t)) continue;
      findings.push(finding("error", `forbidden-tool:${t}`, path, "tools", `A ${cls}-class agent must not have ${t}: a reviewer that can edit ends up validating its own fixes.`, [
        removeFix(t),
        { kind: "change-class", detail: "implement" },
      ]));
    }
    for (const t of contract.discouraged) {
      if (!present(t)) continue;
      findings.push(finding("warn", `discouraged-tool:${t}`, path, "tools", `${t} is outside the ${cls} convention.`, [removeFix(t)]));
    }
    for (const t of contract.missingRecommended) {
      if (present(t)) continue;
      findings.push(finding("warn", `missing-recommended:${t}`, path, "tools", `A ${cls}-class agent is expected to have ${t}.`, [addFix(t)]));
    }
    for (const e of Array.isArray(tools) ? tools : []) {
      const m = /^([A-Za-z_][A-Za-z0-9_.-]*)\(/.exec(e);
      if (!m) continue;
      findings.push(finding("warn", "scoped-tool-entry", path, "tools", `tools entry ${JSON.stringify(e)} grants the whole ${m[1]} tool: Claude Code does not enforce the scope.`, [
        { kind: "edit-frontmatter", detail: `remove ${e} from tools, or list plain ${m[1]} knowingly; to restrict a tool, add it to disallowedTools` },
      ]));
    }
  }
  if (!builtin && !effDescription.text) {
    findings.push(finding("warn", "no-description", path, "description", "No config description and no frontmatter description: a side role's directive line would be empty.", [
      { kind: "set-description", detail: `roster.mjs role set ${role} --description "<one line>"` },
    ]));
  }
  if (loc.shadowed) {
    findings.push(finding("warn", "shadowed-agent", path, null, `${JSON.stringify(agent)} exists at both levels: ${path} was validated and loads here; ${loc.shadowed} is shadowed in this repo.`, [
      { kind: "remove-file", detail: `delete or rename the shadowed user file ${loc.shadowed}, or rename the repo agent ${path}` },
    ]));
  }
  return { findings, file, description: effDescription };
}

/** True when any finding is an error. */
export function hasContractErrors(findings) {
  return Array.isArray(findings) && findings.some((f) => f.level === "error");
}

/** Plain-text findings: `<LEVEL> <code>: <message>` and one `  fix: …` line per fix. */
export function formatFindings(findings) {
  return findings.map((f) => [`${f.level.toUpperCase()} ${f.code}: ${f.message}`, ...f.fix.map((x) => `  fix: [${x.kind}] ${x.detail}`)].join("\n")).join("\n");
}

/**
 * Validate one registry role, when it needs validating: every custom row and every built-in
 * override. Shipped `ah:*` agents are trusted and return null.
 */
export function validateRole(role, resolved) {
  const entry = resolved && resolved.roles && resolved.roles[role];
  if (!entry) return null;
  // A pack agent is judged from the text the pin covers, through its one strict parse.
  const parsed = entry.pack && typeof entry.pack.agentText === "string" ? packAgentParse(entry.pack.agentText, entry.pack.agentPath) : null;
  const inMemory = parsed ? { path: entry.pack.agentPath, text: entry.pack.agentText, fm: parsed.fm } : null;
  let result;
  if (isBuiltinRole(role)) {
    if (!isOverride(role, entry)) return null;
    result = validateAgentContract({ role, cls: BUILTIN_CLASS[role], agent: roleAgent(role, entry), builtin: true, cwd: resolved.cwd, inMemory });
  } else {
    result = validateAgentContract({ role, cls: entry.class, agent: entry.agent, description: entry.description || null, cwd: resolved.cwd, inMemory });
  }
  return entry.pack ? { ...result, findings: [...packFindings(role, entry.pack, parsed), ...result.findings] } : result;
}

/** The agents adopted pack roles resolve to — a `from` row's, or a built-in's agent a pack
    overrides — whether or not the role is available now. */
export function packAgentRefs(resolved) {
  const out = new Set();
  for (const role of registryRoles(resolved)) {
    const entry = resolved.roles[role];
    if (entry && entry.from) out.add(roleAgent(role, entry));
  }
  return out;
}

/** An adopted role's pack findings: its pack reason when it isn't "ok", then the pack-agent
    frontmatter checks (`parsed`, its `packAgentParse`, when the caller holds it). Every one is an
    error, so the role is unavailable through the usual path. */
export function packFindings(role, pack, parsed = null) {
  const out = [];
  if (pack.status !== "ok") {
    const fix =
      pack.status === "pack-changed" || pack.status === "pack-untrusted-here"
        ? [{ kind: "trust", detail: `review it with \`roster.mjs role trust ${role} --dry-run\`, then commit with the pin it prints` }]
        : pack.status === "pack-ambiguous"
          ? [{ kind: "uninstall", detail: "uninstall all but one install of the plugin" }]
          : [{ kind: "remove", detail: `\`roster.mjs role remove ${role}\`, or reinstall the pack` }];
    out.push(finding("error", pack.status, pack.agentPath, null, `${role} (from ${pack.from}): ${pack.message}${pack.subcode && pack.subcode !== pack.status ? ` [${pack.subcode}]` : ""}`, fix));
  }
  if (parsed) out.push(...parsed.findings);
  else if (typeof pack.agentText === "string") out.push(...packAgentFindings(pack.agentText, pack.agentPath));
  return out;
}

/** The subagent_type to dispatch for a role: its agent (`roleAgent`), or task-runner's `delegate` when its agent is not overridden. */
export function subagentType(role, entry) {
  if (role === "task-runner" && entry && entry.delegate === "task-gopher" && !isOverride(role, entry)) {
    return "task-gopher:task-gopher";
  }
  return roleAgent(role, entry);
}

/**
 * One dispatch line per role. `inherit` renders as "omit the parameter", never
 * as a value. A chain role gets its peer target, the spawn command for when none
 * is live, and where to turn when it cannot be launched — never a subagent call.
 * A legwork role gets the subagent call alone.
 */
function roleLines(resolved, repoBasename) {
  const cwd = resolved.cwd || "<abs cwd>";
  return registryRoles(resolved).map((role) => {
    const entry = resolved.roles[role];
    const type = subagentType(role, entry);
    const tag = isBuiltinRole(role) ? "" : customTag(role, entry);
    const agentCall =
      entry.model === "inherit"
        ? `Agent(subagent_type:"${type}") — OMIT \`model\` entirely (inherits this session's model). Never pass "inherit" as a value.`
        : `Agent(subagent_type:"${type}", model:"${entry.model}")`;
    if (classProp(role, resolved, "chain") !== true) {
      return `- ${roleLabel(role, resolved)}${tag} — ${agentCall}`;
    }
    const explicit = entry.peer && entry.peer !== "auto";
    const target = explicit
      ? `peer ${resolvedPeerTargets(role, entry, repoBasename).map((p) => `"${p}"`).join(" / ")}`
      : "its live teammate (names: `ListAgents` / `roster.mjs teams`)";
    const verb = rosterMemberFor(resolved, role) ? "spawn-one" : "spawn-ad-hoc";
    return `- ${roleLabel(role, resolved)}${tag} — SendMessage ${target}; none live → \`node "${ROSTER_CLI}" ${verb} ${role} --cwd ${cwd}\`, then SendMessage the name it prints. Can't launch → agent-team 'When a role can't take the work'.`;
  });
}

/** True when a custom row is an in-chain alternative: a chain class with `routes`. */
export function isAlternative(role, entry) {
  return !isBuiltinRole(role) && !!entry && CLASSES[entry.class] && CLASSES[entry.class].chain && typeof entry.routes === "string" && !!entry.routes;
}

/** A custom role line's tag: `[custom · <class> · alt. to <Builtin>]`, or `[custom · <class>]` plus its quoted description. */
function customTag(role, entry) {
  if (isAlternative(role, entry)) return ` [custom · ${entry.class} · alt. to ${ROLE_LABELS[classBuiltin(entry.class)]}]`;
  return ` [custom · ${entry.class}]${entry.effectiveDescription ? ` "${entry.effectiveDescription}"` : ""}`;
}

/**
 * The directive's view of the registry at SessionStart: every custom row and built-in override
 * is validated against its class contract. A custom row with errors is dropped from the view
 * (it stays in the real registry, so gates and messaging still work); an override with errors
 * reverts to the shipped `ah:<role>`. Available custom rows gain their effective description.
 * Returns `{view, unavailable}` with `unavailable` as display names.
 */
export function availabilityView(resolved) {
  const roles = { ...resolved.roles };
  const unavailable = [];
  for (const role of registryRoles(resolved)) {
    const entry = resolved.roles[role];
    if (isBuiltinRole(role) && !isOverride(role, entry)) continue;
    let result;
    try {
      result = validateRole(role, resolved);
    } catch {
      result = { findings: [finding("error", "agent-not-found", null, null, "validation failed", [])], description: { text: null } };
    }
    if (!result) continue;
    const failed = hasContractErrors(result.findings);
    if (isBuiltinRole(role)) {
      if (!failed) continue;
      const { agent, ...rest } = entry;
      roles[role] = rest;
      unavailable.push(`${role} (${agent})`);
      continue;
    }
    if (failed) {
      delete roles[role];
      unavailable.push(role);
      continue;
    }
    roles[role] = { ...entry, effectiveDescription: result.description.text };
  }
  return { view: { ...resolved, roles }, unavailable };
}

/** Available custom rows with `routes`, grouped by chain step class, each list in name order. */
function alternativesByClass(resolved) {
  const out = {};
  for (const role of customRoleNames(resolved)) {
    const entry = resolved.roles[role];
    if (isAlternative(role, entry)) (out[entry.class] ||= []).push(role);
  }
  return out;
}

/** The generated routing item, numbered `n`, or null when no available custom row has `routes`. */
function routingItem(resolved, n) {
  const alts = alternativesByClass(resolved);
  const steps = ["advise", "design", "implement", "review"].filter((c) => alts[c]);
  if (!steps.length) return null;
  const lines = steps.map((c) => {
    const picks = alts[c].map((r) => `${roleLabel(r, resolved)} for "${resolved.roles[r].routes}"`).join("; ");
    return `· ${CLASSES[c].step}: ${picks}; otherwise ${ROLE_LABELS[classBuiltin(c)]}.`;
  });
  return [
    `${n}. ROUTING — custom alternatives (first fit by name):`,
    ...lines,
    "A spec's `Implementer:`/`Reviewer:` decides; unsure → built-in (auto) or ask (confirm). A routed role owns its rework: impl-defect → the implementing role, spec-defect → the designing role. Handoff gate, review loop, message files: as for the built-in.",
  ].join("\n");
}

/**
 * The design routing block, given to design-class roles (built-in or custom) when Implement or
 * Review alternatives exist; null otherwise.
 */
export function designRoutingBlock(resolved) {
  const alts = alternativesByClass(resolved);
  const steps = ["implement", "review"].filter((c) => alts[c]);
  if (!steps.length) return null;
  const lines = steps.map((c) => {
    const picks = alts[c].map((r) => `\`${r}\` for "${resolved.roles[r].routes}"`).join("; ");
    return `· ${CLASSES[c].step}: ${picks}; otherwise \`${classBuiltin(c)}\`.`;
  });
  return [
    "ROUTING — when you write a spec, name its roles within its first 40 lines, each on its own line: `Implementer: <role>` and/or `Reviewer: <role>`. Choices:",
    ...lines,
  ].join("\n");
}

const CONTRACTS_DIR = join(dirname(dirname(fileURLToPath(import.meta.url))), "contracts");
let contractLogged = false;

function readContractFile(name) {
  try {
    return readFileSync(join(CONTRACTS_DIR, `${name}.md`), "utf8");
  } catch (err) {
    if (!contractLogged) {
      contractLogged = true;
      logHookError("contracts", err);
    }
    return null;
  }
}

/**
 * The injected behavioural contract for a custom or overridden chain role: `contracts/common.md`
 * plus the class file, placeholders substituted. `peerRoute` drops the `~` lines the role-session
 * notice already carries. Null for legwork, for a role that needs no contract, or when a contract
 * file is missing (logged once).
 */
export function contractBlock(role, resolved, { peerRoute = false } = {}) {
  const entry = resolved && resolved.roles && resolved.roles[role];
  const cls = roleClass(role, resolved);
  if (!entry || !cls || !CLASSES[cls].chain) return null;
  if (isBuiltinRole(role) && !isOverride(role, entry)) return null;
  const common = readContractFile("common");
  const specific = readContractFile(cls);
  if (common === null || specific === null) return null;
  const routes = isAlternative(role, entry) ? entry.routes : null;
  const fill = (t) =>
    t
      .split("<Label>").join(roleLabel(role, resolved))
      .split("<class>").join(cls)
      .split("<BuiltinLabel>").join(ROLE_LABELS[classBuiltin(cls)])
      .split("<routes>").join(routes || "")
      .split("<msg-cli>").join(MSG_CLI);
  const lines = [];
  for (const line of common.split("\n")) {
    if (!line.trim()) continue;
    if (line.startsWith("?routes ")) {
      if (routes) lines.push(line.slice("?routes ".length));
      continue;
    }
    if (line.startsWith("~ ")) {
      if (!peerRoute) lines.push(line.slice(2));
      continue;
    }
    lines.push(line);
  }
  return fill(["HIERARCHY CONTRACT —", ...lines, specific.trim()].join("\n"));
}

/**
 * The Ultra-Advisor user gate, appended to protocol item 7.
 *
 * The gate itself is enforced by the PreToolUse hook; this text exists so the
 * Orchestrator recognizes the denial as policy rather than a malfunction, and
 * so a spoken "stop asking about the advisor" can be honored on the spot the
 * way the flow switch already is.
 */
function gateSentences(sessionId) {
  const lines = [
    "USER GATE: a PreToolUse hook DENIES the first Ultra-Advisor dispatch of every session — Agent-tool spawn or SendMessage to its named peer — until the user approves. The denial states the exact question to put to them and the exact command that records their answer — follow it verbatim; no improvised wording, no skipped record step. Their answer (allow for this session / ask each time / blocked this session) is session-scoped, covers both routes, resets next session. In \"confirm\" flow that prompt REPLACES item 0's confirmation for that dispatch: ask once, not twice.",
  ];
  if (sessionId) {
    lines.push(
      `This session's gate id is "${sessionId}". Plain-words request ("don't use the ultra advisor", "stop asking me about it", "go ahead without asking") → run \`node "${GATE_CLI}" set --session "${sessionId}" --choice session|each|off\` without waiting for a dispatch; \`node "${GATE_CLI}" status --session "${sessionId}"\` reports the current answer.`
    );
  }
  return lines.join(" ");
}

/**
 * `, and custom: <labels>` for the custom roles the tier rule applies to (design and advise
 * classes), appended to the tier prose; empty when there are none, so the built-in text is
 * unchanged.
 */
export function customTierText(resolved) {
  const labels = customRoleNames(resolved).filter((r) => classProp(r, resolved, "tier") === true).map((r) => roleLabel(r, resolved));
  return labels.length ? `, and custom: ${labels.join(", ")}` : "";
}

/**
 * The three 0.29.0 protocol items: message files (12), peer roster (13), tier
 * rule (14). `hierDir` and `model` may be null (unit callers); the text
 * degrades to the generic form.
 */
function protocolItems1214(resolved, hierDir, model) {
  const dirText = hierDir || "<hierarchy dir>";
  const t = tierOf(model);
  const roleTierText = `Architect ${resolved.roles.architect.model}(${tierOf(resolved.roles.architect.model) ?? "?"}), Ultra-Advisor ${resolved.roles["ultra-advisor"].model}(${tierOf(resolved.roles["ultra-advisor"].model) ?? "?"})${customTierText(resolved)}`;
  const tierOpen =
    model && t !== null
      ? `TIER RULE — you are ${model} (tier ${t}). ${roleTierText}. haiku<sonnet<opus<fable.`
      : `TIER RULE — read your own model from your environment line and rank haiku<sonnet<opus<fable; ${roleTierText}.`;
  return [
    `12. MESSAGE FILES — every role dispatch (Agent spawn of architect/implementor/reviewer/ultra-advisor, or a peer brief via SendMessage) carries its brief as a file, not inline prose; a PreToolUse gate denies the dispatch otherwise. Writer: \`node "${MSG_CLI}" new --to <role> --from orchestrator --slug <slug> [--to-name <peer-or-agent name>] [--parent <id>] [--reason context|second-opinion|parallel]\` (never hand-roll ids or skeletons), then fill EVERY section of the skeleton it prints — request keys [0] tldr [1] goal [2] context [3] constraints [4] files [5] acceptance [6] want_back; \`[0] tldr\` = one bullet per section, \`- [N] key: <≤10-word gist>\`. Style: bullets, imperative, no prose, no restating what the reader can see; every constraint / negative / acceptance criterion survives verbatim — brevity is the tie-breaker, never the goal. In-band pointer: the Agent prompt / SendMessage body opens with \`[hierarchy-msg <abs request path>]\` then ≤3 TL;DR lines (peer briefs keep the [hierarchy-peer-brief ...] sentinel line first). Reader: \`grep -n '^## \\\\[' <path>\` = the index; Read(offset,limit) only the sections the tldr says matter (whole-file Read fine when small). The role replies \`[hierarchy-msg <abs response path>]\` + its [1] status bullet; a response file closes the exchange — new work is a new id (\`--parent <id>\` links it), never an append. Files under ${dirText}/msgs/; \`node "${MSG_CLI}" list|index|sweep|roster\` (or /hierarchy msgs|peers|sweep). Multiple instances per role are normal — roles are categories; \`to_name:\`/\`from_name:\` name the instance.`,
    `13. PEER ROSTER — ${dirText}/peers.jsonl is ground truth for which role peers are up, seen, or briefed; after compaction trust the HIERARCHY STATE block over memory. A PreToolUse gate denies EVERY Agent call for Ultra-Advisor/Architect/Reviewer/Implementor: the deny names the live peer to SendMessage, or carries the exact spawn command to run. Standing up, reshaping, or tearing down a live Team — create/spawn a Team, dismiss one member, disband, resync/move — goes through the \`ah:agent-team\` skill (\`Skill(skill:"ah:agent-team")\`, or \`/agent-team\`); editing the roster TEMPLATE — add/edit/remove a role — through \`ah:agent-roster\`; neither is a raw roster MCP call. Spawning one session is a direct call, not a skill: a roster member is \`node "${ROSTER_CLI}" spawn-one <role> [--member <n>] --cwd <abs cwd>\`; with no roster, or for a role the roster does not carry, \`… spawn-ad-hoc <role> [--kind pi|codex|claude] [--route peer|pane] --cwd <abs cwd>\`. A non-\`claude\` \`--kind\` is route \`pane\`: brief it with \`roster.mjs deliver\` in the background, never SendMessage. Under Herdr a session name (the team prefix + role, or \`--member\`) must be \`[a-z][a-z0-9_-]\`, at most 32 characters — spawn refuses a longer one before opening a pane.`,
    `14. ${tierOpen} Do not dispatch Architect or Ultra-Advisor for REASONING when its tier ≤ yours — take that role's contract inline (write the spec at the spec path yourself; adjudicate yourself). Same-or-lower-tier dispatch only for: context — the design is large and belongs out of your window; second-opinion — the user asked, or you want a fresh-context check; parallel — other work runs meanwhile. Put the reason in the request file's reason: field and one tldr line. Ultra-Advisor: escalate only when strictly higher than you; same tier → decide it yourself and say so. Reviewer is exempt — review buys independence, not tier. A PreToolUse gate denies ONCE per role per session when your model is known, the role's tier ≤ yours, and the request file carries no reason:.`,
  ];
}

/**
 * The full SessionStart injection for a configured, enabled session.
 * `extra.hierDir` (runtime dir) and `extra.model` (session model, if known)
 * shape items 4/12/14; both optional.
 */
export function buildDirective(fullResolved, sessionId, extra = {}) {
  const hierDir = extra && typeof extra.hierDir === "string" ? extra.hierDir : null;
  const model = extra && typeof extra.model === "string" ? extra.model : null;
  const { view: resolved, unavailable } = availabilityView(fullResolved);
  const confirm = resolved.handoffs === "confirm";
  const repoBasename = teamPrefix(resolved.cwd, resolved.team);
  const custom = customRoleNames(resolved);
  const sideRoles = custom.filter((r) => !isAlternative(r, resolved.roles[r]));
  const registryNotes = [
    ...(sideRoles.length ? ["Custom side roles are dispatched when the user asks for one or when its quoted description fits; they are never substituted into the chain."] : []),
    ...(unavailable.length ? [`Unavailable user-defined roles (agent file fails its class contract — /ah:agent-role): ${unavailable.join(", ")}.`] : []),
  ];
  const taskRunnerAgent = isOverride("task-runner", resolved.roles["task-runner"]) ? roleAgent("task-runner", resolved.roles["task-runner"]) : null;
  const routing = routingItem(resolved, 15);
  const lines = [
    "Agent hierarchy ACTIVE. You are the Orchestrator: decompose, dispatch, synthesize — do not design or implement non-trivial changes yourself, except where agent-team 'When a role can't take the work' has you take a role over.",
    "",
    "Roles — dispatch route per role below. Ultra-Advisor, Architect, Reviewer, Implementor are peer sessions, never subagents: SendMessage the live one; none live → spawn it with the command on its line, then SendMessage the name it prints (Ultra-Advisor is approval-gated — item 7). Legwork (Task-Runner) always spawns or delegates to task-gopher; pass `model` on the Agent call — agent frontmatter is fallback only:",
    ...roleLines(resolved, repoBasename),
    ...registryNotes,
    "",
    "PEER BRIEF CONTRACT — a peer session is an independent Claude session: unlike a subagent, NOTHING returns its result to you automatically; a peer that finishes goes idle without telling you unless the brief itself obliges it to report. Every SendMessage that tasks a role peer must:",
    "- Open with the sentinel line `[hierarchy-peer-brief reply-to=\"sender\" task=\"<short-slug>\"]`. reply-to=\"sender\" = the peer replies to the delivery-envelope address: your message arrives wrapped as `<cross-session-message from=\"...\">`; copying that `from` into the reply's `to` is the reliable route (the sender is often NOT in the peer's ListAgents — never rely on that). Explicit `reply-to=\"<name> [ref]\"` only to redirect the report to a third session.",
    "- Next line: `[hierarchy-msg <request path>]` — the brief lives in the message file (item 12); set its `to_name:` to the peer's session name.",
    "- Same self-contained brief a subagent would get (spec path, task, constraints) — the peer shares none of your context.",
    "- End with an explicit report-back order: the exact report expected (same as the role's subagent form); the reply rule restated in prose (copy this message's wrapper `from` into the SendMessage `to`); and plainly: task NOT COMPLETE until that report is sent back via SendMessage — finishing silently strands the caller.",
    "- No reply and ListAgents shows the peer idle → ping it with notify_when_idle (\"Ping n/3: you owe a report on task <slug> — SendMessage it back to the sender\"); never ping a busy peer; 3 unanswered pings → take over per agent-team 'When a role can't take the work', leaving its pane running.",
    "",
    "Protocol (hard default, not a preference):",
    ...(confirm
      ? [
          "0. Handoff gate — user chose per-handoff approval (config handoffs:\"confirm\"). Before dispatching Ultra-Advisor, Architect, Implementor, or Reviewer — review-loop re-dispatches included — ListAgents first: is its peer present? Then AskUserQuestion naming the role, its model, one line on what you hand it. Peer listed → offer \"Task peer \\\"<name>\\\" via SendMessage (Recommended)\", \"Do it inline yourself\", \"Skip this step\", in that order. Peer not listed → offer \"Spawn the <role> peer (Recommended)\", \"Do it inline yourself\", \"Skip this step\". This item decides only WHETHER to hand off. Ultra-Advisor: gated by item 7's PreToolUse approval gate (it watches SendMessage to the Ultra-Advisor peer) — the peer option never skips user approval. Ask per dispatch, not per plan; never re-ask a dispatch already approved. Legwork (Task-Runner / task-gopher) exempt — errands are not handoffs. \"Task peer\" = SendMessage that peer the same self-contained brief a subagent gets, then await its reply as you would a subagent's completion; the brief must follow the PEER BRIEF CONTRACT above — a peer not ordered to report back does the work and goes idle silently. \"Do it inline\" = you take that role's contract for that step. \"Skip\" = the step does not happen; say plainly what that leaves undesigned or unverified.",
        ]
      : []),
    "1. Gate: binds the top-level Orchestrator only. Role agents never spawn ultra-advisor/architect/reviewer/implementor. They MAY dispatch task-gopher for legwork — that is not recursion.",
    "2. Scope: the chain governs changes. Analysis, debugging, research → Architect (design reasoning) or Task-Runner (retrieval) alone — no Reviewer without a diff. Never dispatch Architect or Ultra-Advisor when the deliverable is only writing, recording, or persisting something you already know — a memory entry, a status note, a file update with no open design question: no reasoning content → do it yourself, or hand the mechanical write to Task-Runner or Implementor. Architect/Ultra-Advisor = reasoning that produces new judgment, never the write step alone.",
    "3. Tiers: trivial (one blind Edit, no verification — typo, config value) → yourself. Determined (request fixes the spec; no design choices left) → Implementor, then Reviewer. Everything else → Architect → spec → Implementor → Reviewer; Ultra-Advisor ahead of the Architect when an item 7 trigger fires.",
    `4. Spec handoff: one unique absolute spec path — default \`${hierDir ? join(hierDir, "specs") : "<hierarchy dir>/specs"}/<slug>.md\` — dictated in the Architect's prompt; same path to Implementor and Reviewer. Dispatches are self-contained — subagents share no context.`,
    "5. Living spec: Implementor reports a spec gap, or a deviation is agreed → amend the spec file (yourself, or re-dispatch the Architect for design questions) BEFORE the Reviewer runs. The Reviewer always validates against the current spec.",
    "6. Review loop: Reviewer classifies each finding impl-defect or spec-defect. Impl-defect → Implementor; spec-defect → Architect. Max 2 round-trips; findings still open after that → escalate to Ultra-Advisor, not another loop, then surface its verdict to the user.",
    `7. Ultra-Advisor — escalation apex, never a routine step. Reasons and adjudicates; never implements. Dispatch ONLY when: the user says the problem is hard, important, or high-stakes, or asks for a second opinion; the Architect reports low confidence or a fork it could not resolve; the review loop hits item 6's cap; or the change carries outsized blast radius (security, auth, data migration, concurrency, a public interface, anything hard to reverse). Give it the same absolute spec path plus the specific question. Its answer is authoritative: fold it into the spec before the Implementor runs again. Never escalate because a task feels large — size is the Architect's job. No Ultra-Advisor reachable → the escalation ladder in agent-team 'When a role can't take the work'. ${gateSentences(sessionId)}`,
    taskRunnerAgent
      ? `8. Task-Runner: dispatch \`${taskRunnerAgent}\` (roles.task-runner.agent); that agent type unavailable → \`ah:task-runner\`.`
      : "8. Task-Runner: prefer `task-gopher:task-gopher`; that agent type unavailable → `ah:task-runner`. task-gopher's on/off toggle controls only its directive, not the agent — delegation works either way.",
    "9. Skills and commands override: a skill mandating a different flow (tdd, diagnose, review) wins over this protocol for its scope.",
    `10. Flow control — handoffs are currently "${resolved.handoffs}"${confirm ? " (ask before each reasoning-role dispatch, per item 0)" : " (you advance the chain yourself and report)"}. The user owns this switch and may flip it AT ANY TIME, either direction, just by telling you — "ask me before handoffs", "stop asking", or /hierarchy flow auto|confirm. Then: update the "handoffs" key in the most specific agent-hierarchy.json that exists (project if present, else user) with the Write tool, preserving every other key; confirm in one line; honor the new mode immediately for the rest of this session — no restart.`,
    "11. Evidence loop — YOU keep the roles in their lanes. The Architect reasons and designs; it never executes — no tests, builds, or experiments, direct or via a runner (Bash is denied to it). (a) Dispatch it with design questions only: never fold \"and verify it works\" into an Architect prompt. (b) Its report or spec carries NEEDS-EVIDENCE items → route that gruntwork to the Implementor (write/run/measure, at implementation rates; Task-Runner for a pure run-and-report), then re-dispatch the Architect with the results and the same spec path. (c) The Reviewer likewise reasons only: it reads diffs itself (read-only git is its instrument) but MUST delegate every execution — suites, builds, repro scripts — to task-gopher and judge the compact report; its Bash is for inspection, never for running. (d) A role's report shows it did another role's work — an Architect that ran tests, a Reviewer that ran a suite itself, an Implementor that redesigned → do not accept that part: note the overstep, route the work to the role that owns it. Reasoning-tier tokens buy judgment, not gruntwork; enforcing that split is YOUR job, not the roles' goodwill.",
    ...protocolItems1214(resolved, hierDir, model),
    ...(routing ? [routing] : []),
  ];
  for (const warning of resolved.warnings) lines.push(warning);
  return lines.join("\n");
}

/** One-line setup nudge for an unconfigured top-level session. */
export function buildNudge(resolved) {
  const lines = ["agent-hierarchy is installed but not configured — run `/hierarchy init` to assign a model to each role."];
  for (const warning of resolved.warnings) lines.push(warning);
  return lines.join("\n");
}

/**
 * The SessionStart injection for a top-level `claude --agent <role>` session.
 *
 * Such a session IS the main session, so the Orchestrator directive would
 * otherwise reach it — and a role told it is the Orchestrator starts
 * dispatching instead of doing its own work. This says the opposite, in three
 * sentences. It deliberately carries no role→model table and no protocol: the
 * role's own `agents/*.md` body is the whole contract here.
 */
export function buildRoleSessionNotice(role, agentType, resolved = null) {
  const entry = resolved && resolved.roles ? resolved.roles[role] : null;
  // Keyed on the agent this session actually runs: an ah:* session is the shipped agent even when
  // an override is configured (a failing override is spawned as ah:<role>), and is never injected.
  const viaAgentFile = !!entry && typeof agentType === "string" && !agentType.startsWith("ah:") && agentType === roleAgent(role, entry);
  const label = roleLabel(role, resolved);
  let governs = `Your ${label} contract in \`agents/*.md\` governs.`;
  if (viaAgentFile) {
    const cls = roleClass(role, resolved);
    const alt = isAlternative(role, entry) ? `, alternative to ${ROLE_LABELS[classBuiltin(cls)]} for: ${entry.routes}` : "";
    governs = `Your ${label} contract (${isBuiltinRole(role) ? "built-in" : "custom"} ${cls} role${alt}): your agent file (\`${roleAgent(role, entry)}\`) governs, subject to the hierarchy contract below.`;
  }
  const notice = [
    `You are running as \`${agentType}\` as the MAIN session of this Claude Code instance, launched with \`--agent\`.`,
    "The agent-hierarchy Orchestrator protocol does NOT apply to you: do not decompose-and-dispatch, and do not treat yourself as the top of the chain.",
    governs,
    "If a message tasks you as a peer (it opens with `[hierarchy-peer-brief reply-to=...]`), the work is not finished until you have sent your report back via SendMessage to that reply-to address — completing the task and going idle without replying strands the session that tasked you.",
    `You are a peer ${label}. Briefs arrive as [hierarchy-msg <path>]; read via grep '^## \\[' then Read; reply with a response file (node "${MSG_CLI}" new --type response --id <id> --req <that request path>) and [hierarchy-msg <path>] first line.`,
    "The request's frontmatter `team_file` is your Team's file by absolute path — trust it over anything derived from your cwd; `team_guide` beside it says how to use it.",
    "Role sessions do not dispatch ah roles (Ultra-Advisor, Architect, Reviewer, Implementor): route any such need back to your Orchestrator in your report as NEEDS-<ROLE> (e.g. NEEDS-IMPLEMENTOR), or NEEDS-EVIDENCE for a run or a measurement; legwork (`task-gopher:*`, `ah:task-runner`) is allowed.",
  ].join(" ");
  const blocks = [notice];
  if (viaAgentFile) {
    const contract = contractBlock(role, resolved, { peerRoute: true });
    if (contract) blocks.push(contract);
  }
  if (resolved && roleClass(role, resolved) === "design") {
    const routing = designRoutingBlock(availabilityView(resolved).view);
    if (routing) blocks.push(routing);
  }
  return blocks.join("\n\n");
}

/** Human-readable resolved table for `/hierarchy status` and the wizard's echo. */
export function statusReport(cwd) {
  const resolved = resolveConfig(cwd);
  const out = [];
  const userPath = userConfigPath();
  const projectPath = projectConfigPath(cwd);
  const seen = Object.fromEntries(resolved.layers.map((l) => [l.scope, l.path]));

  out.push(`ah: ${!resolved.configured ? "NOT CONFIGURED" : resolved.enabled ? "ON" : "OFF (enabled:false)"}`);
  out.push(`user config:    ${seen.user || `${userPath} (none)`}`);
  out.push(`project config: ${seen.project || `${projectPath || "(unknown cwd)"} (none)`}`);
  out.push(
    `handoff flow:   ${resolved.handoffs} ${resolved.handoffs === "confirm" ? "(ask before each reasoning-role dispatch)" : "(automatic handoffs)"} — from ${resolved.handoffsSource}; switch anytime with /hierarchy flow or by asking the Orchestrator`
  );
  out.push(
    "ultra gate:     the first Ultra-Advisor escalation each session needs your approval — /hierarchy gate to view or change it (session-scoped; resets next session)"
  );
  out.push("");
  out.push("Resolved effective table:");
  out.push(`  Orchestrator  ${"session model".padEnd(14)} fixed (this session's agent)`);
  const repoBasename = teamPrefix(resolved.cwd, resolved.team);
  for (const role of ROLES) {
    const entry = resolved.roles[role];
    const model = entry.model === "inherit" ? "inherit*" : entry.model;
    const peers = resolvedPeerTargets(role, entry, repoBasename);
    const dispatch = PEER_ELIGIBLE_ROLES.includes(role) ? (peers.length ? `dispatch: peer ${peers.map((p) => `"${p}"`).join(" / ")}` : "dispatch: subagent-only") : "";
    out.push(
      `  ${ROLE_LABELS[role].padEnd(13)} ${model.padEnd(14)} from ${resolved.sources[role].padEnd(8)} -> ${subagentType(role, entry)}${dispatch ? `  [${dispatch}]` : ""}`
    );
  }
  for (const role of customRoleNames(resolved)) {
    const entry = resolved.roles[role];
    const model = entry.model === "inherit" ? "inherit*" : entry.model;
    const placement = isAlternative(role, entry) ? `alt. to ${ROLE_LABELS[classBuiltin(entry.class)]}` : "side";
    out.push(`  ${entry.label.padEnd(13)} ${model.padEnd(14)} from ${resolved.sources[role].padEnd(8)} -> ${entry.agent}  [custom · ${entry.class} · ${placement}]`);
  }
  if (customRoleNames(resolved).length || resolved.excludedRoles.length) out.push("  (custom roles: node \"" + ROSTER_CLI + "\" role list --cwd <abs cwd>, or /ah:agent-role)");
  out.push("");
  out.push("* inherit = omit the `model` parameter on the Agent call (never pass \"inherit\").");
  out.push("");
  if (resolved.roster) {
    const r = resolved.roster;
    out.push(`Roster: level=${r.level} route=${r.route} path=${r.path}`);
    for (const m of r.members) {
      // The default ("auto") is resolved here at the display site, not stamped onto the
      // member — literal, not imported, to avoid a lib-roster.mjs -> lib-config.mjs import cycle
      // (lib-roster.mjs already imports ROLES/VALID_MODELS_BY_ROLE from this file).
      const onMissingDefaulted = m.onMissing === undefined || m.onMissing === null;
      const onMissingEffective = onMissingDefaulted ? "auto" : m.onMissing;
      // §3.3: name the reason, not a bare "(inert)" — non-peer-eligible role and subagent route are
      // two different causes with two different fixes.
      // Spec 0043 §1.3: `pane` keeps on-missing's spawn-selection meaning but has no
      // peer-fallback meaning (nothing to fall back TO), so it gets its own wording rather
      // than reusing the subagent one, which would read as "this setting does nothing".
      const effRoute = m.route || r.route;
      const onMissingTag = classProp(m.role, resolved, "chain") !== true
        ? " (inert: role is not peer-eligible)"
        : effRoute === "subagent"
          ? " (inert: route is subagent)"
          : effRoute === "pane"
            ? " (selects which member to spawn; no peer fallback on route pane)"
            : onMissingDefaulted
              ? " (default)"
              : "";
      out.push(
        `  ${m.name.padEnd(24)} ${ROLE_LABELS[m.role] || m.role} kind=${resolveKind(m)} model=${resolveKind(m) === KIND_DEFAULT ? m.model || "?" : nonClaudeModelText(m)} effort=${m.effort || "-"} route=${effRoute} auto-mode=${m.autoMode || "-"} on-missing=${onMissingEffective}${onMissingTag}`
      );
    }
  } else {
    out.push("Roster: none configured — /agent-roster init to define one (roles/route above stay in effect).");
  }
  const nameSource = resolved.team ? "team" : teamPrefixInfo(resolved.cwd, null).source;
  out.push(`Team name: ${repoBasename} (${nameSource}) — agents named ${repoBasename}-<role>`);
  for (const w of staleTeamKeys(resolved.cwd, resolved).warnings) out.push(w);
  out.push(`Stand up one missing peer: node "${ROSTER_CLI}" spawn-one <role> --cwd ${resolved.cwd}. Full-team Create is the /agent-team skill's job — do not hand-assemble create calls.`);
  let team = null;
  try {
    team = readTeam(hierarchyDir(resolved.cwd));
  } catch {
    team = null;
  }
  out.push(team ? `Team: ${team.team_id} (${team.transport}, ${team.members.length} member(s)${teamIsPartial(hierarchyDir(resolved.cwd), resolved.cwd, null, team, resolved) ? ", partial" : ""})` : "Team: none active — /agent-team create to instantiate the roster");
  if (resolved.shadowed.length) {
    out.push(`WARNING: project config shadows user-scope values for: ${resolved.shadowed.join(", ")}.`);
  }
  for (const warning of resolved.warnings) out.push(warning);
  out.push("Changes apply to this session now; other live sessions pick them up at their next start, clear, or compaction.");
  return out.join("\n");
}

// Run directly: print the status table for the current working directory.
if (process.argv[1] && resolve(process.argv[1]).endsWith("lib-config.mjs")) {
  process.stdout.write(statusReport(process.cwd()) + "\n");
}
