'use strict';

const { spawnSync } = require('child_process');
const inject = require('./inject');

// Short: this runs while the daemon is on its way out. A hung notifier must
// not hold the process open longer than a blink.
const NOTIFY_TIMEOUT_MS = 2000;

// osascript interprets its argument as AppleScript, so a quote or backslash in
// the text is a syntax break, not just ugly output. The text can carry stderr
// from a foreign binary, so restrict it to a charset with no AppleScript or
// shell meaning rather than trying to escape it. (spawnSync is called without a
// shell, so this is about AppleScript only — but the same sanitised string is
// used on every platform, which keeps this to one rule.)
function sanitize(s) {
  return String(s == null ? '' : s)
    .replace(/[^\w \-.:,/]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim()
    .slice(0, 200);
}

// Best-effort desktop notification. Returns true if the OS mechanism reported
// success, false otherwise. NEVER throws, on any platform, for any reason.
function notify(title, body) {
  try {
    const t = sanitize(title);
    const b = sanitize(body);
    const opts = {
      timeout: NOTIFY_TIMEOUT_MS,
      encoding: 'utf8',
      windowsHide: true,
      stdio: ['ignore', 'ignore', 'ignore'],
    };

    if (process.platform === 'darwin') {
      const script = 'display notification "' + b + '" with title "' + t + '"';
      const res = spawnSync('osascript', ['-e', script], opts);
      return !res.error && res.status === 0;
    }

    if (process.platform === 'win32') {
      // ponytail: msg.exe is absent on Home editions, where this silently
      // no-ops. Upgrade path if that matters: a PowerShell
      // Windows.UI.Notifications toast with inline XML (still zero-dep, but
      // ~15 lines of XML to get right).
      if (!inject.have('msg')) return false;
      const res = spawnSync('msg', ['*', '/TIME:30', t + ': ' + b], opts);
      return !res.error && res.status === 0;
    }

    // Linux and anything else that might have it.
    if (!inject.have('notify-send')) return false;
    const res = spawnSync('notify-send', ['--urgency=normal', t, b], opts);
    return !res.error && res.status === 0;
  } catch (_) {
    // The contract is "never throws". A missing binary, a permission denial, a
    // spawn failure, an unknown platform: all are the same non-event here.
    return false;
  }
}

module.exports = { notify, sanitize, NOTIFY_TIMEOUT_MS };
