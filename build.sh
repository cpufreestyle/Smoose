#!/bin/zsh
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
NAME="Smoose"
BUILD="$ROOT/build"
APP="$BUILD/$NAME.app"
SDK="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
SWIFTC="$(/usr/bin/xcrun --sdk macosx --find swiftc)"
# 受限环境（CI / agent 沙箱）里 Swift 宏插件服务器起不来（它自己要套 sandbox，
# 外层已禁嵌套 sandbox_apply），表现为 SwiftUIMacros... malformed response。
# 这种环境里用 SMOOSE_SWIFT_EXTRA=-disable-sandbox ./build.sh。普通终端留空即可。
: "${SMOOSE_SWIFT_EXTRA:=}"

rm -rf "$BUILD"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

/bin/echo "→ compiling"
"$SWIFTC" $SMOOSE_SWIFT_EXTRA -O \
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
# 用 Apple Development 证书签名，DR 绑定证书而非 cdhash，
# 这样重新编译后 TCC 的辅助功能授权不会失效（ad-hoc 签名每次 cdhash 都会变）。
# 签名身份走环境变量，不写死个人证书 —— 换机器 / 换账号时只 export 一下即可，
# 否则必然签名失败并静默回落到 ad-hoc，于是授权又失效（2026-10-26 修）。
#   export SMOOSE_SIGN_ID="Apple Development: you@example.com (TEAMID)"
# 签名身份三级回退：
#   1. 环境变量 SMOOSE_SIGN_ID（fork / 换机器时显式指定）
#   2. 自动探测本机钥匙串里的 Apple Development 证书
#   3. ad-hoc（会警告：辅助功能授权每次重新编译都失效）
# 早先这里写死个人证书名，后来改成只认环境变量 —— 但那样默认路径直接坏掉：
# 不 export 就产出 ad-hoc 包，release.sh 的 TeamIdentifier 自检必然失败，
# 跑一次 harness 都要先手动设变量（2026-10-26 实测）。所以补上自动探测。
SIGN_ID="${SMOOSE_SIGN_ID:-}"
if [ -z "$SIGN_ID" ]; then
  SIGN_ID="$(/usr/bin/security find-identity -v -p codesigning 2>/dev/null \
    | /usr/bin/awk -F'"' '/Apple Development/{print $2; exit}')"
  [ -n "$SIGN_ID" ] && /bin/echo "→ 自动选用签名身份：$SIGN_ID"
fi
if [ -n "$SIGN_ID" ]; then
  if /usr/bin/codesign --force --sign "$SIGN_ID" --timestamp=none "$APP" >/dev/null 2>&1; then
    /bin/echo "→ signed: $SIGN_ID"
  else
    /bin/echo "⚠️ 用 '$SIGN_ID' 签名失败，回落 ad-hoc（辅助功能授权会失效）" >&2
    /usr/bin/codesign --force --sign - --timestamp=none "$APP" >/dev/null
  fi
else
  /bin/echo "⚠️ 钥匙串里没有 Apple Development 证书，也没设 SMOOSE_SIGN_ID，使用 ad-hoc 签名" >&2
  /bin/echo "   辅助功能授权会在每次重新编译后失效；发布也会被 TeamIdentifier 自检拒绝" >&2
  /usr/bin/codesign --force --sign - --timestamp=none "$APP" >/dev/null
fi
/bin/echo "→ built: $APP"
