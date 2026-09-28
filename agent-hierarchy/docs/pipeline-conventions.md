# Pipeline conventions — `.claude/ah-conventions.json`

A team declares how `/pipeline` behaves in its repo in one committed JSON file,
`.claude/ah-conventions.json`. Committing it also **opts the repo in** to the ah push guard.
Every team-overridable pipeline choice reads from this file and from nowhere else.

## Where it is read from

Always the committed blob on origin's default branch, `<origin-default>:.claude/ah-conventions.json`,
never the working tree. `<origin-default>` is the first of these that resolves:

1. `refs/remotes/origin/HEAD`, by its symbolic target;
2. `refs/remotes/origin/main`;
3. `refs/remotes/origin/master`.

If none resolves, or the blob is absent, the repo is **not opted in** and the push guard does nothing
there.

An agent can edit the working tree freely, and an injected instruction could delete or loosen a
local copy of the file. The default branch changes only through a push to it, and the push guard
denies that. Editing the file on a branch changes nothing until the change is merged, and the file
sits under `.claude/**`, a protected path, so an agent can never push a change to it.

Nothing here fetches. `origin`'s refs are as fresh as the last `git fetch origin`.

This is a separate file from `.claude/agent-hierarchy.json`. That file is the roster config:
`roster.mjs` writes it, and it may be personal and uncommitted. Conventions are team-shared,
committed, and never rewritten by a CLI.

## Schema, version 1

```json
{
  "version": 1,
  "issues": {
    "trigger_label": "ready-for-agent",
    "trusted_actors": ["octocat"]
  },
  "pr": {
    "draft": true,
    "issue_link": "refs",
    "reviewers": []
  },
  "ci_secrets": "none-on-branches",
  "protected_paths": ["infra/**"],
  "protected_branches": ["release/*"],
  "on_item_done": "my-team:tracker-sync"
}
```

| Key | Type | Default when absent | Meaning |
|---|---|---|---|
| `version` | integer, must be `1` | none; required | Schema version. |
| `issues.trigger_label` | non-empty string | none — issue runs refuse without it | The label that makes an issue eligible. |
| `issues.trusted_actors` | array of GitHub logins | the repo owner's login when the owner is a user account; **required** when it is an organization | Who may apply the trigger label, and whose comments count as input. |
| `pr.draft` | boolean | `true` | Open PRs as drafts. |
| `pr.issue_link` | `"refs"` \| `"closes"` | `"refs"` | Writes `Refs #N` or `Closes #N` in the PR body. |
| `pr.reviewers` | array of logins or `org/team` | `[]` | Reviewers requested after the PR is created. |
| `ci_secrets` | `"none-on-branches"` \| `"skip-ci"` | `"none-on-branches"` | The team's CI-secrets posture. `none-on-branches`: runs triggered by pushes to non-default branches or by pull requests don't use repo secrets. `skip-ci`: every agent commit's subject ends with `[skip ci]`, and the run checks it before each push. A team whose branch or PR runs can reach secrets must declare `skip-ci`. |
| `protected_paths` | array of globs | `[]` | Extends the baseline protected paths below; never replaces them. |
| `protected_branches` | array of globs | `[]` | Extends the default branch, which is always protected. |
| `on_item_done` | skill name | none | A skill the pipeline runs after each item, for the team's own tracker writes. It is invoked at least once per issue whose status is final, and may repeat after an interruption, so it must be idempotent. |

**Validation is strict.** Invalid JSON, a wrong type, `version` other than `1`, or **any unknown key
at any level** is a violation — so a typo such as `protected_path` cannot silently drop a
protection. On a violation the repo is still opted in: the push guard applies the baseline only and
ignores the file's extensions, and issue runs refuse to start with one line naming the violation.
Plan and spec runs are unaffected.

`node <AH_ROOT>/hooks/pretooluse-push-guard.mjs check --branch HEAD --cwd <repo>` prints the
conventions status (`"ok"`, `"absent"` or `"invalid: <why>"`) — see [cli-tools.md](cli-tools.md).

### Globs

Globs in `protected_paths` and `protected_branches` match repo-relative POSIX paths or branch
short names. A pattern must match the **whole** string, anchored at both ends: `release/*` matches
`release/1` but not `release/1/x`; use `release/**` for any depth.

- `*` matches any run of characters except `/`;
- `?` matches one character except `/`;
- a whole `**` segment matches zero or more segments;
- everything else is literal — no negation, character classes or brace expansion. A pattern with
  no wildcard matches exactly.

## The push guard

In an opted-in repo, a PreToolUse hook on Bash denies, for every Claude session (the user's own
interactive ones included): force pushes, `--no-verify`, deletions, bulk and tag pushes, pushes to
a remote other than `origin`, pushes to the default branch or a protected branch, pushes whose range
touches a protected path, and changes to remote configuration. A person pushes those from their own
terminal. A dry run is evaluated like a real push.

### Baseline protected paths

Anchored at the repo root:

- **CI:** `.github/**`, `.gitlab-ci.yml`, `.gitlab/**`, `.circleci/**`, `Jenkinsfile`,
  `.buildkite/**`, `.travis.yml`, `azure-pipelines.yml`, `bitbucket-pipelines.yml`, `.drone.yml`,
  `action.yml`, `action.yaml`.
- **Git and pre-commit hooks:** `.pre-commit-config.yaml`, `.husky/**`, `.githooks/**`,
  `.gitmodules`.
- **Agent config:** `**/.claude/**`, `**/.mcp.json`, `**/.claude-plugin/**`.
- **Plugin hooks:** `D/hooks/**` for every directory `D` (the repo root included) where
  `D/.claude-plugin/plugin.json` exists in the pushed commit or the range base. Ordinary
  `src/hooks/` directories are not flagged.

