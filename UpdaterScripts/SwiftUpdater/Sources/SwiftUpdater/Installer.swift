import Foundation


enum Installer {
    static func removeQuarantine(at url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-dr", "com.apple.quarantine", url.path]
        try? process.run()
        process.waitUntilExit()
    }

    static func extractArchive(_ archive: URL, to destination: URL) throws {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdaterError.archive("Failed to extract archive")
        }
    }

    static func copyBundle(from source: URL, to destination: URL, requireSudo: Bool) throws {
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        if requireSudo {
            let script = """
            set -euo pipefail
            mkdir -p "\(destination.deletingLastPathComponent().path)"
            rm -rf "\(destination.path)"
            /usr/bin/ditto --rsrc --preserveHFSCompression "\(source.path)" "\(destination.path)"
            """
            guard let data = script.data(using: .utf8) else {
                throw UpdaterError.install("Unable to prepare install script")
            }
            let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString).appendingPathExtension("sh")
            try data.write(to: tempURL)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: tempURL.path)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = ["/bin/bash", tempURL.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw UpdaterError.install("Administrator install failed")
            }
        } else {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
            process.arguments = ["--rsrc", "--preserveHFSCompression", source.path, destination.path]
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw UpdaterError.install("Installation failed")
            }
        }
    }

    static func copyBundleWithPassword(from source: URL, to destination: URL, password: String) throws {
        let script = """
        set -euo pipefail
        mkdir -p "\(destination.deletingLastPathComponent().path)"
        rm -rf "\(destination.path)"
        /usr/bin/ditto --rsrc --preserveHFSCompression "\(source.path)" "\(destination.path)"
        """
        guard let data = script.data(using: .utf8) else {
            throw UpdaterError.install("Unable to prepare install script")
        }
        let tempScript = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString).appendingPathExtension("sh")
        try data.write(to: tempScript)
        defer { try? FileManager.default.removeItem(at: tempScript) }
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: tempScript.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = ["-S", "-k", "-p", "", "/bin/bash", tempScript.path]
        let inputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        if let data = (password + "\n").data(using: .utf8) {
            inputPipe.fileHandleForWriting.write(data)
        }
        inputPipe.fileHandleForWriting.closeFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdaterError.install("Administrator install failed")
        }
    }
}
