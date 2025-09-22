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


APP_DIR="$ROOT_DIR/BoltAIMacUI.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# Copy Swift executable as the app executable
cp "$SWIFT_BIN" "$MACOS_DIR/BoltAIMacUI"
chmod +x "$MACOS_DIR/BoltAIMacUI"

# Copy boltai binary into the app bundle
cp "$RUST_BIN" "$MACOS_DIR/boltai"
chmod +x "$MACOS_DIR/boltai"

# Ensure an AppIcon exists (1x1 PNG placeholder) - decode from embedded base64 if missing
ICON_PATH="$RESOURCES_DIR/AppIcon.png"
if [ ! -f "$ICON_PATH" ]; then
  echo "Creating placeholder AppIcon.png"
  cat > "$ICON_PATH" <<'PNGBASE64'
iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8Xw8AAn4B9xqVQYAAAAASUVORK5CYII=
PNGBASE64
  base64 --decode "$ICON_PATH" > "$ICON_PATH.tmp" || (cat "$ICON_PATH" | base64 --decode > "$ICON_PATH.tmp")
  mv "$ICON_PATH.tmp" "$ICON_PATH"
fi

# Create a minimal Info.plist for the app
INFO_PLIST="$CONTENTS_DIR/Info.plist"
cat > "$INFO_PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>BoltAIMacUI</string>
  <key>CFBundleDisplayName</key>
  <string>BoltAI</string>
  <key>CFBundleIdentifier</key>
  <string>com.example.boltai</string>
  <key>CFBundleVersion</key>
  <string>0.1</string>
  <key>CFBundleExecutable</key>
  <string>BoltAIMacUI</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon.png</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
</dict>
</plist>
PLIST

echo "App assembled at $APP_DIR"

# Open the app
open "$APP_DIR"
