#!/usr/bin/env node
// Issue intake: decides which GitHub issues are eligible pipeline input and writes a sanitized snapshot
// of each eligible one. Eligibility is decided from metadata alone, so no title, body or comment body is
// ever fetched for an issue that fails it. An eligible issue's title and rendered HTML (never its raw
// markdown) are fetched once together with its metadata again; the issue must still pass the same
// checks, unedited, or it is dropped. The snapshot holds the rendered HTML's visible text only, screened
// for hidden content, in `<out-dir>/issue-<N>.md`. All GitHub I/O goes through `gh`, whose output never
// reaches stdout.
// Interface and output: docs/cli-tools.md.

import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { parseArgs } from "node:util";
import { logHookError } from "./lib-config.mjs";
import { CONVENTIONS_PATH, loadConventions, tryGit } from "./lib-conventions.mjs";

const USAGE = `usage: node issue-intake.mjs --cwd <abs> --out-dir <abs> (--issues <ref,ref,...> | --labelled)
  <ref>       N, #N or https://github.com/<o>/<r>/issues/N; given order kept, duplicates dropped
  --labelled  every open issue carrying issues.trigger_label, in ascending number
Prints one JSON object {repo, trigger_label, trusted_actors, items}, exit 0;
a run-level failure prints {"error": "<code>: <detail>"}, exit 1.
`;

/** A run-level failure. `detail` is printed; `diag`, when present, goes only to the hook error log. */
class Fail extends Error {
  constructor(code, detail, diag) {
    super(`${code}: ${detail}`);
    this.diag = diag;
  }
}

const firstLine = (s) => String(s || "").trim().split("\n")[0];

/** intake-failed with fixed printed text; the log gets gh's exit status and its first stderr line. */
const ghFailed = (detail, r) => new Fail("intake-failed", detail, `${detail}: gh exit ${r.status}: ${firstLine(r.err).slice(0, 200)}`);

const GITHUB_REMOTE = /^(?:https:\/\/(?:[^@/]+@)?github\.com\/|git@github\.com:|ssh:\/\/git@github\.com\/)([^/]+)\/([^/]+?)(?:\.git)?\/?$/i;
const ISSUE_URL = /^https:\/\/github\.com\/([^/]+)\/([^/]+)\/issues\/(\d+)\/?$/i;

const HIDDEN_CHARS = /[\u061C\u200B-\u200F\u2028-\u202E\u2060-\u206F\uFEFF\u{E0000}-\u{E007F}\u{E0100}-\u{E01EF}]/u;
// A ZWJ between pictographs (the first optionally followed by VS16 or a skin-tone modifier) only joins
// an emoji sequence and carries no payload.
const EMOJI_ZWJ = /(?<=\p{Extended_Pictographic}(?:\uFE0F|[\u{1F3FB}-\u{1F3FF}])?)\u200D(?=\p{Extended_Pictographic})/gu;
// Line breaks a consumer might split on, beyond LF: in the title each becomes a space, in content an LF.
const TITLE_BREAKS = /\r\n|[\r\n\u{B}\u{C}\u{85}]/gu;
const CONTENT_BREAKS = /\r\n|[\r\u{B}\u{C}\u{85}]/gu;

