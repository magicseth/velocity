#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/screenshots docs/screenshots
sources=()
for source in Sources/TerminalVelocity/*.swift; do
  [[ "$source" == */App.swift ]] || sources+=("$source")
done
swiftc -parse-as-library "${sources[@]}" scripts/screenshots.swift -o .build/screenshots/render
.build/screenshots/render
