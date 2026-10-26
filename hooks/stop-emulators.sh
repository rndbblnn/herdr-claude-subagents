# Stop the Android emulators a spawned child started, when its pane is torn down.
#
# Why: an emulator launched from a child's shell is reparented to init/systemd and outlives
# the pane. Observed 2026-10-26: a ux-designer child booted `basil-test` on 2026-10-24 and the
# headless emulator ran ~44 h after the child was gone, holding ~3 GB of RAM + swap.
#
# Sourced (not run) by scripts/herdr-spawn.sh (--close, --reap) and hooks/team-report.sh
# (--oneshot). Linux only: it reads /proc, and does nothing where /proc is absent.
#
# An emulator belongs to a child when its environment carries the child's
# CLAUDE_CODE_SESSION_ID — the uuid the spawner passed as `claude --session-id`, which Herdr
# reports as agent_session.value and which the env keeps even after a resume.
# Left alone: emulators started with LANE set (owned by a `lane` tool, stopped by `lane down`)
# or with CC_TEAM_KEEP_EMULATOR=1, and everything when CC_TEAM_STOP_EMULATORS=0.
# Test seams: CC_TEAM_PROC (the /proc root), CC_TEAM_KILL (the kill command).

stop_session_emulators() { # <session uuid> [dry]; prints "stopped emulator <pid> <avd>" per hit
  local session="$1" dry="${2:-}" proc="${CC_TEAM_PROC:-/proc}" d pid argv0 env avd
  [ -n "$session" ] && [ "${CC_TEAM_STOP_EMULATORS:-1}" != 0 ] && [ -d "$proc" ] || return 0
  for d in "$proc"/[0-9]*; do
    pid="${d##*/}"
    [ -r "$d/cmdline" ] && [ -r "$d/environ" ] || continue
    argv0=$(tr '\0' '\n' < "$d/cmdline" 2>/dev/null | head -n 1)
    case "${argv0##*/}" in qemu-system-*|emulator|emulator64-*) ;; *) continue ;; esac
    env=$(tr '\0' '\n' < "$d/environ" 2>/dev/null) || continue
    printf '%s\n' "$env" | grep -qx "CLAUDE_CODE_SESSION_ID=$session" || continue
    printf '%s\n' "$env" | grep -q '^LANE=.' && continue
    printf '%s\n' "$env" | grep -qx 'CC_TEAM_KEEP_EMULATOR=1' && continue
    avd=$(tr '\0' '\n' < "$d/cmdline" | awk 'p { print; exit } $0 == "-avd" { p = 1 }')
    if [ -n "$dry" ]; then
      printf 'would stop emulator %s %s\n' "$pid" "${avd:--}"
    elif ${CC_TEAM_KILL:-kill} -TERM "$pid" 2>/dev/null; then
      printf 'stopped emulator %s %s\n' "$pid" "${avd:--}"
    fi
  done
  return 0
}
