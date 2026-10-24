#!/usr/bin/env bash
# Spawn one named Claude session into a Herdr pane, inside this task's tab.
#
# Why this exists
# ---------------
# The Agent tool's subagents run *in-process* inside the calling session: no PTY, no child
# process, no session id of their own. Herdr recognises agents by inspecting what occupies a
# pane, so an in-process subagent is invisible to it and always will be — `pane report-agent`
# needs a real pane_id, so not even a hook can conjure one without creating an empty pane
# that displays nothing. Making a delegated agent visible therefore means spawning a real
# `claude` process into a real pane. That is all this script does.
#
# The payoff is that one spawn produces three identities that already line up:
#
#   herdr agent name   `herdr agent prompt|read|wait|get <name>`   (pane control)
#   Claude Code name   SendMessage({to: "<name>"})                 (agent-to-agent messages)
#   session uuid       reported by `herdr agent list` as           (the join key between them)
#                      .agents[].agent_session.value
#
# Verified on 2026-09-10: `herdr agent list` reported this repo's live sessions with
# agent_session.value equal to each one's $CLAUDE_CODE_SESSION_ID. Herdr panes and Claude
# Code peer sessions are one-to-one already; --name and --session-id only let us choose both
# sides of the mapping up front instead of reading it back afterwards.
#
# Topology: one tab per task, one pane per agent. The tab is found by its label and created
# on first use, so the second and later agents of a task land beside their siblings rather
# than in a tab of their own. Closing the tab tears the whole team down.
#
# Usage
#   herdr-spawn.sh <name> --task <slug> [options] [-- <claude args...>]
#   herdr-spawn.sh <name> --close     close a finished agent's pane (and its tab, if it was
#                                     the last pane); its sidebar row goes with it
#   herdr-spawn.sh --reap <task>      close every pane of that task whose agent is idle/done
#                                     AND has a saved FINAL report; print closed and skipped
#
#   --task <slug>          tab label; the unit that groups one team           (required)
#   --prompt <text>        submitted after the agent reports ready
#   --orchestrator <name>  this session's Claude Code peer name, so the child can
#                          SendMessage back; read it from ListAgents. Also appended to
#                          the child's system prompt as standing reporting instructions
#   --cwd <path>           working directory for the pane        (default: $PWD)
#   --trust                record --cwd as trusted before spawning, instead of refusing
#                          to spawn into a directory Claude Code would stop and ask about
#   --env KEY=VALUE        extra env for the pane; repeatable
#   --wait                 block until the prompt settles (idle|done|blocked)
#   --timeout <ms>         bound for --wait                      (default 300000)
#   --oneshot              close the child's pane by itself once its FINAL report is saved
#                          and its turn has ended
#   --dry-run              print the herdr commands, touch nothing
#   --                     everything after is passed to `claude` verbatim
#
# Every spawned pane also receives:
#   CC_TEAM_TASK, CC_TEAM_AGENT, CC_TEAM_ORCHESTRATOR, CC_TEAM_ORCHESTRATOR_PANE,
#   CC_TEAM_ORCHESTRATOR_SESSION_AT_START, CC_TEAM_REPORT_FILE (+ CC_TEAM_ONESHOT=1)
# display-only pane metadata for the sidebar: $team (the task), $parent (--orchestrator),
# and hooks/team-report.sh via `claude --settings`, which saves a "FINAL:" report to
#   ${XDG_STATE_HOME:-~/.local/state}/herdr-spawn/<task>/<name>.md
# With --orchestrator, the caller's own pane is also renamed in Herdr to that name.
#
# Prints one JSON line describing the spawn.

set -u

SELF="herdr-spawn"
die() { printf '%s: %s\n' "$SELF" "$1" >&2; exit 1; }

# json_string_field lives with the hooks because that is what needed it first; jq is not
# guaranteed to exist (see hooks/json-field.sh) and duplicating the parser here would
# be worse than reaching across one directory for it.
LIB="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../hooks" && pwd)/json-field.sh"
[ -r "$LIB" ] || die "cannot read $LIB"
# shellcheck source=../hooks/json-field.sh
. "$LIB"

# Numbers, which json_string_field cannot read: a pane rect is {"height":65,"width":121}.
json_number_field() {
  local key="$1" anchor="${2:-}"
  awk -v key="$key" -v anchor="$anchor" '
    { buf = buf $0 }
    END {
      s = buf
      if (anchor != "") { i = index(buf, anchor); if (!i) exit 0; s = substr(buf, i) }
      j = index(s, "\"" key "\"")
      if (!j) exit 0
      s = substr(s, j + length(key) + 2)
      k = 1
      while (k <= length(s) && substr(s, k, 1) ~ /[ \t\r\n:]/) k++
      out = ""
      while (k <= length(s) && substr(s, k, 1) ~ /[0-9.-]/) { out = out substr(s, k, 1); k++ }
      printf "%s", out
    }'
}

# Herdr returns arrays on one line. Records are only ever separated by `},{` — nested objects
# such as "agent_session":{...} and "rect":{...} are followed by `},"`, never `},{` — so this
# split is exact for these payloads.
json_records() { sed 's/},{/}\n{/g'; }

