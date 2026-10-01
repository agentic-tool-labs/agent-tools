#!/usr/bin/env node
// agent-hierarchy — PreToolUse push guard (Bash). Push rules apply only in repos that commit
// `.claude/ah-conventions.json` on origin's default branch; merge rules only while a /pipeline run
// is open. It reads the run anchor and the run's decision log; it writes nothing.
//
// In an opted-in repo it denies force pushes, --no-verify, deletions, bulk and tag pushes, pushes to a
// remote other than origin, pushes to the default or a protected branch, pushes whose range touches
// a protected path, and edits to remote configuration. Errors before opt-in is established allow;
// errors after it fail closed (PG-ERROR).
//
// While a run is open, in any repo, it denies every way the run could merge, approve, ready or
// auto-merge a PR, `git merge`/`git pull` on the default or a protected branch, and a push to either.
// If those rules throw on such a command, it denies while a run is live or liveness is unknown
// (PG-MERGE-ERROR), and stays out of the way otherwise. The one exception
// is the pinned merge command (lib-decisions.mjs mergeCommand) from the run's top-level Orchestrator
// in a run that opted into auto-merge: that gets the native permission prompt, so the user's click
// is the approval.
//
// It matches command text, so it stops a compliant model following an injected instruction, not an
// adversarial one: shell expansion, command text fed to a shell as data, other programs that run
// git, git aliases, non-literal paths, other API clients (curl, hub), gh aliases and extensions all
// get past it. See docs/pipeline-conventions.md.
//
// CLI mode, the same evaluation without a push, and the read-only merge readiness check:
//   node pretooluse-push-guard.mjs check --branch <name> --cwd <abs>
//   node pretooluse-push-guard.mjs merge-check --pr <N> --cwd <abs>

import { execFileSync } from "node:child_process";
import { existsSync, readdirSync } from "node:fs";
import { join, resolve } from "node:path";
import { logHookError, mainHierarchyDir, readHookInput, resolveHierarchyRole } from "./lib-config.mjs";
import { conventionSettings, git, globMatch, globRegExp, loadConventions, refExists, tryGit } from "./lib-conventions.mjs";

// ---------------------------------------------------------------------------------------------
// Shell text → events: { cmd: [word…] } per simple command and { sub: [event…] } per `$(…)`,
// backtick or `( … )` body, in the order they run. Words keep `$…` and backtick text unexpanded.

function skipHeredoc(src, i, { delim, strip }) {
  while (i < src.length) {
    let j = src.indexOf("\n", i);
    if (j < 0) j = src.length;
    const line = strip ? src.slice(i, j).replace(/^\t+/, "") : src.slice(i, j);
    i = j + 1;
    if (line === delim) break;
  }
  return i;
}

function parseShell(src, start = 0, nested = false) {
  const events = [];
  const heredocs = [];
  let words = [];
  let word = null;
  let drop = false;
  let i = start;
  const endWord = () => {
    if (word !== null) {
      if (drop) drop = false;
      else words.push(word);
    }
    word = null;
  };
  const endCmd = () => {
    endWord();
    if (words.length) events.push({ cmd: words });
    words = [];
    drop = false;
  };
  const add = (s) => {
    word = (word ?? "") + s;
  };
  const substitution = (from) => {
    const inner = parseShell(src, from, true);
    events.push({ sub: inner.events });
    return inner.end;
  };
  const backtick = (from) => {
    let j = from;
    while (j < src.length && src[j] !== "`") j += src[j] === "\\" ? 2 : 1;
    events.push({ sub: parseShell(src.slice(from, j)).events });
    return j + 1;
  };
  const embedded = () => {
    const s = i;
    i = src[i] === "`" ? backtick(i + 1) : substitution(i + 2);
    add(src.slice(s, i));
  };

  while (i < src.length) {
    const c = src[i];
    if (c === "\\") {
      if (src[i + 1] !== "\n") add(src[i + 1] ?? "");
      i += 2;
    } else if (c === "'") {
      const j = src.indexOf("'", i + 1);
      const end = j < 0 ? src.length : j;
      add(src.slice(i + 1, end));
      i = end + 1;
    } else if (c === '"') {
      add("");
      i++;
      while (i < src.length && src[i] !== '"') {
        if (src[i] === "\\" && '$`"\\\n'.includes(src[i + 1] ?? "")) {
          if (src[i + 1] !== "\n") add(src[i + 1]);
          i += 2;
        } else if ((src[i] === "$" && src[i + 1] === "(") || src[i] === "`") embedded();
        else add(src[i++]);
      }
      i++;
    } else if ((c === "$" && src[i + 1] === "(") || c === "`") {
      embedded();
    } else if (c === "(") {
      endCmd();
      i = substitution(i + 1);
    } else if (c === ")") {
      endCmd();
      i++;
      if (nested) return { events, end: i };
    } else if (c === "#" && word === null) {
      while (i < src.length && src[i] !== "\n") i++;
    } else if (c === "\n") {
      endCmd();
      i++;
      for (const h of heredocs.splice(0)) i = skipHeredoc(src, i, h);
    } else if (c === "<" || c === ">" || (c === "&" && src[i + 1] === ">")) {
      // A redirection: its fd prefix and its target word are not arguments.
      if (word !== null && /^\d+$/.test(word)) word = null;
      else endWord();
      if (src.startsWith("<<<", i)) {
        i += 3;
        drop = true;
      } else if (src.startsWith("<<", i)) {
        i += 2;
        const strip = src[i] === "-";
        if (strip) i++;
        while (src[i] === " " || src[i] === "\t") i++;
        let delim = "";
        for (; i < src.length && !/[\s;&|<>()]/.test(src[i]); i++) if (!`'"\\`.includes(src[i])) delim += src[i];
        heredocs.push({ delim, strip });
      } else {
        i += c === "&" ? 2 : 1;
        if (">&|<".includes(src[i] ?? "")) i++;
        drop = true;
      }
    } else if (c === ";" || c === "&" || c === "|") {
      endCmd();
      i++;
    } else if (c === " " || c === "\t") {
      endWord();
      i++;
    } else {
      add(c);
      i++;
    }
  }
  endCmd();
  return { events, end: i };
}

