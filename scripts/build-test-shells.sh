#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Self-contained bash and fish binaries for VM shell-integration tests. Deliberate upgrades only.
bash52_sha=9599b22ecd1d5787ad7d3b7bf0c59f312b3396d1e281175dd1f8a4014da621ff
bash53_sha=0d5cd86965f869a26cf64f4b71be7b96f90a3ba8b3d74e27e8e9d9d5550f31ba
bash53_patches=20
# Hash of all official bash53-NNN patches concatenated in order.
bash53_patches_sha=67aa3c11559c91dde818a8466a6a0b312de5f42b0c3f6b90cdd61ec4b7c8fd4d
fish_version=4.9.3
fish_sha=20998a25f73217ddcc19f499055fd587e9912d1ad6e7109120fbcf2871f0b98c
root="$PWD/.build/test-shells"
src="$root/src"
mkdir -p "$src"
jobs="$(getconf _NPROCESSORS_ONLN)"

fetch() { # url sha
  local file="$src/${1##*/}"
  [[ -f "$file" ]] || curl --fail --location --max-time 300 "$1" -o "$file"
  echo "$2  $file" | shasum -a 256 -c - >&2
  echo "$file"
}

# Fail if any binary links a library outside the OS (e.g. Homebrew's libintl).
check_and_sign() {
  local bad
  bad="$(otool -L "$1" | tail -n +2 | awk '{print $1}' | grep -Ev '^(/usr/lib/|/System/)' || true)"
  [[ -z "$bad" ]] || { echo "$1 links non-system libraries: $bad" >&2; exit 1; }
  codesign --force --sign - "$1"
}

built() { [[ -x "$root/$1" && "$(cat "$(dirname "$root/$1")/VERSION" 2>/dev/null)" == "$2" ]]; }

build_bash() { # dir marker tarball [patches...]
  local out="$root/$1" marker="$2" tarball="$3" work="$src/$1"; shift 3
  rm -rf "$work" "$out" && mkdir -p "$work" "$out"
  tar -xzf "$tarball" -C "$work" --strip-components 1
  local patch; for patch in "$@"; do patch -d "$work" -p0 -s < "$patch"; done
  # A system-only PATH and no NLS keep Homebrew gettext/readline out of the link.
  (cd "$work" && PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    ./configure --quiet --disable-nls --without-bash-malloc --without-installed-readline \
    && PATH=/usr/bin:/bin:/usr/sbin:/sbin make -j"$jobs" -s bash) > "$work.log" 2>&1 \
    || { tail -40 "$work.log"; exit 1; }
  cp "$work/bash" "$out/bash"
  check_and_sign "$out/bash"
  echo "$marker" > "$out/VERSION"
}

marker="bash 5.2.37 $bash52_sha"
built bash-5.2/bash "$marker" || build_bash bash-5.2 "$marker" \
  "$(fetch https://ftp.gnu.org/gnu/bash/bash-5.2.37.tar.gz "$bash52_sha")"

marker="bash 5.3.$bash53_patches $bash53_sha $bash53_patches_sha"
if ! built bash-5.3/bash "$marker"; then
  patches=()
  for i in $(seq -f %03g 1 "$bash53_patches"); do
    patches+=("$src/bash53-$i")
    [[ -f "$src/bash53-$i" ]] || curl --fail --location --max-time 60 \
      "https://ftp.gnu.org/gnu/bash/bash-5.3-patches/bash53-$i" -o "$src/bash53-$i"
  done
  [[ "$(cat "${patches[@]}" | shasum -a 256)" == "$bash53_patches_sha  -" ]] || {
    echo 'bash 5.3 patches do not match the pin.' >&2; exit 1;
  }
  build_bash bash-5.3 "$marker" \
    "$(fetch https://ftp.gnu.org/gnu/bash/bash-5.3.tar.gz "$bash53_sha")" "${patches[@]}"
fi

out="$root/fish-4"
marker="fish $fish_version $fish_sha"
if ! built fish-4/fish "$marker"; then
  tarball="$(fetch "https://github.com/fish-shell/fish-shell/releases/download/$fish_version/fish-$fish_version.tar.xz" "$fish_sha")"
  work="$src/fish-$fish_version"
  rm -rf "$work" "$out" && mkdir -p "$work" "$out"
  tar -xJf "$tarball" -C "$work" --strip-components 1
  # Cargo builds embed share/ in the binary. Default features need Sphinx and msgfmt, so skip
  # them. PCRE2_SYS_STATIC vendors pcre2; a private CARGO_HOME keeps ~/.cargo untouched.
  (cd "$work" && PCRE2_SYS_STATIC=1 CARGO_HOME="$src/cargo-home" CARGO_TARGET_DIR="$src/fish-target" \
    "${CARGO:-$HOME/.cargo/bin/cargo}" build --release --locked --no-default-features --bin fish) \
    > "$work.log" 2>&1 || { tail -40 "$work.log"; exit 1; }
  cp "$src/fish-target/release/fish" "$out/fish"
  check_and_sign "$out/fish"
  echo "$marker" > "$out/VERSION"
fi

for shell in bash-5.2/bash bash-5.3/bash fish-4/fish; do
  echo "$root/$shell: $("$root/$shell" --version | head -1)"
done