# A v4 uuid without depending on python or uuidgen, neither of which is guaranteed here.
uuid4() {
  local h
  h=$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')
  [ ${#h} -eq 32 ] || die "could not read 16 random bytes"
  printf '%s-%s-4%s-a%s-%s\n' \
    "${h:0:8}" "${h:8:4}" "${h:13:3}" "${h:17:3}" "${h:20:12}"
}

name=""
task=""
prompt=""
orchestrator=""
cwd="$PWD"
trust=no
wait_for_settle=no
timeout_ms=300000
dry_run=no
close=no
reap=no
oneshot=no
envs=()
claude_args=()

[ $# -gt 0 ] || die "usage: $SELF <name> --task <slug> [options] [-- <claude args...>] | $SELF --reap <task>"
if [ "$1" = --reap ]; then
  reap=yes; task="${2-}"; shift 2 2>/dev/null || shift
  [ -n "$task" ] || die "usage: $SELF --reap <task>"
else
  name="$1"; shift
  case "$name" in -*) die "first argument must be the agent name, got '$name'" ;; esac
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --task)         task="${2-}"; shift 2 ;;
    --prompt)       prompt="${2-}"; shift 2 ;;
    --orchestrator) orchestrator="${2-}"; shift 2 ;;
    --cwd)          cwd="${2-}"; shift 2 ;;
    --env)          envs+=("${2-}"); shift 2 ;;
    --trust)        trust=yes; shift ;;
    --timeout)      timeout_ms="${2-}"; shift 2 ;;
    --wait)         wait_for_settle=yes; shift ;;
    --dry-run)      dry_run=yes; shift ;;
    --close)        close=yes; shift ;;
    --oneshot)      oneshot=yes; shift ;;
    --)             shift; claude_args=("$@"); break ;;
    *)              die "unknown option '$1'" ;;
  esac
done

# herdr.exe is a Windows binary; Git Bash's $PWD is a POSIX path it cannot resolve.
if command -v cygpath >/dev/null 2>&1; then
  cwd=$(cygpath -w "$cwd" 2>/dev/null || printf '%s' "$cwd")
fi

[ "${HERDR_ENV:-}" = 1 ] || die "not running inside a Herdr pane (HERDR_ENV is not 1)"
[ -n "${HERDR_WORKSPACE_ID:-}" ] || die "HERDR_WORKSPACE_ID is unset"

run() {
  if [ "$dry_run" = yes ]; then printf '+ %s\n' "$*" >&2; return 0; fi
  "$@"
}

tab_id_for_label() {
  herdr tab list --workspace "$HERDR_WORKSPACE_ID" \
    | json_records \
    | while IFS= read -r rec; do
        [ "$(printf '%s' "$rec" | json_string_field label)" = "$1" ] || continue
        printf '%s' "$rec" | json_string_field tab_id
        printf '\n'
      done | head -n 1
}

panes_in_tab() {
  herdr pane list --workspace "$HERDR_WORKSPACE_ID" \
    | json_records \
    | while IFS= read -r rec; do
        [ "$(printf '%s' "$rec" | json_string_field tab_id)" = "$1" ] || continue
        printf '%s' "$rec" | json_string_field pane_id
        printf '\n'
      done
}

# Where hooks/team-report.sh saves a child's FINAL report. The spawner hands the child the
# full path (CC_TEAM_REPORT_FILE) and --reap recomputes it, so this is the one definition.
report_file() { # <task> <name>
  printf '%s/herdr-spawn/%s/%s.md\n' "${XDG_STATE_HOME:-$HOME/.local/state}" \
    "$(printf '%s' "$1" | tr '/\\' '__')" "$2"
}

# Teardown. Herdr drops a tab with its last pane, and the sidebar row with the pane, so
# closing the pane is the whole job. Herdr's `done` only means a turn ended, so this is the
# orchestrator's call once it has the child's final report, never a status-triggered hook.
close_pane() { # <pane> <label for messages>; 1 on refusal or failure, with the reason on stdout
  if [ "$1" = "${HERDR_PANE_ID:-}" ]; then printf 'that is this pane'; return 1; fi
  run herdr pane close "$1" >/dev/null || { printf 'herdr pane close %s failed' "$1"; return 1; }
}

if [ "$close" = yes ]; then
  info=$(herdr agent get "$name" 2>/dev/null) || die "no live agent named '$name' (herdr agent list)"
  pane=$(printf '%s' "$info" | json_string_field pane_id)
  [ -n "$pane" ] || die "could not read the pane of '$name' from herdr agent get"
  why=$(close_pane "$pane") || die "refusing to close '$name': $why"
  printf '{"agent":"%s","pane_id":"%s","closed":true}\n' "$name" "$pane"
  exit 0
fi

