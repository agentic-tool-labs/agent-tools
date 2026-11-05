/**
 * agent-hierarchy — which herdr a session runs under, and the one translator from the herdr TUI calls ah makes
 * to herdr core (`hc`) and the herdr desktop app (`herdr-app`).
 *
 * Spec: agent-hierarchy-v2 docs/specs/herdr-desktop.md, revision 2, Phase 3. The transport string stays
 * "herdr" for both; the flavour is `tui` or `core`. Under `tui` the translator is `muxExec("herdr", ...)`,
 * unchanged. Under `core` each TUI argv becomes `hc` / `herdr-app` calls, and the reply is shaped like the
 * TUI's, so callers parse it as they always have. A failure is thrown shaped like a failed TUI call: exit 1
 * with `{"error":{"code","message"}}` on stdout.
 */

import { randomBytes } from "node:crypto";
import { muxExec } from "./lib-mux.mjs";

/** `tui` when HERDR_ENV=1, else `core` when HC_TERMINAL_ID is non-empty, else null (not herdr). §2. */
export function herdrFlavourFromEnv(env = process.env) {
  if (env.HERDR_ENV === "1") return "tui";
  if (typeof env.HC_TERMINAL_ID === "string" && env.HC_TERMINAL_ID !== "") return "core";
  return null;
}

/** The flavour for a herdr call. v1 has no daemon, so it is the env's alone; nothing is stored on the team (§2, rev 4). */
export function herdrFlavour() {
  return herdrFlavourFromEnv() || "tui";
}

/** The binary a flavour's calls run. */
export function herdrBinary(flavour = herdrFlavour()) {
  return flavour === "core" ? "hc" : "herdr";
}

/** The calling session's own pane id: HERDR_PANE_ID under tui, the terminal address HC_TERMINAL_ID under core. */
export function herdrSelfPane(env = process.env) {
  return (herdrFlavourFromEnv(env) === "core" ? env.HC_TERMINAL_ID : env.HERDR_PANE_ID) || null;
}

/**
 * `muxExec("herdr", args, opts)` for the flavour: returns stdout, throws like execFileSync on failure. Under
 * core, the TUI verb is translated; a verb with no core mapping throws the `unsupported` error and runs nothing.
 */
export function herdrExec(args, opts = {}) {
  if (herdrFlavour() !== "core") return muxExec("herdr", args, opts);
  return translate(args, { timeout: opts.timeout || Number(process.env.AH_HERDR_TIMEOUT_MS || 10000) });
}

/** Under core, whether the desktop app answers (`herdr-app status` succeeds). Checked per call that needs it. */
export function herdrAppPresent() {
  try {
    appStatus({ timeout: Number(process.env.AH_HERDR_TIMEOUT_MS || 10000) });
    return true;
  } catch {
    return false;
  }
}

// ---------------------------------------------------------------- core plumbing

function tuiError(code, message) {
  const err = new Error(message);
  err.stdout = JSON.stringify({ error: { code, message } });
  err.stderr = message;
  err.status = 1;
  return err;
}

const unsupported = (verb, why = "") => tuiError("unsupported", `\`herdr ${verb}\` is not supported under herdr core${why ? ` (${why})` : ""}`);

/** A failed child that timed out is rethrown as is (the caller reads `err.signal`); anything else is returned. */
function run(bin, args, o) {
  try {
    return { ok: true, stdout: muxExec(bin, args, { encoding: "utf8", timeout: o.timeout, maxBuffer: 4 * 1024 * 1024, stdio: ["ignore", "pipe", "pipe"] }) };
  } catch (err) {
    if (err.signal) throw err;
    return { ok: false, stdout: err.stdout ? String(err.stdout) : "", stderr: err.stderr ? String(err.stderr) : "", message: err.message };
  }
}

/** One `hc` call with `--json`. hc writes `{"error":{"kind","message","hint"}}` on stderr (CORE cli.rs:207-219). */
function hc(args, o, { notFound = "not_found" } = {}) {
  const r = run("hc", [...args, "--json"], o);
  if (!r.ok) {
    let e = null;
    try {
      e = JSON.parse(r.stderr).error;
    } catch {
      // not JSON
    }
    const kind = (e && e.kind) || "hc_failed";
    throw tuiError(kind === "not_found" || kind === "finished" ? notFound : kind, `hc ${args[0]}: ${(e && e.message) || r.stderr.trim() || r.message}`);
  }
  try {
    return JSON.parse(r.stdout);
  } catch {
    throw tuiError("hc_failed", `hc ${args[0]} produced unparseable output`);
  }
}

