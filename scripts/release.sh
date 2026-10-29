#!/bin/zsh
# Smoose 发布脚本 —— 自动更新的安装包产出端。
#
# 用法：
#   ./scripts/release.sh            # 只在本地产出 dist/Smoose-<version>.zip
#   ./scripts/release.sh --github   # 额外建 GitHub Release 并把 zip 作为 asset 上传
#   ./scripts/release.sh --github --repo owner/name   # 显式指定仓库（本项目没有 git remote，
#                                       靠 git remote 推导不出仓库名，必须显式给）
#
# 为什么必须有这个脚本：Updater.swift 的安装失败文案让用户「用 ./release.sh
# 打个 zip」，而在脚本存在之前那句话是空的 —— 自动更新链路只有消费端没有产出端。
# Updater 对安装包有三个硬要求，这个脚本逐个保证：
#   1. zip 顶层必须是 Smoose.app（findApp 只认最外层，嵌套的会被忽略）
#   2. bundle id 必须是 app.smoose.macos（安装前校验，不匹配直接中止）
#   3. zip 必须真的能解出可运行的 App（打完后本地自检一遍再算成功）
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# gh 不保证在 /usr/bin：Homebrew 装在 /opt/homebrew/bin，MacPorts 在 /opt/local/bin。
# 早前硬编码 /usr/bin/gh，在装了 Homebrew gh 的机器上直接
# "no such file or directory: /usr/bin/gh"（2026-10-22 实测）。
# 从 PATH 找，找不到再退回几个常见位置，最后给明确错误。
GH="$(command -v gh || true)"
if [ -z "$GH" ]; then
  for c in /opt/homebrew/bin/gh /usr/local/bin/gh /opt/local/bin/gh; do
    if [ -x "$c" ]; then GH="$c"; break; fi
  done
fi
NAME="Smoose"
APP="$ROOT/build/$NAME.app"
DIST="$ROOT/dist"
UPLOAD=0
REPO_FLAG=""
# 一次遍历解析全部参数。早前的实现有两处真 bug：
#   1. "--repo" 分支是空的，value 原样留在 "$@" 里，落到 *) 上 exit 2
#      —— 文档写的 --repo owner/name 用法从来没真正能用过（2026-10-22 实测）；
#   2. 事后补救用的 for 循环只处理 "--repo value"，不认 "--repo=value"。
# 现在两种写法都支持，且 value 缺失时给明确错误而不是静默用默认源。
while [ $# -gt 0 ]; do
  case "$1" in
    --github) UPLOAD=1; shift ;;
    --repo)
      if [ $# -lt 2 ]; then /bin/echo "✗ --repo 需要一个值：--repo owner/name" >&2; exit 2; fi
      REPO_FLAG="$2"; shift 2 ;;
    --repo=*) REPO_FLAG="${1#--repo=}"; shift ;;
    -h|--help) /bin/echo "用法: $0 [--github] [--repo owner/name]"; exit 0 ;;
    *) /bin/echo "未知参数: $1（只支持 --github / --repo owner/name）" >&2; exit 2 ;;
  esac
done


# 1. 构建（签名用 build.sh 里那把 Apple Development 证书，DR 绑定，
#    这样用户升级后 TCC 辅助功能授权不会失效）
"$ROOT/build.sh"

# 2. 版本号从构建产物读，避免源码里再维护一份
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$APP/Contents/Info.plist")"
BID="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$APP/Contents/Info.plist")"
if [ "$BID" != "app.smoose.macos" ]; then
  /bin/echo "✗ bundle id 是 $BID 而不是 app.smoose.macos，自动更新会拒绝安装" >&2
  exit 1
fi
/bin/echo "→ 版本 $VERSION（$BID）"

# 3. 打包。用 -y 保留符号链接，否则 App 里的软链会变成实体文件，签名失效。
/bin/mkdir -p "$DIST"
ZIP="$DIST/$NAME-$VERSION.zip"
/bin/rm -f "$ZIP"
(cd "$ROOT/build" && /usr/bin/zip -qry "$ZIP" "$NAME.app")

# 4. 自检：解到干净目录，确认顶层就是 Smoose.app 且 bundle id 对得上。
#    这一步是给发布者看的 —— 用户那头看到的是 Updater 的报错文案，
#    在那之前先在这里拦住，比让用户下载一个装不上的包好。
CHECK="$DIST/.check"
/bin/rm -rf "$CHECK"; /bin/mkdir -p "$CHECK"
/usr/bin/unzip -qq "$ZIP" -d "$CHECK"
if [ ! -d "$CHECK/$NAME.app" ]; then
  /bin/echo "✗ zip 顶层不是 $NAME.app（实际：$(/bin/ls "$CHECK")）" >&2
  exit 1
fi
CBID="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$CHECK/$NAME.app/Contents/Info.plist" 2>/dev/null || /bin/echo "")"
if [ "$CBID" != "app.smoose.macos" ]; then
  /bin/echo "✗ zip 里的 bundle id 是「$CBID」" >&2
  exit 1
fi
if ! /usr/bin/codesign --verify --deep "$CHECK/$NAME.app" 2>/dev/null; then
  /bin/echo "✗ zip 里的 App 签名校验失败（zip -r 少了 -y？）" >&2
  exit 1
