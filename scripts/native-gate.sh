#!/bin/bash
# Shared build-only/prebuilt boundary for standalone native verification scripts.
slate_native_gate() {
  local name="$1"
  [[ "$name" =~ ^[a-z0-9-]+$ ]] || { echo 'Invalid native gate name' >&2; exit 1; }
  [[ "${SLATE_VM_BUILD_ONLY:-0}:${SLATE_VM_PREBUILT:-0}" != 1:1 ]] || {
    echo 'Build-only and prebuilt execution are mutually exclusive' >&2; exit 1;
  }
  mkdir -p artifacts
  if [[ "${SLATE_VM_BUILD_ONLY:-0}" == 1 || "${SLATE_VM_PREBUILT:-0}" == 1 ]]; then
    gate="$PWD/.build/vm-native/$name"
    mkdir -p "$gate"
  else
    gate="$(mktemp -d "${TMPDIR:-/tmp}/slate-$name.XXXXXXXX")"
    trap 'slate_native_cleanup' EXIT
  fi
}

slate_native_cleanup() {
  local status=$?
  if [[ "$status" != 0 && "${SLATE_NATIVE_KEEP_FAILURE:-0}" == 1 ]]; then
    echo "Preserved fixture ownership metadata: $gate" >&2
  else
    rm -rf "$gate"
  fi
}

slate_native_swiftc() {
  [[ "${SLATE_VM_PREBUILT:-0}" != 1 ]] || {
    echo 'FAIL: native gate attempted guest compilation' >&2; return 125;
  }
  local output='' library=0 previous='' argument
  local archive_flags=()
  for argument in "$@"; do
    [[ "$previous" != -o ]] || output="$argument"
    [[ "$argument" != -emit-library ]] || library=1
    # Standalone consumers do not inherit SwiftPM's transitive C-module/link flags.
    if [[ "$argument" == -lSlateTermSettings || "$argument" == */SlateTermSettings.o ]]; then
      archive_flags=(-I "$PWD/Sources/SlateArchive/include" -larchive)
      if [[ "$argument" == */SlateTermSettings.o ]]; then
        archive_flags+=("${argument%/*}/SlateArchive.o")
      fi
    fi
    previous="$argument"
  done
  [[ -n "$output" ]] || { echo 'Native compiler output (-o) is required' >&2; return 1; }
  if [[ "$library" == 1 ]]; then
    command swiftc "$@" ${archive_flags[@]+"${archive_flags[@]}"} -Xlinker -install_name -Xlinker "@rpath/$(basename "$output")" \
      -Xlinker -rpath -Xlinker '@loader_path'
  else
    command swiftc "$@" ${archive_flags[@]+"${archive_flags[@]}"} -Xlinker -rpath -Xlinker '@loader_path'
  fi
}

slate_native_ready() {
  [[ -x "$1" ]] || { echo "Missing native executable: $1" >&2; exit 1; }
  # This is the only host preparation exit: no fixture is launched above it.
  [[ "${SLATE_VM_BUILD_ONLY:-0}" != 1 ]] || exit 0
}

slate_native_cli() {
  if [[ "${SLATE_VM_PREBUILT:-0}" == 1 ]]; then
    printf '%s\n' "$PWD/.build/vm-support/slate-term"
  else
    printf '%s/slate-term\n' "$(command swift build --show-bin-path)"
  fi
}