/** One `herdr-app` call. It prints its JSON reply on stdout and exits 1 on `{error}`, 2 with no window (APP control.rs:73-128). */
function app(args, o) {
  const r = run("herdr-app", args, o);
  let reply = null;
  try {
    reply = JSON.parse(r.stdout);
  } catch {
    // no JSON reply
  }
  if (!r.ok || !reply || reply.error) {
    const why = (reply && typeof reply.error === "string" && reply.error) || r.stderr.trim() || r.message || "no reply";
    throw tuiError(r.ok || reply ? "app_error" : "app_absent", `herdr-app ${args.slice(0, 2).join(" ")}: ${why}`);
  }
  return reply;
}

const appDo = (action, payload, o) => app(["do", action, JSON.stringify(payload)], o);
const appStatus = (o) => app(["status"], o);
const appWorld = (o) => app(["ls"], o);

/** Every terminal the window shows: `{terminal, pane, tab, space}` (APP window.rs:3746-3786). */
function shownTerminals(world) {
  const out = [];
  for (const s of (world && world.spaces) || []) {
    for (const t of s.tabs || []) {
      for (const term of t.terminals || []) out.push({ terminal: term.terminal, pane: term.pane, tab: t.id, space: s.id });
    }
  }
  return out;
}

function needApp(verb, o) {
  try {
    return appStatus(o);
  } catch (err) {
    throw unsupported(verb, `it needs the herdr app window: ${err.message}`);
  }
}

/**
 * The live terminal labelled `ah.name=<name>` (§3.1). None: `agent_not_found`. More than one: never picks
 * one. ponytail: the clash is reported as `agent_name_ambiguous`, not `agent_not_found`, so ah's
 * three-valued logic reads it as indeterminate (as §3.3 says) rather than not-live.
 */
function lookup(name, o) {
  const rows = (hc(["ls", "--label", `ah.name=${name}`], o).terminals || []).filter((t) => t.state === undefined || t.state === "live");
  if (rows.length === 0) throw tuiError("agent_not_found", `no live terminal labelled ah.name=${name}`);
  if (rows.length > 1) throw tuiError("agent_name_ambiguous", `ah.name=${name} matches ${rows.length} live terminals (${rows.map((t) => t.address).join(", ")}); none was picked`);
  return rows[0].address;
}

/** TUI `agent_status` for a core record (§3.3): the reported state, `unknown` when none was reported. */
function mappedStatus(state) {
  return typeof state === "string" && state ? state : "unknown";
}

/** `hc get` of a live terminal; a finished one is `agent_not_found`, never its last status. */
function liveRecord(address, o) {
  const rec = hc(["get", address], o, { notFound: "agent_not_found" });
  if (rec.state !== "live") throw tuiError("agent_not_found", `terminal ${address} is ${rec.state || "not live"}`);
  return rec;
}

/** TUI `agent_type` for a core record (§3.3): `status.app`, with `claude-code` → `claude`; null when none was reported. */
function agentType(rec) {
  const appName = rec.status && typeof rec.status.app === "string" && rec.status.app ? rec.status.app : null;
  return appName === "claude-code" ? "claude" : appName;
}

function agentReply(address, o) {
  const rec = liveRecord(address, o);
  const labels = rec.labels || {};
  return { result: { agent: { name: labels["ah.name"] || null, pane_id: address, agent_status: mappedStatus(rec.status && rec.status.state), agent_type: agentType(rec), cwd: rec.cwd || null } } };
}

/**
 * TUI `agent list` rows for every live terminal: `name` from its `ah.name` label, `pane_id` = its address, the
 * tab and space from the app's labels. ponytail: one `hc get` per terminal (`hc ls` rows carry no labels); one
 * `terminal.list` with labels if a team ever grows past a handful of terminals.
 */
function agentRows(o) {
  return (hc(["ls"], o).terminals || [])
    .filter((t) => t.state === undefined || t.state === "live")
    .map((t) => {
      const rec = hc(["get", t.address], o);
      const labels = rec.labels || {};
      return { name: labels["ah.name"] || null, pane_id: t.address, tab_id: labels["herdr.tab"] || null, workspace_id: labels["herdr.space"] || null, cwd: rec.cwd || null, agent_status: mappedStatus(rec.status && rec.status.state), agent_type: agentType(rec) };
    });
}

