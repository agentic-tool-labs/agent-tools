#!/usr/bin/env node
/**
 * agent-hierarchy — UserPromptSubmit tracker for the peer report-back contract.
 *
 * E2 (live-verified): UserPromptSubmit fires in the receiving session for a
 * SendMessage-delivered peer message, and the payload's `prompt` field carries
 * the full delivered text INCLUDING the `<cross-session-message>` wrapper —
 * there is no structured field that marks a delivery as a peer tasking, so
 * regexing `prompt` for the sentinel is the only and the correct mechanism.
 *
 * When the prompt carries a well-formed `[hierarchy-peer-brief reply-to="..."
 * task="..."]` sentinel inside its wrapper, this appends a "pending" record so
 * the Stop hook can hold the session to its report-back obligation. No
 * sentinel (the overwhelming majority of prompts) costs one failed regex test
 * and nothing else. Never blocks or alters the prompt — this hook only
 * observes and records; it exits silently either way. A brief that also
 * carries `[hierarchy-msg <request path>]` records that path as `msg` on the
 * obligation, which then resolves only against a reply carrying the matching
 * response pointer (see posttooluse-peer-resolve.mjs).
 *
 * Amendment 2 (interactive peers): a peer session doubles as an interactive
 * one, and enforcement must fire only on turns the PEER's own tasking work
 * touches, never on a turn the USER is driving. So, in addition to the brief
 * detection above, this arms a `{"type":"turn","status":"armed"}` marker
 * whenever BOTH: the prompt carries a `<cross-session-message>` wrapper at
 * all (ANY peer delivery — a brief, a ping, an unrelated peer message; this
 * check is intentionally unanchored, unlike the brief sentinel above), AND
 * the session has at least one pending obligation afterward — read via
 * `pendingFor` AFTER the append above, so it also catches an obligation this
 * very prompt just created. A typed prompt, or a session with no pending
 * obligations, arms nothing, which is what keeps state growth bounded to
 * active-obligation windows.
 *
 * No-ops for subagents (same `agent_id` discriminator as the rest of the
 * plugin) — a subagent is not a peer, and its own SessionStart injection is
 * already suppressed for the same reason.
 *
 * Team-intent nudge (spec 0042 §1.5): a prompt matching one of the
 * team-lifecycle phrases from `skills/agent-team/SKILL.md`'s frontmatter
 * `description` gets exactly one injected line naming the `ah:agent-team`
 * skill — read from that file at hook time so the phrase list has one
 * source of truth (the test asserts the two match). No new prompt, no
 * instruction, no restating the protocol; a prompt with no match injects
 * nothing.
 */

import { cliRootLine, isSubagent, logHookError, readHookInput, resolveConfig, resolveHierarchyRole } from "./lib-config.mjs";
import { dirname } from "node:path";

import { extractMsgToken, listExchanges, parseMsgFilename, readMsgFile, responseLanded } from "./lib-hier.mjs";
import { thresholdFor } from "./lib-liveness.mjs";
import { matchedTeamIntentPhrase } from "./lib-team-intent.mjs";
import { appendPeerRecord, appendReportRecord, appendTurnMarker, dispatchRecordsFor, extractPendingRecord, latestDispatchRows, parseWrapper, pendingFor, readPeerRecords, reportShown, unconsumedWatchEvents } from "./lib-peer.mjs";

const IDLE_NOTICE_RE = /^\s*\[Cross-session idle notice\]\s+"([^"]+)"([\s\S]*)$/;

const hhmm = (ms) => {
  const d = new Date(ms);
  return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
};

/**
 * For an idle notice naming peer X, the lines to inject: one per request this session dispatched
 * to X and has not yet been shown the report for. A notice that repeats the last one for X (a
 * re-subscribe to a peer that is still idle fires at once with the same text) injects nothing, and
 * one whose wording is not recognised injects a single check-X line. It never asks for a status
 * query or a re-subscribe; the dispatch watcher owns timed follow-up.
 */
function idleNoticeLines(sessionId, prompt) {
  const m = prompt.match(IDLE_NOTICE_RE);
  if (!m) return [];
  const name = m[1];
  const body = m[2];
  const key = `${(body.match(/finished a turn at (\d{1,2}:\d{2})/) || [])[1] || ""}|${(body.match(/«([^»]*)»/) || [])[1] || ""}|${/is idle now/.test(body) ? "" : body.slice(0, 200)}`;
  const last = readPeerRecords().filter((r) => r && r.type === "idle-seen" && r.session_id === sessionId && r.name === name).pop();
  if (last && last.key === key) return [];
  appendPeerRecord({ type: "idle-seen", session_id: sessionId, name, key, ts: new Date().toISOString() });
  if (!/is idle now/.test(body)) {
    const open = latestDispatchRows(sessionId).filter((r) => r.path && r.to_addr === name && !reportShown(sessionId, r.request_id)).map((r) => r.request_id);
    return [`ah: idle notice about ${name} not recognised: «${body.trim().slice(0, 200)}». Call ListAgents. If ${name} is gone and has open requests (${open.join(", ") || "none"}), tell the user. If ${name} is alive, there is nothing to do; the dispatch watcher keeps time.`];
  }
  const now = Date.now();
  const lines = [];
  for (const row of latestDispatchRows(sessionId)) {
    if (!row.path || row.to_addr !== name || reportShown(sessionId, row.request_id)) continue;
    const e = listExchanges(dirname(dirname(row.path))).find((x) => x.id === row.request_id);
    if (!e) continue;
    if (!e.open) {
      if (!responseLanded(e.response.path, now)) continue;
      lines.push(`${name} is idle; its report for ${e.id} landed but was never sent to you: ${e.response.path}. Read it now.`);
      appendReportRecord("surfaced", sessionId, e.id);
    } else {
      const fm = (readMsgFile(e.request.path) || {}).fm || {};
      const created = Date.parse(fm.created);
      const due = Number.isFinite(created) ? ` checks in at ${hhmm(created + thresholdFor(fm.eta) * 1000)}` : " checks in";
      lines.push(`${name} is idle with no report for ${e.id} yet. It may be waiting on its own background work. Nothing to do now; the dispatch watcher${due}.`);
    }
  }
  return lines;
}

