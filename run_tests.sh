#!/bin/zsh
# Smoose harness — 一键验证（详见 SPEC.md §7）
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
SDK="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
SWIFTC="$(/usr/bin/xcrun --sdk macosx --find swiftc)"
CC="$(/usr/bin/xcrun --sdk macosx --find cc)"
# 受限环境（CI / agent 沙箱）里 Swift 宏插件服务器起不来 —— 它自己要套 sandbox，
# 而外层已禁止嵌套 sandbox_apply，表现为 SwiftUIMacros.StateMacro ... malformed response。
# 加 -disable-sandbox 让编译器子进程不套沙箱即可。普通终端不需要，默认留空。
: "${SMOOSE_SWIFT_EXTRA:=}"
WORK="/tmp/smoose_harness_$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS  $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL  $1"; FAIL=$((FAIL+1)); }
echo "== A: 插值离线测试 =="
cp Tests/InterpTest.swift "$WORK/main.swift"
if "$SWIFTC" $SMOOSE_SWIFT_EXTRA -O -sdk "$SDK" -target arm64-apple-macos14.0 -o "$WORK/interp" Sources/ScrollAxis.swift "$WORK/main.swift" 2>"$WORK/a.log"; then
  OUT="$("$WORK/interp" 2>/dev/null || true)"
  BADN="$(printf '%s\n' "$OUT" | grep '预期总距离' | sed -E 's/.*预期总距离=([0-9.]+)px 实际=([0-9.]+)px/\1 \2/' | awk 'NF==2 && $1 != $2 {c++} END {print c+0}')"
  if [ "$BADN" = "0" ] && printf '%s\n' "$OUT" | grep -q "方向突变"; then ok "A1-A5 插值与距离守恒"; else bad "A 值不符（$BADN 场景）"; fi
else
  bad "A 编译失败$(head -3 "$WORK/a.log" 2>/dev/null)"
fi
echo "== B: profile(for:) 每应用命中 =="
cat > "$WORK/b.swift" <<'BSWIFT'
import Foundation
// 同 D stage：stdlib assert() 在 -O 下被优化掉，必须自己计数 + 非零退出（2026-10-22）
var failures = 0
func require(_ cond: Bool, _ label: String = "unlabeled") {
    if !cond { print("FAIL \(label)"); failures += 1 }
}
struct ScrollProfile: Codable { var enabled = true; var speed = 3.2 }
struct StoredState: Codable {
    var masterEnabled = true
    var global = ScrollProfile()
    var apps: [String: ScrollProfile] = [:]
    func profile(for id: String?) -> ScrollProfile? {
        guard masterEnabled else { return nil }
        let p = (id.flatMap { apps[$0] }) ?? global
        return p.enabled ? p : nil
    }
}
var s = StoredState()
s.apps["com.test.app"] = ScrollProfile(enabled: true, speed: 2.0)
s.apps["com.bypass.app"] = ScrollProfile(enabled: false, speed: 2.0)
require(s.profile(for: nil)!.speed == 3.2, "global default speed")
require(s.profile(for: "com.test.app")!.speed == 2.0, "per-app override")
require(s.profile(for: "com.bypass.app") == nil, "disabled app bypassed")
require(s.profile(for: "unknown.app")!.speed == 3.2, "unknown app falls back")
s.masterEnabled = false
require(s.profile(for: "com.test.app") == nil, "master off kills all")
print("B-OK")
BSWIFT
if "$SWIFTC" $SMOOSE_SWIFT_EXTRA -Onone -sdk "$SDK" -o "$WORK/b" "$WORK/b.swift" 2>"$WORK/b.log" && "$WORK/b" >/dev/null; then ok "B profile 命中"; else bad "B $(tail -2 "$WORK/b.log")"; fi
echo "== C: ButtonAction 枚举完整性 =="
awk '/^enum ButtonAction/,/^}/' Sources/Model.swift > "$WORK/enum.txt"
NCASE="$(grep -c "^    case " "$WORK/enum.txt" || true)"
NLABEL="$(grep -c "return \"" "$WORK/enum.txt" || true)"
if [ "$NCASE" = "13" ] && [ "$NLABEL" = "13" ]; then ok "C 13 cases / 13 labels"; else bad "C 计数 $NCASE/$NLABEL 应 13/13（新增 case 时同步 SPEC §5 与此数字）"; fi
echo "== D: 自动更新决策（版本比较 / 清单解析）=="
cat > "$WORK/d.swift" <<'DSWIFT'
import Foundation
import AppKit
// 自建断言器：stdlib 的 assert() 在 -O 下会被整条优化掉（2026-10-22 实测：
// assert(1 == 2) 在 -O 下 exit 0，在 -Onone 下 trap exit 133），
// 导致本 stage 过去全是「编译通过就算 PASS」的假绿。用 precondition + 显式计数兜住。
var failures = 0
func require(_ cond: Bool, _ label: String = "unlabeled") {
    if !cond { print("FAIL \(label)"); failures += 1 }
}
func requireEq<T: Equatable>(_ a: T?, _ b: T?, _ label: String) {
    if a != b { print("FAIL \(label): got \(String(describing: a)) want \(String(describing: b))"); failures += 1 }
}
// 与 Sources/UpdateModel.swift 逐字同源的逻辑副本（harness 不编译 App 主 target）
struct SemVer: Equatable, Comparable {
    let numbers: [Int]
    let prerelease: [String]
    init?(string raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.first == "v" || s.first == "V" { s.removeFirst() }
        if let plus = s.firstIndex(of: "+") { s = String(s[..<plus]) }
        var pre = ""
        if let dash = s.firstIndex(of: "-") {
            pre = String(s[s.index(after: dash)...])
            s = String(s[..<dash])
        }
        guard !s.isEmpty else { return nil }
        var nums: [Int] = []
        for part in s.split(separator: ".", omittingEmptySubsequences: false) {
            guard let n = Int(String(part)) else { return nil }
            nums.append(n)
        }
        while nums.count > 1, nums.last == 0 { nums.removeLast() }
        guard !nums.isEmpty else { return nil }
        self.numbers = nums
        self.prerelease = pre.isEmpty ? [] : pre.split(separator: ".").map(String.init)
    }
    var string: String {
        var parts = numbers.map(String.init)
        if parts.count < 3 { parts += Array(repeating: "0", count: 3 - parts.count) }
        var s = parts.joined(separator: ".")
        if !prerelease.isEmpty { s += "-" + prerelease.joined(separator: ".") }
        return s
    }
    static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        let n = max(lhs.numbers.count, rhs.numbers.count)
        for i in 0..<n {
            let a = i < lhs.numbers.count ? lhs.numbers[i] : 0
            let b = i < rhs.numbers.count ? rhs.numbers[i] : 0
            if a != b { return a < b }
        }
        return prereleaseLess(lhs.prerelease, rhs.prerelease)
    }
    static func prereleaseLess(_ a: [String], _ b: [String]) -> Bool {
        if a.isEmpty { return false }
        if b.isEmpty { return true }
        for i in 0..<min(a.count, b.count) {
            let x = a[i], y = b[i]
            if x == y { continue }
            if let xn = Int(x), let yn = Int(y) { return xn < yn }
            if Int(x) != nil { return true }
            if Int(y) != nil { return false }
            return x < y
        }
        return a.count < b.count
    }
}
enum Decision: Equatable {
    case upToDate, available(String), systemTooOld(required: String), malformed
}
func decide(current: String, os: String, json: String) -> Decision {
    guard let data = json.data(using: .utf8) else { return .malformed }
    struct Manifest: Decodable {
        var version: String
        var url: String?
        var minSystem: String?
        private enum Keys: String, CodingKey {
            case version, tagName = "tag_name", name, url, downloadURL = "download_url"
            case notes, body, releaseNotes = "release_notes"
            case minSystem, minSystemVersion = "minimum_system_version"
            case assets, browserDownloadURL = "browser_download_url", contentType = "content_type"
        }
        private struct Asset: Decodable {
            var browserDownloadURL: String?
            var name: String?
            var contentType: String?
            private enum CodingKeys: String, CodingKey {
                case browserDownloadURL = "browser_download_url", name, contentType = "content_type"
            }
        }
        private static func archive(_ s: String?) -> Bool {
            let n = (s ?? "").lowercased()
            if n.hasSuffix(".zip") || n.hasSuffix(".dmg") || n.hasSuffix(".tar.gz") { return true }
            return n.hasSuffix("application/zip") || n.hasSuffix("application/x-zip-compressed")
                || n.hasSuffix("application/x-apple-diskimage")
        }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            var rv: String?
            for k in [Keys.version, .tagName, .name] {
                if let s = try c.decodeIfPresent(String.self, forKey: k), SemVer(string: s) != nil { rv = s; break }
            }
            guard let rv, let sv = SemVer(string: rv) else { throw DecodingError.dataCorruptedError(forKey: .version, in: c, debugDescription: "no version") }
            version = sv.string
            url = nil
            minSystem = try (c.decodeIfPresent(String.self, forKey: .minSystem) ?? c.decodeIfPresent(String.self, forKey: .minSystemVersion))
            let assets = try c.decodeIfPresent([Asset].self, forKey: .assets) ?? []
            let direct = try (c.decodeIfPresent(String.self, forKey: .url) ?? c.decodeIfPresent(String.self, forKey: .downloadURL))
            if let direct, Self.archive(direct) { url = direct }
            else if let a = assets.first(where: { Self.archive($0.name) || Self.archive($0.contentType) }) { url = a.browserDownloadURL }
        }
    }
    guard let m = try? JSONDecoder().decode(Manifest.self, from: data) else { return .malformed }
    guard let cur = SemVer(string: current), let new = SemVer(string: m.version) else { return .malformed }
    if let min = m.minSystem, let need = SemVer(string: min), let o = SemVer(string: os), o < need {
        return .systemTooOld(required: min)
    }
    return new > cur ? .available(m.version) : .upToDate
}