// ---------------------------------------------------------------------------------------------
// Events → git invocations, each with its effective directory, git-dir and work-tree.

const literalDir = (w) => typeof w === "string" && w !== "" && !/[$`~]/.test(w);
const basename = (w) => w.slice(w.lastIndexOf("/") + 1);
const RESERVED = new Set(["!", "{", "}", "if", "then", "elif", "else", "do", "while", "until"]);
const EXEC_OPTS_WITH_ARG = new Set(["-a"]);
const NICE_OPTS_WITH_ARG = new Set(["-n", "--adjustment"]);
const ENV_OPTS_WITH_ARG = new Set(["-u", "-C", "-P", "-S", "--unset", "--chdir", "--split-string"]);
const SUDO_OPTS_WITH_ARG = new Set(["-u", "-g", "-h", "-p", "-C", "-D", "-r", "-t", "-U"]);
const TIMEOUT_OPTS_WITH_ARG = new Set(["-s", "-k"]);
const SHELLS = new Set(["bash", "sh", "zsh", "dash", "ksh"]);
const GIT_OPTS_WITH_ARG = new Set(["-C", "-c", "--git-dir", "--work-tree", "--namespace", "--config-env", "--super-prefix"]);

/**
 * Index of the word the shell actually runs, past assignments, reserved words and wrappers
 * (repeatedly, in any order), plus every NAME=value assignment met on the way and the directory an
 * `env -C` names. `command -v`/`-V` runs nothing, which reads as an index past the end.
 */
function commandWord(w) {
  const env = {};
  let dir = null;
  let k = 0;
  const assignment = () => {
    const m = /^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/s.exec(w[k]);
    if (m) {
      env[m[1]] = m[2];
      k++;
    }
    return Boolean(m);
  };
  const options = (withArg) => {
    while (k < w.length && w[k].startsWith("-")) k += withArg.has(w[k]) ? 2 : 1;
  };
  while (k < w.length) {
    const word = w[k];
    if (assignment()) continue;
    k++;
    if (RESERVED.has(word) || word === "nohup") continue;
    if (word === "time") {
      if (w[k] === "-p") k++;
    } else if (word === "command") {
      for (; k < w.length && w[k].startsWith("-"); k++) if (/[vV]/.test(w[k])) return { k: w.length, env, dir };
    } else if (word === "exec") options(EXEC_OPTS_WITH_ARG);
    else if (word === "nice") options(NICE_OPTS_WITH_ARG);
    else if (word === "env") {
      while (k < w.length && !assignment() && w[k].startsWith("-")) {
        if (w[k] === "-C" || w[k] === "--chdir") dir = w[k + 1];
        else if (w[k].startsWith("--chdir=")) dir = w[k].slice("--chdir=".length);
        k += ENV_OPTS_WITH_ARG.has(w[k]) ? 2 : 1;
      }
      while (k < w.length && assignment());
    } else if (word === "sudo") options(SUDO_OPTS_WITH_ARG);
    else if (word === "timeout") {
      options(TIMEOUT_OPTS_WITH_ARG);
      k++;
    } else {
      k--;
      break;
    }
  }
  return { k, env, dir };
}

function gitInvocation(args, cwd, env) {
  const cfg = [];
  const named = {};
  let k = 0;
  for (; k < args.length && args[k].startsWith("-"); k++) {
    const a = args[k];
    const eq = a.startsWith("--") ? a.indexOf("=") : -1;
    const opt = eq > 0 ? a.slice(0, eq) : a;
    if (!GIT_OPTS_WITH_ARG.has(opt)) continue;
    const value = eq > 0 ? a.slice(eq + 1) : args[++k];
    if (opt === "-C") {
      if (literalDir(value)) cwd = resolve(cwd, value);
    } else if (opt === "-c" || opt === "--config-env") cfg.push({ opt, kv: value ?? "" });
    else if (opt === "--git-dir" || opt === "--work-tree") named[opt] = value;
  }
  // An option overrides the environment variable, as in git; a non-literal value applies neither.
  const pick = (opt, envVar) => {
    const v = opt in named ? named[opt] : env[envVar];
    return literalDir(v) ? resolve(cwd, v) : null;
  };
  return { sub: args[k], args: args.slice(k + 1), cwd, gitDir: pick("--git-dir", "GIT_DIR"), workTree: pick("--work-tree", "GIT_WORK_TREE"), cfg };
}

/**
 * `state` is `{ cwd, stack }` for this command sequence (the stack is pushd's); a subshell or a
 * nested command string gets a copy. `root` is the hook's own cwd, where an unknowable directory
 * change (`pushd` with no argument or `+N`/`-N`, an unmatched `popd`) falls back to.
 */
function gitInvocations(events, state, root, out = [], ghOut = []) {
  const copy = (cwd) => ({ cwd, stack: [...state.stack] });
  for (const ev of events) {
    if (ev.sub) {
      gitInvocations(ev.sub, copy(state.cwd), root, out, ghOut);
      continue;
    }
    const { k, env, dir } = commandWord(ev.cmd);
    const name = ev.cmd[k];
    const args = ev.cmd.slice(k + 1);
    if (name === undefined) continue;
    const here = literalDir(dir) ? resolve(state.cwd, dir) : state.cwd;
    if (name === "cd") {
      if (args.length === 1 && literalDir(args[0]) && !args[0].startsWith("-")) state.cwd = resolve(state.cwd, args[0]);
    } else if (name === "pushd") {
      if (args.length === 1 && !/^[+-]\d+$/.test(args[0])) {
        state.stack.push(state.cwd);
        if (literalDir(args[0])) state.cwd = resolve(state.cwd, args[0]);
      } else state.cwd = root;
    } else if (name === "popd") {
      state.cwd = args.length === 0 && state.stack.length ? state.stack.pop() : root;
    } else if (SHELLS.has(basename(name))) {
      let j = 0;
      let dashC = false;
      for (; j < args.length && /^[-+]./.test(args[j]); j++) {
        if (/^-[A-Za-z]*c[A-Za-z]*$/.test(args[j])) dashC = true;
        if (/^[-+][A-Za-z]*[oO]$/.test(args[j]) || args[j] === "--rcfile" || args[j] === "--init-file") j++;
      }
      if (dashC && j < args.length) gitInvocations(parseShell(args[j]).events, copy(here), root, out, ghOut);
    } else if (name === "eval") {
      gitInvocations(parseShell(args.join(" ")).events, copy(here), root, out, ghOut);
    } else if (basename(name) === "git") {
      out.push(gitInvocation(args, here, env));
    } else if (basename(name) === "gh") {
      ghOut.push({ args, cwd: here });
    }
  }
  return out;
}

// ---------------------------------------------------------------------------------------------
// Evaluation (opted-in repos only).

const BASELINE_PATHS = [
  ".github/**", ".gitlab-ci.yml", ".gitlab/**", ".circleci/**", "Jenkinsfile", ".buildkite/**", ".travis.yml",
  "azure-pipelines.yml", "bitbucket-pipelines.yml", ".drone.yml", "action.yml", "action.yaml",
  ".pre-commit-config.yaml", ".husky/**", ".githooks/**", ".gitmodules",
  "**/.claude/**", "**/.mcp.json", "**/.claude-plugin/**",
];
const PLUGIN_MANIFEST = ".claude-plugin/plugin.json";
const REMOTE_CFG_KEY = /^(remote|url)\.|^branch\..+\.(remote|pushremote)$/i;
const REMOTE_CFG_SECTION = /^(remote|url)$|^(remote|url|branch)\./i;
const HOOKS_PATH_KEY = /^core\.hookspath$/i;
const REMOTE_WRITES = new Set(["add", "set-url", "rename", "remove", "rm", "set-head"]);
const CONFIG_OPTS_WITH_ARG = new Set(["-f", "--file", "--blob", "--type", "--default", "--comment", "--value"]);
const CONFIG_READ_FLAGS = new Set(["--get", "--get-all", "--get-regexp", "--get-urlmatch", "--list", "-l", "--show-origin", "--show-scope"]);
const CONFIG_WRITE_FLAGS = new Set(["--unset", "--unset-all", "--replace-all", "--add", "--rename-section", "--remove-section"]);
const PUSH_OPTS_WITH_ARG = new Set(["-o", "--push-option", "--receive-pack", "--exec"]);
const SHORT_GROUP = /^-[A-Za-z0-9]+$/;

const cfgKey = (c) => c.kv.split("=")[0];
const needsOptIn = (inv) =>
  ["push", "remote", "config", "symbolic-ref", "update-ref"].includes(inv.sub) || inv.cfg.some((c) => REMOTE_CFG_KEY.test(cfgKey(c)));

/** Where the hook's own git subprocesses run for this invocation. */
const repoAt = (inv) => (inv.gitDir || inv.workTree ? { cwd: inv.cwd, gitDir: inv.gitDir, workTree: inv.workTree } : inv.cwd);

const currentBranch = (repo) => (tryGit(repo, ["symbolic-ref", "-q", "--short", "HEAD"]) || "").trim() || null;
const configValue = (repo, key) => (tryGit(repo, ["config", "--get", key]) || "").trim() || null;
const configValues = (repo, key) => (tryGit(repo, ["config", "--get-all", key]) || "").split("\n").filter(Boolean);
const shortName = (ref) => ref.replace(/^refs\/heads\//, "");

function branchProtected(conv, name) {
  return name === conv.default.branch || (conv.conventions?.protected_branches ?? []).some((g) => globMatch(g, name));
}

/**
 * `{ src, base, revs, range }` for pushing `src` to origin's `dst`: the commits reachable from `src`
 * and from neither the remote branch nor origin's default branch — what is already on the default
 * branch is never this push's change. Throws when `src` does not resolve.
 */
function pushRange(repo, conv, src, dst) {
  if (tryGit(repo, ["rev-parse", "--verify", "-q", `${src}^{commit}`]) === null) throw new Error(`cannot resolve ${src}`);
  const remoteRef = `refs/remotes/origin/${dst}`;
  const base = refExists(repo, remoteRef) ? remoteRef : conv.default.ref;
  return { src, base, revs: [src, `^${base}`, `^${conv.default.ref}`], range: `${base}..${src} excluding ${conv.default.ref}` };
}

/**
 * Every path touched in the range that the baseline, the team's globs or a plugin's hooks dir
 * protects. A merge counts only paths differing from every parent (dense combined), so what it
 * brings in unchanged is not counted but an edit made inside the merge is.
 */
function protectedHits(repo, conv, r) {
  const out = git(repo, ["log", "--no-renames", "--diff-merges=dense-combined", "--name-only", "-z", "--format=", ...r.revs, "--"]);
  const paths = [...new Set(out.split("\0").map((p) => p.replace(/^\n+/, "")).filter(Boolean))];
  const globs = [...BASELINE_PATHS, ...(conv.conventions?.protected_paths ?? [])].map(globRegExp);
  const pluginDirs = [];
  if (paths.some((p) => /(^|\/)hooks\//.test(p))) {
    for (const rev of [r.src, r.base]) {
      for (const e of git(repo, ["ls-tree", "-r", "--full-tree", "--name-only", "-z", rev]).split("\0")) {
        if (e === PLUGIN_MANIFEST || e.endsWith(`/${PLUGIN_MANIFEST}`)) pluginDirs.push(e.slice(0, -PLUGIN_MANIFEST.length));
      }
    }
  }
  return paths.filter((p) => globs.some((g) => g.test(p)) || pluginDirs.some((d) => p.startsWith(`${d}hooks/`)));
}

function parsePush(args) {
  const flags = [];
  const pos = [];
  let repoOpt = null;
  let options = true;
  for (let k = 0; k < args.length; k++) {
    const a = args[k];
    if (!options || !a.startsWith("-") || a === "-") pos.push(a);
    else if (a === "--") options = false;
    else if (a === "--repo") repoOpt = args[++k] ?? null;
    else if (a.startsWith("--repo=")) repoOpt = a.slice("--repo=".length);
    else if (PUSH_OPTS_WITH_ARG.has(a)) k++;
    else flags.push(a);
  }
  return { flags, remote: pos.length ? pos[0] : repoOpt, refspecs: pos.slice(1) };
}

/** Where a push with no refspec goes under `push.default` (unset means simple); null for `nothing`. */
function defaultDestination(repo, mode, cur) {
  if (mode === "simple" || mode === "current") return { spec: "(none)", src: "HEAD", dst: cur };
  if (mode === "upstream" || mode === "tracking") {
    return { spec: "(none)", src: "HEAD", dst: cur && shortName(configValue(repo, `branch.${cur}.merge`) || cur) };
  }
  if (mode === "nothing") return null;
  throw new Error(`unknown push.default ${mode}`);
}

const srcOf = (spec) => spec.replace(/^\+/, "").split(":")[0];

/** What a `git push` invocation sends: its flags, remote, refspecs, push.default mode, current branch, and `{spec, src, dst}` pairs. */
function pushPlan(inv, repo) {
  const { flags, remote: named, refspecs: given } = parsePush(inv.args);
  const cur = currentBranch(repo);
  const remote =
    named ??
    ((cur && configValue(repo, `branch.${cur}.pushRemote`)) || configValue(repo, "remote.pushDefault") || (cur && configValue(repo, `branch.${cur}.remote`)) || "origin");
  // With no refspec, git pushes remote.<remote>.push if set, else by push.default.
  const refspecs = given.length ? given : configValues(repo, `remote.${remote}.push`);
  const mode = refspecs.length ? null : configValue(repo, "push.default") || "simple";
  const pairs = () =>
    refspecs.length
      ? refspecs.map((spec) => {
          const c = spec.replace(/^\+/, "").indexOf(":");
          const src = srcOf(spec);
          const dst = c >= 0 ? spec.replace(/^\+/, "").slice(c + 1) : src === "HEAD" || src === "@" ? cur : src;
          return { spec, src, dst: dst && shortName(dst) };
        })
      : [defaultDestination(repo, mode, cur)].filter(Boolean);
  return { flags, remote, refspecs, mode, cur, pairs };
}

function pushRule(inv, repo, conv) {
  const { flags, remote, refspecs, mode, pairs: destinations } = pushPlan(inv, repo);
  const flag = (test) => flags.find(test);

  const force =
    flag((f) => ["--force", "--force-with-lease", "--force-if-includes"].includes(f) || f.startsWith("--force-with-lease=") || (SHORT_GROUP.test(f) && f.includes("f"))) ||
    refspecs.find((r) => r.startsWith("+"));
  if (force) return { rule: "PG-FORCE", short: "force push", detail: `flag ${force}` };
  if (flag((f) => f === "--no-verify")) return { rule: "PG-NOVERIFY", short: "--no-verify", detail: "flag --no-verify" };
  const hooksPath = inv.cfg.find((c) => HOOKS_PATH_KEY.test(cfgKey(c)));
  if (hooksPath) return { rule: "PG-NOVERIFY", short: "--no-verify", detail: `${hooksPath.opt} ${cfgKey(hooksPath)}` };
  const del = flag((f) => f === "--delete" || f === "--prune" || (SHORT_GROUP.test(f) && f.includes("d"))) || refspecs.find((r) => r.startsWith(":"));
  if (del) return { rule: "PG-DELETE", short: "branch deletion", detail: `${del.startsWith(":") ? "refspec" : "flag"} ${del}` };
  const tagWord = refspecs.findIndex((r, i) => r === "tag" && i + 1 < refspecs.length);
  const tagName = refspecs.find((r) => {
    const src = srcOf(r);
    return src && !src.startsWith("refs/") && tryGit(repo, ["rev-parse", "--verify", "-q", `refs/tags/${src}`]) !== null;
  });
  const bulkFlag = flag((f) => ["--all", "--branches", "--mirror", "--tags", "--follow-tags"].includes(f));
  const bulkSpec = refspecs.find((r) => r.includes("*") || r.includes("refs/tags/"));
  const bulk =
    (bulkFlag && `flag ${bulkFlag}`) ||
    (bulkSpec && `refspec ${bulkSpec}`) ||
    (tagWord >= 0 && `refspec tag ${refspecs[tagWord + 1]}`) ||
    (tagName && `refspec ${tagName} names a tag`) ||
    (mode === "matching" && "push.default matching");
  if (bulk) return { rule: "PG-BULK", short: "bulk or tag push", detail: bulk };

  if (remote !== "origin") return { rule: "PG-REMOTE", short: "remote other than origin", detail: `remote ${remote}` };

  const pairs = destinations();
  for (const p of pairs) {
    if (!p.dst) return { rule: "PG-BRANCH", short: "unresolved destination", detail: `destination of ${p.spec} unresolved (detached HEAD)` };
    if (branchProtected(conv, p.dst)) return { rule: "PG-BRANCH", short: `protected branch ${p.dst}`, detail: `branch ${p.dst}` };
  }

  const ranges = [];
  const hits = [];
  for (const p of pairs) {
    const r = pushRange(repo, conv, p.src, p.dst);
    ranges.push(r.range);
    hits.push(...protectedHits(repo, conv, r));
  }
  if (hits.length) {
    const more = hits.length > 1 ? ` and ${hits.length - 1} more` : "";
    return { rule: "PG-PATHS", short: `protected path ${hits[0]}${more}`, detail: `paths ${hits.slice(0, 5).join(", ")}`, range: ranges.join(", ") };
  }
  return null;
}

/**
 * The protected key or section a `git config` invocation writes, "edit" for an editor session, or null.
 * Reads never match, and only the key or section is matched — never a value.
 */
function configWrite(args) {
  const words = [];
  let edit = false;
  let write = false;
  let read = false;
  for (let k = 0; k < args.length; k++) {
    const a = args[k];
    if (!a.startsWith("-")) words.push(a);
    else if (CONFIG_OPTS_WITH_ARG.has(a)) k++;
    else if (a === "-e" || a === "--edit") edit = true;
    else if (CONFIG_WRITE_FLAGS.has(a)) write = true;
    else if (CONFIG_READ_FLAGS.has(a)) read = true;
  }
  // rename-section takes two section words, and either one being protected makes it a protected write.
  let keys;
  let section = false;
  if (words[0] === "get" || words[0] === "list") return null;
  if (words[0] === "edit" || edit) return "edit";
  if (["set", "unset", "rename-section", "remove-section"].includes(words[0])) {
    keys = words.slice(1, words[0] === "rename-section" ? 3 : 2);
    section = words[0].endsWith("-section");
  } else if (write) {
    const rename = args.includes("--rename-section");
    keys = words.slice(0, rename ? 2 : 1);
    section = rename || args.includes("--remove-section");
  } else if (read || words.length < 2) return null;
  else keys = [words[0]];
  return keys.find((key) => (section ? REMOTE_CFG_SECTION : REMOTE_CFG_KEY).test(key)) ?? null;
}

function remoteConfigRule(inv) {
  const pos = inv.args.filter((a) => !a.startsWith("-"));
  let what = null;
  const cfg = inv.cfg.find((c) => REMOTE_CFG_KEY.test(cfgKey(c)));
  if (cfg) what = `${cfg.opt} ${cfgKey(cfg)}`;
  else if (inv.sub === "remote" && REMOTE_WRITES.has(pos[0])) what = `git remote ${pos[0]}`;
  else if (inv.sub === "config") {
    const key = configWrite(inv.args);
    if (key) what = `git config ${key}`;
  } else if (inv.sub === "symbolic-ref" || inv.sub === "update-ref") {
    const refs = [];
    for (let k = 0; k < inv.args.length; k++) {
      if (inv.args[k] === "-m") k++;
      else if (!inv.args[k].startsWith("-")) refs.push(inv.args[k]);
    }
    if (refs.length >= 2 && refs[0].startsWith("refs/remotes/")) what = `git ${inv.sub} ${refs[0]}`;
  }
  return what && { rule: "PG-REMOTECFG", short: "remote config change", detail: what };
}

function evaluate(inv, repo, conv) {
  try {
    return (inv.sub === "push" && pushRule(inv, repo, conv)) || remoteConfigRule(inv);
  } catch (err) {
    return { rule: "PG-ERROR", short: "could not verify", detail: `evaluation failed: ${err.message}` };
  }
}

/** `conv` is null for a merge rule, which doesn't depend on the repo's conventions. */
function deny(v, conv) {
  const source = conv && (conv.conventions ? conv.default.ref : "baseline only");
  const detail = [v.detail, v.range && `range ${v.range}`, source && `conventions ${source}`].filter(Boolean).join("; ");
  const reason =
    `ah-push-guard:${v.rule} ${detail}. Do not retry, rephrase, split, or route this ${conv ? "push" : "command"} through another command, script, or agent. ` +
    `In a /pipeline run, follow the autonomous-pipeline skill's handling for ${v.rule}. ` +
    "Otherwise, tell the user that a person can run it from their own terminal if it is intended.";
  const calm = !conv
    ? `ah push-guard stopped a ${v.short} while a /pipeline run is open. Nothing was sent.`
    : v.rule === "PG-REMOTECFG"
      ? `ah push-guard stopped a git remote change (${v.short}).`
      : `ah push-guard stopped a git push (${v.short}). Nothing was sent.`;
  process.stdout.write(
    JSON.stringify({ systemMessage: calm, hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: reason } }),
  );
  process.exit(0);
}

