# Shape assertions for a PreToolUse deny, sourced by the suites. They read the
# suite's $OUT and $RC from the last hook run.

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

AH_U1_CALM="ah: holding an Ultra-Advisor escalation until you decide whether it should run."
AH_U2_CALM="ah: Ultra-Advisor is off for this session, so this escalation did not run."
AH_U3_CALM="ah: held a raw herdr brief to the Ultra-Advisor; it goes through the approved route instead."
AH_M1_CALM="ah: held a role dispatch until its brief is written as a message file; it will be re-sent."
AH_R1_CALM="ah: held an over-long report message; it will be trimmed to the file pointer and re-sent."
AH_R2_CALM="ah: held a report whose file pointer matches no open request; it will be corrected."
AH_R3_CALM="ah: held an inline reply while a report is owed as a response file; nothing is broken."
AH_G1_CALM="ah: the Orchestrator does not run as a subagent; this work stays in this session."
AH_G2_CALM="ah: held a message to a session outside your team; it goes to your team's member instead."
AH_G3_CALM="ah: held a SendMessage to a pane-run member; it will be briefed through the roster instead."
AH_G4_CALM="ah: role sessions do not dispatch ah roles; the need goes back to the Orchestrator."
AH_G5_CALM="ah: held a subagent dispatch of a chain role; it goes to the live peer instead."
AH_G6_CALM="ah: held a subagent dispatch of a chain role; a peer session will be started instead."
AH_G7_CALM="ah: held a dispatch to a role at or below this session's tier; it will be justified or done here."
AH_G8_CALM="ah: the route gate could not check this dispatch, so it was held; see the hook error log."
AH_H1_CALM="ah: held a herdr agent start with an invalid name; the same pane will be reused."
AH_H2_CALM="ah: held a raw herdr call to a hierarchy member; it goes through the roster instead."
AH_S1_CALM="ah: held a team lifecycle command until the agent-team skill is loaded; it reruns after."
AH_C1_CALM="ah: a role session tried to reach you directly; its question goes to the Orchestrator instead."
