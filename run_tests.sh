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

# S31 指针配置通知：persist() 必须真的发通知，用户拖滑条不能等下一个轮询周期。
#
# 2026-11-06 契约改写：原来 S31g 要求「兜底轮询 ≥ 30 秒」，因为那时每轮都会全量
# 枚举 IOKit。现在枚举改由 IOHIDManager 插拔回调驱动，轮询只做「读属性 + 对漂移设备
# 重写」，于是要求反过来 —— 必须足够短才能及时纠正 macOS 把 HIDMouseAcceleration
# 重置回默认（静置后起步发黏的根因，见 I 段）。守卫随之改成卡新的三件事：
# 周期 ≤ 10s、轮询不碰全量枚举、插拔回调确实注册了。
PC_SRC="$ROOT/Sources/PointerController.swift"
MD_SRC="$ROOT/Sources/Model.swift"
S31FAILS=""
/bin/echo "$(cat "$MD_SRC")" | /usr/bin/grep -q 'smoosePointerConfigChanged' || S31FAILS="$S31FAILS S31a"
/bin/echo "$(cat "$MD_SRC")" | /usr/bin/grep -q 'post(name: .smoosePointerConfigChanged' || S31FAILS="$S31FAILS S31b"
/bin/echo "$(cat "$MD_SRC")" | /usr/bin/grep -q 'lastPersistedPointerSignature' || S31FAILS="$S31FAILS S31c"
/bin/echo "$(cat "$PC_SRC")" | /usr/bin/grep -q 'addObserver(forName: .smoosePointerConfigChanged' || S31FAILS="$S31FAILS S31d"
# 签名判空必须有：没判空的话每次 persist（哪怕改的是滚动参数）都会重发通知 → 又变回轮询
/bin/echo "$(cat "$MD_SRC")" | /usr/bin/grep -q 'pointerSig != lastPersistedPointerSignature' || S31FAILS="$S31FAILS S31e"
POLLSEC="$(/bin/echo "$(cat "$PC_SRC")" | /usr/bin/sed -nE 's/.*scheduledTimer\(withTimeInterval: ([0-9.]+).*/\1/p')"
if [ -z "$POLLSEC" ]; then S31FAILS="$S31FAILS S31f"; fi
if [ -n "$POLLSEC" ]; then
  # 周期必须够短：30/60 秒会让「系统重置加速度」的窗口长到用户以为鼠标坏了
  /usr/bin/awk -v v="$POLLSEC" 'BEGIN { exit !(v+0 > 0 && v+0 <= 10.0) }' || S31FAILS="$S31FAILS S31g"
fi
# 轮询里必须是 apply(force:false)（只读属性），不是 refresh（全量枚举）
/bin/echo "$(cat "$PC_SRC")" | /usr/bin/grep -q 'self.apply(force: false)' || S31FAILS="$S31FAILS S31h"
# 设备插拔 / 重枚举必须有事件驱动，不能只靠轮询
/bin/echo "$(cat "$PC_SRC")" | /usr/bin/grep -q 'IOHIDManagerRegisterDeviceMatchingCallback' || S31FAILS="$S31FAILS S31i"
/bin/echo "$(cat "$PC_SRC")" | /usr/bin/grep -q 'IOHIDManagerRegisterDeviceRemovalCallback' || S31FAILS="$S31FAILS S31j"
# 签名必须纳入设备实际读数（I 段有行为级断言，这里只是防误删的文本守卫）
/bin/echo "$(cat "$PC_SRC")" | /usr/bin/grep -q 'PointerAccelSignature.make' || S31FAILS="$S31FAILS S31k"
if [ -z "$S31FAILS" ]; then ok "S31 指针配置事件驱动（通知 / 短轮询 / 插拔回调 / 读数签名）"; else bad "S31$S31FAILS"; fi

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
# 2026-11-06 起每个页都包一层 ScaledTabContent（窗口放大时等比缩放），
# 守卫跟着改成校验「缩放容器 + 标签 + tag」三者仍绑在同一页上，不是放宽成只查关键词。
/bin/echo "$VIEWSNC" | /usr/bin/grep -qE 'ScaledTabContent \{ GamePerfTab\(\) \}\.tabItem \{ Label\("游戏", systemImage: "gamecontroller"\) \}\.tag\(4\)' || S35FAILS="$S35FAILS S35c"
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

echo "== S36-S39: 合成事件相位 / 点击刹车（2026-11-03，移植 Mos ScrollPhase + ScrollPoster）=="
# 背景：Smoose 早期合成的滚动事件 isContinuous=0、scrollPhase=0、momentumPhase=0，
# 消费端（Chrome / Safari / 原生控件）看到的是「物理滚轮 + 像素增量」，于是套用自己的
# 行量化与动量，Smoose 的曲线被二次加工 —— 同一条曲线在 Mos 里更跟手的根因之一。
# 本轮移植 Mos 的两件事：① 合成事件带相位（isContinuous=1 + scroll/momentum phase +
# 收尾帧）；② 左键点击立刻刹车收掉尾巴（含未走完的距离）。
# 逻辑全部落在纯函数 / 纯结构体里（ScrollPhases.swift + ScrollAxis.brake），
# 所以这里编译真源码直接断言，不需要逻辑副本。
S36DIR="$WORK/s36dir"
/bin/mkdir -p "$S36DIR"
/bin/cat > "$S36DIR/main.swift" <<'S36SWIFT'
import Foundation
var failures = 0
func require(_ c: Bool, _ label: String) { if !c { print("FAIL \(label)"); failures += 1 } }
func requireEq<T: Equatable>(_ a: T?, _ b: T?, _ label: String) {
    if a != b { print("FAIL \(label): got \(String(describing: a)) want \(String(describing: b))"); failures += 1 }
}

// ---- S36 相位常量 + 字段写入 ----
requireEq(ScrollPhaseValue.trackingBegan, ScrollPhaseValue(scroll: 1, momentum: 0), "S36a trackingBegan 必须是 scroll=1")
requireEq(ScrollPhaseValue.trackingChanged, ScrollPhaseValue(scroll: 2, momentum: 0), "S36b trackingChanged 必须是 scroll=2")
requireEq(ScrollPhaseValue.trackingEnded, ScrollPhaseValue(scroll: 4, momentum: 0), "S36c trackingEnded 必须是 scroll=4")
requireEq(ScrollPhaseValue.momentumBegan, ScrollPhaseValue(scroll: 0, momentum: 1), "S36d momentumBegan 必须是 momentum=1")
requireEq(ScrollPhaseValue.momentumChanged, ScrollPhaseValue(scroll: 0, momentum: 2), "S36e momentumChanged 必须是 momentum=2")
requireEq(ScrollPhaseValue.momentumEnded, ScrollPhaseValue(scroll: 0, momentum: 3), "S36f momentumEnded 必须是 momentum=3")
// 关闭开关时必须全 0：这是「关掉 = 与老版本逐字节一致」的契约，写错会让
// 关掉开关的用户突然收到带相位的事件，行为静默改变。
requireEq(ScrollPhaseFields.write(simulateTrackpad: false, phase: .trackingBegan), SyntheticScrollFields.none, "S36g 关闭时三个字段必须全 0")
requireEq(ScrollPhaseFields.write(simulateTrackpad: true, phase: nil), SyntheticScrollFields.none, "S36h 开启但无相位也必须全 0")
requireEq(ScrollPhaseFields.write(simulateTrackpad: false, phase: .momentumEnded), SyntheticScrollFields(cont: 0, scroll: 0, momentum: 0), "S36g2 关闭惯性帧同样全 0")
let sf1 = ScrollPhaseFields.write(simulateTrackpad: true, phase: .trackingBegan)
require(sf1.cont == 1 && sf1.scroll == 1 && sf1.momentum == 0, "S36i 开启时 cont=1 且相位正确（实际=\(sf1)）")
let sf2 = ScrollPhaseFields.write(simulateTrackpad: true, phase: .momentumEnded)
require(sf2.cont == 1 && sf2.scroll == 0 && sf2.momentum == 3, "S36j 惯性收尾帧字段（实际=\(sf2)）")

// ---- S37 手势相位状态机 ----
var t = ScrollPhaseTracker()
require(t.advance(now: 1.0, posting: false, settled: true).isEmpty, "S37a 空闲时不得发任何相位帧")
require(!t.isActive, "S37b 空闲时 isActive=false")
t.noteInput(now: 1.0)
require(t.isActive, "S37c 有输入后 isActive=true")
var p = t.advance(now: 1.008, posting: true, settled: false)
requireEq(p.body, .trackingBegan, "S37d 手势首帧必须是 trackingBegan")
require(p.end == nil && p.interrupt == nil, "S37e 首帧不该带收尾/打断帧")
t.noteInput(now: 1.05)
p = t.advance(now: 1.058, posting: true, settled: false)
requireEq(p.body, .trackingChanged, "S37f 输入间隔 0.05s 仍是 trackingChanged")
// 输入停下超过 continuationThreshold(0.18) → 惯性段
p = t.advance(now: 1.30, posting: true, settled: false)
requireEq(p.body, .momentumBegan, "S37g 输入停下超过 0.18s 必须转 momentumBegan")
p = t.advance(now: 1.40, posting: true, settled: false)
requireEq(p.body, .momentumChanged, "S37h 惯性持续为 momentumChanged")
p = t.advance(now: 1.45, posting: false, settled: true)
requireEq(p.end, .momentumEnded, "S37i 惯性段收尾必须是 momentumEnded")
require(p.body == nil, "S37j 收尾帧不带增量相位")
require(!t.isActive, "S37k 收尾后必须回到 idle")
require(t.advance(now: 1.46, posting: false, settled: true).isEmpty, "S37l 收尾后不得再发帧")

// 亚像素帧（无增量）不得把 Began 提前消耗掉
var t2 = ScrollPhaseTracker()
t2.noteInput(now: 10.0)
var p2 = t2.advance(now: 10.008, posting: false, settled: false)
require(p2.body == nil, "S37m 无增量的帧不得发 body")
p2 = t2.advance(now: 10.016, posting: true, settled: false)
requireEq(p2.body, .trackingBegan, "S37n 亚像素帧之后首帧仍是 Began（begun 未被消耗）")

// 尾巴没走完又滚 → 先补 MomentumEnd，再开新 Tracking
var t3 = ScrollPhaseTracker()
t3.noteInput(now: 20.0)
_ = t3.advance(now: 20.01, posting: true, settled: false)
_ = t3.advance(now: 20.30, posting: true, settled: false)
t3.noteInput(now: 20.40)
var p3 = t3.advance(now: 20.408, posting: true, settled: false)
requireEq(p3.interrupt, .momentumEnded, "S37o 惯性未走完又滚必须先补 MomentumEnd")
requireEq(p3.body, .trackingBegan, "S37p 补完打断帧再开新 tracking")
require(p3.end == nil, "S37q 重新接管时不得同时收尾")

// 距上次输入超过 separationThreshold(0.45) → 新手势，重新发 Began
t3.noteInput(now: 21.00)
p3 = t3.advance(now: 21.008, posting: true, settled: false)
requireEq(p3.body, .trackingBegan, "S37r 隔太久必须算新手势并重新发 Began")

// 尾巴很短、手指还没离开就到位 → TrackingEnd（不是 MomentumEnd）
var t4 = ScrollPhaseTracker()
t4.noteInput(now: 30.0)
_ = t4.advance(now: 30.008, posting: true, settled: false)
var p4 = t4.advance(now: 30.016, posting: true, settled: true)
requireEq(p4.body, .trackingChanged, "S37s 到位帧仍带增量相位")
requireEq(p4.end, .trackingEnded, "S37t 手指段收尾是 TrackingEnd")
t4.reset()
require(!t4.isActive, "S37u reset 后回到 idle")
require(t4.advance(now: 30.1, posting: true, settled: true).isEmpty, "S37v reset 后不得再发帧")

// ---- S38 点击刹车 ----
var ax = ScrollAxis()
ax.brake()
require(ax.isIdle, "S38a 空轴刹车必须无害")
var ay = ScrollAxis()
ay.push(100)
var emitted = 0
for _ in 0..<3 { emitted += Int(ay.advance(dt: 0.008, tau: 0.05)) }
require(emitted > 0, "S38b 刹车前必须已有增量投递")
require(ay.current < 100, "S38c 刹车前必须还没到位（否则测不到刹车）")
let stoppedAt = ay.current
ay.brake()
require(ay.isIdle, "S38d 刹车后必须 idle")
require(ay.advance(dt: 0.008, tau: 0.05) == 0, "S38e 刹车后不得再投递")
require(ay.current == stoppedAt && ay.target == stoppedAt, "S38f 刹车丢弃剩余距离、停在当前位置")

if failures == 0 { print("S36-OK") } else { exit(1) }
S36SWIFT
if "$SWIFTC" $SMOOSE_SWIFT_EXTRA -Onone -sdk "$SDK" -target arm64-apple-macos14.0 \
    -framework CoreGraphics -o "$WORK/s36" Sources/ScrollAxis.swift Sources/ScrollPhases.swift "$S36DIR/main.swift" 2>"$WORK/s36.log"; then
  S36OUT="$("$WORK/s36" 2>&1 || true)"
  S36FAILS="$(/bin/echo "$S36OUT" | grep '^FAIL' || true)"
  if [ -z "$S36FAILS" ] && /bin/echo "$S36OUT" | grep -q 'S36-OK'; then
    ok "S36-S38 相位常量/字段/状态机/刹车（S36a-j + S37a-v + S38a-f）"
  else
    bad "S36-S38 $S36FAILS"
  fi
else
  bad "S36-S38 编译失败$(tail -3 "$WORK/s36.log")"
fi