# Reap a task: close the panes whose work is provably over. The trigger is the report file,
# not the status — `done` fires after every turn, including a child waiting for an answer —
# and the status check only stops us closing a child mid-turn after it reported. A report
# from another session (a stale file under a reused name) does not count.
if [ "$reap" = yes ]; then
  tab_id=$(tab_id_for_label "$task")
  [ -n "$tab_id" ] || die "no tab labelled '$task' in workspace $HERDR_WORKSPACE_ID"
  agents=$(herdr agent list 2>/dev/null | json_records)
  n_closed=0; n_skipped=0
  for pane in $(panes_in_tab "$tab_id"); do
    rec=$(printf '%s\n' "$agents" | grep -F "\"pane_id\":\"$pane\"" | head -n 1)
    name=$(printf '%s' "$rec" | json_string_field name)
    status=$(printf '%s' "$rec" | json_string_field agent_status)
    session=$(printf '%s' "$rec" | json_string_field value agent_session)
    file=""; [ -z "$name" ] || file=$(report_file "$task" "$name")
    why=""
    if   [ "$pane" = "${HERDR_PANE_ID:-}" ]; then why="this pane"
    elif [ -z "$rec" ];  then why="no agent in pane"
    elif [ -z "$name" ]; then why="agent has no name, so no report file"
    elif [ ! -r "$file" ]; then why="no report at $file"
    elif [ -n "$session" ] && ! grep -qx "session_id: $session" "$file"; then
      why="report in $file is from another session than $session"
    else
      case "$status" in idle|done) ;; *) why="agent is $status" ;; esac
    fi
    if [ -z "$why" ] && why=$(close_pane "$pane"); then
      printf 'closed  %s %s (report: %s)\n' "$pane" "$name" "$file"; n_closed=$((n_closed + 1))
    else
      printf 'skipped %s %s (%s)\n' "$pane" "${name:--}" "$why"; n_skipped=$((n_skipped + 1))
    fi
  done
  printf '{"task":"%s","tab_id":"%s","closed":%d,"skipped":%d}\n' "$task" "$tab_id" "$n_closed" "$n_skipped"
  exit 0
fi

[ -n "$task" ] || die "--task <slug> is required; it is the tab label that groups the team"

# Herdr's own constraint, enforced here so a bad name fails naming the rule, not the symptom.
case "$name" in
  [a-z]*) ;;
  *) die "agent name must start with a lowercase letter: '$name'" ;;
esac
case "$name" in
  *[!a-z0-9_-]*) die "agent name may only contain [a-z0-9_-]: '$name'" ;;
esac
[ ${#name} -le 32 ] || die "agent name must be at most 32 characters: '$name'"
# Two sessions sharing a peer name make bare-name SendMessage ambiguous (seen 2026-10-24:
# a child listed as a second "LaneB"), and the orchestrator's pane takes this name in Herdr.
if [ -n "$orchestrator" ] && [ "$(printf '%s' "$orchestrator" | tr 'A-Z' 'a-z')" = "$name" ]; then
  die "agent name '$name' is the orchestrator's own name; a child must have a name of its own"
fi

if herdr agent get "$name" >/dev/null 2>&1; then
  die "an agent named '$name' is already live; names must be unique (herdr agent list)"
fi

# Which pane to split, and which way. Always the largest by area, halved along its longer
# axis — that is what turns N agents into a grid instead of N stacked ribbons. Splitting the
# *last* pane instead makes every split land in the same shrinking corner, and the herdr
# skill's warning about repeated same-direction splits then comes true immediately.
#
# Terminal cells are about twice as tall as wide, so `width > 2 * height` is the "looks wider
# than tall" test. The 100-column floor stops a split that would leave either half too narrow
# to read; below it the pane stacks instead. On a 121x65 tab that yields, in order: one full
# pane; two rows; two rows with the lower split in half; then a 2x2 grid.
MIN_SPLIT_WIDTH=100

largest_pane_in_tab() {
  local seed="$1" layout best_id="" best_area=-1 id w h area
  layout=$(herdr pane layout --pane "$seed" 2>/dev/null) || { printf '%s\n' "$seed"; return; }
  while IFS= read -r rec; do
    id=$(printf '%s' "$rec" | json_string_field pane_id)
    [ -n "$id" ] || continue
    # Anchor on "rect". The first record also carries the layout's own "area", which is the
    # whole tab — read unanchored, every first pane measures 121x65 on a 121x65 tab, always
    # wins "largest", and every agent after the first lands inside it. That is exactly what
    # happened on the first four-agent run: alpha was split three times and bravo, twice its
    # area, was never touched.
    w=$(printf '%s' "$rec" | json_number_field width '"rect"')
    h=$(printf '%s' "$rec" | json_number_field height '"rect"')
    case "$w" in ''|*[!0-9]*) continue ;; esac
    case "$h" in ''|*[!0-9]*) continue ;; esac
    area=$((w * h))
    if [ "$area" -gt "$best_area" ]; then best_area=$area; best_id=$id; fi
  done <<EOF
$(printf '%s' "$layout" | json_records)
EOF
  printf '%s\n' "${best_id:-$seed}"
}

split_direction() {
  local pane="$1" layout w h
  layout=$(herdr pane layout --pane "$pane" 2>/dev/null) || { printf 'down\n'; return; }
  w=$(printf '%s' "$layout" | json_number_field width "\"pane_id\":\"$pane\"")
  h=$(printf '%s' "$layout" | json_number_field height "\"pane_id\":\"$pane\"")
  case "$w" in ''|*[!0-9]*) printf 'down\n'; return ;; esac
  case "$h" in ''|*[!0-9]*) printf 'down\n'; return ;; esac
  if [ "$w" -ge "$MIN_SPLIT_WIDTH" ] && [ "$w" -gt $((2 * h)) ]; then
    printf 'right\n'
  else
    printf 'down\n'
  fi
}

