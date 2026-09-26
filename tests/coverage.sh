#!/bin/bash
# Line coverage of the shell this project writes, measured with kcov over
# the bats suite (decision 0004). The measured files are the first boot
# library and the first boot hook itself; the 95 percent bar of decision
# 0003 applies to both. Exits 1 below the threshold, 2 when a tool is
# missing.
#
#   tests/coverage.sh [THRESHOLD]
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
threshold="${1:-${COVERAGE_THRESHOLD:-95}}"

for tool in kcov bats python3; do
    if ! command -v "$tool" >/dev/null; then
        echo "$tool not found (apt-get install $tool)" >&2
        exit 2
    fi
done

report="${COVERAGE_DIR:-$(mktemp -d)}"
kcov --include-pattern=/lib/nodebb.sh,/firstboot.d/40nodebb \
    --exclude-pattern=/tests/ \
    "$report" bats "$here"

json="$(find "$report" -mindepth 2 -maxdepth 2 -name coverage.json -not -path "*/kcov-merged/*" | head -1)"
echo
echo "kcov line coverage (threshold $threshold percent):"
awk -F'"' -v threshold="$threshold" '
    /^ *\{"file":/ {
        n = split($4, parts, "/")
        printf "%7.2f  %s/%s  %s", $8, $12, $16, parts[n]
        if ($8 + 0 < threshold) { printf "  BELOW THRESHOLD"; below = 1 }
        printf "\n"
        seen = 1
    }
    END {
        if (!seen) { print "no file measured"; exit 1 }
        exit below
    }' "$json"