# S39 接线守卫：逻辑对了但没接进引擎 = 没做。剥注释后再匹配，
# 否则解释相位历史的注释里本身就含这些代码串，会自我触发。
S39FAILS=""
ENGNC="$(/bin/echo "$(cat "$ROOT/Sources/ScrollEngine.swift")" | /usr/bin/sed -E 's://.*$::')"
APPNC="$(/bin/echo "$(cat "$ROOT/Sources/App.swift")" | /usr/bin/sed -E 's://.*$::')"
VIEWSNC="$(/bin/echo "$(cat "$ROOT/Sources/Views.swift")" | /usr/bin/sed -E 's://.*$::')"
MODELNC="$(/bin/echo "$(cat "$ROOT/Sources/Model.swift")" | /usr/bin/sed -E 's://.*$::')"
/bin/echo "$ENGNC" | /usr/bin/grep -q 'ScrollPhaseFields.write(simulateTrackpad: phase != nil, phase: phase)' || S39FAILS="$S39FAILS S39a(post未写相位字段)"
/bin/echo "$ENGNC" | /usr/bin/grep -q 'event.setDoubleValueField(F.phase, value: fields.scroll)' || S39FAILS="$S39FAILS S39b"
/bin/echo "$ENGNC" | /usr/bin/grep -q 'event.setDoubleValueField(F.momentum, value: fields.momentum)' || S39FAILS="$S39FAILS S39c"
/bin/echo "$ENGNC" | /usr/bin/grep -q 'phaseTracker.advance(now: CACurrentMediaTime(), posting: moved, settled: settled)' || S39FAILS="$S39FAILS S39d(帧循环未推进相位)"
/bin/echo "$ENGNC" | /usr/bin/grep -q 'phaseTracker.noteInput(now: CACurrentMediaTime())' || S39FAILS="$S39FAILS S39e(输入未通知状态机)"
/bin/echo "$ENGNC" | /usr/bin/grep -q 'axisY.brake()' || S39FAILS="$S39FAILS S39f"
/bin/echo "$ENGNC" | /usr/bin/grep -q 'axisX.brake()' || S39FAILS="$S39FAILS S39g"
/bin/echo "$ENGNC" | /usr/bin/grep -q 'activeAppID == "com.apple.dock"' || S39FAILS="$S39FAILS S39h(Launchpad/Dock未透传)"
/bin/echo "$APPNC" | /usr/bin/grep -q 'addGlobalMonitorForEvents(matching: .leftMouseDown)' || S39FAILS="$S39FAILS S39i(没监听左键)"
/bin/echo "$APPNC" | /usr/bin/grep -q 'ScrollEngine.shared.brake()' || S39FAILS="$S39FAILS S39j(左键没接刹车)"
/bin/echo "$VIEWSNC" | /usr/bin/grep -q 'prefs.global.simulateTrackpad' || S39FAILS="$S39FAILS S39k(全局开关没接)"
/bin/echo "$VIEWSNC" | /usr/bin/grep -q 'profile.simulateTrackpad' || S39FAILS="$S39FAILS S39l(每应用开关没接)"
/bin/echo "$MODELNC" | /usr/bin/grep -q 'simulateTrackpad = try c.decodeIfPresent(Bool.self, forKey: .simulateTrackpad) ?? true' || S39FAILS="$S39FAILS S39m(旧配置缺键时未兜底 true)"
if [ -z "$S39FAILS" ]; then ok "S39 引擎/UI/持久化接线（13 项）"; else bad "S39$S39FAILS"; fi

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
    Sources/ScrollPhases.swift \
    Sources/ScrollEngine.swift Sources/UpdateModel.swift Sources/Updater.swift Sources/Views.swift Sources/SettingsLauncher.swift \
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

echo "== I: 加速度接管签名对 HID 参数漂移敏感（2026-11-06，编译真 PointerController.swift）=="
# 背景（用户 2026-11-06 反馈「鼠标静置后再动起步发黏、慢慢恢复正常」）：
# 接管加速度=0 依赖 HID 参数持续保持。鼠标省电挂起 / 重枚举后 macOS 把
# HIDMouseAcceleration 恢复成默认 163840(2.5)，配置值和 registryID 都没变 ——
# 旧签名恰好只由这两样组成，于是 apply(force:false) 永久短路，再也不纠正。
# 实测：罗技接收器两个 HID 接口，一个 0、一个 2.5，且两者都可写。
# I 段验的是「决策输入」（签名），不是端到端 IOKit 写入；后者由真机探针覆盖。
/bin/mkdir -p "$WORK/idir"
/bin/cat > "$WORK/idir/main.swift" <<'ISWIFT'
import Foundation
var failures = 0
func require(_ c: Bool, _ label: String) { if !c { print("FAIL \(label)"); failures += 1 } }

func snap(_ readings: [(rid: UInt64, current: Double?)], value: Double = 0.0,
          managed: Bool = true, include: Bool = true) -> PointerAccelSnapshot {
    PointerAccelSnapshot(managed: managed, value: value,
                         includeBuiltIn: include, readings: readings)
}
func sig(_ s: PointerAccelSnapshot) -> String { PointerAccelSignature.make(s) }

// 实况：用户开了「接管加速度 = 0」，两个 USB Receiver 接口都已正确写成 0
let clean: [(rid: UInt64, current: Double?)] = [
    (rid: 4294972324, current: 0.0), (rid: 4294972593, current: 0.0)]
let cleanSig = sig(snap(clean))

require(cleanSig == sig(snap(clean)), "I1 同输入签名幂等（短路仍有效，不每轮白写）")

// ★核心反例：系统把第二个接口重置成默认 2.5，配置与 rid 完全没变。
// 旧实现在这里返回相同签名 → 永久短路 → 这就是静置后手感变黏的根因。
let drifted: [(rid: UInt64, current: Double?)] = [
    (rid: 4294972324, current: 0.0), (rid: 4294972593, current: 163840.0)]
require(cleanSig != sig(snap(drifted)), "I2 HID 参数漂移必须改变签名（旧 bug 在此假绿）")

let drift1: [(rid: UInt64, current: Double?)] = [
    (rid: 4294972324, current: 163840.0), (rid: 4294972593, current: 0.0)]
require(cleanSig != sig(snap(drift1)), "I3 第一个接口漂移也要能发现")
require(sig(snap(drift1)) != sig(snap(drifted)), "I4 不同接口漂移必须可区分")

require(cleanSig != sig(snap(clean, value: 1.5)), "I5 用户改加速度数值要改变签名")
require(cleanSig != sig(snap(clean, include: false)), "I6 includeBuiltIn 要参与签名")
require(cleanSig != sig(snap(clean, managed: false)), "I7 managed 要参与签名")
require(cleanSig != sig(snap([(rid: 4294972324, current: 0.0)])), "I8 设备减少要改变签名")
require(cleanSig != sig(snap(clean + [(rid: 4294973000, current: 0.0)])), "I9 设备增加要改变签名")

// 设备枚举顺序不稳定不能导致签名抖动，否则每 8 秒都会误判成漂移
require(sig(snap(Array(clean.reversed()))) == cleanSig, "I10 设备顺序无关")

// 读不到参数的设备：稳定、且与「读到 0」不同
let withNil: [(rid: UInt64, current: Double?)] = [
    (rid: 4294972324, current: 0.0), (rid: 4294972593, current: nil)]
require(sig(snap(withNil)) == sig(snap(withNil)), "I11 nil 读数稳定")
require(sig(snap(withNil)) != cleanSig, "I11b nil 与 0 必须区分")

// 小数抖动（IOFixed 换算残差）不能让签名每轮都变
let jitter: [(rid: UInt64, current: Double?)] = [
    (rid: 4294972324, current: 0.4), (rid: 4294972593, current: 0.0)]
require(sig(snap(jitter)) == cleanSig, "I12 亚 1 计数抖动不构成漂移")

// apply() 写完保存的是「全符合期望」的签名；它必须等于全符合时的读数签名，
// 否则下一轮永远不相等 → 每 8 秒白写一次。
let settled: [(rid: UInt64, current: Double?)] = [
    (rid: 4294972324, current: 0.0), (rid: 4294972593, current: 0.0)]
require(sig(snap(settled)) == cleanSig, "I13 期望签名与全符合读数相等（否则短路失效）")
require(sig(snap(settled)) != sig(snap(drifted)), "I14 期望签名仍能抓住漂移")

if failures == 0 { print("I-OK") } else { exit(1) }
ISWIFT
if "$SWIFTC" $SMOOSE_SWIFT_EXTRA -Onone -sdk "$SDK" -target arm64-apple-macos14.0 -I Sources -o "$WORK/i" \
    Sources/Model.swift Sources/Actions.swift Sources/ScrollAxis.swift Sources/PointerController.swift \
    Sources/ScrollPhases.swift \
    Sources/ScrollEngine.swift Sources/UpdateModel.swift Sources/Updater.swift Sources/Views.swift Sources/SettingsLauncher.swift \
    Sources/App.swift Sources/CursorZoom.swift Sources/LogitechHIDPP.swift Sources/GamePerf.swift \
    Sources/TouchEvents.c "$WORK/idir/main.swift" 2>"$WORK/i.log"; then
  IRC=0
  IOUT="$("$WORK/i" 2>&1)" || IRC=$?
  IFAILS="$(/bin/echo "$IOUT" | grep '^FAIL' || true)"
  if [ "$IRC" != "0" ]; then IFAILS="$IFAILS I_EXIT(rc=$IRC 非零退出/崩溃)"; fi
  /bin/echo "$IOUT" | grep -q 'I-OK' || IFAILS="$IFAILS I_NOMARK(缺 I-OK 完成标记)"
  if [ -z "$IFAILS" ]; then ok "I 加速度签名（漂移敏感 / 幂等 / 顺序无关，14 项）"; else bad "I $IFAILS"; fi
else
  bad "I 编译失败$(tail -3 "$WORK/i.log")"
fi

echo "== J: 设置窗口放大后内容等比联动（2026-11-06，编译真 Views.swift）=="
# 背景（用户 2026-11-06 反馈「页面放大以后，内容没放大」）：窗口可 resizable，
# 但根视图只有 minWidth/minHeight，各 Tab 的字号 / 间距 / 420pt 内容宽度全是硬编码点数，
# 于是内容始终按原始点数居中。J 段验的是缩放决策纯函数，不依赖屏幕。
# 设计基准 560×620：620 是「关于」页完整内容的实测高度（按 520 排版会压行 + 裁页脚）。
# 接线守卫：纯函数全绿不代表界面真的用上了。六个页必须都包 ScaledTabContent，
# 且 TabView 必须是根视图 —— 真机验证过，把整个 TabView 包进缩放容器会裁掉系统标签栏。
JVIEWS="$(/bin/echo "$(/bin/cat "$ROOT/Sources/Views.swift")" | /usr/bin/sed -E 's://.*$::')"
JWFAILS=""
NSCALED="$(/bin/echo "$JVIEWS" | /usr/bin/grep -c 'ScaledTabContent {' || true)"
[ "$NSCALED" = "6" ] || JWFAILS="$JWFAILS 缩放容器数=$NSCALED(应为6)"
for t in 0 1 2 3 4 5; do
  /bin/echo "$JVIEWS" | /usr/bin/grep -qF ".tag($t)" || JWFAILS="$JWFAILS 缺tag$t"
done
/bin/echo "$JVIEWS" | /usr/bin/grep -qF 'TabView(selection: $nav.selectedTab)' \
  || JWFAILS="$JWFAILS TabView非根视图"
if [ -z "$JWFAILS" ]; then ok "J_W 六页全部接入缩放且 TabView 保持根视图（接线）"; else bad "J_W$JWFAILS"; fi
/bin/mkdir -p "$WORK/jdir"
/bin/cat > "$WORK/jdir/main.swift" <<'JSWIFT'
import Foundation
var failures = 0
func require(_ c: Bool, _ label: String) { if !c { print("FAIL \(label)"); failures += 1 } }
func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(Double(a - b)) < 1e-9 }

// 旧行为哨兵：修复前「窗口变大、内容恒 1×」。变异验证时把 uiScale 换成它，
// 下面这些断言必须报红，否则就是假绿。
func oldScale(_ w: CGFloat, _ h: CGFloat) -> CGFloat { 1 }

require(near(SettingsLayout.uiScale(width: 560, height: 620), 1), "J1 基准尺寸不放大")
require(near(SettingsLayout.uiScale(width: 1120, height: 1240), 2), "J2 窗口翻倍内容必须翻倍")
let shot = SettingsLayout.uiScale(width: 1080, height: 1002)
require(shot > 1.5 && shot < 2, "J3 大窗口 1080×1002 应放大到约 1.62×")
require(shot != oldScale(1080, 1002), "J4 新缩放必须与旧的恒 1× 行为不同")
// 只变一个方向时不能按那个方向放大 —— 否则另一个方向的内容会被裁掉。
require(near(SettingsLayout.uiScale(width: 1080, height: 620), 1), "J5 只加宽时按高度取 min")
require(near(SettingsLayout.uiScale(width: 560, height: 1002), 1), "J6 只加高时按宽度取 min")
require(near(SettingsLayout.uiScale(width: 4000, height: 4000), 2), "J7 2× 封顶")
require(near(SettingsLayout.uiScale(width: 300, height: 300), 1), "J8 小于基准钳到 1")
require(near(SettingsLayout.uiScale(width: 0, height: 520), 1), "J9 0 宽防御")
require(near(SettingsLayout.uiScale(width: 560, height: -1), 1), "J10 负高防御")

// 关键不变量：logicalSize × s == 窗口尺寸，放大后正好铺满、既不裁切也不留白。
let dims: [(CGFloat, CGFloat)] = [(560, 620), (1080, 1002), (1120, 1240),
                                  (4000, 4000), (1080, 620), (700, 900), (300, 300)]
for (w, h) in dims {
    let s = SettingsLayout.uiScale(width: w, height: h)
    let l = SettingsLayout.logicalSize(width: w, height: h)
    require(near(l.width * s, w), "J11 \(Int(w))×\(Int(h)) 放大后宽度正好铺满")
    require(near(l.height * s, h), "J12 \(Int(w))×\(Int(h)) 放大后高度正好铺满")
    require(l.width >= SettingsLayout.baseWidth - 0.001 || near(s, 1),
            "J13 \(Int(w))×\(Int(h)) 逻辑宽度不得窄于设计基准（否则排版换行错乱）")
}
let l2 = SettingsLayout.logicalSize(width: 1120, height: 1240)
require(near(l2.width, 560) && near(l2.height, 620), "J14 2× 窗口逻辑尺寸回到 560×620")
// 1080×1002 是「高度」这一侧更紧（1002/620 < 1080/560），所以逻辑高度精确回到
// 基准 620、逻辑宽度略大于 560。断言写死宽度 560 是错的，这里卡的是「哪一侧受限」。
let lshot = SettingsLayout.logicalSize(width: 1080, height: 1002)
require(near(lshot.height, SettingsLayout.baseHeight), "J15 截图尺寸逻辑高度回到基准 620")
require(lshot.width >= SettingsLayout.baseWidth, "J15b 逻辑宽度不得小于基准（不压缩排版）")

