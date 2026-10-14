#!/bin/sh
# Explicitly invoke an interpreter in the manifest; no executable bit is needed.
# The inherited target is captured when the command is invoked, not when this runs.
set -eu
"$SLATE_TERM_CLI" command run split.left
