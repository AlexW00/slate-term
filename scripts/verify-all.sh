#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p artifacts
python3 scripts/verification-manifest.py start
run() {
  local name="$1"
  shift
  "$@" 2>&1 | tee "artifacts/final-$name.log"
  printf '%s\n' "$name" >> artifacts/verification-checks.txt
}
run engine bash scripts/build-ghostty.sh
run model bash scripts/verify-model.sh
run mutations python3 scripts/verify-model-mutations.py
run terminal-keys bash scripts/verify-terminal-keys.sh
run terminal-runs bash scripts/verify-terminal-runs.sh
run event-hub bash scripts/verify-event-hub.sh
run plugin-process bash scripts/verify-plugin-process.sh
run plugin-listener bash scripts/verify-plugin-listener.sh
run process-titles bash scripts/verify-process-titles.sh
run pane-movement-native bash scripts/verify-pane-movement-native.sh
run pane-titles-native bash scripts/verify-pane-titles-native.sh
# GUI gates are deliberately sequential and own their windows/state/processes.
run terminal bash scripts/verify-terminal.sh
run build bash scripts/build-app.sh
run plugin-worker python3 scripts/verify-plugin-worker.py
for iteration in 1 2 3; do
  run "app-$iteration" python3 scripts/verify-app.py
done
run config-cli python3 scripts/verify-config-cli.py
run settings python3 scripts/verify-settings.py
run settings-window python3 scripts/verify-settings-window.py
run command-picker python3 scripts/verify-command-picker.py
run window-recovery python3 scripts/verify-window-recovery.py
run appearance python3 scripts/verify-appearance.py
run palettes python3 scripts/verify-palettes.py
run menu-ui python3 scripts/verify-menu-ui.py
run shell python3 scripts/verify-shell.py
run browser python3 scripts/verify-browser.py
run context python3 scripts/verify-context.py
run pane-titles python3 scripts/verify-pane-titles.py
run pane-movement python3 scripts/verify-pane-movement.py
run plugins python3 scripts/verify-plugins.py
run plugin-services python3 scripts/verify-plugin-services.py
run plugin-commands python3 scripts/verify-plugin-commands.py
run plugin-header-buttons python3 scripts/verify-plugin-header-buttons.py
run events python3 scripts/verify-events.py
run extension-interop python3 scripts/verify-extension-interop.py
run whitespace git diff --check
python3 scripts/verification-manifest.py finish
