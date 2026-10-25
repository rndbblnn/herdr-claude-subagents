# herdr-claude-subagents — notes for working on this repo

- **Bash + awk only, on purpose.** No jq: a stock Windows Git Bash lacks it, and a hook that
  needs a missing tool fails silently. `hooks/json-field.sh` is the shared parser.
  `scripts/herdr-spawn.sh` sources it via `../hooks`, so keep `scripts/` and `hooks/` as siblings.
- **The hook finds the plugin by its own location.** `route-agent-to-herdr.sh` derives the
  plugin root from its own directory and names `scripts/herdr-spawn.sh` and
  `skills/herdr-spawn/SKILL.md` in its refusal message. If you move either file, update the hook.
- **Hook exit codes.** 0 = allow, 2 = block (stderr goes to Claude). Outside Herdr it must
  always exit 0.
- **Why not make in-process subagents visible?** It can't be done: Herdr's
  `pane report-agent` needs a real pane id, and an in-process subagent has none.
- **The return path lives in the spawner, not the prompt.** With `--orchestrator`, the
  spawner appends a SendMessage-back instruction via `--append-system-prompt` (merging into a
  caller's own, since claude takes one value). Herdr passes it as a single argv element —
  verified 2026-10-23 with a live haiku probe that reported back unprompted.
- **`--agent` + a `tools:` whitelist strips SendMessage** (observed 2026-10-24: a ux-designer
  child typed its FINAL into the orchestrator's prompt via `herdr agent prompt`). With
  `--orchestrator`, the spawner re-emits the agent via `--agents` (which beats `.claude/agents`;
  verified with claude 2.1.310) with SendMessage appended. The frontmatter parser is awk and
  handles only scalars, `[a, b]`/`- a` lists and `|`/`>` blocks; anything else warns, unchanged.
  Its JSON escaper loops over characters on purpose: backslashes in a gsub replacement differ
  between awks.
- **Trust follows git (2026-10-24).** A submodule inside a trusted worktree stopped on the trust
  dialog (Claude recorded the submodule's own path), while a linked worktree of a trusted repo
  with no entry came up clean. The preflight counts entries between the cwd and its git
  toplevel, plus the main checkout's root for a linked worktree. `--trust` also sets
  `hasClaudeMdExternalIncludesApproved`: an engine repo whose CLAUDE.md @-imports a sibling
  showed that dialog right after trust was accepted.
- **Sidebar tags are display-only pane metadata** (`herdr pane report-metadata --source
  herdr-spawn`): `--display-agent` on both ends (the built-in `agent` token says "claude" for
  every Claude pane), `$team`/`$parent`/`$under` on the child. `$under` carries "↳ " because
  layouts can't hold literal text. They last until the pane closes, and failure only warns.
  Herdr has no agent-row indentation (only worktree Spaces nest), so "hierarchy" means these tags
  plus the default `spaces` sort. Verified live 2026-10-23.
- **`--close` is explicit, never status-driven.** Herdr's `done` fires after every turn,
  including a child waiting for an answer. Closing the last pane of a tab removes the tab
  (verified 2026-10-23), so `--close` only closes the pane. It refuses `$HERDR_PANE_ID`.
- **The orchestrator's display name goes stale** when it is renamed (resume or compaction:
  observed 5d→5e on 2026-10-23); children recover through ListAgents, the label does not.
- **Test before release:** `./test.sh` (hook allow/block matrix + spawner against a fake
  `herdr` that logs argv; `KEEP_T=1` keeps the logs), then `claude plugin validate .`. The fake
  `.claude.json` must be pretty-printed: the trust reader is indent-based.
- **Upstream:** the code comes from github.com/assafcaf/herdr-claude-setup (MIT, by assafcaf).
  Keep his copyright line in LICENSE. To pull in upstream fixes, diff against
  `claude/{hooks,scripts,skills}` in a clone of that repo. Changes made here: paths use
  `${CLAUDE_PLUGIN_ROOT}`, examples are generic, `CC_HERDR_ALLOWED_AGENTS` was added, the return path is automatic, and
  `evidence-reviewer` was removed from the built-in allowlist.
- **FINAL reports are files (2026-10-24).** `hooks/team-report.sh` is NOT in hooks.json: the
  spawner injects it per child with `claude --settings <file>`, so it travels with whichever
  spawner started the child and never runs in other sessions. Settings hooks merge with the
  user's (verified live, claude 2.1.310). It fires on PostToolUse(SendMessage) and on Stop
  (`last_assistant_message`, transcript fallback). A Stop echo never overwrites a SendMessage
  report of the same session: children often end with "FINAL: ... sent". It must exit 0 on
  every path, because a Stop hook that exits 2 keeps the child running.
- **`--reap` keys on the report file, not on status.** A file whose `session_id` differs from
  the pane's `agent_session.value` doesn't count (a stale file under a reused name), and a
  spawn deletes the old file for its name. `--oneshot` is the hook closing its own pane after
  Stop, detached via setsid with a 2s delay.
- **Naming the orchestrator.** A pane Herdr auto-detected has `name: null`. `herdr agent rename
  <pane> <name>` names it in place (verified, herdr 0.9.5). Herdr refuses uppercase, so the
  name is lowercased ("LaneB" becomes "laneb"). This is Herdr's name only: it can't change a
  Claude Code peer name, so a duplicate peer name in ListAgents never comes from here.
- **Herdr types the claude command into the pane's shell.** With a long argv (a re-emitted
  `--agents` JSON is ~2.6 KB), fish intermittently never ran it: a half-typed line with a
  stray `}}'` at the end, then the startup timeout. The bytes typed were intact (captured into
  `cat`), and the same argv passed 5 of 6 times, so it is a line-editor race. Mitigations: the
  `--settings` JSON goes in a file, the `--agents` JSON is pure ASCII (`\uXXXX`), and a failed
  `agent start` gets Ctrl-C and one retry. A scalar `tools: Read, Bash` used to be wrongly
  rejected as unparseable. It is fixed now, and a test covers it.
- **Sound: children should be silent, but Herdr can't fully do it (2026-10-24).** The operator
  wants sound only when a parent finishes or needs help. The report notification uses
  `--sound none`. Herdr's own state-change sounds (background workspaces only) can be muted
  only per agent *kind* (`[ui.sound.agents] claude = "off"`), which would silence parents too.
  Herdr 0.9.5 has no per-pane mute, and sound events are not logged, so none of this can be
  checked except by ear.
- **Session names (2026-10-25).** `hooks/session-name.sh` (in hooks.json: SessionStart,
  UserPromptSubmit, Stop) names unnamed sessions `<repo abbr>[-<lane>]-<slug of the AI title>`.
  Probed live with claude 2.1.310: a hook's `sessionTitle` is stored as both `customTitle` and
  `agentName`, so **it renames the peer name** (SendMessage address), and a custom title stops
  AI retitling for good. Only SessionStart/UserPromptSubmit may set it; the AI title exists
  after turn 1, so naming happens at prompt 2, once. "Has a name" = the transcript has a
  `customTitle` (unnamed sessions have none); then Herdr follows Claude, never the reverse.
  The spawner writes `herdr-spawn/orchestrators/$CLAUDE_CODE_SESSION_ID` and the hook won't
  rename such a session, or its children would lose their return address. The Herdr name is
  claimed first (unique, max 32) so the title uses exactly what Herdr accepted.
  Sidebar label: the hook reports `--display-agent` under source `herdr-spawn` only for
  unspawned panes, because a report replaces a child's `$nested`/`$under` tokens.
- **`herdr agent prompt` into a lane-b session typed without submitting** (2026-10-25, twice in
  a row; the next Enter sent both lines as one prompt). Not seen elsewhere; if a live test
  stalls, `herdr pane read` before assuming the hook failed.
