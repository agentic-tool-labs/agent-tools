#!/usr/bin/env node
/**
 * agent-hierarchy — PreToolUse allow hook for the ah CLIs (spec 0048 §2.2).
 *
 * Every ah operation is now a Bash call to `hooks/roster.mjs` or `hooks/msg.mjs` (the MCP server
 * is gone, spec 0048 §3). Without this hook each of those calls would raise a Bash permission
 * prompt, so the hook grants prompt-free execution of exactly those two scripts — the ones this
 * plugin itself ships — with their arguments restricted to the `lib-ah-cli.mjs` grammar: one
 * simple command, no shell metacharacters outside single quotes, hence no compound command,
 * redirection, substitution or expansion riding along. The grammar is the security boundary:
 * a partial or uncertain parse returns null and this hook then prints nothing, which leaves the
 * user's ordinary permission flow untouched. It never allows anything it did not fully parse.
 *
 * Close commands (`roster.mjs dismiss|disband … --close`) are deliberately NOT allowed here: the
 * hook stays silent so pretooluse-disband-close-gate.mjs's always-`ask` stands alone. Hook-vs-hook
 * precedence for one hook's `allow` against another's `ask` is undocumented; staying silent avoids
 * depending on it. The remaining state-changing verbs (`untrack --commit`, `reap --commit`,
 * `create --commit`, `remove`) are bookkeeping on ah's own files and were auto-allowed as MCP
 * calls too; the roster skill gate's `deny` still outranks this `allow`.
 *
 * Path rule and the sibling-directory arm: see `scriptUnderRoot` in lib-ah-cli.mjs. A copy of the
 * script anywhere else — /tmp, a user checkout while the installed root is the plugin cache — is
 * not recognised and prompts normally.
 */

import { dirname } from "node:path";
import { fileURLToPath } from "node:url";

import { isSubagent, logHookError, readHookInput } from "./lib-config.mjs";
import { isCloseCommand, isTrustCommit, parseAhCommand, scriptUnderRoot } from "./lib-ah-cli.mjs";

const OWN_ROOT = dirname(dirname(fileURLToPath(import.meta.url)));

/**
 * A `roster.mjs deliver <name> --req <path>` that is not `--wait-only` sends a brief to a pane
 * member: record it as this session's dispatch, the same row a SendMessage dispatch gets, so the
 * Orchestrator's Stop-hook check-ins cover pane work. Written before the command runs; a deliver
 * that then refuses leaves an open exchange that is still owed either way. The libs load only for
 * a deliver, since this hook runs on every Bash call.
 */
async function recordDeliver(input, parsed) {
  if (isSubagent(input) || parsed.script !== "roster" || parsed.verb !== "deliver") return;
  if (typeof parsed.flags.req !== "string" || parsed.flags["wait-only"] === true) return;
  const sessionId = typeof input.session_id === "string" ? input.session_id : "";
  const { parseMsgFilename } = await import("./lib-hier.mjs");
  const { appendDispatchRecord } = await import("./lib-peer.mjs");
  const meta = parseMsgFilename(parsed.flags.req);
  if (sessionId && meta && meta.type === "request") appendDispatchRecord(sessionId, meta.id, meta.to);
}

try {
  const input = await readHookInput();
  if (input.tool_name !== "Bash") process.exit(0);
  const toolInput = input.tool_input && typeof input.tool_input === "object" ? input.tool_input : {};
  const parsed = parseAhCommand(toolInput.command);
  if (!parsed) process.exit(0);
  if (isCloseCommand(parsed)) process.exit(0);
  // A role-pack trust commit gets the roster skill gate's `ask` (or `deny`) alone.
  if (isTrustCommit(parsed)) process.exit(0);
  if (!scriptUnderRoot(parsed.scriptPath, OWN_ROOT)) process.exit(0);

  try {
    await recordDeliver(input, parsed);
  } catch (err) {
    logHookError("pretooluse-ah-cli.mjs", err);
  }

  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "allow",
        permissionDecisionReason: `ah: plugin-shipped CLI — ${parsed.script}.mjs ${parsed.verb || "(no verb)"}`,
      },
    })
  );
} catch (err) {
  logHookError("pretooluse-ah-cli.mjs", err);
  process.exit(0);
}
