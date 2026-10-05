#!/bin/bash
# agent-hierarchy — lib-status.mjs never opens a non-regular file at status.json / activity/<x>.json,
# never sweeps through a linked activity dir, and never writes through a link at a temp name.
# Each case runs in its own child process under a timeout, so a FIFO hang fails instead of hanging.
# Usage: bash tests/test-status-reader-hazard.sh   (exits 0 iff all cases pass)
PLUGIN="$(cd "$(dirname "$0")/.." && pwd)"
exec node "$PLUGIN/tests/status-reader-hazard.mjs"
