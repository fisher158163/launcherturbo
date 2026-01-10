import Foundation

enum UpdaterError: Error, CustomStringConvertible {
    case network(String)
    case assetNotFound(String)
    case archive(String)
    case install(String)
    case cancelled

    var description: String {
        switch self {
        case .network(let message):
            return message
        case .assetNotFound(let message):
            return message
        case .archive(let message):
            return message
        case .install(let message):
            return message
        case .cancelled:
            return "Operation cancelled"
        }
    }
}
