# 0071 evidence (§11), Claude Code 2.1.289, 2026-10-04

Probes only. No product code was changed. Scratch root used below:
`S=/private/tmp/claude-501/-Users-jimcline-git-repos-agent-tools/bd403965-5b7b-46b1-92d5-e5205ed571f1/scratchpad`
(throwaway). macOS has no `timeout`, so `perl -e 'alarm N; exec @ARGV' …` stands in for it.

## Verdicts

| # | Verdict | One line |
|---|---|---|
| E1 | **within bounds** (P1 step 7 re-run on the step-6b tree, see E1) | Status write p95: warm 5.6 ms (bound 15), cold 13.4 ms (bound 20). `listExchanges` p95 1.5–3.4 ms (bound 5). Import deltas within 10 ms. The first run (write 17–22 ms, `listExchanges` 5.7–5.8 ms) was over; step 6b removed the waste. |
| E2 | **async works** | `"async": true` is honoured on a plugin PostToolUse command hook. Sync no-op node hook = +32–36 ms per tool call. |
| E3 | **fires, but note is generic** | Notification(`permission_prompt`) fires in an `--agent ah:implementor` session. `message` is always `"Claude needs your permission"`. It lands ~6–8 s after the dialog shows. |
| E4 | **yes** | UserPromptSubmit fires on a cross-session SendMessage. Idle peer: within 1 s. Busy peer: at the next tool boundary, inside the running turn. |
| E5 | **answered** | No `mock.fs`, and no real fs in tests. The test answers `fs.stat`/`fs.read` via `on(…)` returning `{ value }`. `mock.clock` drives `$.clock.every` exactly. |
| E7 | deferred to P2a | claude-tui-line has no `ah` item yet (0 hits). `bench/bench.sh` exists (hyperfine old-vs-new). |
| E8 | **engine cancels** | After a hot reload, the old environment's `every` timer stops. No module-side cancel is needed. |
| E9 | **Branch A** | Both plugin.json forms load the classic hooks file and the `{modules}` file together (`classic.ok` and `mod.ok` both present). Also, one hooks.json holding both keys works. |
| E10 | **both shown → toggle** | A configured statusLine does not hide `$.ui.status`. The engine renders it as `⚠ <plugin>: <text>` on its own line, above the statusLine output. |
| E11 | read done; suite run at P1 step 2: only intended failures (see E11) | Push guard: no new merge block on the three item slugs. But the pipeline closes `pipeline-run-anchor` with a stub, which the §3.7.1 rule would leave open (see below). |
| E12 | **readable, no blocking prompt → userConfig (§6.4)** | `register(on, options)` gets `status_entry` with its default filled in. A stored value is read from user settings or `--settings` only, not from project or local settings. Update, enable and interactive start never prompt. A fresh install prints one non-blocking "1 userConfig option not yet set" line. |
| E13 | **no → embedded fixtures module + drift check (§6.6)** | `claude plugin test` refuses any `.json` import ("not named like code and was not loaded"), with or without `with { type: "json" }`. A `.ts` module that embeds the JSON loads. |
| E14 | **(a) yes → register-level toggle test; (b) no → AC 3 is `validate` only** | (a) `test(name, { options }, body)` hands `register` the userConfig values. (b) The only type check named is `tsc -p <mod folder>`, which needs `tsc`, and `ah` has none. Reference only; nothing was run. |

## Spec assumptions broken

