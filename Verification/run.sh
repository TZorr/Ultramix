#!/bin/bash
#
# Verification/run.sh
# Ultramix
#
# Builds and runs the verification harness against the app's non-UI
# sources: Model, Analysis, Engine and Export. The UI is left out on
# purpose - anything a view decides that needs checking belongs in a pure
# function in one of those folders, where this harness can reach it.
#
# The folders are globbed rather than listed. A list goes stale the first
# time someone adds a file, and the harness then fails to link for a reason
# that has nothing to do with the change.
#
# LAME is C, so it is compiled with clang into objects first (once; an
# object is rebuilt only when its source is newer), with the same defines
# as the app target, and the Swift side sees it through the app's own
# bridging header.
#
# Usage: Verification/run.sh [-O]      (-O: optimised, as the Release app)
#

set -euo pipefail
cd "$(dirname "$0")/.."

OPT="-Onone"
[[ "${1:-}" == "-O" ]] && OPT="-O"

OUT="${TMPDIR:-/tmp}/ultramix_verify"
LAME="Ultramix/LAME"
OBJECTS="$OUT.lame"
mkdir -p "$OBJECTS"
for source in "$LAME"/*.c; do
    object="$OBJECTS/$(basename "$source" .c).o"
    if [[ ! "$object" -nt "$source" || "$LAME/config.h" -nt "$object" ]]; then
        clang -c -O2 -w -arch arm64 -DHAVE_CONFIG_H=1 -I"$LAME" -I"$LAME/vector" -o "$object" "$source"
    fi
done

SOURCES=()
for dir in Model Analysis Engine Export; do
    [[ -d "Ultramix/$dir" ]] || continue
    while IFS= read -r -d '' file; do SOURCES+=("$file"); done \
        < <(find "Ultramix/$dir" -name '*.swift' -print0 | sort -z)
done

swiftc $OPT -default-isolation MainActor -swift-version 5 \
    -import-objc-header Ultramix/Ultramix-Bridging-Header.h -Xcc -I"$LAME" \
    -o "$OUT" Verification/main.swift "${SOURCES[@]}" "$OBJECTS"/*.o
"$OUT"
