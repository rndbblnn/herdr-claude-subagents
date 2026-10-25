#!/usr/bin/env bash
# Give each Claude session one name, shared by the Claude app's session list, the peer name
# SendMessage addresses, and the Herdr pane: <repo abbr>[-<lane>]-<slug>, e.g. bo-b-iga-shopping.
#
# What a hook can do (probed live 2026-10-25, claude 2.1.310): SessionStart and
# UserPromptSubmit may return hookSpecificOutput.sessionTitle. Claude records it as both
# customTitle and agentName, so it IS the peer name (ListAgents showed the probe under its new
# title). A custom title also stops Claude's own AI titling for good. So a session is named
# once, from its first AI title ("type":"ai-title" in the transcript, written during turn 1),
# at the next UserPromptSubmit, and never renamed by this hook again.
#
#   - A transcript that already has a customTitle (--name, /rename, a spawned child, or this
#     hook earlier) keeps it; Herdr is synced to it on SessionStart, UserPromptSubmit and Stop.
#   - A session that has spawned children is not renamed: they address it by its current peer
#     name. herdr-spawn.sh leaves a marker named after CLAUDE_CODE_SESSION_ID for that.
#
# Herdr names are [a-z][a-z0-9_-]{0,31} and unique, so the name is built to fit, and a taken
# name gets -2..-5 before it is used for the Claude title too.
#
# Inside Herdr only. Fail open, always: every path exits 0, and a Stop hook that exits 2 would
# keep the session running.

main() {
  [ "${HERDR_ENV:-}" = 1 ] && [ -n "${HERDR_PANE_ID:-}" ] || return 0
  command -v herdr >/dev/null 2>&1 || return 0

  local lib
  lib="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/json-field.sh"
  [ -r "$lib" ] || return 0
  # shellcheck source=json-field.sh
  . "$lib"

  local payload event transcript cwd session custom ai name
  payload=$(cat)
  event=$(printf '%s' "$payload" | json_string_field hook_event_name)
  transcript=$(printf '%s' "$payload" | json_string_field transcript_path)
  cwd=$(printf '%s' "$payload" | json_string_field cwd)
  session=$(printf '%s' "$payload" | json_string_field session_id)
  [ -n "$cwd" ] || cwd=$PWD

  custom=$(last_title customTitle "$transcript")
  if [ -n "$custom" ]; then
    sync_herdr "$custom" "$event"
    return 0
  fi

  [ "$event" = UserPromptSubmit ] || return 0
  [ ! -e "$(state_dir)/herdr-spawn/orchestrators/${CLAUDE_CODE_SESSION_ID:-$session}" ] || return 0
  ai=$(last_title aiTitle "$transcript")
  [ -n "$ai" ] || return 0

  name=$(build_name "$cwd" "$ai")
  [ -n "$name" ] || return 0
  name=$(claim_herdr_name "$name") || return 0
  printf '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","sessionTitle":"%s"}}\n' "$name"
}

state_dir() { printf '%s' "${XDG_STATE_HOME:-$HOME/.local/state}"; }

last_title() { # <customTitle|aiTitle> <transcript>; the newest value, or nothing
  [ -n "$2" ] && [ -r "$2" ] || return 0
  grep -o "\"$1\":\"[^\"]*\"" "$2" 2>/dev/null | tail -n 1 | cut -d'"' -f4
}

# Lowercase, [a-z0-9_-] only, starts with a letter, at most 32 characters.
herdr_safe() {
  local n
  n=$(printf '%s' "$1" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9_-]/-/g; s/--*/-/g; s/^-//; s/-$//')
  case "$n" in [a-z]*) ;; *) n="s-$n" ;; esac
  fit "$n" 32
}

fit() { # <name> <max>; cut at the last whole word that fits
  local n="$1"
  if [ "${#n}" -gt "$2" ]; then n="${n:0:$(($2 + 1))}"; n="${n%-*}"; fi
  printf '%s' "${n%-}"
}

