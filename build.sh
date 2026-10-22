#!/bin/zsh
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
NAME="Smoose"
BUILD="$ROOT/build"
APP="$BUILD/$NAME.app"
SDK="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
SWIFTC="$(/usr/bin/xcrun --sdk macosx --find swiftc)"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

/bin/echo "→ compiling"
"$SWIFTC" -O \
  -target arm64-apple-macos14.0 \
  -sdk "$SDK" \
  -o "$APP/Contents/MacOS/$NAME" \
  "$ROOT"/Sources/Model.swift \
  "$ROOT"/Sources/Actions.swift \
  "$ROOT"/Sources/ScrollAxis.swift \
  "$ROOT"/Sources/PointerController.swift \
  "$ROOT"/Sources/ScrollEngine.swift \
  "$ROOT"/Sources/UpdateModel.swift \
  "$ROOT"/Sources/Updater.swift \
  "$ROOT"/Sources/Views.swift \
  "$ROOT"/Sources/App.swift \
  "$ROOT"/Sources/CursorZoom.swift \
  "$ROOT"/Sources/main.swift

cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
# 用本机 Apple Development 证书签名，DR 绑定证书而非 cdhash，
# 这样重新编译后 TCC 的辅助功能授权不会失效（ad-hoc 签名每次 cdhash 都会变）。
/usr/bin/codesign --force --sign "Apple Development: qm0819@hotmail.com (5F66DDWD6H)" --timestamp=none "$APP" >/dev/null || /usr/bin/codesign --force --sign - --timestamp=none "$APP" >/dev/null
/bin/echo "→ built: $APP"
