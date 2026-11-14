#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
test -d Benchmarks/audio || python3 Benchmarks/prepare.py
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
swiftc -swift-version 6 -parse-as-library -target "$(uname -m)-apple-macos26.0" \
    Sources/Ramble/{AudioCapture,Language,LocalTranscriber,OpenAI,Realtime,Timing,TranscriptUpdate}.swift \
    Benchmarks/Run.swift -o "$scratch/bench"
TZ=America/Sao_Paulo "$scratch/bench" "$@"
python3 Benchmarks/report.py