fi
# 光有 codesign --verify 不够：ad-hoc 签名也能过完整性校验，但拿不到 TeamIdentifier，
# 而用户端的 Updater 正是靠 TeamIdentifier 判断「这是不是官方发的包」。
# 少了这一步，打出来的就是一个用户永远装不上的包（2026-10-26）。
TEAM="$(/usr/bin/codesign --display --verbose=4 "$CHECK/$NAME.app" 2>&1 \
  | /usr/bin/awk -F= '/TeamIdentifier=/{print $2; exit}')"
if [ -z "$TEAM" ] || [ "$TEAM" = "not set" ]; then
  /bin/echo "✗ 打出的 App 是 ad-hoc 签名（没有 TeamIdentifier），用户端会被签名校验拒绝安装" >&2
  /bin/echo "  先设置签名身份再重打：export SMOOSE_SIGN_ID=\"Apple Development: 你的名字 (TEAMID)\"" >&2
  exit 1
fi
/bin/rm -rf "$CHECK"

SHA="$(/usr/bin/shasum -a 256 "$ZIP" | /usr/bin/awk '{print $1}')"
SIZE="$(/usr/bin/stat -f%z "$ZIP")"
/bin/echo "✓ $ZIP"
/bin/echo "  大小 $SIZE 字节  sha256 $SHA"

# 5. 可选：发 GitHub Release。默认版本源就是这个仓库的 latest release，
#    所以这一步做完用户的自动更新才真的能收到东西。
if [ "$UPLOAD" = "1" ]; then
  # 优先用显式 --repo；本项目没有 git remote 也没有 .git，靠 remote 推导必然失败，
  # 而 gh repo view 需要 cwd 在某个仓库里 —— 两条路都不可靠，所以显式指定是主路径。
  REPO="$REPO_FLAG"
  if [ -z "$REPO" ]; then
    # 刻意不用 sed -E 抽仓库名：BSD sed 不支持惰性量词 [^/]+?，
    # 那条正则是 PCRE 写法，一旦真的配上 git remote 就会 RE error 崩掉（2026-10-22 实测）。
    # 用 shell 切分：兼容 https://github.com/owner/repo(.git) 和 git@github.com:owner/repo(.git)。
    REMOTE="$(/usr/bin/git -C "$ROOT" remote get-url origin 2>/dev/null || /bin/echo "")"
    if [ -n "$REMOTE" ]; then
      HOSTPATH="${REMOTE#*github.com}"
      HOSTPATH="${HOSTPATH#:}"
      HOSTPATH="${HOSTPATH#/}"
      HOSTPATH="${HOSTPATH%.git}"
      case "$HOSTPATH" in
        */*) REPO="$HOSTPATH" ;;
      esac
    fi
  fi
  if [ -z "$REPO" ]; then
    REPO="$("$GH" repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || /bin/echo "")"
  fi
  if [ -z "$REPO" ] || ! /bin/echo "$REPO" | /usr/bin/grep -Eq '^[^/]+/[^/]+$'; then
    /bin/echo "✗ 无法确定 GitHub 仓库。请显式指定：--repo owner/name" >&2
    /bin/echo "  （本项目没有 git remote，也没有 .git 目录，自动推导不出仓库名）" >&2
    exit 1
  fi
  TAG="v$VERSION"
  /bin/echo "→ 发 Release $TAG 到 $REPO"
  if ! "$GH" release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    # sha256 写进 Release notes：GitHub API 的 asset 元数据里没有校验和字段，
    # 自动更新走 JSON 版本源能拿到，手动下载的用户只能靠这里自行核对
    "$GH" release create "$TAG" --repo "$REPO" --title "$NAME $VERSION" \
      --generate-notes --notes "安装包 sha256: \`$SHA\`"
  fi
  "$GH" release upload "$TAG" "$ZIP" --repo "$REPO" --clobber
  /bin/echo "✓ https://github.com/$REPO/releases/tag/$TAG"
fi

# 6. 产出可直接自托管的版本源 JSON（带 sha256）。
#    GitHub Releases API 的 asset 里没有校验和字段，所以 sha256 只能靠自建版本源传递；
#    Updater 只在 manifest 里读到 sha256 时才校验，读不到就跳过 —— 不影响已有流程。
MANIFEST="$DIST/$NAME-$VERSION.json"
if [ "$UPLOAD" = "1" ] && [ -n "${REPO:-}" ]; then
  DLURL="https://github.com/$REPO/releases/download/v$VERSION/$NAME-$VERSION.zip"
else
  DLURL=""
fi
/bin/cat > "$MANIFEST" <<JSON
{
  "version": "$VERSION",
  "url": "$DLURL",
  "sha256": "$SHA",
  "minSystem": "14.0",
  "notes": "$NAME $VERSION"
}
JSON
/bin/echo "✓ $MANIFEST"
/bin/echo "  url 为空表示还没上传；填好后把这个 JSON 传到任意 https 静态托管，"
/bin/echo "  再把地址填进「关于 → 自动更新 → 版本源」，即可启用 sha256 校验"
