import Foundation
import AppKit
import CryptoKit

/// 自动更新：拉版本源 → 比较 → 下载安装包 → 解压 → 替换 → 重启。
/// 零第三方依赖，刻意不用 Sparkle：本项目没有 appcast feed、没有 EdDSA 发布签名链，
/// 也没有 git remote，引入 Sparkle 只会得到一个永远报错的更新器。
final class Updater: ObservableObject {

    static let shared = Updater()

    // 默认版本源：GitHub Releases latest。仓库由用户在「关于」页填一次，
    // 留空则指向官方预期地址（建好仓库后开箱即用）。
    static let defaultFeedURL = "https://api.github.com/repos/cpufreestyle/Smoose/releases/latest"
    /// 检查间隔：24 小时
    static let checkInterval: TimeInterval = 24 * 60 * 60
    /// 检查失败后的重试间隔：1 小时。
    /// 失败时同样写 lastCheck 时间戳，所以必须配这个短间隔 ——
    /// 否则启动时断一次网，接下来 24 小时都不会再静默检查（2026-10-22 实测缺陷）。
    static let retryInterval: TimeInterval = 60 * 60
    /// 目标 App 的 bundle id。安装前校验，防止一个不相关的 zip 覆盖掉用户的 App。
    ///
    /// ⚠️ bundle id 只是 Info.plist 里的一个字符串，谁都能写成这个值 —— 它只能挡住
    /// 「下错包」这种误操作，挡不住攻击者。真正的身份校验走 `expectedTeamIdentifier`。
    static let bundleIdentifier = "app.smoose.macos"

    /// 期望的签名 Team ID（10 位）。更新包必须由它签名，才允许覆盖 /Applications/Smoose.app。
    ///
    /// 本 App 持有辅助功能权限（能监听并合成全局输入），所以「更新」这条链路等价于
    /// 远程代码执行入口：任何人只要能改版本源响应或劫持下载，就能把任意代码放进这个
    /// 高权限位置。因此除了 bundle id，还必须校验 codesign 身份。
    ///
    /// fork 请改这里（或在 Info.plist 里加 `SmooseUpdateTeamID` 覆盖），
    /// 否则你签出来的包会被自己拒绝安装。
    ///
    /// ⚠️ 这个值必须取 `codesign --display --verbose=4` 输出的 TeamIdentifier，
    /// **不是** 签名身份 CN 里那串括号内容。实测（2026-10-26）：用
    /// "Apple Development: qm0819@hotmail.com (5F66DDWD6H)" 签出来的包，
    /// TeamIdentifier 是 6U2DQJ6Z2N —— 两串不一样，照抄证书名会让每次更新都被拒。
    static var expectedTeamIdentifier: String {
        if let v = Bundle.main.infoDictionary?["SmooseUpdateTeamID"] as? String,
           !v.trimmingCharacters(in: .whitespaces).isEmpty {
            return v.trimmingCharacters(in: .whitespaces)
        }
        return "6U2DQJ6Z2N"
    }

    enum Phase: Equatable {
        case idle
        case checking
        /// 发现了新版本，等用户点「下载并安装」。带上版本号，界面好显示。
        case updateFound(String)
        case downloading(progress: Double)
        case installing
        case readyToRelaunch(String)
        /// 用户此前跳过这个版本；手动检查时明确告知，而不是什么都不说
        case skipped(String)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .checking, .downloading, .installing: return true
            default: return false
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    /// 最近一次检查时间
    @Published private(set) var lastCheckedAt: Date?
    /// 上次发现的新版本（用于界面常驻提示）
    @Published private(set) var available: UpdateManifest?
    /// 用户点过「跳过此版本」的版本号集合
    @Published private(set) var skippedVersions: Set<String> = []

    private var task: URLSessionTask?
    private var downloadTask: URLSessionDownloadTask?
    /// 这两个 session 必须强引用住并在用完后 invalidate：
    /// URLSession 会强持有 delegate 与底层连接，不 invalidate 就是每次检查泄漏一个。
    private var checkSession: URLSession?
    private var downloadSession: URLSession?
    /// 下载进度回传。必须强引用：session 结束时 delegate 会被回收，
    /// 不拉住它的话进度回调会静默消失。
    private var progressDelegate: DownloadProgressDelegate?

    private init() {
        skippedVersions = Set(UserDefaults.standard.stringArray(forKey: kSkipKey) ?? [])
    }