1. **§6.1 "A hooks.json cannot hold both `modules` and `hooks`" is false on 2.1.289.** In E9 variant e, one `hooks/hooks.json` with both keys loaded the module (`hooks module e9e@inline loaded`) and also fired the classic UserPromptSubmit command (marker written). The manifest forms work too (Branch A).
2. **§3.3 / §6.5 `blocked_note` = Notification `message` carries no information.** The value is the constant `"Claude needs your permission"`, with no tool name, no command, and no `title` field. The toast would always read `{label} blocked · Claude needs your permission`. Also, `blocked` lags the dialog by ~6–8 s.
3. **§6.4 status entry text.** The engine prefixes every plugin status with `⚠ <plugin name>: `. So `ah · {text}` from plugin `ah-status` renders as `⚠ ah-status: ah · …`: a double label, plus a warning glyph we do not control.
4. **§6.6 tests.** In `claude plugin test`, nothing sits beneath the plugin. The test must itself answer:
   - `session.start`, by returning `{ cwd }`;
   - `ui.status`, by returning `{ value: undefined }`;
   - every `fs.*` call, with `{ value }`;
   - `clock.every`/`after`/`sleep`, via `mock.clock(on)`. Without it, `every` is refused with "no implementation".

   A real file is never read: E5 test B, with `status.json` present in both the cwd and the plugin root, gave `HooksError: no implementation for fs.stat`.
5. **§3.7.1 vs. pipeline anchors (E11), NEEDS-ARCHITECT.** The pipeline closes these with `msg.mjs new --type response`:
   - `pipeline-run-anchor`;
   - `<tag>-verdicts`;
   - every item record, `-x` record and `-done` record.

   Sources: skills/autonomous-pipeline/SKILL.md:1466-1469 for run end, and :768-772 for stale-anchor recovery. `msg.mjs new` has no `--body` flag (grep: 0 hits). So unless the Orchestrator edits each file afterwards, these responses are skeleton stubs. Under §3.7.1 they become **open**, and that breaks things:
   - `liveRun` (lib-decisions.mjs:196-203) needs exactly one open anchor. Two stale anchors give `null`, so the push guard's `pinnedMerge` (pretooluse-push-guard.mjs:623) refuses every pinned merge with `no-run`. One stale anchor gives a false live run, so merges are offered under a finished run's constraints.
   - SKILL.md:765-772's "another run's anchor is still open" halt re-triggers on every later run, and its prescribed fix command writes only another stub.
   - The live `agent-tools` pool has 0 `pipeline-run-anchor` / `-i<N>` exchanges, so there is no real-run sample. Whether real runs edit the body is **unknown**.
6. **E2 side note.** An async hook still running when a `claude -p` session exits is killed. With an 8 s hook, 0 of 3 `post-end` lines were written, and no orphan processes remained.

## Per item

### E2: async PostToolUse
- Setup: two plugins, identical except `"async": true|false` on PostToolUse(`*`). The hook is `node log.mjs`, which logs process origin and start, busy-waits `$E2_SLEEP` ms, then logs the end. PreToolUse(`*`) logs too. Model haiku, `--setting-sources local`.
- With 8000 ms hooks, 3 sequential `echo` calls:

  | Mode | Next PreToolUse | `post-end` |
  |---|---|---|
  | sync | always after the previous `post-end` (+8.0 s per call; e.g. post-end 1791168161491 → next pre 1791168162629) | written 3 of 3 |
  | async | 1.5 s / 1.1 s after `post-start`, never waiting | written 0 of 3 (killed at exit) |

- Cost with 0 ms hooks, 5 calls. The tool command logs its own end time (`perl … TOOLEND`).

  | Mode | Tool end → hook spawn | Tool end → hook done |
  |---|---|---|
  | sync | 18–22 ms | **32–36 ms** |
  | async | 19–23 ms | 33–40 ms (off the critical path) |

- Node baseline, 20 runs each:

  | Command | p50 | p95 |
  |---|---|---|
  | `node -e 0` | 25 ms | 27 ms |
  | `import lib-config.mjs` | 33 ms | 34 ms |
  | `import lib-roster.mjs` | 34 ms | 36 ms |

  So a sync `activity.mjs` would cost ≈ 40–50 ms before any status write. Moot, since async works.
- Repro: `$S/e2/plugin-{async,sync}`. Run `cd $(mktemp -d) && E2_LOG=$PWD/log E2_SLEEP=8000 perl -e 'alarm 240; exec @ARGV' claude -p --setting-sources local --plugin-dir $S/e2/plugin-async --allowedTools Bash --model haiku 'Run exactly these three Bash commands, each as its own separate Bash tool call, one after another: `echo one`, then `echo two`, then `echo three`. Then reply DONE.'`

