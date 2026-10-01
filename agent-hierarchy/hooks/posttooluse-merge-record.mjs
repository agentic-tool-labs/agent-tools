#!/usr/bin/env node
// agent-hierarchy — PostToolUse (Bash): when the pinned /pipeline merge command ran, appends a `merge`
// line to the open run's decision log. The push guard lets that command through only after the user
// approved its permission prompt, so a declined prompt runs nothing and records nothing. The record
// says the command ran; whether GitHub merged is read at report time.

import { logHookError, readHookInput } from "./lib-config.mjs";

async function main() {
  const input = await readHookInput();
  const command = input.tool_input && typeof input.tool_input.command === "string" ? input.tool_input.command : "";
  if (input.tool_name !== "Bash" || !command.includes("gh")) return;
  const { appendMergeRecord, decisionLogPath, liveRun, parseMergeForm } = await import("./lib-decisions.mjs");
  const form = parseMergeForm(command);
  if (!form) return;
  const run = liveRun(typeof input.cwd === "string" && input.cwd ? input.cwd : process.cwd());
  if (run) appendMergeRecord(decisionLogPath(run.dir, run.id), form);
}

try {
  await main();
} catch (err) {
  logHookError("posttooluse-merge-record.mjs", err);
}
process.exit(0);