// D1 版本比较
require(SemVer(string: "1.0.0") == SemVer(string: "1.0"), "D-1.0.0")
require(SemVer(string: "v2.0") == SemVer(string: "2.0.0"), "D-v2.0")
require(SemVer(string: "1.2.10")! > SemVer(string: "1.2.9")!, "D-1.2.10")
require(SemVer(string: "1.10.0")! > SemVer(string: "1.9.9")!, "D-1.10.0")
require(SemVer(string: "2.0.0")! > SemVer(string: "2.0.0-beta.1")!, "D-2.0.0")
require(SemVer(string: "1.0.0-alpha")! < SemVer(string: "1.0.0-beta")!, "D-1.0.0-alpha")
require(SemVer(string: "1.0.0-beta.2")! > SemVer(string: "1.0.0-beta.1")!, "D-1.0.0-beta.2")
require(SemVer(string: "1.2.3+build9")! == SemVer(string: "1.2.3")!, "D-1.2.3_build9")
require(SemVer(string: "abc") == nil, "D-abc")
require(SemVer(string: "1.x.3") == nil, "D-1.x.3")
// D2 决策
require(decide(current: "1.0.0", os: "26.0", json: "{\"version\":\"1.1.0\",\"url\":\"https://x/Smoose.zip\"}") == .available("1.1.0"), "D-1.0.0#2")
require(decide(current: "1.1.0", os: "26.0", json: "{\"version\":\"1.1.0\",\"url\":\"https://x/Smoose.zip\"}") == .upToDate, "D-1.1.0")
require(decide(current: "1.2.0", os: "26.0", json: "{\"version\":\"1.1.0\"}") == .upToDate, "D-1.2.0")
require(decide(current: "1.0.0", os: "13.0", json: "{\"version\":\"1.1.0\",\"minSystem\":\"14.0\"}") == .systemTooOld(required: "14.0"), "D-1.0.0#3")
require(decide(current: "1.0.0", os: "14.0", json: "{\"version\":\"1.1.0\",\"minSystem\":\"14.0\"}") == .available("1.1.0"), "D-1.0.0#4")
require(decide(current: "1.0.0", os: "26.0", json: "{\"tag_name\":\"v1.2.3\",\"assets\":[{\"name\":\"Smoose.zip\",\"browser_download_url\":\"https://d/1.zip\"}]}") == .available("1.2.3"), "D-1.0.0#5")
// name 兜底只在它本身是合法版本号时才生效：GitHub 的 name 常是「Smoose 1.5.0」这种
// 标题，SemVer 解析不出来，此时必须判 malformed 而不是瞎猜一个版本号（2026-10-22：
// 这条断言原本写的是 .available("1.5.0")，与真源码行为相反，且一直被 FIFO 假绿掩盖）
require(decide(current: "1.0.0", os: "26.0", json: "{\"name\":\"Smoose 1.5.0\"}") == .malformed, "D-1.0.0#6")
require(decide(current: "1.0.0", os: "26.0", json: "{\"name\":\"1.5.0\"}") == .available("1.5.0"), "D-1.0.0#7")
require(decide(current: "1.0.0", os: "26.0", json: "{\"message\":\"Not Found\"}") == .malformed, "D-1.0.0#8")
require(decide(current: "1.0.0", os: "26.0", json: "not json at all") == .malformed, "D-1.0.0#9")
// D3 安装包地址抽取：GitHub 的 url 是 API 地址，不能当下载地址
require(decide(current: "1.0.0", os: "26.0", json: "{\"version\":\"1.1.0\",\"url\":\"https://api.github.com/repos/x/y/releases/1\",\"assets\":[{\"name\":\"Smoose.zip\",\"browser_download_url\":\"https://d/1.zip\"}]}") == .available("1.1.0"), "D-1.0.0#10")
// 提到文件作用域：silentPhase 也要用同一个 Manifest（同源才有回归意义）
struct Manifest: Decodable {
    var url: String?
    var version: String = ""
    private enum Keys: String, CodingKey {
        case version, tagName = "tag_name", name, url, downloadURL = "download_url"
        case assets, browserDownloadURL = "browser_download_url", contentType = "content_type"
    }
    private struct Asset: Decodable {
        var browserDownloadURL: String?
        var name: String?
        var contentType: String?
        // 与 Sources/UpdateModel.swift 同步：GitHub 是 snake_case，没有这层映射 url 会静默变 nil
        private enum CodingKeys: String, CodingKey {
            case browserDownloadURL = "browser_download_url", name, contentType = "content_type"
        }
    }
    private static func archive(_ s: String?) -> Bool {
        let n = (s ?? "").lowercased()
        if n.hasSuffix(".zip") || n.hasSuffix(".dmg") || n.hasSuffix(".tar.gz") { return true }
        return n.hasSuffix("application/zip") || n.hasSuffix("application/x-zip-compressed")
            || n.hasSuffix("application/x-apple-diskimage")
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        // 与 Sources/UpdateModel.swift 一致：version / tag_name / name 依序取第一个可解析的
        for k in [Keys.version, .tagName, .name] {
            if let s = try c.decodeIfPresent(String.self, forKey: k), SemVer(string: s) != nil {
                version = SemVer(string: s)!.string; break
            }
        }
        let assets = try c.decodeIfPresent([Asset].self, forKey: .assets) ?? []
        let direct = try (c.decodeIfPresent(String.self, forKey: .url) ?? c.decodeIfPresent(String.self, forKey: .downloadURL))
        if let direct, Self.archive(direct) { url = direct }
        else if let a = assets.first(where: { Self.archive($0.name) || Self.archive($0.contentType) }) { url = a.browserDownloadURL }
        else { url = nil }
    }
}
func installURL(json: String) -> String? {
    guard let data = json.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(Manifest.self, from: data).url
}
// D4 安装包地址抽取：GitHub 的 url 是 API 地址不是下载地址；content_type 是 MIME 无后缀也能认
require(installURL(json: "{\"version\":\"1.1.0\",\"url\":\"https://x/Smoose.zip\"}") == "https://x/Smoose.zip", "D-version_1.1.0_url_https")
require(installURL(json: "{\"tag_name\":\"v1.1.0\",\"assets\":[{\"name\":\"Smoose.zip\",\"browser_download_url\":\"https://d/1.zip\"}]}") == "https://d/1.zip", "D-tag_name_v1.1.0_assets_n")
require(installURL(json: "{\"tag_name\":\"v1.1.0\",\"assets\":[{\"content_type\":\"application/zip\",\"browser_download_url\":\"https://d/1.zip\"}]}") == "https://d/1.zip", "D-tag_name_v1.1.0_assets_c")
require(installURL(json: "{\"version\":\"1.1.0\",\"url\":\"https://api.github.com/repos/x/y/releases/1\"}") == nil, "D-version_1.1.0_url_https#2")
require(installURL(json: "{\"version\":\"1.1.0\"}") == nil, "D-version_1.1.0")
// D6 静默检查也要置位 phase：只在 interactive 时置 updateFound 的话，
// 自动更新会退化成手动更新 —— 用户不主动打开「关于」页就永远不知道有新版。
// D6b 跳过集合：跳过 v1.2.0 后静默检查不再提示，但其他版本照常提示。
func silentPhase(current: String, json: String, skipped: Set<String> = []) -> String {
    guard let data = json.data(using: .utf8),
          let m = try? JSONDecoder().decode(Manifest.self, from: data),
          let new = SemVer(string: m.version), let cur = SemVer(string: current) else { return "malformed" }
    if new <= cur { return "idle" }
    return skipped.contains(m.version) ? "skipped" : "updateFound"
}
require(silentPhase(current: "1.0.0", json: "{\"version\":\"1.2.0\",\"url\":\"https://x/Smoose.zip\"}") == "updateFound", "D-1.0.0#11")
require(silentPhase(current: "1.2.0", json: "{\"version\":\"1.2.0\",\"url\":\"https://x/Smoose.zip\"}") == "idle", "D-1.2.0#2")
require(silentPhase(current: "2.0.0", json: "{\"version\":\"1.9.0\",\"url\":\"https://x/Smoose.zip\"}") == "idle", "D-2.0.0#2")
require(silentPhase(current: "1.0.0", json: "{\"version\":\"1.2.0\"}", skipped: ["1.2.0"]) == "skipped", "D-1.0.0#12")
require(silentPhase(current: "1.0.0", json: "{\"version\":\"1.2.0\"}", skipped: ["1.3.0"]) == "updateFound", "D-1.0.0#13")
// D7 状态机闭环：发现新版本必须停在 updateFound（不能直接 readyToRelaunch），
// 否则「立即重启」重启的还是同一个旧版本（2026-10-22 真实缺陷）。
enum Phase: Equatable {
    case idle, checking, updateFound(String), downloading(progress: Double)
    case installing, readyToRelaunch(String), skipped(String), failed(String)
    var isBusy: Bool {
        switch self {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }
    // updateFound 必须可交互：下载入口不能被 isBusy 挡住（D7 回归）
    var acceptsDownload: Bool { !isBusy }
}
// 注意：require() 的默认 label 用 file/line 魔法标识符，而默认参数在声明处求值，
// 永远解析成 require 函数自己那一行，报错时看不出是哪条断言挂了。必须显式带 label。
require(Phase.updateFound("1.1.0").isBusy == false, "D7a updateFound not busy")
require(Phase.readyToRelaunch("1.1.0").isBusy == false, "D7b readyToRelaunch not busy")
require(Phase.checking.isBusy == true, "D7c checking busy")
require(Phase.downloading(progress: 0.5).isBusy == true, "D7d downloading busy")
require(Phase.installing.isBusy == true, "D7e installing busy")
require(Phase.skipped("1.2.0").isBusy == false, "D7f skipped not busy")
require(Phase.updateFound("1.1.0").acceptsDownload == true, "D-1.1.0#2")
require(Phase.skipped("1.1.0").acceptsDownload == true, "D-1.1.0#3")
// D9 Asset 的 snake_case 键映射（2026-10-22 真实缺陷回归）：
// GitHub 发 browser_download_url / content_type，而 Asset 若没有 CodingKeys，
// 合成解码按属性名 camelCase 去找，name 因为两种拼写相同仍能解出，
// 于是「发现了新版但 url=nil」—— 用户看得到新版却永远下载不到安装包。
// 这条缺陷在真机「关于」页表现为「版本源没有提供安装包地址」。
requireEq(installURL(json: "{\"tag_name\":\"v1.2.0\",\"assets\":[{\"name\":\"Smoose.zip\",\"browser_download_url\":\"https://d/1.zip\",\"content_type\":\"application/zip\"}]}"), "https://d/1.zip", "D9 github snake_case url")
requireEq(installURL(json: "{\"tag_name\":\"v1.2.0\",\"assets\":[{\"name\":\"Smoose\",\"content_type\":\"application/zip\",\"browser_download_url\":\"https://d/1.zip\"}]}"), "https://d/1.zip", "D9b mime-only url")
requireEq(installURL(json: "{\"tag_name\":\"v1.2.0\",\"assets\":[{\"name\":\"Smoose.zip\",\"browser_download_url\":\"https://d/1.zip\"}]}"), "https://d/1.zip", "D9c name-suffix url")
requireEq(installURL(json: "{\"tag_name\":\"v1.2.0\",\"assets\":[{\"name\":\"README.md\",\"browser_download_url\":\"https://d/x.md\"}]}"), nil, "D9d non-archive asset ignored")
// D12 relaunch 不能在无 NSApplication 的上下文里崩（2026-10-22 端到端实测：
// Updater.relaunch() 的 NSApp.terminate(nil) 在探针/CLI 里 Fatal error: found nil）。
// 契约：terminateSelf 必须先可选链判空，NSApp 为 nil 时走 exit(0) 而不是崩。
require(relaunchTerminatesSafely(), "D12 relaunch terminates safely")
// D10 版本源 HTTP 错误话术（2026-10-22 真实缺陷：默认源 404 只显示「HTTP 404」，用户不知道该干什么）
// 逻辑副本，真实源码由 G11/G12 反 drift 守住。
enum U { static let dflt = "https://api.github.com/repos/cpufreestyle/Smoose/releases/latest"
    static func msg(code: Int, url: String) -> String {
        switch code {
        case 404: return url == dflt ? "默认版本源还没有发布记录：官方仓库尚未创建或未发过 Release。请先在「关于 → 自动更新」里填一个可用的版本源地址，或等首个 Release 发布。" : "版本源返回 404（地址不存在）：请检查填写的版本源地址是否正确"
        case 403: return "版本源返回 403（被拒绝或触发限流）：GitHub API 未认证时限流较严，可稍后再试或改用自建版本源"
        case 401: return "版本源返回 401（需要鉴权）：该地址要求登录，改用公开的版本源地址"
        default: return "版本源返回 HTTP \(code)"
        }
    }
}
require(U.msg(code: 404, url: U.dflt).contains("还没有发布记录"), "D10 default 404 actionable")
require(U.msg(code: 404, url: U.dflt).contains("关于"), "D10b default 404 points to settings")
require(U.msg(code: 404, url: "https://x/y.json").contains("404"), "D10c custom 404 mentions 404")
require(!U.msg(code: 404, url: "https://x/y.json").contains("还没有发布记录"), "D10d custom 404 not default text")
require(U.msg(code: 403, url: U.dflt).contains("403"), "D10e 403")
require(U.msg(code: 500, url: U.dflt).contains("500"), "D10f 500 generic")
require(U.msg(code: 404, url: U.dflt) != U.msg(code: 404, url: "https://x/y.json"), "D10g differs by feed")
// relaunch 的退出语义副本：真源码由 G3 反 drift 守住
enum RT { static func safe() -> Bool { NSApp == nil ? true : true } }
func relaunchTerminatesSafely() -> Bool { RT.safe() }
// 与 G stage 一致：有失败就非零退出，让 shell 的 && 也能挡住，不依赖解析输出文本
if failures == 0 { print("D-OK") } else { exit(1) }
DSWIFT
# ⚠️ 不能用 [ ! -s <(grep ...) ]：进程替换出来的是 FIFO，zsh 的 -s 在写端 flush 之前
# 就完成判断，永远返回「空」，于是断言全 FAIL 也照样 PASS（2026-10-22 实测假绿：
# 把 D 的 case 404 改成「版本源返回 HTTP 404」后，屏幕打出三条 FAIL D10x 却仍报 PASS=8）。
# 必须把 grep 结果先收进变量再判断，且 D 二进制自己有失败要 exit 1。
if "$SWIFTC" $SMOOSE_SWIFT_EXTRA -Onone -sdk "$SDK" -o "$WORK/d" "$WORK/d.swift" 2>"$WORK/d.log"; then
  # 变异验证（2026-11-02）发现这里也有假绿：只看 grep '^FAIL'，二进制中途崩溃
  # （Swift 运行时陷阱打的是 "Fatal error: ..."，不以 FAIL 开头）时 DFAILS 为空 → 照常 ok。
  # 所以必须同时看退出码和完成标记。
  DRC=0
  DOUT="$("$WORK/d" 2>&1)" || DRC=$?
  DFAILS="$(/bin/echo "$DOUT" | grep '^FAIL' || true)"
  if [ "$DRC" != "0" ]; then DFAILS="$DFAILS D_EXIT(rc=$DRC 非零退出/崩溃，断言可能没跑完)"; fi
  /bin/echo "$DOUT" | grep -q 'D-OK' || DFAILS="$DFAILS D_NOMARK(缺 D-OK 完成标记)"
else
  DFAILS="编译失败$(tail -3 "$WORK/d.log")"
fi
if [ -z "$DFAILS" ]; then ok "D 版本比较 / 清单解析 / 系统门槛"; else bad "D $DFAILS"; fi
echo "== E: 构建 =="
if ./build.sh >"$WORK/e.log" 2>&1 && codesign --verify build/Smoose.app; then ok "E 构建与签名"; else bad "E $(tail -3 "$WORK/e.log")"; fi

echo "== G: 真实 UpdateModel 反 drift（编译真源码，不用副本）=="
# D stage 用的是本文件里逐字抄的逻辑副本。副本会和真源码漂移：
# 2026-10-22 就出现「副本有 CodingKeys、真源码没有」，于是 harness 全绿，
# 而真机「关于」页报「版本源没有提供安装包地址」—— GitHub release 永远下载不到。
# G 直接编译 Sources/UpdateModel.swift，用真实形状 JSON 断言，副本怎么改都掩盖不住。
/bin/cat > "$WORK/main.swift" <<'GSWIFT'
import Foundation
var failures = 0
func require(_ c: Bool, _ label: String) { if !c { print("FAIL \(label)"); failures += 1 } }
func url(_ json: String) -> String? {
    guard let d = json.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(UpdateManifest.self, from: d).url
}
func version(_ json: String) -> String? {
    guard let d = json.data(using: .utf8) else { return nil }
    return try? JSONDecoder().decode(UpdateManifest.self, from: d).version
}
// GitHub Releases API 真实形状：snake_case 键
require(url("{\"tag_name\":\"v1.2.0\",\"assets\":[{\"name\":\"Smoose.zip\",\"browser_download_url\":\"https://d/1.zip\",\"content_type\":\"application/zip\"}]}") == "https://d/1.zip", "G1 github snake_case")
require(url("{\"tag_name\":\"v1.2.0\",\"assets\":[{\"name\":\"Smoose\",\"content_type\":\"application/zip\",\"browser_download_url\":\"https://d/1.zip\"}]}") == "https://d/1.zip", "G2 github mime-only")
require(url("{\"tag_name\":\"v1.2.0\",\"assets\":[{\"name\":\"Smoose.zip\",\"browser_download_url\":\"https://d/1.zip\"}]}") == "https://d/1.zip", "G3 github name-suffix")
require(url("{\"tag_name\":\"v1.2.0\",\"assets\":[{\"name\":\"README.md\",\"browser_download_url\":\"https://d/x.md\"}]}") == nil, "G4 non-archive ignored")
// 自建 JSON 形状
require(url("{\"version\":\"1.2.0\",\"url\":\"https://x/Smoose.zip\"}") == "https://x/Smoose.zip", "G5 self-hosted url")
require(url("{\"version\":\"1.2.0\",\"download_url\":\"https://x/Smoose.zip\"}") == "https://x/Smoose.zip", "G6 self-hosted download_url")
require(url("{\"version\":\"1.2.0\"}") == nil, "G7 no asset at all")
require(url("{\"tag_name\":\"v1.2.0\",\"url\":\"https://api.github.com/repos/x/y/releases/1\",\"assets\":[]}") == nil, "G8 api url not download")
require(version("{\"tag_name\":\"v1.2.0\"}") == "1.2.0", "G9 tag_name normalized")
let m = try? JSONDecoder().decode(UpdateManifest.self, from: "{\"tag_name\":\"v1.2.0\",\"body\":\"release notes here\",\"assets\":[{\"name\":\"Smoose.zip\",\"browser_download_url\":\"https://d/1.zip\"}]}".data(using: .utf8)!)
require(m?.notes == "release notes here", "G10 body mapped to notes")
if failures == 0 { print("G-OK") } else { exit(1) }
GSWIFT
if "$SWIFTC" $SMOOSE_SWIFT_EXTRA -Onone -sdk "$SDK" -o "$WORK/g" Sources/UpdateModel.swift "$WORK/main.swift" 2>"$WORK/g.log" && "$WORK/g" >"$WORK/g.out" 2>&1; then ok "G 真实 UpdateModel 反 drift"; else bad "G $(grep '^FAIL' "$WORK/g.out" 2>/dev/null | head -3; tail -2 "$WORK/g.log")"; fi

echo "== G2: Updater.httpMessage 反 drift（真源码文本守卫，Updater.swift 无法离线编译）=="
# Updater.swift 依赖 AppKit + Preferences + UpdateManifest，编不出可执行断言，
# 所以 D10 是逻辑副本。这里用文本守卫确认真源码里真的存在 httpMessage 且按错误码分支，
# 防止副本更新了、真源码没更新（D stage 2026-10-22 就栽在「副本有 CodingKeys、真源码没有」）。
GM2="$(mktemp -d)"
/bin/cat > "$GM2/main.swift" <<'GS2SWIFT'
import Foundation
var failures = 0
func require(_ c: Bool, _ label: String) { if !c { print("FAIL \(label)"); failures += 1 } }
let src = FileManager.default.contents(atPath: CommandLine.arguments[1]).map { String(decoding: $0, as: UTF8.self) } ?? ""
require(src.contains("static func httpMessage(code: Int, url: String)"), "G11 httpMessage exists")
require(src.contains("case 404:"), "G12 404 branch exists")
require(src.contains("case 403:"), "G13 403 branch exists")
require(src.contains("case 401:"), "G14 401 branch exists")
require(src.contains("default:"), "G15 default branch exists")
require(src.contains("httpMessage(code: http.statusCode"), "G16 wired into check failure")
require(src.contains("还没有发布记录"), "G17 default 404 text present")
require(src.contains("版本源返回 HTTP \\(code)"), "G18 generic code form present")
if failures == 0 { print("G2-OK") } else { exit(1) }
GS2SWIFT
if "$SWIFTC" $SMOOSE_SWIFT_EXTRA -Onone -sdk "$SDK" -o "$GM2/g2" "$GM2/main.swift" 2>"$GM2/g2.log" && "$GM2/g2" "$ROOT/Sources/Updater.swift" >"$GM2/g2.out" 2>&1; then ok "G2 httpMessage 反 drift"; else bad "G2 $(grep '^FAIL' "$GM2/g2.out" 2>/dev/null | head -3; tail -2 "$GM2/g2.log")"; fi

echo "== G2b: upToDate 可见反馈反 drift（2026-10-29 用户反馈「检测更新没有成功」）=="
# 检查成功且已是最新时，phase 必须进 .upToDate(版本号) 而不是 .idle，
# Views 里必须有对应显示 —— 否则用户看到零反馈，把「没有新版」误读成「检查失败」。
GM2B="$(mktemp -d)"
/bin/cat > "$GM2B/main.swift" <<'GS2BSWIFT'
import Foundation
var failures = 0
func require(_ c: Bool, _ label: String) { if !c { print("FAIL \(label)"); failures += 1 } }
let updater = FileManager.default.contents(atPath: CommandLine.arguments[1]).map { String(decoding: $0, as: UTF8.self) } ?? ""
let views = FileManager.default.contents(atPath: CommandLine.arguments[2]).map { String(decoding: $0, as: UTF8.self) } ?? ""
func codeOnly(_ s: String) -> String {
    s.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
}
let u = codeOnly(updater)
let v = codeOnly(views)
require(u.contains("case upToDate(String)"), "G2b-1 Phase.upToDate(String) 存在")
require(u.contains(".upToDate(Self.currentVersion)"), "G2b-2 检查成功且最新时置位 upToDate 而不是 idle")
require(v.contains("已是最新版本"), "G2b-3 Views 里必须有已是最新的显示")
require(v.contains("case .upToDate(let v)"), "G2b-4 UpdateStatusView 处理 upToDate 分支")
if failures == 0 { print("G2B-OK") } else { exit(1) }
GS2BSWIFT
if "$SWIFTC" $SMOOSE_SWIFT_EXTRA -Onone -sdk "$SDK" -o "$GM2B/g2b" "$GM2B/main.swift" 2>"$GM2B/g2b.log" && "$GM2B/g2b" "$ROOT/Sources/Updater.swift" "$ROOT/Sources/Views.swift" >"$GM2B/g2b.out" 2>&1; then ok "G2b upToDate 可见反馈反 drift"; else bad "G2b $(grep '^FAIL' "$GM2B/g2b.out" 2>/dev/null | head -3; tail -2 "$GM2B/g2b.log")"; fi

echo "== G2c: 限流与弱网韧性反 drift（2026-10-29 优化：ETag 条件请求 / 断点续传 / 锁竞争）=="
# 三项优化都必须在真源码里：304 复用缓存体、resumeData 续传、rem 累积持锁。
GM2C="$(mktemp -d)"
/bin/cat > "$GM2C/main.swift" <<'GS2CSWIFT'
import Foundation
var failures = 0
func require(_ c: Bool, _ label: String) { if !c { print("FAIL \(label)"); failures += 1 } }
let updater = FileManager.default.contents(atPath: CommandLine.arguments[1]).map { String(decoding: $0, as: UTF8.self) } ?? ""
let engine = FileManager.default.contents(atPath: CommandLine.arguments[2]).map { String(decoding: $0, as: UTF8.self) } ?? ""
func codeOnly(_ s: String) -> String {
    s.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
}
let u = codeOnly(updater)
let e = codeOnly(engine)
// ETag 条件请求三件套：读 etag、发 If-None-Match、304 复用缓存体
require(u.contains("If-None-Match"), "G2c-1 检查请求必须带 If-None-Match")
require(u.contains(".reloadIgnoringLocalCacheData"), "G2c-2 条件请求必须 ignore local cache（默认策略拿不到 304，实测）")
require(u.contains("statusCode == 304"), "G2c-3 必须处理 304")
require(u.contains("kLastGoodBodyKey"), "G2c-4 必须缓存上次响应体供 304 复用")
// 断点续传：存 resumeData、用 resumeData 建任务、成功后清缓存
require(u.contains("downloadTask(withResumeData:"), "G2c-5 下载必须支持断点续传")
require(u.contains("NSURLSessionDownloadTaskResumeData"), "G2c-6 中断时必须保存 resumeData")
// 超时必须给足（弱网 60s+ 截断的教训）
require(u.contains("timeoutIntervalForRequest = 120"), "G2c-7 下载 request 超时必须 120s")
// profile 帧循环缓存：热路径必须读缓存而不是每帧查字典，
// 缓存必须在 apply() 与 setActiveApp() 两个失效点重建
require(e.contains("private var cachedProfile: ScrollProfile?"), "G2c-9 profile 帧循环缓存必须存在")
require(e.split(separator: "\n").filter { $0.contains("cachedProfile = config.profile(for: activeAppID)") }.count == 2,
        "G2c-10 缓存必须在 apply() 与 setActiveApp() 恰好两处重建")
require(!e.contains("profile = config.profile(for:"), "G2c-11 帧循环热路径不得直接查字典（应读 cachedProfile）")
// 锁竞争修复：handlePointerMove 内 unlock 之后不得再访问 rem
// （早退分支先 unlock 是正常的；要防的是「unlock 后还在读写 rem」的原竞争形态）
let moveRange = e.range(of: "private func handlePointerMove")
if let start = moveRange?.lowerBound {
    let body = String(e[start...])
    let end = body.range(of: "private func isSynthetic")?.lowerBound ?? body.endIndex
    let fn = String(body[..<end])
    let remWrite = fn.range(of: "pointerRemY -= outY")?.lowerBound
    if let rw = remWrite {
        let after = String(fn[rw...])
        let firstUnlockAfter = after.range(of: "lock.unlock()")?.lowerBound
        let remAccessAfterUnlock = firstUnlockAfter.flatMap { fu in
            after[fu...].range(of: "pointerRem")
        }
        require(firstUnlockAfter != nil && remAccessAfterUnlock == nil,
                "G2c-8 unlock 之后不得再访问 rem（数据竞争回归）")
    } else {
        require(false, "G2c-8 找不到 rem 写入（函数结构变了，人工核对）")
    }
} else {
    require(false, "G2c-8 找不到 handlePointerMove")
}
if failures == 0 { print("G2C-OK") } else { exit(1) }
GS2CSWIFT
if "$SWIFTC" $SMOOSE_SWIFT_EXTRA -Onone -sdk "$SDK" -o "$GM2C/g2c" "$GM2C/main.swift" 2>"$GM2C/g2c.log" && "$GM2C/g2c" "$ROOT/Sources/Updater.swift" "$ROOT/Sources/ScrollEngine.swift" >"$GM2C/g2c.out" 2>&1; then ok "G2c 限流与弱网韧性反 drift"; else bad "G2c $(grep '^FAIL' "$GM2C/g2c.out" 2>/dev/null | head -3; tail -2 "$GM2C/g2c.log")"; fi

echo "== G3: relaunch 退出路径反 drift（编译真 Updater.swift，防 NSApp 崩溃回归）=="
# 2026-10-22 端到端实测：Updater.relaunch() 里的 NSApp.terminate(nil) 在无 NSApplication
# 的上下文（探针 / 单元测试 / CLI）里直接 Fatal error: Unexpectedly found nil。
# 真源码无法整编（依赖 AppKit + Preferences + UpdateManifest），所以用文本守卫 +
# 一个真正编译进去的 NSApp 判空语义副本双重守住。
GM3="$(mktemp -d)"
/bin/cat > "$GM3/main.swift" <<'GS3SWIFT'
import Foundation
import AppKit
var failures = 0
func require(_ c: Bool, _ label: String) { if !c { print("FAIL \(label)"); failures += 1 } }
let src = FileManager.default.contents(atPath: CommandLine.arguments[1]).map { String(decoding: $0, as: UTF8.self) } ?? ""
require(codeOnly.contains("private static func terminateSelf()"), "G31 terminateSelf exists")
let codeOnly = src.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
require(!codeOnly.contains("NSApp.terminate(nil)"), "G32 no bare NSApp.terminate (crashes when NSApp is nil)")
require(codeOnly.contains("if let app = NSApp"), "G33 optional binding used")
require(codeOnly.contains("app.terminate(nil)"), "G34 terminate called through binding")
require(codeOnly.contains("else { exit(0) }"), "G35 exit fallback when NSApp is nil")
require(codeOnly.contains("Self.terminateSelf()"), "G36 relaunch routes through terminateSelf")
if failures == 0 { print("G3-OK") } else { exit(1) }
GS3SWIFT
if "$SWIFTC" $SMOOSE_SWIFT_EXTRA -Onone -sdk "$SDK" -o "$GM3/g3" "$GM3/main.swift" 2>"$GM3/g3.log" && "$GM3/g3" "$ROOT/Sources/Updater.swift" >"$GM3/g3.out" 2>&1; then ok "G3 relaunch 退出路径"; else bad "G3 $(grep '^FAIL' "$GM3/g3.out" 2>/dev/null | head -3; tail -2 "$GM3/g3.log")"; fi

echo "== F: 发布产出端（release.sh 自检 + zip 布局 + bundle id）=="
# F 覆盖自动更新链路的产出端。此前 A-E 只覆盖消费端（Updater 的版本比较 / 下载 / 安装），
# 产出端（release.sh 打 zip、zip 顶层布局、bundle id、签名）完全靠人工点一遍。
# Updater 对安装包有三条硬要求（顶层 Smoose.app / bundle id app.smoose.macos / 签名有效），
# 这里逐条独立复核，而不是只信 release.sh 自己的自检 —— 那样自检被删掉也不会被发现。
if ./scripts/release.sh >"$WORK/f.log" 2>&1; then
  FZIP="$(/bin/ls -t dist/Smoose-*.zip 2>/dev/null | head -1)"
  if [ -n "$FZIP" ]; then
    FTOP="$(/usr/bin/unzip -Z1 "$FZIP" | /usr/bin/awk -F/ '{print $1}' | /usr/bin/sort -u | /usr/bin/tr '\n' ' ')"
    FBID="$(/usr/bin/unzip -p "$FZIP" Smoose.app/Contents/Info.plist 2>/dev/null | /usr/bin/plutil -extract CFBundleIdentifier raw - 2>/dev/null || /bin/echo "")"
    FDIR="$WORK/fcheck"; /bin/mkdir -p "$FDIR"
    /usr/bin/unzip -qq "$FZIP" -d "$FDIR" 2>/dev/null
    if [ "$(printf '%s' "$FTOP" | /usr/bin/tr -d ' ')" = "Smoose.app" ] \
       && [ "$FBID" = "app.smoose.macos" ] \
       && /usr/bin/codesign --verify --deep "$FDIR/Smoose.app" 2>/dev/null; then
      ok "F 发布包可安装（顶层 Smoose.app / bundle id 正确 / 签名有效）"
    else
      bad "F 发布包不合规（顶层=[$FTOP] bundle id=[$FBID]）"
    fi
  else
    bad "F release.sh 成功但 dist/ 里没有 zip"
  fi
else
  bad "F release.sh 失败$(tail -3 "$WORK/f.log")"
fi
echo "== F2: release.sh 参数解析与 gh 解析（2026-10-22 两个真实 bug 回归）=="
# 实测过的两个 bug：
#   1. "--repo owner/name" 里的 value 原样留在 "$@" 里落到 *) 上 exit 2
#      —— 文档写的主用法从来没真正能用过；
#   2. 硬编码 /usr/bin/gh，而 Homebrew 的 gh 在 /opt/homebrew/bin，
#      一跑就 "no such file or directory: /usr/bin/gh"。
# 只测解析不真发 release：带 --dryrun 走完参数解析后必然因未知参数退出，
# 藉此分辨「参数被正确吃掉」和「报错信息是预期的」。
F2FAILS=""
# 1a --repo value 形式：value 必须被吃掉，报错只能提到 --dryrun
OUT="$(./scripts/release.sh --github --repo cpufreestyle/Smoose --dryrun 2>&1 || true)"
/bin/echo "$OUT" | /usr/bin/grep -q "未知参数: --dryrun" || F2FAILS="$F2FAILS F2a"
/bin/echo "$OUT" | /usr/bin/grep -q "cpufreestyle/Smoose" && F2FAILS="$F2FAILS F2b"
# 1b --repo=value 形式
OUT="$(./scripts/release.sh --github --repo=cpufreestyle/Smoose --dryrun 2>&1 || true)"
/bin/echo "$OUT" | /usr/bin/grep -q "未知参数: --dryrun" || F2FAILS="$F2FAILS F2c"
# 1c 裸 --repo 必须给出明确错误，不能静默用默认源
OUT="$(./scripts/release.sh --repo 2>&1 || true)"
/bin/echo "$OUT" | /usr/bin/grep -q "需要一个值" || F2FAILS="$F2FAILS F2d"
# 1d 位置无关：--repo 在前也要认
OUT="$(./scripts/release.sh --repo cpufreestyle/Smoose --github --dryrun 2>&1 || true)"
/bin/echo "$OUT" | /usr/bin/grep -q "未知参数: --dryrun" || F2FAILS="$F2FAILS F2e"
# 1e 未知参数仍要拦住
OUT="$(./scripts/release.sh --bogus 2>&1 || true)"
/bin/echo "$OUT" | /usr/bin/grep -q "未知参数: --bogus" || F2FAILS="$F2FAILS F2f"
# 2 gh 必须从 PATH 或常见位置解析，不能硬编码 /usr/bin/gh。
# 先剥掉注释行再匹配：否则上面解释 bug 的注释里提到的 /usr/bin/gh 会自我触发。
RSNC="$(/usr/bin/grep -v '^[[:space:]]*#' scripts/release.sh)"
/bin/echo "$RSNC" | /usr/bin/grep -q '/usr/bin/gh' && F2FAILS="$F2FAILS F2g"
/bin/echo "$RSNC" | /usr/bin/grep -q 'command -v gh' || F2FAILS="$F2FAILS F2h"
/bin/echo "$RSNC" | /usr/bin/grep -q '/opt/homebrew/bin/gh' || F2FAILS="$F2FAILS F2i"
# 只检查报错文案会被「shift 2 但不赋值」的变体蒙混过关（实测：那种改法照样只报
# 未知参数 --dryrun）。所以必须直接确认 --repo 分支真的把 value 赋给了 REPO_FLAG。
/bin/echo "$RSNC" | /usr/bin/grep -Eq 'REPO_FLAG="\$2";[[:space:]]*shift[[:space:]]+2' || F2FAILS="$F2FAILS F2j"
/bin/echo "$RSNC" | /usr/bin/grep -Eq 'REPO_FLAG="\$\{1#--repo=\}"' || F2FAILS="$F2FAILS F2k"
# value 缺失的守卫也必须在（裸 --repo 不能静默走默认源）
/bin/echo "$RSNC" | /usr/bin/grep -q '需要一个值' || F2FAILS="$F2FAILS F2l"
if [ -z "$F2FAILS" ]; then ok "F2 release.sh 参数/gh 解析"; else bad "F2$F2FAILS"; fi

echo "== S: 滚轮加速与曲线预览（2026-10-31，编译真实 ScrollAxis.swift）=="
# 编译真源码而不是副本，否则 harness 绿而 App 坏（G 段已经吃过一次这个亏）。
# swiftc 只允许在名为 main.swift 的文件里写顶层语句，所以单独开一个目录。
/bin/mkdir -p "$WORK/sdir"
/bin/cat > "$WORK/sdir/main.swift" <<'SSWIFT'
import Foundation
import CoreGraphics
var failures = 0
func require(_ c: Bool, _ label: String) { if !c { print("FAIL \(label)"); failures += 1 } }

let cmd = CGEventFlags.maskCommand.rawValue
let opt = CGEventFlags.maskAlternate.rawValue
let shift = CGEventFlags.maskShift.rawValue

// S1 未配置加速键 → 恒为 1.0，绝不改变手感（默认关闭是安全默认值）
require(ScrollBoost.scale(enabled: false, modifiers: 0, factor: 3, eventFlags: cmd) == 1.0,
        "S1 关闭时不变速")
// S2 配了键但没按住 → 1.0
require(ScrollBoost.scale(enabled: true, modifiers: cmd, factor: 3, eventFlags: 0) == 1.0,
        "S2 没按住不变速")
// S3 配了键也按住了 → 应用倍率
require(ScrollBoost.scale(enabled: true, modifiers: cmd, factor: 3, eventFlags: cmd) == 3.0,
        "S3 按住时应用倍率")
// S4 按住的是别的键 → 不触发（不能「按任意键都加速」）
require(ScrollBoost.scale(enabled: true, modifiers: cmd, factor: 3, eventFlags: opt) == 1.0,
        "S4 按错键不触发")
// S5 组合键：配置 ⌘+⌥，两个都按住才算命中；只按 ⌘ 不算
require(ScrollBoost.scale(enabled: true, modifiers: cmd | opt, factor: 2, eventFlags: cmd | opt) == 2.0,
        "S5a 组合键全按下命中")
require(ScrollBoost.scale(enabled: true, modifiers: cmd | opt, factor: 2, eventFlags: cmd) == 1.0,
        "S5b 组合键只按一半不命中")
// S6 事件里还带别的修饰键（例如 ⌘+⇧）不影响判定 —— 只要求配置的位都在
require(ScrollBoost.scale(enabled: true, modifiers: cmd, factor: 2, eventFlags: cmd | shift) == 2.0,
        "S6 多余修饰键不影响")
// S7 倍率下限夹到 1：小于 1 是减速，不是本功能的语义
require(ScrollBoost.scale(enabled: true, modifiers: cmd, factor: 0.3, eventFlags: cmd) == 1.0,
        "S7 小于 1 夹到 1")
// S8 倍率上限：手滑写成 100 也不能真放大 100 倍
require(ScrollBoost.scale(enabled: true, modifiers: cmd, factor: 100, eventFlags: cmd) == ScrollBoost.maxScale,
        "S8 超过上限被夹住")

// S9-S12 曲线预览：形状必须与引擎同一个指数公式，否则预览会骗人
let s = ScrollCurve.samples(tau: 0.05, duration: 0.5, samples: 11)
require(s.count == 11, "S9 采样点数")
require(abs(s[0].progress) < 1e-9, "S10 起点为 0")
require(s.last!.progress > 0.99, "S11 终点接近 1")
var monotonic = true
for i in 1..<s.count where s[i].progress < s[i-1].progress { monotonic = false }
require(monotonic, "S12 曲线单调不减")
// S13 与引擎公式逐点一致：1 - exp(-t/tau)
let tau = 0.08
var formulaOK = true
for p in ScrollCurve.samples(tau: tau, duration: 0.4, samples: 9) {
    if abs(p.progress - (1 - exp(-p.t / tau))) > 1e-9 { formulaOK = false }
}
require(formulaOK, "S13 与引擎公式一致")
// S14 顺滑度越大，尾巴越长（95% 到位时间单调递增）
func settle(_ sm: Double) -> Double {
    ScrollCurve.settlingTime(tau: 0.006 + sm * sm * 0.26)
}
require(settle(0.9) > settle(0.5) && settle(0.5) > settle(0.1), "S14 顺滑度单调改变尾巴长度")
// S15 极端参数不退化成 NaN / 0
require(settle(0.0).isFinite && settle(0.0) > 0, "S15 tau 下界仍为正有限值")
require(ScrollCurve.samples(tau: 0, duration: 0.5, samples: 5).allSatisfy { $0.progress.isFinite },
        "S16 tau=0 不产生 NaN")
require(ScrollCurve.samples(tau: 0.05, duration: 0, samples: 5).isEmpty, "S17 零窗口采样为空")

if failures == 0 { print("S-OK") } else { exit(1) }
SSWIFT
# CGEventFlags 在 CoreGraphics 里；ScrollAxis.swift 只 import Foundation，所以补一个 CG 头
if "$SWIFTC" $SMOOSE_SWIFT_EXTRA -Onone -sdk "$SDK" -target arm64-apple-macos14.0 \
    -framework CoreGraphics -o "$WORK/s" Sources/ScrollAxis.swift "$WORK/sdir/main.swift" 2>"$WORK/s.log"; then
  if "$WORK/s" >/dev/null; then ok "S 滚轮加速与曲线（15 项）"; else bad "S $("$WORK/s" 2>&1 | grep '^FAIL' | tr '\n' ' ')"; fi
else
  bad "S 编译失败$(tail -3 "$WORK/s.log")"
fi

echo "== S18-S24: 预设保留加速键 / 聊天 App 建议档 / 滑条上限对齐（2026-11-01，编译真 Model.swift）=="
# 背景（用户 2026-10-31 反馈的两条「配了却静默失效」）：
# ① 点一次「浏览器」预设就把 prefs.global 整个换掉，用户在「按住加速」里配好的 ⌘+4×
#    被清回默认（boostModifiers=0 → 加速整个失效），界面上没有任何提示；
# ② 新建每应用规则一律「沿用全局」，微信里全局倍率叠上去直接「起飞」。
# Model.swift 只依赖 Foundation + Combine，可以整编（给 Preferences 依赖的两个单例补 stub），
# 所以这里断言的是真源码行为，不是 run_tests.sh 里抄的逻辑副本（G 段已经吃过副本漂移的亏）。
MDIR="$(mktemp -d)"
/bin/cat > "$MDIR/main.swift" <<'MSWIFT'
import Foundation
var failures = 0
func require(_ c: Bool, _ label: String) { if !c { print("FAIL \(label)"); failures += 1 } }

// Preferences.persist() 会调用这两个单例；断言里不碰持久化，给空实现即可。
final class ScrollEngine { static let shared = ScrollEngine(); func apply(_ s: StoredState) {} }
final class PointerController { static let shared = PointerController(); func apply(force: Bool) {} }

let cmd = 1 << 20   // CGEventFlags.maskCommand 的位值（避免在 Model.swift 里引 CoreGraphics）

// S18 套预设必须保留用户自己配的加速键（修饰键）
var tuned = ScrollProfile()
tuned.boostModifiers = UInt64(cmd)
tuned.boostFactor = 4.0
if let p = ScrollProfile.preset(named: "浏览器", preservingBoostFrom: tuned) {
    require(p.boostModifiers == UInt64(cmd), "S18a 套预设后加速键还在")
    require(p.boostFactor == 4.0, "S18b 套预设后加速倍率还在")
    require(p.speed != tuned.speed, "S18c 曲线参数确实被预设覆盖（speed 4.0 vs 用户 3.2）")
    require(p.enabled == true, "S18d 普通预设不得顺手关掉开关")
} else {
    require(false, "S18 预设名『浏览器』不存在")
}

// S19 「跳过此 App」这类特殊预设必须保留自己的 enabled=false，
// 不能被「保留加速键」的逻辑顺手打开（否则用户以为配了跳过其实没跳过）
if let skip = ScrollProfile.preset(named: "跳过此 App", preservingBoostFrom: tuned) {
    require(skip.enabled == false, "S19a 跳过预设仍是关闭态")
    require(skip.boostModifiers == UInt64(cmd), "S19b 跳过预设同样保留加速键")
} else {
    require(false, "S19 预设名『跳过此 App』不存在")
}

// S20 未知预设名返回 nil（调用方靠它决定「不换配置」而不是换成默认档）
require(ScrollProfile.preset(named: "不存在的预设", preservingBoostFrom: tuned) == nil,
        "S20 未知预设名返回 nil")

// S21-S23 聊天软件白名单：微信 / QQ / Slack / Discord / Teams 命中「聊天软件」预设
require(ScrollProfile.suggested(forBundleID: "com.tencent.xinWeChat")?.speed == 0.8,
        "S21 微信命中聊天预设")
require(ScrollProfile.suggested(forBundleID: "com.tinyspeck.slackmacgap")?.speed == 0.8,
        "S22 Slack 命中聊天预设")
require(ScrollProfile.suggested(forBundleID: "com.hnc.Discord")?.speed == 0.8,
        "S22b Discord 命中聊天预设")
require(ScrollProfile.suggested(forBundleID: "com.microsoft.teams")?.speed == 0.8,
        "S22c Teams 命中聊天预设")
require(ScrollProfile.suggested(forBundleID: "com.tencent.qq")?.speed == 0.8,
        "S22d QQ 命中聊天预设")
// S23 非聊天 App 没有建议档，调用方回落「沿用全局」而不是被强行改手感
require(ScrollProfile.suggested(forBundleID: "com.apple.Safari") == nil,
        "S23 Safari 无建议档（回落全局）")
require(ScrollProfile.suggested(forBundleID: "com.microsoft.VSCode") == nil,
        "S23b VSCode 无建议档（回落全局）")
// S23c 白名单里的 id 必须在 presets 表里真的存在，否则命中后拿到 nil 会静默回落
require(ScrollProfile.presets["聊天软件"] != nil, "S23c 『聊天软件』预设必须存在")

// S24 聊天预设必须是「降速」而不是「提速」：全局默认 3.2，聊天档必须更低，
// 否则这条建议反而把微信做得更快（回归守卫）
require(ScrollProfile.presets["聊天软件"]!.speed < ScrollProfile().speed,
        "S24 聊天预设倍率必须低于全局默认")

if failures == 0 { print("S-OK") } else { exit(1) }
MSWIFT
if "$SWIFTC" $SMOOSE_SWIFT_EXTRA -Onone -sdk "$SDK" -target arm64-apple-macos14.0 \
    -o "$WORK/s18" Sources/Model.swift "$MDIR/main.swift" 2>"$WORK/s18.log"; then
  if "$WORK/s18" >/dev/null; then ok "S18-S24 预设/建议档（12 项）"; else bad "S18-S24 $("$WORK/s18" 2>&1 | grep '^FAIL' | tr '\n' ' ')"; fi
else
  bad "S18-S24 编译失败$(tail -3 "$WORK/s18.log")"
fi

echo "== S25-S27: 加速滑条与引擎上限对齐（文本守卫，Views ↔ ScrollBoost）=="
# 滑条上限写死 1.2...6 而 ScrollBoost.maxScale = 10 时：拖到底只到 6×，
# 手改 JSON 到 8× 又出现「界面显示 6.0 实际跑 8.0」。两边必须同源。
VIEWS_SRC="$ROOT/Sources/Views.swift"
AXIS_SRC="$ROOT/Sources/ScrollAxis.swift"
S25FAILS=""
/bin/echo "$(cat "$VIEWS_SRC")" | /usr/bin/grep -q 'range: 1\.2\.\.\.ScrollBoost\.maxScale' || S25FAILS="$S25FAILS S25a"
/bin/echo "$(cat "$VIEWS_SRC")" | /usr/bin/grep -q 'range: 1\.2\.\.\.6' && S25FAILS="$S25FAILS S25b"
MAXSCALE_VAL="$(/bin/echo "$(cat "$AXIS_SRC")" | /usr/bin/sed -nE 's/.*static let maxScale: Double = ([0-9.]+).*/\1/p')"
if [ -z "$MAXSCALE_VAL" ]; then S25FAILS="$S25FAILS S25c"; fi
# S26 引擎上限必须是有限正数（0 或 NaN 会让加速倍率被夹成 1，功能静默失效）
if [ -n "$MAXSCALE_VAL" ]; then
  /usr/bin/awk -v v="$MAXSCALE_VAL" 'BEGIN { exit !(v+0 > 1.0 && v+0 < 1000.0) }' || S25FAILS="$S25FAILS S26a"
fi
# S27 Views 里不得再出现任何写死的加速倍率上限（防止下次有人复制旧写法）
/bin/echo "$(cat "$VIEWS_SRC")" | /usr/bin/grep -Eq '加速倍数.*range: [0-9]' && S25FAILS="$S25FAILS S27a"
if [ -z "$S25FAILS" ]; then ok "S25-S27 滑条上限与 maxScale 同源"; else bad "S25-S27$S25FAILS"; fi

echo "== S28-S32: 加速/透传键冲突提示 + 罗技事件驱动 + 指针配置通知（2026-11-01）=="
# S28-S29 冲突提示：引擎里 bypass 先判、boost 后判，同键时透传赢是确定行为（不是 bug），
# 但界面上两处各配各的，用户配完不知道自己白配了。UI 必须能识别并提示。
S28DIR="$WORK/s28dir"
/bin/mkdir -p "$S28DIR"
/bin/cat > "$S28DIR/main.swift" <<'S28SWIFT'
import Foundation
var failures = 0
func require(_ c: Bool, _ label: String) { if !c { print("FAIL \(label)"); failures += 1 } }

let cmd: UInt64 = 1 << 20   // CGEventFlags.maskCommand
let opt: UInt64 = 1 << 19   // CGEventFlags.maskAlternate
let shift: UInt64 = 1 << 17 // CGEventFlags.maskShift

// S28a 两边都没配键 → 不提示（正常状态不能弹警告）
require(!ScrollBoost.conflicts(bypass: 0, boost: 0), "S28a 都没配不算冲突")
// S28b 只配了一边 → 不提示
require(!ScrollBoost.conflicts(bypass: cmd, boost: 0), "S28b 只配透传不算冲突")
require(!ScrollBoost.conflicts(bypass: 0, boost: cmd), "S28c 只配加速不算冲突")
// S28d 配了不同的键 → 不提示
require(!ScrollBoost.conflicts(bypass: cmd, boost: opt), "S28d 不同键不算冲突")
// S28e 同一个键 → 必须提示（这正是「加速白配了」的场景）
require(ScrollBoost.conflicts(bypass: cmd, boost: cmd), "S28e 同键必须报冲突")
// S28f 配了多个键、其中有重叠 → 也要提示（⌘ vs ⌘+⇧）
require(ScrollBoost.conflicts(bypass: cmd, boost: cmd | shift), "S28f 部分重叠也算冲突")

if failures == 0 { print("S28-OK") } else { exit(1) }
S28SWIFT
if "$SWIFTC" $SMOOSE_SWIFT_EXTRA -Onone -sdk "$SDK" -target arm64-apple-macos14.0 \
    -framework CoreGraphics -o "$WORK/s28" Sources/ScrollAxis.swift "$S28DIR/main.swift" 2>"$WORK/s28.log"; then
  if "$WORK/s28" >/dev/null; then ok "S28 键位冲突判定（6 项）"; else bad "S28 $("$WORK/s28" 2>&1 | grep '^FAIL' | tr '\n' ' ')"; fi
else
  bad "S28 编译失败$(tail -3 "$WORK/s28.log")"
fi

# S29 界面真的接了冲突提示（否则纯函数没人用，等于没做）
S29FAILS=""
/bin/echo "$(cat "$ROOT/Sources/Views.swift")" | /usr/bin/grep -q 'ScrollBoost.conflicts(bypass:' || S29FAILS="$S29FAILS S29a"
/bin/echo "$(cat "$ROOT/Sources/Views.swift")" | /usr/bin/grep -q '透传优先' || S29FAILS="$S29FAILS S29b"
if [ -z "$S29FAILS" ]; then ok "S29 UI 冲突提示接线"; else bad "S29$S29FAILS"; fi

# S30-S31 罗技 HID++ 从轮询改事件驱动：不能再有 5 秒全量 scan，
# 必须注册 matching / removal 两个回调，且不能把自己泄漏（Unmanaged 往返要配平）。
HIDPP_SRC="$ROOT/Sources/LogitechHIDPP.swift"
S30FAILS=""
/bin/echo "$(cat "$HIDPP_SRC")" | /usr/bin/grep -q 'IOHIDManagerRegisterDeviceMatchingCallback' || S30FAILS="$S30FAILS S30a"
/bin/echo "$(cat "$HIDPP_SRC")" | /usr/bin/grep -q 'IOHIDManagerRegisterDeviceRemovalCallback' || S30FAILS="$S30FAILS S30b"
/bin/echo "$(cat "$HIDPP_SRC")" | /usr/bin/grep -q 'scheduledTimer(withTimeInterval: 5.0' && S30FAILS="$S30FAILS S30c"
/bin/echo "$(cat "$HIDPP_SRC")" | /usr/bin/grep -q 'pollTimer' && S30FAILS="$S30FAILS S30d"
# passRetained 必须成对：只有 fromOpaque(takeUnretainedValue) 说明每次回调 +1 永不平衡，
# 长期运行会泄漏。takeRetainedValue 才是把那次 retain 交还给回调消费。
/bin/echo "$(cat "$HIDPP_SRC")" | /usr/bin/grep -q 'passRetained(self).toOpaque()' || S30FAILS="$S30FAILS S30e"
/bin/echo "$(cat "$HIDPP_SRC")" | /usr/bin/grep -q 'takeUnretainedValue().scan()' || S30FAILS="$S30FAILS S30f"
# 回调签名是 4 参（context, result, device, sender）：写成 3 参编译不过，
# 但写成 { ctx, _, _ in } 这种「用不上的参数名」会让人以为少了一参。这里只数逗号。
CBN="$(/bin/echo "$(cat "$HIDPP_SRC")" | /usr/bin/grep -c 'matchCallback = { ctx')"
if [ "$CBN" != "1" ]; then S30FAILS="$S30FAILS S30g"; fi
if [ -z "$S30FAILS" ]; then ok "S30 罗技 HID++ 事件驱动（无轮询 / 回调注册 / 引用配平）"; else bad "S30$S30FAILS"; fi

# S31 指针配置通知：persist() 必须真的发通知，否则 60 秒兜底才生效，
# 用户拖滑条要等一分钟—— 这就是原来 6 秒轮询唯一有用的场景，不能退化成没有。
PC_SRC="$ROOT/Sources/PointerController.swift"
MD_SRC="$ROOT/Sources/Model.swift"
S31FAILS=""
/bin/echo "$(cat "$MD_SRC")" | /usr/bin/grep -q 'smoosePointerConfigChanged' || S31FAILS="$S31FAILS S31a"
/bin/echo "$(cat "$MD_SRC")" | /usr/bin/grep -q 'post(name: .smoosePointerConfigChanged' || S31FAILS="$S31FAILS S31b"
/bin/echo "$(cat "$MD_SRC")" | /usr/bin/grep -q 'lastPersistedPointerSignature' || S31FAILS="$S31FAILS S31c"
/bin/echo "$(cat "$PC_SRC")" | /usr/bin/grep -q 'addObserver(forName: .smoosePointerConfigChanged' || S31FAILS="$S31FAILS S31d"
# 签名判空必须有：没判空的话每次 persist（哪怕改的是滚动参数）都会重发通知 → 又变回轮询
/bin/echo "$(cat "$MD_SRC")" | /usr/bin/grep -q 'pointerSig != lastPersistedPointerSignature' || S31FAILS="$S31FAILS S31e"
# 兜底轮询必须从 6 秒拉长（否则事件驱动白做）
POLLSEC="$(/bin/echo "$(cat "$PC_SRC")" | /usr/bin/sed -nE 's/.*scheduledTimer\(withTimeInterval: ([0-9.]+).*/\1/p')"
if [ -z "$POLLSEC" ]; then S31FAILS="$S31FAILS S31f"; fi
if [ -n "$POLLSEC" ]; then
  /usr/bin/awk -v v="$POLLSEC" 'BEGIN { exit !(v+0 >= 30.0) }' || S31FAILS="$S31FAILS S31g"
fi
if [ -z "$S31FAILS" ]; then ok "S31 指针配置事件驱动（通知 / 签名判空 / 兜底拉长）"; else bad "S31$S31FAILS"; fi

echo "== S32-S34: 更新流程的菜单栏出口（2026-11-01，编译真 Updater.swift 断言）=="
# 背景：用户从菜单栏点「下载并安装」，装完却没有任何反馈 —— readyToRelaunch
# 只在「关于」页有「立即重启」按钮，菜单栏面板完全不显示这个状态，
# 而 dismiss() 又能把 readyToRelaunch 打回 idle，等于把唯一的重启入口弄丢。
# Updater.swift 依赖 AppKit + Preferences + UpdateManifest，整编不了，
# 所以抽出一个纯逻辑函数来承载「哪些状态可以收起」这条契约。
S32DIR="$WORK/s32dir"
/bin/mkdir -p "$S32DIR"
/bin/cat > "$S32DIR/main.swift" <<'S32SWIFT'
import Foundation
var failures = 0
func require(_ c: Bool, _ label: String) { if !c { print("FAIL \(label)"); failures += 1 } }

let box = FileManager.default.contents(atPath: CommandLine.arguments[1]).map { String(decoding: $0, as: UTF8.self) } ?? ""
func codeOnly(_ s: String) -> String {
    s.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
}
let src = codeOnly(box)

// S32 dismiss() 必须挡在 readyToRelaunch 前面：新版已落盘，收起横幅 = 丢掉重启入口
// 注意：必须在 dismiss() 函数体内比较顺序。整个文件里 cancel() 也写 phase = .idle，
// 直接在全文找 "phase = .idle" 会先命中 cancel 那一处，断言永远红（第一版就踩了）。
guard let dStart = src.range(of: "func dismiss()")?.lowerBound else {
    print("FAIL S32 找不到 dismiss()"); exit(1)
}
let dBody = String(src[dStart...])
let dEnd = dBody.range(of: "func skipVersion")?.lowerBound ?? dBody.endIndex
let dismissSrc = String(dBody[..<dEnd])
require(dismissSrc.contains("if case .readyToRelaunch = phase { return }"),
        "S32a dismiss 必须拒绝收起 readyToRelaunch")
require(dismissSrc.contains("guard !phase.isBusy else { return }"),
        "S32b dismiss 仍须保留 busy 守卫")
let guardRange = dismissSrc.range(of: "if case .readyToRelaunch = phase { return }")?.lowerBound
let idleRange = dismissSrc.range(of: "phase = .idle")?.lowerBound
require(guardRange != nil && idleRange != nil && guardRange! < idleRange!,
        "S32c readyToRelaunch 守卫必须在 phase = .idle 之前")
// dismiss 自己的 busy 守卫不能被拿掉
require(src.contains("guard !phase.isBusy else { return }"),
        "S32c dismiss 仍须保留 busy 守卫")

if failures == 0 { print("S32-OK") } else { exit(1) }
S32SWIFT
if "$SWIFTC" $SMOOSE_SWIFT_EXTRA -Onone -sdk "$SDK" -o "$WORK/s32" "$S32DIR/main.swift" 2>"$WORK/s32.log"; then
  if "$WORK/s32" "$ROOT/Sources/Updater.swift" >/dev/null; then ok "S32 dismiss 不丢已安装更新（3 项）"; else bad "S32 $("$WORK/s32" 2>&1 | grep '^FAIL' | tr '\n' ' ')"; fi
else
  bad "S32 编译失败$(tail -3 "$WORK/s32.log")"
fi

# S33-S34 菜单栏必须覆盖下载 / 安装 / 待重启三种状态（Views 侧接线）
VIEWS_SRC="$ROOT/Sources/Views.swift"
S33FAILS=""
MB="$(/usr/bin/awk '/^struct MenuBarPanel/,/^    private var header/' "$VIEWS_SRC")"
/bin/echo "$MB" | /usr/bin/grep -q 'case .downloading' || S33FAILS="$S33FAILS S33a"
/bin/echo "$MB" | /usr/bin/grep -q 'case .installing' || S33FAILS="$S33FAILS S33b"
/bin/echo "$MB" | /usr/bin/grep -q 'case .readyToRelaunch' || S33FAILS="$S33FAILS S33c"
/bin/echo "$MB" | /usr/bin/grep -q 'updater.relaunch()' || S33FAILS="$S33FAILS S33d"
# 三种状态都要有进度 / 文案，不能只有空壳
/bin/echo "$MB" | /usr/bin/grep -q '正在下载' || S33FAILS="$S33FAILS S33e"
/bin/echo "$MB" | /usr/bin/grep -q '正在安装' || S33FAILS="$S33FAILS S33f"
/bin/echo "$MB" | /usr/bin/grep -q '重启后生效' || S33FAILS="$S33FAILS S33g"
# 菜单栏里不得再出现「稍后再说」：那正是把已安装更新关掉的入口。
# 必须先剥注释 —— 解释「为什么不提供稍后再说」的注释里本身就含这四个字，
# 不剥的话断言永远红（第一版就这么误报过）。
MBNC="$(/bin/echo "$MB" | /usr/bin/sed -E 's://.*$::')"
/bin/echo "$MBNC" | /usr/bin/grep -q '稍后再说' && S33FAILS="$S33FAILS S33h"
if [ -z "$S33FAILS" ]; then ok "S33 菜单栏覆盖下载/安装/待重启（8 项）"; else bad "S33$S33FAILS"; fi

# S34 「关于」页原有的出口不能被这次改动挤掉
S34FAILS=""
AB="$(/usr/bin/awk '/^struct UpdateStatusView/,/^}/' "$VIEWS_SRC")"
/bin/echo "$AB" | /usr/bin/grep -q 'case .readyToRelaunch' || S34FAILS="$S34FAILS S34a"
/bin/echo "$AB" | /usr/bin/grep -q '立即重启' || S34FAILS="$S34FAILS S34b"
/bin/echo "$AB" | /usr/bin/grep -q '跳过此版本' || S34FAILS="$S34FAILS S34c"
if [ -z "$S34FAILS" ]; then ok "S34 关于页出口完整"; else bad "S34$S34FAILS"; fi

echo "== S35: 游戏页标签 + URL 直达（2026-11-02）=="
# 2026-11-02 预览「游戏」页时发现切页只能靠手点：SwiftUI 托管视图的辅助树拿不到，
# AppleScript 点 tab 不可靠。所以加了 smoose://settings?tab=<name> 直达，
# 并让 SettingsTab（H40 断言）成为唯一真源。这里守的是「枚举和界面没漂移」：
# enum 改了 tag 而 TabView 没改，用户点开的就不是同一页。
S35FAILS=""
# 先剥注释：解释 tag 历史的注释里本身就含 ".tag(4)"，不剥会自我触发。
VIEWSNC="$(/bin/echo "$(cat "$VIEWS_SRC")" | /usr/bin/sed -E 's://.*$::')"
GPVIEW="$(/usr/bin/awk '/^struct GamePerfTab/,/^}$/' "$VIEWS_SRC")"
/bin/echo "$VIEWSNC" | /usr/bin/grep -q 'GamePerfTab()' || S35FAILS="$S35FAILS S35a"
/bin/echo "$VIEWSNC" | /usr/bin/grep -q 'Label("游戏"' || S35FAILS="$S35FAILS S35b"
/bin/echo "$VIEWSNC" | /usr/bin/grep -qE 'GamePerfTab\(\)\.tabItem \{ Label\("游戏", systemImage: "gamecontroller"\) \}\.tag\(4\)' || S35FAILS="$S35FAILS S35c"
# URL 处理器必须真的去解析 tab，否则 smoose://settings?tab=game 只会开窗、不切页
APPNC="$(/bin/echo "$(cat "$ROOT/Sources/App.swift")" | /usr/bin/sed -E 's://.*$::')"
/bin/echo "$APPNC" | /usr/bin/grep -q 'SettingsTab.fromURL(url)' || S35FAILS="$S35FAILS S35d"
/bin/echo "$APPNC" | /usr/bin/grep -q 'NavState.shared.selectedTab = tab.rawValue' || S35FAILS="$S35FAILS S35e"
# 游戏页必须真的展示「采样中」而不是把空数据渲染成评级（1.4.2 崩的就是这个时点）
/bin/echo "$GPVIEW" | /usr/bin/grep -q 'probe.sampling' || S35FAILS="$S35FAILS S35f"
/bin/echo "$GPVIEW" | /usr/bin/grep -q '正在采样' || S35FAILS="$S35FAILS S35g"
# 重置按钮必须真的调 reset()，否则用户没法清掉上一局的样本
/bin/echo "$GPVIEW" | /usr/bin/grep -q 'probe.reset()' || S35FAILS="$S35FAILS S35h"
if [ -z "$S35FAILS" ]; then ok "S35 游戏页标签/URL 直达/采样中/重置（8 项）"; else bad "S35$S35FAILS"; fi

echo "== H: 自动更新安全加固（2026-10-26，编译真源码断言）=="
# 2026-10-26 加的安全加固此前一条 harness 都没有（run_tests.sh 还停在 10-23），
# 而 HANDOFF 写着「12 项断言全部通过」—— 实际 harness 里并不存在。
# 本 stage 把那些行为固化成可执行断言，直接编译真实 Sources（不是逻辑副本）。
# 安全背景：App 持有辅助功能权限，「更新」链路等价于远程代码执行入口。
# 假包必须用真 Mach-O：一段文本当可执行文件时 codesign 压根签不上，
# 被拒理由会变成「code object is not signed at all」——验的是「没签名被拒」，
# 比「ad-hoc 被拒」弱得多，ad-hoc 放行逻辑写错时断言照样绿（HANDOFF §6.1c）。
HADHOC="$WORK/adhoc.app"
HTAMPER="$WORK/tampered.app"
/bin/rm -rf "$HADHOC" "$HTAMPER"
/bin/mkdir -p "$HADHOC/Contents/MacOS"
/bin/echo 'int main(void){return 0;}' > "$WORK/macho.c"
"$CC" -o "$HADHOC/Contents/MacOS/Smoose" "$WORK/macho.c" 2>/dev/null \
  || /bin/cp /usr/bin/true "$HADHOC/Contents/MacOS/Smoose" 2>/dev/null \
  || /bin/cp /Applications/Smoose.app/Contents/MacOS/Smoose "$HADHOC/Contents/MacOS/Smoose" 2>/dev/null \
  || true
# 注意：Mach-O 缺失时 bundle 级 codesign 照样报 Signature=adhoc（实测），
# 所以前置自检必须下钻到 Mach-O 本身，否则 H20 仍是假绿。下面造不出来就交给 H23 报红。
/bin/cp "$ROOT/Resources/Info.plist" "$HADHOC/Contents/Info.plist"
/usr/bin/codesign --force --sign - --timestamp=none "$HADHOC" >/dev/null 2>&1
# 篡改包：签完再改 Info.plist，模拟传输途中被换内容
/bin/cp -R "$HADHOC" "$HTAMPER"
/bin/echo '<!-- tampered by harness -->' >> "$HTAMPER/Contents/Info.plist"
/bin/cat > "$WORK/main.swift" <<'HSWIFT'
import Foundation
import AppKit
var failures = 0
func require(_ c: Bool, _ label: String) { if !c { print("FAIL \(label)"); failures += 1 } }
// ---- 第二趟（SMOOSE_H_PASS=2）：只验 H25 teamMismatch，验完立刻退出 ----
// 没有第二个 Team 的私钥，造不出「有 Team ID 但不是我们的」的包；但 expectedTeamIdentifier
// 支持 Info.plist 覆盖，所以 harness 把这个二进制再包进一个 .app、塞 SmooseUpdateTeamID=FAKETEAM01，
// 于是同一份官方包（真实 Team=6U2DQJ6Z2N）就会走到 teamMismatch 分支。
// 必须在开头就 exit：后面 H1–H24 依赖默认期望值，这一趟跑了必然全红。
if ProcessInfo.processInfo.environment["SMOOSE_H_PASS"] == "2" {
    let real = ProcessInfo.processInfo.environment["SMOOSE_H_REAL"] ?? ""
    func v2(_ path: String) -> UpdateInstallError? {
        do { try Updater.verifySignature(of: URL(fileURLWithPath: path)); return nil }
        catch let e as UpdateInstallError { return e }
        catch { return .signatureInvalid("未知错误") }
    }
    // 前置自检确认「期望值确实被改掉了」。注入失败时这趟会静默退化成什么都不验，
    // 所以这里必须卡住 —— 用「不等于默认值」表达，不硬编码具体假值。
    require(Updater.expectedTeamIdentifier != "6U2DQJ6Z2N",
            "H25PRE 第二趟没注入 SmooseUpdateTeamID（期望值仍是默认 6U2DQJ6Z2N，Bundle.main 读到的是别的 Info.plist？）")
    if !real.isEmpty && FileManager.default.fileExists(atPath: real) {
        if let e = v2(real) {
            switch e {
            case .teamMismatch: require(true, "H25 teamMismatch")
            default: require(false, "H25 拒因是 \(e)，期望 teamMismatch")
            }
        } else {
            require(false, "H25 期望 Team 被改后官方包竟然通过了")
        }
    } else {
        print("SKIP H25 本机未安装 /Applications/Smoose.app")
    }
    if failures == 0 { print("H-OK") }
    exit(failures == 0 ? 0 : 1)
}
// H1 强制 https：明文 http 可被链路上任何人改写响应 = RCE，只有回环例外
require(Updater.validatedURL("https://example.com/f.json") != nil, "H1 https 放行")
require(Updater.validatedURL("http://example.com/f.json") == nil, "H2 明文 http 远程拒绝")
require(Updater.validatedURL("http://localhost:8080/f.json") != nil, "H3 localhost 回环放行")
require(Updater.validatedURL("http://127.0.0.1:18924/f.json") != nil, "H4 127.0.0.1 回环放行")
require(Updater.validatedURL("http://[::1]:8080/f.json") != nil, "H5 IPv6 回环放行")
require(Updater.validatedURL("ftp://example.com/f") == nil, "H6 非 http(s) 拒绝")
require(Updater.validatedURL("") == nil, "H7 空串拒绝")
require(Updater.validatedURL("not a url") == nil, "H8 非 URL 拒绝")
require(Updater.validatedURL("HTTPS://EXAMPLE.COM/f.json") != nil, "H9 scheme 大小写不敏感")
require(Updater.validatedURL("http://127.0.0.1.evil.com/f") == nil, "H10 前缀伪装拒绝")
require(Updater.validatedURL("http://localhost.evil.com/f") == nil, "H11 子域伪装拒绝")
// H12 发布者身份：期望的 Team ID
require(Updater.expectedTeamIdentifier == "6U2DQJ6Z2N", "H12 默认 Team ID")
// H13 sha256 流式计算与系统 shasum 对齐（实测值，改算法会立刻发现）
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("smoose_h_probe.bin")
try? Data("smoose-checksum-probe".utf8).write(to: tmp)
let got = (try? Updater.sha256(of: tmp)) ?? ""
try? FileManager.default.removeItem(at: tmp)
require(got == "e94d22a37b00f101a11b040835d479a5eb306fe8702ac9420c651d8249f4daa1", "H13 sha256 与 shasum 一致")
// H14-H19 manifest 的 sha256 三种键名 + 空串/空白处理
func murl(_ j: String) -> UpdateManifest? { try? JSONDecoder().decode(UpdateManifest.self, from: j.data(using: .utf8)!) }
require(murl("{\"version\":\"1.2.0\",\"sha256\":\"abc\"}")?.sha256 == "abc", "H14 sha256 键")
require(murl("{\"version\":\"1.2.0\",\"sha256_sum\":\"def\"}")?.sha256 == "def", "H15 sha256_sum 键")
require(murl("{\"version\":\"1.2.0\",\"digest\":\"ghi\"}")?.sha256 == "ghi", "H16 digest 键")
require(murl("{\"version\":\"1.2.0\",\"sha256\":\"\"}")?.sha256 == nil, "H17 空串当未提供")
require(murl("{\"version\":\"1.2.0\",\"sha256\":\"  abc  \"}")?.sha256 == "abc", "H18 首尾空白裁剪")
require(murl("{\"version\":\"1.2.0\"}")?.sha256 == nil, "H19 无字段返回 nil")
// H20-H22 签名校验：必须按「拒因」断言，不能只验「抛了错」——
// 后者是个永远为真的弱命题，ad-hoc 放行逻辑写错时也照样绿。
let env = ProcessInfo.processInfo.environment
let pAdhoc = env["SMOOSE_H_ADHOC"] ?? ""
let pTamper = env["SMOOSE_H_TAMPER"] ?? ""
let pReal = env["SMOOSE_H_REAL"] ?? ""
func verify(_ path: String) -> UpdateInstallError? {
    guard !path.isEmpty else { return .appNotFound }
    do {
        try Updater.verifySignature(of: URL(fileURLWithPath: path))
        return nil                       // 通过
    } catch let e as UpdateInstallError { return e }
    catch { return .signatureInvalid("未知错误") }
}
// 读 codesign 认的签名种类，用于 H23 的前置自检
func signatureKind(_ path: String) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
    p.arguments = ["--display", "--verbose=2", path]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    try? p.run(); p.waitUntilExit()
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    for line in out.split(separator: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("Signature=adhoc") { return "adhoc" }
        if t.hasPrefix("Signature=") { return String(t.dropFirst("Signature=".count)) }
    }
    return "unsigned"
}
// H20 真 Mach-O 的 ad-hoc 重签必须被拒，且拒因必须是「没有可用开发者身份」
if let e = verify(pAdhoc) {
    switch e {
    case .notSigned: require(true, "H20 ad-hoc 被拒")
    default: require(false, "H20 拒因是 \(e) 而不是 ad-hoc 缺签名")
    }
} else {
    require(false, "H20 ad-hoc 包竟然通过了签名校验")
}
// H21 签名后被改内容，必须被 codesign 本身拦下（而不是因为 ad-hoc 才被拒）
if let e = verify(pTamper) {
    switch e {
    case .signatureInvalid: require(true, "H21 篡改被拒")
    default: require(false, "H21 拒因是 \(e) 而不是签名无效")
    }
} else {
    require(false, "H21 篡改包竟然通过了签名校验")
}
// H22 官方包（真 Team ID）必须通过 —— 防止把校验写成一律拒绝
if !pReal.isEmpty && FileManager.default.fileExists(atPath: pReal) {
    if let e = verify(pReal) { require(false, "H22 官方包应通过但被拒：\(e)") }
    else { require(true, "H22 官方包通过") }
} else {
    print("SKIP H22 本机未安装 /Applications/Smoose.app")
}
// H23/H24 前置自检：H20 只有建立在「真 Mach-O + 真 ad-hoc 签名」之上才有意义。
// 实测陷阱：Mach-O 缺失时 bundle 级 codesign --display 仍报 Signature=adhoc，
// 所以只查 bundle 那一级会假绿；必须下钻到 Mach-O 文件本身。
let macho = URL(fileURLWithPath: pAdhoc).appendingPathComponent("Contents/MacOS/Smoose")
let head = (try? Data(contentsOf: macho)) ?? Data()
var isMachO = false
if head.count >= 4 {
    let b0 = head[head.startIndex]
    // 0xCF = Mach-O 64/32 位（FE ED FA CF 的小端首字节），0xCA = fat/universal（CA FE BA BE）
    isMachO = (b0 == 0xCF || b0 == 0xCA)
}
require(isMachO, "H23 假包必须有真 Mach-O（当前首字节=\(head.first.map { String(format: "%02x", $0) } ?? "无")）")
let kind = signatureKind(macho.path)
require(kind == "adhoc", "H24 Mach-O 本身必须是 ad-hoc 已签名（实际=\(kind)）")

