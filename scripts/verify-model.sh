#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p artifacts
swift test --jobs 4 2>&1 | tee artifacts/model-tests.log
