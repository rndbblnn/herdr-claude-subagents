#!/usr/bin/env bash
# Save a spawned child's FINAL report to a file, and tell the orchestrator's pane it landed.
#
# Why: a child's report used to live in two fragile places, the SendMessage that carried it
# and the pane's scrollback. Observed 2026-10-24: children spawned without SendMessage left
# their reports in scrollback, which truncated, and the orchestrator had to dig the full text
# out of ~/.claude/projects/*/<session>.jsonl. The report file is the durable copy, and the
# trigger `herdr-spawn.sh --reap` uses to decide a pane is safe to close.
#
# Not registered in hooks.json. herdr-spawn.sh injects it into each child with
# `claude --settings`, for two events:
#   PostToolUse(SendMessage)  tool_input.message starts with "FINAL:"   (the normal path)
#   Stop                      the last assistant text has a line starting "FINAL:" (no SendMessage)
# and points it at the file through CC_TEAM_REPORT_FILE. Without that variable it does nothing.
#
# Fail open, always: a Stop hook that exits 2 keeps the session running, so every path ends
# in exit 0 and every herdr call is allowed to fail.

main() {
  local file="${CC_TEAM_REPORT_FILE:-}"
  [ -n "$file" ] || return 0

  local lib
  lib="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/json-field.sh"
  [ -r "$lib" ] || return 0
  # shellcheck source=json-field.sh
  . "$lib"

  local payload event session text="" source=""
  payload=$(cat)
  [ -z "${CC_TEAM_HOOK_DUMP:-}" ] || printf '%s\n' "$payload" >> "$CC_TEAM_HOOK_DUMP"
  event=$(printf '%s' "$payload" | json_string_field hook_event_name)
  session=$(printf '%s' "$payload" | json_string_field session_id)

  case "$event" in
    PostToolUse)
      [ "$(printf '%s' "$payload" | json_string_field tool_name)" = SendMessage ] || return 0
      text=$(printf '%s' "$payload" | json_string_field message tool_input)
      source=SendMessage ;;
    Stop)
      text=$(printf '%s' "$payload" | json_string_field last_assistant_message)
      if [ -z "$text" ]; then
        local transcript
        transcript=$(printf '%s' "$payload" | json_string_field transcript_path)
        [ -r "$transcript" ] && text=$(last_assistant_text "$transcript")
      fi
      source=Stop ;;
    *) return 0 ;;
  esac

  # A child that sent its FINAL often ends the turn echoing it ("FINAL: ... sent to boss").
  # That echo must not replace the full report SendMessage carried in the same session.
  if [ "$source" = Stop ] && grep -qx "session_id: $session" "$file" 2>/dev/null \
     && grep -qx "source: SendMessage" "$file" 2>/dev/null; then
    text=""
  fi

  # A report is a message with a line that starts with "FINAL:", first or not: children often
  # summarise first and put the FINAL line last (observed 2026-10-25, readme-writer). The whole
  # message is saved, since the summary above that line is the useful part.
  case "${text#"${text%%[![:space:]]*}"}" in
    FINAL:*|*$'\n'FINAL:*) write_report "$file" "$session" "$source" "$text" && notify "$file" ;;
  esac

  [ "$event" = Stop ] && [ "${CC_TEAM_ONESHOT:-}" = 1 ] && close_self_if_reported "$file" "$session"
  return 0
}

# The newest transcript entry of an assistant turn that carries text: Claude Code writes
# one JSON object per line, and a turn's final words are the last such line before Stop.
last_assistant_text() {
  local line
  line=$(awk '/"type":"assistant"/ && /"type":"text"/ { last = $0 } END { print last }' "$1")
  [ -n "$line" ] || return 0
  # Blank out the "text" *value* of "type":"text" first, or the reader would stop at it.
  printf '%s' "$line" | sed 's/"type":"text"/"type":"t"/g' | json_string_field text
}

write_report() { # <file> <session> <source> <text>
  local file="$1" tmp
  mkdir -p -- "$(dirname -- "$file")" 2>/dev/null || return 1
  tmp="$file.tmp.$$"
  {
    printf -- '---\n'
    printf 'agent: %s\n' "${CC_TEAM_AGENT:-}"
    printf 'task: %s\n' "${CC_TEAM_TASK:-}"
    printf 'orchestrator: %s\n' "${CC_TEAM_ORCHESTRATOR:-}"
    printf 'session_id: %s\n' "$2"
    printf 'pane_id: %s\n' "${HERDR_PANE_ID:-}"
    printf 'source: %s\n' "$3"
    printf 'written: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf -- '---\n\n%s\n' "$4"
  } > "$tmp" 2>/dev/null && mv -f -- "$tmp" "$file" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
}

# Display-only, so failure costs nothing: a token on the orchestrator's pane (a separate
# --source, so it never clears the display name herdr-spawn set), a ✓ on the child's own
# pane, and a silent Herdr notification naming the file. Silent on purpose: the operator
# wants sound only from a parent finishing or needing help, never from a child (2026-10-24).
notify() {
  [ "${HERDR_ENV:-}" = 1 ] && command -v herdr >/dev/null 2>&1 || return 0
  local agent="${CC_TEAM_AGENT:-child}"
  if [ -n "${CC_TEAM_ORCHESTRATOR_PANE:-}" ]; then
    herdr pane report-metadata "$CC_TEAM_ORCHESTRATOR_PANE" --source herdr-spawn-report \
      --token "last_report=$agent" >/dev/null 2>&1
  fi
  [ -z "${HERDR_PANE_ID:-}" ] || herdr pane report-metadata "$HERDR_PANE_ID" \
    --source herdr-spawn-report --token "report=✓" >/dev/null 2>&1
  herdr notification show "FINAL from $agent" --body "$1" --sound none >/dev/null 2>&1
  return 0
}

# --oneshot: once this session's report is on disk and its turn has ended, close the pane.
# Detached and delayed so the hook returns before the process it belongs to is killed.
close_self_if_reported() { # <file> <session>
  [ -r "$1" ] && [ -n "${HERDR_PANE_ID:-}" ] || return 0
  grep -qx "session_id: $2" "$1" 2>/dev/null || return 0
  command -v herdr >/dev/null 2>&1 || return 0
  local pane="$HERDR_PANE_ID"
  if command -v setsid >/dev/null 2>&1; then
    setsid sh -c 'sleep "$2"; herdr pane close "$1"' _ "$pane" "${CC_TEAM_ONESHOT_DELAY:-2}" </dev/null >/dev/null 2>&1 &
  else
    nohup sh -c 'sleep "$2"; herdr pane close "$1"' _ "$pane" "${CC_TEAM_ONESHOT_DELAY:-2}" </dev/null >/dev/null 2>&1 &
  fi
  return 0
}

main "$@"
exit 0