// 诊断入口解析：合法尺寸要能取到，非法 / 不完整一律忽略（不能把窗口设成 0×0）。
let dbg = SettingsLayout.debugWindowSize(from: "smoose://settings?w=1080&h=1002")
require(dbg?.width == 1080 && dbg?.height == 1002, "J16 诊断尺寸解析")
let dbg2 = SettingsLayout.debugWindowSize(from: "smoose://settings?tab=about&h=780&w=840")
require(dbg2?.width == 840 && dbg2?.height == 780, "J17 参数顺序无关且可带 tab")
require(SettingsLayout.debugWindowSize(from: "smoose://settings") == nil, "J18 无 query 返回 nil")
require(SettingsLayout.debugWindowSize(from: "smoose://settings?w=1080") == nil, "J19 缺 h 返回 nil")
require(SettingsLayout.debugWindowSize(from: "smoose://settings?w=-5&h=780") == nil, "J20 负数被拒")
require(SettingsLayout.debugWindowSize(from: "smoose://settings?w=99999&h=780") == nil, "J21 超范围被拒")
require(SettingsLayout.debugWindowSize(from: "smoose://settings?w=abc&h=780") == nil, "J22 非数字被拒")

if failures == 0 { print("J-OK") } else { exit(1) }
JSWIFT
if "$SWIFTC" $SMOOSE_SWIFT_EXTRA -Onone -sdk "$SDK" -target arm64-apple-macos14.0 -I Sources -o "$WORK/j" \
    Sources/Model.swift Sources/Actions.swift Sources/ScrollAxis.swift Sources/PointerController.swift \
    Sources/ScrollPhases.swift \
    Sources/ScrollEngine.swift Sources/UpdateModel.swift Sources/Updater.swift Sources/Views.swift Sources/SettingsLauncher.swift \
    Sources/App.swift Sources/CursorZoom.swift Sources/LogitechHIDPP.swift Sources/GamePerf.swift \
    Sources/TouchEvents.c "$WORK/jdir/main.swift" 2>"$WORK/j.log"; then
  JRC=0
  JOUT="$("$WORK/j" 2>&1)" || JRC=$?
  JFAILS="$(/bin/echo "$JOUT" | grep '^FAIL' || true)"
  if [ "$JRC" != "0" ]; then JFAILS="$JFAILS J_EXIT(rc=$JRC 非零退出/崩溃)"; fi
  /bin/echo "$JOUT" | grep -q 'J-OK' || JFAILS="$JFAILS J_NOMARK(缺 J-OK 完成标记)"
  if [ -z "$JFAILS" ]; then ok "J 窗口放大内容等比联动（含封顶/裁切/诊断入口，23 项）"; else bad "J $JFAILS"; fi
else
  bad "J 编译失败$(tail -3 "$WORK/j.log")"
fi

# 变异验证：把 uiScale 换回修复前的「恒 1×」，J 段必须报红。
# 只跑正常路径全绿不算验证过 —— 这一趟就是负例载体（2026-11-02 起的项目约定）。
/bin/mkdir -p "$WORK/jmut"
/usr/bin/sed 's|return min(maxScale, max(1, min(width / baseWidth, height / baseHeight)))|return 1 // MUTANT|' \
    Sources/Views.swift > "$WORK/jmut/Views.swift"
if ! /usr/bin/grep -q 'MUTANT' "$WORK/jmut/Views.swift"; then
  bad "J_MUT 变异注入失败（前置没造出来，不能算验证过）"
elif "$SWIFTC" $SMOOSE_SWIFT_EXTRA -Onone -sdk "$SDK" -target arm64-apple-macos14.0 \
    -I "$WORK/jmut" -I Sources -o "$WORK/jm" \
    Sources/Model.swift Sources/Actions.swift Sources/ScrollAxis.swift Sources/PointerController.swift \
    Sources/ScrollPhases.swift \
    Sources/ScrollEngine.swift Sources/UpdateModel.swift Sources/Updater.swift "$WORK/jmut/Views.swift" Sources/SettingsLauncher.swift \
    Sources/App.swift Sources/CursorZoom.swift Sources/LogitechHIDPP.swift Sources/GamePerf.swift \
    Sources/TouchEvents.c "$WORK/jdir/main.swift" 2>"$WORK/jm.log"; then
  MRC=0
  MOUT="$("$WORK/jm" 2>&1)" || MRC=$?
  # 必须卡具体断言，不能只卡「有没有报错」这种恒成立命题。
  MMISSES=""
  for CASE in J2 J3 J4 J14 J15; do
    /bin/echo "$MOUT" | grep -q "^FAIL $CASE" || MMISSES="$MMISSES $CASE"
  done
  if [ "$MRC" = "0" ] || [ -n "$MMISSES" ]; then
    bad "J_MUT 恒 1× 旧实现没被抓红(rc=$MRC 漏报:$MMISSES)"
  else
    ok "J_MUT 变异验证（旧恒 1× 实现被 J2/J3/J4/J14/J15 抓红）"
  fi
else
  bad "J_MUT 编译失败$(tail -3 "$WORK/jm.log")"
fi

# ---------------------------------------------------------------------------
# K 段：关闭加速的正确语义（2026-11-06 二次纠正）
# 用户连续两轮反馈「静止后起步发黏没修好」：静置 70 秒采样读数一直是 0，
# 把全部 HID 服务也写成 0 后用户仍反馈「还是黏」→ 根因不是「值被重置」，
# 而是 0 只代表「最小加速度」，系统仍走低速增益 <1 的加速曲线。
# LinearMouse 源码确认：线性 = 加速度 -1（IOFixed -65536）
# + HIDUseLinearScalingMouseAcceleration=1（Sonoma+ 设备实例）。
# K 段验决策纯函数与签名；端到端写入由真机探针覆盖。
# ---------------------------------------------------------------------------
/bin/mkdir -p "$WORK/kdir"
/bin/cat > "$WORK/kdir/main.swift" <<'KSWIFT'
import Foundation
var failures = 0
func require(_ c: Bool, _ label: String) { if !c { print("FAIL \(label)"); failures += 1 } }

let lin = PointerAccelPolicy.plan(value: 0)
require(lin.ioFixed == -65536, "K1 线性模式加速度必须是 -1（IOFixed -65536），不是 0")
require(lin.linear == 1, "K2 线性模式必须启用 HIDUseLinearScalingMouseAcceleration=1")
require(PointerAccelPolicy.isLinear(value: 0), "K3 value=0 判定为线性")
require(!PointerAccelPolicy.isLinear(value: 2.5), "K3b value>0 判定为自定义加速曲线")
let sys = PointerAccelPolicy.plan(value: 2.5)
require(sys.ioFixed == 163840, "K4 2.5 → IOFixed 163840")
require(sys.linear == 0, "K5 自定义加速时必须关掉线性缩放标志")
require(lin.ioFixed != 0 && lin.linear != 0, "K6 线性模式与「只写 0」旧实现必须不同（旧 bug 在此假绿）")
require(PointerAccelPolicy.plan(value: 0.00001).ioFixed == -65536, "K7 极小正值仍按线性处理")
require(PointerAccelPolicy.plan(value: 6).ioFixed == 393216, "K8 上限 6 → 393216")

func snap(_ readings: [(rid: UInt64, current: Double?)],
          _ linear: [(rid: UInt64, flag: Int?)] = [],
          value: Double = 0) -> PointerAccelSnapshot {
    PointerAccelSnapshot(managed: true, value: value, includeBuiltIn: true,
                         readings: readings, linear: linear)
}
func sig(_ s: PointerAccelSnapshot) -> String { PointerAccelSignature.make(s) }
let base: [(rid: UInt64, current: Double?)] = [(rid: 1, current: -65536.0), (rid: 2, current: -65536.0)]
let linOn: [(rid: UInt64, flag: Int?)] = [(rid: 1, flag: 1), (rid: 2, flag: 1)]
let clean = sig(snap(base, linOn))
require(clean == sig(snap(base, linOn)), "K9 签名幂等（无漂移时短路仍有效）")
let linOff: [(rid: UInt64, flag: Int?)] = [(rid: 1, flag: 0), (rid: 2, flag: 1)]
require(clean != sig(snap(base, linOff)), "K10 线性标志漂移必须改变签名")
require(clean != sig(snap(base, [(rid: 1, flag: nil), (rid: 2, flag: 1)])), "K11 标志丢失(nil)与 1 必须区分")
require(clean != sig(snap(base, [])), "K12 完全不采集标志（旧实现）与采集必须区分")
require(clean == sig(snap(Array(base.reversed()), Array(linOn.reversed()))), "K13 设备顺序无关")
require(clean != sig(snap([(rid: 1, current: 0), (rid: 2, current: 0)], linOn)), "K14 加速度被改回 0 也要抓到")

// 本机实况：USB Receiver 写入线性键回显成功、读回仍是 null（hidutil 整数/布尔都试过）。
// LinearMouse 的回退是「不支持就只靠 -1」，绝不能把这种情况判成写入失败。
let native = PointerAccelPolicy.linearOutcome(before: nil, after: nil, expected: 1)
require(!native.supported && native.settled == nil, "K15 设备不支持线性键时识别为回退")
require(native.ok, "K16 不支持线性键不能判失败（否则常驻红色警告 + 失败态短路）")
require(!native.supported && native.ok, "K19 回退路径整体仍算成功（-1 已禁用加速）")
let supportedOK = PointerAccelPolicy.linearOutcome(before: 0, after: 1, expected: 1)
require(supportedOK.supported && supportedOK.ok && supportedOK.settled == 1, "K17 支持且写入成功存期望值")
let supportedFail = PointerAccelPolicy.linearOutcome(before: 0, after: 0, expected: 1)
require(!supportedFail.ok && supportedFail.settled == 0, "K18 支持但写入失败要判红并存实际值以重试")

if failures == 0 { print("K-OK") } else { exit(1) }
KSWIFT
if "$SWIFTC" $SMOOSE_SWIFT_EXTRA -Onone -sdk "$SDK" -target arm64-apple-macos14.0 -I Sources -o "$WORK/k" \
    Sources/Model.swift Sources/Actions.swift Sources/ScrollAxis.swift Sources/PointerController.swift \
    Sources/ScrollPhases.swift \
    Sources/ScrollEngine.swift Sources/UpdateModel.swift Sources/Updater.swift Sources/Views.swift Sources/SettingsLauncher.swift \
    Sources/App.swift Sources/CursorZoom.swift Sources/LogitechHIDPP.swift Sources/GamePerf.swift \
    Sources/TouchEvents.c "$WORK/kdir/main.swift" 2>"$WORK/k.log"; then
  KRC=0
  KOUT="$("$WORK/k" 2>&1)" || KRC=$?
  KFAILS="$(/bin/echo "$KOUT" | grep '^FAIL' || true)"
  if [ "$KRC" != "0" ]; then KFAILS="$KFAILS K_EXIT(rc=$KRC 非零退出/崩溃)"; fi
  /bin/echo "$KOUT" | grep -q 'K-OK' || KFAILS="$KFAILS K_NOMARK(缺 K-OK 完成标记)"
  if [ -z "$KFAILS" ]; then ok "K 关闭加速语义：线性 -1 + 线性缩放标志 + 回退 + 签名（20 项）"; else bad "K $KFAILS"; fi
else
  bad "K 编译失败$(tail -3 "$WORK/k.log")"
fi

# 接线守卫：K 段只验纯函数，必须另有守卫确认 apply/restore 真的写这两个键，
# 否则「纯函数全绿、运行时仍写 0」又是一次假绿。
PCNC="$(/bin/cat Sources/PointerController.swift)"
KWFAILS=""
/bin/echo "$PCNC" | /usr/bin/grep -q 'let plan = PointerAccelPolicy.plan(value: want)' || KWFAILS="$KWFAILS KW1"
/bin/echo "$PCNC" | /usr/bin/grep -q 'PointerAccelPolicy.linearKey as CFString' || KWFAILS="$KWFAILS KW2"
/bin/echo "$PCNC" | /usr/bin/grep -q 'let okAccel = IOHIDServiceClientSetProperty' || KWFAILS="$KWFAILS KW3"
/bin/echo "$PCNC" | /usr/bin/grep -q 'let outcome = PointerAccelPolicy.linearOutcome' || KWFAILS="$KWFAILS KW4"
/bin/echo "$PCNC" | /usr/bin/grep -q '&& outcome.ok' || KWFAILS="$KWFAILS KW5"
/bin/echo "$PCNC" | /usr/bin/grep -q 'linear: readings.map' || KWFAILS="$KWFAILS KW6"
/bin/echo "$PCNC" | /usr/bin/grep -q 'let flag = linearBaselines\[device.registryID\] ?? 0' || KWFAILS="$KWFAILS KW7"
# 恢复基线必须来自全局 HIDParameters；用「设备当前读数」会把已接管的 -1 当默认值。
/bin/echo "$PCNC" | /usr/bin/grep -q 'let accel = Self.systemDefaultAcceleration()' || KWFAILS="$KWFAILS KW8"
/bin/echo "$PCNC" | /usr/bin/grep -q '"IOService:/IOResources/IOHIDSystem"' || KWFAILS="$KWFAILS KW9"
if [ -z "$KWFAILS" ]; then ok "K_W 接线守卫（apply 双写 / 读回 / 签名 / restore / 全局默认基线）"; else bad "K_W $KWFAILS"; fi

# 变异验证：把 plan 换回「线性也写 0、不设线性缩放」的旧实现，K 段必须报红。
/bin/mkdir -p "$WORK/kmut"
/usr/bin/sed 's|if value <= 0.0001 { return (disabledIOFixed, 1) }|if value <= 0.0001 { return (0, 0) } // MUTANT|' \
    Sources/PointerController.swift > "$WORK/kmut/PointerController.swift"
if ! /usr/bin/grep -q 'MUTANT' "$WORK/kmut/PointerController.swift"; then
  bad "K_MUT 变异注入失败（前置没造出来，不能算验证过）"
elif "$SWIFTC" $SMOOSE_SWIFT_EXTRA -Onone -sdk "$SDK" -target arm64-apple-macos14.0 \
    -I "$WORK/kmut" -I Sources -o "$WORK/km" \
    Sources/Model.swift Sources/Actions.swift Sources/ScrollAxis.swift "$WORK/kmut/PointerController.swift" \
    Sources/ScrollPhases.swift \
    Sources/ScrollEngine.swift Sources/UpdateModel.swift Sources/Updater.swift Sources/Views.swift Sources/SettingsLauncher.swift \
    Sources/App.swift Sources/CursorZoom.swift Sources/LogitechHIDPP.swift Sources/GamePerf.swift \
    Sources/TouchEvents.c "$WORK/kdir/main.swift" 2>"$WORK/km.log"; then
  KMRC=0
  KMOUT="$("$WORK/km" 2>&1)" || KMRC=$?
  KMMISSES=""
  for CASE in K1 K2 K6; do
    /bin/echo "$KMOUT" | grep -q "^FAIL $CASE" || KMMISSES="$KMMISSES $CASE"
  done
  if [ "$KMRC" = "0" ] || [ -n "$KMMISSES" ]; then
    bad "K_MUT 旧「恒写 0」实现没被抓红(rc=$KMRC 漏报:$KMMISSES)"
  else
    ok "K_MUT 变异验证（旧恒写 0 实现被 K1/K2/K6 抓红）"
  fi
