#!/bin/bash
# The shared inventory owns every gate, including all three app iterations.
# Builds and quiet checks run on the host; all native/UI execution stays in VMPal.
set -euo pipefail
cd "$(dirname "$0")/.."
exec python3 scripts/verify-vm.py --all "$@"