const VOID_ELEMENTS = new Set(["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"]);
// Elements a browser does not show the text of; dropped whole whether or not GitHub's sanitizer keeps them.
const DROPPED_ELEMENTS = new Set([
  "template", "noscript", "script", "style", "rp", "video", "audio", "object", "canvas",
  "iframe", "noembed", "noframes", "datalist", "dialog", "title",
]);
const LINE_ELEMENTS = new Set(["div", "li", "tr", "dt", "dd"]);
const BLOCK_ELEMENTS = new Set(["p", "pre", "blockquote", "ul", "ol", "table", "hr", "h1", "h2", "h3", "h4", "h5", "h6"]);
const ENTITY = /&(#[0-9]+|#[xX][0-9a-fA-F]+|amp|lt|gt|quot|apos|nbsp);/g;
const NAMED_ENTITIES = { amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " " };
const ATTRIBUTE = /([^\s"'=<>/]+)(?:\s*=\s*("[^"]*"|'[^']*'|[^\s"'=<>`]+))?/g;

const OWNER_QUERY = `query IntakeOwner($owner: String!, $name: String!) {
  repository(owner: $owner, name: $name) { owner { __typename login } }
}`;

const LABELLED_QUERY = `query IntakeLabelled($owner: String!, $name: String!, $label: String!, $after: String) {
  repository(owner: $owner, name: $name) {
    issues(first: 100, after: $after, states: OPEN, labels: [$label]) {
      nodes { number }
      pageInfo { hasNextPage endCursor }
    }
  }
}`;

// The metadata the eligibility checks read; no title, body or comment body. The timeline window is the
// latest 100 events, so the latest trigger-label event and every rename after it are always inside it,
// or the label event is missing and the issue fails closed.
const ISSUE_METADATA = `
      state
      lastEditedAt
      labels(first: 100) { nodes { name } }
      timelineItems(last: 100, itemTypes: [LABELED_EVENT, RENAMED_TITLE_EVENT]) {
        nodes {
          __typename
          ... on LabeledEvent { createdAt actor { login } label { name } }
          ... on RenamedTitleEvent { createdAt }
        }
      }`;

// The newest 100 comments; older ones are never considered, which can only drop a comment.
const META_QUERY = `query IntakeMeta($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    issue(number: $number) {${ISSUE_METADATA}
      comments(last: 100) { nodes { id author { login } createdAt lastEditedAt } }
    }
  }
}`;

const FETCH_QUERY = `query IntakeFetch($owner: String!, $name: String!, $number: Int!, $ids: [ID!]!) {
  repository(owner: $owner, name: $name) {
    issue(number: $number) {
      title
      bodyHTML${ISSUE_METADATA}
    }
  }
  nodes(ids: $ids) { ... on IssueComment { id bodyHTML lastEditedAt } }
}`;

/** `{ status, out, err }` of one gh call. Throws `gh-unavailable` when gh is not installed. */
function gh(args, input) {
  try {
    const out = execFileSync("gh", args, { input, encoding: "utf8", stdio: ["pipe", "pipe", "pipe"], maxBuffer: 64 << 20 });
    return { status: 0, out, err: "" };
  } catch (err) {
    if (err.code === "ENOENT") throw new Fail("gh-unavailable", "gh is not installed");
    return { status: err.status ?? null, out: err.stdout || "", err: err.stderr || "" };
  }
}

/**
 * One GraphQL request: `{ data, status, err }`. gh exits non-zero whenever the response carries errors
 * (a missing issue, a deleted comment id) while still printing the body, so callers judge by `data`.
 */
function graphql(query, variables) {
  const r = gh(["api", "graphql", "--input", "-"], JSON.stringify({ query, variables }));
  let data = null;
  try {
    data = JSON.parse(r.out).data ?? null;
  } catch {}
  return { data, status: r.status, err: r.err };
}

/**
 * The issue in a GraphQL answer; null when GitHub says it does not exist (a present repository with a
 * null issue, or, with no parseable answer, gh's "Could not resolve to an Issue"). Anything else,
 * including a null repository, throws intake-failed.
 */
function answeredIssue(r, detail) {
  const repository = r.data?.repository;
  if (repository?.issue) return repository.issue;
  if (repository ? repository.issue === null : !r.data && /Could not resolve to an? Issue/i.test(r.err)) return null;
  throw ghFailed(detail, r);
}

/** Every connection is present and holds no null node; a partial GraphQL error leaves one missing. */
const complete = (...connections) => connections.every((c) => Array.isArray(c?.nodes) && c.nodes.every(Boolean));

function ownerActors(owner, name) {
  const r = graphql(OWNER_QUERY, { owner, name });
  const own = r.data?.repository?.owner;
  if (!own) throw ghFailed("reading the repo owner failed", r);
  if (own.__typename !== "User") {
    throw new Fail("org-needs-trusted-actors", `${own.login} is an organization; set issues.trusted_actors in ${CONVENTIONS_PATH}`);
  }
  return [own.login];
}

function labelledNumbers(owner, name, label) {
  const numbers = [];
  let after = null;
  do {
    const r = graphql(LABELLED_QUERY, { owner, name, label, after });
    const conn = r.data?.repository?.issues;
    if (!complete(conn)) throw ghFailed("listing labelled issues failed", r);
    numbers.push(...conn.nodes.map((n) => n.number));
    after = conn.pageInfo.hasNextPage ? conn.pageInfo.endCursor : null;
  } while (after);
  return numbers.sort((a, b) => a - b);
}

/** `[{ number, other }]` in the given order, duplicates dropped. `other` marks a ref to another repo. */
function parseRefs(list, repo) {
  const seen = new Set();
  const refs = [];
  for (const ref of list.split(",").map((s) => s.trim()).filter(Boolean)) {
    let key;
    let item;
    const local = /^#?(\d+)$/.exec(ref);
    const url = ISSUE_URL.exec(ref);
    if (local) {
      item = { number: Number(local[1]), other: false };
    } else if (url) {
      const refRepo = `${url[1]}/${url[2]}`.toLowerCase();
      item = { number: Number(url[3]), other: refRepo !== repo.toLowerCase() };
      if (item.other) key = `${refRepo}#${item.number}`;
    } else {
      throw new Fail("usage", `not an issue ref: ${ref}`);
    }
    key ??= `#${item.number}`;
    if (!seen.has(key)) {
      seen.add(key);
      refs.push(item);
    }
  }
  return refs;
}