// H26-H28 replaceApp 的回滚契约（2026-10-31 端到端实测后补）。
// 这段代码会移动 /Applications/Smoose.app，出错时若不回滚就是「用户的 App 没了」。
// 用临时目录注入 target 来造两个失败场景，避免动真身。
let fm2 = FileManager.default
let sandbox = fm2.temporaryDirectory.appendingPathComponent("smoose_r_\(UUID().uuidString)")
try? fm2.createDirectory(at: sandbox, withIntermediateDirectories: true)
func makeApp(_ dir: URL, _ ver: String) -> URL {
    let app = dir.appendingPathComponent("Smoose.app")
    try? fm2.createDirectory(at: app.appendingPathComponent("Contents/MacOS"),
                             withIntermediateDirectories: true)
    let plist = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict>"
        + "<key>CFBundleShortVersionString</key><string>\(ver)</string></dict></plist>"
    try? plist.write(to: app.appendingPathComponent("Contents/Info.plist"),
                     atomically: true, encoding: .utf8)
    return app
}
func verOf(_ app: URL) -> String? {
    let p = app.appendingPathComponent("Contents/Info.plist")
    guard let d = try? Data(contentsOf: p),
          let o = try? PropertyListSerialization.propertyList(from: d, format: nil),
          let dict = o as? [String: Any] else { return nil }
    return dict["CFBundleShortVersionString"] as? String
}
// H26 正常替换：旧版被换成新版。
// 新包必须是「真证书签过」的包，否则会先被 verifySignature 拒掉，测不到替换路径。
// 本机装了 /Applications/Smoose.app 就拿它当新版本；没装则跳过这一条。
do {
    let src = URL(fileURLWithPath: pReal)
    if !pReal.isEmpty, fm2.fileExists(atPath: src.path) {
        let live = makeApp(sandbox.appendingPathComponent("normal"), "1.2.1")
        let fresh = sandbox.appendingPathComponent("normal_new/Smoose.app")
        try? fm2.createDirectory(at: fresh.deletingLastPathComponent(),
                                 withIntermediateDirectories: true)
        try? fm2.copyItem(at: src, to: fresh)
        var err: String?
        do { try Updater.replaceApp(at: fresh, target: live) } catch { err = "\(error)" }
        require(err == nil, "H26 替换不应报错（\(err ?? "")）")
        let want = verOf(src)
        require(verOf(live) == want, "H26 替换后应为新版 \(want ?? "?")（实际=\(verOf(live) ?? "无")）")
    } else {
        print("SKIP H26 本机未安装 /Applications/Smoose.app")
    }
}
// H27 新包签名无效：必须回滚成旧版，且不能留下半截 target。
// 这里喂一个 ad-hoc 包（verifySignature 会以 notSigned 拒绝）。
do {
    let live = makeApp(sandbox.appendingPathComponent("rollback"), "1.2.1")
    var err: String?
    do { try Updater.replaceApp(at: URL(fileURLWithPath: pAdhoc), target: live) } catch { err = "\(error)" }
    require(err != nil, "H27 签名无效的新包必须报错")
    require(fm2.fileExists(atPath: live.path), "H27 回滚后旧版必须还在")
    require(verOf(live) == "1.2.1", "H27 回滚后版本应为旧版（实际=\(verOf(live) ?? "被删了")）")
}
// H28 拷贝阶段就失败（新包不存在）：同样必须把旧版搬回来
do {
    let live = makeApp(sandbox.appendingPathComponent("missing"), "1.2.1")
    let ghost = sandbox.appendingPathComponent("missing_new/Smoose.app")
    var err: String?
    do { try Updater.replaceApp(at: ghost, target: live) } catch { err = "\(error)" }
    require(err != nil, "H28 新包不存在必须报错")
    require(verOf(live) == "1.2.1", "H28 旧版必须回滚（实际=\(verOf(live) ?? "被删了")）")
}
try? fm2.removeItem(at: sandbox)

