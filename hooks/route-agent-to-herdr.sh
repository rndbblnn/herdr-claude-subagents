#!/usr/bin/env bash
# PreToolUse(Agent) — keep delegated work visible in Herdr.
#
# The Agent tool's subagents run in-process inside the calling session. They have no PTY, no
# child process and no session id, so Herdr cannot see them: they do not appear in
# `herdr agent list`, they occupy no pane, and there is no way to watch, prompt or interrupt
# one from the TUI. A team assembled that way is invisible to the operator by construction.
#
# So: work that writes, or that runs long enough to be worth watching, is redirected to
# the herdr-spawn.sh beside this hook, which puts a real `claude` session in a real pane inside
# the task's tab. Cheap read-only lookups stay in-process, because turning a five-second
# file search into a pane, a process spawn and a teardown is not worth the visibility.
#
# Where the line sits, and why:
#
#   allowed   Explore              read-only tool set; the fan-out search case
#   allowed   claude-code-guide    read-only; docs lookup
#   allowed   statusline-setup     Read+Edit on one settings file, seconds long
#   allowed   evidence-reviewer    a read-only auditor pattern: Read/Grep/Glob, reports only
#   blocked   general-purpose      has every tool, including Write and Edit
#   blocked   Plan                 long-running by design; worth watching
#   blocked   claude               catch-all with every tool
#   blocked   anything unlisted    unknown capability defaults to visible
#
# A note on what was asked versus what is implemented. The intent agreed with the operator
# was "allow single read-only lookups, block parallel or writing ones". Parallelism is not
# observable here: PreToolUse fires once per tool call, and parallel calls arrive as separate
# invocations of this script with nothing in the payload tying them together. Timing games
# ("did another Agent call fire within two seconds?") would be racy and would block the
# second call rather than the batch. Capability is observable, so the rule keys on that
# instead: a subagent that can only read is cheap enough to allow however many run at once.
# Edit ALLOWED_TYPES below to move the line, or add your own read-only agent types with
# CC_HERDR_ALLOWED_AGENTS (comma- or space-separated) in settings.json's "env" block.
#
# Escape hatches, both deliberate:
#   - outside Herdr (HERDR_ENV != 1) nothing is blocked, because the spawner cannot run there
#     and a hook with no available alternative is just a wall;
#   - CC_ALLOW_INPROCESS_AGENTS=1 disables the redirect for one session.

set -u

# Subagent types cheap and read-only enough to stay in-process. One per line.
ALLOWED_TYPES="
Explore
claude-code-guide
statusline-setup
$(printf '%s' "${CC_HERDR_ALLOWED_AGENTS:-}" | tr ', ' '\n\n')
"

HOOK_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./json-field.sh
. "$HOOK_DIR/json-field.sh"

# Self-locating, so the same file works installed at ~/.claude or inside a project's .claude
# without anything rewriting these paths at install time. The message a caller reads names the
# copy that actually blocked them — which matters when both are present.
CLAUDE_DIR="$(cd -- "$HOOK_DIR/.." && pwd)"
SPAWNER="$CLAUDE_DIR/scripts/herdr-spawn.sh"
SPAWN_SKILL="$CLAUDE_DIR/skills/herdr-spawn/SKILL.md"
case "$CLAUDE_DIR" in
  "$HOME"/*) SPAWNER="~${SPAWNER#"$HOME"}"; SPAWN_SKILL="~${SPAWN_SKILL#"$HOME"}" ;;
esac

# No Herdr, no alternative to redirect to.
[ "${HERDR_ENV:-}" = 1 ] || exit 0
[ "${CC_ALLOW_INPROCESS_AGENTS:-}" = 1 ] && exit 0

payload=$(cat)
subagent_type=$(printf '%s' "$payload" | json_string_field subagent_type tool_input)
description=$(printf '%s' "$payload" | json_string_field description tool_input)

# An Agent call with no subagent_type defaults to general-purpose, which is blocked.
[ -n "$subagent_type" ] || subagent_type="general-purpose"

while IFS= read -r allowed; do
  [ -n "$allowed" ] || continue
  [ "$allowed" = "$subagent_type" ] && exit 0
done <<EOF
$ALLOWED_TYPES
EOF

cat >&2 <<EOF
Blocked by $HOOK_DIR/route-agent-to-herdr.sh: subagent_type '$subagent_type' runs
in-process, where Herdr cannot see it.${description:+ (task: $description)}

In-process subagents have no pane, no name and no session id, so they never appear in
\`herdr agent list\` and cannot be watched, prompted or interrupted from the TUI.

Spawn it into a pane instead — one tab per task, one pane per agent:

    bash $SPAWNER <agent-name> \\
      --task <task-slug> \\
      --orchestrator <your own name from ListAgents> \\
      --prompt "<the same instructions you were about to pass>"

Then drive it with the name you chose:

    herdr agent get <agent-name>                 # idle | working | blocked | done
    herdr agent read <agent-name> --source recent-unwrapped --lines 120
    SendMessage({to: "<agent-name>", message: "..."})

See $SPAWN_SKILL for the full loop, including teardown.

If this really is a cheap read-only lookup, use subagent_type 'Explore' instead.
EOF
exit 2
