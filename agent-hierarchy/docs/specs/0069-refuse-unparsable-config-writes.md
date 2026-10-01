# 0069 — roster.mjs writers refuse a config file that won't parse

Implementer: implementor
Reviewer: reviewer

Status: not built. Small follow-up, one phase, next ah patch. Branch
`feat/0064-named-rosters`.

## 1. Problem

`readLevelFile` (agent-hierarchy/hooks/roster.mjs:2018-2027) returns
`{ version: CONFIG_VERSION }` for a missing file, and also for an existing
file that is not valid JSON (:2026-2027) or does not parse to a JSON object
(:2022). Every roster.mjs verb that writes a level file reads it through
`readLevelFile` and then writes the result back. So a hand-edited config file
with a typo is silently replaced, and its content is lost.

The user chose: writers refuse. They exit nonzero naming the path and the
parse error, and write nothing. Read verbs are unchanged.

## 2. Behaviour

**Unparsable** below means a level file (global, repo or repo-user) that
exists and either fails `JSON.parse` (an empty 0-byte file included) or parses
to something that is not a plain object (`null`, an array, a number, a
string). A missing file is not unparsable, and nothing about missing files
changes.

### 2.1 Verbs whose job is to write the file refuse

When the file a verb would write is unparsable, the verb exits 2 through the
existing `fail()` (roster.mjs:221-224), before writing any file at all. Its
stderr line names:
- the absolute path;
- the reason: `is not valid JSON (<the JSON.parse error message>)`, or
  `is not a JSON object`. These match the read side's wording in
  `loadScope` (lib-config.mjs:1301-1307);
- what to do and what happened: fix or delete the file and re-run, and
  `nothing was written`.

Illustrative only:
`roster.mjs: /r/.claude/agent-hierarchy.local.json is not valid JSON (Expected ',' or '}' after property value in JSON at position 41) — fix or delete it, then re-run; nothing was written`

Verbs covered: every caller found reading the file it then writes:
- `init` (:5190), `add` (:5207), `edit` (:5273), `remove` (removeConfigMember
  via :5370);
- `tier set` and `tier remove` (:6618);
- `role set` (:403), `role set --from` (:702), `role trust` (:792),
  `role remove` (:554);
- `roster copy` (:1086), `roster delete` (:1117/:1144), and `roster use <name>`
  (:1168).

The audit rule is: any verb that writes a level file must refuse rather than
overwrite an unparsable one. If the build finds a writer this list misses,
it is covered too; name it in the PR.

A writer that also reads other level files without writing them, such as
`role remove`'s usage scan over every level (:542-550), may refuse when one
of those is unparsable. That is stricter and accepted. Keeping today's
behaviour there is equally accepted.

A refusing verb must have written nothing. If some verb writes another file
before it reads the one it would refuse on, stop and report it; don't
reorder silently.

### 2.2 Where the config write is a side effect, warn and keep going

`dismiss` (:5887) and `untrack` (:2253) remove the member from the config
through `removeConfigMember` after their main work: closing the pane
(:5872), and writing the team's rows (:5885, :2221). Failing there would
leave a half-done verb whose output says nothing was written.

Instead, when the config file is unparsable, these verbs:
- finish their main work;
- leave the config file untouched;
- write one stderr warning naming the path and the reason (same wording as
  §2.1), and saying the member was not removed from it;
- report it in their JSON output where they already report the config
  removal result. `removeConfigMember` already returns
  `{ removed: false, reason }`; the reason carries the path and the parse
  reason;
- exit as they would have with the member already absent from the config.

`remove` is not in this group. The config edit is its whole job, so it
refuses under §2.1.

`storeTeamLayout` (:2801-2817) already behaves this way: it reads with its
own `JSON.parse`, throws on a non-object, writes nothing and warns. It is
unchanged.

### 2.3 Unchanged

- `show --level L` (:5155) reads through `readLevelFile` but never writes.
  It must keep today's output for an unparsable file, which is the same as
  for a missing one.
- Every read path: `levelFileData` (:976-986, null for unparsable), its
  callers (rosterDefinitions, rosterDelete's lookup, rosterUse's `had`),
  `loadScope` and everything in lib-config.mjs. All are unchanged.
