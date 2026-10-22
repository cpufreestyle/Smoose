import Foundation

// MARK: - 语义化版本号

/// 纯逻辑、无 I/O —— harness 可离线编译断言（SPEC §21）。
/// 归一化规则：去掉尾部 0，所以 "1.0" == "1.0.0" == "1"。
struct SemVer: Equatable, Comparable {
    let numbers: [Int]
    /// 预发布标识（"-beta.1" 拆成 ["beta","1"]）；空数组 = 正式版
    let prerelease: [String]

    init?(string raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.first == "v" || s.first == "V" { s.removeFirst() }
        // build metadata（"+" 之后）不参与比较
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

    /// 归一化字符串，至少三段，如 "1.2.0"
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

    /// semver 规则：预发布版 < 正式版；数字标识 < 字母标识
    static func prereleaseLess(_ a: [String], _ b: [String]) -> Bool {
        if a.isEmpty { return false }     // a 正式、b 预发布 → a 不小
        if b.isEmpty { return true }      // a 预发布、b 正式 → a 更小
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

// MARK: - 更新清单

/// 支持两种版本源形状：
/// 1) 自建 JSON：{"version":"1.1.0","url":"https://.../Smoose.zip","notes":"...","minSystem":"14.0"}
/// 2) GitHub Releases API：{"tag_name":"v1.1.0","assets":[{"browser_download_url":"..."}],"body":"..."}
struct UpdateManifest: Decodable, Equatable {
    var version: String
    var url: String?
    var notes: String?
    var minSystem: String?

    init(version: String, url: String? = nil, notes: String? = nil, minSystem: String? = nil) {
        self.version = version
        self.url = url
        self.notes = notes
        self.minSystem = minSystem
    }

    private enum CodingKeys: String, CodingKey {
        case version, tagName = "tag_name", name, url, downloadURL = "download_url"
        case notes, body, releaseNotes = "release_notes"
        case minSystem, minSystemVersion = "minimum_system_version"
        case assets, browserDownloadURL = "browser_download_url"
        case contentType = "content_type"
    }

    private struct Asset: Decodable {
        var browserDownloadURL: String?
        var name: String?
        var contentType: String?
        // 必须有 CodingKeys：GitHub 发的是 snake_case（browser_download_url / content_type），
        // 而合成解码默认按属性名 camelCase 去找。少了这个映射，name 因为两种拼写相同还能解出来，
        // 但下载地址和 content_type 会静默变成 nil —— 结果是「发现了新版却下载不到安装包」
        // （2026-10-22 端到端实测：真 feed 解出 version=1.2.0 但 url=nil）。
        private enum CodingKeys: String, CodingKey {
            case browserDownloadURL = "browser_download_url", name, contentType = "content_type"
        }
    }

    private static func looksLikeArchive(_ s: String?) -> Bool {
        let n = (s ?? "").lowercased()
        if n.hasSuffix(".zip") || n.hasSuffix(".dmg") || n.hasSuffix(".tar.gz") { return true }
        // GitHub 的 content_type 是 MIME 形式（application/zip、application/x-apple-diskimage），
        // 没有 .zip 后缀 —— 不认这个就会「看得到新版、下载不到安装包」。
        return n.hasSuffix("application/zip") || n.hasSuffix("application/x-zip-compressed")
            || n.hasSuffix("application/x-apple-diskimage")
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // 版本号：自建用 version，GitHub 用 tag_name。name 也能解析时才兜底
        // （GitHub 的 name 常是 "Smoose 1.1.0" 这种标题，解析不出来就跳过）
        var rawVersion: String?
        for key in [CodingKeys.version, .tagName, .name] {
            if let s = try c.decodeIfPresent(String.self, forKey: key), SemVer(string: s) != nil {
                rawVersion = s
                break
            }
        }
        guard let rawVersion, let sv = SemVer(string: rawVersion) else {
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: c,
                debugDescription: "版本源缺少可解析的 version / tag_name 字段")
        }
        version = sv.string
        notes = try (c.decodeIfPresent(String.self, forKey: .notes)
            ?? c.decodeIfPresent(String.self, forKey: .body)
            ?? c.decodeIfPresent(String.self, forKey: .releaseNotes))
        minSystem = try (c.decodeIfPresent(String.self, forKey: .minSystem)
            ?? c.decodeIfPresent(String.self, forKey: .minSystemVersion))

        let assets = try c.decodeIfPresent([Asset].self, forKey: .assets) ?? []
        // GitHub 的 release.url 是 API 地址不是下载地址，只有自建清单的 url/download_url
        // 以安装包结尾时才敢直接用；否则必须走 assets 里的 browser_download_url。
        let direct = try (c.decodeIfPresent(String.self, forKey: .url)
            ?? c.decodeIfPresent(String.self, forKey: .downloadURL))
        if let direct, Self.looksLikeArchive(direct) {
            url = direct
        } else if let asset = assets.first(where: { Self.looksLikeArchive($0.name) || Self.looksLikeArchive($0.contentType) }) {
            url = asset.browserDownloadURL
        } else {
            url = nil
        }
    }
}

// MARK: - 更新决策

enum UpdateDecision: Equatable {
    case upToDate
    case available(UpdateManifest)
    /// 有新版，但当前 macOS 低于清单要求的最低系统版本
    case systemTooOld(UpdateManifest, required: String)
    case malformed(String)
}

/// 纯逻辑：给定当前版本 / 系统版本 / 版本源字节，得出更新决策。
enum UpdateCheck {
    static func decide(current: String, osVersion: String, data: Data) -> UpdateDecision {
        let manifest: UpdateManifest
        do {
            manifest = try JSONDecoder().decode(UpdateManifest.self, from: data)
        } catch {
            return .malformed("版本源格式无法解析：\(error.localizedDescription)")
        }
        guard let cur = SemVer(string: current) else {
            return .malformed("当前版本号无法解析：\(current)")
        }
        guard let new = SemVer(string: manifest.version) else {
            return .malformed("版本源版本号无法解析：\(manifest.version)")
        }
        // 系统门槛：解析不了系统版本时放行，不让用户卡死在"无法检查"
        if let min = manifest.minSystem, let need = SemVer(string: min),
           let os = SemVer(string: osVersion), os < need {
            return .systemTooOld(manifest, required: min)
        }
        return new > cur ? .available(manifest) : .upToDate
    }
}
