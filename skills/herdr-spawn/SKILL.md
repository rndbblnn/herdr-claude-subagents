---
name: herdr-spawn
description: Spawn a team of named Claude sessions as Herdr panes instead of in-process subagents, so the operator can watch and interrupt them. Use when a task needs more than one agent, when delegated work will write files or run long, or when a PreToolUse hook has refused an Agent call and pointed here.
---

# Spawning a visible team

The `Agent` tool's subagents run in-process. They have no pane, no name and no session id, so
Herdr cannot see them and the operator cannot watch, prompt or interrupt one. This plugin
redirects that work into real panes for every repo — its `PreToolUse` hook
(`hooks/route-agent-to-herdr.sh`) blocks the Agent types that can write or run long, and
points here. Outside Herdr (`HERDR_ENV != 1`) the hook stands down and the Agent tool behaves
normally.

One spawn produces three identities that refer to the same agent:

| Identity | Used for | Set by |
|---|---|---|
| herdr agent name | `herdr agent get/read/prompt/wait <name>` | `herdr agent start <name>` |
| Claude Code peer name | `SendMessage({to: "<name>"})` | `claude --name <name>` |
| session uuid | the join key; `herdr agent list` reports it as `agent_session.value` | `claude --session-id <uuid>` |

`${CLAUDE_PLUGIN_ROOT}/scripts/herdr-spawn.sh` sets all three to agree, so after spawning `reviewer` you can
address it either way and mean the same pane.

## Topology

One tab per task, one pane per agent. The tab is labelled with the task slug and created on
first use; later agents for the same slug land beside their siblings.

```
workspace w7
├── tab "2"              you, the orchestrator
└── tab "review-auth"  the team
    ├── pane reviewer
    ├── pane tester
    └── pane docs
```

## Spawn

Get your own name from `ListAgents` — the first line names this session — and pass it as
`--orchestrator` so the child can message you back.

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/herdr-spawn.sh" reviewer \
  --task review-auth \
  --orchestrator my-session \
  --prompt "Review the diff on this branch. Report findings only; change nothing."