    // MARK: - 版本源地址

    var feedURLString: String {
        let custom = UserDefaults.standard.string(forKey: kFeedKey)?.trimmingCharacters(in: .whitespaces) ?? ""
        return custom.isEmpty ? Self.defaultFeedURL : custom
    }

    func setFeedURL(_ s: String) {
        let t = s.trimmingCharacters(in: .whitespaces)
        if t.isEmpty {
            UserDefaults.standard.removeObject(forKey: kFeedKey)
        } else {
            UserDefaults.standard.set(t, forKey: kFeedKey)
        }
    }

    /// 只接受 https（本地回环除外，方便自建版本源自测）。
    ///
    /// 版本源地址是用户可填的任意 URL，明文 http 可以被链路上的任何人改写响应内容；
    /// 结合「App 持有辅助功能权限」这一点，一次劫持就等于远程代码执行。
    /// localhost / 127.0.0.1 / [::1] 不经过网络，放行不影响安全性。
    static func validatedURL(_ s: String) -> URL? {
        guard let comps = URLComponents(string: s),
              let scheme = comps.scheme?.lowercased(),
              let url = comps.url else { return nil }
        if scheme == "https" { return url }
        // 明文 http 只放行回环地址（自建版本源自测），其余一律拒绝
        if scheme == "http" {
            // URLComponents.host 对 IPv6 字面量会**保留方括号**（"[::1]"），
            // 而直接跟 "::1" 比永远不等 —— 于是 IPv6 回环被误判成远程地址拒绝
            // （2026-10-26 实测，HANDOFF 承诺放行却没生效）。先剥掉括号再比。
            var host = (comps.host ?? "").lowercased()
            if host.hasPrefix("["), host.hasSuffix("]") {
                host = String(host.dropFirst().dropLast())
            }
            if host == "localhost" || host == "127.0.0.1" || host == "::1" { return url }
        }
        return nil
    }

    // MARK: - 检查

    /// 版本源 HTTP 错误 → 人能照着做的话术。
    /// 默认版本源指向一个还没创建的 GitHub 仓库，404 是必然结果，
    /// 只显示「HTTP 404」用户完全不知道该干什么（2026-10-22 实测）。
    static func httpMessage(code: Int, url: String) -> String {
        switch code {
        case 404:
            if url == Self.defaultFeedURL {
                return "默认版本源还没有发布记录：官方仓库尚未创建或未发过 Release。请先在「关于 → 自动更新」里填一个可用的版本源地址，或等首个 Release 发布。"
            }
            return "版本源返回 404（地址不存在）：请检查填写的版本源地址是否正确"
        case 403:
            return "版本源返回 403（被拒绝或触发限流）：GitHub API 未认证时限流较严，可稍后再试或改用自建版本源"
        case 401:
            return "版本源返回 401（需要鉴权）：该地址要求登录，改用公开的版本源地址"
        default:
            return "版本源返回 HTTP \(code)"
        }
    }

    /// 静默检查（启动 / 定时）。静默失败不打扰用户。
    func checkIfNeeded() {
        guard Preferences.shared.autoCheckUpdates else { return }
        // 正在下载 / 安装时不要插一次检查进来，会打断下载
        guard !phase.isBusy else { return }
        let now = Date()
        let last = UserDefaults.standard.object(forKey: kLastCheckKey) as? Date ?? .distantPast
        let failed = UserDefaults.standard.bool(forKey: kLastFailedKey)
        let interval: TimeInterval = failed ? Self.retryInterval : Self.checkInterval
        guard now.timeIntervalSince(last) >= interval else { return }
        check(interactive: false)
    }

