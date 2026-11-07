#!/usr/bin/env node
'use strict';

// The Node half of hooks/register.ts, which has no Node of its own.
//   mod.js arm    stdin: the classic Stop input. Prints {ms, instructions, ...}
//                 when the mod should arm, else {}; claims the turn from arm.js.
//   mod.js fired  stdin: the plan arm printed plus {ok, reason, detail}.
//                 Records the fire in the stats log as timer.js does.

const fs = require('fs');

const config = require('./lib/config');
const state = require('./lib/state');
const transcript = require('./lib/transcript');
const prompt = require('./lib/prompt');
const stats = require('./lib/stats');
const notify = require('./lib/notify');
const { readInput } = require('./lib/hookio');

function arm(input) {
  const sessionId = input.session_id;
  if (!sessionId) return {};
  const cfg = config.resolve();
  // Keepalive types a real prompt, which the mod does not do: arm.js keeps it.
  if (!cfg.enabled || cfg.idleAction !== 'compact') {
    state.takeClaim(sessionId);
    return {};
  }
  config.ensureRoot();
  fs.writeFileSync(state.claimFile(sessionId), String(Date.now()));
  const info = input.transcript_path ? transcript.lastAssistantInfo(input.transcript_path) : null;
  const tokens = info ? info.tokens : null;
  if (tokens !== null && tokens < cfg.minTokens) return {};
  return {
    ms: cfg.idleMinutes * 60 * 1000,
    instructions: prompt.resolveFor(input.cwd || process.cwd(), cfg).text,
    sessionId,
    tokens,
    model: info ? info.model : null,
    effort: info ? info.effort : null,
  };
}

function fired(input) {
  const outcome = { at: Date.now(), ok: !!input.ok, reason: input.reason || null, detail: input.detail || null };
  stats.record(input.sessionId, outcome, {
    mode: 'compact',
    tokens: input.tokens,
    model: input.model,
    effort: input.effort,
  });
  if (!outcome.ok) notify.notify('Auto-compact failed', 'session.compact: ' + (outcome.detail || outcome.reason));
  return {};
}

readInput()
  .then((input) => {
    const verb = process.argv[2];
    const out = verb === 'arm' ? arm(input || {}) : verb === 'fired' ? fired(input || {}) : {};
    process.stdout.write(JSON.stringify(out));
    process.exit(0);
  })
  .catch(() => process.exit(0));
