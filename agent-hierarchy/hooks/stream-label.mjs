#!/usr/bin/env node
// agent-hierarchy — keeps a stream's Herdr tab label current from inside each stream member's own
// session: UserPromptSubmit renders it as that member working, Stop as idle, and a permission
// prompt (Notification, matcher permission_prompt) as blocked. The render itself runs through
// `roster.mjs stream-label`, so roster.mjs stays the one place herdr is executed.
//
// Inert — two env reads and out — in every session that is not a roster-spawned herdr peer, and
// for subagents. Never writes stdout, never blocks, always exits 0.
//
// ponytail: × stays until this peer's next Stop; clearing it on permission grant needs a PostToolUse tick.
// ponytail: a Stop that stop-peer-nudge then blocks renders ○ while the peer carries on working.
// ponytail: two members stopping at once can race to a stale glyph.
// Each of these is corrected by the next tick or by `stream-status`.

import { execFileSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { basename, dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { isSubagent, logHookError, readHookInput } from "./lib-config.mjs";

try {
  const pane = process.env.HERDR_PANE_ID;
  const teamFile = process.env.AH_TEAM_FILE;
  if (pane && teamFile) {
    // Loaded only past the early exit: a static import would add lib-hier's load time to every session.
    const { SELF_STATE } = await import("./lib-hier.mjs");
    const input = await readHookInput();
    const state = input && SELF_STATE[input.hook_event_name];
    if (state && !isSubagent(input)) {
      const team = JSON.parse(readFileSync(teamFile, "utf8"));
      const me = team.members.find((m) => m && m.transport_id === pane);
      const stream = me && me.stream && team.streams && team.streams[me.stream];
      if (stream && stream.state === "open") {
        const args = [join(dirname(fileURLToPath(import.meta.url)), "roster.mjs"), "stream-label", me.stream, "--self-pane", pane, "--self-state", state, "--cwd", team.expected_root];
        // A named team is `teams/<name>.json`; the legacy `team.json` is the default and takes no --team.
        if (basename(dirname(teamFile)) === "teams") args.push("--team", basename(teamFile, ".json"));
        execFileSync(process.execPath, args, { timeout: 5000, stdio: "ignore" });
      }
    }
  }
} catch (err) {
  logHookError("stream-label.mjs", err);
}
process.exit(0);