# CC_TEAM_ORCHESTRATOR is the only one of these a child needs to reply: it is the Claude Code
# peer name that SendMessage addresses, and the caller passes it because a session cannot read
# its own name from the environment.
#
# CC_TEAM_ORCHESTRATOR_PANE is the durable handle. $HERDR_PANE_ID survives a `claude --resume`
# in the same pane; $CLAUDE_CODE_SESSION_ID does not stay in step with it. Observed 2026-09-10:
# after a resume this session's shell still reported CLAUDE_CODE_SESSION_ID=e9edfb37… and Herdr
# still reported the same value for the pane (it reads what the process announced at startup),
# while the messaging identity had moved from rollout-collection-8c [bcfc95] to
# rollout-collection-fc [64e7b6]. So the session uuid is kept for correlation but marked for
# what it is — a startup-time value that a resume can strand — and nothing is built on it.
#
# CC_TEAM_REPORT_FILE is where hooks/team-report.sh saves this child's FINAL report.
report=$(report_file "$task" "$name")
team_env=("CC_TEAM_REPORT_FILE=$report")
[ "$oneshot" = no ] || team_env+=("CC_TEAM_ONESHOT=1")
env_args=()
for kv in "CC_TEAM_TASK=$task" "CC_TEAM_AGENT=$name" \
          "CC_TEAM_ORCHESTRATOR=$orchestrator" \
          "CC_TEAM_ORCHESTRATOR_PANE=${HERDR_PANE_ID:-}" \
          "CC_TEAM_ORCHESTRATOR_SESSION_AT_START=${CLAUDE_CODE_SESSION_ID:-}" \
          "${team_env[@]}" ${envs[@]+"${envs[@]}"}; do
  env_args+=(--env "$kv")
done

# Trust preflight — run before anything is created, so a refusal costs no pane.
#
# Claude Code gates each working directory behind a one-time "Is this a project you created
# or one you trust?" dialog and records the answer in ~/.claude.json as
# projects["<cwd>"].hasTrustDialogAccepted. No flag answers it: `claude --help` documents the
# dialog being skipped only in non-interactive mode (-p, or a non-TTY stdout), which is not
# what a pane is. So a spawn into an untrusted directory sits on the dialog, never reaches
# interactive_ready, and `herdr agent start` fails naming a pane rather than a cause.
#
# Observed 2026-09-10: spawning with --cwd into a fresh temp directory produced
#   herdr-spawn: herdr agent start failed for 'newdirprobe' in pane w7:pM
# with the trust dialog on screen in that pane.
#
# Trust does NOT simply cover descendants. Observed 2026-10-24 (claude 2.1.310): a submodule
# checked out inside a trusted worktree stopped on the dialog, and accepting it recorded the
# submodule's own path. Meanwhile a linked worktree of a trusted repo, with no entry of its
# own, came up clean. So the check follows git: an entry counts if it sits between the cwd
# and its git toplevel (a nested repo is a new boundary), or is the main checkout's root when
# the cwd is a linked worktree. Outside git, any ancestor counts, as before.
CLAUDE_CONFIG="${CLAUDE_CONFIG_DIR:-$HOME}/.claude.json"

# Project keys are stored with forward slashes; cygpath -w handed us backslashes.
path_key() { printf '%s' "$1" | tr '\\' '/' | sed 's:/*$::'; }
lower_ascii() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }

# The keys whose hasTrustDialogAccepted is true, one per line. Claude Code writes this file
# pretty-printed at a fixed indent — project keys at four spaces, their fields at six — which
# is what lets a line-oriented reader stay honest without jq. If that shape ever changes this
# returns nothing, and the caller warns rather than blocking every spawn on a parser.
trusted_projects() {
  [ -r "$CLAUDE_CONFIG" ] || return 0
  awk '
    /^  "projects": \{/ { inproj = 1; next }
    inproj && /^  \}/   { inproj = 0 }
    inproj && /^    "/ {
      key = $0
      sub(/^    "/, "", key)
      sub(/":.*$/, "", key)
      next
    }
    inproj && key != "" && /^      "hasTrustDialogAccepted": true/ { print key }
  ' "$CLAUDE_CONFIG"
}

# trusted | untrusted | case-mismatch | unknown.
#
# case-mismatch is called out on its own because the two paths are indistinguishable to
# someone reading them. Keys are case-sensitive strings, so one folder can appear twice —
# a Windows machine was seen carrying "d:/code/..." (false) beside "D:/code/..." (true) — and
# "untrusted" is a baffling thing to be told about a directory you trusted last week.
# The roots an entry may sit at for <dir>: "<top>\t<main>" (main empty unless a linked
# worktree), or nothing outside git.
git_roots() {
  command -v git >/dev/null 2>&1 || return 0
  local top common main=""
  top=$(git -C "$1" rev-parse --show-toplevel 2>/dev/null) || return 0
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)
  case "$common" in
    */.git) [ "$(path_key "${common%/.git}")" = "$(path_key "$top")" ] || main="${common%/.git}" ;;
  esac
  printf '%s\t%s\n' "$(path_key "$top")" "$(path_key "$main")"
}