// ---------------------------------------------------------------------------------------------
// Merge rules (while a /pipeline run is open, in any repo).

// `updateRef` matches `updateRefs` too.
const API_MERGE_WORDS = ["mergePullRequest", "mergeBranch", "updateRef", "enablePullRequestAutoMerge", "markPullRequestReadyForReview", "addPullRequestReview", "submitPullRequestReview", "event=APPROVE"];

/** gh's command group and verb: its first two positional words, skipping the repo flag (-R v, -Rv, --repo v, --repo=v) wherever it sits. */
function ghWords(args) {
  const words = [];
  for (let k = 0; k < args.length && words.length < 2; k++) {
    if (args[k] === "-R" || args[k] === "--repo") k++;
    else if (!args[k].startsWith("-")) words.push(args[k]);
  }
  return words;
}

/** `gh api`'s method when one is given (-X v, -Xv, --method v, --method=v), upper-cased; null when gh picks it. */
function apiMethod(args) {
  for (let k = 0; k < args.length; k++) {
    const a = args[k];
    if (a === "-X" || a === "--method") return String(args[k + 1] ?? "").toUpperCase();
    if (a.startsWith("--method=")) return a.slice("--method=".length).toUpperCase();
    if (/^-X./.test(a)) return a.slice(2).toUpperCase();
  }
  return null;
}