# basildragon-orchestrator -> bo, herdr-claude-subagents -> hcs, homedevices -> homedevices.
repo_abbr() {
  printf '%s' "$1" | tr 'A-Z' 'a-z' | awk -F'[-_. ]+' '{
    if (NF < 2) { print $0; exit }
    s = ""; for (i = 1; i <= NF; i++) if ($i != "") s = s substr($i, 1, 1); print s }'
}

repo_name() { # <cwd>; the main checkout's folder, also from a linked worktree
  local common
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
    || { basename -- "$1"; return; }
  case "$common" in
    */.git) basename -- "$(dirname -- "$common")" ;;
    *)      basename -- "${common%.git}" ;;   # bare repo, or .git/modules/<submodule>
  esac
}

lane_slot() { # <cwd>; "b" inside a bound lane, else nothing. `lane status` answers in ~40 ms.
  command -v lane >/dev/null 2>&1 || return 0
  (cd -- "$1" 2>/dev/null && timeout 3 lane status 2>/dev/null | head -n 1) \
    | awk '/^Lane [A-Za-z0-9]+/ { print tolower($2) }'
}

slug() { # <AI title>; its first three meaningful words
  printf '%s' "$1" | tr 'A-Z' 'a-z' | sed 's/[^a-z0-9]/ /g' | awk '
    BEGIN { split("a an the and or of for to in on at with from by via into vs is are", w, " ")
            for (i in w) stop[w[i]] = 1 }
    { for (i = 1; i <= NF && n < 3; i++) if (!($i in stop)) out = out (n++ ? "-" : "") $i }
    END { print out }'
}

build_name() { # <cwd> <AI title>
  local abbr lane s
  abbr=$(repo_abbr "$(repo_name "$1")")
  lane=$(lane_slot "$1")
  s=$(slug "$2")
  [ -n "$s" ] || return 0
  herdr_safe "$abbr${lane:+-$lane}-$s"
}

# Rename this pane in Herdr to <name>, or <name>-2..-5 when taken; print the one it got.
claim_herdr_name() {
  local base="$1" try i
  for i in "" 2 3 4 5; do
    try=$base
    [ -z "$i" ] || try="$(fit "$base" $((31 - ${#i})))-$i"
    if herdr_rename "$try"; then printf '%s' "$try"; return 0; fi
  done
  return 1
}

herdr_rename() { # <safe name>; true when the pane has that name afterwards
  local have
  have=$(timeout 5 herdr agent get "$HERDR_PANE_ID" 2>/dev/null | json_string_field name)
  [ "$have" = "$1" ] && return 0
  timeout 5 herdr agent rename "$HERDR_PANE_ID" "$1" >/dev/null 2>&1 || return 1
  label "$1"
}

# Sidebar label. Spawned children keep the spawner's tags ($nested and friends), which a
# report from the same source would replace, so only unspawned sessions are relabelled here.
label() {
  [ -z "${CC_TEAM_AGENT:-}" ] || return 0
  timeout 5 herdr pane report-metadata "$HERDR_PANE_ID" --source herdr-spawn \
    --display-agent "$1" >/dev/null 2>&1
  return 0
}

# Herdr follows a name Claude already has. The cache skips the herdr calls on every turn, but
# SessionStart always checks: a Herdr restart forgets pane names.
sync_herdr() { # <Claude title> <event>
  local want cache
  want=$(herdr_safe "$1")
  cache="$(state_dir)/herdr-session-name/${HERDR_PANE_ID//[^A-Za-z0-9_-]/_}"
  if [ "$2" != SessionStart ] && [ "$(cat -- "$cache" 2>/dev/null)" = "$want" ]; then return 0; fi
  herdr_rename "$want" || return 0
  mkdir -p -- "$(dirname -- "$cache")" 2>/dev/null && printf '%s' "$want" > "$cache" 2>/dev/null
  return 0
}

main "$@" 2>/dev/null
exit 0
