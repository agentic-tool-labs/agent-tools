#!/usr/bin/env node
'use strict';

// The Node half of hooks/register.ts, which has no Node of its own.
//   mod.js arm    stdin: {session_id, cwd, root, tokens}. Prints {ms, instructions, ...}
//                 when the mod should arm, else {}; claims the turn from arm.js.
//   mod.js check  stdin: the plan. Prints {why} when the fire must wait, else {}.
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
  // The context fill comes from $.session.usage(); the transcript, when found, adds the stats and the fire-time guard.
  const transcriptPath = input.transcript_path || transcript.locate(sessionId, [input.root, input.cwd]);
  const info = transcriptPath ? transcript.lastAssistantInfo(transcriptPath) : null;
  const tokens = typeof input.tokens === 'number' ? input.tokens : info ? info.tokens : null;
  // Below the floor arm.js declines too, so nothing is claimed.
  if (tokens !== null && tokens < cfg.minTokens) return {};
  const plan = {
    ms: cfg.idleMinutes * 60 * 1000,
    instructions: prompt.resolveFor(input.cwd || process.cwd(), cfg).text,
    sessionId,
    transcriptPath: transcriptPath || null,
    tokens,
    model: info ? info.model : null,
    effort: info ? info.effort : null,
  };
  // Last, once the plan is whole: a throw above leaves arm.js to inject.
  config.ensureRoot();
  fs.writeFileSync(state.claimFile(sessionId), String(Date.now()));
  return plan;
}

// The fire-time guard timer.js uses. Prints {why} when the fire must wait; the
// first wait of an arm logs the activity-detected row, as timer.js's defer does.
function check(input) {
  const why = input.transcriptPath ? transcript.fireBlocker(input.transcriptPath) : null;
  if (why && why !== 'gone' && !input.deferLogged) {
    stats.record(
      input.sessionId,
      { ok: false, reason: 'activity-detected', detail: why },
      { mode: 'compact', tokens: input.tokens, model: input.model, effort: input.effort }
    );
  }
  return why ? { why } : {};
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
    const fn = { arm, check, fired }[verb];
    const out = fn ? fn(input || {}) : {};
    process.stdout.write(JSON.stringify(out));
    process.exit(0);
  })
  .catch(() => process.exit(0));
