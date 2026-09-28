#!/usr/bin/env node
// agent-hierarchy — PreToolUse push guard (Bash). Stateless and always on, but only in repos that
// commit `.claude/ah-conventions.json` on origin's default branch; inert everywhere else.
//
// In an opted-in repo it denies force pushes, --no-verify, deletions, bulk and tag pushes, pushes to a
// remote other than origin, pushes to the default or a protected branch, pushes whose range touches
// a protected path, and edits to remote configuration. Errors before opt-in is established allow;
// errors after it fail closed (PG-ERROR).
//
// It matches command text, so it stops a compliant model following an injected instruction, not an
// adversarial one: shell expansion, command text fed to a shell as data, other programs that run
// git, git aliases, non-literal paths and the GitHub API all get past it. See
// docs/pipeline-conventions.md.
//
// CLI mode, the same evaluation without a push:
//   node pretooluse-push-guard.mjs check --branch <name> --cwd <abs>

import { resolve } from "node:path";
import { logHookError, readHookInput } from "./lib-config.mjs";
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
function gitInvocations(events, state, root, out = []) {
  const copy = (cwd) => ({ cwd, stack: [...state.stack] });
  for (const ev of events) {
    if (ev.sub) {
      gitInvocations(ev.sub, copy(state.cwd), root, out);
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
      if (dashC && j < args.length) gitInvocations(parseShell(args[j]).events, copy(here), root, out);
    } else if (name === "eval") {
      gitInvocations(parseShell(args.join(" ")).events, copy(here), root, out);
    } else if (basename(name) === "git") {
      out.push(gitInvocation(args, here, env));
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

function pushRule(inv, repo, conv) {
  const { flags, remote: named, refspecs: given } = parsePush(inv.args);
  const flag = (test) => flags.find(test);
  const cur = currentBranch(repo);
  const remote =
    named ??
    ((cur && configValue(repo, `branch.${cur}.pushRemote`)) || configValue(repo, "remote.pushDefault") || (cur && configValue(repo, `branch.${cur}.remote`)) || "origin");
  // With no refspec, git pushes remote.<remote>.push if set, else by push.default.
  const refspecs = given.length ? given : configValues(repo, `remote.${remote}.push`);
  const mode = refspecs.length ? null : configValue(repo, "push.default") || "simple";
  const srcOf = (spec) => spec.replace(/^\+/, "").split(":")[0];

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

  const pairs = refspecs.length
    ? refspecs.map((spec) => {
        const c = spec.replace(/^\+/, "").indexOf(":");
        const src = srcOf(spec);
        const dst = c >= 0 ? spec.replace(/^\+/, "").slice(c + 1) : src === "HEAD" || src === "@" ? cur : src;
        return { spec, src, dst: dst && shortName(dst) };
      })
    : [defaultDestination(repo, mode, cur)].filter(Boolean);
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

function deny(v, conv) {
  const source = conv.conventions ? conv.default.ref : "baseline only";
  const detail = [v.detail, v.range && `range ${v.range}`, `conventions ${source}`].filter(Boolean).join("; ");
  const reason =
    `ah-push-guard:${v.rule} ${detail}. Do not retry, rephrase, split, or route this push through another command, script, or agent. ` +
    `In a /pipeline run, follow the autonomous-pipeline skill's handling for ${v.rule}. ` +
    "Otherwise, tell the user that a person can run it from their own terminal if it is intended.";
  const calm =
    v.rule === "PG-REMOTECFG"
      ? `ah push-guard stopped a git remote change (${v.short}).`
      : `ah push-guard stopped a git push (${v.short}). Nothing was sent.`;
  process.stdout.write(
    JSON.stringify({ systemMessage: calm, hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: reason } }),
  );
  process.exit(0);
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

async function main() {
  const input = await readHookInput();
  const command = input.tool_input && typeof input.tool_input.command === "string" ? input.tool_input.command : "";
  if (input.tool_name !== "Bash" || !command.includes("git")) return;
  const cwd = typeof input.cwd === "string" && input.cwd ? input.cwd : process.cwd();
  for (const inv of gitInvocations(parseShell(command).events, { cwd, stack: [] }, cwd)) {
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
else {
  try {
    await main();
  } catch (err) {
    logHookError("pretooluse-push-guard.mjs", err);
  }
  process.exit(0);
}
