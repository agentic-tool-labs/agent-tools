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
fs.writeFileSync(
  path.join(bin, 'hc'),
  '#!/bin/sh\nprintf "%s|" "$@" >> ' + JSON.stringify(argvLog) + '\nprintf "\\n" >> ' + JSON.stringify(argvLog) + '\necho screen\n'
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
  'send|t2j|/compact keep it|',
  'read|t2j|',
  'keys|t2j|enter|',
]);
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

console.log('hc-and-claim: ok');
