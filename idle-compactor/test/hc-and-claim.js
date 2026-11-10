'use strict';

// The hc provider's detection and argv (a stub `hc`, never the real one), and the mod's claim handing a turn
// from arm.js to hooks/register.ts. Sandboxed HOME, so ~/.claude/idle-compactor is never touched.

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const SANDBOX = fs.mkdtempSync(path.join(os.tmpdir(), 'ic-hc-'));
process.on('exit', () => fs.rmSync(SANDBOX, { recursive: true, force: true }));
process.env.HOME = SANDBOX;
process.env.USERPROFILE = SANDBOX;
const ORIG_PATH = process.env.PATH;

const PLUGIN = path.resolve(__dirname, '..');
const inject = require(path.join(PLUGIN, 'scripts', 'lib', 'inject.js'));
const state = require(path.join(PLUGIN, 'scripts', 'lib', 'state.js'));

// --- hc provider ---
const bin = path.join(SANDBOX, 'bin');
fs.mkdirSync(bin);
const argvLog = path.join(SANDBOX, 'hc-argv.txt');
const envLog = path.join(SANDBOX, 'hc-env.txt');
// The calling session's own hc identity, which every hc child must be spawned without.
process.env.HC_TERMINAL_ID = 'self';
process.env.HC_SOCKET = '/tmp/hc.sock';
fs.writeFileSync(
  path.join(bin, 'hc'),
  '#!/bin/sh\nprintf "%s|" "$@" >> ' + JSON.stringify(argvLog) + '\nprintf "\\n" >> ' + JSON.stringify(argvLog) +
    '\nprintf "%s/%s\\n" "${HC_TERMINAL_ID-unset}" "${HC_SOCKET-unset}" >> ' + JSON.stringify(envLog) + '\necho screen\n'
);
fs.chmodSync(path.join(bin, 'hc'), 0o755);
process.env.PATH = bin + path.delimiter + ORIG_PATH;

assert.strictEqual(inject.captureEnv({ HC_TERMINAL_ID: 't2j' }).HC_TERMINAL_ID, 't2j');
const hc = inject.detect(inject.makeContext({ env: { HC_TERMINAL_ID: 't2j' }, text: '/compact keep it' })).find((p) => p.name === 'hc');
assert.ok(hc, 'hc detected from HC_TERMINAL_ID with hc on PATH');
assert.strictEqual(hc.blind, false);
assert.ok(hc.send().ok);
assert.strictEqual(hc.snapshot(), 'screen');
assert.ok(hc.submit().ok);
assert.deepStrictEqual(fs.readFileSync(argvLog, 'utf8').trim().split('\n'), [
  'keys|t2j|esc|',
  'send|t2j|/compact keep it|',
  'read|t2j|',
  'keys|t2j|enter|',
]);
assert.deepStrictEqual(fs.readFileSync(envLog, 'utf8').trim().split('\n'), Array(4).fill('unset/unset'),
  'every hc call is spawned without HC_TERMINAL_ID and HC_SOCKET');
// Order, after the mod: the herdr app's pane, then herdr core's terminal, then the other providers. Stubs only.
for (const name of ['herdr', 'tmux']) {
  fs.writeFileSync(path.join(bin, name), '#!/bin/sh\nexit 0\n');
  fs.chmodSync(path.join(bin, name), 0o755);
}
const both = { HERDR_ENV: '1', HERDR_PANE_ID: 'p1', HC_TERMINAL_ID: 't1', TMUX: '/tmp/tmux-sock,1,0', TMUX_PANE: '%1' };
assert.deepStrictEqual(inject.detect(inject.makeContext({ env: both })).map((p) => p.name).slice(0, 3),
  ['herdr', 'hc', 'tmux'], 'herdr app, then herdr core, ahead of every other provider');
assert.deepStrictEqual(inject.detect(inject.makeContext({ env: Object.assign({}, both, { HERDR_PANE_ID: '' }) }))
  .map((p) => p.name).slice(0, 2), ['hc', 'tmux'], 'herdr core alone leads the other providers');
// The herdr app's env as a session in it has it: the pane id is captured for the detached timer; HERDR_ENV
// alone names no pane, so it is not a herdr session to send to (negative).
assert.strictEqual(inject.captureEnv(both).HERDR_PANE_ID, 'p1');
assert.ok(!inject.detect(inject.makeContext({ env: { HERDR_ENV: '1' } })).some((p) => p.name === 'herdr'));
for (const name of ['herdr', 'tmux']) fs.unlinkSync(path.join(bin, name));
// Negative: no terminal id, and an id with no hc on PATH.
assert.ok(!inject.detect(inject.makeContext({ env: {} })).some((p) => p.name === 'hc'));
process.env.PATH = '/usr/bin:/bin';
assert.ok(!inject.detect(inject.makeContext({ env: { HC_TERMINAL_ID: 't2j' } })).some((p) => p.name === 'hc'));
process.env.PATH = ORIG_PATH;

// --- mod claim ---
const run = (script, args, input, extraEnv) =>
  spawnSync(process.execPath, [path.join(PLUGIN, 'scripts', script)].concat(args), {
    input: JSON.stringify(input),
    encoding: 'utf8',
    env: Object.assign({}, process.env, extraEnv || {}),
    timeout: 15000,
  });

