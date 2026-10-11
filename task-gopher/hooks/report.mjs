#!/usr/bin/env node
/**
 * task-gopher — audit report.
 *
 * Reads the append-only JSONL log written by pretooluse-nudge.mjs and prints a
 * human-readable summary: how often the strict checkpoint fired, how many
 * direct retrievals were bypassed (and what they were), how many times the
 * agent dispatched to task-gopher vs. smart-gopher, how often the
 * smart-gopher gate checkpointed a distinct escalation request, and how the
 * subagent relay behaved. Because
 * dispatch/relay lines are written whenever the plugin is ON while
 * checkpoint/bypass lines require strict mode, the bypass-to-dispatch ratio is
 * computed only over dispatches from strict-gated turns — otherwise
 * non-strict-era dispatches would dilute the exact rubber-stamping signal the
 * ratio exists to expose.
 *
 * It also prints the per-turn delegation metrics M1-M6 (spec 0003 §4), a turn being one `pid`. Checkpoint counts are
 * shown twice, as logged and "as if G1": the first Read of a turn passes unchallenged once G1 ships, so older rows where
 * a turn-start checkpoint hit a Read are recomputed as passes, which is what lets the two eras be compared.
 *
 * Read-only. Prints to stdout. Never throws.
 */

import { readFileSync } from "node:fs";
import { LOG_FILE, gopherKind } from "./directive.mjs";

const RECENT = Number(process.argv[2]) || 12;

const pct = (a, b) => (b ? `${((100 * a) / b).toFixed(1)}%` : "n/a");
const per = (a, b) => (b ? (a / b).toFixed(2) : "n/a");

/** ISO week label (YYYY-Www) of an ISO timestamp, or "" when it has none. */
function weekOf(ts) {
  const d = new Date(ts);
  if (!ts || Number.isNaN(d.getTime())) return "";
  const t = new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate()));
  const day = t.getUTCDay() || 7;
  t.setUTCDate(t.getUTCDate() + 4 - day);
  const y0 = new Date(Date.UTC(t.getUTCFullYear(), 0, 1));
  return `${t.getUTCFullYear()}-W${String(Math.ceil(((t - y0) / 86400000 + 1) / 7)).padStart(2, "0")}`;
}

/**
 * M1-M6 over the work events (checkpoint, bypass, dispatch) of each turn, in log order. `asIfG1` recomputes the log as
 * if the first Read of a turn had been a free pass: such a turn-start checkpoint row becomes a bypass.
 */
function metricsOf(events, agentOf, asIfG1) {
  const turns = new Map();
  for (const e of events) {
    if (!e.pid || !["checkpoint", "bypass", "dispatch"].includes(e.event)) continue;
    let row = e;
    if (asIfG1 && e.event === "checkpoint" && e.kind === "turn-start" && e.tool === "Read") row = { ...e, event: "bypass", open: "read" };
    if (!turns.has(e.pid)) turns.set(e.pid, []);
    turns.get(e.pid).push(row);
  }
  let work = 0, firstDispatch = 0, firstCheckpoint = 0, withCheckpoint = 0, escalated = 0, gated = 0;
  const byAgent = { "task-gopher": 0, "smart-gopher": 0 };
  let taskTurns = 0, escalatedTurns = 0;
  for (const rows of turns.values()) {
    const hasCp = rows.some((r) => r.event === "checkpoint");
    const hasDisp = rows.some((r) => r.event === "dispatch");
    if (hasCp) withCheckpoint++;
    escalated += rows.filter((r) => r.event === "checkpoint" && r.kind === "escalated").length;
    gated += rows.filter((r) => r.event === "checkpoint" || r.event === "bypass").length;
    for (const r of rows) if (r.event === "dispatch") byAgent[agentOf(r)] = (byAgent[agentOf(r)] || 0) + 1;
    if (hasCp || hasDisp) {
      work++;
      if (rows[0].event === "dispatch") firstDispatch++;
      if (rows[0].event === "checkpoint") firstCheckpoint++;
    }
    const kinds = rows.filter((r) => r.event === "dispatch").map(agentOf);
    const t = kinds.indexOf("task-gopher");
    if (t >= 0) {
      taskTurns++;
      if (kinds.slice(t + 1).includes("smart-gopher")) escalatedTurns++;
    }
  }
  const dispatches = byAgent["task-gopher"] + byAgent["smart-gopher"];
  return { work, firstDispatch, firstCheckpoint, withCheckpoint, escalated, gated, dispatches, byAgent, taskTurns, escalatedTurns };
}