else
  bad "K_MUT 编译失败$(tail -3 "$WORK/km.log")"
fi

# 第二趟变异：把「设备不支持线性键 = 回退成功」改成判失败，K16/K19 必须报红。
# 这一条守的是真机截图里那排红色「写入未生效」——不能把硬件能力缺失报成写入失败。
/usr/bin/sed 's|if !supported { return (false, nil, true) }|if !supported { return (false, nil, false) } // MUTANT|' \
    Sources/PointerController.swift > "$WORK/kmut/PointerController.swift"
if ! /usr/bin/grep -q 'MUTANT' "$WORK/kmut/PointerController.swift"; then
  bad "K_MUT2 变异注入失败（前置没造出来，不能算验证过）"
elif "$SWIFTC" $SMOOSE_SWIFT_EXTRA -Onone -sdk "$SDK" -target arm64-apple-macos14.0 \
    -I "$WORK/kmut" -I Sources -o "$WORK/km2" \
    Sources/Model.swift Sources/Actions.swift Sources/ScrollAxis.swift "$WORK/kmut/PointerController.swift" \
    Sources/ScrollPhases.swift \
    Sources/ScrollEngine.swift Sources/UpdateModel.swift Sources/Updater.swift Sources/Views.swift Sources/SettingsLauncher.swift \
    Sources/App.swift Sources/CursorZoom.swift Sources/LogitechHIDPP.swift Sources/GamePerf.swift \
    Sources/TouchEvents.c "$WORK/kdir/main.swift" 2>"$WORK/km2.log"; then
  KM2RC=0
  KM2OUT="$("$WORK/km2" 2>&1)" || KM2RC=$?
  KM2MISSES=""
  for CASE in K16 K19; do
    /bin/echo "$KM2OUT" | grep -q "^FAIL $CASE" || KM2MISSES="$KM2MISSES $CASE"
  done
  if [ "$KM2RC" = "0" ] || [ -n "$KM2MISSES" ]; then
    bad "K_MUT2 回退误判没被抓红(rc=$KM2RC 漏报:$KM2MISSES)"
  else
    ok "K_MUT2 变异验证（把硬件不支持误判为失败会被 K16/K19 抓红）"
  fi
else
  bad "K_MUT2 编译失败$(tail -3 "$WORK/km2.log")"
fi

# L 段：HID++ 0x2201 真实 DPI 能力（2026-11-06，用户指出鼠标上限 25600）
# 背景：旧实现把档位硬编码 [400...3200]、currentDPI 写死 1000、把 feature ID 高字节
# 0x22 当 feature index、发完报文不看返回值就显示「已应用硬件 DPI」。
# 真机探针（pid=0xc547）回报：featureIndex=7，档位 [100, 25600]，步长 50，
# 当前 5400、默认 1600；另一个接收器 pid=0xc548 返回 index=0（不支持）。
# L 段验的是协议解析与写入判定纯函数；端到端链路由真机探针覆盖。
/bin/mkdir -p "$WORK/ldir"
/bin/cat > "$WORK/ldir/main.swift" <<'LSWIFT'
import Foundation

var failures = 0
func require(_ cond: @autoclosure () -> Bool, _ label: String) {
    if !cond() { print("FAIL \(label)"); failures += 1 }
}

