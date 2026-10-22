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
- **Upstream:** the code comes from github.com/assafcaf/herdr-claude-setup (MIT, by assafcaf).
  Keep his copyright line in LICENSE. To pull in upstream fixes, diff against
  `claude/{hooks,scripts,skills}` in a clone of that repo. Changes made here: paths use
  `${CLAUDE_PLUGIN_ROOT}`, examples are generic, `CC_HERDR_ALLOWED_AGENTS` was added, and
  `evidence-reviewer` was removed from the built-in allowlist.
