#!/usr/bin/env bash
set -euo pipefail
RUST_SCRIPT_DIRECTORY="$(cd "$(dirname "$0")" && pwd)"
RUST_PROJECT_DIRECTORY="$(cd "$RUST_SCRIPT_DIRECTORY/.." && pwd)"
RUST_ARCHITECTURES="${1:-native}"
RUST_TARGET_DIRECTORY="$RUST_PROJECT_DIRECTORY/.build/rust"
RUST_LIBRARY_DIRECTORY="$RUST_PROJECT_DIRECTORY/.build/rust/lib"
mkdir -p "$RUST_LIBRARY_DIRECTORY"
# Release artifacts use one pinned lockfile and bounded native parsers. No Rust dylib is shipped.
if [[ "$RUST_ARCHITECTURES" == "universal" ]]; then
  for RUST_TARGET in aarch64-apple-darwin x86_64-apple-darwin; do
    if ! rustup target list --installed | /usr/bin/grep -qx "$RUST_TARGET"; then
      echo "Install the Rust target first: rustup target add $RUST_TARGET" >&2; exit 1
    fi
    MACOSX_DEPLOYMENT_TARGET=14.0 cargo build --manifest-path "$RUST_PROJECT_DIRECTORY/Engine/almeng-core/Cargo.toml" \
      --locked --release --target-dir "$RUST_TARGET_DIRECTORY" --target "$RUST_TARGET"
  done
  lipo -create "$RUST_TARGET_DIRECTORY/aarch64-apple-darwin/release/libalmeng_core.a" \
    "$RUST_TARGET_DIRECTORY/x86_64-apple-darwin/release/libalmeng_core.a" \
    -output "$RUST_LIBRARY_DIRECTORY/libalmeng_core.a"
else
  MACOSX_DEPLOYMENT_TARGET=14.0 cargo build --manifest-path "$RUST_PROJECT_DIRECTORY/Engine/almeng-core/Cargo.toml" \
    --locked --release --target-dir "$RUST_TARGET_DIRECTORY"
  cp "$RUST_TARGET_DIRECTORY/release/libalmeng_core.a" "$RUST_LIBRARY_DIRECTORY/libalmeng_core.a"
fi