// 真机 GET_SENSOR_DPI_LIST 响应的 parameters 区：
// 00 | 0064 | e032 | 6400 | 0000...  → sensor0 / 100 / 步长 50 / 25600 / 结束
let listParams: [UInt8] = [0x00, 0x00, 0x64, 0xe0, 0x32, 0x64,
                           0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
let parsed = HIDPPDPIParser.parseList(listParams)
require(parsed != nil, "L1 真机 DPI 列表必须能解析")
guard let list = parsed else { print("FAIL L1 前置不成立，后续无法验证"); exit(1) }
require(list.sensorIndex == 0, "L2 sensorIndex=0")
require(list.values == [100, 25600], "L3 档位 [100, 25600]")
require(list.step == 50, "L4 步长编码 0xE032 → 50")
require(list.min == 100 && list.max == 25600, "L5 上限 25600（用户实机值）")
require(list.max != 3200, "L6 不能再是旧硬编码上限 3200")

// 真机 GET_SENSOR_DPI：00 | 1518 | 0640 → 当前 5400、默认 1600
let curParams: [UInt8] = [0x00, 0x15, 0x18, 0x06, 0x40, 0x00, 0x00, 0x00]
let cur = HIDPPDPIParser.parseCurrent(curParams)
require(cur?.current == 5400, "L7 当前 DPI=5400")
require(cur?.defaultValue == 1600, "L8 默认 DPI=1600")

let sel = HIDPPDPIParser.selectableDPIs(list, current: 5400)
require(sel.contains(25600), "L9 设备上限 25600 必须可选")
require(sel.contains(5400), "L10 设备当前值必须可选")
require(sel.allSatisfy { $0 >= list.min && $0 <= list.max }, "L11 档位不得超出设备回报范围")
require(sel.allSatisfy { ($0 - list.min) % 50 == 0 }, "L12 档位必须对齐设备步长 50")
require(sel == sel.sorted() && Set(sel).count == sel.count, "L13 档位有序且去重")

// SET_SENSOR_DPI 报文：featureIndex 必须来自 getFeature，不能写死 0x22
let req = HIDPPDPIParser.setRequest(featureIndex: 7, sensor: 0, dpi: 25600)
require(req.count == 20, "L14 长报文 20 字节")
require(req[0] == 0x11 && req[1] == 0x01, "L15 reportID / deviceIndex")
require(req[2] == 7, "L16 featureIndex 用查询得到的 7")
require(req[2] != 0x22, "L17 不能把 feature ID 高字节当 index（旧实现）")
require(req[3] == 0x38, "L18 SET_SENSOR_DPI = fn3<<4|sw8 = 0x38")
require(req[4] == 0, "L19 sensorIndex")
require(req[5] == 0x64 && req[6] == 0x00, "L20 25600 = 0x6400 大端")
let req800 = HIDPPDPIParser.setRequest(featureIndex: 7, sensor: 0, dpi: 800)
require(req800[5] == 0x03 && req800[6] == 0x20, "L21 800 = 0x0320 大端")

// 写入判定：任一环缺失都必须判红，不能只凭 SetReport 返回值报绿
require(HIDPPDPIWrite.verdict(setReportOK: true, echo: 25600, readBack: 25600, target: 25600) == .verified,
        "L22 全链路一致才算成功")
let noSet = HIDPPDPIWrite.verdict(setReportOK: false, echo: nil, readBack: nil, target: 25600)
require(!noSet.ok && noSet == .setReportFailed, "L23 报文未被接受不得报绿且要给出具体拒因")
let noRead = HIDPPDPIWrite.verdict(setReportOK: true, echo: nil, readBack: nil, target: 25600)
require(!noRead.ok && noRead == .noReadBack, "L24 没有读回不得报绿（旧实现假绿点）")
require(HIDPPDPIWrite.verdict(setReportOK: true, echo: nil, readBack: 800, target: 25600) == .readBackMismatch(800),
        "L25 读回与目标不符要判红")
require(HIDPPDPIWrite.verdict(setReportOK: true, echo: 800, readBack: 25600, target: 25600) == .echoMismatch(800),
        "L26 设备回显不符要判红（不能只看读回）")
require(HIDPPDPIWrite.verdict(setReportOK: true, echo: 0, readBack: 25600, target: 25600) == .verified,
        "L27 协议 v0 不回显时仍以读回为准")

// 解析防御：读不到就返回 nil，绝不拿硬编码档位兜底
require(HIDPPDPIParser.parseList([0x00]) == nil, "L28 报文过短返回 nil")
require(HIDPPDPIParser.parseList([0x00, 0x00, 0x00]) == nil, "L29 无档位返回 nil")
require(HIDPPDPIParser.parseCurrent([0x00, 0x15]) == nil, "L30 当前 DPI 报文过短返回 nil")

if failures == 0 { print("L-OK") } else { exit(1) }
LSWIFT

if "$SWIFTC" $SMOOSE_SWIFT_EXTRA -Onone -sdk "$SDK" -target arm64-apple-macos14.0 \
    -o "$WORK/l" Sources/LogitechHIDPP.swift "$WORK/ldir/main.swift" 2>"$WORK/l.log"; then
  LRC=0
  LOUT="$("$WORK/l" 2>&1)" || LRC=$?
  LFAILS="$(/bin/echo "$LOUT" | grep '^FAIL' || true)"
  if [ "$LRC" != "0" ]; then LFAILS="$LFAILS L_EXIT(rc=$LRC 非零退出/崩溃)"; fi
  if [ -z "$LFAILS" ]; then ok "L HID++ 0x2201 真实 DPI 能力与写入读回校验（30 项）"; else bad "L $LFAILS"; fi
else
  bad "L 编译失败$(tail -3 "$WORK/l.log")"
fi

# L_W 接线守卫：源码里不能残留旧假绿写法
LWFAILS=""
HSRC="$(/bin/cat Sources/LogitechHIDPP.swift)"
VSRC="$(/bin/cat Sources/Views.swift)"
/bin/echo "$VSRC" | /usr/bin/grep -q 'ForEach(\[400, 800, 1000, 1200, 1600, 2000, 2400, 3200\]' && LWFAILS="$LWFAILS LW1"
/bin/echo "$HSRC" | /usr/bin/grep -q 'req\[2\] = 0x22' && LWFAILS="$LWFAILS LW2"
/bin/echo "$HSRC" | /usr/bin/grep -q 'supportedDPIs: \[400, 800' && LWFAILS="$LWFAILS LW3"
/bin/echo "$HSRC" | /usr/bin/grep -q 'currentDPI: 1000' && LWFAILS="$LWFAILS LW4"
/bin/echo "$HSRC" | /usr/bin/grep -q 'HIDPPDPIWrite.verdict(' || LWFAILS="$LWFAILS LW5"
/bin/echo "$HSRC" | /usr/bin/grep -q 'HIDPPDPICommand.getFeature' || LWFAILS="$LWFAILS LW6"
/bin/echo "$HSRC" | /usr/bin/grep -q 'if result.verdict.ok' || LWFAILS="$LWFAILS LW7"
/bin/echo "$VSRC" | /usr/bin/grep -q 'logi.selectableDPIs' || LWFAILS="$LWFAILS LW8"
/bin/echo "$VSRC" | /usr/bin/grep -q 'case .ready(let cap' || LWFAILS="$LWFAILS LW9"
/bin/echo "$VSRC" | /usr/bin/grep -q 'Button("刷新") { logi.refresh() }' || LWFAILS="$LWFAILS LW10"
LSEC="$(/usr/bin/sed -n '/^struct LogitechSectionView/,/^}/p' Sources/Views.swift)"
# 写入必须是显式按钮：早先 onChange(of: selectedDPI) 自动下发，打开页面就发 SET 报文。
/bin/echo "$LSEC" | /usr/bin/grep -qF '.onChange(of: selectedDPI)' && LWFAILS="$LWFAILS LW11"
/bin/echo "$LSEC" | /usr/bin/grep -q 'Button("应用") {' || LWFAILS="$LWFAILS LW12"
/bin/echo "$LSEC" | /usr/bin/grep -q 'logi.setDPI(selectedDPI)' || LWFAILS="$LWFAILS LW13"
if [ -z "$LWFAILS" ]; then ok "L_W 接线守卫（无硬编码档位 / 真实探测 / 失败不报绿 / 写入必须显式）"; else bad "L_W $LWFAILS"; fi

# 两趟变异验证：把「假绿」注入回源码，L 段必须抓红。
/bin/mkdir -p "$WORK/lmut"
/usr/bin/sed 's|guard setReportOK else { return .setReportFailed }|guard setReportOK else { return .verified } // MUTANT|' \
    Sources/LogitechHIDPP.swift > "$WORK/lmut/LogitechHIDPP.swift"
if ! /usr/bin/grep -q 'MUTANT' "$WORK/lmut/LogitechHIDPP.swift"; then
  bad "L_MUT 变异注入失败（前置没造出来，不能算验证过）"
elif "$SWIFTC" $SMOOSE_SWIFT_EXTRA -Onone -sdk "$SDK" -target arm64-apple-macos14.0 \
    -o "$WORK/lm" "$WORK/lmut/LogitechHIDPP.swift" "$WORK/ldir/main.swift" 2>"$WORK/lm.log"; then
  LMRC=0
  LMOUT="$("$WORK/lm" 2>&1)" || LMRC=$?
  if [ "$LMRC" = "0" ] || ! /bin/echo "$LMOUT" | grep -q '^FAIL L23'; then
    bad "L_MUT 报文失败却报绿没被抓红(rc=$LMRC)"
  else
    ok "L_MUT 变异验证（报文失败仍报绿会被 L23 抓红）"
  fi
else
  bad "L_MUT 编译失败$(tail -3 "$WORK/lm.log")"
fi

/usr/bin/sed 's|req\[2\] = featureIndex|req[2] = 0x22 // MUTANT|' \
    Sources/LogitechHIDPP.swift > "$WORK/lmut/LogitechHIDPP.swift"
if ! /usr/bin/grep -q 'MUTANT' "$WORK/lmut/LogitechHIDPP.swift"; then
  bad "L_MUT2 变异注入失败（前置没造出来，不能算验证过）"
elif "$SWIFTC" $SMOOSE_SWIFT_EXTRA -Onone -sdk "$SDK" -target arm64-apple-macos14.0 \
    -o "$WORK/lm2" "$WORK/lmut/LogitechHIDPP.swift" "$WORK/ldir/main.swift" 2>"$WORK/lm2.log"; then
  LM2RC=0
  LM2OUT="$("$WORK/lm2" 2>&1)" || LM2RC=$?
  LM2MISSES=""
  for CASE in L16 L17; do
    /bin/echo "$LM2OUT" | grep -q "^FAIL $CASE" || LM2MISSES="$LM2MISSES $CASE"
  done
  if [ "$LM2RC" = "0" ] || [ -n "$LM2MISSES" ]; then
    bad "L_MUT2 旧 featureIndex 写法没被抓红(rc=$LM2RC 漏报:$LM2MISSES)"
  else
    ok "L_MUT2 变异验证（把 featureIndex 写死 0x22 会被 L16/L17 抓红）"
  fi
else
  bad "L_MUT2 编译失败$(tail -3 "$WORK/lm2.log")"
fi

# ---------------------------------------------------------------------------
# M 段：内建触控板不参与加速度写入，且「跳过」必须可见（2026-11-06 第四轮）
# 真机：用户勾选了旧开关后，内建触控板写 HIDMouseAcceleration=-1 读回 0，
# 于是整段「状态」区变成红色「写入未生效」，但那台设备其实从未被接管过。
# 旧开关是个没有载体的假选项：设备不支持，勾了只会制造假失败。
# M 段验设备范围 + 状态合成两个纯决策；端到端由真机截图验收。
# ---------------------------------------------------------------------------
/bin/mkdir -p "$WORK/mdir"
/bin/cat > "$WORK/mdir/main.swift" <<'MSWIFT'
import Foundation
var failures = 0
func require(_ c: @autoclosure () -> Bool, _ label: String) {
    if !c() { print("FAIL \(label)"); failures += 1 }
}

// 真机拓扑：罗技 USB Receiver 两个 HID 接口 + 内建触控板
let topo: [(rid: UInt64, builtIn: Bool)] = [
    (rid: 4294972324, builtIn: false),
    (rid: 4294972593, builtIn: false),
    (rid: 4294973001, builtIn: true),
]

require(PointerAccelPolicy.scope(builtIn: true) == .systemManagedBuiltIn,
        "M1 内建触控板必须归类为「系统管理」，不是「可写但失败」")
require(PointerAccelPolicy.scope(builtIn: false) == .externalMouse,
        "M2 外接鼠标归类为可接管")
let ids = PointerAccelPolicy.eligible(topo)
require(ids == [4294972324, 4294972593], "M3 eligible 只含两台外接设备")
require(!ids.contains(4294973001), "M4 触控板 rid 不得进入写入列表")
require(PointerAccelPolicy.eligible([(rid: 7, builtIn: true)]) == [],
        "M5 只有触控板时写入列表必须为空")
require(PointerAccelPolicy.eligible([]) == [], "M6 无设备时写入列表为空")
require(PointerAccelPolicy.eligible([(rid: 1, builtIn: false), (rid: 2, builtIn: true),
                                     (rid: 3, builtIn: false)]) == [1, 3],
        "M7 混合设备保持外接设备的原始顺序")

// 成功判定：跳过项绝不参与，且空结果不能报绿
require(PointerAccelStatus.allOK([true, true]), "M8 外接设备全部写入成功 = 绿")
require(!PointerAccelStatus.allOK([true, false]), "M9 任一外接设备失败必须判红")
require(!PointerAccelStatus.allOK([]), "M10 一台可写设备都没有不能报绿（旧假绿点）")
let onlyPad = PointerAccelPolicy.eligible([(rid: 9, builtIn: true)])
require(onlyPad.isEmpty && !PointerAccelStatus.allOK(Array(repeating: true, count: onlyPad.count)),
        "M11 只有触控板时整体状态仍为未接管，不能因「跳过」变绿")

// 跳过必须可见：带设备名、带具体原因、且不能复用「写入失败」措辞
let line = PointerAccelStatus.skippedLine(name: "Apple Internal Trackpad")
require(line.contains("Apple Internal Trackpad"), "M12 跳过说明必须带设备名（不能静默跳过）")
require(line.contains("内建触控板由系统管理"), "M13 跳过说明必须写清原因")
require(!line.isEmpty, "M14 跳过说明不得为空字符串")
require(!line.contains("⚠️"), "M15 跳过不是写入失败，不得带警告符号")
require(!line.contains("写入未生效"), "M16 跳过不得复用写入失败措辞（旧版整段红字的来源）")

if failures == 0 { print("M-OK") } else { exit(1) }
MSWIFT

# 全套源码编译（与 I/K 段一致）：M 段只调用纯策略，但必须编译真文件而不是复制品。
MCOMPILE() {
  "$SWIFTC" $SMOOSE_SWIFT_EXTRA -Onone -sdk "$SDK" -target arm64-apple-macos14.0 \
    -I "$1" -I Sources -o "$2" \
    Sources/Model.swift Sources/Actions.swift Sources/ScrollAxis.swift "$1/PointerController.swift" \
    Sources/ScrollPhases.swift \
    Sources/ScrollEngine.swift Sources/UpdateModel.swift Sources/Updater.swift Sources/Views.swift Sources/SettingsLauncher.swift \
    Sources/App.swift Sources/CursorZoom.swift Sources/LogitechHIDPP.swift Sources/GamePerf.swift \
    Sources/TouchEvents.c "$WORK/mdir/main.swift"
}
/bin/mkdir -p "$WORK/mmut"
/bin/cp Sources/PointerController.swift "$WORK/mmut/PointerController.swift"
if MCOMPILE "$WORK/mmut" "$WORK/m" 2>"$WORK/m.log"; then
  MRC=0
  MOUT="$("$WORK/m" 2>&1)" || MRC=$?
  MFAILS="$(/bin/echo "$MOUT" | grep '^FAIL' || true)"
  if [ "$MRC" != "0" ]; then MFAILS="$MFAILS M_EXIT(rc=$MRC 非零退出/崩溃)"; fi
  /bin/echo "$MOUT" | grep -q 'M-OK' || MFAILS="$MFAILS M_NOMARK(缺 M-OK 完成标记)"
  if [ -z "$MFAILS" ]; then ok "M 内建触控板隔离：设备范围 / 状态合成 / 跳过可见（16 项）"; else bad "M $MFAILS"; fi
else
  bad "M 编译失败$(tail -3 "$WORK/m.log")"
fi

# M_W 接线守卫：纯函数全绿不代表 apply / UI 真的接上了。
# 源码先剥行注释，避免守卫抓到文档里的旧写法字面量（LW11 踩过这个坑）。
MWFAILS=""
MPNC="$(/usr/bin/sed -E 's://.*$::' Sources/PointerController.swift)"
MVIEWS="$(/usr/bin/sed -E 's://.*$::' Sources/Views.swift)"
/bin/echo "$MPNC" | /usr/bin/grep -qF 'prefs.pointerIncludeBuiltIn || !$0.builtIn' && MWFAILS="$MWFAILS MW1"
/bin/echo "$MPNC" | /usr/bin/grep -qF 'PointerAccelPolicy.scope(builtIn: $0.builtIn) == .externalMouse' || MWFAILS="$MWFAILS MW2"
/bin/echo "$MPNC" | /usr/bin/grep -qF 'let readings = eligible.map' || MWFAILS="$MWFAILS MW3"
/bin/echo "$MPNC" | /usr/bin/grep -qF 'PointerAccelStatus.skippedLine(name: device.name)' || MWFAILS="$MWFAILS MW4"
/bin/echo "$MPNC" | /usr/bin/grep -qF 'let allOK = PointerAccelStatus.allOK(writeResults)' || MWFAILS="$MWFAILS MW5"
/bin/echo "$MPNC" | /usr/bin/grep -qF 'writeResults.append(good)' || MWFAILS="$MWFAILS MW6"
/bin/echo "$MVIEWS" | /usr/bin/grep -qF 'Toggle("同时应用到内置触控板"' && MWFAILS="$MWFAILS MW7"
/bin/echo "$MVIEWS" | /usr/bin/grep -qF 'isOn: $prefs.pointerIncludeBuiltIn' && MWFAILS="$MWFAILS MW8"
/bin/echo "$MVIEWS" | /usr/bin/grep -qF '内建触控板由系统管理' || MWFAILS="$MWFAILS MW9"
if [ -z "$MWFAILS" ]; then ok "M_W 接线守卫（apply 按策略筛选 / 跳过行可见 / UI 无假开关）"; else bad "M_W $MWFAILS"; fi

# 三趟变异：每次都先确认 MUTANT 真的注入成功，再要求具体断言报红。
# ① 把触控板重新纳入写入（旧开关行为）→ M1/M3/M4/M5/M7 必须红。
/usr/bin/sed 's|builtIn ? \.systemManagedBuiltIn : \.externalMouse|builtIn ? .externalMouse : .externalMouse // MUTANT|' \
    Sources/PointerController.swift > "$WORK/mmut/PointerController.swift"
if ! /usr/bin/grep -q 'MUTANT' "$WORK/mmut/PointerController.swift"; then
  bad "M_MUT 变异注入失败（前置没造出来，不能算验证过）"
elif MCOMPILE "$WORK/mmut" "$WORK/mm1" 2>"$WORK/mm1.log"; then
  MM1RC=0
  MM1OUT="$("$WORK/mm1" 2>&1)" || MM1RC=$?
  MM1MISSES=""
  for CASE in M1 M3 M4 M5 M7; do
    /bin/echo "$MM1OUT" | grep -q "^FAIL $CASE" || MM1MISSES="$MM1MISSES $CASE"
  done
  if [ "$MM1RC" = "0" ] || [ -n "$MM1MISSES" ]; then
    bad "M_MUT 触控板重新纳入写入没被抓红(rc=$MM1RC 漏报:$MM1MISSES)"
  else
    ok "M_MUT 变异验证（旧开关行为被 M1/M3/M4/M5/M7 抓红）"
  fi
else
  bad "M_MUT 编译失败$(tail -3 "$WORK/mm1.log")"
fi

# ② 把成功判定改成恒真（旧假绿）→ M9/M10/M11 必须红。
/usr/bin/sed 's|!writeResults.isEmpty && writeResults.allSatisfy { $0 }|true // MUTANT|' \
    Sources/PointerController.swift > "$WORK/mmut/PointerController.swift"
if ! /usr/bin/grep -q 'MUTANT' "$WORK/mmut/PointerController.swift"; then
  bad "M_MUT2 变异注入失败（前置没造出来，不能算验证过）"
elif MCOMPILE "$WORK/mmut" "$WORK/mm2" 2>"$WORK/mm2.log"; then
  MM2RC=0
  MM2OUT="$("$WORK/mm2" 2>&1)" || MM2RC=$?
  MM2MISSES=""
  for CASE in M9 M10 M11; do
    /bin/echo "$MM2OUT" | grep -q "^FAIL $CASE" || MM2MISSES="$MM2MISSES $CASE"
  done
  if [ "$MM2RC" = "0" ] || [ -n "$MM2MISSES" ]; then
    bad "M_MUT2 恒真成功判定没被抓红(rc=$MM2RC 漏报:$MM2MISSES)"
  else
    ok "M_MUT2 变异验证（恒绿实现被 M9/M10/M11 抓红）"
  fi
else
  bad "M_MUT2 编译失败$(tail -3 "$WORK/mm2.log")"
fi

# ③ 抹掉跳过原因（静默跳过）→ M13 必须红。
/usr/bin/sed 's|：内建触控板由系统管理（不写入加速度）"|" // MUTANT|' \
    Sources/PointerController.swift > "$WORK/mmut/PointerController.swift"
if ! /usr/bin/grep -q 'MUTANT' "$WORK/mmut/PointerController.swift"; then
  bad "M_MUT3 变异注入失败（前置没造出来，不能算验证过）"
elif MCOMPILE "$WORK/mmut" "$WORK/mm3" 2>"$WORK/mm3.log"; then
  MM3RC=0
  MM3OUT="$("$WORK/mm3" 2>&1)" || MM3RC=$?
  if [ "$MM3RC" = "0" ] || ! /bin/echo "$MM3OUT" | grep -q '^FAIL M13'; then
    bad "M_MUT3 静默跳过没被抓红(rc=$MM3RC)"
  else
    ok "M_MUT3 变异验证（跳过原因被抹掉会被 M13 抓红）"
  fi
else
  bad "M_MUT3 编译失败$(tail -3 "$WORK/mm3.log")"
fi

# ---------------------------------------------------------------------------
# N 段：鼠标硬件 DPI 快捷键切换后的自动同步（2026-11-06 第五轮）
# 真机探针结论：Solaar notifications.py 里 0x2201 没有 DPI 变更通知 → 必须主动 GET。
# 纠正一次误判：最初以为「None 打开收不到响应」，独立进程 15/15 全部读到 5400，
# 证明那只是接收器休眠预热；所以同步连接用 None 非独占打开，不霸占 HID++ 接口。
# N 段验「变化判定 / 失败不吞 / 写入竞态 / 文案不撒谎」四个纯决策；
# 端到端由真机按 DPI 键 + 截图验收。
# ---------------------------------------------------------------------------
/bin/mkdir -p "$WORK/ndir"
/bin/cat > "$WORK/ndir/main.swift" <<'NSWIFT'
import Foundation
var failures = 0
func require(_ c: @autoclosure () -> Bool, _ label: String) {
    if !c() { print("FAIL \(label)"); failures += 1 }
}

// 真机能力：100–25600，步长 50；当前 5400
let p: [UInt8] = [0x00, 0x00, 0x64, 0xe0, 0x32, 0x64,
                  0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
guard let cap = HIDPPDPIParser.parseList(p) else {
    print("FAIL N0 前置不成立：真机 DPI 列表解析失败"); exit(1)
}

// 硬件按 DPI 键切到 3200 的 GET_SENSOR_DPI 响应
let d3200: [UInt8] = [0x00, 0x0c, 0x80, 0x06, 0x40, 0x00, 0x00, 0x00]
require(HIDPPDPIParser.parseCurrent(d3200)?.current == 3200, "N1 新档位 3200 必须能从设备报文解析")

require(HIDPPDPISync.outcome(baseline: 5400, observed: 3200, capability: cap, writing: false)
        == .hardwareChanged(3200), "N2 硬件切换必须识别为 hardwareChanged")
require(HIDPPDPISync.outcome(baseline: 5400, observed: 5400, capability: cap, writing: false)
        == .noChange, "N3 值没变不产生同步事件")
require(HIDPPDPISync.outcome(baseline: 0, observed: 5400, capability: cap, writing: false)
        == .hardwareChanged(5400), "N4 首次读到值也要同步（基线 0 不能吞掉）")

// 读失败绝不能被当成「没变」：否则硬件切换会被静默吞掉
require(HIDPPDPISync.outcome(baseline: 5400, observed: nil, capability: cap, writing: false)
        == .readFailed, "N5 读失败必须单独成 case，不能报 noChange")
require(HIDPPDPISync.outcome(baseline: 5400, observed: 0, capability: cap, writing: false)
        == .readFailed, "N6 设备回 0 不是有效 DPI，不得当成 noChange")
require(HIDPPDPISync.outcome(baseline: 5400, observed: -1, capability: cap, writing: false)
        == .readFailed, "N7 负数读数不得当成 noChange")
require(HIDPPDPISync.outcome(baseline: 5400, observed: 30000, capability: cap, writing: false)
        == .outOfRange(30000), "N8 超出设备能力上限要判越界而非同步")
require(HIDPPDPISync.outcome(baseline: 5400, observed: 50, capability: cap, writing: false)
        == .outOfRange(50), "N9 低于设备能力下限要判越界")

// App 自己写入期间，读到的中间值不得被当成「硬件切换」
require(HIDPPDPISync.outcome(baseline: 5400, observed: 3200, capability: cap, writing: true)
        == .ignoredWhileWriting, "N10 写入竞态必须忽略观测值")
require(HIDPPDPISync.outcome(baseline: 5400, observed: nil, capability: cap, writing: true)
        == .ignoredWhileWriting, "N11 写入期间读失败也不能刷成失败状态")

let hs = HIDPPDPISync.hardwareStatus(3200)
require(hs.contains("3200"), "N12 状态文案要带新档位数值")
require(hs.contains("未回写硬件"), "N13 状态文案必须明确没有回写硬件")
require(!hs.contains("已应用"), "N14 自动同步不得复用「已应用硬件 DPI」措辞（会误以为 Smoose 写了设备）")
let fs = HIDPPDPISync.failureStatus(failures: 3, kept: 5400)
require(fs.contains("3") && fs.contains("5400"), "N15 读失败必须显示连续次数并保留上次值")
require(HIDPPDPISync.outOfRangeStatus(30000, min: cap.min, max: cap.max).contains("30000"),
        "N16 越界文案要带被忽略的读数")
require(HIDPPDPISync.badge(watching: true).contains("自动同步中"), "N17 同步中要有可见标识")
require(HIDPPDPISync.badge(watching: false).contains("暂停"), "N18 暂停不能伪装成同步中")

require(HIDPPDPISync.pollInterval > 0 && HIDPPDPISync.pollInterval <= 0.5,
        "N19 轮询间隔要跟手且不能忙等")
require(HIDPPDPISync.backoffThreshold >= 2 && HIDPPDPISync.backoffInterval > HIDPPDPISync.pollInterval,
        "N20 连续失败要退避，退避间隔必须大于正常轮询")
require(HIDPPDPISync.warmupRequests >= 2,
        "N23 接收器休眠必须预热，不能把首个超时当成读取失败")

// 硬件可能切到不在常用档位里的值：Picker 必须仍然有这个选项
let sel = HIDPPDPIParser.selectableDPIs(cap, current: 3300)
require(sel.contains(3300), "N21 硬件切到非常规档位 3300 时下拉框仍须可选")
require(sel.allSatisfy { $0 >= cap.min && $0 <= cap.max }, "N22 同步后的档位仍受设备能力约束")

if failures == 0 { print("N-OK") } else { exit(1) }
NSWIFT

NCOMPILE() {
  "$SWIFTC" $SMOOSE_SWIFT_EXTRA -Onone -sdk "$SDK" -target arm64-apple-macos14.0 \
    -o "$2" "$1/LogitechHIDPP.swift" "$WORK/ndir/main.swift"
}
/bin/mkdir -p "$WORK/nmut"
/bin/cp Sources/LogitechHIDPP.swift "$WORK/nmut/LogitechHIDPP.swift"
if NCOMPILE "$WORK/nmut" "$WORK/n" 2>"$WORK/n.log"; then
  NRC=0
  NOUT="$("$WORK/n" 2>&1)" || NRC=$?
  NFAILS="$(/bin/echo "$NOUT" | grep '^FAIL' || true)"
  if [ "$NRC" != "0" ]; then NFAILS="$NFAILS N_EXIT(rc=$NRC 非零退出/崩溃)"; fi
  /bin/echo "$NOUT" | grep -q 'N-OK' || NFAILS="$NFAILS N_NOMARK(缺 N-OK 完成标记)"
  if [ -z "$NFAILS" ]; then ok "N 硬件 DPI 自动同步：变化判定 / 失败不吞 / 写入竞态 / 文案（23 项）"; else bad "N $NFAILS"; fi
else
  bad "N 编译失败$(tail -3 "$WORK/n.log")"
fi

# N_W 接线守卫：纯函数全绿不代表真机链路接上了、也不代表没有偷偷回写硬件。
NWFAILS=""
NHSRC="$(/usr/bin/sed -E 's://.*$::' Sources/LogitechHIDPP.swift)"
NVSRC="$(/usr/bin/sed -E 's://.*$::' Sources/Views.swift)"
NAPP="$(/usr/bin/sed -E 's://.*$::' Sources/App.swift)"
NWATCH="$(/usr/bin/sed -n '/^private final class HIDPPWatchSession/,/^\/\/ MARK: - 探测结果/p' Sources/LogitechHIDPP.swift)"
NHANDLE="$(/usr/bin/sed -n '/^    private func handleSyncReading/,/^    private func adoptCurrentDPI/p' Sources/LogitechHIDPP.swift)"

# 前置必须单独成条：范围是空的 / 抓错函数时，「没找到写入」这种断言会假绿。
/bin/echo "$NWATCH" | /usr/bin/grep -q '^private final class HIDPPWatchSession' || NWFAILS="$NWFAILS NW_PRE1"
/bin/echo "$NWATCH" | /usr/bin/grep -qF 'private func run()' || NWFAILS="$NWFAILS NW_PRE2"
/bin/echo "$NHANDLE" | /usr/bin/grep -q '^    private func handleSyncReading' || NWFAILS="$NWFAILS NW_PRE3"
/bin/echo "$NHANDLE" | /usr/bin/grep -qF 'case .hardwareChanged' || NWFAILS="$NWFAILS NW_PRE4"

/bin/echo "$NHSRC" | /usr/bin/grep -qF 'HIDPPDPISync.outcome(baseline: currentDPI' || NWFAILS="$NWFAILS NW1"
/bin/echo "$NHSRC" | /usr/bin/grep -qF 'HIDPPDPISync.hardwareStatus(dpi)' || NWFAILS="$NWFAILS NW2"
/bin/echo "$NHSRC" | /usr/bin/grep -qF 'HIDPPDPISync.failureStatus(' || NWFAILS="$NWFAILS NW3"
/bin/echo "$NHSRC" | /usr/bin/grep -qF 'HIDPPDPISync.badge(watching: true)' || NWFAILS="$NWFAILS NW4"
/bin/echo "$NHSRC" | /usr/bin/grep -qF 'let want = windowVisible && dpiPageVisible && !isWriting && probeInfo != nil' || NWFAILS="$NWFAILS NW5"
# 「App 失活就暂停」是错的：硬件 DPI 键恰恰在 Smoose 不是前台时按。
/bin/echo "$NHSRC" | /usr/bin/grep -qF 'appActive' && NWFAILS="$NWFAILS NW5B"
/bin/echo "$NHSRC" | /usr/bin/grep -qF 'adoptCurrentDPI(dpi, info: info)' || NWFAILS="$NWFAILS NW6"
/bin/echo "$NHSRC" | /usr/bin/grep -qF '.ready(info.capability, current: dpi' || NWFAILS="$NWFAILS NW7"
/bin/echo "$NHSRC" | /usr/bin/grep -qF 'isWriting = true' || NWFAILS="$NWFAILS NW8"
/bin/echo "$NHSRC" | /usr/bin/grep -qF 'session.requestOnce(info.featureIndex, HIDPPDPICommand.getSensorDPI' || NWFAILS="$NWFAILS NW9"
/bin/echo "$NHSRC" | /usr/bin/grep -qF 'IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))' || NWFAILS="$NWFAILS NW10"
# 同步连接必须非独占：既要有 None 打开，也不能出现 SeizeDevice。
/bin/echo "$NWATCH" | /usr/bin/grep -qF 'IOHIDDeviceOpen(dev, IOOptionBits(kIOHIDOptionsTypeNone))' || NWFAILS="$NWFAILS NW10A"
/bin/echo "$NWATCH" | /usr/bin/grep -qF 'SeizeDevice' && NWFAILS="$NWFAILS NW10B"
/bin/echo "$NHSRC" | /usr/bin/grep -qF '0..<HIDPPDPISync.warmupRequests' || NWFAILS="$NWFAILS NW10C"
# 同步链路只读：watch 会话和状态处理里都不允许出现写入报文 / setDPI
/bin/echo "$NWATCH" | /usr/bin/grep -qE 'setSensorDPI|0x38|HIDPPWrite' && NWFAILS="$NWFAILS NW11"
/bin/echo "$NHANDLE" | /usr/bin/grep -qF 'setDPI(' && NWFAILS="$NWFAILS NW12"
# UI 接线
/bin/echo "$NVSRC" | /usr/bin/grep -qF 'logi.setDPIPageVisible(true)' || NWFAILS="$NWFAILS NW13"
/bin/echo "$NVSRC" | /usr/bin/grep -qF 'logi.setDPIPageVisible(false)' || NWFAILS="$NWFAILS NW14"
/bin/echo "$NVSRC" | /usr/bin/grep -qF '当前硬件 DPI：' || NWFAILS="$NWFAILS NW15"
/bin/echo "$NVSRC" | /usr/bin/grep -qF 'logi.syncStatus' || NWFAILS="$NWFAILS NW16"
/bin/echo "$NVSRC" | /usr/bin/grep -qF 'case .ready(let cap, let current, let def)' || NWFAILS="$NWFAILS NW17"
# App 生命周期：窗口隐藏要停连接（App 失活绝不停），唤醒要重新探测
/bin/echo "$NAPP" | /usr/bin/grep -qF 'setSettingsVisible(true)' || NWFAILS="$NWFAILS NW18"
/bin/echo "$NAPP" | /usr/bin/grep -qF 'setSettingsVisible(false)' || NWFAILS="$NWFAILS NW19"
/bin/echo "$NAPP" | /usr/bin/grep -qF 'setAppActive' && NWFAILS="$NWFAILS NW20"
/bin/echo "$NAPP" | /usr/bin/grep -qF 'LogitechHIDPP.shared.refresh()' || NWFAILS="$NWFAILS NW21"
if [ -z "$NWFAILS" ]; then ok "N_W 接线守卫（同步链路只读 / 可见性门禁 / 状态与 UI 接线）"; else bad "N_W $NWFAILS"; fi

# 三趟变异：每次先确认 MUTANT 真的注入，再要求具体断言变红。
/usr/bin/sed 's|return v == baseline ? .noChange : .hardwareChanged(v)|return .noChange // MUTANT|' \
    Sources/LogitechHIDPP.swift > "$WORK/nmut/LogitechHIDPP.swift"
if ! /usr/bin/grep -q 'MUTANT' "$WORK/nmut/LogitechHIDPP.swift"; then
  bad "N_MUT 变异注入失败（前置没造出来，不能算验证过）"
elif NCOMPILE "$WORK/nmut" "$WORK/nm1" 2>"$WORK/nm1.log"; then
  NM1RC=0
  NM1OUT="$("$WORK/nm1" 2>&1)" || NM1RC=$?
  NM1MISSES=""
  for CASE in N2 N4; do
    /bin/echo "$NM1OUT" | grep -q "^FAIL $CASE" || NM1MISSES="$NM1MISSES $CASE"
  done
  if [ "$NM1RC" = "0" ] || [ -n "$NM1MISSES" ]; then
    bad "N_MUT 吞掉硬件切换没被抓红(rc=$NM1RC 漏报:$NM1MISSES)"
  else
    ok "N_MUT 变异验证（恒 noChange 会被 N2/N4 抓红）"
  fi
else
  bad "N_MUT 编译失败$(tail -3 "$WORK/nm1.log")"
fi

/usr/bin/sed 's|guard let v = observed, v > 0 else { return .readFailed }|guard let v = observed, v > 0 else { return .noChange } // MUTANT|' \
    Sources/LogitechHIDPP.swift > "$WORK/nmut/LogitechHIDPP.swift"
if ! /usr/bin/grep -q 'MUTANT' "$WORK/nmut/LogitechHIDPP.swift"; then
  bad "N_MUT2 变异注入失败（前置没造出来，不能算验证过）"
elif NCOMPILE "$WORK/nmut" "$WORK/nm2" 2>"$WORK/nm2.log"; then
  NM2RC=0
  NM2OUT="$("$WORK/nm2" 2>&1)" || NM2RC=$?
  NM2MISSES=""
  for CASE in N5 N6 N7; do
    /bin/echo "$NM2OUT" | grep -q "^FAIL $CASE" || NM2MISSES="$NM2MISSES $CASE"
  done
  if [ "$NM2RC" = "0" ] || [ -n "$NM2MISSES" ]; then
    bad "N_MUT2 读失败被吞没被抓红(rc=$NM2RC 漏报:$NM2MISSES)"
  else
    ok "N_MUT2 变异验证（读失败伪装成 noChange 会被 N5/N6/N7 抓红）"
  fi
else
  bad "N_MUT2 编译失败$(tail -3 "$WORK/nm2.log")"
fi

/usr/bin/sed 's|guard !writing else { return .ignoredWhileWriting }|_ = writing // MUTANT|' \
    Sources/LogitechHIDPP.swift > "$WORK/nmut/LogitechHIDPP.swift"
if ! /usr/bin/grep -q 'MUTANT' "$WORK/nmut/LogitechHIDPP.swift"; then
  bad "N_MUT3 变异注入失败（前置没造出来，不能算验证过）"
elif NCOMPILE "$WORK/nmut" "$WORK/nm3" 2>"$WORK/nm3.log"; then
  NM3RC=0
  NM3OUT="$("$WORK/nm3" 2>&1)" || NM3RC=$?
  NM3MISSES=""
  for CASE in N10 N11; do
    /bin/echo "$NM3OUT" | grep -q "^FAIL $CASE" || NM3MISSES="$NM3MISSES $CASE"
  done
  if [ "$NM3RC" = "0" ] || [ -n "$NM3MISSES" ]; then
    bad "N_MUT3 写入竞态门禁被抹掉没被抓红(rc=$NM3RC 漏报:$NM3MISSES)"
  else
    ok "N_MUT3 变异验证（去掉 writing 门禁会被 N10/N11 抓红）"
  fi
else
  bad "N_MUT3 编译失败$(tail -3 "$WORK/nm3.log")"
fi

# ---------------------------------------------------------------------------
# O 段：系统设置「去授权」跳转（2026-11-07）
# 真机：旧 URL 落到 Device Control and Data Access；System Settings 进程 hung 时
# LSOpenURLs 报 -1712 并弹英文 not responding。验「URL 契约 / 失败不吞 / 反馈三要素」。
# ---------------------------------------------------------------------------
/bin/mkdir -p "$WORK/odir"
/bin/cat > "$WORK/odir/main.swift" <<'OSWIFT'
import Foundation
var failures = 0
func require(_ c: @autoclosure () -> Bool, _ label: String) {
    if !c() { print("FAIL \(label)"); failures += 1 }
}

let u = AccessibilitySettingsLauncher.urlString
require(u.contains("com.apple.settings.PrivacySecurity.extension"), "O1 必须用新 PrivacySecurity 扩展 ID")
require(!u.contains("com.apple.preference.security"), "O2 不得残留旧 preference.security ID")
require(!u.contains("Privacy_Accessibility"), "O3 不得残留会落到 Device Control 页的旧 anchor")
require(URL(string: u)?.scheme == "x-apple.systempreferences", "O4 URL 可解析且 scheme 正确")

require(AccessibilitySettingsLauncher.outcome(errorDescription: nil) == .opened, "O5 无 error 才算成功")
let e = "The application System Settings is not responding (-1712)"
require(AccessibilitySettingsLauncher.outcome(errorDescription: e) == .failed(e), "O6 失败必须保留具体原因")
require(AccessibilitySettingsLauncher.outcome(errorDescription: "   ") == .failed("系统设置未返回具体错误"), "O7 空白原因不能伪装成成功")
require(AccessibilitySettingsLauncher.outcome(errorDescription: " -1712 ") == .failed("-1712"), "O8 原因要去首尾空白")
require(AccessibilitySettingsLauncher.outcome(errorDescription: "") == .failed("系统设置未返回具体错误"), "O14 空字符串原因也要判失败")

let m = AccessibilitySettingsLauncher.failureMessage(reason: e)
require(m.contains(e), "O9 失败文案必须带具体原因")
require(m.contains("重试"), "O10 失败文案必须给出可操作的重试")
require(m.contains(AccessibilitySettingsLauncher.manualPath), "O11 失败文案必须给手动路径")
require(m.contains("辅助功能") && m.contains("隐私与安全性"), "O12 手动路径要指明两层位置")
require(!m.contains("已授权") && !m.contains("打开成功"), "O13 失败文案不得伪装成成功")

if failures == 0 { print("O-OK") } else { exit(1) }
OSWIFT

OCOMPILE() {
  "$SWIFTC" $SMOOSE_SWIFT_EXTRA -Onone -sdk "$SDK" -target arm64-apple-macos14.0 \
    -o "$2" "$1/SettingsLauncher.swift" "$WORK/odir/main.swift"
}
/bin/mkdir -p "$WORK/omut"
/bin/cp Sources/SettingsLauncher.swift "$WORK/omut/SettingsLauncher.swift"
if OCOMPILE "$WORK/omut" "$WORK/o" 2>"$WORK/o.log"; then
  ORC=0
  OOUT="$("$WORK/o" 2>&1)" || ORC=$?
  OFAILS="$(/bin/echo "$OOUT" | grep '^FAIL' || true)"
  if [ "$ORC" != "0" ]; then OFAILS="$OFAILS O_EXIT(rc=$ORC 非零退出/崩溃)"; fi
  /bin/echo "$OOUT" | grep -q 'O-OK' || OFAILS="$OFAILS O_NOMARK(缺 O-OK 完成标记)"
  if [ -z "$OFAILS" ]; then ok "O 系统设置跳转：URL 契约 / 失败判定 / 反馈三要素（14 项）"; else bad "O $OFAILS"; fi
else
  bad "O 编译失败$(tail -3 "$WORK/o.log")"
fi

# O_W 接线守卫：纯逻辑全绿不代表引导页真的换了实现，也不代表新文件进了编译列表。
OWFAILS=""
OLSRC="$(/usr/bin/sed -E 's://.*$::' Sources/SettingsLauncher.swift)"
OVSRC="$(/usr/bin/sed -n '/^struct OnboardingView/,/^\/\/ MARK: - 组件/p' Sources/Views.swift | /usr/bin/sed -E 's://.*$::')"
OBUILD="$(/usr/bin/sed -E 's:^#.*$::' build.sh)"
OAPP="$(/usr/bin/sed -E 's://.*$::' Sources/App.swift)"

# 前置单独成条：范围抓空时，「没有旧 URL / 没有裸 open」这类断言会假绿。
/bin/echo "$OLSRC" | /usr/bin/grep -q '^enum AccessibilitySettingsLauncher' || OWFAILS="$OWFAILS OW_PRE1"
/bin/echo "$OVSRC" | /usr/bin/grep -q '^struct OnboardingView' || OWFAILS="$OWFAILS OW_PRE2"
/bin/echo "$OVSRC" | /usr/bin/grep -qF 'private func step(' || OWFAILS="$OWFAILS OW_PRE3"
/bin/echo "$OBUILD" | /usr/bin/grep -qF 'SettingsLauncher.swift' || OWFAILS="$OWFAILS OW1"
/bin/echo "$OLSRC" | /usr/bin/grep -qF 'com.apple.settings.PrivacySecurity.extension' || OWFAILS="$OWFAILS OW2"
/bin/echo "$OLSRC" | /usr/bin/grep -qF 'NSWorkspace.shared.open(url, configuration: configuration)' || OWFAILS="$OWFAILS OW3"
/bin/echo "$OVSRC" | /usr/bin/grep -qF 'AccessibilitySettingsLauncher.open()' || OWFAILS="$OWFAILS OW4"
/bin/echo "$OVSRC" | /usr/bin/grep -qF 'case .failed(let reason)' || OWFAILS="$OWFAILS OW5"
/bin/echo "$OVSRC" | /usr/bin/grep -qF 'AccessibilitySettingsLauncher.failureMessage(reason: reason)' || OWFAILS="$OWFAILS OW6"
/bin/echo "$OVSRC" | /usr/bin/grep -qF 'Button("重试")' || OWFAILS="$OWFAILS OW7"
/bin/echo "$OVSRC" | /usr/bin/grep -qF 'if let launchFailure' || OWFAILS="$OWFAILS OW8"
/bin/echo "$OVSRC" | /usr/bin/grep -qF 'AccessibilitySettingsLauncher.manualPath' || OWFAILS="$OWFAILS OW9"
/bin/echo "$OAPP" | /usr/bin/grep -qF 'showOnboarding(force: true)' || OWFAILS="$OWFAILS OW12"
# 旧实现必须彻底消失：裸 open + 旧 URL 任何一个残留都算没修干净。
/bin/echo "$OVSRC" | /usr/bin/grep -qF 'NSWorkspace.shared.open(url)' && OWFAILS="$OWFAILS OW10"
/bin/echo "$OVSRC" | /usr/bin/grep -qF 'com.apple.preference.security' && OWFAILS="$OWFAILS OW11"
if [ -z "$OWFAILS" ]; then ok "O_W 接线守卫（引导页换实现 / 失败可见 / 编译列表接线）"; else bad "O_W $OWFAILS"; fi

# 三趟变异：先确认 MUTANT 真的注入，再要求具体断言变红。
/usr/bin/sed 's|return trimmed.isEmpty ? .failed("系统设置未返回具体错误") : .failed(trimmed)|return .opened // MUTANT|' \
    Sources/SettingsLauncher.swift > "$WORK/omut/SettingsLauncher.swift"
if ! /usr/bin/grep -q 'MUTANT' "$WORK/omut/SettingsLauncher.swift"; then
  bad "O_MUT 变异注入失败（前置没造出来，不能算验证过）"
elif OCOMPILE "$WORK/omut" "$WORK/om1" 2>"$WORK/om1.log"; then
  OM1RC=0
  OM1OUT="$("$WORK/om1" 2>&1)" || OM1RC=$?
  OM1MISSES=""
  for CASE in O6 O7 O8 O14; do
    /bin/echo "$OM1OUT" | grep -q "^FAIL $CASE" || OM1MISSES="$OM1MISSES $CASE"
  done
  if [ "$OM1RC" = "0" ] || [ -n "$OM1MISSES" ]; then
    bad "O_MUT 恒绿失败判定没被抓红(rc=$OM1RC 漏报:$OM1MISSES)"
  else
    ok "O_MUT 变异验证（把失败伪装成成功会被 O6/O7/O8/O14 抓红）"
  fi
else
  bad "O_MUT 编译失败$(tail -3 "$WORK/om1.log")"
fi

/usr/bin/sed 's|"打开系统设置失败.*勾选 Smoose。"|"打开系统设置失败" // MUTANT|' \
    Sources/SettingsLauncher.swift > "$WORK/omut/SettingsLauncher.swift"
if ! /usr/bin/grep -q 'MUTANT' "$WORK/omut/SettingsLauncher.swift"; then
  bad "O_MUT2 变异注入失败（前置没造出来，不能算验证过）"
elif OCOMPILE "$WORK/omut" "$WORK/om2" 2>"$WORK/om2.log"; then
  OM2RC=0
  OM2OUT="$("$WORK/om2" 2>&1)" || OM2RC=$?
  OM2MISSES=""
  for CASE in O9 O10 O11 O12; do
    /bin/echo "$OM2OUT" | grep -q "^FAIL $CASE" || OM2MISSES="$OM2MISSES $CASE"
  done
  if [ "$OM2RC" = "0" ] || [ -n "$OM2MISSES" ]; then
    bad "O_MUT2 空壳失败文案没被抓红(rc=$OM2RC 漏报:$OM2MISSES)"
  else
    ok "O_MUT2 变异验证（抹掉原因/重试/手动路径会被 O9-O12 抓红）"
  fi
else
  bad "O_MUT2 编译失败$(tail -3 "$WORK/om2.log")"
fi

/usr/bin/sed 's|com.apple.settings.PrivacySecurity.extension?privacy-accessibility|com.apple.preference.security?Privacy_Accessibility|' \
    Sources/SettingsLauncher.swift > "$WORK/omut/SettingsLauncher.swift"
# 只看代码、不看注释：注释里本来就会提到新扩展 ID，否则前置会被自己的文档误伤。
OM3CODE="$(/usr/bin/sed -E 's://.*$::' "$WORK/omut/SettingsLauncher.swift")"
if ! /bin/echo "$OM3CODE" | /usr/bin/grep -qF 'com.apple.preference.security?Privacy_Accessibility' \
   || /bin/echo "$OM3CODE" | /usr/bin/grep -qF 'com.apple.settings.PrivacySecurity.extension'; then
  bad "O_MUT3 变异注入失败（前置没造出来，不能算验证过）"
elif OCOMPILE "$WORK/omut" "$WORK/om3" 2>"$WORK/om3.log"; then
  OM3RC=0
  OM3OUT="$("$WORK/om3" 2>&1)" || OM3RC=$?
  OM3MISSES=""
  for CASE in O1 O2 O3; do
    /bin/echo "$OM3OUT" | grep -q "^FAIL $CASE" || OM3MISSES="$OM3MISSES $CASE"
  done
  if [ "$OM3RC" = "0" ] || [ -n "$OM3MISSES" ]; then
    bad "O_MUT3 旧 deep link 回退没被抓红(rc=$OM3RC 漏报:$OM3MISSES)"
  else
    ok "O_MUT3 变异验证（换回旧 URL 会被 O1/O2/O3 抓红）"
  fi
else
  bad "O_MUT3 编译失败$(tail -3 "$WORK/om3.log")"
fi

# ---------------------------------------------------------------------------
# P 段：光标放大「开启不生效」（2026-11-07）
# 真机：键 CGDisableCursorLocationMagnification 是对的（GUI 点开关只改这一个键），
# 但第三方只写 plist 不会让系统即时加载；旧实现写完就报绿、Toggle 立刻变蓝 = 假绿。
# 验「反相映射 / 写后独立读回 / 待重新登录文案 / Display 页 URL」。
# ---------------------------------------------------------------------------
/bin/mkdir -p "$WORK/pdir" "$WORK/pmut"
/bin/cat > "$WORK/pdir/main.swift" <<'PSWIFT'
import Foundation
var failures = 0
func require(_ c: @autoclosure () -> Bool, _ label: String) {
    if !c() { print("FAIL \(label)"); failures += 1 }
}

require(CursorZoomPolicy.key == "CGDisableCursorLocationMagnification", "P1 偏好键必须是反相的 CG 键")
require(CursorZoomPolicy.domain == ".GlobalPreferences", "P2 必须写全局域（standard 域不落盘）")
require(CursorZoomPolicy.storedValue(enabled: true) == false, "P3 功能开必须写 false")
require(CursorZoomPolicy.storedValue(enabled: false) == true, "P4 功能关必须写 true")
require(CursorZoomPolicy.systemEnabled(stored: nil) == true, "P5 键缺失按系统默认开")
require(CursorZoomPolicy.systemEnabled(stored: false) == true, "P6 存 false 表示功能开")
require(CursorZoomPolicy.systemEnabled(stored: true) == false, "P7 存 true 表示功能关")

require(CursorZoomPolicy.verdict(writeOK: false, readBack: false, expected: false) == .writeFailed,
        "P8 写失败不能算成功")
require(CursorZoomPolicy.verdict(writeOK: true, readBack: nil, expected: false)
        == .readBackMismatch(expected: false, actual: nil), "P9 读不到必须报具体 mismatch，不能算成功")
require(CursorZoomPolicy.verdict(writeOK: true, readBack: true, expected: false)
        == .readBackMismatch(expected: false, actual: true), "P10 读回不一致必须带实际值")
require(CursorZoomPolicy.verdict(writeOK: true, readBack: false, expected: false)
        == .writtenPendingRelogin, "P11 一致才算写入完成（仍待重新登录）")
require(CursorZoomApplyResult.writtenPendingRelogin.ok, "P12 只有写入完成允许保留开关")
require(!CursorZoomApplyResult.writeFailed.ok && !CursorZoomApplyResult.suiteUnavailable.ok,
        "P13 写入失败必须回弹")
require(!CursorZoomApplyResult.readBackMismatch(expected: false, actual: nil).ok,
        "P14 读回失败必须回弹")

let okMsg = CursorZoomPolicy.statusMessage(.writtenPendingRelogin)
require(okMsg.contains("已写入"), "P15 成功文案必须说明写好了")
require(okMsg.contains("重新登录"), "P16 成功文案必须说明生效条件")
require(okMsg.contains("系统设置") && okMsg.contains("开关"), "P17 必须给可操作路径")
require(!okMsg.contains("已生效") && !okMsg.contains("立即生效"), "P18 不得伪装成即时生效")

let failMsgs = [
    CursorZoomPolicy.statusMessage(.suiteUnavailable),
    CursorZoomPolicy.statusMessage(.writeFailed),
    CursorZoomPolicy.statusMessage(.readBackMismatch(expected: false, actual: true)),
]
for (i, m) in failMsgs.enumerated() {
    require(m.contains("重试"), "P19.\(i) 失败文案必须给可操作的重试")
    require(m.contains("失败"), "P20.\(i) 失败文案必须标明失败")
}
require(CursorZoomPolicy.statusMessage(.readBackMismatch(expected: false, actual: true)).contains("true"),
        "P21 mismatch 必须带实际读回值")
require(CursorZoomPolicy.statusMessage(.readBackMismatch(expected: false, actual: nil)).contains("读不到"),
        "P22 读不到必须明说，不能含糊成失败")

let du = DisplaySettingsLauncher.urlString
require(URL(string: du)?.scheme == "x-apple.systempreferences", "P23 URL scheme 正确且可解析")
require(du.contains("com.apple.Accessibility-Settings.extension") && du.contains("?display"),
        "P24 必须是辅助功能扩展 + Display anchor")
require(!du.contains("Privacy_Accessibility") && !du.contains("PrivacySecurity"),
        "P25 不得复用「去授权」的隐私页 URL")
require(DisplaySettingsLauncher.manualPath.contains("辅助功能")
        && DisplaySettingsLauncher.manualPath.contains("显示"), "P26 手动路径要指明两层位置")
let dm = DisplaySettingsLauncher.failureMessage(reason: "-1712")
require(dm.contains("-1712") && dm.contains("重试")
        && dm.contains(DisplaySettingsLauncher.manualPath), "P27 失败反馈三要素")

// 冷启动实证：带 anchor 的单 URL 只到 Accessibility 首页，必须「先基础、后 anchor」两步。
let seq = DisplaySettingsLauncher.urlSequence()
require(seq.count == 2, "P28 冷启动必须两步，单发 anchor 会只到首页")
require(!seq[0].contains("?") && seq[0].contains("Accessibility-Settings.extension"),
        "P29 第一步不能带 anchor（冷启动会被丢弃）")
require(seq.count > 1 && seq[1] == seq[0] + "?display",
        "P30 第二步必须是在第一步基础上加 display anchor")
require(seq.count > 1 && URL(string: seq[0])?.scheme == "x-apple.systempreferences"
        && URL(string: seq[1])?.scheme == "x-apple.systempreferences", "P31 两步 URL 都可解析")

if failures == 0 { print("P-OK") } else { exit(1) }
PSWIFT

PCOMPILE() {
  "$SWIFTC" $SMOOSE_SWIFT_EXTRA -Onone -sdk "$SDK" -target arm64-apple-macos14.0 \
    -o "$2" "$1/CursorZoom.swift" "$1/SettingsLauncher.swift" "$WORK/pdir/main.swift"
}
/bin/cp Sources/CursorZoom.swift Sources/SettingsLauncher.swift "$WORK/pmut/"
if PCOMPILE "$WORK/pmut" "$WORK/p" 2>"$WORK/p.log"; then
  PRC=0
  POUT="$("$WORK/p" 2>&1)" || PRC=$?
  PFAILS="$(/bin/echo "$POUT" | /usr/bin/grep '^FAIL' || true)"
  if [ "$PRC" != "0" ]; then PFAILS="$PFAILS P_EXIT(rc=$PRC 非零退出/崩溃)"; fi
  /bin/echo "$POUT" | /usr/bin/grep -q 'P-OK' || PFAILS="$PFAILS P_NOMARK(缺 P-OK 完成标记)"
  if [ -z "$PFAILS" ]; then ok "P 光标放大：反相映射 / 写后读回 / 待重新登录文案 / 两步 URL（31 项）"; else bad "P $PFAILS"; fi
else
  bad "P 编译失败$(/usr/bin/tail -3 "$WORK/p.log")"
fi

# P_W 接线守卫：纯逻辑全绿不代表指针页真的换了实现、也不代表读回真的独立。
PWFAILS=""
PCSRC="$(/usr/bin/sed -E 's://.*$::' Sources/CursorZoom.swift)"
PVSRC="$(/usr/bin/sed -n '/^struct PointerTab/,/^}$/p' Sources/Views.swift | /usr/bin/sed -E 's://.*$::')"
PSSRC="$(/usr/bin/sed -E 's://.*$::' Sources/SettingsLauncher.swift)"
PBUILD="$(/usr/bin/sed -E 's:^#.*$::' build.sh)"

# 前置单独成条：范围抓空时「没有旧实现」这类断言会假绿。
/bin/echo "$PCSRC" | /usr/bin/grep -q '^enum CursorZoomPolicy' || PWFAILS="$PWFAILS PW_PRE1"
/bin/echo "$PVSRC" | /usr/bin/grep -q '^struct PointerTab' || PWFAILS="$PWFAILS PW_PRE2"
/bin/echo "$PSSRC" | /usr/bin/grep -q '^enum DisplaySettingsLauncher' || PWFAILS="$PWFAILS PW_PRE3"
/bin/echo "$PBUILD" | /usr/bin/grep -qF 'CursorZoom.swift' || PWFAILS="$PWFAILS PW1"
/bin/echo "$PBUILD" | /usr/bin/grep -qF 'SettingsLauncher.swift' || PWFAILS="$PWFAILS PW2"
/bin/echo "$PCSRC" | /usr/bin/grep -qF 'CFPreferencesCopyValue' || PWFAILS="$PWFAILS PW3"
/bin/echo "$PCSRC" | /usr/bin/grep -qF 'CursorZoomPolicy.verdict(' || PWFAILS="$PWFAILS PW4"
/bin/echo "$PCSRC" | /usr/bin/grep -qF 'func apply(_ enabled: Bool) -> CursorZoomApplyResult' || PWFAILS="$PWFAILS PW5"
/bin/echo "$PCSRC" | /usr/bin/grep -qF 'let writeOK = d.synchronize()' || PWFAILS="$PWFAILS PW6"
/bin/echo "$PVSRC" | /usr/bin/grep -qF 'isOn: cursorZoomBinding' || PWFAILS="$PWFAILS PW7"
/bin/echo "$PVSRC" | /usr/bin/grep -qF 'CursorZoomController.shared.apply(enabled)' || PWFAILS="$PWFAILS PW8"
/bin/echo "$PVSRC" | /usr/bin/grep -qF 'if result.ok { prefs.cursorZoomEnabled = enabled }' || PWFAILS="$PWFAILS PW9"
/bin/echo "$PVSRC" | /usr/bin/grep -qF 'CursorZoomPolicy.statusMessage(zoomResult)' || PWFAILS="$PWFAILS PW10"
/bin/echo "$PVSRC" | /usr/bin/grep -qF 'DisplaySettingsLauncher.open()' || PWFAILS="$PWFAILS PW11"
/bin/echo "$PVSRC" | /usr/bin/grep -qF 'Button("重试")' || PWFAILS="$PWFAILS PW12"
/bin/echo "$PVSRC" | /usr/bin/grep -qF 'if let zoomLaunchFailure' || PWFAILS="$PWFAILS PW13"
/bin/echo "$PVSRC" | /usr/bin/grep -qF '当前显示的是系统偏好值' || PWFAILS="$PWFAILS PW14"
# 两步 URL 不能只是写在注释里：open() 必须真的依次发两个 URL。
/bin/echo "$PSSRC" | /usr/bin/grep -qF 'static func urlSequence() -> [String] { [baseURLString, urlString] }' || PWFAILS="$PWFAILS PW18"
/bin/echo "$PSSRC" | /usr/bin/grep -qF 'for (index, string) in urlSequence().enumerated()' || PWFAILS="$PWFAILS PW19"
/bin/echo "$PSSRC" | /usr/bin/grep -qF 'let result = await openOne(string)' || PWFAILS="$PWFAILS PW20"
/bin/echo "$PSSRC" | /usr/bin/grep -qF 'if index > 0 { try? await Task.sleep' || PWFAILS="$PWFAILS PW21"
# 旧实现必须彻底消失：裸绑定 + onChange 直写 + 无返回值的 apply。
/bin/echo "$PVSRC" | /usr/bin/grep -qF 'isOn: $prefs.cursorZoomEnabled' && PWFAILS="$PWFAILS PW15"
/bin/echo "$PVSRC" | /usr/bin/grep -qF '.onChange(of: prefs.cursorZoomEnabled)' && PWFAILS="$PWFAILS PW16"
/bin/echo "$PCSRC" | /usr/bin/grep -qF 'func apply(_ enabled: Bool) {' && PWFAILS="$PWFAILS PW17"
if [ -z "$PWFAILS" ]; then ok "P_W 接线守卫（独立读回 / 失败回弹 / 生效提示 / 编译列表接线）"; else bad "P_W $PWFAILS"; fi

# 三趟变异：先确认 MUTANT 真的注入，再要求具体断言变红。
/bin/cp Sources/SettingsLauncher.swift "$WORK/pmut/SettingsLauncher.swift"
/usr/bin/sed \
  -e 's|guard writeOK else { return .writeFailed }|if !writeOK { return .writtenPendingRelogin } // MUTANT|' \
  -e 's|return .readBackMismatch(expected: expected, actual: nil)|return .writtenPendingRelogin // MUTANT|' \
  -e 's|return actual == expected|return actual == actual // MUTANT|' \
  Sources/CursorZoom.swift > "$WORK/pmut/CursorZoom.swift"
if [ "$(/usr/bin/grep -c 'MUTANT' "$WORK/pmut/CursorZoom.swift")" != "3" ]; then
  bad "P_MUT 变异注入失败（前置没造出来，不能算验证过）"
elif PCOMPILE "$WORK/pmut" "$WORK/pm1" 2>"$WORK/pm1.log"; then
  PM1RC=0
  PM1OUT="$("$WORK/pm1" 2>&1)" || PM1RC=$?
  PM1MISSES=""
  for CASE in P8 P9 P10; do
    /bin/echo "$PM1OUT" | /usr/bin/grep -q "^FAIL $CASE" || PM1MISSES="$PM1MISSES $CASE"
  done
  if [ "$PM1RC" = "0" ] || [ -n "$PM1MISSES" ]; then
    bad "P_MUT 恒绿写入判定没被抓红(rc=$PM1RC 漏报:$PM1MISSES)"
  else
    ok "P_MUT 变异验证（恒绿判定会被 P8/P9/P10 抓红）"
  fi
else
  bad "P_MUT 编译失败$(/usr/bin/tail -3 "$WORK/pm1.log")"
fi

/usr/bin/sed 's|需重新登录才生效|已立即生效|' \
  Sources/CursorZoom.swift > "$WORK/pmut/CursorZoom.swift"
if ! /usr/bin/grep -q '已立即生效' "$WORK/pmut/CursorZoom.swift" \
   || /usr/bin/grep -q '需重新登录才生效' "$WORK/pmut/CursorZoom.swift"; then
  bad "P_MUT2 变异注入失败（前置没造出来，不能算验证过）"
elif PCOMPILE "$WORK/pmut" "$WORK/pm2" 2>"$WORK/pm2.log"; then
  PM2RC=0
  PM2OUT="$("$WORK/pm2" 2>&1)" || PM2RC=$?
  PM2MISSES=""
  for CASE in P16 P18; do
    /bin/echo "$PM2OUT" | /usr/bin/grep -q "^FAIL $CASE" || PM2MISSES="$PM2MISSES $CASE"
  done
  if [ "$PM2RC" = "0" ] || [ -n "$PM2MISSES" ]; then
    bad "P_MUT2 假绿文案没被抓红(rc=$PM2RC 漏报:$PM2MISSES)"
  else
    ok "P_MUT2 变异验证（抹掉生效条件 / 宣称立即生效会被 P16/P18 抓红）"
  fi
else
  bad "P_MUT2 编译失败$(/usr/bin/tail -3 "$WORK/pm2.log")"
fi

/bin/cp Sources/CursorZoom.swift "$WORK/pmut/CursorZoom.swift"
/usr/bin/sed 's|static let urlString = baseURLString + "?display"|static let urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" // MUTANT|' \
  Sources/SettingsLauncher.swift > "$WORK/pmut/SettingsLauncher.swift"
# 只看代码不看注释：文件顶部注释里本来就有旧 URL，否则前置会被自己的文档误伤。
PM3CODE="$(/usr/bin/sed -E 's://.*$::' "$WORK/pmut/SettingsLauncher.swift")"
if ! /bin/echo "$PM3CODE" | /usr/bin/grep -qF 'com.apple.preference.security?Privacy_Accessibility' \
   || /bin/echo "$PM3CODE" | /usr/bin/grep -qF 'static let urlString = baseURLString + "?display"'; then
  bad "P_MUT3 变异注入失败（前置没造出来，不能算验证过）"
elif PCOMPILE "$WORK/pmut" "$WORK/pm3" 2>"$WORK/pm3.log"; then
  PM3RC=0
  PM3OUT="$("$WORK/pm3" 2>&1)" || PM3RC=$?
  PM3MISSES=""
  for CASE in P24 P25 P30; do
    /bin/echo "$PM3OUT" | /usr/bin/grep -q "^FAIL $CASE" || PM3MISSES="$PM3MISSES $CASE"
  done
  if [ "$PM3RC" = "0" ] || [ -n "$PM3MISSES" ]; then
    bad "P_MUT3 旧 deeplink 回退没被抓红(rc=$PM3RC 漏报:$PM3MISSES)"
  else
    ok "P_MUT3 变异验证（换回去授权 URL 会被 P24/P25/P30 抓红）"
  fi
else
  bad "P_MUT3 编译失败$(/usr/bin/tail -3 "$WORK/pm3.log")"
fi

# 第四趟：抹掉两步法的第一步（冷启动只发 anchor）必须被 P28/P29/P30 抓红。
/bin/cp Sources/CursorZoom.swift "$WORK/pmut/CursorZoom.swift"
/usr/bin/sed 's|static func urlSequence() -> \[String\] { \[baseURLString, urlString\] }|static func urlSequence() -> [String] { [urlString] } // MUTANT|' \
  Sources/SettingsLauncher.swift > "$WORK/pmut/SettingsLauncher.swift"
if ! /usr/bin/grep -q 'MUTANT' "$WORK/pmut/SettingsLauncher.swift" \
   || /usr/bin/grep -qF 'static func urlSequence() -> [String] { [baseURLString, urlString] }' "$WORK/pmut/SettingsLauncher.swift"; then
  bad "P_MUT4 变异注入失败（前置没造出来，不能算验证过）"
elif PCOMPILE "$WORK/pmut" "$WORK/pm4" 2>"$WORK/pm4.log"; then
  PM4RC=0
  PM4OUT="$("$WORK/pm4" 2>&1)" || PM4RC=$?
  PM4MISSES=""
  for CASE in P28 P29 P30; do
    /bin/echo "$PM4OUT" | /usr/bin/grep -q "^FAIL $CASE" || PM4MISSES="$PM4MISSES $CASE"
  done
  if [ "$PM4RC" = "0" ] || [ -n "$PM4MISSES" ]; then
    bad "P_MUT4 单发 anchor 没被抓红(rc=$PM4RC 漏报:$PM4MISSES)"
  else
    ok "P_MUT4 变异验证（去掉冷启动基础 URL 会被 P28/P29/P30 抓红）"
  fi
else
  bad "P_MUT4 编译失败$(/usr/bin/tail -3 "$WORK/pm4.log")"
fi

echo
echo "== 结果: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" = "0" ]