### E3: Notification(`permission_prompt`) in an `--agent` peer
- Session setup:
  - interactive, in tmux, in `T=$(mktemp -d)`, with `git -C "$T/repo" init`;
  - `claude --setting-sources project,local --plugin-dir <agent-hierarchy working copy> --plugin-dir $T/p --agent ah:implementor --model haiku --permission-mode default -n e34peer`;
  - `$T/p` logs the stdin of classic Notification and UserPromptSubmit, and has a module that logs `prompt.submit` `origin`/`turnId`.
- Prompt typed: `Use the Bash tool to run exactly: touch e3-probe.txt`. The Bash permission dialog appeared ~2 s later.
- Notification payload, verbatim keys: `session_id`, `transcript_path`, `cwd`, `scratchpad_dir`, `prompt_id`, `"agent_type":"ah:implementor"`, `"hook_event_name":"Notification"`, `"message":"Claude needs your permission"`, `"notification_type":"permission_prompt"`. There is no `title`.
- Timing, 1 s resolution: UserPromptSubmit 1791168832; dialog visible ≈ 834; Notification 1791168840.
- Not done:
  - No team file was created, because `roster.mjs init`/`create` would touch user-level config. The role session comes from `agent_type` alone (`hierarchyRoleOf`, lib-config.mjs:577).
  - The event is the engine's, so a team does not affect whether it fires. That inference was not run.
- Repro: `$S/e34.sh` builds and launches it. Then send the Bash prompt with `tmux send-keys -t e34 -l '<prompt>'` + `Enter`, and read `$T/log/Notification.log`.

### E4: UserPromptSubmit on a cross-session SendMessage
- Same peer as E3. From this session: `SendMessage({to:"e34peer", message:"E4 probe: reply with the single word OK. Use no tools."})`.
- Idle peer:
  - UserPromptSubmit fired at 1791168872, within 1 s of the send.
  - `prompt` = `<cross-session-message from="uds:/tmp/cc-socks/42814.sock" from-name="agent-tools-implementor" from-mode="prompting">\n…\n</cross-session-message>`.
  - There is no `source` field. The types document `source:"system"` for peer messages, but 2.1.289 omits it.
  - The module saw `origin: {kind:"peer"}`, `turnId: null`.
- Busy peer: the message was sent during a 30 s Bash call.
  - It showed as queued (`› Message from …`).
  - UserPromptSubmit fired at 1791168950, when that tool call ended, ~25 s after the send.
  - The module saw `origin: {kind:"peer"}`, `turnId: "3a7014c4-…"`, so it was delivered into the running turn.
- The peer ran in `default` mode while the sender was `auto`, and the message was **not** held for approval.
- Consequence for §3.3: `working` is immediate for an idle peer. A busy peer is already `working`.

### E5: `claude plugin test` staging
- Plugin `$S/e5/p`: the module's `session.start` stats and reads `status.json`, calls `$.ui.status`, and starts `$.clock.every(2000, tick)`.
- Tests in `$S/e5/p/tests/probe.test.ts`; run `cd $S/e5/cwd && claude plugin test $S/e5/p`.

  | Test | What it does | Result |
  |---|---|---|
  | A | answers `on('fs.stat', → {value:{kind:'file',size,mtimeMs:111,isLink:false}})` and `on('fs.read', → {value:'STAGED'})` | **pass**; status `m=111 STAGED` |
  | B | unstaged fs; real `status.json` in cwd and plugin root | fails with `HooksError: no implementation for fs.stat` (real fs is never consulted) |
  | C | `mock.clock(on,{now:0})`; advance 1999 / 1 / 4000 | status counts `[1,1,2,4]`; **pass** (`every` fires exactly at each period) |
  | D | no `mock.clock` | the initial tick runs, then `$.clock.every refused: no implementation for clock.every` |

