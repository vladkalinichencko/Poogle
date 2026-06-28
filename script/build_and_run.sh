#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="Poogle"
BUNDLE_ID="com.vladislavkalinichenko.Poogle"
MIN_SYSTEM_VERSION="15.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
INSTALLED_APP="/Applications/$APP_NAME.app"
INSTALL_STAGING="/Applications/.$APP_NAME.app.installing.$$"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_FRAMEWORKS="$APP_CONTENTS/Frameworks"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ICON_SOURCE="$ROOT_DIR/Assets/poogle.icon"
LEGACY_ICON="$APP_RESOURCES/poogle.icns"
ICON_PARTIAL_PLIST="$DIST_DIR/poogle-icon-info.plist"
RESOURCE_BUNDLE="$APP_NAME"_"$APP_NAME.bundle"

stop_running_app() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
  pkill -f "embedding_worker.py" >/dev/null 2>&1 || true
}

if [[ ! -x "$ROOT_DIR/.venv/bin/python" ]]; then
  "$ROOT_DIR/script/setup_worker.sh"
fi

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.build/clang-module-cache}"
mkdir -p "$CLANG_MODULE_CACHE_PATH"

swift build --disable-sandbox
BUILD_BINARY="$(swift build --disable-sandbox --show-bin-path)/$APP_NAME"
BUILD_DIR="$(swift build --disable-sandbox --show-bin-path)"

PYTHON_BASE_PREFIX="$("$ROOT_DIR/.venv/bin/python" -c 'import sys; print(sys.base_prefix)')"
PYTHON_VERSION="$("$ROOT_DIR/.venv/bin/python" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
PYTHON_EXECUTABLE_NAME="$(basename "$(readlink "$ROOT_DIR/.venv/bin/python")")"
PYTHON_RUNTIME="$APP_RESOURCES/python-runtime"
PYTHON_LIBRARY="$APP_FRAMEWORKS/Python"
PYTHON_EXECUTABLE="$APP_RESOURCES/.venv/bin/$PYTHON_EXECUTABLE_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_FRAMEWORKS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
cp -R "$BUILD_DIR/$RESOURCE_BUNDLE" "$APP_RESOURCES/$RESOURCE_BUNDLE"
ditto "$ROOT_DIR/.venv" "$APP_RESOURCES/.venv"
mkdir -p "$PYTHON_RUNTIME/lib/python$PYTHON_VERSION"
rsync -a \
  --exclude __pycache__ \
  --exclude "config-$PYTHON_VERSION-darwin" \
  --exclude site-packages \
  --exclude test \
  "$PYTHON_BASE_PREFIX/lib/python$PYTHON_VERSION/" \
  "$PYTHON_RUNTIME/lib/python$PYTHON_VERSION/"
cp "$PYTHON_BASE_PREFIX/Python" "$PYTHON_LIBRARY"
rm -f "$PYTHON_EXECUTABLE"
cp \
  "$PYTHON_BASE_PREFIX/Resources/Python.app/Contents/MacOS/Python" \
  "$PYTHON_EXECUTABLE"
install_name_tool \
  -change "$PYTHON_BASE_PREFIX/Python" \
  "@executable_path/../../../Frameworks/Python" \
  "$PYTHON_EXECUTABLE"
test -x "$APP_RESOURCES/.venv/bin/python"

if [[ -d "$ICON_SOURCE" ]]; then
  rm -f "$ICON_PARTIAL_PLIST"
  xcrun actool \
    --compile "$APP_RESOURCES" \
    --platform macosx \
    --minimum-deployment-target "$MIN_SYSTEM_VERSION" \
    --app-icon poogle \
    --output-partial-info-plist "$ICON_PARTIAL_PLIST" \
    "$ICON_SOURCE"
  test -f "$APP_RESOURCES/Assets.car"
  test -f "$LEGACY_ICON"
elif [[ -f "$ROOT_DIR/Assets/poogle.icns" ]]; then
  cp "$ROOT_DIR/Assets/poogle.icns" "$LEGACY_ICON"
fi

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>poogle</string>
  <key>CFBundleIconName</key>
  <string>poogle</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

plutil -lint "$INFO_PLIST"
test -x "$APP_BINARY"
test -d "$APP_RESOURCES/$RESOURCE_BUNDLE"
codesign --force --sign - "$PYTHON_LIBRARY"
codesign --force --sign - "$PYTHON_EXECUTABLE"
codesign --force --deep --sign - "$APP_BUNDLE"

open_app() {
  /usr/bin/open -n "$INSTALLED_APP"
}

install_app() {
  rm -rf "$INSTALL_STAGING"
  ditto "$APP_BUNDLE" "$INSTALL_STAGING"
  rm -rf "$INSTALLED_APP"
  mv "$INSTALL_STAGING" "$INSTALLED_APP"
  test -x "$INSTALLED_APP/Contents/MacOS/$APP_NAME"
  test -f "$INSTALLED_APP/Contents/Info.plist"
  test -d "$INSTALLED_APP/Contents/Resources/$RESOURCE_BUNDLE"
}

case "$MODE" in
  build)
    ;;
  install|--install)
    install_app
    ;;
  run)
    stop_running_app
    install_app
    open_app
    ;;
  --debug|debug)
    stop_running_app
    install_app
    lldb -- "$INSTALLED_APP/Contents/MacOS/$APP_NAME"
    ;;
  --logs|logs)
    stop_running_app
    install_app
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    stop_running_app
    install_app
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    stop_running_app
    install_app
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [build|install|run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