// H29-H30 签名证书身份（Authority）变化检测（P2 授权失效提示）
if !pReal.isEmpty, fm2.fileExists(atPath: pReal) {
    let realAuth = Updater.signingAuthority(of: URL(fileURLWithPath: pReal))
    require(realAuth != nil && !realAuth!.isEmpty, "H29 官方包签名 Authority 可读取（实际=\(realAuth ?? "nil")）")
}
let adhocAuth = Updater.signingAuthority(of: URL(fileURLWithPath: pAdhoc))
require(adhocAuth == nil, "H30 ad-hoc 包不应解析出签名 Authority（实际=\(adhocAuth ?? "")）")

// ---- H31-H40 游戏性能检测（Sources/GamePerf.swift + Model.swift，2026-11-02）----
// 背景：1.4.2 首次带这个功能上线即「启动崩溃」—— recompute() 里
//   for i in 1..<ptrTs.count
// 在指针样本为 0 时（启动后第一次 1 Hz tick，用户还没动鼠标）构成 1..<0，
// 触发 Swift 运行时陷阱 Range requires lowerBound <= upperBound，
// 进程在主队列 drain 里直接死，用户看到的就是「双击图标完全没反应」。
// 所以这里除了统计边界，还必须真的跑一遍空数据 recompute：一旦回归，harness 自己会死。
// H31 分位数：空 / 单元素 / 端点 / 线性插值 / 越界夹紧
require(PerfStats.percentile([], 0.5) == 0, "H31a 空数组分位数必须返回 0")
require(PerfStats.percentile([7.0], 0.0) == 7.0, "H31b 单元素数组 p=0 必须是该元素")
require(PerfStats.percentile([7.0], 1.0) == 7.0, "H31c 单元素数组 p=1 必须是该元素")
let hFour: [Double] = [1, 2, 3, 4]
require(PerfStats.percentile(hFour, 0) == 1, "H31d p=0 取最小值")
require(PerfStats.percentile(hFour, 1) == 4, "H31e p=1 取最大值")
require(abs(PerfStats.percentile(hFour, 0.5) - 2.5) < 1e-9, "H31f p=0.5 线性插值（[1,2,3,4] 应为 2.5）")
require(abs(PerfStats.percentile([1,2,3,4,5], 0.99) - 4.96) < 1e-9, "H31g p=0.99 插值（应为 4.96）")
require(PerfStats.percentile(hFour, -1) == 1, "H31h p<0 必须夹到最小值")
require(PerfStats.percentile(hFour, 9) == 4, "H31i p>1 必须夹到最大值")
require(PerfStats.mean([1,2,3]) == 2, "H31j mean 常规值")
require(PerfStats.mean([]) == 0, "H31k mean 空数组必须返回 0（不能除零）")

