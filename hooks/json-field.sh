#!/usr/bin/env bash
# Pull one string field out of a hook's stdin payload.
#
# `jq` is not guaranteed to exist (a stock Windows Git Bash has none, for one), and a
# hook that needs a tool the operator does not have is a hook that silently
# never fires. awk is present in every Git Bash install, so the parse lives here.
#
#   json_string_field <key> [anchor]
#
# `anchor` scopes the search to the text after the first occurrence of that key, which is
# how `command` is read from inside `tool_input` rather than from anywhere else.

json_string_field() {
  local key="$1" anchor="${2:-}"
  awk -v key="$key" -v anchor="$anchor" '
    { buf = buf $0 "\n" }
    END {
      s = buf
      if (anchor != "") {
        i = index(buf, "\"" anchor "\"")
        if (i) s = substr(buf, i)
      }
      j = index(s, "\"" key "\"")
      if (!j) exit 0
      s = substr(s, j + length(key) + 2)
      k = 1
      while (k <= length(s) && substr(s, k, 1) ~ /[ \t\r\n:]/) k++
      if (substr(s, k, 1) != "\"") exit 0
      k++
      out = ""
      while (k <= length(s)) {
        c = substr(s, k, 1)
        if (c == "\\") {
          k++
          e = substr(s, k, 1)
          if (e == "n")      out = out "\n"
          else if (e == "t") out = out "\t"
          else if (e == "r") out = out "\r"
          else if (e == "u") {
            hex = substr(s, k + 1, 4)
            k += 4
            code = 0
            for (h = 1; h <= 4; h++) {
              d = index("0123456789abcdef", tolower(substr(hex, h, 1))) - 1
              if (d < 0) { code = -1; break }
              code = code * 16 + d
            }
            out = out (code > 0 && code < 128 ? sprintf("%c", code) : " ")
          }
          else               out = out e
          k++
        } else if (c == "\"") {
          break
        } else {
          out = out c
          k++
        }
      }
      printf "%s", out
    }'
}

# Split a shell command into the pieces a separate program could run: the operators
# Claude Code itself recognises as command separators, plus subshell and substitution
# punctuation, so `foo && git checkout x` and `echo "$(git checkout x)"` both surface the
# inner command as its own segment.
command_segments() {
  printf '%s\n' "$1" | sed -e 's/[`(){};|&]/\n/g'
}

# Reduce one segment to `<git subcommand> <args...>`, or nothing if it is not a git call.
# Leading `VAR=x` assignments and the wrapper programs that run their argument are stepped
# over first; then git's own global options, so `git -C dir checkout` is still a checkout.
git_subcommand_args() {
  local seg="$1"
  # Word splitting is the point here.
  # shellcheck disable=SC2086
  set -- $seg
  while [ $# -gt 0 ]; do
    case "$1" in
      *=*) shift ;;
      timeout|time|nice|nohup|stdbuf|command|builtin|xargs|sudo|env) shift ;;
      *) break ;;
    esac
  done
  [ $# -gt 0 ] || return 1
  case "${1##*/}" in
    git|git.exe) shift ;;
    *) return 1 ;;
  esac
  while [ $# -gt 0 ]; do
    case "$1" in
      -C|-c|--git-dir|--work-tree|--namespace|--exec-path)
        if [ $# -ge 2 ]; then shift 2; else shift; fi ;;
      -*) shift ;;
      *) break ;;
    esac
  done
  [ $# -gt 0 ] || return 1
  printf '%s\n' "$@"
}
