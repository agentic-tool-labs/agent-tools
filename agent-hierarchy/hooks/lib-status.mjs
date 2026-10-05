/**
 * agent-hierarchy — the hierarchy status document, `<hier>/status.json` (docs/status-file.md). This
 * is the only code that turns hierarchy state into that document and the only code that writes it.
 * Its readers (claude-tui-line's items, the ah mod) display it and re-derive nothing.
 *
 * Time-driven changes are scheduled in the document rather than waited for: each dispatch carries
 * its `states` with `at` timestamps, and `timeline` holds every instant the counts change, so a
 * reader picks the last entry with `at ≤ now` and the file never needs a rewrite because time passed.
 *
 * Every input comes from the existing single sources: team files and team liveness (lib-roster),
 * exchanges and the open rule, member liveness, the eta table and check-in cadence (lib-hier), the
 * dispatch origin (lib-peer), run anchors and decision counts (lib-decisions). Nothing here spawns
 * a process, calls herdr or takes a lock.
 */

import { existsSync, readFileSync, renameSync, statSync, writeFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";

import { hierarchyDir, resolveConfig } from "./lib-config.mjs";
import { decisionLogPath, decisionSummary, openRunAnchor, readDecisions } from "./lib-decisions.mjs";
import { attributedRoster, CHECKIN_CADENCE, etaOf, listExchanges, attributedLiveness, readGates, readMsgFile, SELF_STATE, thresholdFor } from "./lib-hier.mjs";
import { dispatchOrigin } from "./lib-peer.mjs";
import { listTeamNames, readTeam, teamIsLive } from "./lib-roster.mjs";

export const STATUS_SCHEMA = 1;
/** The /pipeline skill's cap on rounds per item; it has no other code constant. */
export const ROUND_CAP = 3;
/** How long a reported dispatch stays listed, and so how long it counts toward nothing but stays visible. */
const REPORTED_WINDOW_MS = 600 * 1000;
const EXPIRES_AFTER_MS = 24 * 3600 * 1000;
const DISPATCH_CAP = 50;
const ITEM_CAP = 20;
const NAME_CAP = 64;
const SLUG_CAP = 32;
const NOTE_CAP = 80;
// lib-hier, lib-roster and lib-decisions import this module back, so nothing at module top level may
// read an imported binding: derived values are built on first use.
let activities = null;
const knownActivity = (a) => (activities ||= [...Object.values(SELF_STATE), "unknown"]).includes(a);
const SEVERITY = { stalled: 0, blocked: 1, overdue: 2, working: 3, reported: 4, expired: 5 };

// Escape sequences go whole (CSI and OSC), then any C0/C1 control character left.
const ESC_SEQ_RE = /\u001b\[[0-?]*[ -/]*[@-~]|\u001b\][^\u0007\u001b]*(?:\u0007|\u001b\\)?/g;
const CONTROL_RE = /[\u0000-\u001f\u007f-\u009f]/g;

/** A string read from a file, safe to display: escape sequences and control characters stripped, cut at `cap`. */
function clean(value, cap) {
  if (typeof value !== "string") return null;
  const text = value.replace(ESC_SEQ_RE, "").replace(CONTROL_RE, "");
  return cap ? text.slice(0, cap) : text;
}

const iso = (ms) => new Date(ms).toISOString();

function readActivity(dir, file) {
  if (file.includes("/") || file.includes("\\")) return null;
  try {
    const rec = JSON.parse(readFileSync(join(dir, "activity", file), "utf8"));
    return rec && typeof rec === "object" && !Array.isArray(rec) ? rec : null;
  } catch {
    return null;
  }
}

function describeMembers(dir, team, roster) {
  const members = (Array.isArray(team.members) ? team.members : []).filter((m) => m && typeof m.name === "string").map((m) => {
    const route = m.route === "pane" ? "pane" : "peer";
    let live, sessionId = null, rec;
    if (route === "pane") {
      rec = readActivity(dir, `pane-${m.name}.json`);
      live = !rec ? null : rec.activity !== "unknown";
    } else {
      const att = attributedLiveness(roster, m.name);
      live = att.live;
      sessionId = att.rec && typeof att.rec.session_id === "string" ? att.rec.session_id : null;
      rec = sessionId ? readActivity(dir, `${sessionId}.json`) : null;
    }
    const activity = rec && knownActivity(rec.activity) ? rec.activity : "unknown";
    return {
      name: clean(m.name, NAME_CAP),
      role: clean(m.role, NAME_CAP),
      label: null,
      kind: clean(m.kind, NAME_CAP) || "claude",
      route,
      session_id: clean(sessionId),
      live,
      activity,
      activity_at: rec ? clean(rec.at) : null,
      blocked_by: activity === "blocked" ? clean(rec.blocked_by, NAME_CAP) : null,
      blocked_note: route === "pane" && activity === "blocked" ? clean(rec.note, NOTE_CAP) : null,
    };
  });
  for (const m of members) {
    const shared = members.some((o) => o !== m && o.live === true && o.role === m.role);
    m.label = shared ? m.name : m.role;
  }
  return members;
}

/** `states` per the four rules: reported, member gone, member blocked, otherwise the cadence schedule from the origin. */
function dispatchStates(nowMs, reportedMs, member, sentMs, tMs) {
  if (reportedMs !== null) return [{ at: iso(nowMs), state: "reported" }, { at: iso(reportedMs + REPORTED_WINDOW_MS), state: "expired" }];
  if (member && member.live === false) return [{ at: iso(nowMs), state: "stalled", reason: "member-gone" }];
  if (member && member.activity === "blocked") return [{ at: iso(nowMs), state: "blocked" }];
  const overdueMs = sentMs + tMs * CHECKIN_CADENCE[0];
  return [
    { at: iso(sentMs), state: "working" },
    { at: iso(overdueMs), state: "overdue" },
    { at: iso(overdueMs + tMs * CHECKIN_CADENCE[1]), state: "stalled", reason: "no-report" },
  ];
}

/** A dispatch's state at `ms`: the last of its states at or before it, else its first. */
function stateAt(d, ms) {
  let current = d.states[0];
  for (const s of d.states) if (Date.parse(s.at) <= ms) current = s;
  return current.state;
}

function requestFm(e, cache) {
  if (!cache.has(e.id)) {
    const parsed = readMsgFile(e.request.path);
    cache.set(e.id, (parsed && parsed.fm) || {});
  }
  return cache.get(e.id);
}

function mtimeMs(path) {
  try {
    return statSync(path).mtimeMs;
  } catch {
    return null;
  }
}

function describeDispatches(exchanges, fmCache, teamKey, members, gates, nowMs) {
  const out = [];
  for (const e of exchanges) {
    if (e.to === "orchestrator") continue;
    const reportedMs = e.open ? null : mtimeMs(e.response.path);
    if (!e.open && (reportedMs === null || reportedMs + REPORTED_WINDOW_MS <= nowMs)) continue;
    const fm = requestFm(e, fmCache);
    if ((fm.team || null) !== teamKey) continue;
    const sentAt = dispatchOrigin(e.id, fm.created || null);
    const sentMs = Date.parse(sentAt);
    if (!Number.isFinite(sentMs)) continue;
    const eta = etaOf(fm.eta);
    const tMs = thresholdFor(eta) * 1000;
    const toName = clean(fm.to_name, NAME_CAP);
    const member = (toName && members.find((m) => m.name === toName)) || (() => {
      const byRole = members.filter((m) => m.role === e.to);
      return byRole.length === 1 ? byRole[0] : null;
    })();
    out.push({
      id: e.id,
      slug: clean(e.slug, SLUG_CAP),
      to: e.to,
      to_name: toName,
      member: member ? member.name : null,
      label: member ? member.label : toName || e.to,
      eta,
      eta_ms: tMs,
      created: clean(fm.created),
      sent_at: clean(sentAt),
      checkins: gates.filter((g) => g && g.type === "liveness-nudge" && g.request_id === e.id).length,
      reported_at: reportedMs === null ? null : iso(reportedMs),
      states: dispatchStates(nowMs, reportedMs, member, sentMs, tMs),
    });
  }
  return out.sort((a, b) => SEVERITY[stateAt(a, nowMs)] - SEVERITY[stateAt(b, nowMs)] || Date.parse(a.sent_at) - Date.parse(b.sent_at));
}

function describePipeline(dir, exchanges, fmCache, teamKey) {
  const anchor = openRunAnchor(dir, teamKey);
  if (!anchor.id) return null;
  const anchorEx = exchanges.find((e) => e.id === anchor.id);
  const started = anchorEx ? requestFm(anchorEx, fmCache).created || null : null;
  const startedMs = Date.parse(started);
  const { decisions, skipped } = readDecisions(decisionLogPath(dir, anchor.id));
  const slugs = new Set();
  for (const e of exchanges) {
    if (e.to === "orchestrator" || e.slug.startsWith("dec-")) continue;
    const fm = requestFm(e, fmCache);
    if ((fm.team || null) === teamKey && Date.parse(fm.created) >= startedMs) slugs.add(e.slug);
  }
  const items = [...slugs].map((slug) => {
    const all = exchanges.filter((e) => e.slug === slug);
    const newest = all.reduce((a, b) => (Date.parse(requestFm(b, fmCache).created) > Date.parse(requestFm(a, fmCache).created) ? b : a));
    return { slug: clean(slug, SLUG_CAP), rounds: all.length, open: all.some((e) => e.open), to: newest.to, newestMs: Date.parse(requestFm(newest, fmCache).created) };
  });
  items.sort((a, b) => b.newestMs - a.newestMs);
  return {
    anchor_id: anchor.id,
    started: clean(started),
    round_cap: ROUND_CAP,
    waiting_on_user: decisionSummary(decisions, skipped).parked,
    items: items.slice(0, ITEM_CAP).map(({ newestMs: _n, ...item }) => item),
  };
}

function countsAt(members, dispatches, ms) {
  const live = members.filter((m) => m.live !== false);
  const states = dispatches.map((d) => stateAt(d, ms));
  return {
    live: live.length,
    out: states.filter((s) => s !== "reported" && s !== "expired").length,
    blocked: live.filter((m) => m.activity === "blocked").length,
    overdue: states.filter((s) => s === "overdue").length,
    stalled: states.filter((s) => s === "stalled").length,
  };
}

function timelineEntry(at, c, enabled, anyPipeline) {
  const extra = [["blocked", "b"], ["overdue", "o"], ["stalled", "s"]].filter(([k]) => c[k] > 0);
  const tone = c.overdue + c.stalled > 0 ? "bad" : c.blocked > 0 ? "warn" : c.out > 0 ? "work" : "idle";
  return {
    at,
    visible: Boolean(enabled && (c.live > 0 || c.out > 0 || anyPipeline)),
    tone,
    ...c,
    text: [`${c.live} live · ${c.out} out`, ...extra.map(([k]) => `${c[k]} ${k}`)].join(" · "),
    short: [`${c.live}/${c.out}`, ...extra.map(([k, s]) => `${c[k]}${s}`)].join(" "),
  };
}

function buildTimeline(nowMs, members, dispatches, enabled, anyPipeline) {
  const instants = [...new Set(dispatches.flatMap((d) => d.states.map((s) => Date.parse(s.at))).filter((ms) => ms > nowMs))].sort((a, b) => a - b);
  const timeline = [];
  let last = null;
  for (const ms of [nowMs, ...instants]) {
    const c = countsAt(members, dispatches, ms);
    const key = JSON.stringify(c);
    if (key === last) continue;
    last = key;
    timeline.push(timelineEntry(iso(ms), c, enabled, anyPipeline));
  }
  return timeline;
}

/** The status document for the pool `dir` (by default the one `cwd` resolves to), evaluated at `nowMs`. Reads only. */
export function computeStatus(cwd, nowMs = Date.now(), dir = hierarchyDir(cwd)) {
  const enabled = Boolean(resolveConfig(cwd).enabled);
  const teams = [];
  const allMembers = [];
  const allDispatches = [];
  if (dir && existsSync(dir)) {
    const roster = attributedRoster(dir);
    const exchanges = listExchanges(dir);
    const gates = readGates(dir);
    const fmCache = new Map();
    for (const key of [null, ...listTeamNames(dir)]) {
      const t = readTeam(dir, key);
      if (!teamIsLive(t, null)) continue;
      const members = describeMembers(dir, t, roster);
      const dispatches = describeDispatches(exchanges, fmCache, key, members, gates, nowMs);
      allMembers.push(...members);
      allDispatches.push(...dispatches);
      teams.push({
        team: key,
        members,
        dispatches: dispatches.slice(0, DISPATCH_CAP),
        dispatches_truncated: Math.max(0, dispatches.length - DISPATCH_CAP),
        pipeline: describePipeline(dir, exchanges, fmCache, key),
      });
    }
  }
  return {
    schema: STATUS_SCHEMA,
    written_at: iso(nowMs),
    expires_at: iso(nowMs + EXPIRES_AFTER_MS),
    enabled,
    member_sessions: allMembers.filter((m) => m.route === "peer" && m.live === true && m.session_id).map((m) => m.session_id),
    teams,
    timeline: buildTimeline(nowMs, allMembers, allDispatches, enabled, teams.some((t) => t.pipeline !== null)),
  };
}

/**
 * Write `doc` to `<dir>/status.json` atomically (a per-process temp file, then rename). Writes nothing
 * when `dir` does not exist, and never creates it. Never throws.
 */
export function saveStatus(dir, doc) {
  try {
    if (dir && existsSync(dir)) {
      const tmp = join(dir, `status.json.${process.pid}.tmp`);
      writeFileSync(tmp, JSON.stringify(doc) + "\n");
      // ponytail: two writers racing leave the last rename, possibly one event behind; the next write fixes it. Coalesce writes if that ever shows.
      renameSync(tmp, join(dir, "status.json"));
    }
  } catch {
    // A status write never fails the operation that triggered it.
  }
}

let writing = false;

/** Compute and save, ignoring a call made while a write is already running in this process. Never throws. */
function refresh(cwd, dir, nowMs) {
  if (writing) return null;
  writing = true;
  try {
    const doc = computeStatus(cwd, nowMs, dir);
    saveStatus(dir, doc);
    return doc;
  } catch {
    return null;
  } finally {
    writing = false;
  }
}

/**
 * Recompute and write the document for the pool `cwd` resolves to. Returns it, or null when it could
 * not be computed. Never throws: a status write never changes its caller's exit code, output or decision.
 */
export function writeStatus(cwd, nowMs = Date.now()) {
  return refresh(cwd, hierarchyDir(cwd), nowMs);
}

/** The repo whose config governs a hierarchy dir: `<root>` for `<root>/.claude/hierarchy`, else this process's cwd. */
function cwdOfDir(dir) {
  const parent = dirname(dir);
  return basename(dir) === "hierarchy" && basename(parent) === ".claude" ? dirname(parent) : process.cwd();
}

/**
 * The write trigger the hierarchy's shared write helpers call after changing state in `dir`: peers
 * rows, message files, team files, decision rows, check-in rows. Never throws, does nothing without
 * the dir, and ignores a trigger that arrives while this process is already writing.
 */
export function statusChanged(dir) {
  try {
    if (dir && existsSync(dir)) refresh(cwdOfDir(dir), dir, Date.now());
  } catch {
    // A status write never fails the operation that triggered it.
  }
}

/** `ah · <text>` for the timeline entry current at `nowMs`, or "" when that entry is not visible. */
export function plainStatus(doc, nowMs) {
  let entry = doc.timeline[0];
  for (const e of doc.timeline) if (Date.parse(e.at) <= nowMs) entry = e;
  return entry && entry.visible ? `ah · ${entry.text}` : "";
}
