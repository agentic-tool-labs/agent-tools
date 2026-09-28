# Shape assertions for a PreToolUse deny, sourced by the suites. They read the
# suite's $OUT and $RC from the last run_hook.

# quiet_deny <calm> <model-phrase>: stdout is one JSON object whose only keys are
# systemMessage (== calm, one line) and a PreToolUse deny whose reason contains
# model-phrase.
quiet_deny() {
  [ "$RC" -eq 0 ] && printf '%s' "$OUT" | node -e '
    const [calm, phrase] = process.argv.slice(1);
    let s = "";
    process.stdin.on("data", (d) => (s += d)).on("end", () => {
      let o;
      try { o = JSON.parse(s); } catch { process.exit(1); }
      const h = (o && o.hookSpecificOutput) || {};
      const r = h.permissionDecisionReason;
      const ok =
        o !== null && typeof o === "object" && !Array.isArray(o) &&
        Object.keys(o).sort().join() === "hookSpecificOutput,systemMessage" &&
        o.systemMessage === calm && !calm.includes("\n") &&
        h.hookEventName === "PreToolUse" && h.permissionDecision === "deny" &&
        typeof r === "string" && r.length > 0 && r.includes(phrase);
      process.exit(ok ? 0 : 1);
    });' "$1" "$2"
}

# no_system_message: stdout is one JSON object with no top-level systemMessage.
no_system_message() {
  printf '%s' "$OUT" | node -e '
    let s = "";
    process.stdin.on("data", (d) => (s += d)).on("end", () => {
      let o;
      try { o = JSON.parse(s); } catch { process.exit(1); }
      process.exit(o && typeof o === "object" && !("systemMessage" in o) ? 0 : 1);
    });'
}

TG1_CALM="task-gopher: held a destructive or outward-facing command from a delegated runner; it reports back instead."
TG2_CALM="task-gopher: held a dispatch that asks a gopher to copy whole files; the order will be narrowed."
TG3_CALM="task-gopher: paused a smart-gopher dispatch to check a cheaper runner fits; re-running proceeds."
TG4_CALM="task-gopher: paused one direct lookup to suggest delegating it; re-running proceeds."
TG5_CALM="task-gopher: paused again after several direct lookups in a row; re-running proceeds."
