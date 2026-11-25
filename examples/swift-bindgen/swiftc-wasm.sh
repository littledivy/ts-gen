#!/usr/bin/env bash
# swiftc for wasm32-unknown-wasip1 through the Swift SDK for WASI: a
# statically linked reactor module, optimized for size.
#
#   swiftc-wasm.sh --check     prints the toolchain and SDK, or exits 3 when
#                              either is missing
#   swiftc-wasm.sh <args>...   swiftc with these arguments added
#
# SWIFT_TOOLCHAIN is the toolchain's `usr` directory: by default the newest
# swift-*-RELEASE.xctoolchain under ~/Library/Developer/Toolchains, else the
# one of `swiftc` on PATH. SWIFT_SDK is the SDK's `wasm32-unknown-wasip1`
# directory: by default the one in the installed SDK bundle whose version
# matches the toolchain's (`swift sdk install`).
set -euo pipefail

toolchain() {
  if [ -n "${SWIFT_TOOLCHAIN:-}" ]; then echo "$SWIFT_TOOLCHAIN"; return; fi
  local t
  t=$(ls -d "$HOME"/Library/Developer/Toolchains/swift-*-RELEASE.xctoolchain 2>/dev/null | sort -V | tail -1)
  if [ -n "$t" ]; then echo "$t/usr"; return; fi
  # The toolchain of `swiftc` on PATH, through any proxy (swiftly's).
  t=$(swiftc -print-target-info 2>/dev/null | sed -n 's/.*"runtimeResourcePath": "\(.*\)\/lib\/swift".*/\1/p' | head -1)
  [ -n "$t" ] && echo "$t"
}

sdk() {
  if [ -n "${SWIFT_SDK:-}" ]; then echo "$SWIFT_SDK"; return; fi
  local v d
  v=$("$1/bin/swiftc" --version 2>/dev/null | sed -n 's/.*Swift version \([0-9.]*\).*/\1/p' | head -1)
  [ -n "$v" ] || return 1
  for d in "$HOME/Library/org.swift.swiftpm/swift-sdks" "$HOME/.swiftpm/swift-sdks" "${XDG_CONFIG_HOME:-$HOME/.config}/swiftpm/swift-sdks"; do
    for s in "$d"/swift-"$v"-RELEASE_wasm.artifactbundle/*/wasm32-unknown-wasip1; do
      [ -d "$s/WASI.sdk" ] && { echo "$s"; return; }
    done
  done
  return 1
}

TC=$(toolchain) || { echo "swiftc-wasm.sh: no Swift toolchain" >&2; exit 3; }
[ -x "$TC/bin/swiftc" ] || { echo "swiftc-wasm.sh: no swiftc in $TC" >&2; exit 3; }
SDK=$(sdk "$TC") || { echo "swiftc-wasm.sh: no Swift SDK for WASI matching $TC" >&2; exit 3; }

if [ "${1:-}" = --check ]; then
  echo "toolchain: $TC"
  echo "sdk: $SDK"
  exit 0
fi

exec "$TC/bin/swiftc" -target wasm32-unknown-wasip1 -sdk "$SDK/WASI.sdk" \
  -resource-dir "$SDK/swift.xctoolchain/usr/lib/swift_static" -static-stdlib \
  -Osize -wmo -parse-as-library -swift-version 5 \
  -Xclang-linker -mexec-model=reactor -Xlinker --strip-all -Xlinker --gc-sections \
  -Xlinker --export=__stack_pointer \
  "$@"