const time = (iso) => Date.parse(iso);

/**
 * The eligibility checks over one read of an issue's metadata: `{ reason }` for the first that fails,
 * else `{ labelled, at }`; the latest trigger-label event and its time.
 */
function gate(issue, label, trusts) {
  if (issue.state !== "OPEN") return { reason: "closed" };
  if (!issue.labels.nodes.some((l) => l.name === label)) return { reason: "no-trigger-label" };
  const events = issue.timelineItems.nodes;
  const labelled = events
    .filter((e) => e.__typename === "LabeledEvent" && e.label?.name === label)
    .reduce((latest, e) => (!latest || time(e.createdAt) >= time(latest.createdAt) ? e : latest), null);
  if (!labelled || !trusts(labelled.actor?.login)) return { reason: "untrusted-labeler" };
  const at = time(labelled.createdAt);
  const renamedAfter = events.some((e) => e.__typename === "RenamedTitleEvent" && time(e.createdAt) > at);
  if ((issue.lastEditedAt && time(issue.lastEditedAt) > at) || renamedAfter) return { reason: "edited-after-label" };
  return { labelled, at };
}

const hiddenChars = (text) => HIDDEN_CHARS.test(text.replace(EMOJI_ZWJ, ""));

function decodeEntities(text) {
  return text.replace(ENTITY, (_, ref) => {
    if (ref[0] !== "#") return NAMED_ENTITIES[ref];
    const cp = ref[1] === "x" || ref[1] === "X" ? parseInt(ref.slice(2), 16) : parseInt(ref.slice(1), 10);
    return cp > 0 && cp <= 0x10ffff && (cp < 0xd800 || cp > 0xdfff) ? String.fromCodePoint(cp) : "\u{FFFD}";
  });
}

/** Index of the `>` ending the tag that opens at `from`, skipping quoted attribute values; -1 if none. */
function tagEnd(html, from) {
  let quote = null;
  for (let i = from + 1; i < html.length; i++) {
    const ch = html[i];
    if (quote) {
      if (ch === quote) quote = null;
    } else if (ch === '"' || ch === "'") {
      quote = ch;
    } else if (ch === ">") {
      return i;
    }
  }
  return -1;
}

