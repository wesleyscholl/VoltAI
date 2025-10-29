#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
echo "Root: $ROOT_DIR"

# Build Rust voltai
echo "Building voltai (release)..."
cd "$ROOT_DIR/.."
cargo build --release

RUST_BIN="$ROOT_DIR/../target/release/voltai"
if [ ! -x "$RUST_BIN" ]; then
  echo "voltai binary not found at $RUST_BIN"
  exit 1
fi

cd "$ROOT_DIR"

# Build mac UI
echo "Building mac UI (release)..."
swift build -c release

SWIFT_BIN=".build/release/VoltAI"
if [ ! -x "$SWIFT_BIN" ]; then
  echo "Swift executable not found at $SWIFT_BIN"
  exit 1
fi


APP_DIR="$ROOT_DIR/VoltAI.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

# Copy Swift executable as the app executable
cp "$SWIFT_BIN" "$MACOS_DIR/VoltAI"
chmod +x "$MACOS_DIR/VoltAI"

# Copy voltai binary into the app bundle
cp "$RUST_BIN" "$MACOS_DIR/voltai"
chmod +x "$MACOS_DIR/voltai"

# Verify the app executable is the Swift UI binary (not the Rust CLI). If a previous run
# accidentally overwrote the app executable with the Rust binary, detect by checksum and
# correct it automatically (or fail if we can't).
SWIFT_SHA=$(shasum -a 256 "$SWIFT_BIN" | awk '{print $1}')
RUST_SHA=$(shasum -a 256 "$RUST_BIN" | awk '{print $1}')
APP_EXEC="$MACOS_DIR/VoltAI"
APP_SHA=$(shasum -a 256 "$APP_EXEC" | awk '{print $1}') || APP_SHA=""

if [ "$APP_SHA" = "$RUST_SHA" ]; then
  echo "Detected Rust CLI in place of app executable — fixing by copying Swift executable into bundle"
  cp "$SWIFT_BIN" "$APP_EXEC"
  chmod +x "$APP_EXEC"
  APP_SHA=$(shasum -a 256 "$APP_EXEC" | awk '{print $1}') || APP_SHA=""
fi

if [ "$APP_SHA" != "$SWIFT_SHA" ]; then
  echo "ERROR: app executable checksum does not match Swift build. Expected $SWIFT_SHA, got $APP_SHA"
  echo "Please re-run the build or inspect $APP_EXEC"
  exit 1
fi

# generate iconset from Resources/AppIcon.png (if present)
# SRC="$ROOT_DIR/Resources/AppIcon.png"
# ICONSET="$ROOT_DIR/AppIcon.iconset"
# if [ -f "$SRC" ]; then
#   rm -rf "$ICONSET"
#   mkdir -p "$ICONSET"
#   sips -z 16 16   "$SRC" --out "$ICONSET/icon_16x16.png"
#   sips -z 32 32   "$SRC" --out "$ICONSET/icon_16x16@2x.png"
#   sips -z 32 32   "$SRC" --out "$ICONSET/icon_32x32.png"
#   sips -z 64 64   "$SRC" --out "$ICONSET/icon_32x32@2x.png"
#   sips -z 128 128 "$SRC" --out "$ICONSET/icon_128x128.png"
#   sips -z 256 256 "$SRC" --out "$ICONSET/icon_128x128@2x.png"
#   sips -z 256 256 "$SRC" --out "$ICONSET/icon_256x256.png"
#   sips -z 512 512 "$SRC" --out "$ICONSET/icon_256x256@2x.png"
#   sips -z 512 512 "$SRC" --out "$ICONSET/icon_512x512.png"
#   sips -z 1024 1024 "$SRC" --out "$ICONSET/icon_512x512@2x.png"
#   iconutil -c icns "$ICONSET" -o "$ROOT_DIR/Resources/AppIcon.icns"
#   cp mac-ui/AppIcon.icns mac-ui/VoltAI.app/Contents/Resources/AppIcon.icns || true
# fi

# Create a minimal Info.plist for the app
INFO_PLIST="$CONTENTS_DIR/Info.plist"
cat > "$INFO_PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>VoltAI</string>
  <key>CFBundleDisplayName</key>
  <string>VoltAI</string>
  <key>CFBundleIdentifier</key>
  <string>com.example.voltai</string>
  <key>CFBundleVersion</key>
  <string>0.1</string>
  <key>CFBundleExecutable</key>
  <string>VoltAI</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
</dict>
</plist>
PLIST

echo "App assembled at $APP_DIR"

# Open the app
open "$APP_DIR"