function apiRule(args) {
  const text = args.join(" ");
  const method = apiMethod(args);
  const withFields = args.some((a) => /^(-f|-F|--field|--raw-field|--input)(=|$)/.test(a) || /^-[fF]./.test(a));
  const hit =
    /pulls\/[^/\s]+\/(merge|reviews)\b/.exec(text)?.[0] ||
    /repos\/[^/\s]+\/[^/\s]+\/merges\b/.exec(text)?.[0] ||
    (/git\/refs(\/|\b)/.test(text) && ((method && method !== "GET") || withFields) && "a write to git/refs") ||
    API_MERGE_WORDS.find((w) => text.includes(w)) ||
    (ghWords(args)[1] === "graphql" && args.some((a) => a.includes("query=@") || a === "--input" || a.startsWith("--input=")) && "a graphql query the guard can't read");
  return hit ? { rule: "PG-API-MERGE", short: "PR merge or review through the API", detail: `gh api: ${hit}` } : null;
}

function ghRule(args) {
  const [group, verb] = ghWords(args);
  if (group === "api") return apiRule(args);
  if (group !== "pr") return null;
  if (verb === "merge") {
    const flag = args.find((a) => /^--(auto|disable-auto|admin)(=|$)/.test(a));
    return flag
      ? { rule: "PG-AUTOMERGE", short: "PR auto-merge or admin merge", detail: `gh pr merge ${flag}` }
      : { rule: "PG-MERGE", short: "PR merge", detail: "gh pr merge outside the run's pinned, approved merge command" };
  }
  if (verb === "review" && args.some((a) => a === "--approve" || a.startsWith("--approve=") || /^-[A-Za-z]*a[A-Za-z]*$/.test(a))) {
    return { rule: "PG-APPROVE", short: "PR approval", detail: "gh pr review --approve" };
  }
  if (verb === "ready") return { rule: "PG-READY", short: "PR ready", detail: "gh pr ready outside the run's pinned, approved merge command" };
  return null;
}