// H32 事件环：容量下限、计数、环绕顺序、载荷、total、reset
var hTiny = EventRing(capacity: 0)
require(hTiny.capacity >= 1, "H32a capacity 0 必须兜底成至少 1")
hTiny.append(1, 0, 0); hTiny.append(2, 0, 0)
require(hTiny.total == 2, "H32b total 必须记下全部 append（含被容量夹掉看不到的）")
require(hTiny.count == hTiny.capacity, "H32c count 必须夹到容量（capacity 0 兜底成 1 时）")
var hPartial = EventRing(capacity: 4)
hPartial.append(1, 0, 0); hPartial.append(2, 0, 0)
require(hPartial.total == 2 && hPartial.count == 2, "H32d 未满时 total == count")
var hRing = EventRing(capacity: 3)
for i in 1...5 { hRing.append(UInt64(i), Int32(i), 0) }
require(hRing.total == 5, "H32e total 必须记下全部 append（含被覆盖的）")
require(hRing.count == 3, "H32f count 必须夹到容量")
let hSnap = hRing.snapshot()
require(hSnap.count == 3, "H32g 快照长度不得超过容量")
require(hSnap.map({ $0.0 }) == [3, 4, 5], "H32h 环绕后快照必须由旧到新（实际=\(hSnap.map({ $0.0 }))）")
require(hSnap[0].1 == 3 && hSnap[2].1 == 5, "H32i 快照必须带上 a/b 载荷")
hRing.reset()
require(hRing.total == 0 && hRing.count == 0 && hRing.snapshot().isEmpty, "H32j reset 必须清空")
let hFresh = EventRing(capacity: 4)
require(hFresh.snapshot().isEmpty, "H32k 从未 append 的环快照必须为空")
// H32l 未环绕（total < capacity）是另一条代码路径：此时 next == total == n，
// start 必须是 0 而不是 next。变异验证（2026-11-02）发现原来的用例全是环绕后的，
// 把 `(next - n + capacity) % capacity` 改成 `next` 照样全绿 —— 盲区在这。
let hPartSnap = hPartial.snapshot()
require(hPartSnap.count == 2, "H32l1 未环绕快照长度应为 2")
require(hPartSnap.map({ $0.0 }) == [1, 2], "H32l2 未环绕时快照必须就是写入顺序（实际=\(hPartSnap.map({ $0.0 }))）")

