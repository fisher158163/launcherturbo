import Foundation

struct UpdaterArguments {
    var tag: String?
    var assetPattern: String
    var installDirectory: URL?
    var downloadOnly: Bool
    var emitJSON: Bool
    var assumeYes: Bool
    var language: String?
    var resetLanguage: Bool
    var holdWindow: Bool

    static let defaultAssetPattern = "LaunchNext.*\\.zip"
}

enum ArgumentError: Error {
    case invalidValue(String)
}

enum RunContext {
    case interactive
    case nonInteractive
}

func parseArguments() throws -> UpdaterArguments {
    var parser = CommandLine.arguments.makeIterator()
    _ = parser.next() // drop executable name

    var result = UpdaterArguments(
        tag: nil,
        assetPattern: UpdaterArguments.defaultAssetPattern,
        installDirectory: nil,
        downloadOnly: false,
        emitJSON: false,
        assumeYes: false,
        language: nil,
        resetLanguage: false,
        holdWindow: false
    )

    while let token = parser.next() {
        switch token {
        case "--tag":
            guard let value = parser.next() else { throw ArgumentError.invalidValue(token) }
            result.tag = value
        case "--asset-pattern":
            guard let value = parser.next() else { throw ArgumentError.invalidValue(token) }
            result.assetPattern = value
        case "--install-dir":
            guard let value = parser.next() else { throw ArgumentError.invalidValue(token) }
            result.installDirectory = URL(fileURLWithPath: value)
        case "--download-only":
            result.downloadOnly = true
        case "--emit-json":
            result.emitJSON = true
        case "--yes":
            result.assumeYes = true
        case "--language":
            guard let value = parser.next() else { throw ArgumentError.invalidValue(token) }
            result.language = value
        case "--reset-language":
            result.resetLanguage = true
        case "--hold-window":
            result.holdWindow = true
        default:
            throw ArgumentError.invalidValue(token)
        }
    }

    return result
}