function printMetrics(events, agentOf, smartGateCheckpoints) {
  const a = metricsOf(events, agentOf, false);
  const g = metricsOf(events, agentOf, true);
  console.log("");
  console.log("per-turn delegation metrics (a turn is one prompt id; spec 0003 §4)");
  console.log(`  work turns (a checkpoint or a dispatch): ${a.work}`);
  console.log(`  M1 upfront delegation (first work event is a dispatch): ${a.firstDispatch}/${a.work} = ${pct(a.firstDispatch, a.work)}   target >= 40% (>= 30% passes)`);
  console.log(`  M2 dispatches per 100 gated direct calls: ${per(100 * a.dispatches, a.gated)}  (${a.dispatches} dispatches / ${a.gated} gated calls)   target >= 10`);
  console.log(`  M3 escalated checkpoints per retrieval turn: as logged ${per(a.escalated, a.withCheckpoint)}  |  as if G1 ${per(g.escalated, g.withCheckpoint)}   target <= 1.0`);
  console.log(`  M4 turns that open with a checkpoint: as logged ${pct(a.firstCheckpoint, a.work)}  |  as if G1 ${pct(g.firstCheckpoint, g.work)}   target <= 50% as if G1`);
  console.log(
    `  M5 per-gopher dispatches per 100 gated calls: task-gopher ${per(100 * a.byAgent["task-gopher"], a.gated)}, smart-gopher ${per(100 * a.byAgent["smart-gopher"], a.gated)}`
  );
  console.log(
    `  M6a escalations (a smart-gopher dispatch after a task-gopher one in the same turn): ${a.escalatedTurns}/${a.taskTurns} task-gopher turns = ${pct(a.escalatedTurns, a.taskTurns)}   target <= 15%`
  );
  console.log(`  M6b smart-gopher orders available for a blind label (first 160 characters): ${smartGateCheckpoints.length}   target <= 20% decision-free of >= 100 sampled`);
  // by week: how M2 moves, which is the trend the spec's baseline is read from
  const weeks = new Map();
  for (const e of events) {
    const w = weekOf(e.ts);
    if (!w) continue;
    const row = weeks.get(w) || { gated: 0, disp: 0 };
    if (e.event === "checkpoint" || e.event === "bypass") row.gated++;
    if (e.event === "dispatch") row.disp++;
    weeks.set(w, row);
  }
  const shown = [...weeks.entries()].sort().slice(-8);
  if (shown.length) console.log(`  M2 by week: ${shown.map(([w, r]) => `${w} ${per(100 * r.disp, r.gated)}`).join(", ")}`);
}