    /// 用户点「检查更新」，或启动 / 定时的静默检查（interactive=false）。
    func check(interactive: Bool) {
        guard !phase.isBusy else { return }
        guard let url = Self.validatedURL(feedURLString) else {
            if interactive {
                phase = .failed(feedURLString.lowercased().hasPrefix("http://")
                    ? "版本源必须是 https 地址（明文 http 可被劫持，已拒绝）：\(feedURLString)"
                    : "版本源地址无效：\(feedURLString)")
            }
            return
        }
        if interactive { phase = .checking }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let session = URLSession(configuration: .ephemeral)
        task?.cancel()
        checkSession?.finishTasksAndInvalidate()
        checkSession = session
        task = session.dataTask(with: req) { [weak self] data, resp, err in
            guard let self else { return }
            // session 用完必须 invalidate，否则每次检查都泄漏一个 session
            // （session 会强持有 delegate / 底层连接，长时间运行会累积）
            defer { session.finishTasksAndInvalidate() }
            DispatchQueue.main.async {
                self.checkSession = nil
                self.lastCheckedAt = Date()
                if let err {
                    self.recordCheck(failed: true)
                    if interactive { self.phase = .failed("无法连接版本源：\(err.localizedDescription)") }
                    return
                }
                if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
                    self.recordCheck(failed: true)
                    if interactive { self.phase = .failed(Self.httpMessage(code: http.statusCode, url: self.feedURLString)) }
                    return
                }
                guard let data else {
                    self.recordCheck(failed: true)
                    if interactive { self.phase = .failed("版本源没有内容") }
                    return
                }
                let os = ProcessInfo.processInfo.operatingSystemVersion
                let osString = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
                switch UpdateCheck.decide(current: Self.currentVersion, osVersion: osString, data: data) {
                case .upToDate:
                    self.recordCheck(failed: false)
                    self.available = nil
                    if interactive { self.phase = .idle }
                case .available(let m):
                    self.recordCheck(failed: false)
                    if self.skippedVersions.contains(m.version) {
                        self.available = nil
                        // 手动检查时要说明白「跳过了」，不是查无结果
                        if interactive { self.phase = .skipped(m.version) }
                    } else {
                        self.available = m
                        // 静默检查也必须把 phase 推到 updateFound：菜单栏横幅和「关于」页
                        // 都靠这个状态显示。只在 interactive 时置位的话，用户不主动打开
                        // 「关于」页就永远不知道有新版，自动更新退化成手动更新（2026-10-22）。
                        self.phase = .updateFound(m.version)
                    }
                case .systemTooOld(let m, let need):
                    self.recordCheck(failed: false)
                    self.available = nil
                    if interactive { self.phase = .failed("\(m.version) 需要 macOS \(need) 或更高") }
                case .malformed(let why):
                    self.recordCheck(failed: true)
                    self.available = nil
                    if interactive { self.phase = .failed(why) }
                }
            }
        }
        task?.resume()
    }

    /// 记录一次检查的结果时间戳 + 成败。
    /// 失败也写时间戳，但会写 failed 标记，让 checkIfNeeded 用 1 小时节奏重试。
    private func recordCheck(failed: Bool) {
        UserDefaults.standard.set(Date(), forKey: kLastCheckKey)
        UserDefaults.standard.set(failed, forKey: kLastFailedKey)
    }

    func cancel() {
        task?.cancel(); task = nil
        downloadTask?.cancel(); downloadTask = nil
        checkSession?.invalidateAndCancel(); checkSession = nil
        downloadSession?.invalidateAndCancel(); downloadSession = nil
        progressDelegate = nil
        phase = .idle
    }

    /// 用户点了「暂不更新」：回到 idle，但保留 available，
    /// 这样下次启动的静默检查仍能再次提示（不会因为关掉一次就永远不提示）。
    func dismiss() {
        guard !phase.isBusy else { return }
        phase = .idle
    }

    /// 用户点了「跳过此版本」：这个版本不再自动提示，直到换版本源或清缓存。
    func skipVersion(_ v: String) {
        var s = skippedVersions
        s.insert(v)
        skippedVersions = s
        UserDefaults.standard.set(Array(s), forKey: kSkipKey)
        if case .updateFound = phase { phase = .idle }
        if available?.version == v { available = nil }
    }

    // MARK: - 下载安装

    func downloadAndInstall() {
        guard let m = available else {
            phase = .failed("版本源没有提供安装包地址")
            return
        }
        guard let urlString = m.url else {
            phase = .failed("版本源没有提供安装包地址")
            return
        }
        guard let url = Self.validatedURL(urlString) else {
            phase = .failed("安装包地址不是 https（明文 http 可被劫持，已拒绝）：\(urlString)")
            return
        }
        guard !phase.isBusy else { return }
        phase = .downloading(progress: 0)
        // 用 delegate 而不是 completion-handler：后者拿不到增量进度，
        // 界面上的百分比会一直停在 0% 然后突然跳完（2026-10-22）。
        let delegate = DownloadProgressDelegate(
            onProgress: { [weak self] p in
                DispatchQueue.main.async {
                    // 只在还处于下载状态时更新，避免把 failed 状态盖掉
                    if case .downloading = self?.phase { self?.phase = .downloading(progress: p) }
                }
            },
            onFinish: { [weak self] location, resp, err in
                DispatchQueue.main.async {
                    self?.downloadSession?.finishTasksAndInvalidate()
                    self?.downloadSession = nil
                    self?.progressDelegate = nil
                    self?.handleDownloaded(location, response: resp, error: err, url: url, manifest: m)
                }
            })
        progressDelegate = delegate
        downloadSession?.finishTasksAndInvalidate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        downloadSession = session
        downloadTask?.cancel()
        downloadTask = session.downloadTask(with: url)
        downloadTask?.resume()
    }