const json = (v) => JSON.stringify(v);

function flagValue(args, flag) {
  const i = args.indexOf(flag);
  return i >= 0 && i + 1 < args.length ? args[i + 1] : undefined;
}

/** `hc read` reply text. Visible screen = `--lines 0`; history = `--lines N` (§5). `--json` keeps hc's own notes out of the text. */
function readText(address, args, o) {
  const lines = args.includes("--source") && flagValue(args, "--source") === "visible" ? 0 : Number(flagValue(args, "--lines") || 0);
  const r = hc(["read", address, "--lines", String(lines)], o, { notFound: "agent_not_found" });
  return typeof r.text === "string" ? r.text : "";
}

const KEY_NAMES = { Enter: "enter", Return: "enter", Escape: "esc", Esc: "esc", Tab: "tab", Space: "space", BSpace: "backspace", Backspace: "backspace", Up: "up", Down: "down", Left: "left", Right: "right", Home: "home", End: "end", PageUp: "pageup", PageDown: "pagedown", Delete: "delete" };
const CORE_KEYS = new Set(Object.values(KEY_NAMES).concat(["esc"]));

/** TUI key name → hc key name (CORE keys.rs:20-75). An unmapped key fails. */
export function coreKey(key) {
  if (KEY_NAMES[key]) return KEY_NAMES[key];
  if (CORE_KEYS.has(key)) return key;
  const ctrl = /^C-([a-z])$/i.exec(key);
  if (ctrl) return `ctrl+${ctrl[1].toLowerCase()}`;
  if (/^[0-9a-z]$/i.test(key)) return key;
  throw tuiError("unsupported", `key ${JSON.stringify(key)} has no herdr core name`);
}