- Test-hook answers are `{ value }` (or `{ deny }`). A bare return is skipped with "returned neither { value } nor { deny }". Event hooks return their result (`session.start` → `{ cwd }`).
- `mock` has only `clock`, `store` and `env` (types 14685-14714).

### E8: timer after a hot reload
- Mod `$S/e8/mod`:
  - module-level `GEN` (random) and counter `n`;
  - `session.start` runs `$.clock.every(1000, …)`, which writes `tick-<GEN>.txt = n`, and sets `$.ui.status('gen '+GEN)`.
- Run interactively in tmux with `--plugin-dir`. After ~5 s, append a comment to `register.ts`.

  | Moment | `tick-horp7` (old) | `tick-cnnww` (new) |
  |---|---|---|
  | before reload | 4 | — |
  | +6 s | 4 | 5 |
  | +10 s | 4 | 9 |

  The status line showed `⚠ e8mod: gen cnnww`.
- The old timer stopped and the counter restarted, which matches reference.md:69: "the previous environment's timers are dropped".

### E9: classic + modules in one plugin (r2 method)
- Script `$S/e9r2.sh string|array`, exactly as §11. Deviation: `perl alarm 90` in place of `timeout 90`.
- Each run used a fresh `T=$(mktemp -d)` and `git -C "$T/repo" init`, then `claude --plugin-dir $T/p -p "reply ok"` from `$T/repo`.

  | Form | validate | `classic.ok` | `mod.ok` |
  |---|---|---|---|
  | `"hooks":"./mod/hooks.json"` | passed; only warning is missing `author`; lists `./register.ts hooks: session.start` | PRESENT | PRESENT |
  | `"hooks":["./hooks/hooks.json","./mod/hooks.json"]` | same | PRESENT | PRESENT |

  - Debug log for the array form: "names the standard hooks/hooks.json, which loads on its own; loaded once".
  - `validate` reports only the modules file in either form. It does not list the classic file.
- Extra variants (`$S/e9/{a..e}`, `--setting-sources local`, `--debug-file`):
  - `"hooks":["./hooks/mods.json"]`: both fire.
  - A single `hooks.json` with `{"modules":[…],"hooks":{…}}`: both fire.
- Not tested: an installed (marketplace) copy, as opposed to `--plugin-dir` inline.

### E10: statusLine vs `$.ui.status` (r2 method)
- Script `$S/e10r2.sh`:
  - `$T/repo/.claude/settings.json` = `{"statusLine":{"type":"command","command":"echo E10-STATUSLINE"}}`;
  - the mod's `session.start` does `$.ui.status("E10-PROBE")` and writes `$T/m.ok`;
  - `tmux new-session -d -s e10-$$ -x 200 -y 50 -c "$T/repo" …`.
- Result: `m.ok` PRESENT. Screen tail:
  ```
    ⚠ e10m: E10-PROBE
    E10-STATUSLINE
    ⏵⏵ auto mode on (shift+tab to cycle) · ← 2 agents
  ```
- Also checked:
  - no statusLine (`--setting-sources local`): `⚠ e10mod: E10-MOD-STATUS` shows alone;
  - a 3-line statusLine: the mod line sits above all three;
  - at 50 columns: unchanged.
- Deviations:
  - `--setting-sources project,local`, so user plugins cannot rewrite `~/.claude/settings.json` (see side effects);
  - in 2.1.289 the folder-trust dialog **defaults to "No, exit"**, so the spec's `send-keys Enter` exits claude (2 invalid runs, `CLAUDE-EXITED=1`). It is accepted with `Down` then `Enter`.