trust_state() {
  local want lwant key lkey any=no near=no roots top="" main=""
  want=$(path_key "$1")
  lwant=$(lower_ascii "$want")
  roots=$(git_roots "$1")
  if [ -n "$roots" ]; then top="${roots%%$'\t'*}"; main="${roots#*$'\t'}"; fi
  while IFS= read -r key; do
    key=$(path_key "$key")
    [ -n "$key" ] || continue
    any=yes
    if [ -n "$main" ] && [ "$key" = "$main" ]; then printf 'trusted\n'; return; fi
    case "$want" in
      "$key"|"$key"/*)
        # Inside git, an entry above the toplevel is a different repo's answer.
        if [ -n "$top" ]; then
          case "$key" in "$top"|"$top"/*) ;; *) continue ;; esac
        fi
        printf 'trusted\n'; return ;;
    esac
    lkey=$(lower_ascii "$key")
    case "$lwant" in
      "$lkey"|"$lkey"/*) near=yes ;;
    esac
  done <<EOF
$(trusted_projects)
EOF
  if   [ "$any" = no ];    then printf 'unknown\n'
  elif [ "$near" = yes ];  then printf 'case-mismatch\n'
  else                          printf 'untrusted\n'
  fi
}

# Write the entry the dialog would have written. Node is the dependency here rather than jq
# because Claude Code ships on it, so any machine that can run a spawned agent can run this.
#
# A live session rewrites ~/.claude.json wholesale from its own memory, so an entry seeded
# here can be dropped again by a session that started before it. Spawn straight after
# seeding; the child records its own entry once it settles.
grant_trust() {
  local key="$1"
  if [ "$dry_run" = yes ]; then
    printf '+ record %s as trusted (and its external CLAUDE.md imports approved) in %s\n' "$key" "$CLAUDE_CONFIG" >&2
    return 0
  fi
  command -v node >/dev/null 2>&1 \
    || die "--trust needs node to edit $CLAUDE_CONFIG; answer the dialog in the pane instead"
  node -e '
    const fs = require("fs");
    const file = process.argv[1], key = process.argv[2];
    const conf = JSON.parse(fs.readFileSync(file, "utf8"));
    conf.projects = conf.projects || {};
    // The external-imports dialog comes next when CLAUDE.md @-imports files outside the
    // project; left unanswered it stalls the spawn just like the trust dialog (2026-10-24).
    conf.projects[key] = Object.assign({}, conf.projects[key], {
      hasTrustDialogAccepted: true,
      hasClaudeMdExternalIncludesApproved: true,
      hasClaudeMdExternalIncludesWarningShown: true,
    });
    const tmp = file + ".herdr-spawn.tmp";
    fs.writeFileSync(tmp, JSON.stringify(conf, null, 2) + "\n");
    fs.renameSync(tmp, file);
  ' "$CLAUDE_CONFIG" "$key" || die "could not record trust for $key in $CLAUDE_CONFIG"
}

# Checked even under --dry-run: reading the config mutates nothing, and a dry run that
# stayed silent about a refusal would be the one place you most wanted to hear about it.
case "$(trust_state "$cwd")" in
  trusted) ;;
  unknown)
    printf '%s: warning: no trusted projects readable in %s; spawning without the check\n' \
      "$SELF" "$CLAUDE_CONFIG" >&2 ;;
  case-mismatch)
    [ "$trust" = yes ] || die "$(printf '%s\n' \
      "$cwd is trusted under a different spelling of the same path." \
      "Trust keys in $CLAUDE_CONFIG are case-sensitive strings, so one folder can hold two" \
      "entries carrying two answers. Reconcile them there, or pass --trust to record this one.")"
    grant_trust "$(path_key "$cwd")" ;;
  untrusted)
    [ "$trust" = yes ] || die "$(printf '%s\n' \
      "Claude Code has not been trusted with $cwd, so a session started there would stop on" \
      "its trust dialog and never report ready — the spawn would fail naming a pane, not a cause." \
      "Spawn somewhere already trusted, or pass --trust if you would answer yes yourself.")"
    grant_trust "$(path_key "$cwd")" ;;
esac

tab_id=$(tab_id_for_label "$task")

if [ -z "$tab_id" ]; then
  created=$(run herdr tab create --workspace "$HERDR_WORKSPACE_ID" \
                 --label "$task" --cwd "$cwd" "${env_args[@]}" --no-focus) \
    || die "herdr tab create failed"
  if [ "$dry_run" = yes ]; then
    tab_id="<new-tab>"; pane_id="<new-tab-root-pane>"
  else
    tab_id=$(printf '%s' "$created" | json_string_field tab_id)
    pane_id=$(printf '%s' "$created" | json_string_field pane_id "root_pane")
    [ -n "$pane_id" ] || die "tab create returned no root pane: $created"
  fi
else
  seed=$(panes_in_tab "$tab_id" | tail -n 1)
  [ -n "$seed" ] || die "tab $tab_id ($task) reports no panes"
  target=$(largest_pane_in_tab "$seed")
  dir=$(split_direction "$target")
  split=$(run herdr pane split "$target" --direction "$dir" --cwd "$cwd" \
               "${env_args[@]}" --no-focus) \
    || die "herdr pane split failed"
  if [ "$dry_run" = yes ]; then
    pane_id="<new-split-pane>"
  else
    pane_id=$(printf '%s' "$split" | json_string_field pane_id "\"pane\"")
    [ -n "$pane_id" ] || die "pane split returned no pane: $split"
  fi
fi

session_id=$(uuid4)

# The return path, written into the child's system prompt so it holds whatever --prompt says.
# Without it a child reports back only if the caller remembered to ask, and its questions go
# to AskUserQuestion in its own pane, where the orchestrator never sees them. A caller's own
# --append-system-prompt is kept: ours is prepended to it, since claude takes one value.
if [ -n "$orchestrator" ]; then
  return_path="You are \"$name\", a Claude Code session spawned in its own Herdr pane by the session \"$orchestrator\" (your orchestrator) for task \"$task\". When you finish, send your results to it with SendMessage (to: \"$orchestrator\"). Send questions about the task the same way and wait for the reply, instead of using AskUserQuestion: nobody may be watching this pane. Use AskUserQuestion only when the orchestrator tells you to ask the operator directly. Start your final report with \"FINAL:\" and send it only when nothing is left to do: your orchestrator closes your pane when it gets one. If SendMessage cannot find \"$orchestrator\", it was probably resumed under a new name; run ListAgents to find it."
  merged=no
  for i in ${claude_args[@]+"${!claude_args[@]}"}; do
    case "${claude_args[$i]}" in
      --append-system-prompt)
        claude_args[i+1]="$return_path ${claude_args[i+1]-}"; merged=yes; break ;;
      --append-system-prompt=*)
        claude_args[i]="--append-system-prompt=$return_path ${claude_args[i]#--append-system-prompt=}"
        merged=yes; break ;;
    esac
  done
  [ "$merged" = yes ] || claude_args+=(--append-system-prompt "$return_path")
fi

# The return path needs SendMessage, and `-- --agent <name>` limits the child to that agent's
# `tools:` whitelist, which seldom names it. Observed 2026-10-24: a ux-designer child
# (tools: Read, Write, Edit, Bash, Grep, Glob, Skill) had no SendMessage and typed its FINAL
# into the orchestrator's prompt with `herdr agent prompt`, where it read as operator input.
# `--agents <json>` defines an agent for one session and wins over the same name in
# .claude/agents (verified 2026-10-24, claude 2.1.310), so the spawner re-emits the agent
# with SendMessage added to its whitelist. Everything else about the agent is unchanged.
# Only the simple frontmatter forms are parsed (scalars, [a, b] and "- a" lists, | and >
# blocks). Anything else (hooks, mcpServers, maps) leaves the agent as it was, with a warning.
agent_file() { # <name>: the .md whose frontmatter `name:` matches, project dirs first
  local d="$cwd" f dirs=()
  while :; do
    dirs+=("$d/.claude/agents")
    [ "$d" = / ] || [ -z "$d" ] && break
    d=$(dirname -- "$d")
  done
  dirs+=("${CLAUDE_CONFIG_DIR:-$HOME/.claude}/agents")
  for d in "${dirs[@]}"; do
    [ -d "$d" ] || continue
    for f in "$d"/*.md; do
      [ -r "$f" ] || continue
      awk -v n="$1" 'NR==1&&!/^---[ \t]*$/{exit 1} NR==1{next} /^---[ \t]*$/{exit 1}
        /^name:/{v=$0; sub(/^name:[ \t]*/,"",v); gsub(/^["'\'']|["'\''][ \t]*$|[ \t]+$/,"",v); exit (v==n?0:1)}' "$f" \
        && { printf '%s\n' "$f"; return 0; }
    done
  done
  return 1
}

