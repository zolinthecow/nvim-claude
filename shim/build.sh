#!/bin/bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

echo "[shim] Building arm64 slice..."
cargo build --target aarch64-apple-darwin --release

echo "[shim] Building arm64e slice (nightly, build-std)..."
cargo +nightly build \
  -Z build-std \
  --target arm64e-apple-darwin \
  --release

UNIVERSAL_DIR="target/universal/release"
mkdir -p "$UNIVERSAL_DIR"

echo "[shim] Creating universal dylib..."
lipo -create \
  target/aarch64-apple-darwin/release/libnvimclaude_shim.dylib \
  target/arm64e-apple-darwin/release/libnvimclaude_shim.dylib \
  -output "$UNIVERSAL_DIR/libnvimclaude_shim.dylib"

codesign -s - -v "$UNIVERSAL_DIR/libnvimclaude_shim.dylib" >/dev/null
echo "[shim] Universal build written to $UNIVERSAL_DIR/libnvimclaude_shim.dylib"
