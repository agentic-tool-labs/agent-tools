#!/usr/bin/env node
// agent-hierarchy — PreToolUse merge rule for GitHub MCP tools while a /pipeline run is open: the
// MCP counterpart of the push guard's merge rules. A tool from a server whose name contains
// "github" is denied PG-MCP-MERGE when its name contains "merge", when any string in its input is
// APPROVE, or when it is update_pull_request setting draft to false. Everything else passes with no
// output, and tools from other servers exit at once. On a merge-type call a failure, or liveness it
// can't determine, denies PG-MERGE-ERROR.

import { logHookError, MCP_TOOL_PREFIX, readHookInput } from "./lib-config.mjs";

function deny(rule, tool, detail) {
  const reason =
    `ah-push-guard:${rule} ${tool}: ${detail}. Do not retry, rephrase, split, or route this call through another tool, command, script, or agent. ` +
    `In a /pipeline run, follow the autonomous-pipeline skill's handling for ${rule}. ` +
    "Otherwise, tell the user that a person can do it themselves if it is intended.";
  process.stdout.write(
    JSON.stringify({
      systemMessage: `ah push-guard stopped a GitHub tool call (${tool}) while a /pipeline run is open. Nothing was sent.`,
      hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: reason },
    }),
  );
  process.exit(0);
}

/** Any string anywhere in `value` equal to `want`, in any case. */
const hasString = (value, want) =>
  typeof value === "string"
    ? value.toLowerCase() === want
    : value && typeof value === "object"
      ? Object.values(value).some((v) => hasString(v, want))
      : false;

const input = await readHookInput();
const name = typeof input.tool_name === "string" ? input.tool_name : "";
if (!name.startsWith(MCP_TOOL_PREFIX)) process.exit(0);
const rest = name.slice(MCP_TOOL_PREFIX.length);
const sep = rest.indexOf("__");
if (sep <= 0 || !/github/i.test(rest.slice(0, sep))) process.exit(0);
const tool = rest.slice(sep + 2);
const args = input.tool_input && typeof input.tool_input === "object" ? input.tool_input : {};
const cwd = typeof input.cwd === "string" && input.cwd ? input.cwd : process.cwd();

/** Why this call merges, approves or readies a PR, or null. */
function mergeWhy() {
  if (/merge/i.test(tool)) return "a tool that merges";
  if (hasString(args, "approve")) return "an approving review";
  if (tool === "update_pull_request" && args.draft === false) return "marking the PR ready (draft false)";
  return null;
}

// A merge-type call for the error path: it merges, approves, or may ready a PR.
const mergeType = /merge/i.test(tool) || tool === "update_pull_request" || hasString(args, "approve");

try {
  const { runLiveness } = await import("./lib-decisions.mjs");
  const state = runLiveness(cwd);
  if (state === "not") process.exit(0);
  if (state === "unknown") throw new Error("whether a /pipeline run is live can't be determined");
  const why = mergeWhy();
  if (why) deny("PG-MCP-MERGE", tool, `${why}, while a /pipeline run is open`);
} catch (err) {
  if (mergeType) deny("PG-MERGE-ERROR", tool, `the merge rules failed: ${err && err.message ? err.message : String(err)}`);
  logHookError("pretooluse-mcp-guard.mjs", err);
}
process.exit(0);