/** `{ end, name, attrs, selfClosing }` for the text between `<` and `>`, or null when it names no element. */
function parseTag(raw) {
  const head = /^(\/?)\s*([A-Za-z][^\s/>]*)/.exec(raw);
  if (!head) return null;
  const attrs = new Map();
  for (const a of raw.slice(head[0].length).matchAll(ATTRIBUTE)) {
    attrs.set(a[1].toLowerCase(), (a[2] ?? "").replace(/^(["'])([\s\S]*)\1$/, "$2"));
  }
  return { end: head[1] === "/", name: head[2].toLowerCase(), attrs, selfClosing: /\/\s*$/.test(raw) };
}

/**
 * The text a reader sees in GitHub's rendered HTML, and whether it holds a details/summary start tag.
 * Every `<` in that HTML is markup: comments are dropped, a tag is dropped with all its attributes, and
 * DROPPED_ELEMENTS subtrees and elements carrying `hidden` are dropped whole. Anything
 * unterminated drops everything after it. Layout follows a browser: whitespace collapses outside `pre`,
 * adjacent block boundaries merge into the larger break, and lists, headings, table cells, checkboxes
 * and images get plain-text markers.
 */
function visibleText(html) {
  let out = "";
  let breaks = 0;
  let prefix = "";
  let pre = 0;
  let skip = null;
  let collapsed = false;
  let firstCell = false;
  const lists = [];

  const need = (n) => {
    breaks = Math.max(breaks, n);
  };
  const emit = (s, verbatim) => {
    if (!verbatim && (breaks || out === "" || /[ \n]$/.test(out))) s = s.replace(/^ /, "");
    if (s === "") return;
    if (breaks && out !== "") {
      out = out.replace(/ +$/, "");
      out += "\n".repeat(Math.max(0, breaks - /\n*$/.exec(out)[0].length));
    }
    breaks = 0;
    out += prefix + s;
    prefix = "";
  };
  const text = (raw) => {
    if (skip || raw === "") return;
    const decoded = decodeEntities(raw);
    if (pre) emit(decoded, true);
    else emit(decoded.replace(/[ \t\n\r\f]+/g, " "), false);
  };
  const layout = ({ end, name, attrs }) => {
    if (name === "pre") pre = Math.max(0, pre + (end ? -1 : 1));
    if (BLOCK_ELEMENTS.has(name)) need(2);
    else if (LINE_ELEMENTS.has(name)) need(1);
    if (end) {
      if (name === "ul" || name === "ol") lists.pop();
      if (name === "li" || /^h[1-6]$/.test(name)) prefix = "";
      return;
    }
    if (name === "ul" || name === "ol") {
      lists.push({ ordered: name === "ol", n: 0 });
    } else if (name === "li") {
      const list = lists.at(-1);
      if (list) prefix = list.ordered ? `${++list.n}. ` : "- ";
    } else if (/^h[1-6]$/.test(name)) {
      prefix = `${"#".repeat(Number(name[1]))} `;
    } else if (name === "tr") {
      firstCell = true;
    } else if (name === "td" || name === "th") {
      if (!firstCell) emit(" | ", false);
      firstCell = false;
    } else if (name === "input" && attrs.get("type")?.toLowerCase() === "checkbox") {
      emit(attrs.has("checked") ? "[x] " : "[ ] ", false);
    } else if (name === "img") {
      emit("[image]", false);
    } else if (name === "br") {
      emit("\n", true);
    }
  };

  for (let i = 0; i < html.length; ) {
    const lt = html.indexOf("<", i);
    text(html.slice(i, lt < 0 ? html.length : lt));
    if (lt < 0) break;
    if (html.startsWith("<!--", lt)) {
      const close = html.indexOf("-->", lt + 4);
      if (close < 0) break;
      i = close + 3;
      continue;
    }
    const close = tagEnd(html, lt);
    if (close < 0) break;
    i = close + 1;
    const tag = parseTag(html.slice(lt + 1, close));
    if (!tag) continue;
    if (!tag.end && (tag.name === "details" || tag.name === "summary")) collapsed = true;
    const opensSubtree = !tag.end && !tag.selfClosing && !VOID_ELEMENTS.has(tag.name);
    if (skip) {
      if (tag.name === skip.name && (tag.end || opensSubtree)) skip.depth += tag.end ? -1 : 1;
      if (skip.depth === 0) skip = null;
      continue;
    }
    if (!tag.end && (DROPPED_ELEMENTS.has(tag.name) || tag.attrs.has("hidden"))) {
      if (opensSubtree) skip = { name: tag.name, depth: 1 };
      continue;
    }
    layout(tag);
  }

  const visible = out.replace(/ +$/gm, "").replace(/\n{3,}/g, "\n\n").replace(/^\n+|\n+$/g, "");
  return { text: visible, collapsed };
}

/** Content lines behind a `| ` gutter (a bare `|` when empty), so none can pose as a structural line. */
const gutter = (text) =>
  text === "" ? "" : `${text.replace(/\n$/, "").split("\n").map((l) => (l === "" ? "|" : `| ${l}`)).join("\n")}\n`;

const snapshotPath = (outDir, number) => join(outDir, `issue-${number}.md`);

/** The intake verdict for one issue: `{ reason }`, or `{ snapshot, sha256, lines }` when eligible. */
function intakeIssue(ctx, number) {
  const { owner, name, repo, label, trusts, outDir } = ctx;
  const readFailed = `reading issue #${number} failed`;
  const meta = graphql(META_QUERY, { owner, name, number });
  const issue = answeredIssue(meta, readFailed);
  if (!issue) return { reason: "not-found" };
  if (!complete(issue.labels, issue.timelineItems, issue.comments)) throw ghFailed(readFailed, meta);
  const gated = gate(issue, label, trusts);
  if (gated.reason) return gated;
  const { labelled, at } = gated;

  const included = issue.comments.nodes.filter((c) => trusts(c.author?.login) && (!c.lastEditedAt || time(c.lastEditedAt) <= at));
  const fetchFailed = `fetching issue #${number} failed`;
  const fetch = graphql(FETCH_QUERY, { owner, name, number, ids: included.map((c) => c.id) });
  const text = answeredIssue(fetch, fetchFailed);
  if (!text) return { reason: "edited-during-intake" };
  if (!complete(text.labels, text.timelineItems) || !Array.isArray(fetch.data.nodes)) throw ghFailed(fetchFailed, fetch);
  const nodes = new Map(fetch.data.nodes.filter(Boolean).map((n) => [n.id, n]));
  const changed =
    text.lastEditedAt !== issue.lastEditedAt ||
    included.some((c) => !nodes.has(c.id) || nodes.get(c.id).lastEditedAt !== c.lastEditedAt) ||
    gate(text, label, trusts).reason;
  if (changed) return { reason: "edited-during-intake" };

  // The title is plain text and is screened as fetched; the body and comments are what GitHub rendered.
  const title = text.title ?? "";
  const rendered = [text.bodyHTML ?? "", ...included.map((c) => nodes.get(c.id).bodyHTML ?? "")].map(visibleText);
  if (hiddenChars(title) || rendered.some((r) => r.collapsed || hiddenChars(r.text))) return { reason: "hidden-content" };
  const [body, ...commentBodies] = rendered.map((r) => r.text.replace(CONTENT_BREAKS, "\n"));

  let snapshot =
    `UNTRUSTED ISSUE SNAPSHOT ${repo}#${number} labelled-by=${labelled.actor.login} at=${labelled.createdAt} fetched=${new Date().toISOString()}\n` +
    `\nTITLE: ${title.replace(TITLE_BREAKS, " ")}\n\nBODY:\n${gutter(body)}`;
  included.forEach((c, i) => {
    snapshot += `COMMENT ${c.author.login} ${c.createdAt}:\n${gutter(commentBodies[i])}`;
  });
  const path = snapshotPath(outDir, number);
  try {
    mkdirSync(outDir, { recursive: true });
    writeFileSync(path, snapshot, "utf8");
  } catch (err) {
    throw new Fail("intake-failed", `writing snapshot for #${number} failed`, err);
  }
  return {
    snapshot: path,
    sha256: createHash("sha256").update(snapshot, "utf8").digest("hex"),
    lines: snapshot.split("\n").length - 1,
  };
}

/**
 * One item of the output. An ineligible local issue also loses any snapshot a previous run left for it;
 * an other-repo ref never touches the out-dir, since its number may equal an eligible local issue's.
 */
function item(ctx, { number, other }) {
  if (other) return { issue: number, eligible: false, reason: "other-repo" };
  let v;
  try {
    v = intakeIssue(ctx, number);
  } catch (err) {
    throw err instanceof Fail ? err : new Fail("intake-failed", `processing issue #${number} failed`, err);
  }
  if (!v.reason) return { issue: number, eligible: true, ...v };
  try {
    rmSync(snapshotPath(ctx.outDir, number), { force: true });
  } catch (err) {
    throw new Fail("intake-failed", `removing stale snapshot for #${number} failed`, err);
  }
  return { issue: number, eligible: false, reason: v.reason };
}

function main(argv) {
  let opts;
  try {
    ({ values: opts } = parseArgs({
      args: argv,
      options: {
        cwd: { type: "string" },
        "out-dir": { type: "string" },
        issues: { type: "string" },
        labelled: { type: "boolean" },
        help: { type: "boolean", short: "h" },
      },
    }));
  } catch (err) {
    throw new Fail("usage", err.message);
  }
  if (opts.help) {
    process.stdout.write(USAGE);
    return;
  }
  if (!opts.cwd || !opts["out-dir"]) throw new Fail("usage", "--cwd and --out-dir are required");
  if (!opts.issues === !opts.labelled) throw new Fail("usage", "give exactly one of --issues and --labelled");

  const origin = tryGit(opts.cwd, ["remote", "get-url", "origin"])?.trim();
  const remote = origin && GITHUB_REMOTE.exec(origin);
  if (!remote) throw new Fail("origin-not-github", origin || "no origin remote");
  const [owner, name] = [remote[1], remote[2]];
  const repo = `${owner}/${name}`;
  const refs = opts.issues ? parseRefs(opts.issues, repo) : null;

  const conv = loadConventions(opts.cwd);
  if (conv.status === "absent") throw new Fail("conventions-absent", `no ${CONVENTIONS_PATH} on origin's default branch`);
  if (!conv.conventions) throw new Fail("conventions-invalid", conv.status.replace(/^invalid: /, ""));
  const label = conv.conventions.issues?.trigger_label;
  if (!label) throw new Fail("no-trigger-label", `set issues.trigger_label in ${CONVENTIONS_PATH}`);
  if (gh(["auth", "status", "--hostname", "github.com"]).status !== 0) {
    throw new Fail("gh-unavailable", "`gh auth status --hostname github.com` failed");
  }

  const trusted = conv.conventions.issues.trusted_actors ?? ownerActors(owner, name);
  const trustedLower = new Set(trusted.map((a) => a.toLowerCase()));
  const ctx = { owner, name, repo, label, outDir: opts["out-dir"], trusts: (login) => !!login && trustedLower.has(login.toLowerCase()) };

  const targets = refs ?? labelledNumbers(owner, name, label).map((number) => ({ number, other: false }));
  const items = targets.map((t) => item(ctx, t));
  process.stdout.write(`${JSON.stringify({ repo, trigger_label: label, trusted_actors: trusted, items })}\n`);
}

try {
  main(process.argv.slice(2));
} catch (err) {
  const fail = err instanceof Fail ? err : new Fail("intake-failed", "unexpected error", err);
  if (fail.diag !== undefined) logHookError("issue-intake.mjs", fail.diag instanceof Error ? fail.diag : new Error(fail.diag));
  process.stdout.write(`${JSON.stringify({ error: fail.message })}\n`);
  process.exitCode = 1;
}