function main() {
  let raw;
  try {
    raw = readFileSync(LOG_FILE, "utf8");
  } catch {
    console.log(`No task-gopher audit log yet (${LOG_FILE}).`);
    console.log("It fills up once the plugin is ON (dispatch/relay events) — and in strict mode, checkpoint events too.");
    return;
  }

  const events = raw
    .split("\n")
    .filter(Boolean)
    .map((l) => {
      try {
        return JSON.parse(l);
      } catch {
        return null;
      }
    })
    .filter(Boolean);

  if (!events.length) {
    console.log(`task-gopher audit log is empty (${LOG_FILE}).`);
    return;
  }

  const checkpoints = events.filter((e) => e.event === "checkpoint");
  const bypasses = events.filter((e) => e.event === "bypass");
  const dispatches = events.filter((e) => e.event === "dispatch");
  const relayOk = events.filter((e) => e.event === "relay-ok");
  const relayInjected = events.filter((e) => e.event === "relay-injected");
  const relaySkipped = events.filter((e) => e.event === "relay-skip");
  const blocked = events.filter((e) => e.event === "destructive-blocked");
  const authorized = events.filter((e) => e.event === "destructive-allowed");
  const asked = events.filter((e) => e.event === "destructive-ask");
  const smartGateCheckpoints = events.filter((e) => e.event === "smart-gate-checkpoint");
  const verbatimDenies = events.filter((e) => e.event === "verbatim-deny");
  const exempts = events.filter((e) => e.event === "exempt");
  const openReads = events.filter((e) => e.open === "read");
  const turns = new Set(events.map((e) => e.pid).filter(Boolean)).size;

  // Only dispatches from turns the strict gate actually saw count toward the
  // ratio; dispatch lines also accrue in non-strict mode.
  const strictPids = new Set([...checkpoints, ...bypasses].map((e) => e.pid).filter(Boolean));
  const strictDispatches = dispatches.filter((d) => strictPids.has(d.pid));

  // `e.agent` fallback matters: logs written by earlier versions have no `agent`
  // field, and the report must not misreport historical lines. Falling back to
  // the `detail` substring (which holds the subagent_type) reads them correctly;
  // `gopherKind` already tests smart-gopher before task-gopher (see directive.mjs).
  const agentOf = (e) => e.agent || gopherKind(e.detail) || "task-gopher";
  const smartDispatches = dispatches.filter((d) => agentOf(d) === "smart-gopher");
  const cheapDispatches = dispatches.filter((d) => agentOf(d) === "task-gopher");

  const ratio = strictDispatches.length
    ? (bypasses.length / strictDispatches.length).toFixed(2)
    : `∞ (${bypasses.length} bypasses, 0 strict-turn dispatches)`;

  // Which tools/commands get bypassed most.
  const byTool = {};
  for (const b of bypasses) byTool[b.tool || "?"] = (byTool[b.tool || "?"] || 0) + 1;
  const toolBreakdown = Object.entries(byTool)
    .sort((a, b) => b[1] - a[1])
    .map(([t, n]) => `${t} ${n}`)
    .join(", ");

  const span =
    events[0].ts && events[events.length - 1].ts
      ? `${events[0].ts} → ${events[events.length - 1].ts}`
      : "(no timestamps)";

  console.log("task-gopher — audit report");
  console.log("=".repeat(42));
  console.log(`log:            ${LOG_FILE}`);
  console.log(`span:           ${span}`);
  console.log(`turns logged:   ${turns}  (${strictPids.size} saw the strict gate)`);
  console.log(`checkpoints:    ${checkpoints.length}  (times the strict gate blocked)`);
  console.log(`bypasses:       ${bypasses.length}  (direct retrievals done anyway)`);
  console.log(
    `dispatches:     ${dispatches.length}  (${cheapDispatches.length} task-gopher, ${smartDispatches.length} smart-gopher; ` +
      `${strictDispatches.length} in strict-gated turns)`
  );
  console.log(`bypass/dispatch ratio: ${ratio}  (strict-gated turns only; lower is better)`);
  if (smartDispatches.length || smartGateCheckpoints.length) {
    console.log(
      `smart-gopher gate: ${smartGateCheckpoints.length} checkpoint(s) fired ` +
        `(once per distinct request, independent of strict mode)`
    );
  }
  if (toolBreakdown) console.log(`bypassed tools: ${toolBreakdown}`);
  if (relayOk.length || relayInjected.length || relaySkipped.length) {
    console.log(
      `subagent relay:  ${relayInjected.length} dispatches stamped, ${relayOk.length} already carried it`
    );
  }
  if (relaySkipped.length) {
    // Broken down by reason so a mistaken skip is legible: "no-dispatch-tool" on
    // an agent that clearly can dispatch is the failure this feature can cause.
    const byReason = {};
    for (const s of relaySkipped) byReason[s.reason || "?"] = (byReason[s.reason || "?"] || 0) + 1;
    const reasons = Object.entries(byReason)
      .sort((a, b) => b[1] - a[1])
      .map(([r, n]) => `${r} ${n}`)
      .join(", ");
    console.log(`relay skipped:   ${relaySkipped.length} dispatches to agents that can't delegate (${reasons})`);
  }

  // The guard's own trail. Interceptions are shown in full rather than counted:
  // each one is a command the runner was about to run and could not judge,
  // which is the single most useful thing this log holds. The ask count is what
  // the guard cost a human in interruptions — if it climbs, the leads are
  // dispatching destructive work instead of running it themselves.
  if (blocked.length || authorized.length || asked.length) {
    console.log(
      `destructive guard: ${asked.length} put to you for approval, ${blocked.length} denied outright, ` +
        `${authorized.length} run under an explicit ALLOW-DESTRUCTIVE`
    );
    const preauth = asked.filter((a) => a.preauthorized).length;
    if (preauth) {
      console.log(`  (${preauth} of those prompts carried a lead's ALLOW-DESTRUCTIVE recommendation)`);
    }
    for (const b of [...asked, ...blocked].slice(-RECENT)) {
      const labels = Array.isArray(b.labels) ? ` [${b.labels.join(", ")}]` : "";
      const what = b.event === "destructive-ask" ? "asked" : "blocked";
      const why = b.why ? ` (${b.why})` : "";
      console.log(`  - ${what} [${agentOf(b)}]: ${b.detail || "?"}${labels}${why}`);
    }
  }

  if (verbatimDenies.length || exempts.length || openReads.length) {
    console.log(
      `other gate events: ${verbatimDenies.length} verbatim-deny, ${exempts.length} exempt (a flagged command that is not a retrieval), ` +
        `${openReads.length} free first Read(s) (open: "read")`
    );
  }
  printMetrics(events, agentOf, smartGateCheckpoints);

  const recent = bypasses.slice(-RECENT);
  if (recent.length) {
    console.log("");
    console.log(`recent bypasses (last ${recent.length}) — what was run directly:`);
    for (const r of recent) {
      const when = r.ts ? r.ts.replace("T", " ").replace(/\..*/, "") : "";
      const detail = r.detail ? `: ${r.detail}` : "";
      console.log(`  - ${when}  ${r.tool || "?"}${detail}`);
    }
  }

  console.log("");
  console.log("A high bypass/dispatch ratio or lots of clearly-delegatable reads above");
  console.log("means the gate is being rubber-stamped. Clear the log with:");
  console.log("  /task-gopher log clear");
}

try {
  main();
} catch (e) {
  console.log(`task-gopher report: could not generate (${e && e.message}).`);
}