    private func handleDownloaded(_ location: URL?, response: URLResponse?, error: Error?,
                                  url: URL, manifest: UpdateManifest) {
        if let error {
            phase = .failed("下载失败：\(error.localizedDescription)")
            return
        }
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            phase = .failed("下载失败：服务器返回 HTTP \(http.statusCode)")
            return
        }
        guard let location else {
            phase = .failed("下载没有内容")
            return
        }
        // URLSession 会在任务结束后清掉临时文件，立刻搬走
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("smoose-update-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(url.lastPathComponent.isEmpty ? "Smoose.update" : url.lastPathComponent)
            try FileManager.default.moveItem(at: location, to: dest)
            // 版本源给了 sha256 就先验和：这一步在解压之前，
            // 坏包 / 被替换的包在这里就被挡掉，连 unzip 都不会跑
            if let expect = manifest.sha256?.lowercased() {
                let actual = try Self.sha256(of: dest)
                guard actual == expect else {
                    throw UpdateInstallError.checksumMismatch(expected: expect, actual: actual)
                }
            }
            installArchive(at: dest, cleanup: dir)
        } catch let e as UpdateInstallError {
            try? FileManager.default.removeItem(at: dir)
            phase = .failed(e.message)
        } catch {
            try? FileManager.default.removeItem(at: dir)
            phase = .failed("准备安装包失败：\(error.localizedDescription)")
        }
    }

    /// 流式算 SHA-256，不把整个安装包读进内存。
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        if #available(macOS 10.15.4, *) {
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } else {
            var data = Data()
            while true {
                let chunk = handle.readData(ofLength: 1 << 20)
                if chunk.isEmpty { break }
                data.append(chunk)
            }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 解压 zip → 找到 .app → 替换 /Applications/Smoose.app → 等用户重启。
    private func installArchive(at archive: URL, cleanup: URL) {
        phase = .installing
        // 解压 + 拷贝可能几百毫秒到数秒。绝不能在主线程跑：
        // 主线程一卡，「正在安装」的界面就冻住，用户会以为程序挂了（2026-10-22）。
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let fm = FileManager.default
            let work = cleanup.appendingPathComponent("extracted", isDirectory: true)
            do {
                try fm.createDirectory(at: work, withIntermediateDirectories: true)
                let ext = archive.pathExtension.lowercased()
                guard ext == "zip" else {
                    throw UpdateInstallError.unsupportedArchive(ext.isEmpty ? "无后缀" : ".\(ext)")
                }
                let unzip = Process()
                unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
                unzip.arguments = ["-q", "-o", archive.path, "-d", work.path]
                try unzip.run()
                unzip.waitUntilExit()
                if unzip.terminationStatus != 0 {
                    throw UpdateInstallError.unzipFailed
                }
                guard let app = Self.findApp(in: work) else {
                    throw UpdateInstallError.appNotFound
                }
                // bundle id 校验：版本源是用户可填的任意地址，
                // 不校验就可能把一个不相关的 .app 覆盖到 /Applications/Smoose.app。
                guard Self.bundleID(of: app) == Self.bundleIdentifier else {
                    throw UpdateInstallError.wrongBundle(Self.bundleID(of: app) ?? "未知")
                }
                // 签名校验才是身份校验：bundle id 谁都能写，Team ID 写不了
                try Self.verifySignature(of: app)
                try Self.replaceApp(at: app)
                // 安装包可能在「应用程序」里，替换后原 zip 已失效，直接清掉
                try? fm.removeItem(at: cleanup)
                DispatchQueue.main.async {
                    self.phase = .readyToRelaunch(self.available?.version ?? "")
                }
            } catch let e as UpdateInstallError {
                DispatchQueue.main.async { self.phase = .failed(e.message) }
            } catch {
                DispatchQueue.main.async { self.phase = .failed("安装失败：\(error.localizedDescription)") }
            }
        }
    }

    /// 在解压目录里找 .app（可能嵌在子目录里，如 GitHub 自动打包的 zip）
    static func findApp(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard let walk = fm.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return nil }
        for case let u as URL in walk where u.pathExtension == "app" {
            // 只要最外层的 Smoose.app，忽略 Contents/Resources 里的嵌套 app
            if u.lastPathComponent == "Smoose.app",
               let v = try? u.resourceValues(forKeys: [.isDirectoryKey]), v.isDirectory == true {
                return u
            }
        }
        return nil
    }

    /// 读 .app/Contents/Info.plist 里的 CFBundleIdentifier，读不到返回 nil。
    static func bundleID(of app: URL) -> String? {
        let plist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let obj = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = obj as? [String: Any] else { return nil }
        return dict["CFBundleIdentifier"] as? String
    }

    /// 换掉 /Applications/Smoose.app。旧版先搬到临时目录，成功后再删 ——
    /// 万一替换失败还能把原版搬回去，不留「App 被删了却装不上」的死局。
    static func replaceApp(at newApp: URL) throws {
        let fm = FileManager.default
        let target = URL(fileURLWithPath: "/Applications/Smoose.app")
        let backup = fm.temporaryDirectory.appendingPathComponent("Smoose.backup-\(UUID().uuidString).app")
        let targetExists = fm.fileExists(atPath: target.path)
        if targetExists {
            try fm.moveItem(at: target, to: backup)
        }
        do {
            try fm.copyItem(at: newApp, to: target)
            // 拷贝完成后再验一次签名：解压目录与 /Applications 之间有一次拷贝窗口，
            // 验失败要把原版搬回来，不能留下「旧版没了、新版不可信」的半截状态
            do {
                try Self.verifySignature(of: target)
            } catch {
                try? fm.removeItem(at: target)
                if targetExists { try? fm.moveItem(at: backup, to: target) }
                throw error
            }
        } catch {
            if targetExists, !fm.fileExists(atPath: target.path) {
                try? fm.moveItem(at: backup, to: target)
            }
            throw error
        }
        if targetExists { try? fm.removeItem(at: backup) }
    }

    // MARK: - 签名校验

    /// 校验更新包的发布者身份。两道关：
    ///  1. `codesign --verify --deep --strict`：完整性 + 证书链（--deep 覆盖嵌套的
    ///     framework / helper，--strict 拒绝宽松签名）
    ///  2. `TeamIdentifier`：只有它能证明「这是本人发的」。ad-hoc 签名能过第 1 关，
    ///     但拿不到 Team ID —— 而被替换的恶意包最常见的形态就是重签成 ad-hoc。
    ///
    /// 没有这一步，任何人只要让版本源指向自己的 zip，就能把带辅助功能权限的
    /// /Applications/Smoose.app 换成任意代码（2026-10-26 审核发现的 P0）。
    static func verifySignature(of app: URL) throws {
        let expected = Self.expectedTeamIdentifier

        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verify.arguments = ["--verify", "--deep", "--strict", "--verbose=2", app.path]
        let vPipe = Pipe()
        verify.standardOutput = vPipe
        verify.standardError = vPipe
        do { try verify.run() } catch {
            throw UpdateInstallError.signatureInvalid("无法运行 codesign：\(error.localizedDescription)")
        }
        verify.waitUntilExit()
        let vOut = String(data: vPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard verify.terminationStatus == 0 else {
            let detail = vOut.trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateInstallError.signatureInvalid(detail.isEmpty
                ? "安装包签名校验未通过（codesign 退出码 \(verify.terminationStatus)）"
                : "安装包签名无效或已被篡改：\(detail)")
        }

        let display = Process()
        display.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        display.arguments = ["--display", "--verbose=4", app.path]
        let dPipe = Pipe()
        display.standardOutput = dPipe
        display.standardError = dPipe
        do { try display.run() } catch {
            throw UpdateInstallError.signatureInvalid("无法读取签名信息：\(error.localizedDescription)")
        }
        display.waitUntilExit()
        let dOut = String(data: dPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        var team: String?
        for line in dOut.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            // 形如 "TeamIdentifier=5F66DDWD6H"；未签名时是 "TeamIdentifier=not set"
            if t.hasPrefix("TeamIdentifier=") {
                team = String(t.dropFirst("TeamIdentifier=".count))
                break
            }
        }
        guard let team, !team.isEmpty, team != "not set" else {
            throw UpdateInstallError.signatureInvalid(
                "安装包没有可用的开发者签名（ad-hoc 或已脱签），无法确认发布者身份")
        }
        guard team == expected else {
            throw UpdateInstallError.signatureInvalid(
                "安装包签名 Team ID 是「\(team)」，与预期的「\(expected)」不一致，已中止安装")
        }
    }

    /// 重启到新版本。用 relaunch 而不是直接 terminate：
    /// 先起新进程再退出旧的，用户不会看到「App 消失了」。
    func relaunch() {
        let app = URL(fileURLWithPath: "/Applications/Smoose.app")
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: app, configuration: cfg) { _, _ in
            DispatchQueue.main.async { Self.terminateSelf() }
        }
    }

    /// 退出自己。`NSApp` 是 `NSApplication?` 类型的隐式解包全局，
    /// 在没有 NSApplication 的上下文（探针 / 单元测试 / CLI）里是 nil，
    /// 直接 `NSApp.terminate(nil)` 会 `Fatal error: Unexpectedly found nil`
    /// （2026-10-22 端到端实测崩在这行）。所以必须可选链 + 兜底 exit。
    private static func terminateSelf() {
        if let app = NSApp { app.terminate(nil) } else { exit(0) }
    }

    // MARK: - 版本号

    /// 从 Bundle 的 Info.plist 读 CFBundleShortVersionString，取不到时退回 "0"
    static var currentVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }
}

