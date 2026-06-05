#!/usr/bin/env bash
# Stop hook — a computational sensor (feedback control) for the agent harness.
#
# Runs the fast Rust check once when the agent finishes a turn. Stays silent on
# success ("success is silent"); on failure it surfaces the errors and blocks the
# stop so the agent self-corrects ("failures are verbose").
#
# Honors `stop_hook_active` so verification runs at most once per turn and never
# loops. See addyosmani.com/blog/agent-harness-engineering &
# martinfowler.com/articles/harness-engineering.
set -uo pipefail

input="$(cat 2>/dev/null || true)"

# If we already blocked this stop once, don't block again — let the agent finish.
active="$(printf '%s' "$input" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin).get("stop_hook_active", False))' 2>/dev/null \
  || echo False)"
[ "$active" = "True" ] && exit 0

cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0

# Fast deterministic sensor. `just check` == `cargo check --all-targets`.
command -v just >/dev/null 2>&1 || exit 0
if ! out="$(just check 2>&1)"; then
  {
    echo "⚠️  Verification sensor: \`just check\` failed — fix before finishing:"
    printf '%s\n' "$out" | tail -n 60
    echo ""
    echo "(Swift changes still need \`just mac-test\` / \`just mac-build\`.)"
  } >&2
  exit 2
fi
exit 0
