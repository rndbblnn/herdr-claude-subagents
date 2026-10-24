#!/usr/bin/env bash
# Hook allow/block matrix + spawner against a fake herdr. Usage: ./test.sh (KEEP_T=1 keeps logs)
set -u
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$ROOT/hooks/route-agent-to-herdr.sh"
fail=0

payload() { printf '{"tool_name":"Agent","tool_input":{%s"description":"t","prompt":"p"}}' "${1:+\"subagent_type\":\"$1\",}"; }

check() { # <want exit> <label> <subagent_type> [env...]
  local want="$1" label="$2" type="$3"; shift 3
  local got; payload "$type" | env -u CC_HERDR_ALLOWED_AGENTS -u CC_ALLOW_INPROCESS_AGENTS "$@" bash "$HOOK" >/dev/null 2>&1; got=$?
  if [ "$got" = "$want" ]; then echo "ok   $label"; else echo "FAIL $label (want $want, got $got)"; fail=1; fi
}

check 0 "outside Herdr, general-purpose allowed"  general-purpose HERDR_ENV=
check 2 "in Herdr, general-purpose blocked"       general-purpose HERDR_ENV=1
check 2 "in Herdr, missing type blocked"          ""              HERDR_ENV=1
check 2 "in Herdr, unknown type blocked"          some-writer     HERDR_ENV=1
check 0 "in Herdr, Explore allowed"               Explore         HERDR_ENV=1
check 0 "CC_HERDR_ALLOWED_AGENTS adds a type"     bulk-reader     HERDR_ENV=1 CC_HERDR_ALLOWED_AGENTS="foo, bulk-reader"
check 2 "allowlist env does not leak to others"   general-purpose HERDR_ENV=1 CC_HERDR_ALLOWED_AGENTS=bulk-reader
check 0 "CC_ALLOW_INPROCESS_AGENTS=1 escape"      general-purpose HERDR_ENV=1 CC_ALLOW_INPROCESS_AGENTS=1

msg=$(payload general-purpose | HERDR_ENV=1 bash "$HOOK" 2>&1 >/dev/null)
case "$msg" in *scripts/herdr-spawn.sh*skills/herdr-spawn/SKILL.md*) echo "ok   refusal names spawner and skill";;
  *) echo "FAIL refusal message"; fail=1;; esac

# Spawner, against a fake herdr that records each call's argv (one arg per line) so the
# return-path system prompt can be checked as a single, intact claude argument.
T=$(mktemp -d)
if [ -n "${KEEP_T:-}" ]; then echo "test dir kept: $T" >&2; else trap 'rm -rf "$T"' EXIT; fi
mkdir -p "$T/bin" "$T/cfg"
cat > "$T/bin/herdr" <<'FAKE'
#!/usr/bin/env bash
{ printf '%s\n' "$@"; echo '--end--'; } >> "$FAKE_LOG"
case "$1 $2" in
  "tab list")   echo '{"result":{"tabs":[]}}' ;;
  "tab create") echo '{"result":{"tab":{"tab_id":"w0:t9"},"root_pane":{"pane_id":"w0:p9"}}}' ;;
  "agent get")
    case "$3" in
      done1) echo '{"result":{"agent":{"name":"done1","pane_id":"w0:p7","tab_id":"w0:t9"}}}' ;;
      me)    echo '{"result":{"agent":{"name":"me","pane_id":"w0:p1","tab_id":"w0:t1"}}}' ;;
      *)     exit 1 ;;   # no agent by that name is live
    esac ;;
esac
FAKE
chmod +x "$T/bin/herdr"
# Pretty-printed like Claude Code writes it; the spawner's trust reader depends on that indent.
printf '{\n  "projects": {\n    "%s": {\n      "hasTrustDialogAccepted": true\n    }\n  }\n}\n' "$ROOT" > "$T/cfg/.claude.json"
spawn() { # <log> <spawner args...>
  local log="$1"; shift; : > "$log"
  env PATH="$T/bin:$PATH" FAKE_LOG="$log" CLAUDE_CONFIG_DIR="$T/cfg" HERDR_ENV=1 \
    HERDR_WORKSPACE_ID=w0 HERDR_PANE_ID=w0:p1 \
    bash "$ROOT/scripts/herdr-spawn.sh" "$@" --cwd "$ROOT" >/dev/null 2>"$log.err"
}
expect() { # <label> <command...>
  local label="$1"; shift
  if "$@"; then echo "ok   $label"; else echo "FAIL $label"; fail=1; fi
}
# The arg after --append-system-prompt in the `agent start` call.
appended() { awk '/^agent$/{a=1} a&&p{print; exit} a&&/^--append-system-prompt$/{p=1}' "$1"; }

