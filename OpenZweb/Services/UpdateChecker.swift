import Foundation
import AppKit

/// Checks GitHub Releases for a newer OpenZweb version. Check-only (no auto install).
/// Uses CN-friendly mirrors when api.github.com is unreachable.
@MainActor
final class UpdateChecker: ObservableObject {
    static let owner = "diyanqi"
    static let repo = "OpenZweb"

    @Published private(set) var isChecking = false
    @Published private(set) var hasUpdate = false
    @Published private(set) var latestVersion: String?
    @Published private(set) var releaseURL: URL?
    @Published private(set) var statusMessage: String?
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var bannerDismissed = false

    private var didAutoCheck = false

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Endpoints tried in order. Mirrors first for mainland reachability, then official API.
    private var apiEndpoints: [URL] {
        let path = "repos/\(Self.owner)/\(Self.repo)/releases/latest"
        let raw = [
            "https://ghfast.top/https://api.github.com/\(path)",
            "https://ghproxy.net/https://api.github.com/\(path)",
            "https://mirror.ghproxy.com/https://api.github.com/\(path)",
            "https://api.github.com/\(path)"
        ]
        return raw.compactMap(URL.init(string:))
    }

    func clearBanner() {
        bannerDismissed = true
    }

    func checkOnLaunchIfNeeded(enabled: Bool) async {
        guard enabled, !didAutoCheck else { return }
        didAutoCheck = true
        await check(manual: false)
    }

    func check(manual: Bool) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        if manual {
            statusMessage = "正在检查更新…"
        }

        do {
            let release = try await fetchLatestRelease()
            lastCheckedAt = Date()
            latestVersion = release.tag
            releaseURL = release.htmlURL
            let newer = Self.isVersion(release.tag, newerThan: currentVersion)
            hasUpdate = newer
            if newer { bannerDismissed = false }
            if newer {
                statusMessage = "发现新版本 \(release.tag)（当前 \(currentVersion)）"
            } else if manual {
                statusMessage = "已是最新版本 (\(currentVersion))"
            } else {
                statusMessage = nil
            }
        } catch {
            hasUpdate = false
            if manual {
                statusMessage = "检查更新失败：\(error.localizedDescription)"
            } else {
                // Silent on launch failures so offline users are not interrupted.
                statusMessage = nil
            }
        }
    }

    private struct ReleaseInfo {
        var tag: String
        var htmlURL: URL?
    }

    private func fetchLatestRelease() async throws -> ReleaseInfo {
        var lastError: Error = URLError(.cannotConnectToHost)
        for url in apiEndpoints {
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 12
                request.setValue("OpenZweb-UpdateChecker", forHTTPHeaderField: "User-Agent")
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw URLError(.badServerResponse)
                }
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw URLError(.cannotParseResponse)
                }
                let tagRaw = (json["tag_name"] as? String) ?? ""
                let tag = Self.normalizeVersion(tagRaw)
                guard !tag.isEmpty else { throw URLError(.cannotParseResponse) }
                let html = (json["html_url"] as? String).flatMap(URL.init(string:))
                return ReleaseInfo(tag: tag, htmlURL: html)
            } catch {
                lastError = error
                continue
            }
        }
        throw lastError
    }

    static func normalizeVersion(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("v") {
            s = String(s.dropFirst())
        }
        // strip pre-release suffix for comparison simplicity: 1.2.0-beta -> 1.2.0
        if let dash = s.firstIndex(of: "-") {
            s = String(s[..<dash])
        }
        return s
    }

    /// Semantic-ish comparison: 1.2.0 vs 1.10.1
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let a = normalizeVersion(candidate).split(separator: ".").compactMap { Int($0) }
        let b = normalizeVersion(current).split(separator: ".").compactMap { Int($0) }
        let n = max(a.count, b.count)
        for i in 0..<n {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
