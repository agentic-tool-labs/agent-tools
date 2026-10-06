#!/usr/bin/env node
/**
 * agent-hierarchy — the dispatch watcher: a long-lived background process, one per Orchestrator
 * session, that keeps time for the requests the session dispatched. Run as a background Bash call
 * (`--session <id> --cwd <dir>`); its exit wakes the Orchestrator, and the findings reach it
 * through the report-back store and the UserPromptSubmit hook.
 *
 * It exits only with findings (code 3), when orphaned, at the lifetime cap, or on a signal. With
 * nothing to watch it keeps polling, because an exit is a wake.
 */

import { dirname, join } from "node:path";

import { hierarchyDir, logHookError } from "./lib-config.mjs";
import { appendGate, listExchanges, readGates, readMsgFile, responseLanded } from "./lib-hier.mjs";
import {
  appendPeerRecord,
  appendReportRecord,
  latestDispatchRows,
  latestWatcher,
  readPeerRecords,
  reportShown,
  watcherAlive,
} from "./lib-peer.mjs";
import { thresholdFor, watcherCall, WATCH_MAX_MS, WATCH_POLL_MS } from "./lib-liveness.mjs";

function arg(name) {
  const i = process.argv.indexOf(`--${name}`);
  return i >= 0 ? process.argv[i + 1] : null;
}

const sessionId = arg("session");
const cwd = arg("cwd") || process.cwd();
// The poll period can be overridden for tests only.
const pollMs = Number(process.env.AH_WATCH_POLL_MS) > 0 ? Number(process.env.AH_WATCH_POLL_MS) : WATCH_POLL_MS;

const fmtAge = (sec) => (sec < 3600 ? `${Math.floor(sec / 60)}m` : `${Math.floor(sec / 3600)}h`);

/** The latest `heard` timestamp from `name` for this session, in ms, or 0. */
function lastHeardMs(records, name) {
  let t = 0;
  for (const r of records) {
    if (r && r.type === "heard" && r.session_id === sessionId && r.from === name) t = Math.max(t, Date.parse(r.ts) || 0);
  }
  return t;
}

/** The events due now across this session's watchable dispatches; each also writes its own store row. */
function evaluate(now) {
  const events = [];
  const dir = hierarchyDir(cwd);
  const records = readPeerRecords();
  const gates = readGates(dir);
  const restart = `Restart the watcher if anything is still open: ${watcherCall(sessionId, cwd)}.`;
  for (const row of latestDispatchRows(sessionId)) {
    if (!row.path || reportShown(sessionId, row.request_id)) continue;
    const e = listExchanges(dirname(dirname(row.path))).find((x) => x.id === row.request_id);
    const fm = e && (readMsgFile(e.request.path) || {}).fm;
    if (!fm || fm.from !== "orchestrator") continue;
    const who = `${e.to} "${fm.to_name || "(unnamed)"}"`;
    const responsePath = join(dirname(row.path), `${e.id}--${fm.from}--${e.slug}--response.md`);
    if (!e.open) {
      if (!responseLanded(e.response.path, now)) continue;
      appendReportRecord("surfaced", sessionId, e.id);
      events.push({ request_id: e.id, kind: "LANDED", text: `ah watcher: ${who} wrote its report for ${e.id} but never sent it: ${e.response.path}. Read it now. ${restart}` });
      continue;
    }
    const T = thresholdFor(fm.eta) * 1000;
    const created = Date.parse(fm.created);
    const base = Math.max(Number.isFinite(created) ? created : 0, lastHeardMs(records, row.to_addr));
    const checkins = gates
      .filter((g) => g.type === "liveness-nudge" && g.session_id === sessionId && g.request_id === e.id && Date.parse(g.ts) > base)
      .map((g) => Date.parse(g.ts))
      .sort((a, b) => a - b);
    const ageSec = Math.max(0, (now - (Number.isFinite(created) ? created : now)) / 1000);
    if (checkins.length === 0 && now >= base + T) {
      appendGate(dir, { type: "liveness-nudge", session_id: sessionId, request_id: e.id });
      events.push({
        request_id: e.id,
        kind: "CHECK-IN",
        text: `ah watcher: ${who}, request ${e.id}, ${fmtAge(ageSec)} old (eta ${fm.eta || "small"}), no report. Call ListAgents, then SendMessage it once, with notify_when_idle:true and the message "Status of request ${e.id}? If finished, SendMessage me [hierarchy-msg ${responsePath}]; if not, one line on where you are." If it is gone, tell the user. ${restart}`,
      });
    } else if (checkins.length === 1 && now >= checkins[0] + T / 2) {
      appendGate(dir, { type: "liveness-nudge", session_id: sessionId, request_id: e.id });
      events.push({
        request_id: e.id,
        kind: "SILENT",
        text: `ah watcher: ${who}, request ${e.id}: no report and no reply ${fmtAge(T / 2000)} after the check-in. Tell the user now (name, request, age ${fmtAge(ageSec)}). The watcher will not wake you for it again unless the peer speaks. ${restart}`,
      });
    }
  }
  return events;
}

function main() {
  if (!sessionId) {
    console.error("dispatch-watcher: --session is required");
    process.exit(0);
  }
  if (watcherAlive(sessionId, process.pid)) {
    console.log(`already running (pid ${latestWatcher(sessionId).pid})`);
    process.exit(0);
  }
  appendPeerRecord({ type: "watcher", session_id: sessionId, pid: process.pid, started: new Date().toISOString() });

  const parent = process.ppid;
  const started = Date.now();
  const tick = () => {
    try {
      // ponytail: pid reuse could fake a live parent or watcher; acceptable because the Stop hook and the idle notice still cover a missed wake.
      if (process.ppid !== parent || process.ppid === 1) process.exit(0);
      if (Date.now() - started >= WATCH_MAX_MS) process.exit(0);
      const events = evaluate(Date.now());
      if (events.length) {
        const ts = new Date().toISOString();
        for (const ev of events) appendPeerRecord({ type: "watch-event", session_id: sessionId, request_id: ev.request_id, kind: ev.kind, text: ev.text, ts });
        for (const ev of events) console.log(ev.text);
        process.exit(3);
      }
    } catch (err) {
      logHookError("dispatch-watcher.mjs", err);
    }
  };
  tick();
  setInterval(tick, pollMs);
}

try {
  main();
} catch (err) {
  logHookError("dispatch-watcher.mjs", err);
  process.exit(0);
}