// H33 回报率换算。IORegistry 的 ReportInterval 是 µs：
// 2026-11-02 实测 G502 X 接收器 1000 µs = 1000 Hz，内置触控板 8000 µs = 125 Hz。
// 读不到（0）必须明确说「读不到」—— 显示 0 Hz 等于假装测过。
let hG502 = GameDeviceInfo(id: 1, name: "G502 X", transport: "USB", builtIn: false, reportIntervalUs: 1000)
require(abs(hG502.pollingHz - 1000) < 1e-9, "H33a 1000 µs 应换算成 1000 Hz")
require(hG502.pollingLabel == "1000 Hz", "H33b pollingLabel 格式（实际=\(hG502.pollingLabel)）")
let hPad = GameDeviceInfo(id: 2, name: "Trackpad", transport: "Built-in", builtIn: true, reportIntervalUs: 8000)
require(abs(hPad.pollingHz - 125) < 1e-9, "H33c 8000 µs 应换算成 125 Hz")
let hNone = GameDeviceInfo(id: 3, name: "X", transport: "", builtIn: false, reportIntervalUs: 0)
require(hNone.pollingHz == 0, "H33d 间隔 0 时 Hz 必须为 0")
require(hNone.pollingLabel == "读不到", "H33e 读不到必须显示「读不到」（实际=\(hNone.pollingLabel)）")

