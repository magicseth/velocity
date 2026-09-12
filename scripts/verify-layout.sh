#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/layout-check
sources=()
for source in Sources/TerminalVelocity/*.swift; do
  [[ "$source" == */App.swift ]] || sources+=("$source")
done
swiftc -parse-as-library "${sources[@]}" scripts/verify-layout.swift -o .build/layout-check/render
.build/layout-check/render
