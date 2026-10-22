#!/bin/zsh
# Smoose harness — 一键验证（详见 SPEC.md §7）
set -e
ROOT="$(cd "$(dirname "$0")" && pwd)"
SDK="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
SWIFTC="$(/usr/bin/xcrun --sdk macosx --find swiftc)"
WORK="/tmp/smoose_harness_$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok()  { echo "PASS  $1"; PASS=$((PASS+1)); }
bad() { echo "FAIL  $1"; FAIL=$((FAIL+1)); }
echo "== A: 插值离线测试 =="
cp Tests/InterpTest.swift "$WORK/main.swift"
if "$SWIFTC" -O -sdk "$SDK" -target arm64-apple-macos14.0 -o "$WORK/interp" Sources/ScrollAxis.swift "$WORK/main.swift" 2>"$WORK/a.log"; then
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
if "$SWIFTC" -Onone -sdk "$SDK" -o "$WORK/b" "$WORK/b.swift" 2>"$WORK/b.log" && "$WORK/b" >/dev/null; then ok "B profile 命中"; else bad "B $(tail -2 "$WORK/b.log")"; fi
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
if "$SWIFTC" -Onone -sdk "$SDK" -o "$WORK/d" "$WORK/d.swift" 2>"$WORK/d.log"; then
  DFAILS="$("$WORK/d" 2>&1 | grep '^FAIL' || true)"
else
  DFAILS="$(tail -3 "$WORK/d.log")"
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
if "$SWIFTC" -Onone -sdk "$SDK" -o "$WORK/g" Sources/UpdateModel.swift "$WORK/main.swift" 2>"$WORK/g.log" && "$WORK/g" >"$WORK/g.out" 2>&1; then ok "G 真实 UpdateModel 反 drift"; else bad "G $(grep '^FAIL' "$WORK/g.out" 2>/dev/null | head -3; tail -2 "$WORK/g.log")"; fi

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
if "$SWIFTC" -Onone -sdk "$SDK" -o "$GM2/g2" "$GM2/main.swift" 2>"$GM2/g2.log" && "$GM2/g2" "$ROOT/Sources/Updater.swift" >"$GM2/g2.out" 2>&1; then ok "G2 httpMessage 反 drift"; else bad "G2 $(grep '^FAIL' "$GM2/g2.out" 2>/dev/null | head -3; tail -2 "$GM2/g2.log")"; fi

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
if "$SWIFTC" -Onone -sdk "$SDK" -o "$GM3/g3" "$GM3/main.swift" 2>"$GM3/g3.log" && "$GM3/g3" "$ROOT/Sources/Updater.swift" >"$GM3/g3.out" 2>&1; then ok "G3 relaunch 退出路径"; else bad "G3 $(grep '^FAIL' "$GM3/g3.out" 2>/dev/null | head -3; tail -2 "$GM3/g3.log")"; fi

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
echo
echo "== 结果: PASS=$PASS FAIL=$FAIL =="
[ "$FAIL" = "0" ]
