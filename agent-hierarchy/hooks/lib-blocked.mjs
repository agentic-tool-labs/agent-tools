/**
 * agent-hierarchy — how a member stopped at a prompt is seen. One place for the screen read that
 * `roster.mjs` (deliver, spawn, answer) and the dispatch watcher share, so a screen is recognised,
 * hashed and excerpted the same way wherever it is looked at.
 *
 * The caller supplies the reader of the raw screen text (`roster.mjs` goes through its own herdr
 * call); `readVisibleScreen` is the plain one for a process that has none.
 */

import { execFileSync } from "node:child_process";

import { resolveKind } from "./lib-config.mjs";
import { KIND_HARNESS, recognizeScreen, screenHash } from "./lib-roster.mjs";

/** One `visible` read of an agent's screen — only what is on screen now, never scrollback. "" when it cannot be read. */
export function readVisibleScreen(name) {
  try {
    return execFileSync("herdr", ["agent", "read", name, "--source", "visible"], { encoding: "utf8", timeout: Number(process.env.AH_HERDR_TIMEOUT_MS || 10000), maxBuffer: 1024 * 1024, stdio: ["ignore", "pipe", "ignore"] });
  } catch {
    return "";
  }
}

/** `herdr agent list` as `[{name, pane_id, agent_status}]`, or null when herdr cannot answer. */
export function herdrAgentList() {
  try {
    const out = execFileSync("herdr", ["agent", "list"], { encoding: "utf8", timeout: Number(process.env.AH_HERDR_TIMEOUT_MS || 10000), maxBuffer: 1024 * 1024, stdio: ["ignore", "pipe", "ignore"] });
    const agents = JSON.parse(out)?.result?.agents;
    return Array.isArray(agents) ? agents.map((a) => ({ name: a.name || null, pane_id: a.pane_id, agent_status: a.agent_status || null })) : null;
  } catch {
    return null;
  }
}

/**
 * What a member's screen shows, given Herdr's status for it: `composer` (idle, empty composer),
 * `recognized` (the prompt it ends with, else null), `block`, `blocked_by` (that prompt, else
 * `harness-prompt` when Herdr reports the agent blocked, else null), the `screen` itself and its
 * `screen_hash`. The same read gives the hash `answer` later checks.
 */
export function readPromptCore(member, agentStatus, readScreen = readVisibleScreen) {
  const kind = resolveKind(member);
  let screen = "";
  try {
    screen = String(readScreen(member.name) ?? "");
  } catch {
    screen = "";
  }
  const seen = recognizeScreen(kind, screen, agentStatus);
  const blocked_by = seen.prompt || (agentStatus === "blocked" ? "harness-prompt" : null);
  return { composer: seen.composer, recognized: seen.prompt, block: seen.block, blocked_by, screen, screen_hash: screenHash(screen) };
}

/** The screen line a recognised prompt starts on (the line holding its heading), or null. */
export function promptNoteLine(kind, recognized, screen) {
  const prompts = (KIND_HARNESS[kind] || {}).prompts || {};
  const spec = recognized ? prompts[recognized] : null;
  if (!spec || typeof spec.heading !== "string") return null;
  const line = String(screen || "").split("\n").find((l) => l.includes(spec.heading));
  return line ? line.trim() : null;
}

const ANSI = /\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b[@-Z\\-_]/g;
const EXCERPT_LINES = 12;
const EXCERPT_CAP = 1200;

/**
 * The part of a screen worth showing: the recognised prompt's heading line, else the last
 * non-empty visible lines. Escape sequences and control characters are stripped and the text is
 * cut to a fixed length, because it is data from another session's screen.
 */
export function excerptOf(screen, note = null) {
  const clean = (s) => String(s ?? "").replace(ANSI, "").replace(/\r/g, "").replace(/[\x00-\x08\x0b-\x1f\x7f-\x9f]/g, "");
  const lines = clean(note ?? "")
    ? [clean(note).trim()]
    : clean(screen)
        .split("\n")
        .map((l) => l.replace(/\s+$/, ""))
        .filter((l) => l.trim() !== "")
        .slice(-EXCERPT_LINES);
  const text = lines.join("\n");
  return text.length > EXCERPT_CAP ? text.slice(0, EXCERPT_CAP) : text;
}
