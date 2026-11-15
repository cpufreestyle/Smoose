#!/bin/zsh
# Smoose — 幂等发布 GitHub Release（2026-11-10 第三十四轮固化）
#
# 为什么单独有这个脚本：
#   1) scripts/release.sh 的 --github 分支走 `gh release create`，历史上 14 次 POST 全败
#      （代理环境下 gh 的 GraphQL/REST 上传不稳）；v1.4.6 实际是靠 /tmp 下一次性的
#      curl REST 脚本发成功的，那个脚本随 /tmp 清理就没了 —— 发版不可复现。
#   2) release.sh 不带 --github 会**重写已发布的 dist/Smoose-<ver>.zip** 并把
#      dist/<ver>.json 的 url 清空。发布完成后绝对不要再跑它，除非是要发新版本。
#
# 本脚本不构建、不重打包、不签名：只把 dist/ 里现成的 zip 发上去。
# 所有写操作都幂等：每次 POST / DELETE 前先 GET 现状，重试前再 GET 一次，
# 所以网络抖动导致「请求发出去了但响应没回来」时重跑不会建出重复 Release / asset。
#
# 用法（需要用户自己执行；助手不得擅自发布）：
#   ./scripts/publish.sh                         # 版本从 Resources/Info.plist 读
#   ./scripts/publish.sh --dry-run              # 只打印计划，不写任何远端
#   ./scripts/publish.sh --repo owner/name --tag v1.4.6
#   GITHUB_TOKEN=xxx ./scripts/publish.sh       # token 也可以直接给，不必装 gh
#
# 前置：
#   - dist/Smooose-<ver>.zip 已由 release.sh（不带 --github）产好并验签
#   - gh 已登录（gh auth token 可取到 token），或环境变量 GITHUB_TOKEN / GH_TOKEN
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${SMOOSE_REPO:-cpufreestyle/Smoose}"
TAG=""
DRY=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --tag) TAG="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) /bin/echo "用法: $0 [--repo owner/name] [--tag vX.Y.Z] [--dry-run]"; exit 0 ;;
    *) /bin/echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$ROOT/Resources/Info.plist")"
[ -n "$TAG" ] || TAG="v$VERSION"
ZIP="$ROOT/dist/Smoose-$VERSION.zip"
MANIFEST="$ROOT/dist/Smoose-$VERSION.json"
ASSET="Smoose-$VERSION.zip"

if [ ! -f "$ZIP" ]; then
  /bin/echo "✗ 找不到 $ZIP —— 先跑 ./scripts/release.sh（不带 --github）产包" >&2
  exit 1
fi
SHA="$(/usr/bin/shasum -a 256 "$ZIP" | /usr/bin/awk '{print $1}')"
SIZE="$(/usr/bin/stat -f%z "$ZIP")"
/bin/echo "→ 准备发布 $TAG  仓库=$REPO"
/bin/echo "  asset=$ASSET  $SIZE 字节  sha256=$SHA"

# 前置自检：顶层必须是 Smoose.app、版本必须与 Info.plist 一致、签名必须有效。
VERIFY="$(/usr/bin/mktemp -d)"
trap '/bin/rm -rf "$VERIFY"' EXIT
/usr/bin/unzip -qq "$ZIP" -d "$VERIFY"
if [ ! -d "$VERIFY/Smoose.app" ]; then
  /bin/echo "✗ zip 顶层没有 Smoose.app" >&2; exit 1
fi
PKGVER="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$VERIFY/Smoose.app/Contents/Info.plist")"
if [ "$PKGVER" != "$VERSION" ]; then
  /bin/echo "✗ 包内版本 $PKGVER 与 Info.plist 的 $VERSION 不一致" >&2; exit 1
fi
/usr/bin/codesign --verify --deep --strict "$VERIFY/Smoose.app" || {
  /bin/echo "✗ 签名校验失败" >&2; exit 1
}
/bin/echo "✓ 前置自检通过（$PKGVER / 顶层 Smoose.app / codesign --deep --strict）"

TOKEN="${GITHUB_TOKEN:-${GH_TOKEN:-}}"
if [ -z "$TOKEN" ]; then
  GH="$(command -v gh || true)"
  [ -n "$GH" ] || GH=/opt/homebrew/bin/gh
  if [ -x "$GH" ]; then TOKEN="$("$GH" auth token 2>/dev/null)" || true; fi
fi
if [ -z "$TOKEN" ] && [ "$DRY" = "0" ]; then
  /bin/echo "✗ 拿不到 GitHub token：先 gh auth login，或 export GITHUB_TOKEN=..." >&2
  exit 1
fi

API="https://api.github.com"
# -f 让 HTTP 错误变成非零退出；--retry 只重试传输层错误，业务幂等由下面的 GET 兜底。
CURL=(/usr/bin/curl -fsSL --retry 5 --retry-all-errors --connect-timeout 15)
AUTH=(-H "Authorization: Bearer $TOKEN" -H "Accept: application/vnd.github+json"
      -H "X-GitHub-Api-Version: 2022-11-28")

if [ "$DRY" = "1" ]; then
  /bin/echo "--dry-run：只做前置自检，不发布、不改 dist/*.json"
  exit 0
fi

