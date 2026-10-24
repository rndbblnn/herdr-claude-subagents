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
  "tab list")   echo "${FAKE_TABS:-{\"result\":{\"tabs\":[]}\}}" ;;
  "pane list")  echo "${FAKE_PANES:-{\"result\":{\"panes\":[]}\}}" ;;
  "agent list") echo "${FAKE_AGENTS:-{\"result\":{\"agents\":[]}\}}" ;;
  "agent rename") [ -z "${FAKE_RENAME_FAIL:-}" ] || exit 1 ;;
  "agent start") [ -z "${FAKE_START_FAIL:-}" ] || { [ -e "$FAKE_LOG.started" ] || { touch "$FAKE_LOG.started"; exit 1; }; } ;;
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
    XDG_STATE_HOME="$T/state" \
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
printf -- '---\nname: hcs-test-uni\ndescription: a — b “q” 🦀\ntools: Read\n---\nx — y\n' > "$T/cfg/agents/uni.md"
spawn "$T/g2" uni --task t1 --orchestrator boss -- --agent hcs-test-uni
expect "--agents JSON is pure ASCII and round-trips non-ASCII" bash -c '
  printf "%s" "$1" | LC_ALL=C grep -q "[^ -~]" && exit 1
  printf "%s" "$1" | python3 -I -c "
