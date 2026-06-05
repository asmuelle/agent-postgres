#!/usr/bin/env bash

set -euo pipefail

tool_name="${1:-}"
if [[ -z "$tool_name" ]]; then
    echo "usage: $0 <sparkle-tool-name>" >&2
    exit 64
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
macos_dir="$(cd "${script_dir}/.." && pwd)"

if [[ -n "${SPARKLE_BIN_DIR:-}" && -x "${SPARKLE_BIN_DIR}/${tool_name}" ]]; then
    printf '%s\n' "${SPARKLE_BIN_DIR}/${tool_name}"
    exit 0
fi

candidates=(
    "${macos_dir}/build/SourcePackages/artifacts/sparkle/Sparkle/bin/${tool_name}"
    "/private/tmp/rshell-dd/SourcePackages/artifacts/sparkle/Sparkle/bin/${tool_name}"
    "/Applications/Sparkle/bin/${tool_name}"
)

for candidate in "${candidates[@]}"; do
    if [[ -x "$candidate" ]]; then
        printf '%s\n' "$candidate"
        exit 0
    fi
done

if [[ -d "${HOME}/Library/Developer/Xcode/DerivedData" ]]; then
    found="$(
        find "${HOME}/Library/Developer/Xcode/DerivedData" \
            -path "*/artifacts/sparkle/Sparkle/bin/${tool_name}" \
            -type f \
            -perm -111 \
            2>/dev/null \
            | sort \
            | tail -n 1
    )"

    if [[ -n "$found" ]]; then
        printf '%s\n' "$found"
        exit 0
    fi
fi

echo "Sparkle tool not found: ${tool_name}" >&2
echo "Set SPARKLE_BIN_DIR or build once after resolving Swift packages." >&2
exit 1