### E11: push guard × open rule (read part)
- `mergeCheck` (pretooluse-push-guard.mjs:750-800) is advisory only (:746-749). It runs only as `merge-check` (:893).
- The real PreToolUse path is `pinnedMerge` (:617-636). It reads exchanges only through `D.liveRun` (:623).

  | Slug | Rule | Under §3.7.1 | New block? |
  |---|---|---|---|
  | `<tag>-i<N>` | must be open, else `not-this-run` (:778) | — | no; open while the run is live |
  | `<tag>-i<N>-ok` | needs a closed exchange, else `not-signed-off` (:781) | — | no on the intended path, where the Architect fills its response. It would fire only for an unfilled `--req` stub, which today passes a sign-off nobody wrote. |
  | `<tag>-i<N>-x` | open gives `exception` (:782) | a stub-closed `-x` reads open | only after run end, when mergeCheck already exits `no-run` at :768 |
  | `pipeline-run-anchor` | via `liveRun` | — | **yes**: see "Spec assumptions broken" #5 |

- Suite run (P1 step 2). The full `ah` bash suite ran with §3.7.1 and the orchestrator-address exemption in place, before any test edits. It ran from a cwd outside any git repo, so `pipelineRunLive(process.cwd())` (roster.mjs:654) could not see the live run. Result: 97 files, 95 pass, 2 fail. Both failures are the intended change in the §3.7.2 rows: a bodyless response to a **member**-addressed request no longer closes the exchange.
  - `test-msg-cli.sh`: 5 assertions failed: `list` default/`--closed` after a bodyless response to an `implementor` request, and `sweep --days 0` / `sweep --plain`, whose "closed" pairs were bodyless responses to `implementor` and `reviewer` requests. Updated under §3.7.7 by writing a content line into those two responses. No assertion changed.
  - `test-roster-stream.sh`: G3b, G6 and T2 failed. The `respond` helper answered `implementor`/`architect` requests bodyless, and `stream-label`/`stream-status` (through `openExchanges`) still saw them open. Updated under §3.7.7: `respond` now writes a content line into the response. No assertion changed.
  - No other failure. These pass unedited: `test-pipeline-decisions.sh`, `test-push-guard.sh`, and every pre-existing `test-pipeline-merge.sh` case (its `-ok` and `-x` records are orchestrator-addressed, so they still close on a bodyless response).
  - `merge-check` against the open rule (AC 22, new cases in `test-pipeline-merge.sh`): an Architect-addressed `-ok` with a skeleton response gives `not-signed-off`; the same response filled gives none; a `-x` record closed bodyless gives no `exception`.
  - After the updates: 98 files, 98 pass (with the new `test-exchange-open.sh`).

### E1: status write cost (P1 step 7)

**Method.**

- The pool is a copy of the live `agent-tools` `.claude/hierarchy` (`cp -Rp`) and of `~/.claude/agent-hierarchy.peer-pending.jsonl`, placed in `T=$(mktemp -d)` (checked non-empty). The run used `AGENT_HIERARCHY_DIR=$T/hierarchy` and `HOME=$T/home`, and cwd `$T`.
- Final code: the P1 worktree at f6742a7 (step 6b), plus the step-7 version bump. The first run, kept below as "Before", used 206c4ab. Pre-step-5 code: `git archive ed9367b`.
- Driver: `run-e1.sh` and `e1.mjs` in the Implementor's scratchpad.
- "Cold" means one fresh `node` process per sample, timing only the call, with module load reported separately. "Warm" means 50 calls in one process after one untimed call. Import wall time covers the whole `node -e 'await import(…)'` process, 20 runs.
- **A copy must keep mtimes.** A plain `cp -R` resets every response's mtime to now. Every recently closed member exchange then counts as reported in the last 10 min and becomes a dispatch: 73 instead of 4. That inflated the write to p95 ~111 ms in a first run, which is discarded.

**Pool.** 90 exchanges: 2 open, and 88 member-addressed with a response. One live team. The document holds 2 dispatches and 3 members, counted on a copy taken just after the run. The peer-pending file is 610,501 bytes. status.json is 3,799 bytes.

