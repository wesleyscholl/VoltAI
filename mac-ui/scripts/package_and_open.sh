#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
echo "Root: $ROOT_DIR"

# Build Rust boltai
echo "Building boltai (release)..."
cd "$ROOT_DIR/.."
cargo build --release

RUST_BIN="$ROOT_DIR/../target/release/boltai"
if [ ! -x "$RUST_BIN" ]; then
  echo "boltai binary not found at $RUST_BIN"
  exit 1
fi

cd "$ROOT_DIR"

# Build mac UI
echo "Building mac UI (release)..."
swift build -c release

SWIFT_BIN=".build/release/BoltAI"
if [ ! -x "$SWIFT_BIN" ]; then
  echo "Swift executable not found at $SWIFT_BIN"
  exit 1
fi

APP_DIR="$ROOT_DIR/BoltAI.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
mkdir -p "$MACOS_DIR"

# Copy Swift executable as the app executable
cp "$SWIFT_BIN" "$MACOS_DIR/BoltAI"
chmod +x "$MACOS_DIR/BoltAI"

# Copy boltai binary into the app bundle
cp "$RUST_BIN" "$MACOS_DIR/boltai"
chmod +x "$MACOS_DIR/boltai"

echo "App assembled at $APP_DIR"

# Open the app
open "$APP_DIR"
