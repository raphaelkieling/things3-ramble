#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
swiftc -swift-version 6 -parse-as-library \
    Sources/Ramble/{AudioCapture,OpenAI,Realtime,Things}.swift \
    Tests/RambleChecks.swift -o "$scratch/ramble-checks"
"$scratch/ramble-checks"