| Measure | p50 | p95 | max | Bound | Verdict |
|---|---|---|---|---|---|
| Status write path, cold (`writeStatus`) | 10.15 ms | 13.40 ms | 20.44 ms | p95 ≤ 20 ms | ok |
| Status write path, warm | 4.89 ms | 5.63 ms | 5.84 ms | p95 ≤ 15 ms | ok |
| Module load before the first write (lib-status + lib-hier) | 7.21 ms | 9.16 ms | 12.32 ms | — | — |
| `listExchanges`, cold | 2.86 ms | 3.39 ms | 3.65 ms | p95 ≤ 5 ms | ok |
| `listExchanges`, warm | 1.16 ms | 1.48 ms | 1.78 ms | p95 ≤ 5 ms | ok |
| `import lib-hier`, pre-step-5 → final | 26.69 → 27.12 ms | 29.17 → 28.64 ms | 29.60 → 28.97 ms | delta ≤ 10 ms | ok (+0.43 / −0.53) |
| `import lib-config`, pre-step-5 → final | 26.05 → 27.18 ms | 27.98 → 31.12 ms | 28.20 → 32.54 ms | delta ≤ 10 ms | ok (+1.13 / +3.14) |

Against the first run, p95: the warm write fell from 17.26 to 5.63 ms, the cold write from 22.40 to 13.40 ms, and warm `listExchanges` from 5.74 to 1.48 ms. A write now lists the exchanges once and reads the peer-pending file once (AC 28). It no longer grows by ~1 ms per out dispatch.

**Before: the first run (206c4ab).** It was measured against r2's single bound of 15 ms. r3.10 ruled on it, and step 6b applied the three levers below.

**Pool, first run.** 85 exchanges: 3 open, and 82 member-addressed with a response. One live team. The document holds 4 dispatches and 3 members. The peer-pending file is 609,525 bytes. status.json is 5,028 bytes.

| Measure | p50 | p95 | max | Bound | Verdict |
|---|---|---|---|---|---|
| Status write path, cold (`writeStatus`) | 19.28 ms | 22.40 ms | 27.63 ms | p95 ≤ 15 ms | **over** |
| Status write path, warm | 13.74 ms | 17.26 ms | 19.97 ms | p95 ≤ 15 ms | **over** |
| Module load before the first write (lib-status + lib-hier) | 6.77 ms | 7.53 ms | 8.84 ms | — | — |
| `listExchanges`, cold | 5.01 ms | 5.80 ms | 6.25 ms | p95 ≤ 5 ms | **over** |
| `listExchanges`, warm | 3.39 ms | 5.74 ms | 7.47 ms | p95 ≤ 5 ms | **over** |
| `import lib-hier`, pre-step-5 → final | 26.69 → 27.48 ms | 29.20 → 28.98 ms | — | delta ≤ 10 ms | ok (+0.79 / −0.22) |
| `import lib-config`, pre-step-5 → final | 25.54 → 27.24 ms | 27.43 → 34.38 ms | 28.29 → 36.06 ms | delta ≤ 10 ms | ok (+1.70 / +6.95) |

**Where one write goes.** Warm medians of 20, timed separately. The compute total is 12.8 ms:

- `listExchanges` 3.25 ms. It reads every member-addressed response for the open rule.
- `openRunAnchor` for the one live team 3.20 ms. It goes through `openExchanges`, which runs `listExchanges` a second time.
- `dispatchOrigin` 1.02 ms per dispatch, 4 dispatches here. Each call re-reads the whole 609 KB peer-pending file.
- `readMsgFile` of every member request 1.39 ms.
- `resolveConfig` 0.10, `attributedRoster` 0.15, `readGates` 0.03.

The write grows with the number of out dispatches, at ~1 ms each from the peer-pending re-read, and with the exchange count. Those three are the levers. Per §8 the remedy amends the spec, so this goes to the Architect.

### E12: userConfig read path, and prompts on update or enable (P2b start)

Claude Code 2.1.289, 2026-10-05. Scratchpad `$SP=/private/tmp/claude-501/-Users-jimcline-git-repos-agent-tools/fc01c82d-251b-4bd7-b671-d7c6fbbbf0fd/scratchpad`. Scripts: `$SP/e12.sh`, `e12b.sh`, `e12c.sh` and `e12d.sh`. Probe field, the same as §6.4: `"userConfig": {"status_entry": {"type": "boolean", "title": "Status entry", "description": "…", "default": true}}`. The module's `session.start` writes `JSON.stringify(options)` to a file.

