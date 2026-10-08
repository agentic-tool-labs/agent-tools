/**
 * agent-hierarchy — the one place a terminal multiplexer binary (herdr, tmux) is executed.
 *
 * Outside the test suite this is exactly `execFileSync`. A test file sets AH_TEST_HERMETIC=1 (tests/lib-hermetic.sh),
 * and then a binary is only run when it resolves, on the PATH the call would use, to a file inside one of the
 * directories the test lists in AH_TEST_FAKE_BIN. A binary that resolves anywhere else is the user's real herdr or
 * tmux: the call is recorded in AH_TEST_TRIPWIRE, reported on stderr, the test process (AH_TEST_PID) is sent SIGTERM,
 * and the call throws without running anything. A binary that is on no PATH entry at all fails as it always did.
 */

import { execFileSync } from "node:child_process";
import { accessSync, appendFileSync, constants, realpathSync, statSync } from "node:fs";
import { delimiter, join, sep } from "node:path";

function resolveOnPath(binary, pathVar) {
  for (const dir of String(pathVar || "").split(delimiter)) {
    if (!dir) continue;
    const candidate = join(dir, binary);
    try {
      if (!statSync(candidate).isFile()) continue;
      accessSync(candidate, constants.X_OK);
      return candidate;
    } catch {
      // not here
    }
  }
  return null;
}

function listedDirs() {
  const dirs = [];
  for (const d of String(process.env.AH_TEST_FAKE_BIN || "").split(":")) {
    if (!d) continue;
    try {
      dirs.push(realpathSync(d));
    } catch {
      // a listed directory that does not exist lists nothing
    }
  }
  return dirs;
}

function tripwire(binary, args) {
  const line = `${binary} ${args.join(" ")} pid=${process.pid}`;
  try {
    if (process.env.AH_TEST_TRIPWIRE) appendFileSync(process.env.AH_TEST_TRIPWIRE, line + "\n");
  } catch {
    // the stderr line and the kill below still happen
  }
  const message = `ah: test hermeticity: a test reached the real ${binary} (${args.join(" ")}). Put a fake in a directory listed in AH_TEST_FAKE_BIN.`;
  try {
    process.stderr.write(message + "\n");
  } catch {
    // closed stderr
  }
  const pid = Number(process.env.AH_TEST_PID);
  if (Number.isInteger(pid) && pid > 0) {
    try {
      process.kill(pid, "SIGTERM");
    } catch {
      // the test file is already gone
    }
  }
  throw new Error(message);
}

function guard(binary, args, options) {
  const pathVar = options && options.env && options.env.PATH !== undefined ? options.env.PATH : process.env.PATH;
  const found = resolveOnPath(binary, pathVar);
  if (!found) return;
  let real;
  try {
    real = realpathSync(found);
  } catch {
    real = found;
  }
  if (listedDirs().some((d) => real === d || real.startsWith(d + sep))) return;
  tripwire(binary, args);
}

/** Run a multiplexer binary. Same signature and result as `execFileSync(binary, args, options)`. */
export function muxExec(binary, args, options) {
  if (process.env.AH_TEST_HERMETIC === "1") guard(binary, args, options);
  return execFileSync(binary, args, options);
}