**This list does not cover code that CI executes** — tests, build scripts, `package.json` scripts,
Makefiles. No path list can. That is what the `ci_secrets` declaration is for.

### What it cannot stop

The guard matches command text. It stops a **compliant** model that follows an injected
instruction at face value — the deny tells it to stop. It does **not** stop an **adversarial**
model. Known gaps:

- shell expansion: variables, `eval` of computed strings, base64;
- command text fed to a shell as data: a heredoc or herestring into `bash`/`sh` (`bash <<EOF`), or
  piping into a shell (`… | sh`);
- git run by another program: scripts, `xargs`, `find -exec`, `parallel`, `watch`, or other
  interpreters (`python -c`, `node -e`, `perl -e`);
- git aliases, including `git -c alias.x=push x`;
- pushing through a subcommand other than `push`: `git subtree push`, `git send-pack`;
- `env -S <string>` (a constructed command string);
- `sudo` long options without `=` (`--user root`), and bundles ending in a value-taking letter
  (`-nu root`). An agent is unlikely to run `sudo git`: it needs a password or TTY, and would push
  with root's credentials;
- non-literal `cd`, `-C`, `--git-dir`, `--work-tree` or `GIT_DIR` values;
- forging local refs (`refs/remotes/origin/*`) by paths other than `update-ref`/`symbolic-ref`;
- the GitHub API used directly.

## Push mode for issue runs

An issue run (`/pipeline <issue-ref> ...` or `/pipeline --labelled`) pushes after each commit with
no person present — **unattended** mode — only while both of these hold at bootstrap. Each is
named for how it fails; the names, in this order, are the only values of the run anchor's
`push-mode-reasons` line besides `none`, and the run-start notification lists the unmet ones.

1. `hook-inactive` — the push guard is installed and active. The probe
   `git push --dry-run --force origin ah-push-guard-probe`, run in the repo, must be denied with
   `ah-push-guard:PG-FORCE`. Any other result means the guard is not active; a probe that is not
   denied still pushes nothing, because its source ref does not exist.
2. `guard2-degraded` — the pipeline's CI-deploy check did not degrade the run.

If any condition is unmet, or its result is unknown, the run is **degraded**: it commits locally,
never pushes during the run, and asks for one approval per item at the end. Plan and spec runs are
unaffected.

Every `/pipeline` run, plan and spec runs included, scans each push for secrets first. It uses
gitleaks when `gitleaks version` exits 0, and otherwise a model scan: a read-only agent,
dispatched fresh for each push, that sees only the commits being pushed. A missing gitleaks does
not degrade a run. The run anchor's `secret-scan:` line and the run-start notification name the
scanner.

The run follows the `ci_secrets` posture, declared or defaulted; it decides only the `[skip ci]`
suffix:

- `"none-on-branches"` (the default when the key is absent): runs triggered by pushes to
  non-default branches or by pull requests are assumed not to use repo secrets, for example
  because secrets are environment-scoped with branch protection. The run adds nothing.
- `"skip-ci"`: every agent commit's subject ends with `[skip ci]`, and the run checks it before
  each push. A branch with a commit whose subject lacks it is not pushed: the item ends
  `local-only`, reason `skip-ci-missing`.

### Residual risk

Unattended mode means code shaped by third-party issue text reaches the remote with no person
present. It rests on four things:

1. the trust gate — a trusted actor applied the trigger label, vouching for what they saw;
2. the push guard — a compliant model cannot push protected paths or branches;
3. the team's CI-secrets posture, declared or defaulted;
4. the secret scan — gitleaks, or the model scan when gitleaks is not installed.

It does not cover:

- a secret the model scan misses (limits below);
- code that CI executes (tests, build scripts) when the posture is wrong. In particular, **a repo
  that does not declare `ci_secrets` but whose branch- or PR-triggered runs use secrets gets
  unattended pushes with no `[skip ci]` guard**, because the default assumes those runs use no
  secrets. Such a team must declare `"skip-ci"`;
- an adversarial model evading the guard (see [What it cannot stop](#what-it-cannot-stop));
- misuse of `gh`, which the guard does not inspect;
- tracker writes through `on_item_done`, which only the skill's instructions govern.

Both defaults are deliberate choices: unattended mode over the more conservative option of
defaulting to degraded mode, and assuming no secrets on branch and PR runs over requiring every
team to declare its posture.

The model secret scan's limits, accepted with the choice to push without gitleaks:

1. **Probabilistic.** The same patch can get different verdicts. A secret with no recognisable
   shape, such as a random password assigned to an innocent-looking name, can be missed. gitleaks
   is deterministic, but also bound to its patterns.
2. **Prompt injection.** Text in the patch, shaped by an issue through the builder, can try to
   talk the scanner into a clean verdict. A fresh context, read-only tools, treating such text as
   a `scan-evasion` finding, and a strict parse of the reply reduce this but don't remove it.
3. **Binary content isn't scanned**, only paths. That includes Git LFS objects, which git shows as
   pointers. A `.gitattributes` change that hides content from the diff is caught only if the
   scanner notices it.
4. **Over-limit patches are never scanned or pushed.** A patch over 256 KiB, or with a line over
   2000 characters, fails closed: in an issue run the item ends `local-only`, and a plan run stops
   pushing. Either way it costs a manual push.
5. **Cost:** one Sonnet dispatch per push, which in unattended mode is one per commit.
6. **The upgrade is installing gitleaks.** The next run uses it automatically.
7. **Only a race remains:** a remote branch rewritten or deleted between the pre-scan
   `git fetch --prune origin` and the push can leave commits out of the scan. The window is seconds
   long.
