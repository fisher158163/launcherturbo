import Foundation

struct UpdaterConfig: Codable {
    var language: String?
    var supportedLanguages: [String]?

    init(language: String? = nil, supportedLanguages: [String]? = nil) {
        self.language = language
        self.supportedLanguages = supportedLanguages
    }
}

enum ConfigManager {
    static var baseDirectory: URL {
        let fm = FileManager.default
        return fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library")
            .appendingPathComponent("Application Support")
            .appendingPathComponent("LaunchNext")
            .appendingPathComponent("updates")
    }

    static var configURL: URL {
        baseDirectory.appendingPathComponent("config.json", isDirectory: false)
    }

    static func load() -> UpdaterConfig {
        guard let data = try? Data(contentsOf: configURL) else {
            return UpdaterConfig()
        }
        do {
            return try JSONDecoder().decode(UpdaterConfig.self, from: data)
        } catch {
            return UpdaterConfig()
        }
    }

    static func save(_ config: UpdaterConfig) {
        var payload = config
        payload.supportedLanguages = Localization.supportedLanguages
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: baseDirectory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(payload)
            try data.write(to: configURL, options: .atomic)
        } catch {
            // non-fatal
        }
    }
}