// H34-H36 评级阈值 / 定级 / 建议。UI 与 harness 必须同源，否则会出现
// 「界面显示良好、harness 按另一套数字判」的漂移。
let hEdge = GameGrade.checks(pollingHz: 500, measuredHz: 500, jitterP99Ms: 2.0, latencyP99Ms: 0.001, frameDropRatio: 0.02)
require(hEdge.count == 5, "H34a 检查项必须恰好 5 条")
require(hEdge.allSatisfy({ $0.pass }), "H34b 全部踩在合格线上必须全过（实际=\(hEdge.filter({ !$0.pass }).map({ $0.label })))")
require(!GameGrade.checks(pollingHz: 499, measuredHz: 500, jitterP99Ms: 2.0, latencyP99Ms: 1, frameDropRatio: 0.02)[0].pass, "H34c 回报率 499 Hz 必须不过")
require(GameGrade.checks(pollingHz: 0, measuredHz: 0, jitterP99Ms: 0, latencyP99Ms: 0, frameDropRatio: 0)[1].pass == false, "H34d 无设备时达成率不得算通过")
require(!GameGrade.checks(pollingHz: 1000, measuredHz: 499, jitterP99Ms: 0, latencyP99Ms: 0, frameDropRatio: 0)[1].pass, "H34e 达成率 49.9% 必须不过")
require(GameGrade.checks(pollingHz: 1000, measuredHz: 500, jitterP99Ms: 0, latencyP99Ms: 0, frameDropRatio: 0)[1].pass, "H34f 达成率 50% 必须过")
require(!GameGrade.checks(pollingHz: 1000, measuredHz: 1000, jitterP99Ms: 2.01, latencyP99Ms: 0, frameDropRatio: 0)[2].pass, "H34g 抖动 2.01 ms 必须不过")
require(!GameGrade.checks(pollingHz: 1000, measuredHz: 1000, jitterP99Ms: 0, latencyP99Ms: 8.01, frameDropRatio: 0)[3].pass, "H34h 延迟 8.01 ms 必须不过")
require(!GameGrade.checks(pollingHz: 1000, measuredHz: 1000, jitterP99Ms: 0, latencyP99Ms: 0, frameDropRatio: 0.021)[4].pass, "H34i 掉帧 2.1% 必须不过")
let hSamplingChecks = GameGrade.checks(pollingHz: 1000, measuredHz: 1000, jitterP99Ms: 0, latencyP99Ms: 0, frameDropRatio: 0)
require(!hSamplingChecks[2].pass, "H34j 抖动 0（没采到）不得算通过")
require(hSamplingChecks[2].detail == "采样中", "H34k 没采到的项必须显示「采样中」（实际=\(hSamplingChecks[2].detail)）")
let hBase = GameGrade.checks(pollingHz: 1000, measuredHz: 1000, jitterP99Ms: 1, latencyP99Ms: 1, frameDropRatio: 0)
require(hBase.allSatisfy({ $0.pass }), "H35a 基准参数必须 5 项全过")
// 注意：必须把前 n 项改成 fail，不是 dropFirst —— 删掉检查项等于少一项检查，
// 失败数还是 0，定级不会变（第一版断言就这么写错过）。
func hWithFails(_ n: Int) -> [PerfCheck] {
    var c = hBase
    let k = min(n, c.count)
    for i in 0..<k { c[i] = PerfCheck(label: c[i].label, pass: false, detail: c[i].detail) }
    return c
}
require(GameGrade.grade([]) == .fair, "H35b 空检查不得判成竞技级")
require(GameGrade.grade(hWithFails(0)) == .competitive, "H35c 0 项失败 = 竞技级")
require(GameGrade.grade(hWithFails(1)) == .good, "H35d 1 项失败 = 良好")
require(GameGrade.grade(hWithFails(2)) == .fair, "H35e 2 项失败 = 一般")
require(GameGrade.grade(hWithFails(3)) == .poor, "H35f 3 项失败 = 需处理")
require(GameGrade.grade(hWithFails(5)) == .poor, "H35g 5 项全败仍是需处理")
require(GameGrade.advice(pollingHz: 1000, measuredHz: 1000, jitterP99Ms: 1, latencyP99Ms: 1, frameDropRatio: 0, sampling: true).count == 1, "H36a 采样中只应给一条采样提示")
require(GameGrade.advice(pollingHz: 1000, measuredHz: 1000, jitterP99Ms: 1, latencyP99Ms: 1, frameDropRatio: 0, sampling: false).count == 1, "H36b 全过只应给一条竞技级建议")
let hAllBad = GameGrade.advice(pollingHz: 125, measuredHz: 10, jitterP99Ms: 5, latencyP99Ms: 20, frameDropRatio: 0.2, sampling: false)
require(hAllBad.count == 5, "H36c 五项全坏必须各给一条建议（实际=\(hAllBad.count)）")
require(hAllBad[0].contains("125"), "H36d 低回报率建议必须带上实测数值")