const stop = { session_id: 'claim1', cwd: SANDBOX };
const plan = JSON.parse(run('mod.js', ['arm'], stop).stdout);
assert.ok(plan.ms > 0, 'mod arms in compact mode');
assert.ok(fs.existsSync(state.claimFile('claim1')), 'mod claims the turn');
run('arm.js', [], stop);
assert.ok(!fs.existsSync(state.claimFile('claim1')), 'arm.js consumes the claim');
assert.strictEqual(state.read('claim1'), null, 'arm.js arms nothing on a claimed turn');
// Negative: disabled (the same branch as keepalive mode), the mod neither arms nor claims.
const kept = JSON.parse(run('mod.js', ['arm'], stop, { CLAUDE_IDLE_COMPACT_DISABLE: '1' }).stdout);
assert.deepStrictEqual(kept, {});
assert.ok(!fs.existsSync(state.claimFile('claim1')));
assert.strictEqual(state.takeClaim('claim1'), false);
// Negative: Stop input that makes arm throw after reading the transcript (a non-string cwd) prints no plan and
// leaves no claim, so arm.js still injects.
const malformed = run('mod.js', ['arm'], { session_id: 'claim2', cwd: 123 });
assert.strictEqual(malformed.stdout, '');
assert.ok(!fs.existsSync(state.claimFile('claim2')), 'a failed arm leaves no claim');

// --- fire-time guard (shared with timer.js) ---
const tp = path.join(SANDBOX, 't.jsonl');
fs.writeFileSync(tp, '{"type":"user","message":{"role":"user","content":"hi"}}\n');
const checkOf = (p) => JSON.parse(run('mod.js', ['check'], { sessionId: 'g1', transcriptPath: p }).stdout);
assert.deepStrictEqual(checkOf(tp), { why: 'settling' }, 'a just-written transcript defers');
assert.deepStrictEqual(checkOf(path.join(SANDBOX, 'none.jsonl')), { why: 'gone' });
const old = new Date(Date.now() - 10 * 60 * 1000);
fs.utimesSync(tp, old, old);
assert.deepStrictEqual(checkOf(tp), {}, 'a quiet transcript fires');

// --- the mod's arm input from $.session (turn.complete has no transcript_path) ---
const transcript = require(path.join(PLUGIN, 'scripts', 'lib', 'transcript.js'));
const root = '/work/my.repo';
const projDir = path.join(SANDBOX, '.claude', 'projects', '-work-my-repo');
fs.mkdirSync(projDir, { recursive: true });
const found = path.join(projDir, 'loc1.jsonl');
fs.writeFileSync(found, '{"message":{"model":"m1","usage":{"input_tokens":9}}}\n');
assert.strictEqual(transcript.locate('loc1', [root, '/elsewhere']), found, 'locate finds <root slug>/<id>.jsonl');
assert.strictEqual(transcript.locate('loc1', [undefined, '/work/my.repo']), found, 'a missing root falls to cwd');
// Negative: another id, or a dir whose slug differs, finds nothing.
assert.strictEqual(transcript.locate('loc2', [root]), null);
assert.strictEqual(transcript.locate('loc1', ['/work/my/repo2']), null);
assert.strictEqual(transcript.locate('', [root]), null);

const located = JSON.parse(run('mod.js', ['arm'], { session_id: 'loc1', cwd: SANDBOX, root, tokens: 50000 }).stdout);
assert.strictEqual(located.transcriptPath, found, 'the plan carries the located transcript');
assert.strictEqual(located.model, 'm1', 'stats read from the located transcript');
assert.strictEqual(located.tokens, 50000, "the floor uses $.session.usage()'s tokens, not the transcript's");
state.takeClaim('loc1');
// Negative: no transcript found still arms, with no stats.
const blind = JSON.parse(run('mod.js', ['arm'], { session_id: 'loc3', cwd: SANDBOX, root, tokens: 50000 }).stdout);
assert.ok(blind.ms > 0, 'a missing transcript skips the stats, not the arm');
assert.strictEqual(blind.transcriptPath, null);
assert.strictEqual(blind.model, null);
state.takeClaim('loc3');
// The floor: below minTokens declines and claims nothing; at it arms.
assert.deepStrictEqual(JSON.parse(run('mod.js', ['arm'], { session_id: 'loc4', cwd: SANDBOX, tokens: 19999 }).stdout), {});
assert.ok(!fs.existsSync(state.claimFile('loc4')), 'below the floor nothing is claimed');
assert.ok(JSON.parse(run('mod.js', ['arm'], { session_id: 'loc4', cwd: SANDBOX, tokens: 20000 }).stdout).ms > 0);
state.takeClaim('loc4');

// --- arm.js's Stop before the mod's turn.complete: disarm.js stops the injection timer ---
run('arm.js', [], { session_id: 'order1', cwd: SANDBOX });
const injecting = state.read('order1');
assert.ok(injecting && injecting.timerPid, 'arm.js, first, arms an injection timer');
assert.ok(JSON.parse(run('mod.js', ['arm'], { session_id: 'order1', cwd: SANDBOX, tokens: 50000 }).stdout).ms > 0);
run('disarm.js', [], { session_id: 'order1' });
assert.strictEqual(state.read('order1'), null, 'disarm.js removes the injection record');
let alive = true;
for (let i = 0; i < 50 && alive; i++) {
  try {
    process.kill(injecting.timerPid, 0);
    spawnSync('sleep', ['0.1']);
  } catch (_) {
    alive = false;
  }
}
assert.ok(!alive, 'the injection timer is stopped');
state.takeClaim('order1');

console.log('hc-and-claim: ok');