# Prints {"<name>":{...}} with <tool> appended to `tools:`, or nothing when no rewrite is
# needed (no whitelist, or the tool is already on it). Exits 2 on a form it does not parse.
agent_json_with_tool() { # <file> <name> <tool>
  # ASCII out, always: non-ASCII becomes \uXXXX (surrogate pairs above U+FFFF). Herdr types
  # this argv into the pane's shell, and a long argument mixing em-dashes with \" escapes
  # never arrived intact — the shell sat on an open quote and the spawn timed out (observed
  # 2026-10-24 with bulk-reader, herdr 0.9.5 + fish; the same text with "-" spawned fine).
  # LC_ALL=C makes awk see bytes, which the decoder below reassembles into code points.
  LC_ALL=C awk -v name="$2" -v tool="$3" '
    BEGIN { for (b=0; b<256; b++) ORD[sprintf("%c", b)] = b }
    function u4(cp) { return sprintf("\\u%04x", cp) }
    function esc(s,   o,i,c,b,n,cp,k) { o=""; for (i=1;i<=length(s);i++) { c=substr(s,i,1); b=ORD[c]
        if (c=="\\") o=o "\\\\"; else if (c=="\"") o=o "\\\""; else if (c=="\t") o=o "\\t"
        else if (c=="\n") o=o "\\n"; else if (c=="\r") continue
        else if (b < 128) o=o c
        else {
          if (b >= 240) { n=3; cp=b-240 } else if (b >= 224) { n=2; cp=b-224 } else if (b >= 192) { n=1; cp=b-192 } else { o=o u4(65533); continue }
          for (k=1; k<=n; k++) cp = cp*64 + (ORD[substr(s,i+k,1)] % 64)
          i += n
          if (cp >= 65536) { cp -= 65536; o = o u4(55296 + int(cp/1024)) u4(56320 + cp%1024) }
          else o = o u4(cp)
        } }; return o }
    function bad() { broken=1; exit }
    function unq(s) { sub(/^[ \t]+/,"",s); sub(/[ \t]+$/,"",s)
      if (s ~ /^".*"$/ || s ~ /^'\''.*'\''$/) s=substr(s,2,length(s)-2); return s }
    function flow(s,   n,i,a,out) { s=substr(s,2,length(s)-2); n=split(s,a,",")
      for (i=1;i<=n;i++) if (unq(a[i])!="") out=out SUBSEP unq(a[i]); return substr(out,2) }
    function close_block() { if (bkey!="") { val[bkey]=bbuf; bkey="" } }
    NR==1 { if ($0 !~ /^---[ \t]*$/) bad(); fm=1; next }
    fm && /^---[ \t]*$/ { close_block(); if (lkey!="") lkey=""; fm=0; body=1; next }
    fm {
      if (bkey!="") { if ($0 ~ /^[ \t]/ || $0=="") { l=$0; sub(/^[ \t]+/,"",l)
          bbuf = bbuf=="" ? l : bbuf (bstyle=="|" ? "\n" : " ") l; next } close_block() }
      if (lkey!="") { if ($0 ~ /^[ \t]*-[ \t]/) { l=$0; sub(/^[ \t]*-[ \t]*/,"",l)
          lst[lkey] = lst[lkey]=="" ? unq(l) : lst[lkey] SUBSEP unq(l); next } lkey="" }
      if ($0 ~ /^[ \t]*(#|$)/) next
      if ($0 !~ /^[A-Za-z][A-Za-z0-9_-]*:/) bad()
      k=$0; sub(/:.*/,"",k); v=$0; sub(/^[^:]*:[ \t]*/,"",v)
      if (v ~ /^[|>][-+]?[ \t]*$/) { bkey=k; bbuf=""; bstyle=substr(v,1,1); next }
      if (v=="") { lkey=k; lst[k]=""; islist[k]=1; next }
      if (v ~ /^\[.*\]$/) { lst[k]=flow(v); islist[k]=1; next }
      if (v ~ /^[\[{]/) bad()
      val[k]=unq(v); next
    }
    body { prompt = started ? prompt "\n" $0 : $0; started=1 }
    END {
      if (broken) exit 2
      if (fm || !body) exit 2
      for (k in val) if (k !~ /^(name|description|model|color|permissionMode|effort|maxTurns|tools|disallowedTools)$/) exit 2
      for (k in islist) if (k !~ /^(tools|disallowedTools|skills)$/) exit 2
      if (!islist["tools"] && val["tools"]=="") exit 0          # no whitelist: inherits all
      t = islist["tools"] ? lst["tools"] : val["tools"]
      if (!islist["tools"]) gsub(/[ \t]*,[ \t]*/,SUBSEP,t)
      n=split(t,ts,SUBSEP); for (i=1;i<=n;i++) if (ts[i]==tool) exit 0
      lst["tools"] = t=="" ? tool : t SUBSEP tool; islist["tools"]=1; delete val["tools"]
      sub(/^\n+/,"",prompt)
      out = "\"description\":\"" esc(val["description"]) "\",\"prompt\":\"" esc(prompt) "\""
      for (k in val) if (k!="name" && k!="description")
        out = out ",\"" k "\":" (k=="maxTurns" && val[k] ~ /^[0-9]+$/ ? val[k] : "\"" esc(val[k]) "\"")
      for (k in islist) { n=split(lst[k],ts,SUBSEP); a=""
        for (i=1;i<=n;i++) a = a (i>1?",":"") "\"" esc(ts[i]) "\""
        out = out ",\"" k "\":[" a "]" }
      printf "{\"%s\":{%s}}\n", esc(name), out
    }' "$1"
}

if [ -n "$orchestrator" ]; then
  agent_name=""; has_agents=no
  for i in ${claude_args[@]+"${!claude_args[@]}"}; do
    case "${claude_args[$i]}" in
      --agent)   agent_name="${claude_args[i+1]-}" ;;
      --agent=*) agent_name="${claude_args[i]#--agent=}" ;;
      --agents|--agents=*) has_agents=yes ;;
    esac
  done
  if [ -n "$agent_name" ]; then
    warn_no_return() { printf '%s: warning: %s; the child may lack SendMessage and be unable to report back\n' "$SELF" "$1" >&2; }
    if [ "$has_agents" = yes ]; then
      warn_no_return "--agents was passed, so agent '$agent_name' is left as given"
    elif ! af=$(agent_file "$agent_name"); then
      warn_no_return "no .claude/agents file defines '$agent_name' (plugin agents are not rewritten)"
    elif agent_json=$(agent_json_with_tool "$af" "$agent_name" SendMessage); then
      [ -z "$agent_json" ] || claude_args+=(--agents "$agent_json")
    else
      warn_no_return "$af uses frontmatter this script does not parse"
    fi
  fi
fi

# The durable report. hooks/team-report.sh goes in through --settings rather than the plugin's
# hooks.json so it travels with whichever spawner started the child (a session on an older
# installed plugin still gets it) and never runs in sessions this script did not start. Hooks
# from --settings merge with the user's own (verified 2026-10-24, claude 2.1.310). claude takes
# one --settings value, and a caller's may be a file path we cannot merge into, so a caller's
# own --settings wins and the child gets no report hook, with a warning.
REPORT_HOOK="$(cd -- "$(dirname -- "$LIB")" && pwd)/team-report.sh"
has_settings=no
for a in ${claude_args[@]+"${claude_args[@]}"}; do
  case "$a" in --settings|--settings=*) has_settings=yes ;; esac