spawn "$T/a" reviewer --task t1 --orchestrator boss --prompt hi
expect "spawn with --orchestrator succeeds" test ! -s "$T/a.err"
expect "return path names orchestrator, agent and task" \
  bash -c '[[ "$1" == *'"'"'"reviewer"'"'"'*'"'"'"boss"'"'"'*'"'"'"t1"'"'"'*SendMessage* ]]' _ "$(appended "$T/a")"
spawn "$T/b" reviewer --task t1 --orchestrator boss -- --append-system-prompt "CALLER-TEXT"
expect "caller's --append-system-prompt kept, ours first" \
  bash -c '[[ "$1" == You\ are*CALLER-TEXT ]] && [ "$(grep -c -- --append-system-prompt "$2")" = 1 ]' _ "$(appended "$T/b")" "$T/b"
spawn "$T/c" reviewer --task t1
expect "no --orchestrator, no return path" \
  bash -c 'grep -qx start "$1" && ! grep -q -- --append-system-prompt "$1"' _ "$T/c"
# The argv of the first call to `herdr <1> <2>`, one arg per line.
call() { awk -v a="$2" -v b="$3" 'p&&/^--end--$/{exit} p{print} prev==a&&$0==b{p=1} {prev=$0}' "$1"; }
expect "child pane tagged with \$team and \$parent" \
  bash -c 'c=$(printf "%s\n" "$1"); [[ "$c" == *w0:p9*team=t1*parent=boss* ]]' _ "$(call "$T/a" pane report-metadata)"
expect "child pane gets an indented \$nested name" \
  bash -c '[[ "$1" == *nested=$'"'"'\u2800'"'"'*reviewer* ]]' _ "$(call "$T/a" pane report-metadata)"
expect "no --orchestrator, \$team only" \
  bash -c '[[ "$1" == *team=t1* && "$1" != *parent=* ]]' _ "$(call "$T/c" pane report-metadata)"
expect "orchestrator pane gets its name as display name" \
  bash -c 'awk "/^report-metadata\$/{r=1} r&&/^--end--\$/{r=0} r" "$1" | tr "\n" " " | grep -q "w0:p1 --source herdr-spawn --display-agent boss"' _ "$T/a"
spawn "$T/d" done1 --close
expect "--close closes the agent's pane" \
  bash -c 'test ! -s "$2.err" && [ "$1" = w0:p7 ]' _ "$(call "$T/d" pane close)" "$T/d"
spawn "$T/e" me --close
expect "--close refuses this pane" bash -c 'test -s "$1.err" && ! grep -qx close "$1"' _ "$T/e"
spawn "$T/f" ghost --close
expect "--close on an unknown agent fails" bash -c 'test -s "$1.err" && ! grep -qx close "$1"' _ "$T/f"

# --agent with a tools whitelist: the spawner re-emits it via --agents with SendMessage added.
# User-level agents dir = $CLAUDE_CONFIG_DIR/agents; names are unique so no real agent matches.
mkdir -p "$T/cfg/agents"
printf -- '---\nname: hcs-test-wl\ndescription: "Has: a colon"\ntools: [Read, Bash]\nmodel: sonnet\n---\n\nLine "one"\n\tTabbed \\ slash\n' > "$T/cfg/agents/wl.md"
printf -- '---\nname: hcs-test-all\ndescription: no whitelist\n---\nBody\n' > "$T/cfg/agents/all.md"
printf -- '---\nname: hcs-test-has\ndescription: d\ntools:\n  - Read\n  - SendMessage\n---\nBody\n' > "$T/cfg/agents/has.md"
printf -- '---\nname: hcs-test-odd\ndescription: d\ntools: [Read]\nhooks:\n  Stop: x\n---\nBody\n' > "$T/cfg/agents/odd.md"
# The arg after --agents in the `agent start` call.
agents_arg() { awk '/^agent$/{a=1} a&&p{print; exit} a&&/^--agents$/{p=1}' "$1"; }
spawn "$T/g" wl --task t1 --orchestrator boss -- --agent hcs-test-wl
expect "--agent whitelist gains SendMessage via --agents" \
  bash -c 'printf "%s" "$1" | python3 -I -c "