/** A push to the default or a protected branch, in any repo. The default is origin/HEAD's target; when that can't be resolved, main and master both count. */
function runPushRule(inv) {
  const repo = repoAt(inv);
  if (!(tryGit(repo, ["rev-parse", "--show-toplevel"]) || "").trim()) return null;
  const head = (tryGit(repo, ["symbolic-ref", "-q", "refs/remotes/origin/HEAD"]) || "").trim();
  const defaults = head.startsWith("refs/remotes/origin/") ? [head.slice("refs/remotes/origin/".length)] : ["main", "master"];
  const globs = loadConventions(repo).conventions?.protected_branches ?? [];
  const hit = pushPlan(inv, repo)
    .pairs()
    .find((p) => p.dst && (defaults.includes(p.dst) || globs.some((g) => globMatch(g, p.dst))));
  return hit ? { rule: "PG-RUN-PUSH", short: `push to ${hit.dst}`, detail: `git push to ${hit.dst}, the default or a protected branch, while a /pipeline run is open` } : null;
}

function gitMergeRule(inv) {
  const repo = repoAt(inv);
  if (!(tryGit(repo, ["rev-parse", "--show-toplevel"]) || "").trim()) return null;
  const conv = loadConventions(repo);
  const name = currentBranch(repo);
  if (!conv.default || !name || !branchProtected(conv, name)) return null;
  return { rule: "PG-GIT-MERGE", short: `git ${inv.sub} on ${name}`, detail: `git ${inv.sub} while HEAD is ${name}, the default or a protected branch` };
}