**Reference.** The reference is explicit about the read path:
- reference.md:15: `register(on, options)`, where "`options` holds the values of the fields the manifest's `userConfig` declares".
- Types 7314–7326, `PluginOptions`: "defaults filled in", stored at `settings.json pluginConfigs[<plugin>].options`. "A change to them reloads the plugin and `register` runs again" (8796).
- The reference does not say whether adding a field prompts anyone, so that part was probed.

**Read path** (`--plugin-dir`, real HOME; validate passed):

| Where the value is | Settings sources | `options` the module got |
|---|---|---|
| nowhere | `local` | `{"status_entry":true}` (the default) |
| `.claude/settings.local.json` `pluginConfigs.e12p.options.status_entry=false` (also tried the `e12p@inline` key) | `local` | `{"status_entry":true}`: **not honoured** |
| `.claude/settings.json`, same value | `project` | `{"status_entry":true}`: **not honoured** |
| `--settings '{"pluginConfigs":{"e12p":{"options":{"status_entry":false}}}}'` | `local` + flag | `{"status_entry":false}` |
| `$HOME/.claude/settings.json` with scratch HOME, same value | `user` | `{"status_entry":false}` |

A stored value counts only from user settings or the `--settings` flag. That is where `/config` and `claude plugin configure` put it. A project or local settings file does not set it.

**Installed plugin, under a scratch HOME.**
- Setup: a folder marketplace (`claude plugin marketplace add <path>`). The plugin was installed at 0.1.0 with no userConfig, then moved to 0.2.0, which adds `status_entry`.
- The commands run with a TTY (`script -q /dev/null …`), so a prompt would show rather than fail on a pipe.

| Step | Output | Prompt? | `options` at the next session |
|---|---|---|---|
| install 0.1.0 | installed, scope user | no | `{}` |
| `marketplace update` + `plugin update` → 0.2.0 | "updated from 0.1.0 to 0.2.0 … Restart to apply changes." | no | `{"status_entry":true}` |
| `disable`, then `enable` | success lines | no | `{"status_entry":true}` |
| fresh scratch HOME, install 0.2.0 | installed, then a notice: "1 userConfig option not yet set — run /plugin configure e12q@e12mkt in Claude Code, or pass --config KEY=VALUE." Exit 0 | no (an informational line) | `{"status_entry":true}` |
| interactive `claude` in both HOMEs, past folder trust (tmux) | normal prompt; no config dialog | no | `{"status_entry":true}` |

- `claude plugin configure e12q@e12mkt --json` after either path gives `"inputs": {"status_entry": "true"}`, `"configured": []` and `"unconfigured": ["status_entry"]`. A defaulted field counts as "unconfigured", but its default still reaches the module.

**Verdict.**
- **Readable with no blocking prompt → userConfig as in §6.4.**
- A fresh install prints one non-blocking "not yet set" line. An upgrade prints nothing.

**Unknowns.**
- Login: a scratch HOME has none ("Not logged in"). `session.start` runs before the login check, so `options` was observed anyway, and the interactive screen showed no dialog. A logged-in session was not observed.
- Marketplace source: only a folder marketplace was tested, which reads the plugin in place. A copied (git/GitHub) install was not, because `file://` sources are refused ("Invalid marketplace source format").
- The `/plugin` UI flow was not driven.

### E13: fixture JSON in `claude plugin test` (P2b start)

Script `$SP/e13.sh`. It works on a scratch copy of the worktree's `agent-hierarchy` with `"hooks": "./mod/hooks.json"`, a no-op `mod/register.ts`, and tests under `mod/tests/`. Scratch HOME and CLAUDE_CONFIG_DIR. `claude plugin validate` passed.