```

Spawn siblings with the same `--task`. Do the spawns one after another, not in parallel: each
one reads the tab's current pane list to decide where to split.

Useful options:

| Option | When |
|---|---|
| `--env KEY=VALUE` | anything else the child needs; repeatable |
| `--cwd <path>` | a different directory, e.g. a worktree of its own |
| `--trust` | the `--cwd` has not been trusted yet and you would answer yes — see trust below |
| `--wait --timeout <ms>` | you want the spawn call to block until the first turn settles |
| `--dry-run` | print the herdr commands without running them |
| `-- <claude args...>` | passed to `claude` verbatim — see permission mode below |

The spawner also labels the panes for Herdr's agent panel: each child shows its own name with
`$under` = "↳ <orchestrator>", and your pane shows your name. The README has the layout.

Every spawned pane receives `CC_TEAM_TASK`, `CC_TEAM_AGENT`, `CC_TEAM_ORCHESTRATOR`,
`CC_TEAM_ORCHESTRATOR_PANE` and `CC_TEAM_ORCHESTRATOR_SESSION_AT_START`.

The return path is automatic when you pass `--orchestrator`: the spawner appends a standing
instruction to the child's system prompt (`--append-system-prompt`) telling it to send results
*and task questions* to you with `SendMessage` instead of AskUserQuestion. You don't need to
repeat that in `--prompt`. Expect questions to arrive as peer messages; answer what you can and
ask the operator what you can't. Your own `-- --append-system-prompt` is kept, after ours.
Without `--orchestrator` the child has no way to find you.

`-- --agent <name>` limits the child to that agent's `tools:` whitelist, which usually lacks
`SendMessage`. With `--orchestrator`, the spawner re-emits the agent through `--agents` with
`SendMessage` added, so the return path still works; everything else about the agent is
unchanged. It warns instead (and spawns as given) for a plugin agent, an unknown name, your own
`--agents`, or frontmatter it can't parse (`hooks:`, `mcpServers:`, nested maps). After such a
warning, expect the child to report by typing into your pane, or not at all.

Pass `--orchestrator` from `ListAgents`, never from `$CLAUDE_CODE_SESSION_ID`. A
`claude --resume` gives the session a new messaging identity while the environment variable and
Herdr's `agent_session.value` both keep reporting the uuid from the original start — observed
2026-09-10, when the name moved from `rollout-collection-8c` to `rollout-collection-fc` and
neither of those two followed. `CC_TEAM_ORCHESTRATOR_PANE` is the handle that survives a resume;
the `_AT_START` variable is named for what it is and nothing should be built on it.

## Drive

Two channels, both addressing the same agent by name. Prefer `SendMessage` for instructions
and results, `herdr agent` for lifecycle and for seeing what is on screen.

```bash
herdr agent get reviewer                                      # idle|working|blocked|done
herdr agent read reviewer --source recent-unwrapped --lines 120
herdr agent wait reviewer --until blocked --timeout 120000    # it needs an answer
```

```js
SendMessage({to: "reviewer", message: "..."})                 // instructions, results
SendMessage({to: "reviewer", notify_when_idle: true})         // one-shot; never poll
```

`blocked` means Herdr recognised an approval or question dialog. Read the pane and ask the
operator before answering it — do not send keys at a dialog you have not looked at.

## Trust, the thing that will bite first

Claude Code gates every working directory behind a one-time *"Is this a project you created
or one you trust?"* dialog, recorded in `~/.claude.json` as
`projects["<cwd>"].hasTrustDialogAccepted`. Nothing on the command line answers it — `claude
--help` documents the dialog being skipped only in non-interactive mode (`-p`, or a non-TTY
stdout), which a pane is not.

So a spawn into an untrusted directory does not fail like a permission prompt. The session
sits on the dialog, never reports `interactive_ready`, and the spawner dies with

```
herdr-spawn: herdr agent start failed for 'x' in pane w7:pM
```

which names a pane, not a cause. `herdr pane read w7:pM` shows the dialog.

`herdr-spawn.sh` now checks this before it creates a tab or a pane, so a refusal costs
nothing and says which path it could not find. Trust follows git, not folders: a subdirectory
of a trusted repo is fine, and so is a linked worktree of one, but a nested repo (a submodule
checked out inside a trusted worktree) needs its own entry even though its parent is trusted.
Pass `--trust` to record the directory and spawn anyway — only for a directory you would have
said yes to yourself. `--trust` also pre-approves the second dialog, about CLAUDE.md
`@`-imports from outside the project, which otherwise stalls the spawn the same way.

Keys are case-sensitive path strings, so one folder can hold two entries with two different
answers (`d:/…` untrusted beside `D:/…` trusted) that look identical when you read them. The
preflight reports that case separately; reconcile the entries rather than trusting twice.

## Permission mode

A spawned session picks up whatever your `settings.json` makes the startup default. Where
auto mode is a global opt-in there, children come up in auto mode too — verified 2026-09-10,
both a repo-root and a worktree spawn showing `⏵⏵ auto mode on` with no flag passed.

**Don't pass `--permission-mode` by default.** The operator's `defaultMode` is the mode they
chose for unattended work; a flag overrides it. In particular don't pass `acceptEdits`: it
still prompts for every Bash command, so an unattended child stalls on its first one.

What does *not* carry over is a mode you cycled by hand with shift+tab, which nothing
persists, and a project's `.claude/settings.local.json` allow-list, which applies only while
the cwd is inside that project. Pass a mode only when the operator asks for one, or to make a
child stricter than the default (e.g. `plan` for a read-only reviewer):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/herdr-spawn.sh" reviewer --task review-auth \
  --orchestrator <you> -- --permission-mode plan
```

A peer's permissions are its own: never route work a hook or a denial blocked in your session
through a spawned agent. That is permission laundering, and the answer is to go back to the
operator.

## Tear down

A child starts its last report with `FINAL:` (the return path tells it to). When one arrives
and you need nothing more from that child, close it:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/herdr-spawn.sh" reviewer --close
```

That closes its pane, which removes its row from Herdr's agent panel, and Herdr drops the
tab with its last pane. Herdr's `done` status is not a signal for this: it means one turn
ended, including a child that is waiting for your answer. To end a whole team at once, close
its tab with `herdr tab close <tab id>`.

Do this when the task is done — live agent names are unique, so a forgotten `reviewer` blocks
the next one. Never close a tab, pane or workspace you did not create.

## When not to use this

A single read-only lookup. `Explore` and `claude-code-guide` stay in-process on purpose: a
five-second search is not worth a pane, a process start and a teardown. The hook allows those
types; if you find yourself wanting a pane for one, you probably want `Explore`.