/**
 * No `agent_id`, and either no `agent_type` with a persisted role that is null or orchestrator, or
 * the `ah:orchestrator` agent itself — matched by name, because resolveHierarchyRole maps only the
 * chain roles.
 */
function topLevelOrchestrator(input) {
  if ("agent_id" in input) return false;
  if (input.agent_type) return input.agent_type === "ah:orchestrator";
  const { role } = resolveHierarchyRole(input);
  return role === null || role === "orchestrator";
}

function ask(reason) {
  process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "ask", permissionDecisionReason: reason } }));
  process.exit(0);
}

/** The pinned merge command: the user's permission prompt when every condition holds, else a deny. Never allows. */
function pinnedMerge(input, cwd, form, D) {
  const refuse = (rule, detail) => deny({ rule, short: "PR merge", detail }, null);
  if (!topLevelOrchestrator(input)) refuse("PG-MERGE-ROLE", "the pinned merge command runs only from the run's top-level Orchestrator session");
  // Under bypassPermissions or dontAsk, or with no mode reported, an `ask` may never reach a person.
  if (!PROMPTING_MODES.has(input.permission_mode)) refuse("PG-MERGE", `permission mode ${input.permission_mode || "unreported"} may not show you the merge prompt`);
  const run = D.liveRun(cwd);
  if (!run) refuse("PG-MERGE", "there is no single open /pipeline run to merge under");
  if (run.constraints["merge-opt-in"] !== "yes") refuse("PG-MERGE", "this run has no auto-merge approval (merge-opt-in is not yes)");
  if (form.method !== run.constraints["merge-method"]) refuse("PG-MERGE", `--${form.method} is not this run's merge method (${run.constraints["merge-method"] || "none recorded"})`);
  const log = D.readDecisions(D.decisionLogPath(run.dir, run.id));
  const { line } = D.decisionSummary(log.decisions, log.skipped);
  const top = (tryGit(cwd, ["rev-parse", "--show-toplevel"]) || "").trim();
  // Userinfo in the URL may be a token; it must not reach the prompt or the transcript.
  const origin = top ? (tryGit(top, ["config", "--get", "remote.origin.url"]) || "").trim().replace(/^([a-z][a-z0-9+.-]*:\/\/)[^@/]*@/i, "$1") : "";
  ask(
    `Merge PR #${form.pr} of ${origin || top || cwd} at ${form.sha}${form.draft ? ", marking the draft ready first" : ""} (--${form.method}). ` +
      `/pipeline run ${run.id}, ${line}. Flagged decisions for this PR are in its body under 'Decisions made on your behalf'. ` +
      "Approve only if you want this merged now.",
  );
}