| Test file | Import | Result |
|---|---|---|
| control | none | pass |
| attr | `import doc from '../../tests/fixtures/status/work.json' with { type: 'json' }` | **file did not load** |
| plain | the same path, no attribute | **file did not load** |
| inside | `./local.json` beside the test, with the attribute | **file did not load** |
| embedded (second run) | `import { work } from './fixtures.ts'`, a module holding `export const work = <work.json verbatim> as const` | pass |

The error is the same for each JSON import:

> cannot import "…/work.json" (from mod/tests/attr.test.ts): $T/ah/tests/fixtures/status/work.json is not named like code and was not loaded: a hooks module and the files it imports end in .ts, .tsx, .jsx, .js, .mjs, .cjs, .mts or .cts

This matches reference.md:12, "a file named otherwise is not loaded".

**Verdict: no → the embedded fixtures module plus the bash drift check (§6.6).** The embedded `.ts` module loads and its values read correctly.

### E14: test options and a type check, from the reference only (P2b step 0)

Read only, nothing run. Source: the 2.1.289 plugin-authoring skill, `/private/tmp/claude-501/bundled-skills/2.1.289/674cb784a626d39e2cf6782970c9ba4e/plugin-authoring/`.

- **(a) Can a test supply `options` to `register`? Yes.**
  - reference.md:77: "A test gives the plugin under test its `userConfig` values with `test(name, { options }, body)`, which it reads as the values stored in settings (… defaults filled in, then validated); left out, the plugin gets its manifest's defaults."
  - types/claude-code.d.ts 15148–15170 (`TestOptions.options`): "`register(on, options)` receives them as a load does."
  - → A register.tsx toggle test is added, beside the view.ts test.
- **(b) Is a type check named that needs no new dependency? No.**
  - reference.md:39–49: the engine lays declarations and a `tsconfig.json` in `.claude-plugin/types/` "so its editor and `tsc -p <mod folder>` type it with no step taken. There is no command to run." The only type check named is `tsc`, which is not installed, and `ah` has no package.json.
  - reference.md:62: `claude plugin validate` "checks the contract" of a plugin that adds a noun to `$`, meaning its types file. It does not type-check module code.
  - → AC 3 is `claude plugin validate` only. The ceiling stands: type errors the tests do not exercise go unseen.
- Side note: per reference.md:41–48, a mod loaded from a folder the person owns (`--plugin-dir` among them) gets `.claude-plugin/types/` written beside it at every load and reload. A live `--plugin-dir` run on the worktree would leave generated files in the plugin folder.

## Side effects outside scratch (for the user)
- **`~/.claude/settings.json` was rewritten by the user's own verb-themes plugin** during the two E9 r2 runs. Those runs load full user settings, as r2 prescribes, and verb-themes `rotate.py:217` swaps the spinner pack on each SessionStart. File mtime: 22:47:55. It rotated twice. The runs' output named Star Trek, then James Bond, and the session had started on Doctor Strangelove. It was not reverted, because the brief forbids settings edits. `/verb-themes` restores it. Every other probe used `--setting-sources local|project,local` to avoid this.
- Folder-trust was accepted for 3 `mktemp -d` repos under `/var/folders/…/T/`, as E10/E3 prescribe. This adds `~/.claude.json` project entries.
- E9 r2 ran the user's full plugin set in temp repos, so Engram/ah hooks saw the prompt "reply ok".
- Every `claude`/tmux process started here has exited: `pgrep -fl 'claude --setting-sources'` is empty and no tmux server is running.
- E12/E13 (2026-10-05):
  - Everything ran in the scratchpad, under scratch HOMEs, except E12's read-path runs. Those used the real HOME with `--setting-sources local|project` (no user plugins), and left one transcript folder under `~/.claude/projects/` for the scratch repo.
  - `~/.claude/settings.json`, `~/.claude.json` and `~/.claude/dev-mods` were not written.
  - The interactive runs used private tmux sockets (`tmux -L e12…`), killed afterwards. No probe process is left.
