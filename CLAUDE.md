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
