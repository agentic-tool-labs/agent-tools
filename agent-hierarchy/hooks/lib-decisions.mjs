/**
 * agent-hierarchy — a /pipeline run's decision log: `<hier>/pipeline/<anchor id>/decisions.jsonl`,
 * one JSON object per line, each written with a single append. `msg.mjs decision add|list` writes
 * and reads the `decided` and `parked` lines; the merge record hook writes `merge` lines, which
 * `decision add` refuses. Nothing sweeps or deletes the log.
 */

import { createHash } from "node:crypto";
import { appendFileSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";

import { ID_RE, listExchanges, openExchanges, PIPELINE_ANCHOR_SLUG } from "./lib-hier.mjs";

/** Decided lines allowed per item and per run. Parked and merge lines count toward neither. */
export const DECISION_ITEM_CAP = 4;
export const DECISION_RUN_CAP = 20;

const LETTERS = ["a", "b", "c", "d"];
const WHY_USER = ["dangerous", "unsure", "cap"];
const INPUT_FIELDS = ["kind", "item", "source", "question", "options", "default", "choice", "decider", "rationale", "revert", "review", "why_user", "dangerous", "exchange"];
/** Set by the writer only; a caller supplying one is refused. */
const WRITER_FIELDS = ["id", "time", "run", "decision", "qkey"];

export function decisionLogPath(dir, runId) {
  return join(dir, "pipeline", runId, "decisions.jsonl");
}

/** The live run: the one open `pipeline-run-anchor` exchange of `team` in `dir`, as `{ id }`, or `{ error }` for none or several. */
export function openRunAnchor(dir, team) {
  const anchors = openExchanges(dir, team).filter((e) => e.slug === PIPELINE_ANCHOR_SLUG);
  if (anchors.length === 1) return { id: anchors[0].id };
  return {
    error: anchors.length
      ? `${anchors.length} open ${PIPELINE_ANCHOR_SLUG} exchanges for this team (${anchors.map((a) => a.id).join(", ")}) — exactly one is required`
      : `no open ${PIPELINE_ANCHOR_SLUG} exchange for this team — no pipeline run is live`,
  };
}

/** Whether `runId` names a run in `dir`: a run-anchor exchange with that id, open or closed, or an existing log. */
export function knownRun(dir, runId) {
  if (typeof runId !== "string" || !ID_RE.test(runId)) return false;
  return existsSync(decisionLogPath(dir, runId)) || listExchanges(dir).some((e) => e.id === runId && e.slug === PIPELINE_ANCHOR_SLUG);
}

/** Every line of the log that parses to a JSON object, in file order, and how many lines didn't (a torn last line after a crash). */
export function readDecisions(path) {
  if (!existsSync(path)) return { decisions: [], skipped: 0 };
  const decisions = [];
  let skipped = 0;
  for (const line of readFileSync(path, "utf8").split("\n")) {
    if (!line.trim()) continue;
    try {
      const value = JSON.parse(line);
      if (value && typeof value === "object" && !Array.isArray(value)) decisions.push(value);
      else skipped++;
    } catch {
      skipped++;
    }
  }
  return { decisions, skipped };
}

const isDecided = (d) => d.kind === "decided";
const isParked = (d) => d.kind === "parked";

/** `{ decided, flagged, parked, by_item: { <item>: { decided, parked } }, skipped, line }`. */
export function decisionSummary(decisions, skipped) {
  const byItem = {};
  let decided = 0;
  let flagged = 0;
  let parked = 0;
  for (const d of decisions) {
    if (!isDecided(d) && !isParked(d)) continue;
    const item = (byItem[d.item] ||= { decided: 0, parked: 0 });
    if (isDecided(d)) {
      decided++;
      item.decided++;
      if (d.review === true) flagged++;
    } else {
      parked++;
      item.parked++;
    }
  }
  return { decided, flagged, parked, by_item: byItem, skipped, line: `decisions: ${decided} decided (${flagged} flagged), ${parked} waiting for you` };
}

/** First 12 hex of sha256(`<item>\n<question>`), the question trimmed, lowercased and its whitespace runs collapsed, so a near-exact repeat keys the same. */
export function questionKey(item, question) {
  const normalized = question.trim().toLowerCase().replace(/\s+/g, " ");
  return createHash("sha256").update(`${item}\n${normalized}`).digest("hex").slice(0, 12);
}

const nonEmpty = (v) => typeof v === "string" && v.trim() !== "";
const letterWithin = (v, options) => typeof v === "string" && LETTERS.indexOf(v) !== -1 && LETTERS.indexOf(v) < options.length;
const isOther = (v) => typeof v === "string" && /^other: \S/.test(v);

/** Why `input` can't be logged beside `existing`, as `{ reason, detail }` (`reason`: `invalid`, `parked-before` or `cap`), or null. */
function refusal(input, existing) {
  const invalid = (detail) => ({ reason: "invalid", detail });
  if (!input || typeof input !== "object" || Array.isArray(input)) return invalid("the input must be one JSON object");
  if (input.kind === "merge") return invalid("kind merge is written only by the merge record hook");
  const owned = Object.keys(input).filter((k) => WRITER_FIELDS.includes(k));
  if (owned.length) return invalid(`writer-owned field(s) supplied: ${owned.join(", ")} — the writer sets them`);
  const unknown = Object.keys(input).filter((k) => !INPUT_FIELDS.includes(k));
  if (unknown.length) return invalid(`unknown field(s): ${unknown.join(", ")}`);
  const missing = INPUT_FIELDS.filter((k) => !(k in input));
  if (missing.length) return invalid(`missing field(s): ${missing.join(", ")}`);
  const { kind, options, decider } = input;
  if (kind !== "decided" && kind !== "parked") return invalid("kind must be decided or parked");
  for (const k of ["item", "source", "question"]) if (!nonEmpty(input[k])) return invalid(`${k} must be a non-empty string`);
  if (!Array.isArray(options) || options.length < 2 || options.length > 4 || !options.every(nonEmpty)) return invalid("options must be 2 to 4 non-empty strings");
  if (input.default !== null && !letterWithin(input.default, options)) return invalid("default must be a letter within options, or null");
  if (input.choice !== null && typeof input.choice !== "string") return invalid("choice must be a string or null");
  const deciderOk =
    decider && typeof decider === "object" && !Array.isArray(decider) && nonEmpty(decider.role) &&
    (decider.name === null || typeof decider.name === "string") && (decider.model === null || typeof decider.model === "string");
  if (!(deciderOk || (decider === null && kind === "parked"))) return invalid("decider must be { role, name, model } (null only on a parked line)");
  for (const k of ["rationale", "revert"]) if (typeof input[k] !== "string") return invalid(`${k} must be a string`);
  for (const k of ["review", "dangerous"]) if (typeof input[k] !== "boolean") return invalid(`${k} must be a boolean`);
  if (input.why_user !== null && !WHY_USER.includes(input.why_user)) return invalid(`why_user must be ${WHY_USER.join(", ")} or null`);
  if (input.exchange !== null && !nonEmpty(input.exchange)) return invalid("exchange must be a request id or null");

  if (kind === "decided") {
    if (input.dangerous) return invalid("a decided line can't be dangerous — a dangerous question goes to the user");
    if (decider.role === "user") return invalid("a decided line's decider can't be the user — the user's answers are not logged as decided");
    if (input.why_user !== null) return invalid("a decided line has no why_user");
    if (!letterWithin(input.choice, options) && !isOther(input.choice)) return invalid("choice must be a letter within options, or other: <text>");
  } else {
    if (input.choice !== null) return invalid("a parked line has no choice");
    if (input.why_user === null) return invalid("a parked line needs why_user");
  }
  if (input.dangerous && input.why_user !== "dangerous") return invalid("dangerous: true needs why_user dangerous");

  if (kind === "decided") {
    const qkey = questionKey(input.item, input.question);
    if (existing.some((d) => isParked(d) && d.qkey === qkey)) return { reason: "parked-before", detail: `question ${qkey} was parked earlier in this run — never re-ask` };
    const decided = existing.filter(isDecided);
    const forItem = decided.filter((d) => d.item === input.item).length;
    if (forItem >= DECISION_ITEM_CAP) return { reason: "cap", detail: `item ${input.item} already has ${forItem} decided (cap ${DECISION_ITEM_CAP})` };
    if (decided.length >= DECISION_RUN_CAP) return { reason: "cap", detail: `the run already has ${decided.length} decided (cap ${DECISION_RUN_CAP})` };
  }
  return null;
}

/**
 * Validates `input` against the run's log at `path` and appends it as one line with `id` (d<k>,
 * k = decided and parked lines so far + 1), `time`, `run` and `qkey` added, and a decided line's
 * chosen text as `decision`. Returns `{ refused: { reason, detail } }` having written nothing, or
 * `{ id, path, counts }`.
 */
export function appendDecision(path, runId, input) {
  const { decisions } = readDecisions(path);
  const why = refusal(input, decisions);
  if (why) return { refused: why };
  const k = decisions.filter((d) => isDecided(d) || isParked(d)).length + 1;
  const decision = input.kind === "decided" ? (isOther(input.choice) ? input.choice : input.options[LETTERS.indexOf(input.choice)]) : null;
  const line = { id: `d${k}`, time: new Date().toISOString(), run: runId };
  for (const field of INPUT_FIELDS) {
    line[field] = input[field];
    if (field === "question") line.qkey = questionKey(input.item, input.question);
    if (field === "choice") line.decision = decision;
  }
  mkdirSync(dirname(path), { recursive: true });
  appendFileSync(path, JSON.stringify(line) + "\n");
  const after = decisionSummary([...decisions, line], 0);
  const item = after.by_item[input.item];
  return { id: line.id, path, counts: { run: { decided: after.decided, parked: after.parked }, item: { decided: item.decided, parked: item.parked } } };
}