# 1) Release：已存在就复用 id，绝不重复建。
REL="$("${CURL[@]}" "${AUTH[@]}" "$API/repos/$REPO/releases/tags/$TAG" 2>/dev/null || true)"
RID="$(/bin/echo "$REL" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)"
if [ -z "$RID" ]; then
  /bin/echo "→ 创建 Release $TAG"
  BODY="$(/usr/bin/python3 -c 'import json,sys; print(json.dumps({"tag_name":sys.argv[1],"name":sys.argv[1],"body":"安装包 sha256: `"+sys.argv[2]+"`","draft":False,"prerelease":False}))' "$TAG" "$SHA")"
  "${CURL[@]}" "${AUTH[@]}" -X POST -H "Content-Type: application/json" -d "$BODY" \
    "$API/repos/$REPO/releases" > /dev/null
  # POST 可能成功但响应丢了，重跑前必须先 GET 确认，不能盲目再 POST。
  REL="$("${CURL[@]}" "${AUTH[@]}" "$API/repos/$REPO/releases/tags/$TAG")"
  RID="$(/bin/echo "$REL" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
else
  /bin/echo "→ Release $TAG 已存在（id=$RID），复用"
fi
[ -n "$RID" ] || { /bin/echo "✗ 拿不到 Release id" >&2; exit 1; }

# 2) asset：同名已存在且 sha 一致就跳过；不一致先删再传。
EXIST="$("${CURL[@]}" "${AUTH[@]}" "$API/repos/$REPO/releases/$RID/assets")"
AID="$(/bin/echo "$EXIST" | /usr/bin/python3 -c '
import json,sys
for a in json.load(sys.stdin):
    if a["name"] == sys.argv[1]: print(a["id"]); break
' "$ASSET" 2>/dev/null || true)"
if [ -n "$AID" ]; then
  # GitHub 刚上传完可能还没算出 digest：只认「digest 一致」，其次认「digest 为空但大小一致」，
  # 两者都不满足才判定内容不同、删掉重传，避免无谓重复上传。
  OLD="$(/bin/echo "$EXIST" | /usr/bin/python3 -c '
import json,sys
want = sys.argv[1]
for a in json.load(sys.stdin):
    if a["name"] == want:
        print("%s|%s" % (a.get("digest") or "", a.get("size") or 0)); break
' "$ASSET" 2>/dev/null || true)"
  OLD_DIGEST="${OLD%%|*}"
  OLD_SIZE="${OLD##*|}"
  if [ "$OLD_DIGEST" = "sha256:$SHA" ] || [ -z "$OLD_DIGEST" -a "$OLD_SIZE" = "$SIZE" ]; then
    /bin/echo "→ 同名 asset 已存在且内容一致（${OLD_DIGEST:-digest 待生成 / size=$OLD_SIZE}），跳过上传"
  else
    /bin/echo "→ 同名 asset 内容不同（${OLD_DIGEST:-无 digest} / size=$OLD_SIZE），先删再传"
    "${CURL[@]}" "${AUTH[@]}" -X DELETE "$API/repos/$REPO/releases/assets/$AID" > /dev/null
    AID=""
  fi
fi
if [ -z "$AID" ]; then
  /bin/echo "→ 上传 asset 到 uploads.github.com"
  "${CURL[@]}" "${AUTH[@]}" -X POST -H "Content-Type: application/zip" \
    --data-binary @"$ZIP" \
    "https://uploads.github.com/repos/$REPO/releases/$RID/assets?name=$ASSET" > /dev/null
fi

# 3) 闭环：以 GET /releases/latest 为准，逐项核对 tag / asset / digest / 大小。
LATEST="$("${CURL[@]}" "${AUTH[@]}" "$API/repos/$REPO/releases/latest")"
/bin/echo "$LATEST" | /usr/bin/python3 -c '
import json,sys
d = json.load(sys.stdin)
want_tag, want_name, want_sha, want_size = sys.argv[1:5]
a = next((x for x in d.get("assets",[]) if x["name"] == want_name), None)
assert d.get("tag_name") == want_tag, "latest 还是 " + str(d.get("tag_name"))
assert a is not None, "latest 里没有 " + want_name
assert (a.get("digest") or "") == "sha256:" + want_sha, "digest 不一致: " + str(a.get("digest"))
assert a.get("size") == int(want_size), "size 不一致: " + str(a.get("size"))
print("✓ 线上校验：tag=%s  asset=%s  digest=sha256:%s  size=%s" % (want_tag, want_name, want_sha, want_size))
' "$TAG" "$ASSET" "$SHA" "$SIZE"

# 4) 回填自建版本源 JSON（sha256 与真实下载地址），供用户自托管后启用校验。
#    注意：官方 GitHub 源现在也能从 assets[].digest 直接拿到 sha256（UpdateModel 已支持）。
if [ -f "$MANIFEST" ]; then
  /usr/bin/python3 - "$MANIFEST" "$SHA" "https://github.com/$REPO/releases/download/$TAG/$ASSET" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1])
d = json.loads(p.read_text())
d["url"] = sys.argv[3]
d["sha256"] = sys.argv[2]
p.write_text(json.dumps(d, ensure_ascii=False, indent=2) + "\n")
PY
  /bin/echo "✓ 已回填 $MANIFEST（url + sha256）"
fi

/bin/echo "✓ 发布完成：https://github.com/$REPO/releases/tag/$TAG"
/bin/echo "⚠️ 发布后不要再跑 ./scripts/release.sh 重打这个版本的包（会清空 manifest url 并换掉已发布字节）"
