# 0066 — Several teams at once, asked for in plain words

Implementer: implementor
Reviewer: reviewer

Builds on spec 0064 phase 1 (named rosters, branch `feat/0064-named-rosters`).
One phase, one ah minor bump.

## 1. What this is for

A user says "create team foo from roster foo-named-roster and create team bar
from roster bar-named-roster". The Orchestrator should build both teams without
asking anything the user already said, and afterwards should keep both teams
straight: every later command acts on the right one.

Two parts:
- **A. One session owning several live teams** is a supported state, not a
  refusal case (user ruling). Most of ah already allows it. The gaps are in
  the hooks and `msg.mjs`, which silently pick one team.
- **B. The create flow in plain words:** how `/ah:agent-team` turns such a
  request into `create` calls with no extra questions.

## 2. What exists today (verified by reading)

- **Creating a second team works.** One orchestrator pid can commit
  `--team alpha` and then `--team beta`
  (tests/test-roster-multi-team.sh:47-51). Each team is its own file,
  `<hierarchy dir>/teams/<T>.json`. Members are named `<T>-<role>[-N]`
  (lib-config.mjs:886-891), so two teams' member names never collide.
- **Ownership.** A team is owned by the session whose pid, and session id when
  both are known, match the team file's `orchestrator` record, and it counts
  as live at any age (`teamOwnedBy`, spec 0057 §2.4).
- **roster.mjs is already right.** `resolveTeamFileScope`
  (roster.mjs:1460-1485), for `OWNED_TEAM_VERBS` (roster.mjs:199: create,
  spawn-one, spawn-ad-hoc, dismiss, disband, untrack, resync, move, deliver,
  answer and the stream verbs), works like this without `--team`:
  - it uses the one owned team when there is exactly one;
  - with more than one, it refuses and lists them: "this session owns N live
    teams (…) — pass --team <name> to say which";
  - with none, it falls back to the repo-named team.

  `ownedLiveTeams` (roster.mjs:1489-1496) finds the owned teams. No test
  covers the refusal.
- **The two ownership rules differ.**
  - roster.mjs uses `teamOwnedBy` (lib-roster.mjs:1112-1117). The pid must
    be equal and alive, and the session ids must not conflict, which happens
    only when both are present and differ.
  - roster.mjs and msg.mjs identify the caller by `--orchestrator-pid` or
    `CLAUDE_PID`, and by `--session` only when it's given, which is rarely.
  - The hooks identify the caller by `process.ppid` (the live Claude process)
    and the payload's session id.
  - So a resumed session (same session id, new pid) is recognised by the
    hooks and not by roster.mjs.
- **The hooks pick one team without saying so.** `resolveTeamScope`
  (lib-config.mjs:1338-1359) backs `resolveConfig`. Its steps, in order:
  1. `opts.team`;
  2. a team whose recorded session id equals the caller's (the pid isn't
     compared);
  3. a team with no recorded session id whose pid equals the caller's (no
     liveness check);
  4. the member-side steps (`AH_TEAM_FILE`, pane);
  5. none.

  Each step takes the first match and doesn't check for a second. So:
  - SessionStart's HIERARCHY STATE block (`roster()`, lib-hier.mjs:924-984)
    shows one team's members, and the other team is missing without notice;
  - the route gate's live-peer check for a chain-role dispatch
    (pretooluse-route-gate.mjs:211, :227-228, :287-289) sees one team. With a
    live peer only in the other team, it acts as if there is none.
- **Sending to a member already works across teams.** SendMessage `to` goes
  through `resolveMemberTeam` (route-gate.mjs:246-255), which searches every
  team by member name.
- **`msg.mjs new` and `list` pick one team without saying so.**
  `resolveTeamArg` (msg.mjs:116-150) takes the first team whose pid matches,
  in directory order.
