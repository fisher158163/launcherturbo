import Foundation

struct ReleaseAsset: Decodable {
    let name: String
    let browserDownloadURL: URL
    let size: Int

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case size
    }
}

struct ReleaseMetadata: Decodable {
    let tagName: String
    let htmlURL: URL?
    let assets: [ReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case assets
    }
}

enum GitHubClient {
    static let owner = "RoversX"
    static let repo = "LaunchNext"

    static func latestRelease(tag overrideTag: String?, token: String?) async throws -> ReleaseMetadata {
        let url: URL
        if let overrideTag, !overrideTag.isEmpty {
            url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/tags/\(overrideTag)")!
        } else {
            url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")!
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let token, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UpdaterError.network("Invalid response")
        }
        guard http.statusCode == 200 else {
            throw UpdaterError.network("GitHub API returned status \(http.statusCode)")
        }
        return try JSONDecoder().decode(ReleaseMetadata.self, from: data)
    }
}