/** POSIX single-quote a word for the shell a split pane runs. */
const shWord = (s) => `'${String(s).replace(/'/g, `'\\''`)}'`;

/** A synchronous pause, for the polls below (every caller of herdrExec is synchronous). */
const pause = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

/** Poll `check` every `AH_HC_POLL_MS` until it returns truthy or the deadline passes; its value, or null. */
function pollUntil(check, deadline) {
  for (;;) {
    const v = check();
    if (v) return v;
    if (Date.now() >= deadline) return null;
    pause(Number(process.env.AH_HC_POLL_MS || 250));
  }
}

// ---------------------------------------------------------------- the translator

function translate(args, o) {
  const [group, verb] = args;
  const key = `${group} ${verb}`;
  switch (key) {
    case "agent get":
      return json(agentReply(lookup(args[2], o), o));
    case "agent list":
      return json({ result: { agents: agentRows(o) } });
    case "agent prompt": {
      // hc send always presses Enter, and refuses a blocked program: that refusal is passed up, never forced.
      const address = lookup(args[2], o);
      const wait = args.includes("--wait");
      const ms = Number(flagValue(args, "--timeout") || 0);
      hc(["send", address, args[3], ...(wait ? ["--wait", ...(ms ? ["--timeout", String(Math.ceil(ms / 1000))] : [])] : [])], o, { notFound: "agent_not_found" });
      const reply = agentReply(address, o);
      if (wait && reply.result.agent.agent_status === "working") throw tuiError("timeout", `${args[2]} was still working when the wait ended`);
      return json(reply);
    }
    case "agent wait": {
      if (args.includes("--until")) throw unsupported(key, "--until is not in this release");
      const address = lookup(args[2], o);
      const ms = Number(flagValue(args, "--timeout") || 0);
      hc(["wait", address, ...(ms ? ["--timeout", String(Math.ceil(ms / 1000))] : [])], o, { notFound: "agent_not_found" });
      const reply = agentReply(address, o);
      if (reply.result.agent.agent_status === "working") throw tuiError("timeout", `${args[2]} was still working when the wait ended`);
      return json(reply);
    }
    case "agent send-keys":
      hc(["keys", lookup(args[2], o), ...args.slice(3).map(coreKey)], o, { notFound: "agent_not_found" });
      return json({ result: {} });
    case "agent read":
      return readText(lookup(args[2], o), args, o);
    case "pane read":
      return readText(args[2], args, o);
    case "agent start":
      return json(startAgent(args, o));
    case "pane close":
      return json(closePane(args[2], o));
    case "pane rename":
      // §5.3: the pane title cannot be set under core; success with no change.
      return json({ result: {} });
    case "pane layout":
      return json(paneLayout(args, o));
    case "pane split":
      return json(splitPane(args, o));
    case "pane list":
      return json(paneList(args, o));
    case "pane move":
      return json(movePane(args, o));
    case "tab create":
      return json(createTab(args, o));
    case "tab list": {
      needApp(key, o);
      const tabs = [];
      for (const s of appWorld(o).spaces || []) for (const t of s.tabs || []) tabs.push({ tab_id: t.id, label: t.name, workspace_id: s.id });
      return json({ result: { tabs } });
    }
    case "tab rename":
      needApp(key, o);
      appDo("tab.rename", { id: args[2], name: args[3] }, o);
      return json({ result: {} });
    default:
      throw unsupported(key);
  }
}

/**
 * `agent start <name> [--pane <address>] [--cwd <dir>] -- <launch line>`. Into a split pane's shell: type the
 * line with `hc send`, then label the terminal `ah.name=<name>`. With no pane (no app window):
 * `hc run --bg --label ah.name=<name> --cwd <dir> -- <line>`, a hidden member (§3.2).
 */
function startAgent(args, o) {
  const name = args[2];
  const sep = args.indexOf("--");
  const line = sep >= 0 ? args.slice(sep + 1).join(" ") : "";
  if (!line) throw tuiError("invalid_params", "agent start: no launch line after --");
  const pane = flagValue(args.slice(0, sep), "--pane");
  let address = pane;
  if (pane) {
    hc(["send", pane, line], o);
    hc(["label", pane, `ah.name=${name}`], o);
  } else {
    const cwd = flagValue(args.slice(0, sep), "--cwd");
    address = hc(["run", "--bg", "--label", `ah.name=${name}`, ...(cwd ? ["--cwd", cwd] : []), "--", line], o).address;
    if (!address) throw tuiError("hc_failed", "hc run printed no address");
  }
  return { result: { agent: { name, pane_id: address }, pane: { pane_id: address } } };
}

/** `hc kill`, with or without the app: the app's pane goes with the terminal (§5, E-4). */
function closePane(address, o) {
  hc(["kill", address], o, { notFound: "pane_not_found" });
  return { result: {} };
}

/** Core's default terminal size, which a terminal adopted into a tab that is not shown keeps until it is shown (§5.1, E-8). */
const DEFAULT_COLS = 200;
const DEFAULT_ROWS = 120;

/**
 * §5.1: the panes of the target's tab (the caller's for `--current`), each sized by its terminal's cols × rows
 * at the origin, with `positions:false` so the split rule takes its aspect path. `zoomed` is left out: the
 * app's status `zoom` is the window's font zoom, not a pane zoom (APP window.rs:3727).
 */
function paneLayout(args, o) {
  const status = needApp("pane layout", o);
  const shown = shownTerminals(appWorld(o));
  const target = flagValue(args, "--pane") || process.env.HC_TERMINAL_ID || null;
  const where = (target && shown.find((t) => t.terminal === target)) || null;
  const tab = where ? where.tab : status.tab;
  if (!tab) throw tuiError("pane_not_found", `pane layout: no tab holds ${target || "the caller"}`);
  const panes = shown
    .filter((t) => t.tab === tab)
    .map((t) => {
      const rec = hc(["get", t.terminal], o);
      const width = Number(rec.cols) || 0;
      const height = Number(rec.rows) || 0;
      return { pane_id: t.terminal, rect: { x: 0, y: 0, width, height }, ...(width === DEFAULT_COLS && height === DEFAULT_ROWS ? { size_known: false } : {}) };
    });
  const focused = shown.find((t) => t.pane === status.focused_pane);
  return { result: { layout: { panes, positions: false, tab_id: tab, focused_pane_id: focused ? focused.terminal : null } } };
}

/** §3.2, app present: split the target's app pane, cd the new shell when --cwd differs, give focus back for --no-focus. */
function splitPane(args, o) {
  const status = needApp("pane split", o);
  const target = flagValue(args, "--pane");
  const direction = flagValue(args, "--direction");
  const cwd = flagValue(args, "--cwd");
  const where = shownTerminals(appWorld(o)).find((t) => t.terminal === target);
  if (!where) throw tuiError("pane_not_found", `pane split: ${target} is not shown in the herdr app`);
  const made = appDo("pane.split", { pane: where.pane, direction }, o);
  const address = made.terminal;
  if (!address) throw tuiError("app_error", "pane.split returned no terminal");
  if (cwd) {
    const targetCwd = hc(["get", target], o).cwd;
    if (targetCwd !== cwd) hc(["send", address, `cd ${shWord(cwd)}`], o);
  }
  if (args.includes("--no-focus") && status.focused_pane) appDo("pane.focus", { pane: status.focused_pane }, o);
  return { result: { pane: { pane_id: address }, target, direction } };
}

/** `herdr-app ls` panes as TUI `pane list` rows; with no app, the terminals and their labels. */
function paneList(args, o) {
  const ws = flagValue(args, "--workspace");
  let rows;
  try {
    rows = shownTerminals(appWorld(o)).map((t) => ({ pane_id: t.terminal, tab_id: t.tab, workspace_id: t.space }));
  } catch {
    rows = agentRows(o).map((r) => ({ pane_id: r.pane_id, tab_id: r.tab_id, workspace_id: r.workspace_id }));
  }
  return { result: { panes: ws ? rows.filter((r) => r.workspace_id === ws) : rows } };
}

/** A fresh tab (`tb`) or space (`sp`) id in the app's own format, 32 lowercase hex (§5.2, E-10). */
const mintId = (prefix) => `${prefix}${randomBytes(16).toString("hex")}`;

/**
 * §5.2: park, wait for the blanked space label, relabel, wait for adoption. Adoption always lands right of the
 * tab's last pane, so `--split` is accepted and not honoured. Past the deadline (`AH_HC_ADOPT_WAIT_MS`), the
 * terminal is shown again with terminal.keep and the reply says `changed:"false"`.
 */
function movePane(args, o) {
  needApp("pane move", o);
  const address = args[2];
  const before = shownTerminals(appWorld(o));
  const here = before.find((t) => t.terminal === address);
  let space;
  let tab = null;
  if (args.includes("--tab")) {
    tab = flagValue(args, "--tab");
    const dest = (appWorld(o).spaces || []).find((s) => (s.tabs || []).some((t) => t.id === tab));
    if (!dest) throw tuiError("tab_not_found", `pane move: no tab ${tab}`);
    space = dest.id;
  } else if (args.includes("--new-tab")) {
    space = flagValue(args, "--workspace") || (here && here.space);
    if (!space) throw tuiError("pane_not_found", `pane move: ${address} is in no space`);
    tab = mintId("tb");
  } else if (args.includes("--new-workspace")) {
    space = mintId("sp");
    tab = mintId("tb");
  } else {
    throw tuiError("invalid_params", "pane move: one of --tab, --new-tab, --new-workspace");
  }
  // §5.2: 5 s; E-10 measured adoption at 0.3-0.5 s.
  const deadline = Date.now() + Number(process.env.AH_HC_ADOPT_WAIT_MS || 5000);
  appDo("terminal.park", { terminal: address }, o);
  // Park is asynchronous; a label written before it lands would be blanked by it.
  const parked = pollUntil(() => {
    const labels = hc(["get", address], o).labels || {};
    return !labels["herdr.space"];
  }, deadline);
  let adopted = null;
  if (parked) {
    hc(["label", address, `herdr.space=${space}`, `herdr.tab=${tab}`], o);
    adopted = pollUntil(() => shownTerminals(appWorld(o)).find((t) => t.terminal === address && t.space === space && t.tab === tab), deadline);
  }
  if (!adopted) {
    appDo("terminal.keep", { terminal: address }, o);
    return { result: { changed: "false" } };
  }
  return { result: { changed: "true", pane: { pane_id: address, tab_id: adopted.tab, workspace_id: adopted.space } } };
}

/** §5.4: tab.new in the caller's space with a shell root pane; --no-focus selects the old space and tab again. */
function createTab(args, o) {
  const status = needApp("tab create", o);
  let space = flagValue(args, "--workspace");
  if (!space && process.env.HC_TERMINAL_ID) {
    try {
      space = (hc(["get", process.env.HC_TERMINAL_ID], o).labels || {})["herdr.space"] || undefined;
    } catch {
      // the caller's own terminal is unreadable: the app's active space below
    }
  }
  space = space || status.space;
  const made = appDo("tab.new", { ...(space ? { space } : {}), name: flagValue(args, "--label"), folder: flagValue(args, "--cwd") }, o);
  if (args.includes("--no-focus") && status.space && status.tab) {
    appDo("space.select", { id: status.space }, o);
    appDo("tab.select", { id: status.tab }, o);
  }
  return { result: { tab: { tab_id: made.tab, workspace_id: made.space }, root_pane: { pane_id: made.terminal } } };
}
