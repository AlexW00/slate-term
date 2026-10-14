#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p artifacts
export SLATE_TEST_PYTHON="$(command -v python3)"
xcrun swiftc -swift-version 6 -parse-as-library Native/PluginProcess.swift Native/PluginListener.swift Tests/PluginListener/Listener.swift -o artifacts/plugin-listener-gate
artifacts/plugin-listener-gate