- **The directive and status are one team's.**
  - `buildDirective` (lib-config.mjs:2947-2998) and the HIERARCHY STATE block
    are built at SessionStart only.
  - Each chain-role line (`roleLines`, :2724-2744) takes its peer target from
    the team prefix or the role's `peer` entry. It prints `roster.mjs
    spawn-one|spawn-ad-hoc <role> --cwd …` without `--team`: `spawn-one` when
    the team's roster template has a row for the role (`rosterMemberFor`,
    :503-506), else `spawn-ad-hoc`.
  - `statusReport` (`/hierarchy status`, :3051-3138) prints one team's roster
    table and team line.
- **Other single-team readers:**
  - `roleSetPrefix()` (roster.mjs:1905-1908) checks a new custom role's name
    against the first owned team's prefix only.
  - `doctor`'s team row (roster.mjs:1277-1294) doesn't look at ownership at
    all (`doctor` isn't in `OWNED_TEAM_VERBS`).
  - pretooluse-msg-gate.mjs (:78-83) uses the resolved team's prefix.
  - stop-orchestrator-liveness.mjs (:65, :142) uses the resolved team's open
    exchanges.
  - posttooluse-roster.mjs tags records by member name (`teamTagFor`,
    :24-30), and uses the resolved team only for display.
- **Layout.** tmux opens one window per member. herdr names each agent by its
  member name. `teamLayout` is a global preference used only at create time.
  Nothing in the layout is shared between two live teams.
- **The skill** (skills/agent-team/SKILL.md):
  - It asks the team name in one question unless the user named it (:375-393).
  - It asks which roster in the same question call, only when the plan lists
    `named_rosters` (:395-407).
  - It asks each model in the same round, at most 4 questions per call
    (:409-427).
  - It calls ListAgents once, and captures names-in-use once per team name
    (:349-367).
  - It says nothing about two teams in one request.
  - :130-131 says that without `--team`, a session that doesn't own exactly
    one team gets the repo-named team. For two owned teams that's wrong: the
    CLI refuses.
- **Skill-text tests** grep exact strings in SKILL.md
  (tests/test-team-identity.sh:682-686, E2/E2b). SKILL.md has no size
  ceiling.

## 3. Goals and non-goals

**Goals**
- One session can own any number of live teams, and every ah surface either
  shows all of them or refuses with the list. Nothing picks one without
  saying so.
- A request naming teams and rosters is carried out with no question the
  user's words already answer.
- Every question for every team is asked in one round.
- Afterwards the user refers to teams by name, and ah passes `--team`.

**Non-goals**
- Sub-orchestrators (spec 0067).
- Moving a member between teams (the existing `move` verb).
- Any change to team file format, member naming or roster resolution.

**Migration:** none. A session with at most one team behaves as today, and
its injected text is byte-identical.

## 4. Part A — one session, several live teams

**One rule for every surface.** When the session owns more than one team
and the command gives no `--team`:
- A surface that only shows state shows every owned team, each part under
  its team's name.
- A surface that acts (writes, spawns, destroys, sends) acts on the team
  named by a member name. With no member name, it refuses and lists the
  teams.
- Nothing picks a team without saying so.

### 4.1 One definition of "the teams this session owns"

The owned-team rule is one implementation, in a shared lib. Every place that
asks whether a caller owns a team uses it:
- roster.mjs: `ownedLiveTeams`, `roleSetPrefix`, and every other caller of
  `teamOwnedBy`;
- `resolveTeamScope` in lib-config.mjs;
- `resolveTeamArg` in msg.mjs.

The rule tests one team against the caller's identity (pid, session id).
The team is owned when either of these holds:
- **Same session:** the caller's session id and the team's
  `orchestrator.session_id` are both present and equal. The pid is not
  compared.
  - This arm matters only for a team that recorded a session id, and only
    `create --commit --session <id>` writes one. The skill doesn't pass
    `--session`, and `spawn-one` records none.
  - So in the normal flow, a resumed session (new pid) owns none of its
    teams, as before this spec. It re-claims each one with `roster.mjs adopt
    --orchestrator-pid <new pid> --team <T>` (docs/troubleshooting.md:77-81).
  - Whether to make resumed ownership automatic is Q8.
- **Same process:** the team's `orchestrator.pid` equals the caller's pid,
  and the session ids don't conflict. They conflict only when both are
  present and differ.

Why this rule:
- It accepts every team that either of today's two rules accepts.
- It tests each team on its own, so the answer for one team never depends
  on which other teams exist.
- It keeps every existing ownership row green:
  - the hooks' session match with a different pid: test-roster-multi-team
    17b and 20, test-route-wall 21e, and test-team-lifecycle-names N6, G2,
    N7, N7b, N14 and N18;
  - a conflicting session id beating a pid match: 21d;
  - roster.mjs's pid rule.

It accepts more than today in two cases, both on purpose:
- roster.mjs and msg.mjs, when given `--session`, recognise a resumed
  session's teams, if those teams recorded a session id. Today they don't.
- A hook caller with no session id (statusReport, posttooluse-roster)
  accepts a pid match on a team that recorded a session id. roster.mjs
  already does this today. The hooks' current rule requires the team to have
  no session id.

**Liveness belongs to the identity, not to the rule.** The rule never calls
`pidAlive`.
- roster.mjs and msg.mjs keep today's check on their own pid (from
  `--orchestrator-pid` or `CLAUDE_PID`). A dead pid leaves the identity with
  no pid, so it can only match by session.
- The hooks don't check `process.ppid`, as today. It is the live Claude
  process, and test-route-wall 21a uses a fake pid.

**The owned set** is every team the rule accepts:
- over the default team plus every `teams/*.json`;
- live at any age, as today;
- ordered default team first, then by team name. The two kinds of match
  aren't ranked.

A session that owns exactly one team gets that team, as today. If an
existing row fails only because of this order, stop and report it; don't
change the row.

**Order of steps in `resolveTeamScope`:** as today.
1. `opts.team`;
2. the owner rule;
3. the member-side steps (`AH_TEAM_FILE`, pane);
4. none.

Members are unchanged. A session with `AH_TEAM_FILE` belongs to exactly one
team. It matches no owner step, because neither its pid nor its session id
is recorded as any team's orchestrator.

### 4.2 roster.mjs verbs

- **Verbs with no member argument** (disband, resync, the stream verbs, and
  spawn-one or spawn-ad-hoc without `--member`) keep today's refusal when
  more than one team is owned. It is now covered by a test (M1).
- **Verbs that name one member:** `dismiss <name>`, `spawn-one --member
  <name>`, and every other `OWNED_TEAM_VERBS` verb whose arguments name a
  member. The Implementor lists them in the PR. When `--team` is absent and
  more than one team is owned:
  - resolve the team from the member name, over the owned teams only, with
    the existing name-keyed search (`resolveMemberTeam`);
  - exactly one owned team has that member: use it;
  - none or several: refuse as today, listing the owned teams.

  Member names embed their team (§2), so this almost always resolves. The
  user can say "dismiss bar-reviewer" without saying "team bar".
- **`create` without `--team`** while the session owns a team: today's
  behaviour is unchanged. With one owned team it targets that team (and
  refuses because the team is live). With several it refuses with the list.
  The skill always passes `--team` for a new team (§5), so this only matters
  for a bare create.
- **`teams`** already lists every team with an `own` flag.
  - `own` is computed with the §4.1 rule against `invokerIdentity()`, like
    every other ownership check. Today it compares the pid only
    (roster.mjs:4460).
  - Without `--session` the output is unchanged, because a caller with no
    session id can't conflict.
  - The JSON `name` stays `null` for the default team.
- **The default team has a name for `--team`: `@default`.**
  - The default team is `team.json`, the one that is used when no `--team`
    is given.
  - `@default` fails `validateTeamAlias`
    (`^[A-Za-z0-9][A-Za-z0-9-]{0,31}$`), so no named team can be called
    that.
  - `--team @default` means `team.json` in every roster.mjs verb that takes
    `--team`, and in msg.mjs. It is explicit, exactly like a named `--team`:
    no ownership fallback and no refusal for several owned teams.
  - Any other value outside the pattern is still refused.
  - Wherever ah prints a team name for the user or the model to pass back,
    the default team is shown as `@default`. That covers the refusal lists
    ("pass --team <name> to say which"), the lead line, the directive's team
    labels and printed commands, the route gate's text, and the section
    heads in `statusReport` and `msg.mjs roster`.
  - The `teams --json` schema doesn't change: its `name` stays `null`. The
    skill maps `null` to `@default` (§5.2).
  - Why: once the default team is owned beside a named team, its no-member
    commands (for example `spawn-one <role>`) have no other way to reach it.
    A reserved value goes through the existing `--team` parsing in every
    verb, whereas a new flag would have to be added to every verb's flag set.
- **Verbs outside `OWNED_TEAM_VERBS` that call `registry()`:** show, init,
  add, edit, remove, layout, alias, next-split, layout-splits, tier, adopt,
  teams, checkin, whoami, reap, history, role, pack, roster and doctor.
  - Most read nothing from the resolved team, and stay unchanged:
    - the template verbs resolve a roster by `--roster`;
    - role and pack definitions come from the config layers, not from a
      team;
    - `teams` and `whoami` already cover every team;
    - `checkin` resolves from the member side.
  - The PR lists each verb and says whether its output reads the resolved
    team's name, its roster template or its members. Any verb that does
    follows the rule at the top of §4.
  - Two are known to read the resolved team, and change:
    - **`roleSetPrefix()`**, used by `role set` for a custom role, checks the
      new name against every owned team's prefix. A collision with any team
      refuses and names that team. The Herdr 32-character warning is given
      for each owned team whose `<prefix>-<name>` is too long, naming it.
    - **`doctor`'s team row**, with more than one owned team, names every
      owned team and its roster selection.

    With at most one owned team, both behave as today.

### 4.3 What gets injected

When `resolveTeamScope` finds more than one owned team, it must report all of
them. A single team isn't enough. The Implementor decides the shape, and the
behaviour must be:
- **SessionStart, and every other place that injects the HIERARCHY STATE
  block:**
  - Text built from a team or its roster (members, live peers, routes, open
    exchanges) appears once per owned team, in the §4.1 order, each under a
    line naming the team and its roster.
  - Each team's part uses that team's own resolved config, so its roster
    (for example `rosters.X`) decides its routes and models.
  - Text that doesn't depend on a team (the protocol, the tier line) appears
    once.
  - One extra line goes first: "You own N live teams: foo, bar. Pass --team
    <name> to roster.mjs team verbs and to msg.mjs new; a member name
    already says its team."
    - The default team is listed as `@default` (§4.2).
    - msg.mjs `list` isn't named in the line, because it covers every owned
      team without `--team` (§4.6). `--team` only narrows it.
- **The directive's role lines** (`roleLines` in `buildDirective`):
  - For each role, every owned team gets its own peer target, taken from its
    prefix or its explicit `peer` entry.
  - Each team gets its own verb: `spawn-one` when that team's roster
    template has a row for the role, else `spawn-ad-hoc`.
  - Every printed roster.mjs command carries `--team <T>`, because without
    it roster.mjs refuses. The default team's commands carry `--team
    @default`.
  - The Implementor picks the shape: a block of role lines per team, or one
    line per role with a part for each team. Either way the text must stay
    correct when two teams differ in verb, in target, or in whether the role
    is a peer at all.
  - Text that belongs to the role only (label, tag, the "Can't launch"
    pointer) may appear once per role.
- **`statusReport`** (`/hierarchy status`) follows the same rule:
  - each owned team's roster table and team line appear under its name;
  - the lead line comes first;
  - lines that don't depend on a team appear once.
- **At most one owned team:** the directive, the HIERARCHY STATE block and
  `statusReport` are byte-identical to today, with no `--team` added.
  test-custom-roles.sh's golden files and test-directive-size.sh stay green
  unchanged.
- **Size.** For a two-team fixture with 5 members each, report the injected
  byte count.
  - If it is over test-directive-size.sh's confirm ceiling (16,500 bytes),
    first fold every role line that is byte-identical across all owned teams
    into one shared line, then measure again.
  - If it is still over, stop and report both numbers to the Architect.
  - Don't trim other text to make room.

### 4.4 Route gate

- **Chain-role dispatch** (Agent or Task with a chain role's `subagent_type`):
  the live-peer check covers every owned team.
  - If one or more owned teams have a live peer for that role, act as today
    for a live peer, but name each one with its team ("foo-architect (team
    foo), bar-architect (team bar): SendMessage the one whose team owns this
    work").
  - If none has one, give today's no-live-peer outcome, with its text built
    per team as the directive's role lines are (§4.3):
    - one spawn command per owned team, each with that team's own verb,
      `--team <T>` (`@default` for the default team) and its own prefix in
      the `--names-in-use` hint;
    - then "run the one for the team that owns this work".

    With at most one owned team, the text is byte-identical to today.
- **Checks that need one roster value** (the tier rule's role model, and
  anything else read from the session's resolved config): evaluate once per
  owned team. If any team's result is deny or ask, that is the result, and
  the message names the team it came from.
- **SendMessage** is unchanged (it already searches every team).

### 4.5 The other gates

The Implementor reads pretooluse-ultra-gate.mjs and pretooluse-msg-gate.mjs,
and every other caller of `resolveConfig` or `resolveTeamScope` that uses
the session's team. The PR lists each one, with what it did with two owned
teams before the change and after. The rule is the same as in §4.4:
- a lookup by member name searches every owned team;
- a decision that depends on a team's config is taken per owned team, and
  the strictest result wins (deny over ask over allow).

The behaviour required for each known caller follows. Where the
Implementor's current choice already does this, it stands.
- **pretooluse-route-gate.mjs:** as in §4.4.
- **The ultra-gate's `gateTarget`** (which ultra-advisor members a
  SendMessage is gated for):
  - when the caller owns teams, the ultra-advisors of every owned team;
  - when it owns none, today's scan of every team.

  A team the caller doesn't own is never gated for it. In
  test-roster-multi-team 17b and 20, the caller owns T by session and not
  U, whose session id conflicts. So `U-ultra-advisor` isn't gated.
- **pretooluse-msg-gate.mjs** (its check against `teamPrefix(cwd,
  resolved.team)`) treats the check as a lookup by name. The name belongs to
  whichever owned team's prefix it carries, and that team's config decides.
  A name that carries no owned team's prefix gets today's no-team outcome.
- **stop-orchestrator-liveness.mjs** counts the open exchanges of every owned
  team.
- **posttooluse-roster.mjs** keeps tagging records by member name. Any text
  it prints about a member uses that member's team's prefix.
- **doctor:** as in §4.2.

If a caller can't follow this rule without a design choice, stop and report
it.

### 4.6 msg.mjs

- **`new` without `--team`,** when the session owns more than one team:
  - if `--to-name` is a member of exactly one owned team (the same
    name-keyed search), use that team;
  - otherwise refuse, exit non-zero, list the owned teams and say to pass
    `--team`. Nothing is written.
- **`list` without `--team`,** in the same case: cover every owned team, and
  every row carries its `team`. `index`, `downstream` and `sweep` follow
  `list` if they list exchanges; the PR says which do.
- **`roster` without `--team`,** in the same case: print every owned team's
  table, each under a line naming the team and its roster, in §4.1 order. It
  only reads, so it doesn't refuse (the rule at the top of §4). Any other
  msg.mjs verb that acts, and names no member, refuses with the list.
- **Members and single-team sessions:** unchanged.

### 4.7 Not changed

- Team files, member naming, the `orchestrator` record, and the 24-hour cap
  for other sessions' teams. `teamOwnedBy` changes only as §4.1 says.
- `reap` and `teamIsOrphaned`. This is a known limit:
  - a team owned only by session (it recorded a session id, and its
    recorded pid is dead) still looks orphaned to another session;
  - that session's `reap --commit` can delete it.
  - `adopt` re-stamps the pid and ends that.
  - It is reachable only through `--session`, so the normal flow doesn't
    hit it. Q8 covers making it automatic.
- `AH_TEAM_FILE` and member-side resolution.
- stop-peer-nudge.mjs, which is team-agnostic.
- pretooluse-disband-close-gate.mjs. Its confirmation text reads the
  command's own `--team`. A bare disband with several owned teams is refused
  by roster.mjs before anything is destroyed. The prompt may show the
  default team's names for that refused command, which is cosmetic.
- The pretooluse-roster-skill-gate one-shot rule.

## 5. Part B — the create flow in plain words (skills/agent-team/SKILL.md)

### 5.1 New subsection: "Several teams in one request"

It goes in § Create, before step 0. Its content, in order, follows. The
Implementor may tighten the wording, but must keep the quoted anchor strings
exactly, because tests grep for them (§7, K-rows).

1. **Read the request into a list of teams first,** each with its roster,
   before any command runs. Anchor: "**Several teams in one request.**"
   Rules:
   - "team foo from roster X": foo builds from X.
   - Several teams and several rosters in one phrase ("teams foo and bar
     from rosters X and Y", "set up foo and bar using the foo and bar
     rosters"): pair them in the order given.
   - One roster for several teams ("both from X", "same roster for both"):
     every team uses it.
   - "A team per roster" or "a team for each of X and Y": one team per named
     roster, and the team takes the roster's name.
   - "the foo team from its roster" or "from the foo roster" with no other
     roster word: the roster is `foo`.
   - A team with no roster named: today's rule (the selected roster; the
     roster question only when the plan lists `named_rosters`).
   - Counts that don't pair (two teams, three rosters): settle it with one
     roster question per team, in the round of step 4.
   - "A team per roster" with no rosters named: one multi-select question
     listing `roster.mjs roster list --json` names, the selected roster
     first. Anchor: "a team per roster".
   - The same team name twice: ask once for a different name for the later
     one.
   - Never ask the team-name question for a team the user named. Never ask
     the roster question for a team whose roster the user named. Anchor:
     "never ask what the request already says".
2. **One `ListAgents` call for the whole request.** Anchor: "one `ListAgents`
   call for the whole request".
   - Each team's names-in-use set comes from that one result, by its own
     `<team>-` prefix.
   - It is captured once per team and passed unchanged to that team's
     phases, as today.
3. **Plan each team, one after another** (plans can write: they clear a
   stale team): `create --plan --team <T> [--roster <r>]
   [--names-in-use …]`, with `--team` always given, even when the plan's
   derived name would match.
   - A plan that refuses because the roster is missing (spec 0064 §3.4
     lists the defined rosters): that team's roster joins the step 4 round,
     with the defined rosters as options and the selected one first.
   - A plan that refuses because a live team with that name exists: tell
     the user, and put "another name for <T>, or skip <T>" in the step 4
     round.
   - A plan that refuses with `team-name-unusable`: offer its `suggestion`
     in the step 4 round, as today.
4. **One question round for every team.** Anchor: "one question round for
   every team".
   - It contains only:
     - the team names the user didn't give;
     - the rosters still unsettled;
     - each team's `members_needing_model`;
     - the layout, only if the user asked to change it. One `--mode` applies
       to every team unless the user named one per team.
   - At most 4 questions per AskUserQuestion call, with further calls as
     needed, team by team.
   - Every question's header and text name its team.
   - Re-plan each team whose flags changed.
5. **Spawn, then check in and commit, team by team.** Anchor: "team by team,
   never in parallel".
   - Run `--spawn` for each team in turn. The next team's spawn may start
     while the earlier team's sessions boot.
   - Then each team's check-in and `--commit`, each with that team's own
     `--team`, `--roster`, `--names-in-use` and `--member-model` flags.
   - A team that fails doesn't undo the others. Report it, and ask once
     whether to retry it.
6. **Report one line per team:** "Team foo (roster X): foo-architect,
   foo-implementor, …". Then: "You now own N teams. Name the team when you
   ask for something ('disband foo'); a member's name already says its team
   ('dismiss bar-reviewer')."

### 5.2 Other skill-text changes

- **:126-135 (`--team`).**
  - "each owned by a distinct orchestrator session" becomes "owned by one
    orchestrator session or several".
  - Replace the "Omitted, …" sentence with the §4.2 rule:
    - omitted, with exactly one owned team: that team;
    - with more than one: a verb that names a member resolves from the name,
      and every other verb refuses with the list;
    - with none: the repo-named team.
- **New paragraph after § Create: "Owning more than one team."** Anchor:
  "**Owning more than one team.**" Its content:
  - While this session owns more than one live team, pass `--team` to every
    roster.mjs team verb and to `msg.mjs new`. A verb that names a member
    may leave it out. `msg.mjs list` covers every owned team, and `--team`
    only narrows it.
  - The default team is `--team @default`. In `roster.mjs teams --json` it is
    the row whose `name` is `null`.
  - When the user's words don't say which team ("disband the team"), ask one
    AskUserQuestion listing the owned teams (`roster.mjs teams`, `own:
    true`), or with multi-select when the request can cover several
    ("disband the teams").
  - Each disband keeps its own confirmation.
- **SKILL.md:513-516**, the sentences after "Every subsequent step (…)
  then needs that same `--team <name>`". Two claims in them hold only while
  the session owns exactly one team:
  - roster.mjs team verbs "resolve the Team it owns without the flag";
  - `msg.mjs new`/`list` "auto-resolve the active team".

  State both as true only with one owned team. With several, point to
  **Owning more than one team.** Anchor: "only while this session owns just
  that one team". The rest of the passage (the `CLAUDE_PID`/`pidAlive`
  explanation, "pass `--team <name>` explicitly whenever you are not
  certain") stays.
- **Kept byte-for-byte**, because tests grep them:
  - "Team name — one question, every create";
  - "Run a bare `roster.mjs create --plan`";
  - "Roster — only when the plan lists `named_rosters`";
  - "same** AskUserQuestion call as the team name";
  - "re-run the plan with";
  - "needs_user_choice: false".

  The single-team flow is unchanged. The new subsection sends
  several-team requests down it once per team.

### 5.3 Docs

- **docs/getting-started.md:** a short "Several teams" paragraph at the end
  of "## 5. Spawning a team" (:112-120). It gives one plain example
  sentence, and says that later requests name the team.
- **docs/cli-tools.md:** the `--team` rule from §4.2 (including `--team
  @default`) and the `msg.mjs` rule from §4.6, where `--team` is described.
- **skills/agent-roster/SKILL.md:** no change. It already lists the teams
  per roster (:124).

## 6. Files

- `agent-hierarchy/hooks/lib-config.mjs`: `resolveTeamScope` reports every
  owned team (§4.3), on the shared rule (§4.1).
- A shared lib holds the §4.1 rule. The Implementor picks lib-roster.mjs or
  lib-hier.mjs, whichever roster.mjs, lib-config.mjs and msg.mjs can all
  import without a cycle.
- `agent-hierarchy/hooks/lib-roster.mjs`: `teamOwnedBy` becomes the §4.1
  rule, or is replaced by it. Either way no second ownership test remains.
- `agent-hierarchy/hooks/roster.mjs`: `ownedLiveTeams` calls the shared rule,
  with the pid liveness check in `invokerIdentity`. Member-named verbs
  resolve from the name. `roleSetPrefix` and `doctor`'s team row change as
  in §4.2.
- `agent-hierarchy/hooks/lib-config.mjs`: `buildDirective`/`roleLines` and
  `statusReport` (§4.3).
- `agent-hierarchy/hooks/lib-hier.mjs` (`roster()`, `buildStateBlock`), plus
  the SessionStart injector: the per-team blocks (§4.3).
- `agent-hierarchy/hooks/pretooluse-route-gate.mjs` (§4.4);
  pretooluse-ultra-gate.mjs, pretooluse-msg-gate.mjs,
  stop-orchestrator-liveness.mjs and posttooluse-roster.mjs (§4.5).
- `agent-hierarchy/hooks/msg.mjs` (§4.6).
- `agent-hierarchy/skills/agent-team/SKILL.md` (§5.1, §5.2).
- `agent-hierarchy/docs/getting-started.md` and
  `agent-hierarchy/docs/cli-tools.md` (§5.3).
- New `agent-hierarchy/tests/test-multi-owned-teams.sh` (§7).
- Version: the next ah minor, in `agent-hierarchy/.claude-plugin/plugin.json`
  and in ah's entry in `.claude-plugin/marketplace.json`, together.

## 7. Tests

The mutation standard applies (docs/spec-process.md): every row must be
seen failing against a deliberately broken build. Suggested mutations are
in brackets. Sandboxes redirect HOME and fake `CLAUDE_PID`, as
tests/test-roster-multi-team.sh does. One pid owns team `foo` and team `bar`
throughout unless a row says otherwise.

**Part A**
- **M1 Bare verbs refuse.** `disband`, `resync`, `spawn-one reviewer` and
  `stream-status` with no `--team` exit non-zero and list both teams.
  Nothing is written. [take the first owned team]
- **M2 A member name picks the team.** `dismiss bar-reviewer --plan` with no
  `--team` plans against `bar`. A name in neither team is refused with the
  list. [skip the name lookup]
- **M3 One owner rule.** roster.mjs (given `--orchestrator-pid` and
  `--session`), `resolveTeamScope` and msg.mjs, given the same pid and
  session id, agree on the owned set:
  1. same session id, different pid: owned;
  2. same pid, conflicting session ids: not owned;
  3. same pid, team has no session id: owned;
  4. same pid, caller has no session id, team has one: owned;
  5. roster.mjs and msg.mjs with a dead pid and no `--session`: nothing
     owned.

  Mutations:
  - [let msg.mjs keep its own pid scan];
  - [drop the same-session arm];
  - [require a session-less team for a pid match];
  - [check liveness inside the rule, which breaks test-route-wall 21a].
- **M4 Injection:**
  - with two owned teams from rosters X and Y, SessionStart's text has both
    teams' parts, each with its own members and routes, and the lead line;
  - the directive's role lines name `foo-architect` and `bar-architect`,
    and each printed command carries its own `--team`;
  - where X has an architect row and Y doesn't, foo's command is `spawn-one`
    and bar's is `spawn-ad-hoc`;
  - with one owned team it is byte-identical to a golden file captured
    before the change.

  Mutations: [render only the first team], [use the first team's verb for
  every team], [leave out `--team`].
- **M5 Route gate:**
  - a chain-role dispatch with a live `bar-architect` and none in `foo`
    gets the live-peer outcome naming `bar-architect (team bar)`;
  - with none in either, the no-live-peer outcome.

  [check only the first team]
- **M6 Strictest wins.** A check that allows for `foo` and denies for `bar`
  denies, naming `bar`. [take the first team's result]
- **M7 msg.mjs:**
  - `new --to-name bar-reviewer` with no `--team` writes `team: bar`;
  - `new` to a name in neither team refuses and writes nothing;
  - `list` with no `--team` returns both teams' rows, each tagged.

  [first owned team]
- **M8 Single team.** Every M-row's command, run with one owned team, gives
  today's output. [treat one owned team as several]
- **M9 Reads show every team:**
  - `/hierarchy status` (`statusReport`) and `msg.mjs roster` with no
    `--team` print both teams' sections, each named, and exit 0;
  - `doctor`'s team row names both teams.

  [print only the first team] [make msg.mjs roster refuse]
- **M10 `role set` checks every prefix.** A custom role name that collides
  only with `bar`'s prefix is refused, naming `bar`. A name too long only
  under `bar`'s prefix gets the Herdr warning naming `bar`. [check only
  `owned[0]`]
- **M11 The other gates:**
  - the ultra-gate gates `bar-ultra-advisor` for a caller that owns `foo`
    and `bar`, and doesn't gate a sibling team the caller doesn't own;
  - stop-orchestrator-liveness counts an open exchange that exists only in
    `bar`;
  - msg-gate resolves a `bar-` name against `bar`'s config.

  [scope each to the first owned team]
- **M12 The default team's name.** The session owns `team.json` and `foo`.
  - `spawn-one reviewer --team @default --plan` plans against `team.json`.
  - The directive's default-team commands, the refusal list and the lead
    line all show `@default`.
  - pretooluse-ah-cli allows a `roster.mjs … --team @default` command, as it
    does for a named `--team`.
  - `--team @other` is refused.

  [omit `--team` for the default team], [reject `@default` in validation],
  [accept any `@` value]
- **M13 Route gate, no live peer, several teams.** With two owned teams and
  no live architect, the deny text has one spawn command per team, each
  with its own verb, `--team` and `--names-in-use` prefix. With one owned
  team, it is byte-identical to today. [print one bare command]
- **M14 `teams` `own`.**
  - `--session S` against a team that recorded `S` under a dead pid:
    `own: true`.
  - A recorded session that conflicts, with the same pid: `own: false`.
  - No `--session`: today's output.

  [compare the pid only]

**Part B.** Skill-text rows, in the test-team-identity.sh E2 style: exact
`grep -q` checks on SKILL.md.
- **K1** Each §5.1 and §5.2 anchor is present.
- **K2** Every string §5.2 says to keep is still present.
- **K3** The subsection comes before step 0 (`**Several teams in one
  request.**` appears before `0. **Layout`).
- **K4** The :513-516 anchor "only while this session owns just that one
  team" is present, and the paragraph **Owning more than one team.** names
  `--team @default`.

Skill text can't be run under the mutation standard. For K1 and K2, the
mutation is to delete the anchor and see the row fail.

**Unchanged suites.** The full existing suite passes unchanged, including
test-custom-roles.sh, test-directive-size.sh, test-team-identity.sh,
test-roster-multi-team.sh, test-route-wall.sh (21a, 21d, 21e),
test-team-lifecycle-names.sh and test-team-stale.sh.
- The §4.1 rule is chosen so that every ownership row stays green.
- If a row still fails, stop and report the row and why. Don't change the
  row, and don't add a second rule to pass it.

**Size evidence.** §4.3: report the two-team byte count in the PR.

## 8. Build order

1. The shared owner rule (§4.1) and M3. Run the full existing suite here:
   every ownership row must be green before step 2.
2. roster.mjs and msg.mjs (§4.2, §4.6) with M1, M2, M7, M10 and the msg.mjs
   and doctor parts of M9.
3. `resolveTeamScope`, the directive, the state block, `statusReport` and
   the gates (§4.3–§4.5) with M4–M6, M8, the rest of M9, M11 and the size
   measurement. The size measurement can send the build back to the
   Architect.
4. Skill and docs (§5) with K1–K3.

## 9. Assumptions not verified

- `resolveMemberTeam` can be limited to the owned teams without changing
  what SendMessage resolution does today. If it can't, the Implementor adds
  the restriction in the caller, not in the shared search.
- The msg-gate's prefix check (:78-83) is a lookup by name, as §4.5 treats
  it. Its exact purpose wasn't read. If it's a decision that doesn't reduce
  to "which team is this name", stop and report.
- `reap` and `history` were not traced. §4.2 has the PR confirm that they
  don't read the resolved team.
- `OWNED_TEAM_VERBS` includes deliver, answer and the stream verbs, which
  spec 0057 §2.4 doesn't list. This spec treats the code's list as current.

**Noticed, not in scope:**
- `doctor`'s team row ignores ownership even with one owned named team, so
  it can show a team other than the session's. This spec changes only the
  several-team case.
- `adopt`'s guard against taking over a live team checks the pid only, not
  the session id.

## 10. Open questions for the user (the spec proceeds on the defaults)

- **Q1** A bare team verb when the session owns several teams: refuse and
  list them (default, today's roster.mjs behaviour), or act on the most
  recently created team.
- **Q2** `msg.mjs new` with no `--team`: take the team from the recipient's
  name (default), or always require `--team` once several teams are owned.
- **Q3** Spawning several teams: one after another (default), or in
  parallel.
- **Q4** "A team per roster" with no rosters named: ask with a multi-select
  (default), or build one team for every defined roster.
- **Q5** One team fails during create: keep the others and offer a retry
  (default), or roll every team back.
- **Q6** Gates with several owned teams: the strictest team's result wins
  (default), or the result of the team the dispatch belongs to. That second
  choice needs the dispatch to name a team, which Agent/Task can't do today.
- **Q7** Commands that only show state (`/hierarchy status`, `msg.mjs
  roster`, `doctor`) with several owned teams: show every team (default), or
  refuse and ask for `--team`, as the acting verbs do.
- **Q8** Should a resumed orchestrator (same session id, new pid) keep its
  teams automatically?
  - **Default: not in this spec.** Teams record no session id in the normal
    flow, so a resumed session re-claims each team with `adopt`, as before
    this spec.
  - **If the user says yes**, a later change would:
    1. record the session id at `create --commit`, from `--session`, else
       from `CLAUDE_CODE_SESSION_ID`, which Bash sees (roster.mjs:5037
       already reads it);
    2. have `invokerIdentity` in roster.mjs and msg.mjs read `--session`,
       else `CLAUDE_CODE_SESSION_ID`;
    3. at SessionStart with source `resume`, re-stamp `orchestrator.pid` to
       `process.ppid` for each team matched by session whose recorded pid is
       dead. This follows `adopt`'s guard: never when the recorded pid is
       alive. It also ends the `reap` limit in §4.7.
    4. clear `CLAUDE_CODE_SESSION_ID` in test sandboxes unless a row sets
       it.
  - **Evidence needed first (E1):** does a peer launched by roster.mjs
    (tmux, herdr, terminal) see its own `CLAUDE_CODE_SESSION_ID` in Bash, or
    the orchestrator's? Compare `echo $CLAUDE_CODE_SESSION_ID` in the
    orchestrator and in a spawned peer, with the peer's hook payload
    `session_id`.
    - Its own: steps 1 to 4 as written.
    - The orchestrator's: drop step 2, because every peer would own its
      orchestrator's teams. Step 1 stays, since it runs only in the
      orchestrator. Step 3 then gives the CLI the new pid.
    - Subagents sharing the parent's id is fine, because they are the same
      session.

## 11. Decisions and confidence

- One owner rule for roster.mjs, the hooks and msg.mjs. Today they disagree,
  and that disagreement is the bug.
  - The rule accepts every team that either of today's rules accepts, and
    tests each team on its own.
  - A tiered rule (session matches first, pid matches only when there are
    none) was rejected. Its answer for one team would depend on the other
    teams. It would drop a team that is really owned when one team matched
    by session and another by pid, and quietly dropping a team is the bug
    this spec fixes.
  - Keeping the hooks' old steps in front of the shared rule was rejected
    too, because that is two rules.
- Part A extends roster.mjs's existing "refuse and list" behaviour to every
  surface, and adds only the member-name shortcut. That keeps the change
  small and never guesses a team.
- Byte-identical output for at most one owned team, so nothing changes for
  today's users.
- Part B is skill text only. The CLI already has every flag the flow needs.
- **Confidence:** Part A high. Part B medium-high: plain-language parsing is
  model behaviour, and only its text is testable.

## 12. Results

Filled in by whoever lands the change, after it lands (docs/spec-process.md).