- `roster use --clear` already writes nothing for an unparsable file:
  `levelFileData` returns null, so `cleared: false`. It stays as it is,
  which also keeps this change off the lines the 2eb1c76 review covers.
- `dropNonObjectMembers`, `migrateStaleKeys`, and `writeLevelFile` are
  unchanged.
- Missing files keep returning `{ version: CONFIG_VERSION }` to writers.

## 3. Constraints

- **Wait for the review:** the Reviewer is checking 2eb1c76. Until it
  reports, do not edit `rosterUse`, lib-config.mjs:1452-1456,
  test-roster-select.sh S15/S17, or cli-tools.md:128. Nothing in this spec
  needs those lines. If the build turns out to need one, wait for the
  review.
- **Fix it once:** make the change at the shared read that writers use, not
  as a check copied into each verb. `show --level` and the §2.2 side-effect
  path need a non-refusing view; how to give them one is your call.
- **Tests go in a new file,** `agent-hierarchy/tests/test-config-unparsable.sh`,
  using the sandbox/HOME-redirect pattern of
  `agent-hierarchy/tests/test-roster-select.sh`.

## 4. Tests

Mutation standard: each [bracketed mutation] must make at least one row
fail.

- **U1 Writers refuse.** For each verb in §2.1 whose setup an existing test
  already has a fixture for, against an unparsable target file:
  - exit 2;
  - stderr contains the path, `is not valid JSON` or `is not a JSON object`
    as fits, and `nothing was written`;
  - the file's bytes are unchanged;
  - no other file under the sandbox changed. Compare a listing with content
    hashes before and after.

  Run every verb with truncated JSON (`{"version": 1,`). Run `init`, `add`
  and `roster use` also with `[]` and with an empty 0-byte file. List in the
  PR any §2.1 verb skipped for want of a fixture.

  [return the default for an unparsable file] [accept a non-object]
  [treat an empty file as missing]
- **U2 Missing still works.** `init` in a sandbox with no repo-user file
  succeeds and creates it. [refuse a missing file]
- **U3 Side-effect writers.** Use `untrack` with the existing untrack fixture
  and an unparsable repo-user file:
  - exit status as with the member absent from the config;
  - the team row is gone;
  - the config file's bytes are unchanged;
  - stderr names the path;
  - the JSON output shows the config member not removed, with the reason.

  Do the same for `dismiss` only if an existing fixture covers its config
  removal; otherwise say so in the PR.

  [refuse in untrack] [overwrite in untrack]
- **U4 Reads unchanged.**
  - `show --level repo-user` with an unparsable file exits 0, and its
    output equals the output with that file missing.
  - `show` with no `--level` exits 0.

  [refuse in show --level]

Then run the full suite. Every existing row stays green; if one fails, stop
and report.

## 5. Docs

`agent-hierarchy/docs/cli-tools.md`: one sentence where it describes the
level files. Write verbs refuse (exit 2) a level file that exists but isn't a
JSON object, and leave it untouched; fix or delete it. Read verbs ignore such
a file, as before. Do not edit :128 until the review reports.

Bump the patch version in both manifests, as for other fixes on this branch.

## 6. Decisions

- Refuse rather than back up or keep overwriting: the user's choice.
- An empty 0-byte file is unparsable, not missing. That is one rule with no
  special case, and it matches `loadScope`, which warns "is not valid JSON"
  for it. Treating it as missing was rejected: an existing 0-byte file
  would then come back from the read as `{version}` and could flip a repo
  to configured.
- Side-effect writes warn rather than fail, like `storeTeamLayout` already
  does: failing after the pane has closed would be worse than the problem.
- `use --clear` is left alone: it already writes nothing, and the review is
  pending on its lines.
- Separate spec rather than a 0064 amendment: the bug predates 0064, and a
  separate spec keeps 0064 off lines under review.

## 7. Assumptions not verified

- Callers and line numbers come from a read of the current checkout (after
  2eb1c76). Nobody has verified that each §2.1 verb reads before it writes
  anything; §2.1's stop rule covers that.
- `remove`'s handling of `removeConfigMember`'s `removed: false` was not
  read. If it exits 0 on `removed: false`, `remove` needs its own refusal
  to satisfy §2.1.
