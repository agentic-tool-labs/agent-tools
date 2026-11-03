#!/usr/bin/env node
/**
 * task-gopher — the full directive and its gates, run by the mod (register.ts).
 *
 * Answers with the full delegation directive when the plugin is ON, so a fresh,
 * resumed, or post-compaction session starts already knowing to dispatch
 * tool-heavy work to task-gopher. MAIN SESSION ONLY: prompt.submit never fires for
 * subagents and the mod's session.append hook skips them — they receive the
 * directive via the relay gate in
 * pretooluse-nudge.mjs instead. The directive's own tier gate means only
 * Sonnet-tier-or-higher agents act on it. Silent when OFF, and silent inside
 * either gopher.
 */

import { DIRECTIVE, isEnabled, isGopherAgent, isHierarchyRoleAgent, readHookInput } from "./directive.mjs";

const input = await readHookInput();

if (isEnabled() && !isGopherAgent(input) && !isHierarchyRoleAgent(input)) {
  process.stdout.write(
    JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "SessionStart",
        additionalContext: DIRECTIVE,
      },
    })
  );
}