const PROMPTING_MODES = new Set(["default", "auto", "acceptEdits"]);

/**
 * pipelineRunLive for the merge rules, except that a hierarchy dir (or its msgs/) that exists but
 * can't be listed throws: liveness is then unknown, which the rules treat like a live run.
 */
async function runLive(cwd) {
  const { hierarchyDir, pipelineRunLive } = await import("./lib-hier.mjs");
  for (const dir of [hierarchyDir(cwd), mainHierarchyDir(cwd)].filter(Boolean)) {
    for (const d of [dir, join(dir, "msgs")]) if (existsSync(d)) readdirSync(d);
  }
  return pipelineRunLive(cwd);
}

/** Set once mergeGuard has found a run live, so a later failure is denied without asking again. */
let mergeRunLive = false;

/**
 * Denies or asks for any merge-type command while a run is open: live for the session's cwd or any
 * merge-type invocation's own directory. Returns when the command isn't one, or no run is live.
 */
async function mergeGuard(input, command, cwd, invs, ghs) {
  const gitOps = invs.filter((inv) => inv.sub === "merge" || inv.sub === "pull" || inv.sub === "push");
  if (!ghs.length && !gitOps.length) return;
  const dirs = [...new Set([cwd, ...ghs.map((g) => g.cwd), ...gitOps.map((inv) => inv.cwd)])];
  const live = [];
  for (const dir of dirs) live.push(await runLive(dir));
  if (!live.some(Boolean)) return;
  mergeRunLive = true;
  const D = await import("./lib-decisions.mjs");
  const form = D.parseMergeForm(command);
  if (form) pinnedMerge(input, cwd, form, D);
  for (const g of ghs) {
    const v = ghRule(g.args);
    if (v) deny(v, null);
  }
  for (const inv of gitOps) {
    const v = inv.sub === "push" ? runPushRule(inv) : gitMergeRule(inv);
    if (v) deny(v, null);
  }
}

/** The raw text names a merge-type command, so the test holds even when parsing threw: `gh` with merge, review, ready or api; `git` with merge, pull or push. */
const mergeRelated = (c) =>
  (c.includes("gh") && ["merge", "review", "ready", "api"].some((w) => c.includes(w))) || (c.includes("git") && ["merge", "pull", "push"].some((w) => c.includes(w)));

/** The merge rules threw on a merge-related command: deny while a run is live or liveness is unknown, never ask or allow; stay silent when no run is live. */
async function mergeError(cwd, err) {
  let live = mergeRunLive;
  if (!live) {
    try {
      live = await runLive(cwd);
    } catch {
      live = true;
    }
  }
  if (live) deny({ rule: "PG-MERGE-ERROR", short: "PR merge or push the guard couldn't check", detail: `the merge rules failed: ${err && err.message ? err.message : String(err)}` }, null);
}

// ---------------------------------------------------------------------------------------------

function check(argv) {
  const opt = (name) => {
    const k = argv.indexOf(name);
    return k >= 0 ? argv[k + 1] : undefined;
  };
  try {
    const branch = opt("--branch");
    const cwd = opt("--cwd");
    if (!branch || !cwd) throw new Error("usage: pretooluse-push-guard.mjs check --branch <name> --cwd <abs>");
    const repo = (tryGit(cwd, ["rev-parse", "--show-toplevel"]) || "").trim();
    if (!repo) throw new Error(`not a git repository: ${cwd}`);
    const conv = loadConventions(repo);
    const out = {
      opted_in: conv.opted_in,
      default_branch: conv.default ? conv.default.branch : null,
      conventions: conv.status,
      range: null,
      protected_hits: [],
      branch_protected: false,
      settings: conventionSettings(conv),
    };
    const name = branch === "HEAD" ? currentBranch(repo) : shortName(branch);
    if (conv.opted_in && name) {
      const r = pushRange(repo, conv, name, name);
      out.range = r.range;
      out.protected_hits = protectedHits(repo, conv, r);
      out.branch_protected = branchProtected(conv, name);
    }
    process.stdout.write(`${JSON.stringify(out)}\n`);
    process.exit(0);
  } catch (err) {
    process.stdout.write(`${JSON.stringify({ error: err.message })}\n`);
    process.exit(1);
  }
}

const gh = (cwd, args) => JSON.parse(execFileSync("gh", args, { cwd, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }));
const CHECK_OK = new Set(["SUCCESS", "NEUTRAL", "SKIPPED"]);
const REVIEW_THREADS_QUERY =
  "query($owner: String!, $name: String!, $number: Int!) { repository(owner: $owner, name: $name) { pullRequest(number: $number) { reviewThreads(first: 100) { totalCount nodes { isResolved } } } } }";

/**
 * Read-only: whether the open run may offer PR <N> for a pinned merge, as
 * `{ ok, pr, sha, method, reasons, command }`. Advisory only — the user's click on the permission
 * prompt is the approval, and the hook never requires this ran.
 */
