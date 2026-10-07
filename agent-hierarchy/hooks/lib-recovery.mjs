/**
 * agent-hierarchy — recovery from a turn that ended on an API error.
 *
 * The StopFailure hook (stopfailure-recovery.mjs) and the dispatch watcher (dispatch-watcher.mjs)
 * share these definitions: which errors are worth retrying, how long to wait, what the resume
 * prompt says, and how to read an API-error end out of a session's transcript when the hook did
 * not fire.
 */

import { closeSync, fstatSync, openSync, readSync, realpathSync } from "node:fs";
import { homedir } from "node:os";
import { isAbsolute, join, sep } from "node:path";

/** Errors that may clear on their own. Anything else is escalated at once and never resumed. */
export const RETRYABLE = new Set(["server_error", "overloaded", "rate_limit", "unknown"]);

/** Resumes per failure streak. */
export const MAX_RESUMES = 3;

/** Seconds to wait before resume n (1-based): `rate_limit` waits longer than the rest. */
const BACKOFF_SEC = { rate_limit: [120, 480, 1200], other: [30, 120, 480] };

export const delaySec = (error, streak) => {
  const row = error === "rate_limit" ? BACKOFF_SEC.rate_limit : BACKOFF_SEC.other;
  return row[Math.min(Math.max(Number(streak) || 1, 1), row.length) - 1];
};

/** Two failures this close are one failure seen twice: by the hook and by the transcript. */
export const SAME_FAILURE_MS = 10000;
/** A `failed` record older than this does not start the next streak: nothing typed since may have cleared it. */
export const STREAK_WINDOW_MS = 30 * 60 * 1000;

export const RESUME_PARAGRAPH =
  "Continue the interrupted task. First re-check state: re-read any file you were changing, and for anything with side effects (push, merge, send, close, delete) confirm whether it already happened before doing it again. If you were mid-report, finish and send the report.";

const ANSI = /\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b[@-Z\\-_]/g;

/** One line of text with escape sequences and control characters gone, cut to `cap` characters. */
export function oneLine(value, cap) {
  if (typeof value !== "string") return "";
  const text = value.replace(ANSI, "").replace(/[\x00-\x1f\x7f-\x9f]+/g, " ").replace(/\s+/g, " ").trim();
  return text.length > cap ? text.slice(0, cap) : text;
}

/**
 * The error kind to record: `unknown` when the payload names none, else the name itself, cut to a
 * safe token. A kind this build does not know is kept as it is, so it is not retried.
 */
export function errorKind(value) {
  if (typeof value !== "string") return "unknown";
  const token = value.replace(/[^A-Za-z0-9_]/g, "").slice(0, 40);
  return token || "unknown";
}

/** The path of `file` when it is an absolute `.jsonl` whose real location is under `~/.claude/projects/`, else null. */
export function transcriptPathOk(file) {
  if (typeof file !== "string" || file.length > 1024 || !isAbsolute(file) || !file.endsWith(".jsonl")) return null;
  try {
    const root = realpathSync(join(homedir(), ".claude", "projects"));
    const real = realpathSync(file);
    return real.startsWith(root + sep) ? real : null;
  } catch {
    return null;
  }
}

const TAIL_BYTES = 64 * 1024;

/**
 * Whether the last conversation entry of a transcript is an API-error message the harness wrote:
 * `{error, failed_at}`, else null. Only the last 64 KB is read, and only when the file's (mtime, size)
 * differs from the one `seen` holds for it. Entries that are not part of the conversation (system
 * rows such as a turn's duration, attachments, side-chain rows) are skipped; the last assistant or
 * user entry decides, so an interrupt or typed text after an error means no failure.
 */
export function transcriptFailure(file, seen) {
  const real = transcriptPathOk(file);
  if (!real) return null;
  let fd = null;
  try {
    fd = openSync(real, "r");
    const st = fstatSync(fd);
    const stamp = `${st.mtimeMs}:${st.size}`;
    if (seen.get(real) === stamp) return null;
    seen.set(real, stamp);
    const start = Math.max(0, st.size - TAIL_BYTES);
    const buf = Buffer.alloc(st.size - start);
    readSync(fd, buf, 0, buf.length, start);
    const lines = buf.toString("utf8").split("\n");
    if (start > 0) lines.shift();
    for (let i = lines.length - 1; i >= 0; i--) {
      if (!lines[i].trim()) continue;
      let entry;
      try {
        entry = JSON.parse(lines[i]);
      } catch {
        continue;
      }
      if (!entry || typeof entry !== "object" || entry.isSidechain === true) continue;
      if (entry.type !== "assistant" && entry.type !== "user") continue;
      if (entry.type !== "assistant" || entry.isApiErrorMessage !== true) return null;
      const at = Date.parse(entry.timestamp);
      return { error: errorKind(entry.error), failed_at: Number.isFinite(at) ? new Date(at).toISOString() : new Date().toISOString() };
    }
    return null;
  } catch {
    return null;
  } finally {
    if (fd !== null) closeSync(fd);
  }
}
