import Foundation

private let log = FileLog("Updates")

/// A newer ClaudeSwitch release published on GitHub.
struct AvailableUpdate: Equatable {
    let version: String
    let publishedAt: Date?
    /// The release page, with its notes.
    let releaseURL: URL
    /// The release's zip, when it has one; otherwise the release page.
    let downloadURL: URL
}

/// Looks up the latest ClaudeSwitch release on GitHub. It only reads public release info -- no
/// account, no token -- and never installs anything: updating stays a manual download, since an
/// ad-hoc signed app can't replace itself without tripping Gatekeeper.
enum UpdateChecker {
    static let repository = "Baudrim/ClaudeSwitch"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    enum CheckError: LocalizedError {
        case unreachable(String)
        case unexpectedResponse

        var errorDescription: String? {
            switch self {
            case .unreachable(let reason):
                return "Couldn't reach GitHub: \(reason)"
            case .unexpectedResponse:
                return "GitHub sent back something unexpected. Try again later."
            }
        }
    }

    /// The latest release if it's newer than this build, or nil when up to date.
    static func fetchUpdate() async throws -> AvailableUpdate? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeSwitch/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw CheckError.unreachable(error.localizedDescription)
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let release = try? JSONDecoder.github.decode(Release.self, from: data),
              let releaseURL = URL(string: release.htmlURL) else {
            throw CheckError.unexpectedResponse
        }

        let latest = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        log.info("[fetchUpdate] Latest release \(latest), running \(currentVersion)")
        guard isVersion(latest, newerThan: currentVersion) else { return nil }

        let zip = release.assets.first { $0.name.hasSuffix(".zip") }
        return AvailableUpdate(
            version: latest,
            publishedAt: release.publishedAt,
            releaseURL: releaseURL,
            downloadURL: zip.flatMap { URL(string: $0.browserDownloadURL) } ?? releaseURL
        )
    }

    /// Compares dotted versions numerically, so 0.10.0 is newer than 0.9.3.
    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let lhs = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let rhs = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(lhs.count, rhs.count) {
            let a = index < lhs.count ? lhs[index] : 0
            let b = index < rhs.count ? rhs[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    private struct Release: Decodable {
        let tagName: String
        let htmlURL: String
        let publishedAt: Date?
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case publishedAt = "published_at"
            case assets
        }
    }

    private struct Asset: Decodable {
        let name: String
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }
}

private extension JSONDecoder {
    static let github: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
