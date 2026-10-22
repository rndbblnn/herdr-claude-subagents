# herdr-claude-subagents

A Claude Code plugin that makes delegated agents visible in [Herdr](https://herdr.dev).

## The problem

Claude Code's built-in subagents (the `Agent` tool) run **in-process**. They have no
terminal, no process and no session id of their own. Herdr finds agents by looking at what
runs in each pane, so these subagents never appear in its agent list. You can't watch one
work, answer its question, or interrupt it. No hook can change that, because Herdr needs a
real pane to report on.

## What this plugin does

It stops trying to make subagents visible. Instead, a delegated agent becomes a **real,
named `claude` session in its own Herdr pane**:

```
workspace
├── tab "2"            you, the orchestrator
└── tab "review-auth"  one tab per task
    ├── pane reviewer  one pane per agent
    ├── pane tester
    └── pane docs
```

It has three parts:

| Part | What it does |
|---|---|
| `scripts/herdr-spawn.sh` | Starts one named session in a pane, in the task's tab (the tab is created on first use). It makes the Herdr agent name, the Claude Code peer name and the session id all match, so `herdr agent read reviewer` and `SendMessage({to: "reviewer"})` reach the same pane. It also tells the child who spawned it, so the child can message results back. |
| `skills/herdr-spawn` | Teaches Claude to spawn, drive and tear down a team. |
| `hooks/route-agent-to-herdr.sh` | A `PreToolUse` hook on `Agent`. **Inside Herdr only**, it blocks subagent types that can write files or run long, and points Claude to the spawner. Read-only lookups (`Explore`, `claude-code-guide`, `statusline-setup`) still run in-process. |

## Install

```
/plugin marketplace add rndbblnn/herdr-claude-subagents
/plugin install herdr-claude-subagents@herdr-claude-subagents
```

Requirements: Herdr with its Claude integration installed (it reports panes as agents), and
bash plus awk. `jq` isn't needed. `node` is needed only for `--trust`.

## Configure

| Setting (env, e.g. in `settings.json` → `env`) | Effect |
|---|---|
| `CC_HERDR_ALLOWED_AGENTS=bulk-reader,my-auditor` | More agent types that may stay in-process. List your own read-only agents here. |
| `CC_ALLOW_INPROCESS_AGENTS=1` | Turns the redirect off for a session. |

The hook does nothing outside Herdr (`HERDR_ENV != 1`), so installing the plugin changes
nothing in a plain terminal.

## Use

Claude picks this up on its own once the hook redirects a call. To spawn by hand:

```bash
bash "$CLAUDE_PLUGIN_ROOT/scripts/herdr-spawn.sh" reviewer \
  --task review-auth --orchestrator <your session name> \
  --prompt "Review the diff on this branch. Report findings only."

herdr agent get reviewer      # idle | working | blocked | done
herdr tab close <tab id>      # tear the team down
```

Run `herdr-spawn.sh --dry-run ...` to print the herdr commands without running anything.

## Troubleshooting

- **`herdr agent start failed for 'x' in pane …`**: the child is probably stuck on Claude
  Code's "do you trust this folder?" dialog. `herdr pane read <pane>` will show it. The
  spawner checks for this up front; pass `--trust` only for a directory you would trust yourself.
- **Name already taken**: live agent names are unique. Close the old tab first.
- **Child came up in the wrong permission mode**: a mode you switched with shift+tab doesn't
  carry over. Pin it with `-- --permission-mode acceptEdits`.

## License

MIT
