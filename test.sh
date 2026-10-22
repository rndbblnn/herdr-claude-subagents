#!/usr/bin/env bash
# Hook allow/block matrix + spawner dry run. Usage: ./test.sh
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

for f in "$ROOT"/hooks/*.sh "$ROOT"/scripts/*.sh; do
  bash -n "$f" && echo "ok   syntax $(basename "$f")" || { echo "FAIL syntax $f"; fail=1; }
done

exit $fail
