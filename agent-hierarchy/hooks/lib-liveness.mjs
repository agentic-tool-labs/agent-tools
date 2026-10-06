#!/usr/bin/env node
/**
 * agent-hierarchy — the Orchestrator check-in cadence shared by the Stop hook and the dispatch
 * watcher, so both read one definition of "past its eta" and "due for a check-in".
 */

import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { CHECKIN_CADENCE, thresholdFor } from "./lib-hier.mjs";

/** The dispatch watcher script's file name; the in-flight tracker keys on it. */
export const WATCHER_SCRIPT = "dispatch-watcher.mjs";

/** How often the watcher reads the store, and the longest it lives (an exit is a wake, so it never idles out). */
export const WATCH_POLL_MS = 15 * 1000;
export const WATCH_MAX_MS = 12 * 60 * 60 * 1000;

/** The exact Bash call that starts a session's watcher, as text for a hook to hand the Orchestrator. */
export function watcherCall(sessionId, cwd) {
  const script = join(dirname(fileURLToPath(import.meta.url)), WATCHER_SCRIPT);
  return `Bash with run_in_background: true, description: "ah dispatch watcher", command: node "${script}" --session ${sessionId} --cwd ${cwd}`;
}

export { thresholdFor };

/**
 * A dispatch is due for a check-in when it has never been nudged, or when the gap CHECKIN_CADENCE
 * gives for its next check-in has passed since its last nudge: half a threshold before the second,
 * a full one before each later one. An unparseable or absent `ts` counts as due — nudging one extra
 * time is the harmless direction.
 */
export function dueForNudge(gates, sessionId, item, now) {
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
