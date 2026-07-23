import Foundation

enum CoreBinaryManager {
    static let binaryName = "zju-connect"
    static let defaultReleaseTag = "v1.2.1"

    enum MachOArch: String {
        case arm64
        case x86_64
        case universal
        case unknown
    }

    struct BinaryInfo: Equatable {
        let url: URL
        let arch: MachOArch
        var isNative: Bool {
            switch arch {
            case .universal: return true
            case .arm64: return ProcessInfo.processInfo.machineHardwareName.contains("arm64")
            case .x86_64: return !ProcessInfo.processInfo.machineHardwareName.contains("arm64")
            case .unknown: return false
            }
        }
    }

    /// Preferred locations for the aTrust protocol engine (zju-connect).
    static func resolvedBinaryURL() -> URL? {
        resolveBinary()?.url
    }

    /// Best available engine binary, preferring native arch. Copies into App Support when found elsewhere.
    static func resolveBinary() -> BinaryInfo? {
        let fm = FileManager.default
        var infos: [BinaryInfo] = []
        for url in candidateURLs() {
            guard fm.isExecutableFile(atPath: url.path) || fm.fileExists(atPath: url.path) else { continue }
            // Ensure +x for copied artifacts that lost execute bit.
            if !fm.isExecutableFile(atPath: url.path) {
                try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            }
            guard fm.isExecutableFile(atPath: url.path) else { continue }
            infos.append(BinaryInfo(url: url.standardizedFileURL, arch: machOArch(of: url)))
        }
        // De-duplicate by path
        var seen = Set<String>()
        infos = infos.filter { seen.insert($0.url.path).inserted }
        guard !infos.isEmpty else { return nil }

        let preferred = infos.first(where: \.isNative)
            ?? infos.first(where: { $0.arch == .universal })
            ?? infos.first!

        // Persist a stable copy so Xcode cwd / SRCROOT is not required next launch.
        if preferred.url.path != supportDirectory.appendingPathComponent(binaryName).path {
            if let installed = try? installCopy(from: preferred.url) {
                return BinaryInfo(url: installed, arch: machOArch(of: installed))
            }
        }
        stripQuarantine(at: preferred.url)
        return preferred
    }

    /// Human-readable status for UI (why Connect may be disabled).
    static func diagnosisMessage() -> String? {
        guard let info = resolveBinary() else {
            return "尚未安装 aTrust 协议引擎 (zju-connect)。请点击下方下载，或在终端运行 ./Scripts/download-core.sh，并把 arm64 二进制放到 Core/。"
        }
        if !info.isNative {
            let host = ProcessInfo.processInfo.machineHardwareName
            return "当前引擎架构为 \(info.arch.rawValue)，本机为 \(host)。可在 Rosetta 下尝试连接；推荐下载 zju-connect-darwin-arm64.zip 替换。"
        }
        return nil
    }

