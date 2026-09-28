// Team conventions: `.claude/ah-conventions.json`, read from the committed blob on origin's default
// branch, never from the working tree — an agent can edit the working tree freely, while the default
// branch changes only through a push the push guard denies. The one parser for the file: the push
// guard, its `check` mode and the intake CLI all read conventions through here.

import { execFileSync } from "node:child_process";

export const CONVENTIONS_PATH = ".claude/ah-conventions.json";

/**
 * stdout of git run at `at` — a directory, or `{ cwd, gitDir, workTree }` for a command that named
 * its repo with --git-dir/--work-tree/GIT_DIR. Throws on a non-zero exit or when git is missing.
 */
export function git(at, args) {
  const scope =
    typeof at === "string"
      ? ["-C", at]
      : ["-C", at.cwd, ...(at.gitDir ? [`--git-dir=${at.gitDir}`] : []), ...(at.workTree ? [`--work-tree=${at.workTree}`] : [])];
  return execFileSync("git", [...scope, ...args], { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
}

/** Like git(), but null instead of throwing. */
export function tryGit(dir, args) {
  try {
    return git(dir, args);
  } catch {
    return null;
  }
}

export const refExists =(repo, ref) => tryGit(repo, ["rev-parse", "--verify", "-q", `${ref}^{commit}`]) !== null;

/**
 * `{ ref, branch }` for origin's default branch — `refs/remotes/origin/HEAD` by its symbolic target,
 * else `refs/remotes/origin/main`, else `refs/remotes/origin/master` — or null when none resolves.
 * Never fetches.
 */
export function originDefault(repo) {
  const target = tryGit(repo, ["symbolic-ref", "-q", "refs/remotes/origin/HEAD"]);
  const candidates = [target && target.trim(), "refs/remotes/origin/main", "refs/remotes/origin/master"];
  for (const ref of candidates) {
    if (ref && ref.startsWith("refs/remotes/origin/") && refExists(repo, ref)) {
      return { ref, branch: ref.slice("refs/remotes/origin/".length) };
    }
  }
  return null;
}

const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const nonEmptyString = (v) => typeof v === "string" && v.length > 0;
const stringArray = (v) => Array.isArray(v) && v.every(nonEmptyString);

const SCHEMA = {
  version: (v) => v === 1 || "`version` must be the integer 1",
  issues: {
    trigger_label: (v) => nonEmptyString(v) || "`issues.trigger_label` must be a non-empty string",
    trusted_actors: (v) => stringArray(v) || "`issues.trusted_actors` must be an array of logins",
  },
  pr: {
    draft: (v) => typeof v === "boolean" || "`pr.draft` must be a boolean",
    issue_link: (v) => v === "refs" || v === "closes" || '`pr.issue_link` must be "refs" or "closes"',
    reviewers: (v) => stringArray(v) || "`pr.reviewers` must be an array of logins or org/team names",
  },
  ci_secrets: (v) => v === "none-on-branches" || v === "skip-ci" || '`ci_secrets` must be "none-on-branches" or "skip-ci"',
  protected_paths: (v) => stringArray(v) || "`protected_paths` must be an array of globs",
  protected_branches: (v) => stringArray(v) || "`protected_branches` must be an array of globs",
  on_item_done: (v) => nonEmptyString(v) || "`on_item_done` must be a skill name",
};

function violation(obj, schema, prefix) {
  if (!isObj(obj)) return prefix ? `\`${prefix.slice(0, -1)}\` must be an object` : "the file must hold a JSON object";
  for (const [key, value] of Object.entries(obj)) {
    const rule = schema[key];
    if (!rule) return `unknown key \`${prefix}${key}\``;
    const why = typeof rule === "function" ? rule(value) : violation(value, rule, `${prefix}${key}.`);
    if (typeof why === "string") return why;
  }
  return null;
}

/** Why `obj` breaks schema version 1, or null when it is valid. Unknown keys at any level are violations. */
export function validateConventions(obj) {
  if (isObj(obj) && !("version" in obj)) return "`version` is required";
  return violation(obj, SCHEMA, "");
}

/**
 * The repo's conventions as committed on origin's default branch:
 * `{ opted_in, default: {ref, branch}|null, status: "ok"|"absent"|"invalid: <why>", conventions }`.
 * `conventions` is the parsed file when valid, else null — an invalid file still opts the repo in,
 * with the baseline protections only.
 */
export function loadConventions(repo) {
  const def = originDefault(repo);
  const absent = { opted_in: false, default: def, status: "absent", conventions: null };
  if (!def) return absent;
  const blob = `${def.ref}:${CONVENTIONS_PATH}`;
  if (tryGit(repo, ["cat-file", "-e", blob]) === null) return absent;
  let parsed;
  try {
    parsed = JSON.parse(git(repo, ["cat-file", "blob", blob]));
  } catch (err) {
    return { opted_in: true, default: def, status: `invalid: ${err.message}`, conventions: null };
  }
  const why = validateConventions(parsed);
  return why
    ? { opted_in: true, default: def, status: `invalid: ${why}`, conventions: null }
    : { opted_in: true, default: def, status: "ok", conventions: parsed };
}

/**
 * The team settings of a `loadConventions` result with the schema defaults applied, or null unless its
 * status is "ok". `version` and `issues` are left out: intake owns `issues`, and the `trusted_actors`
 * default needs a GitHub lookup. The protected lists are the file's own extensions, never the baseline.
 */
export function conventionSettings(loaded) {
  if (loaded.status !== "ok") return null;
  const c = loaded.conventions;
  const pr = c.pr ?? {};
  return {
    pr: { draft: pr.draft ?? true, issue_link: pr.issue_link ?? "refs", reviewers: pr.reviewers ?? [] },
    ci_secrets: c.ci_secrets ?? "none-on-branches",
    protected_paths: c.protected_paths ?? [],
    protected_branches: c.protected_branches ?? [],
    on_item_done: c.on_item_done ?? null,
  };
}

/**
 * A conventions glob as an anchored RegExp over repo-relative POSIX paths or branch short names:
 * `*` and `?` never cross `/`, a whole `**` segment spans zero or more segments, everything else
 * is literal.
 */
export function globRegExp(pattern) {
  const segs = pattern.split("/");
  let re = "";
  segs.forEach((seg, i) => {
    const first = i === 0;
    const last = i === segs.length - 1;
    if (seg === "**") {
      if (first && last) re += ".*";
      else if (first) re += "(?:[^/]+/)*";
      else if (last) re += "(?:/.*)?";
      else re += "/(?:[^/]+/)*";
      return;
    }
    if (!first && segs[i - 1] !== "**") re += "/";
    re += seg.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, "[^/]*").replace(/\?/g, "[^/]");
  });
  return new RegExp(`^${re}$`);
}

export const globMatch = (pattern, text) => globRegExp(pattern).test(text);
