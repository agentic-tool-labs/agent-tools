#!/usr/bin/env node
// Checks the directive texts and the category table of a directive module.
// Usage: node directive-check.mjs [path-to-directive.mjs]
// Prints one "FAIL <check> <detail>" line per violation and exits 1 if there is any. The path argument lets a
// deliberately broken copy be fed in, which is how the suite proves every check can fail.

import { pathToFileURL } from "node:url";
import { resolve, dirname } from "node:path";

const target = process.argv[2] || resolve(dirname(new URL(import.meta.url).pathname), "../hooks/directive.mjs");
const m = await import(pathToFileURL(target).href);

const fails = [];
const fail = (check, detail) => fails.push(`FAIL ${check} ${detail}`);

const WORDS_MAX = 250;
const TICK_WORDS_MAX = 45;
const REASON_WORDS_MAX = 60;
const ALL_IDS = ["read", "search", "find", "git-read", "test", "build", "view", "script"];
const TASK = "task-gopher:task-gopher";
const SMART = "task-gopher:smart-gopher";

const whitespaceWords = (s) => s.split(/\s+/).filter(Boolean);
// A bare "->", "=" or "+" is punctuation, not a word.
const words = (s) => whitespaceWords(s).filter((w) => /[A-Za-z0-9]/.test(w));
const bareSmart = (s) => /(?<!task-gopher:)smart-gopher/.test(s);

const { DIRECTIVE, TICK, SENTINEL, EXCEPTION_LINE, ESCALATED_LEAD, CATEGORIES, checkpointReason } = m;

for (const [name, v] of Object.entries({ DIRECTIVE, TICK, SENTINEL, EXCEPTION_LINE, ESCALATED_LEAD })) {
  if (typeof v !== "string" || !v) fail("export", `${name} is missing`);
}
if (!Array.isArray(CATEGORIES) || typeof checkpointReason !== "function") fail("export", "CATEGORIES or checkpointReason missing");
if (fails.length) {
  console.log(fails.join("\n"));
  process.exit(1);
}

// the directive
if (words(DIRECTIVE).length > WORDS_MAX) fail("directive-words", `${words(DIRECTIVE).length} words, cap ${WORDS_MAX}`);
if (!DIRECTIVE.startsWith(`${SENTINEL} PURPOSE:`)) fail("directive-purpose-first", "does not open with the sentinel and PURPOSE:");
for (const token of ["PICK THE RUNNER", "2 direct retrieval calls", TASK, SMART]) {
  if (!DIRECTIVE.includes(token)) fail("directive-token", `missing ${JSON.stringify(token)}`);
}
if (bareSmart(DIRECTIVE)) fail("directive-bare-name", "smart-gopher appears without its plugin prefix");
if (!/\bWHERE \(.*\)\. HOW \(.*\)\. BACK \(.*\)\./.test(DIRECTIVE)) fail("directive-order-template", "WHERE / HOW / BACK line missing");
if (!new RegExp(`-> ${TASK} \\(Haiku\\)\\. E\\.g\\. "[^"]+"`).test(DIRECTIVE)) fail("selector", `no task-gopher bullet with an example`);
if (!new RegExp(`-> ${SMART} \\(Sonnet\\)\\. E\\.g\\. "[^"]+"`).test(DIRECTIVE)) fail("selector", `no smart-gopher bullet with an example`);

// the tick
if (whitespaceWords(TICK).length > TICK_WORDS_MAX) fail("tick-words", `${whitespaceWords(TICK).length} words, cap ${TICK_WORDS_MAX}`);
for (const token of [SENTINEL, "2 direct retrieval calls", TASK, SMART]) {
  if (!TICK.includes(token)) fail("tick-token", `missing ${JSON.stringify(token)}`);
}
if (bareSmart(TICK)) fail("tick-bare-name", "smart-gopher appears without its plugin prefix");

// the category table against the directive's trigger list and the reasons
const ids = CATEGORIES.map((c) => c.id);
for (const id of ALL_IDS) if (!ids.includes(id)) fail("table-missing-category", id);
for (const id of ids) if (!ALL_IDS.includes(id)) fail("table-unknown-category", `${id} is in the table but not in the gate's category list`);
if (new Set(ids).size !== ids.length) fail("table-duplicate", ids.join(","));
for (const c of CATEGORIES) {
  if (!c.words || !DIRECTIVE.includes(c.words)) fail("directive-trigger-list", `${c.id}: ${JSON.stringify(c.words)} is not in the directive`);
  if (!c.deny) fail("table-deny-text", `${c.id} has no deny text`);
  if (!c.runner || !c.deny.includes(c.runner)) fail("deny-runner", `${c.id}: the text does not name ${c.runner}`);
  if (!c.deny.includes(TASK) && !c.deny.includes(SMART)) fail("deny-names-no-gopher", c.id);
  if (bareSmart(c.deny)) fail("deny-bare-name", c.id);
  if (words(c.deny).length > REASON_WORDS_MAX) fail("deny-words", `${c.id}: ${words(c.deny).length} words, cap ${REASON_WORDS_MAX}`);
  if (["read", "search", "find", "git-read"].includes(c.id) && !(c.deny.includes(TASK) && c.deny.includes(SMART))) {
    fail("deny-selector", `${c.id}: must name both gophers`);
  }
  const reason = checkpointReason(c.id, false);
  if (!reason.endsWith(EXCEPTION_LINE)) fail("deny-exception-line", c.id);
  if (!reason.startsWith(c.deny)) fail("deny-text-source", `${c.id}: the reason is not the table's text`);
  if (!checkpointReason(c.id, true).startsWith(ESCALATED_LEAD)) fail("deny-escalated-lead", c.id);
}

if (fails.length) {
  console.log(fails.join("\n"));
  process.exit(1);
}
console.log(`ok: ${CATEGORIES.length} categories; directive ${words(DIRECTIVE).length} words; tick ${whitespaceWords(TICK).length} words`);