    private static func candidateURLs() -> [URL] {
        let fm = FileManager.default
        var list: [URL] = [
            Bundle.main.resourceURL?.appendingPathComponent("Core/\(binaryName)"),
            Bundle.main.bundleURL
                .appendingPathComponent("Contents/Resources/Core/\(binaryName)"),
            supportDirectory.appendingPathComponent(binaryName)
        ].compactMap { $0 }

        list.append(contentsOf: projectCoreCandidates())
        list.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Core/\(binaryName)")
        )
        list.append(URL(fileURLWithPath: "/opt/homebrew/bin/\(binaryName)"))
        list.append(URL(fileURLWithPath: "/usr/local/bin/\(binaryName)"))
        list.append(fm.homeDirectoryForCurrentUser.appendingPathComponent("go/bin/\(binaryName)"))
        return list
    }

    /// Repo-local Core/ when running from Xcode / source tree / #filePath.
    private static func projectCoreCandidates() -> [URL] {
        var roots: [URL] = []
        let env = ProcessInfo.processInfo.environment
        for key in ["SRCROOT", "PROJECT_DIR", "SOURCE_ROOT"] {
            if let root = env[key], !root.isEmpty {
                roots.append(URL(fileURLWithPath: root))
            }
        }
        // Compile-time path → walk up looking for Core/zju-connect (debug & local builds).
        var walker = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<10 {
            roots.append(walker)
            walker = walker.deletingLastPathComponent()
        }
        // Common: app executable under DerivedData; walk up a few levels too.
        if let exe = Bundle.main.executableURL {
            var dir = exe.deletingLastPathComponent()
            for _ in 0..<12 {
                roots.append(dir)
                dir = dir.deletingLastPathComponent()
            }
        }

        var urls: [URL] = []
        var seen = Set<String>()
        for root in roots {
            let candidate = root.appendingPathComponent("Core/\(binaryName)")
            if seen.insert(candidate.path).inserted {
                urls.append(candidate)
            }
            // Also accept nested openZweb/Core when walking from parent folders.
            let nested = root.appendingPathComponent("openZweb/Core/\(binaryName)")
            if seen.insert(nested.path).inserted {
                urls.append(nested)
            }
        }
        return urls
    }

    /// Read Mach-O cputype (or fat header) without spawning `file`.
    static func machOArch(of url: URL) -> MachOArch {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unknown }
        defer { try? handle.close() }
        guard let magicData = try? handle.read(upToCount: 4), magicData.count == 4 else { return .unknown }
        let magic = magicData.withUnsafeBytes { $0.load(as: UInt32.self) }

        // Fat / universal
        let fatMagic: UInt32 = 0xCAFEBABE
        let fatCigam: UInt32 = 0xBEBAFECA
        if magic == fatMagic || magic == fatCigam {
            return .universal
        }

        let mhMagic64: UInt32 = 0xFEEDFACF
        let mhCigam64: UInt32 = 0xCFFAEDFE
        let mhMagic: UInt32 = 0xFEEDFACE
        let mhCigam: UInt32 = 0xCEFAEDFE
        guard magic == mhMagic64 || magic == mhCigam64 || magic == mhMagic || magic == mhCigam else {
            return .unknown
        }

        // cputype is next 4 bytes
        guard let cpuData = try? handle.read(upToCount: 4), cpuData.count == 4 else { return .unknown }
        var cputype = cpuData.withUnsafeBytes { $0.load(as: UInt32.self) }
        let swapped = (magic == mhCigam64 || magic == mhCigam)
        if swapped {
            cputype = cputype.byteSwapped
        }
        // CPU_TYPE_X86_64 = 0x01000007, CPU_TYPE_ARM64 = 0x0100000C
        switch cputype {
        case 0x0100000C: return .arm64
        case 0x01000007: return .x86_64
        default: return .unknown
        }
    }

    private static func installCopy(from source: URL) throws -> URL {
        let target = supportDirectory.appendingPathComponent(binaryName)
        let fm = FileManager.default
        if fm.fileExists(atPath: target.path) {
            // Keep existing if same inode/size and already native when source is not.
            if let srcAttrs = try? fm.attributesOfItem(atPath: source.path),
               let dstAttrs = try? fm.attributesOfItem(atPath: target.path),
               let srcSize = srcAttrs[.size] as? NSNumber,
               let dstSize = dstAttrs[.size] as? NSNumber,
               srcSize == dstSize {
                let existing = BinaryInfo(url: target, arch: machOArch(of: target))
                if existing.isNative || !BinaryInfo(url: source, arch: machOArch(of: source)).isNative {
                    return target
                }
            }
            try? fm.removeItem(at: target)
        }
        try fm.copyItem(at: source, to: target)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        stripQuarantine(at: target)
        return target
    }

    private static func stripQuarantine(at url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-dr", "com.apple.quarantine", url.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("OpenZweb", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var captchaImageURL: URL {
        supportDirectory.appendingPathComponent("captcha.png")
    }

    static var stdinFIFOURL: URL {
        supportDirectory.appendingPathComponent("engine.stdin")
    }

    static var defaultConfigURL: URL {
        supportDirectory.appendingPathComponent("config.toml")
    }

    static var runtimeConfigURL: URL {
        supportDirectory.appendingPathComponent("runtime.toml")
    }

    /// Download the latest zju-connect release for the current architecture.
    static func downloadLatest(progress: ((Double) -> Void)? = nil) async throws -> URL {
        let arch = ProcessInfo.processInfo.machineHardwareName.contains("arm64") ? "arm64" : "amd64"
        progress?(0.05)

        if let fromAPI = try? await downloadFromGitHubAPI(arch: arch, progress: progress) {
            return fromAPI
        }
        progress?(0.4)
        if let fromTag = try? await downloadFromKnownTag(arch: arch, progress: progress) {
            return fromTag
        }
        progress?(0.7)
        if let built = try? await buildWithGo() {
            progress?(1)
            return built
        }
        throw CoreError.assetNotFound(arch: arch)
    }

    private static func downloadFromGitHubAPI(arch: String, progress: ((Double) -> Void)?) async throws -> URL {
        let api = URL(string: "https://api.github.com/repos/Mythologyli/zju-connect/releases/latest")!
        var request = URLRequest(url: api)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw CoreError.releaseMetadataUnavailable
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = json["assets"] as? [[String: Any]] else {
            throw CoreError.releaseMetadataUnavailable
        }

        guard let downloadURL = pickAssetURL(assets: assets, arch: arch) else {
            throw CoreError.assetNotFound(arch: arch)
        }
        progress?(0.2)
        return try await downloadAndInstall(from: downloadURL, progress: progress)
    }

    private static func downloadFromKnownTag(arch: String, progress: ((Double) -> Void)?) async throws -> URL {
        let tag = defaultReleaseTag
        let names = [
            "zju-connect-darwin-\(arch).zip",
            "zju-connect_darwin_\(arch).zip",
            "zju-connect-darwin-\(arch).tar.gz",
            "zju-connect_darwin_\(arch).tar.gz"
        ]
        let prefixes = [
            "",
            "https://ghproxy.net/",
            "https://mirror.ghproxy.com/"
        ]
        var lastError: Error?
        for name in names {
            let direct = "https://github.com/Mythologyli/zju-connect/releases/download/\(tag)/\(name)"
            for prefix in prefixes {
                let full = prefix.isEmpty ? direct : prefix + direct
                guard let url = URL(string: full) else { continue }
                do {
                    return try await downloadAndInstall(from: url, progress: progress)
                } catch {
                    lastError = error
                    continue
                }
            }
        }
        throw lastError ?? CoreError.assetNotFound(arch: arch)
    }

    private static func pickAssetURL(assets: [[String: Any]], arch: String) -> URL? {
        let names = assets.compactMap { a -> (String, String)? in
            guard let name = a["name"] as? String,
                  let url = a["browser_download_url"] as? String else { return nil }
            return (name, url)
        }

        let patterns: [String] = [
            "zju-connect-darwin-\(arch).zip",
            "zju-connect_darwin_\(arch).zip",
            "zju-connect-darwin-\(arch).tar.gz",
            "zju-connect_darwin_\(arch).tar.gz",
            "zju-connect-macos-\(arch).zip"
        ]
        for pat in patterns {
            if let hit = names.first(where: { $0.0.lowercased() == pat.lowercased() }) {
                return URL(string: hit.1)
            }
        }
        // Fuzzy fallback
        for (name, url) in names {
            let n = name.lowercased()
            if n.contains("darwin") && n.contains(arch) && (n.hasSuffix(".zip") || n.hasSuffix(".tar.gz") || n.hasSuffix(".tgz")) {
                return URL(string: url)
            }
        }
        return nil
    }

    private static func downloadAndInstall(from downloadURL: URL, progress: ((Double) -> Void)?) async throws -> URL {
        let (tempURL, _) = try await URLSession.shared.download(from: downloadURL)
        progress?(0.75)
        let destDir = supportDirectory
        let isZip = downloadURL.pathExtension.lowercased() == "zip"
        let archivePath = destDir.appendingPathComponent(isZip ? "zju-connect.zip" : "zju-connect.tar.gz")
        try? FileManager.default.removeItem(at: archivePath)
        if FileManager.default.fileExists(atPath: archivePath.path) {
            try FileManager.default.removeItem(at: archivePath)
        }
        try FileManager.default.moveItem(at: tempURL, to: archivePath)

        let extractDir = destDir.appendingPathComponent("extract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: extractDir) }

        let process = Process()
        if isZip {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-qo", archivePath.path, "-d", extractDir.path]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xzf", archivePath.path, "-C", extractDir.path]
        }
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CoreError.extractFailed
        }

        guard let found = findBinary(named: binaryName, under: extractDir)
                ?? findExecutable(under: extractDir) else {
            throw CoreError.binaryMissingAfterExtract
        }

        let target = destDir.appendingPathComponent(binaryName)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(at: found, to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        try? FileManager.default.removeItem(at: archivePath)

        // Also mirror into project Core/ when writable (dev convenience).
        let projectCore = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Core/\(binaryName)")
        if FileManager.default.isWritableFile(atPath: projectCore.deletingLastPathComponent().path)
            || (try? FileManager.default.createDirectory(at: projectCore.deletingLastPathComponent(), withIntermediateDirectories: true)) != nil {
            try? FileManager.default.removeItem(at: projectCore)
            try? FileManager.default.copyItem(at: target, to: projectCore)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: projectCore.path)
        }

        progress?(1)
        return target
    }

    private static func buildWithGo() async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let go = URL(fileURLWithPath: "/opt/homebrew/bin/go")
                    let goAlt = URL(fileURLWithPath: "/usr/local/bin/go")
                    let goURL = FileManager.default.isExecutableFile(atPath: go.path) ? go : goAlt
                    guard FileManager.default.isExecutableFile(atPath: goURL.path) else {
                        throw CoreError.goUnavailable
                    }
                    let dest = supportDirectory.appendingPathComponent(binaryName)
                    let process = Process()
                    process.executableURL = goURL
                    process.environment = ProcessInfo.processInfo.environment.merging([
                        "GOBIN": supportDirectory.path
                    ]) { _, new in new }
                    process.arguments = [
                        "install",
                        "github.com/Mythologyli/zju-connect@\(defaultReleaseTag)"
                    ]
                    let err = Pipe()
                    process.standardError = err
                    process.standardOutput = Pipe()
                    try process.run()
                    process.waitUntilExit()
                    if process.terminationStatus != 0 || !FileManager.default.isExecutableFile(atPath: dest.path) {
                        // retry latest
                        let p2 = Process()
                        p2.executableURL = goURL
                        p2.environment = process.environment
                        p2.arguments = ["install", "github.com/Mythologyli/zju-connect@latest"]
                        p2.standardError = Pipe()
                        p2.standardOutput = Pipe()
                        try p2.run()
                        p2.waitUntilExit()
                    }
                    guard FileManager.default.isExecutableFile(atPath: dest.path) else {
                        throw CoreError.goBuildFailed
                    }
                    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
                    cont.resume(returning: dest)
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private static func findBinary(named name: String, under root: URL) -> URL? {
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == name {
                return url
            }
        }
        return nil
    }

    private static func findExecutable(under root: URL) -> URL? {
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isExecutableKey]
        )
        while let url = enumerator?.nextObject() as? URL {
            let name = url.lastPathComponent
            if name.hasPrefix("zju-connect") && !name.contains(".") {
                return url
            }
        }
        return nil
    }
}

enum CoreError: LocalizedError {
    case binaryNotFound
    case releaseMetadataUnavailable
    case assetNotFound(arch: String)
    case extractFailed
    case binaryMissingAfterExtract
    case goUnavailable
    case goBuildFailed

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "未找到 zju-connect 协议引擎。请通过「设置 → 下载协议引擎」安装，或运行 Scripts/download-core.sh。"
        case .releaseMetadataUnavailable:
            return "无法获取 zju-connect 发行版信息（网络或 GitHub API）。"
        case .assetNotFound(let arch):
            return "未找到 macOS \(arch) 版本的 zju-connect。可手动从 GitHub Releases 下载 zip 放到 Core/。"
        case .extractFailed:
            return "解压 zju-connect 失败。"
        case .binaryMissingAfterExtract:
            return "解压后未找到 zju-connect 可执行文件。"
        case .goUnavailable:
            return "本机未安装 Go，无法从源码构建 zju-connect。"
        case .goBuildFailed:
            return "go install 构建 zju-connect 失败。"
        }
    }
}

extension ProcessInfo {
    var machineHardwareName: String {
        var sysinfo = utsname()
        uname(&sysinfo)
        return withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingUTF8: $0) ?? "unknown"
            }
        }
    }
}
