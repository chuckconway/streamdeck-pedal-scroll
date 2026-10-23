#!/bin/bash
# Build and run the PedalLogic tests. No Xcode required.

set -euo pipefail

cd "$(dirname "$0")"

OUT="build/tests"
mkdir -p "$OUT"
swiftc PedalLogic.swift tests/main.swift -o "$OUT/PedalLogicTests"
"$OUT/PedalLogicTests"