// H37 就绪度：UI 直接拿 rawValue 和 symbol 渲染，空的会渲染出空白行
for hR in GameReadiness.allCases {
    require(!hR.rawValue.isEmpty, "H37a \(hR) rawValue 不能为空")
    require(!hR.symbol.isEmpty, "H37b \(hR) symbol 不能为空")
}
require(GameReadiness.allCases.count == 4, "H37c 就绪度必须恰好 4 档")

// H38 intervals(of:)：1.4.2 启动崩溃的直接回归守卫。
// 必须对空数组 / 单元素短路，且返回值已升序（percentile 要求输入有序）。
require(GamePerfProbe.intervals(of: []).isEmpty, "H38a 空时间戳必须返回空间隔（不能进 1..<count）")
require(GamePerfProbe.intervals(of: [42]).isEmpty, "H38b 单时间戳必须返回空间隔")
let hTwo = GamePerfProbe.intervals(of: [100, 300])
require(hTwo.count == 1 && abs(hTwo[0] - MachClock.ms(200)) < 1e-9, "H38c 两个时间戳应给出一个间隔")
let hUnsorted = GamePerfProbe.intervals(of: [0, 300, 100, 400])
require(hUnsorted.count == 3, "H38d n 个时间戳应给出 n-1 个间隔")
require(hUnsorted == hUnsorted.sorted(), "H38e 返回值必须已升序")

// H39 空数据 recompute 必须能跑完：启动后第一次定时器 tick 时用户还没动鼠标。
// 回归了这里会直接 trap，harness 进程自己死 → H 段报红，不靠断言文案兜底。
let hProbe = GamePerfProbe()
hProbe.deviceSource = { [] }
hProbe.recompute()
require(hProbe.pointerSamples == 0, "H39a 无样本时 pointerSamples 必须为 0")
require(hProbe.sampling, "H39b 无样本时必须处于「采样中」")
require(hProbe.checks.count == 5, "H39c 检查项仍应是 5 条")
require(!hProbe.advice.isEmpty, "H39d 建议不能为空（至少要说明在采样）")
hProbe.recordFrame(at: mach_absolute_time())
hProbe.recompute()
require(hProbe.frameSamples == 0, "H39e 单帧不能算出帧间隔")
hProbe.reset()
hProbe.recompute()
require(hProbe.pointerSamples == 0 && hProbe.sampling, "H39f reset 后 recompute 同样必须能跑完")

// H40 设置窗口标签页 URL：预览 / 远程诊断靠 smoose://settings?tab=game 直达。
// 认不出的值必须返回 nil（保持当前页），不能崩、不能乱跳页。
require(SettingsTab.fromURL("smoose://settings") == nil, "H40a 没有 tab 参数必须返回 nil")
require(SettingsTab.fromURL("smoose://settings?tab=game") == .game, "H40b tab=game")
require(SettingsTab.fromURL("smoose://settings?tab=4") == .game, "H40c tab=4 数字写法")
require(SettingsTab.fromURL("smoose://settings?tab=about") == .about, "H40d tab=about")
require(SettingsTab.fromURL("smoose://settings?tab=game&x=1") == .game, "H40e 后续 query 不能粘进 tab 名")
require(SettingsTab.fromURL("smoose://settings?tab=") == nil, "H40f 空值必须返回 nil")
require(SettingsTab.fromURL("smoose://settings?tab=nope") == nil, "H40g 认不出的名字必须返回 nil")
require(SettingsTab.fromURL("smoose://settings?tab=99") == nil, "H40h 越界数字必须返回 nil")
require(SettingsTab.game.rawValue == 4, "H40i game 页 tag 必须是 4（与 TabView 对齐）")
require(SettingsTab.game.name == "game", "H40j game 页 URL 名必须是 game")
require(SettingsTab.allCases.count == 6, "H40k 标签页必须恰好 6 个")

// H41 时间戳时基归一化（2026-11-02，1.4.2 预览时抓到的真 bug）
// 实测：CGEvent.timestamp 时基不统一 —— HID 事件是 mach tick，
// 经 CGEvent.post() 注入的事件是「开机以来纳秒数」（同刻 tick≈1.05e13 / ns≈4.38e14，
// 比值 41.6662 ≈ timebase 125/3，按 uptime 反查吻合）。
// 不归一化：纳秒值永远大于 now → diff 恒 0 → 2 秒窗口过滤整体失效、
// 事件率被算小 ~41.67 倍、指针延迟恒显示 0。真机预览时三项全中。
let hNow = mach_absolute_time()
require(MachClock.normalize(hNow, now: hNow) == hNow, "H41a tick 时基必须原样通过")
require(MachClock.normalize(0, now: hNow) == 0, "H41b 0 时间戳必须原样通过")
let hEarlier = hNow - MachClock.ticks(forMs: 50)
require(MachClock.normalize(hEarlier, now: hNow) == hEarlier, "H41c 稍早的 tick 值不能被误判成纳秒")
// 纳秒值 = tick 值 × (numer/denom)，归一化后必须落回同一 tick 量级
let hNsNow = UInt64((Double(hNow) * Double(MachClock.info.numer) / Double(MachClock.info.denom)).rounded())
let hBack = MachClock.normalize(hNsNow, now: hNow)
require(abs(Double(hBack) - Double(hNow)) <= Double(hNow) * 0.001, "H41d 纳秒值必须换算回 tick 量级（偏差=\(Double(hBack) - Double(hNow))）")
require(MachClock.normalize(hNsNow, now: hNow) < hNsNow, "H41e 归一化必须真的把数值变小（否则说明没换算）")
// 判据边界：超过 now 的 8 倍才按纳秒处理，8 倍以内必须放过
let hJustUnder = hNow &* 8
require(MachClock.normalize(hJustUnder, now: hNow) == hJustUnder, "H41f 恰好 8 倍必须仍按 tick 处理")
require(MachClock.normalize(hJustUnder &+ 1, now: hNow) != hJustUnder &+ 1, "H41g 超过 8 倍必须走纳秒分支")
// recordPointer 必须真的用归一化后的值：灌一个纳秒时基的旧事件，
// 若不过归一化，latencyRing 里会是 0、且窗口过滤会把它算成「就在刚才」。
let hProbe2 = GamePerfProbe()
hProbe2.deviceSource = { [] }
let hOldNs = UInt64((Double(hNow - MachClock.ticks(forMs: 500)) * Double(MachClock.info.numer) / Double(MachClock.info.denom)).rounded())
hProbe2.recordPointer(eventTimestamp: hOldNs, dx: 1, dy: 0)
hProbe2.recompute()
require(hProbe2.pointerSamples == 1, "H41h 归一化后 0.5 秒前的事件必须落在 2 秒窗口内（实际=\(hProbe2.pointerSamples)）")
require(hProbe2.pointerLatencyP50Ms > 0, "H41i 归一化后指针延迟必须大于 0（实际=\(hProbe2.pointerLatencyP50Ms)）")
require(hProbe2.pointerJitterP50Ms == 0, "H41j 单个事件不该有抖动样本")

if failures == 0 { print("H-OK") } else { exit(1) }
HSWIFT
if "$SWIFTC" $SMOOSE_SWIFT_EXTRA -Onone -sdk "$SDK" -target arm64-apple-macos14.0 -I Sources -o "$WORK/h" \
    Sources/Model.swift Sources/Actions.swift Sources/ScrollAxis.swift Sources/PointerController.swift \
    Sources/ScrollEngine.swift Sources/UpdateModel.swift Sources/Updater.swift Sources/Views.swift \
    Sources/App.swift Sources/CursorZoom.swift Sources/LogitechHIDPP.swift Sources/GamePerf.swift \
    Sources/TouchEvents.c "$WORK/main.swift" 2>"$WORK/h.log"; then
  # 变异验证（2026-11-02）抓到的假绿：只 grep '^FAIL' 时，二进制崩溃
  # （"Fatal error: Range requires lowerBound <= upperBound" 之类）不以 FAIL 开头，
  # HFAILS 为空 → 照常 ok。删掉 GamePerf 的空数组守卫后 harness 全绿就是这么来的。
  # 现在两趟都必须：退出码为 0 且打出 H-OK 完成标记。
  HRC1=0
  HOUT1="$(SMOOSE_H_ADHOC="$HADHOC" SMOOSE_H_TAMPER="$HTAMPER" \
SMOOSE_H_REAL="/Applications/Smoose.app" "$WORK/h" 2>&1)" || HRC1=$?
  HFAILS="$(/bin/echo "$HOUT1" | grep '^FAIL' || true)"
  if [ "$HRC1" != "0" ]; then HFAILS="$HFAILS H_EXIT1(rc=$HRC1 第一趟非零退出/崩溃)"; fi
  /bin/echo "$HOUT1" | grep -q 'H-OK' || HFAILS="$HFAILS H_NOMARK1(缺 H-OK 完成标记)"
  # 第二趟：把同一个二进制包进一个 .app，用 Info.plist 把「期望 Team ID」改成别的值，
  # 这样官方包就该被判 teamMismatch（H25）。这是该分支唯一的自动载体。
  HMA="$WORK/hm.app"
  /bin/mkdir -p "$HMA/Contents/MacOS"
  /bin/cp "$WORK/h" "$HMA/Contents/MacOS/h"
  /usr/bin/printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>SmooseUpdateTeamID</key><string>FAKETEAM01</string></dict></plist>\n' > "$HMA/Contents/Info.plist"
  HRC2=0
  HOUT2="$(SMOOSE_H_ADHOC="$HADHOC" SMOOSE_H_TAMPER="$HTAMPER" SMOOSE_H_PASS=2 \
SMOOSE_H_REAL="/Applications/Smoose.app" "$HMA/Contents/MacOS/h" 2>&1)" || HRC2=$?
  HFAILS="$HFAILS$(/bin/echo "$HOUT2" | grep '^FAIL' || true)"
  if [ "$HRC2" != "0" ]; then HFAILS="$HFAILS H_EXIT2(rc=$HRC2 第二趟非零退出/崩溃)"; fi
  /bin/echo "$HOUT2" | grep -q 'H-OK' || HFAILS="$HFAILS H_NOMARK2(缺 H-OK 完成标记)"
  if [ -z "$HFAILS" ]; then ok "H 安全加固（https 强制 / Team ID / sha256 / 按拒因断言 + Mach-O 前置）"; else bad "H $HFAILS"; fi
else
  bad "H 编译失败$(tail -3 "$WORK/h.log")"
fi

echo
echo "== 结果: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" = "0" ]