done
if [ "$has_settings" = yes ]; then
  printf '%s: warning: --settings was passed, so no FINAL report hook; --reap will skip %s\n' "$SELF" "$name" >&2
else
  hook_cmd=$(printf 'bash "%s"' "$REPORT_HOOK" | sed 's/\\/\\\\/g; s/"/\\"/g')
  hook="{\"type\":\"command\",\"command\":\"$hook_cmd\",\"timeout\":15}"
  # A file, not inline JSON: everything after `--` is typed into the pane's shell, and the
  # shorter that line the less there is to lose (see the retry below).
  settings_file="${report%.md}.settings.json"
  if [ "$dry_run" = no ]; then
    mkdir -p -- "$(dirname -- "$settings_file")" \
      && printf '{"hooks":{"PostToolUse":[{"matcher":"SendMessage","hooks":[%s]}],"Stop":[{"hooks":[%s]}]}}\n' \
           "$hook" "$hook" > "$settings_file" \
      || die "could not write $settings_file"
  fi
  if command -v cygpath >/dev/null 2>&1; then settings_file=$(cygpath -w "$settings_file"); fi
  claude_args+=(--settings "$settings_file")
fi
# A report left by an earlier agent of the same name would let --reap close this one unread.
[ "$dry_run" = yes ] || rm -f -- "$report"