import json,sys; a=json.load(sys.stdin)[\"hcs-test-uni\"]
assert a[\"description\"]==\"a — b “q” \U0001f980\", a; assert a[\"prompt\"]==\"x — y\", a"' _ "$(agents_arg "$T/g2")"
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

# Orchestrator naming: the caller's pane gets the peer name as its Herdr name, lowercased
# because Herdr refuses uppercase ("LaneB" -> invalid_agent_name, observed 2026-10-24).
export -f call
spawn "$T/m" kid --task t1 --orchestrator LaneB
expect "orchestrator pane renamed to a Herdr-safe name" \
  bash -c '[ "$(call "$1" agent rename | tr "\n" " ")" = "w0:p1 laneb " ]' _ "$T/m"
expect "no --orchestrator, no rename" bash -c '! grep -qx rename "$1"' _ "$T/c"
expect "the child's pane and --name never take the orchestrator's name" bash -c '
  ! awk "/^agent\$/{a=1} a&&/^--name\$/{getline; print; exit}" "$1" | grep -qix laneb &&
  ! grep -A1 -x rename "$1" | grep -qx w0:p9' _ "$T/m"
spawn "$T/m2" laneb --task t1 --orchestrator LaneB
expect "a child named like its orchestrator is refused" \
  bash -c 'grep -q "orchestrator.s own name" "$1.err" && ! grep -qx start "$1"' _ "$T/m2"
: > "$T/n"; env PATH="$T/bin:$PATH" FAKE_LOG="$T/n" FAKE_RENAME_FAIL=1 CLAUDE_CONFIG_DIR="$T/cfg" \
  HERDR_ENV=1 HERDR_WORKSPACE_ID=w0 HERDR_PANE_ID=w0:p1 XDG_STATE_HOME="$T/state" \
  bash "$ROOT/scripts/herdr-spawn.sh" kid --task t1 --orchestrator boss --cwd "$ROOT" >/dev/null 2>"$T/n.err"
expect "a refused rename only warns" bash -c 'grep -q "could not name pane" "$1.err" && grep -qx start "$1"' _ "$T/n"

# A first `agent start` that fails (the shell-typing race) is retried once after Ctrl-C.
: > "$T/v"; env PATH="$T/bin:$PATH" FAKE_LOG="$T/v" FAKE_START_FAIL=1 CLAUDE_CONFIG_DIR="$T/cfg" \
  HERDR_ENV=1 HERDR_WORKSPACE_ID=w0 HERDR_PANE_ID=w0:p1 XDG_STATE_HOME="$T/state" \
  bash "$ROOT/scripts/herdr-spawn.sh" retry --task t1 --cwd "$ROOT" >/dev/null 2>"$T/v.err"
expect "a failed agent start is retried once after C-c" bash -c '
  [ "$(grep -cx start "$1")" = 2 ] && grep -A2 -x send-keys "$1" | grep -qx C-c && grep -q retrying "$1.err"' _ "$T/v"

# Report hook injection: --settings names hooks/team-report.sh for PostToolUse(SendMessage)
# and Stop, and the pane env names the report file.
settings_arg() { awk '/^agent$/{a=1} a&&p{print; exit} a&&/^--settings$/{p=1}' "$1"; }
expect "--settings injects the report hook" bash -c 'python3 -I -c "
import json,sys; s=json.load(sys.stdin)[\"hooks\"]
assert s[\"PostToolUse\"][0][\"matcher\"]==\"SendMessage\", s
for e in (\"PostToolUse\",\"Stop\"): assert s[e][0][\"hooks\"][0][\"command\"]==\"bash \\\"$2/hooks/team-report.sh\\\"\", s" < "$1"' _ "$(settings_arg "$T/a")" "$ROOT"
expect "settings file sits beside the report" bash -c '[ "$1" = "$2/state/herdr-spawn/t1/reviewer.settings.json" ]' _ "$(settings_arg "$T/a")" "$T"
expect "pane env carries CC_TEAM_REPORT_FILE" grep -qx "CC_TEAM_REPORT_FILE=$T/state/herdr-spawn/t1/reviewer.md" "$T/a"
expect "no --oneshot, no CC_TEAM_ONESHOT" bash -c '! grep -q CC_TEAM_ONESHOT "$1"' _ "$T/a"
spawn "$T/o" one --task t1 --oneshot
expect "--oneshot sets CC_TEAM_ONESHOT=1" grep -qx CC_TEAM_ONESHOT=1 "$T/o"
spawn "$T/p" own --task t1 -- --settings '{"x":1}'
expect "caller's --settings wins, with a warning" \
  bash -c '[ "$(grep -cx -- --settings "$1")" = 1 ] && grep -q "no FINAL report hook" "$1.err"' _ "$T/p"
mkdir -p "$T/state/herdr-spawn/t1" && echo stale > "$T/state/herdr-spawn/t1/fresh.md"
spawn "$T/q" fresh --task t1
expect "spawn removes a stale report of the same name" test ! -e "$T/state/herdr-spawn/t1/fresh.md"

# The hook itself. Always exit 0; writes only on a FINAL.
RHOOK="$ROOT/hooks/team-report.sh"
RF="$T/state/herdr-spawn/t2/kid.md"
hook_run() { # <log> <payload> [env...]  → hook exit status
  local log="$1" p="$2"; shift 2; : > "$log"
  printf '%s' "$p" | env PATH="$T/bin:$PATH" FAKE_LOG="$log" HERDR_ENV=1 HERDR_PANE_ID=w0:p7 \
    CC_TEAM_REPORT_FILE="$RF" CC_TEAM_AGENT=kid CC_TEAM_TASK=t2 CC_TEAM_ORCHESTRATOR=boss \
    CC_TEAM_ORCHESTRATOR_PANE=w0:p1 "$@" bash "$RHOOK"
}
ptu() { printf '{"session_id":"s-1","hook_event_name":"PostToolUse","tool_name":"%s","tool_input":{"to":"boss","message":"%s"},"tool_response":{"message":"sent"}}' "$1" "$2"; }
hook_run "$T/r1" "$(ptu SendMessage 'just a question')"
expect "non-FINAL SendMessage writes nothing" test ! -e "$RF"
hook_run "$T/r1" "$(ptu Bash 'FINAL: no')"
expect "other tools write nothing" test ! -e "$RF"
hook_run "$T/r2" "$(ptu SendMessage 'FINAL: all \"done\"\nline two')"
expect "FINAL SendMessage saves the report with its session" \
  bash -c 'grep -qx "session_id: s-1" "$1" && grep -qx "source: SendMessage" "$1" && grep -qx "FINAL: all \"done\"" "$1" && grep -qx "line two" "$1"' _ "$RF"
expect "report notifies the orchestrator pane" \
  bash -c '[ "$(call "$1" pane report-metadata | head -1)" = w0:p1 ] && grep -qx "last_report=kid" "$1" && [ "$(call "$1" notification show | grep -A1 -x -- --sound | tail -1)" = none ]' _ "$T/r2"
hook_run "$T/r2b" '{"session_id":"s-1","hook_event_name":"Stop","last_assistant_message":"FINAL: sent it"}'
expect "a Stop echo never overwrites the SendMessage report" \
  bash -c 'grep -qx "source: SendMessage" "$1" && grep -qx "line two" "$1"' _ "$RF"
rm -f "$RF"
hook_run "$T/r3" '{"session_id":"s-2","hook_event_name":"Stop","last_assistant_message":"  FINAL: by Stop"}'
expect "Stop with a FINAL last message saves it" \
  bash -c 'grep -qx "source: Stop" "$1" && grep -qx "session_id: s-2" "$1"' _ "$RF"
rm -f "$RF"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"FINAL: old"}]}}' \
  '{"type":"user","message":{"content":"more"}}' \
  '{"type":"assistant","message":{"content":[{"type":"text","text":"FINAL: from transcript"}]}}' > "$T/tr.jsonl"
hook_run "$T/r4" "{\"session_id\":\"s-3\",\"hook_event_name\":\"Stop\",\"transcript_path\":\"$T/tr.jsonl\"}"
expect "Stop falls back to the transcript's last text" grep -qx "FINAL: from transcript" "$RF"
rm -f "$RF"
hook_run "$T/r5" '{"session_id":"s-4","hook_event_name":"Stop","last_assistant_message":"Waiting for your answer."}'
expect "Stop without FINAL writes nothing" test ! -e "$RF"
expect "hook without CC_TEAM_REPORT_FILE exits 0" \
  bash -c 'printf "{\"hook_event_name\":\"Stop\"}" | env -u CC_TEAM_REPORT_FILE bash "$1"' _ "$RHOOK"
expect "hook with an unwritable report path exits 0" \
  bash -c 'printf "%s" "$1" | CC_TEAM_REPORT_FILE=/proc/nope/x.md bash "$2"' _ "$(ptu SendMessage 'FINAL: x')" "$RHOOK"
# --oneshot: after the report lands, Stop closes the child's own pane (delay 0 for the test).
hook_run "$T/r6" "$(ptu SendMessage 'FINAL: one')" >/dev/null
hook_run "$T/r6" '{"session_id":"s-1","hook_event_name":"Stop","last_assistant_message":"sent"}' CC_TEAM_ONESHOT=1 CC_TEAM_ONESHOT_DELAY=0
for _ in 1 2 3 4 5 6 7 8 9 10; do grep -qx close "$T/r6" && break; sleep 0.2; done
expect "--oneshot closes its own pane once reported" bash -c '[ "$(call "$1" pane close)" = w0:p7 ]' _ "$T/r6"
hook_run "$T/r7" '{"session_id":"s-other","hook_event_name":"Stop","last_assistant_message":"hi"}' CC_TEAM_ONESHOT=1 CC_TEAM_ONESHOT_DELAY=0
sleep 0.5
expect "--oneshot leaves the pane when the report is another session's" bash -c '! grep -qx close "$1"' _ "$T/r7"

# --reap: closes only idle/done panes whose report exists and matches the pane's session.
RD="$T/state/herdr-spawn/tr"; mkdir -p "$RD"
for n in a c; do printf -- '---\nsession_id: sess-%s\n---\nFINAL: x\n' "$n" > "$RD/$n.md"; done
printf -- '---\nsession_id: sess-old\n---\nFINAL: x\n' > "$RD/d.md"
ag() { printf '{"agent":"claude","agent_session":{"kind":"id","value":"sess-%s"},"agent_status":"%s","name":"%s","pane_id":"w0:p%s","tab_id":"w0:t5"}' "$1" "$2" "$1" "$3"; }
AGENTS="{\"result\":{\"agents\":[$(ag a idle 2),$(ag b idle 3),$(ag c working 4),$(ag d done 5),{\"agent\":\"claude\",\"agent_status\":\"idle\",\"pane_id\":\"w0:p1\",\"tab_id\":\"w0:t5\"}]}}"
PANES='{"result":{"panes":[{"pane_id":"w0:p1","tab_id":"w0:t5"},{"pane_id":"w0:p2","tab_id":"w0:t5"},{"pane_id":"w0:p3","tab_id":"w0:t5"},{"pane_id":"w0:p4","tab_id":"w0:t5"},{"pane_id":"w0:p5","tab_id":"w0:t5"},{"pane_id":"w0:p6","tab_id":"w0:t5"},{"pane_id":"w0:p8","tab_id":"w0:t0"}]}}'
: > "$T/s"
env PATH="$T/bin:$PATH" FAKE_LOG="$T/s" HERDR_ENV=1 HERDR_WORKSPACE_ID=w0 HERDR_PANE_ID=w0:p1 \
  XDG_STATE_HOME="$T/state" FAKE_AGENTS="$AGENTS" FAKE_PANES="$PANES" \
  FAKE_TABS='{"result":{"tabs":[{"label":"tr","tab_id":"w0:t5"}]}}' \
  bash "$ROOT/scripts/herdr-spawn.sh" --reap tr > "$T/s.out" 2>"$T/s.err"
expect "--reap closes exactly the reported, settled pane" \
  bash -c '[ "$(grep -A1 -x close "$1" | grep -v -x -e close -e -- | tr "\n" " ")" = "w0:p2 " ]' _ "$T/s"
expect "--reap explains every skip" bash -c '
  grep -q "^closed  w0:p2 a" "$1" && grep -q "^skipped w0:p1 - (this pane)" "$1" &&
  grep -q "^skipped w0:p3 b (no report at" "$1" && grep -q "^skipped w0:p4 c (agent is working)" "$1" &&
  grep -q "^skipped w0:p5 d (report in .* is from another session" "$1" &&
  grep -q "^skipped w0:p6 - (no agent in pane)" "$1" && ! grep -q w0:p8 "$1" &&
  grep -q "\"closed\":1,\"skipped\":5" "$1"' _ "$T/s.out"
: > "$T/u"
env PATH="$T/bin:$PATH" FAKE_LOG="$T/u" HERDR_ENV=1 HERDR_WORKSPACE_ID=w0 HERDR_PANE_ID=w0:p1 \
  bash "$ROOT/scripts/herdr-spawn.sh" --reap nosuch >/dev/null 2>"$T/u.err"
expect "--reap on an unknown task fails" bash -c 'grep -q "no tab labelled" "$1.err" && ! grep -qx close "$1"' _ "$T/u"

for f in "$ROOT"/hooks/*.sh "$ROOT"/scripts/*.sh; do
  bash -n "$f" && echo "ok   syntax $(basename "$f")" || { echo "FAIL syntax $f"; fail=1; }
done

exit $fail