// MARK: - 下载进度

/// completion-handler 形式的 downloadTask 不会回调增量进度，
/// 所以这里用 delegate 形式把百分比回给界面。
private final class DownloadProgressDelegate: NSObject, URLSessionDownloadDelegate {
    private let onProgress: (Double) -> Void
    private let onFinish: (URL?, URLResponse?, Error?) -> Void
    /// didFinishDownloadingTo 之后系统还会再调一次 didCompleteWithError(nil)，
    /// 加这个闸门保证 onFinish 只触发一次。
    private var done = false

    init(onProgress: @escaping (Double) -> Void,
         onFinish: @escaping (URL?, URLResponse?, Error?) -> Void) {
        self.onProgress = onProgress
        self.onFinish = onFinish
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        finish(location, downloadTask.response, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(nil, task.response, error) }
    }

    private func finish(_ location: URL?, _ response: URLResponse?, _ error: Error?) {
        guard !done else { return }
        done = true
        onFinish(location, response, error)
    }
}

// MARK: - 安装失败原因

/// 每种失败都对应一句用户能照着做的话，而不是笼统的「安装失败」。
private enum UpdateInstallError: Error {
    case unsupportedArchive(String)
    case unzipFailed
    case appNotFound
    case wrongBundle(String)
    case signatureInvalid(String)
    case checksumMismatch(expected: String, actual: String)

