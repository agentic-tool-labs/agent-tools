#!/usr/bin/env node
/**
 * agent-hierarchy — PreToolUse gate on Write, Edit and MultiEdit for the Reviewer.
 *
 * The Reviewer files its report by editing the response file that `msg.mjs new --type response`
 * created, so no Bash heredoc is needed. This gate is what keeps that from being a general write
 * permission: for a session that is positively the Reviewer (`direct`), a write is allowed only on
 * an existing `*--response.md` in a hierarchy msgs dir whose frontmatter says `type: response` and
 * `from: reviewer` and stays byte-identical after the write. Anything else is denied, with the
 * command that creates the file. For every other role, and for no role at all, it says nothing.
 *
 * Unlike the other gates it fails closed: an error while judging a Reviewer's write denies it,
 * because the alternative is a Reviewer that can write anywhere.
 */

import { existsSync, readFileSync, realpathSync, statSync } from "node:fs";
import { basename, dirname, isAbsolute, resolve } from "node:path";

import { fillCommand, logHookError, readHookInput, resolveHierarchyRole, responseCommand } from "./lib-config.mjs";
import { hierarchyDir } from "./lib-hier.mjs";
import { msgsDirsOf } from "./lib-roster.mjs";

const TOOLS = new Set(["Write", "Edit", "MultiEdit"]);

function decide(decision, reason) {
  if (decision) {
    process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: decision, permissionDecisionReason: reason } }));
  }
  process.exit(0);
}

const deny = (why) =>
  decide(
    "deny",
    `ah: the Reviewer may write only its own response file${why ? ` (${why})` : ""}. Create it first with \`${responseCommand()}\`, then file the report with one \`${fillCommand()}\`; Write and Edit on that file work as a fallback while its frontmatter stays as written.`
  );

/** The leading `---` frontmatter block of `text`, closing line included, else null. */
function frontmatter(text) {
  if (!text.startsWith("---\n")) return null;
  const end = text.indexOf("\n---\n", 3);
  return end < 0 ? null : text.slice(0, end + 5);
}

/** `text` after the edits of an Edit or MultiEdit call, or null when an edit does not apply (the tool itself will then fail and write nothing). */
function applyEdits(text, toolName, toolInput) {
  const edits = toolName === "MultiEdit" ? (Array.isArray(toolInput.edits) ? toolInput.edits : []) : [toolInput];
  let out = text;
  for (const e of edits) {
    if (!e || typeof e.old_string !== "string" || typeof e.new_string !== "string") return null;
    if (!out.includes(e.old_string)) return null;
    out = e.replace_all === true ? out.split(e.old_string).join(e.new_string) : out.replace(e.old_string, () => e.new_string);
  }
  return out;
}

let reviewer = false;
try {
  const input = await readHookInput();
  if (!TOOLS.has(input.tool_name)) decide(null);
  const { role, direct } = resolveHierarchyRole(input);
  if (!direct || role !== "reviewer") decide(null);
  reviewer = true;

  const toolInput = input.tool_input && typeof input.tool_input === "object" ? input.tool_input : {};
  const cwd = typeof input.cwd === "string" && input.cwd ? input.cwd : process.cwd();
  const target = toolInput.file_path;
  if (typeof target !== "string" || !target) deny("no file path");
  if (target.split("/").includes("..")) deny("the path climbs directories");
  const path = isAbsolute(target) ? target : resolve(cwd, target);
  if (!basename(path).endsWith("--response.md")) deny("not a response file");
  if (!existsSync(path)) deny("that response file does not exist yet");
  const real = realpathSync(path);
  if (!statSync(real).isFile()) deny("not a file");
  if (!msgsDirsOf(hierarchyDir(cwd)).includes(dirname(real))) deny("outside the hierarchy msgs directory");

  const current = readFileSync(real, "utf8");
  const head = frontmatter(current);
  if (head === null || !/^type: response$/m.test(head) || !/^from: reviewer$/m.test(head)) deny("it is not a response from the reviewer");

  let next;
  if (input.tool_name === "Write") next = typeof toolInput.content === "string" ? toolInput.content : null;
  else next = applyEdits(current, input.tool_name, toolInput);
  // An edit that does not apply writes nothing: the tool reports its own error.
  if (next === null) decide(input.tool_name === "Write" ? "deny" : null, input.tool_name === "Write" ? "ah: the Reviewer's Write has no content." : undefined);
  if (frontmatter(next) !== head) deny("the frontmatter must stay as `msg.mjs new` wrote it");
  decide(null);
} catch (err) {
  logHookError("pretooluse-reviewer-write-gate.mjs", err);
  if (reviewer) deny("the gate could not judge this write");
  decide(null);
}