try {
  const input = await readHookInput();
  const parts = [];
  if (!isSubagent(input)) {
    const sessionId = typeof input.session_id === "string" ? input.session_id : "";
    const prompt = typeof input.prompt === "string" ? input.prompt : "";

    if (sessionId && prompt) {
      // The persisted role is exact here: subagents were excluded above, so the caller is the session itself.
      const { role } = resolveHierarchyRole(input);
      const rec = extractPendingRecord(prompt, role);
      if (rec) {
        const msg = extractMsgToken(prompt);
        appendPeerRecord({
          session_id: sessionId,
          from: rec.from,
          from_name: rec.from_name,
          reply_to: rec.reply_to,
          task: rec.task,
          armed_by: rec.armed_by,
          ...(msg ? { msg } : {}),
          ts: new Date().toISOString(),
          status: "pending",
          nudges: 0,
        });
      }

      // A wrapped delivery carrying the response to one of this session's dispatches means the
      // report reached it, so the Stop hook does not announce it as landed-but-unread.
      const wrapper = parseWrapper(prompt);
      // A peer that writes to us restarts the watcher's schedule for it; an idle notice is not
      // wrapped, so it never counts as hearing from the peer.
      if (wrapper && wrapper.fromName && latestDispatchRows(sessionId).some((r) => r.to_addr === wrapper.fromName)) {
        appendPeerRecord({ type: "heard", session_id: sessionId, from: wrapper.fromName, ts: new Date().toISOString() });
      }
      if (wrapper) {
        const token = extractMsgToken(prompt);
        const meta = token && token.endsWith("--response.md") ? parseMsgFilename(token) : null;
        if (meta && dispatchRecordsFor(sessionId).some((r) => r.request_id === meta.id)) appendReportRecord("seen", sessionId, meta.id);
      }

      if (!role || role === "orchestrator") {
        const idle = idleNoticeLines(sessionId, prompt);
        if (idle.length) parts.push(idle.join("\n"));
        // The watcher's findings come from the store, never from a path named in the prompt.
        const found = unconsumedWatchEvents(sessionId);
        if (found.length) {
          parts.push(found.map((ev) => ev.text).join("\n"));
          appendPeerRecord({ type: "watch-consumed", session_id: sessionId, ts: found[found.length - 1].ts });
        }
      }

      // The marker says whether the turn now starting is peer-driven, so this
      // hook owns BOTH edges: a wrapped delivery arms, a typed prompt disarms.
      // The Stop hook used to disarm as a side effect of blocking, which made
      // the marker a one-shot enforcement token instead of a description of
      // the turn; it no longer does, so a typed prompt that left the marker
      // armed would charge the user's own turns against the nudge budget.
      // Still gated on having a pending obligation, which is what keeps state
      // growth bounded to active-obligation windows.
      if (pendingFor(sessionId).length > 0) {
        appendTurnMarker(sessionId, parseWrapper(prompt) ? "armed" : "disarmed");
      }
    }

    if (prompt && matchedTeamIntentPhrase(prompt)) {
      parts.push('ah: standing up, reshaping, or tearing down a live Team goes through the `ah:agent-team` skill.');
    }

    // `/reload-plugins` fires no SessionStart, so a session that updates mid-flight never hears the
    // root line that hook injected — and the CLI paths are the whole interface since 0.73.0. Every
    // prompt re-states it, on the same classification SessionStart uses.
    const resolved = resolveConfig(typeof input.cwd === "string" ? input.cwd : process.cwd());
    if (!resolved.configured || resolved.enabled) parts.push(cliRootLine());
  }
  if (parts.length) {
    process.stdout.write(
      JSON.stringify({
        hookSpecificOutput: {
          hookEventName: "UserPromptSubmit",
          additionalContext: parts.join("\n\n"),
        },
      })
    );
  }
} catch (err) {
  logHookError("userpromptsubmit-peer-tracking.mjs", err);
  // fail open: a tracking failure must never affect the prompt it observed
}
process.exit(0);