import json,sys; a=json.load(sys.stdin)[\"hcs-test-wl\"]
assert a[\"tools\"]==[\"Read\",\"Bash\",\"SendMessage\"], a
assert a[\"model\"]==\"sonnet\" and a[\"description\"]==\"Has: a colon\", a
assert a[\"prompt\"]==\"Line \\\"one\\\"\n\tTabbed \\\\ slash\", repr(a[\"prompt\"])"' _ "$(agents_arg "$T/g")"
spawn "$T/h" all --task t1 --orchestrator boss -- --agent hcs-test-all
expect "--agent without a whitelist is left alone" bash -c '! grep -qx -- --agents "$1" && test ! -s "$1.err"' _ "$T/h"
spawn "$T/i" has --task t1 --orchestrator boss -- --agent=hcs-test-has
expect "--agent= already holding SendMessage is left alone" bash -c '! grep -qx -- --agents "$1" && test ! -s "$1.err"' _ "$T/i"
spawn "$T/j" odd --task t1 --orchestrator boss -- --agent hcs-test-odd
expect "unparsed frontmatter warns, spawns unchanged" \
  bash -c '! grep -qx -- --agents "$1" && grep -q "does not parse" "$1.err" && grep -qx start "$1"' _ "$T/j"
spawn "$T/k" wl2 --task t1 -- --agent hcs-test-wl
expect "no --orchestrator, no --agents rewrite" bash -c '! grep -qx -- --agents "$1"' _ "$T/k"
spawn "$T/l" ghost2 --task t1 --orchestrator boss -- --agent hcs-test-missing
expect "unknown --agent warns" bash -c 'grep -q "no .claude/agents file" "$1.err" && grep -qx start "$1"' _ "$T/l"

# Trust follows git: a nested repo under a trusted dir is NOT trusted, a linked worktree of a
# trusted repo IS (both observed live 2026-10-24). --dry-run still runs the trust preflight.
G=(git -c user.name=t -c user.email=t@t -c init.defaultBranch=main)
"${G[@]}" init -q "$T/outer" && "${G[@]}" -C "$T/outer" commit -q --allow-empty -m init
mkdir -p "$T/outer/sub" && "${G[@]}" init -q "$T/outer/inner"
"${G[@]}" -C "$T/outer" worktree add -q "$T/wt" 2>/dev/null
mkdir -p "$T/cfg2"
printf '{\n  "projects": {\n    "%s": {\n      "hasTrustDialogAccepted": true\n    }\n  }\n}\n' "$T/outer" > "$T/cfg2/.claude.json"
trust_try() { # <cwd> [extra args] → exit status of a dry-run spawn; stderr in $T/tt.err
  local dir="$1"; shift
  env PATH="$T/bin:$PATH" FAKE_LOG="$T/tt" CLAUDE_CONFIG_DIR="$T/cfg2" HERDR_ENV=1 \
    HERDR_WORKSPACE_ID=w0 HERDR_PANE_ID=w0:p1 \
    bash "$ROOT/scripts/herdr-spawn.sh" tt --task t1 --dry-run --cwd "$dir" "$@" >/dev/null 2>"$T/tt.err"
}
expect "subdir of a trusted repo is trusted"        trust_try "$T/outer/sub"
refused_untrusted() { ! trust_try "$1" && grep -q "has not been trusted" "$T/tt.err"; }
expect "nested repo under a trusted dir is refused" refused_untrusted "$T/outer/inner"
expect "linked worktree of a trusted repo is trusted" trust_try "$T/wt"
trusted_with_imports() { trust_try "$1" --trust && grep -q "external CLAUDE.md imports approved" "$T/tt.err"; }
expect "--trust also approves external imports" trusted_with_imports "$T/outer/inner"

for f in "$ROOT"/hooks/*.sh "$ROOT"/scripts/*.sh; do
  bash -n "$f" && echo "ok   syntax $(basename "$f")" || { echo "FAIL syntax $f"; fail=1; }
done

exit $fail