    var message: String {
        switch self {
        case .unsupportedArchive(let ext):
            return "不支持的安装包格式 \(ext)：请发布 .zip（./release.sh 打出来的就是 zip）"
        case .unzipFailed:
            return "解压失败：安装包可能损坏，请重新下载"
        case .appNotFound:
            return "安装包里没有找到 Smoose.app"
        case .wrongBundle(let id):
            return "安装包里的 App bundle id 是「\(id)」而不是 Smoose，已中止覆盖"
        case .signatureInvalid(let why):
            return "已中止安装：\(why)。这通常是版本源被指向了非官方地址，请检查「关于 → 自动更新」里的版本源"
        case .checksumMismatch(let expected, let actual):
            return "安装包校验和不匹配（期望 \(expected.prefix(16))…，实际 \(actual.prefix(16))…），文件可能在传输中被替换，已中止安装"
        }
    }
}

/// 更新相关的 key 都不进 StoredState —— 这是发布配置，不是手感配置，
/// 且用户改一次就不会再改，单独 key 更干净（避免 StoredState 结构再动一次）。
private let kFeedKey = "smoose.update.feed"
private let kLastCheckKey = "smoose.update.lastCheck"
private let kLastFailedKey = "smoose.update.lastCheckFailed"
private let kSkipKey = "smoose.update.skipped"
