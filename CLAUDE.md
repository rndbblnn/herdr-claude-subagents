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
- **Test before release:** `./test.sh` (hook allow/block matrix + spawner `--dry-run`), then
  `claude plugin validate .`.
- Upstream origin: developed in the author's `~/.claude`, where a private backup is kept.
  This repo is now the source of truth.
