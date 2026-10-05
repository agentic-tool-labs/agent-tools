# 0071 evidence (§11), Claude Code 2.1.289, 2026-10-04

Probes only. No product code was changed. Scratch root used below:
`S=/private/tmp/claude-501/-Users-jimcline-git-repos-agent-tools/bd403965-5b7b-46b1-92d5-e5205ed571f1/scratchpad`
(throwaway). macOS has no `timeout`, so `perl -e 'alarm N; exec @ARGV' …` stands in for it.

## Verdicts

| # | Verdict | One line |
|---|---|---|
| E1 | deferred to P1 | Needs the P1 status write path and the new `listExchanges`. |
| E2 | **async works** | `"async": true` is honoured on a plugin PostToolUse command hook. Sync no-op node hook = +32–36 ms per tool call. |
| E3 | **fires, but note is generic** | Notification(`permission_prompt`) fires in an `--agent ah:implementor` session. `message` is always `"Claude needs your permission"`. It lands ~6–8 s after the dialog shows. |
| E4 | **yes** | UserPromptSubmit fires on a cross-session SendMessage. Idle peer: within 1 s. Busy peer: at the next tool boundary, inside the running turn. |
| E5 | **answered** | No `mock.fs`, and no real fs in tests. The test answers `fs.stat`/`fs.read` via `on(…)` returning `{ value }`. `mock.clock` drives `$.clock.every` exactly. |
| E7 | deferred to P2a | claude-tui-line has no `ah` item yet (0 hits). `bench/bench.sh` exists (hyperfine old-vs-new). |
| E8 | **engine cancels** | After a hot reload, the old environment's `every` timer stops. No module-side cancel is needed. |
| E9 | **Branch A** | Both plugin.json forms load the classic hooks file and the `{modules}` file together (`classic.ok` and `mod.ok` both present). Also, one hooks.json holding both keys works. |
| E10 | **both shown → toggle** | A configured statusLine does not hide `$.ui.status`. The engine renders it as `⚠ <plugin>: <text>` on its own line, above the statusLine output. |
| E11 | read done; suite deferred to P1 | Push guard: no new merge block on the three item slugs. But the pipeline closes `pipeline-run-anchor` with a stub, which the §3.7.1 rule would leave open (see below). |

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

- Suite run: deferred to P1.

## Side effects outside scratch (for the user)
- **`~/.claude/settings.json` was rewritten by the user's own verb-themes plugin** during the two E9 r2 runs. Those runs load full user settings, as r2 prescribes, and verb-themes `rotate.py:217` swaps the spinner pack on each SessionStart. File mtime: 22:47:55. It rotated twice. The runs' output named Star Trek, then James Bond, and the session had started on Doctor Strangelove. It was not reverted, because the brief forbids settings edits. `/verb-themes` restores it. Every other probe used `--setting-sources local|project,local` to avoid this.
- Folder-trust was accepted for 3 `mktemp -d` repos under `/var/folders/…/T/`, as E10/E3 prescribe. This adds `~/.claude.json` project entries.
- E9 r2 ran the user's full plugin set in temp repos, so Engram/ah hooks saw the prompt "reply ok".
- Every `claude`/tmux process started here has exited: `pgrep -fl 'claude --setting-sources'` is empty and no tmux server is running.