async function mergeCheck(argv) {
  const opt = (name) => {
    const k = argv.indexOf(name);
    return k >= 0 ? argv[k + 1] : undefined;
  };
  try {
    const pr = Number(opt("--pr"));
    const cwd = opt("--cwd");
    if (!Number.isInteger(pr) || pr < 1 || !cwd) throw new Error("usage: pretooluse-push-guard.mjs merge-check --pr <N> --cwd <abs>");
    const repo = (tryGit(cwd, ["rev-parse", "--show-toplevel"]) || "").trim();
    if (!repo) throw new Error(`not a git repository: ${cwd}`);
    const D = await import("./lib-decisions.mjs");
    const { listExchanges, readMsgFile } = await import("./lib-hier.mjs");
    const result = (reasons, sha = null, method = null, draft = false) => {
      process.stdout.write(`${JSON.stringify({ ok: reasons.length === 0, pr, sha, method, reasons, command: sha && method ? D.mergeCommand(pr, sha, method, draft) : null })}\n`);
      process.exit(0);
    };
    const run = D.liveRun(repo);
    if (!run) result(["no-run"]);
    const method = D.MERGE_METHODS.includes(run.constraints["merge-method"]) ? run.constraints["merge-method"] : null;
    const reasons = [];
    if (run.constraints["merge-opt-in"] !== "yes") reasons.push("off");
    if (!method) reasons.push("no-method");

    const view = gh(repo, ["pr", "view", String(pr), "--json", "state,isDraft,headRefName,headRefOid,baseRefName,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup"]);
    const tag = run.constraints["run-tag"];
    const issue = /^ah\/issue-([1-9][0-9]*)$/.exec(view.headRefName || "")?.[1];
    const exchanges = listExchanges(run.dir);
    const record = tag && issue ? exchanges.find((e) => e.open && e.slug === `${tag}-i${issue}`) : null;
    if (!record) reasons.push("not-this-run");
    else {
      if (!exchanges.some((e) => !e.open && e.slug === `${tag}-i${issue}-ok`)) reasons.push("not-signed-off");
      if (exchanges.some((e) => e.open && e.slug === `${tag}-i${issue}-x`)) reasons.push("exception");
    }

    if (view.state !== "OPEN") reasons.push("closed");
    else if (!issue || (tryGit(repo, ["rev-parse", "--verify", "-q", `refs/heads/ah/issue-${issue}`]) || "").trim() !== view.headRefOid) reasons.push("head-moved");

    const dependsOn = record ? D.constraintLines((readMsgFile(record.request.path) || {}).text || "")["depends-on"] : null;
    if (dependsOn && /^[1-9][0-9]*$/.test(dependsOn)) {
      const bases = gh(repo, ["pr", "list", "--head", `ah/issue-${dependsOn}`, "--state", "all", "--json", "number,state"]);
      if (!bases.some((b) => b.state === "MERGED")) reasons.push("stacked-base-open");
    }
    const defaultBranch = run.constraints["default-branch"] || (loadConventions(repo).default || {}).branch;
    if (view.baseRefName !== defaultBranch) reasons.push("base-not-default");

    const mergeable = view.mergeable === "MERGEABLE" && (view.mergeStateStatus === "CLEAN" || (view.isDraft && view.mergeStateStatus === "DRAFT"));
    if (!mergeable) reasons.push(`not-mergeable:${view.mergeable !== "MERGEABLE" ? view.mergeable : view.mergeStateStatus}`);

    const checks = Array.isArray(view.statusCheckRollup) ? view.statusCheckRollup : [];
    const verdict = (c) =>
      c.__typename === "StatusContext" || ("state" in c && !("status" in c))
        ? c.state === "SUCCESS" ? "ok" : c.state === "PENDING" || c.state === "EXPECTED" ? "pending" : "failed"
        : c.status !== "COMPLETED" ? "pending" : CHECK_OK.has(c.conclusion) ? "ok" : "failed";
    if (!checks.length) reasons.push("no-checks");
    else if (checks.some((c) => verdict(c) === "failed")) reasons.push("checks-failed");
    else if (checks.some((c) => verdict(c) === "pending")) reasons.push("checks-pending");

    if (view.reviewDecision === "CHANGES_REQUESTED") reasons.push("changes-requested");
    const threads = gh(repo, ["api", "graphql", "-f", `query=${REVIEW_THREADS_QUERY}`, "-F", "owner={owner}", "-F", "name={repo}", "-F", `number=${pr}`]).data.repository.pullRequest.reviewThreads;
    if (threads.totalCount > 100 || threads.nodes.some((t) => !t.isResolved)) reasons.push("unresolved-threads");

    result(reasons, view.headRefOid, method, view.isDraft === true);
  } catch (err) {
    process.stdout.write(`${JSON.stringify({ error: err.message })}\n`);
    process.exit(1);
  }
}

async function main() {
  const input = await readHookInput();
  const command = input.tool_input && typeof input.tool_input.command === "string" ? input.tool_input.command : "";
  if (input.tool_name !== "Bash" || !(command.includes("git") || command.includes("gh"))) return;
  const cwd = typeof input.cwd === "string" && input.cwd ? input.cwd : process.cwd();
  const ghs = [];
  let invs;
  try {
    invs = gitInvocations(parseShell(command).events, { cwd, stack: [] }, cwd, [], ghs);
    await mergeGuard(input, command, cwd, invs, ghs);
  } catch (err) {
    if (mergeRelated(command)) await mergeError(cwd, err);
    throw err;
  }
  for (const inv of invs) {
    if (!needsOptIn(inv)) continue;
    const repo = repoAt(inv);
    if (!(tryGit(repo, ["rev-parse", "--show-toplevel"]) || "").trim()) continue;
    const conv = loadConventions(repo);
    if (!conv.opted_in) continue;
    const verdict = evaluate(inv, repo, conv);
    if (verdict) deny(verdict, conv);
  }
}

if (process.argv[2] === "check") check(process.argv.slice(3));
else if (process.argv[2] === "merge-check") await mergeCheck(process.argv.slice(3));
else {
  try {
    await main();
  } catch (err) {
    logHookError("pretooluse-push-guard.mjs", err);
  }
  process.exit(0);
}