# --name sets the Claude Code peer name that SendMessage addresses; --session-id pins the
# uuid that `herdr agent list` reports back as agent_session.value. Native claude flags only
# after `--`, per the herdr skill.
#
# One retry. Herdr types this command into the pane's interactive shell, and with a long
# argv (a re-emitted --agents definition runs to ~2.6 KB) that intermittently never ran:
# the shell sat on a half-typed line with stray `}}'` at the end until the startup timeout.
# Observed 2026-10-24 with herdr 0.9.5 + fish 4.9.3: the same argv failed 1 run in 6 and
# passed the rest, and the bytes Herdr types (captured into `cat`) were intact, so it is a
# race in the line editor, not quoting. Ctrl-C clears the line and the second try usually lands.
start_agent() {
  run herdr agent start "$name" --kind claude --pane "$pane_id" -- \
    --name "$name" --session-id "$session_id" ${claude_args[@]+"${claude_args[@]}"}
}
if ! start_agent; then
  printf '%s: warning: herdr agent start failed in %s; clearing the line and retrying once\n' "$SELF" "$pane_id" >&2
  run herdr pane send-keys "$pane_id" C-c >/dev/null 2>&1
  sleep 1
  start_agent \
    || die "herdr agent start failed twice for '$name' in pane $pane_id (see: herdr pane read $pane_id)"
fi

# Sidebar hierarchy, display only, lasting until the pane closes. Herdr's `agent` token
# reads "claude" for every Claude pane, so both ends get their peer name as display name;
# $team, $parent, $under ("↳ parent") and $nested (the name, indented) are for a
# [ui.sidebar.agents] layout (README has one). Layouts cannot hold literal text, so the
# decoration rides in the value. Herdr trims leading whitespace from token values, so the
# indent is U+2800 (braille blank): not whitespace, renders empty, one cell wide. Losing them only loses the display, so a
# Herdr without report-metadata warns instead of failing the spawn.
tag_pane() { # <pane> <report-metadata args...>
  local pane="$1"; shift
  run herdr pane report-metadata "$pane" --source herdr-spawn "$@" >/dev/null \
    || printf '%s: warning: could not tag pane %s for the sidebar\n' "$SELF" "$pane" >&2
}

# The orchestrator's own Herdr name. A session Herdr detected on its own (not started with
# `herdr agent start`) has `name: null` in `herdr agent list`, so `herdr agent get <name>`
# cannot find it; display_agent above is only the sidebar label. `herdr agent rename <pane>
# <name>` names a running pane in place (verified 2026-10-24, herdr 0.9.5, including on a
# pane whose name was cleared). Herdr names are [a-z][a-z0-9_-]{0,31} \u2014 "LaneB" is refused
# with invalid_agent_name \u2014 so the peer name is lowercased and anything else becomes "-".
# Every spawn re-applies it, which is how a renamed orchestrator (resume or compaction:
# 5d\u21925e) catches up: the next spawn passes the new --orchestrator and the pane follows.
herdr_name() {
  local n
  n=$(printf '%s' "$1" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9_-]/-/g')
  case "$n" in [a-z]*) ;; *) n="o-$n" ;; esac
  printf '%s' "${n:0:32}"
}
name_orchestrator_pane() { # <pane> <peer name>
  local want have
  want=$(herdr_name "$2")
  have=$(herdr agent get "$1" 2>/dev/null | json_string_field name)
  [ "$have" != "$want" ] || return 0
  run herdr agent rename "$1" "$want" >/dev/null 2>&1 \
    || printf '%s: warning: could not name pane %s "%s" in Herdr (taken, or no agent there)\n' "$SELF" "$1" "$want" >&2
}

indent=$'\u2800\u2800\u2800\u2800'
meta=(--display-agent "$name" --token "team=$task" --token "nested=$indent$name")
[ -z "$orchestrator" ] || meta+=(--token "parent=$orchestrator" --token "under=↳ $orchestrator")
tag_pane "$pane_id" "${meta[@]}"
if [ -n "$orchestrator" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
  tag_pane "$HERDR_PANE_ID" --display-agent "$orchestrator"
  name_orchestrator_pane "$HERDR_PANE_ID" "$orchestrator"
fi

if [ -n "$prompt" ]; then
  if [ "$wait_for_settle" = yes ]; then
    run herdr agent prompt "$name" "$prompt" --wait --timeout "$timeout_ms" \
      || die "prompt to '$name' did not settle; inspect with: herdr agent get $name"
  else
    run herdr agent prompt "$name" "$prompt" \
      || die "prompt to '$name' was not submitted; inspect with: herdr agent get $name"
  fi
fi

printf '{"agent":"%s","task":"%s","workspace_id":"%s","tab_id":"%s","pane_id":"%s","session_id":"%s","prompted":%s}\n' \
  "$name" "$task" "$HERDR_WORKSPACE_ID" "$tab_id" "$pane_id" "$session_id" \
  "$([ -n "$prompt" ] && echo true || echo false)"
