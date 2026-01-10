import Foundation
import Darwin

@main
struct SwiftUpdater {
    private static let defaultInstallPath = "/Applications/LaunchNext.app"

    struct UpdateSuccess {
        let message: String
        let releaseTag: String
        let elapsed: TimeInterval
    }

    static func main() async {
        do {
            let arguments = try parseArguments()
            var config = ConfigManager.load()
            if arguments.resetLanguage {
                config.language = nil
            }
            let context = determineContext(arguments: arguments)
            switch context {
            case .interactive:
                try await runInteractive(arguments: arguments, config: &config)
            case .nonInteractive:
                try await runNonInteractive(arguments: arguments, config: &config)
            }
            ConfigManager.save(config)
        } catch let error as ArgumentError {
            fputs("Argument error: \(error)\n", stderr)
            exit(2)
        } catch {
            fputs("Error: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func determineContext(arguments: UpdaterArguments) -> RunContext {
        let stdinIsTTY = isatty(fileno(stdin)) != 0
        if arguments.assumeYes || !stdinIsTTY {
            return .nonInteractive
        }
        return .interactive
    }

    private static func resolvedInstallURL(from arguments: UpdaterArguments) -> URL {
        if let installDir = arguments.installDirectory {
            return installDir
        }
        return URL(fileURLWithPath: defaultInstallPath)
    }

    private static func resolveLanguage(current config: UpdaterConfig, arguments: UpdaterArguments) -> String {
        if let explicit = arguments.language, Localization.supportedLanguages.contains(explicit) {
            return explicit
        }
        if let stored = config.language, Localization.supportedLanguages.contains(stored) {
            return stored
        }
        return Localization.defaultLanguage
    }

    private static func runInteractive(arguments: UpdaterArguments, config: inout UpdaterConfig) async throws {
        guard let session = CursesSession() else {
            try await runNonInteractive(arguments: arguments, config: &config)
            return
        }
        defer { session.close() }

        let installURL = resolvedInstallURL(from: arguments)

        var language = resolveLanguage(current: config, arguments: arguments)
        let prompt = Localization.string("language_prompt", language: language).components(separatedBy: "\n").filter { !$0.isEmpty }
        language = session.selectLanguage(
            defaultCode: language,
            prompt: prompt,
            options: Localization.languageOptions()
        )
        if !Localization.supportedLanguages.contains(language) {
            language = Localization.defaultLanguage
        }
        config.language = language

        let token = ProcessInfo.processInfo.environment["GITHUB_TOKEN"]
        let metadata: ReleaseMetadata
        do {
            metadata = try await GitHubClient.latestRelease(tag: arguments.tag, token: token)
        } catch {
            session.log("ERROR: \(error)")
            if arguments.emitJSON {
                emitJSON(stage: "Failed", message: String(describing: error), elapsed: 0)
            }
            session.waitForExit(prompt: localized("press_enter", language: language))
            throw error
        }

        let confirmationMessage = localized("about_to_install", language: language, ["tag": metadata.tagName]) + "\n" + localized("prompt_continue", language: language, ["path": installURL.path])
        let proceed = session.promptYesNo(
            message: confirmationMessage,
            defaultYes: true,
            yesLabel: Localization.yesNoLabels(for: language).0,
            noLabel: Localization.yesNoLabels(for: language).1,
            hint: Localization.yesNoHint(for: language)
        )

        if !proceed {
            session.log(localized("cancelled", language: language))
            if arguments.emitJSON {
                emitJSON(stage: "Cancelled", message: localized("cancelled", language: language), elapsed: 0)
            }
            session.waitForExit(prompt: localized("press_enter", language: language))
            return
        }

        let downloadOnly = arguments.downloadOnly
        session.log(localized(downloadOnly ? "download_only_selected" : "download_and_install", language: language))

        do {
            let result = try await performUpdate(
                arguments: arguments,
                language: language,
                installURL: installURL,
                downloadOnly: downloadOnly,
                session: session,
                prefetchedMetadata: metadata
            )
            if arguments.emitJSON {
                emitJSON(stage: "Finished", message: result.message, elapsed: result.elapsed)
            }
            session.log(localized("update_elapsed", language: language, ["seconds": Int(result.elapsed)]))
            session.waitForExit(prompt: localized("press_enter", language: language))
        } catch {
            session.clearProgress()
            session.log("ERROR: \(error)")
            if arguments.emitJSON {
                emitJSON(stage: "Failed", message: String(describing: error), elapsed: 0)
            }
            session.waitForExit(prompt: localized("press_enter", language: language))
            throw error
        }
    }

    private static func runNonInteractive(arguments: UpdaterArguments, config: inout UpdaterConfig) async throws {
        let installURL = resolvedInstallURL(from: arguments)
        let language = resolveLanguage(current: config, arguments: arguments)
        config.language = language

        let downloadOnly = arguments.downloadOnly
        print(localized(downloadOnly ? "download_only_selected" : "download_and_install", language: language))
        if !downloadOnly {
            print(localized("install_prepare", language: language, ["path": installURL.path]))
        }

        do {
            let result = try await performUpdate(
                arguments: arguments,
                language: language,
                installURL: installURL,
                downloadOnly: downloadOnly,
                session: nil
            )
            if arguments.emitJSON {
                emitJSON(stage: "Finished", message: result.message, elapsed: result.elapsed)
            }
            print(localized("update_elapsed", language: language, ["seconds": Int(result.elapsed)]))
            if arguments.holdWindow {
                print(localized("press_enter", language: language))
                _ = readLine()
            }
        } catch {
            if arguments.emitJSON {
                emitJSON(stage: "Failed", message: String(describing: error), elapsed: 0)
            }
            throw error
        }
    }

    private static func performUpdate(
        arguments: UpdaterArguments,
        language: String,
        installURL: URL,
        downloadOnly: Bool,
        session: CursesSession?,
        prefetchedMetadata: ReleaseMetadata? = nil
    ) async throws -> UpdateSuccess {
        let baseDir = ConfigManager.baseDirectory
        defer { session?.clearProgress() }
        let downloadsDir = baseDir.appendingPathComponent("downloads", isDirectory: true)
        let token = ProcessInfo.processInfo.environment["GITHUB_TOKEN"]
        let start = Date()

        func log(_ key: String, _ replacements: [String: CustomStringConvertible] = [:]) {
            let message = localized(key, language: language, replacements)
            if let session {
                session.log(message)
            } else {
                print(message)
            }
        }

        func logRaw(_ message: String) {
            if let session {
                session.log(message)
            } else {
                print(message)
            }
        }

        let metadata: ReleaseMetadata
        if let prefetchedMetadata {
            metadata = prefetchedMetadata
        } else {
            log("fetching", ["url": releaseURL(arguments.tag)])
            metadata = try await GitHubClient.latestRelease(tag: arguments.tag, token: token)
        }
        log("latest_tag", ["tag": metadata.tagName])

        let asset = try selectAsset(
            metadata: metadata,
            pattern: arguments.assetPattern,
            language: language,
            session: session,
            allowManualChoice: !(arguments.assumeYes)
        )
        log("asset_selected", ["name": asset.name, "size": asset.size])

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let archiveURL = tempDir.appendingPathComponent(asset.name, isDirectory: false)
        log("downloading")
        let progressPrinter = session == nil && isatty(STDOUT_FILENO) != 0 ? ProgressPrinter(prefix: localized("downloading", language: language)) : nil
        let downloadResult = try await Downloader.download(
            from: asset.browserDownloadURL,
            to: archiveURL,
            expectedSize: asset.size,
            progress: { current, total in
                if let session {
                    session.updateProgress(
                        label: localized("downloading", language: language),
                        current: current,
                        total: total
                    )
                } else {
                    progressPrinter?.update(current: current, total: total)
                }
            }
        )
        session?.clearProgress()
        progressPrinter?.finish()
        log("download_complete", ["path": downloadResult.fileURL.path, "size": downloadResult.size])

        log("extracting")
        let extractDir = tempDir.appendingPathComponent("extracted", isDirectory: true)
        try Installer.extractArchive(archiveURL, to: extractDir)

        guard let appBundle = try findAppBundle(in: extractDir) else {
            throw UpdaterError.archive("Archive does not contain a .app bundle")
        }
        log("found_bundle", ["path": appBundle.path])

        Installer.removeQuarantine(at: appBundle)

        let releaseTag = metadata.tagName
        var finalMessage: String

        if downloadOnly {
            try FileManager.default.createDirectory(at: downloadsDir, withIntermediateDirectories: true)
            var trimmed = asset.name
            if trimmed.hasSuffix(".zip") {
                trimmed.removeLast(4)
            }
            let target = downloadsDir.appendingPathComponent(trimmed).appendingPathExtension("app")
            if FileManager.default.fileExists(atPath: target.path) {
                try FileManager.default.removeItem(at: target)
            }
            try Installer.copyBundle(from: appBundle, to: target, requireSudo: false)
            finalMessage = localized("download_only_path", language: language, ["path": target.path])
            logRaw(finalMessage)
        } else {
            log("install_prepare", ["path": installURL.path])
            let needsSudo = !installURL.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path)
            if needsSudo {
                log("requires_admin")
                var attempts = 0
                var installed = false
                while attempts < 3 && !installed {
                    attempts += 1
                    session?.pauseForExternal()
                    let password = promptForPassword(language: language)
                    var attemptSucceeded = false
                    do {
                        try Installer.copyBundleWithPassword(from: appBundle, to: installURL, password: password)
                        attemptSucceeded = true
                        installed = true
                    } catch {
                        // will handle after resuming UI
                    }
                    session?.resumeAfterExternal()
                    if !attemptSucceeded {
                        log(localized("sudo_password_retry", language: language))
                    }
                }
                if !installed {
                    throw UpdaterError.install("Administrator install failed")
                }
            } else {
                try Installer.copyBundle(from: appBundle, to: installURL, requireSudo: false)
            }
            log("install_complete")
            if let notes = metadata.htmlURL {
                log("release_notes", ["url": notes.absoluteString])
            }
            finalMessage = localized("update_complete", language: language, ["tag": releaseTag])
            logRaw(finalMessage)
            relaunchApp(at: installURL, language: language, session: session)
        }

        let elapsed = Date().timeIntervalSince(start)
        return UpdateSuccess(message: finalMessage, releaseTag: releaseTag, elapsed: elapsed)
    }

    private static func selectAsset(
        metadata: ReleaseMetadata,
        pattern: String,
        language: String,
        session: CursesSession?,
        allowManualChoice: Bool
    ) throws -> ReleaseAsset {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            throw UpdaterError.assetNotFound("Invalid asset pattern")
        }
        if let match = metadata.assets.first(where: { asset in
            let range = NSRange(location: 0, length: asset.name.utf16.count)
            return regex.firstMatch(in: asset.name, options: [], range: range) != nil
        }) {
            return match
        }
        if metadata.assets.isEmpty {
            throw UpdaterError.assetNotFound(localized("no_assets_available", language: language))
        }
        if !allowManualChoice || session == nil {
            let list = metadata.assets.map { $0.name }.joined(separator: ", ")
            throw UpdaterError.assetNotFound(localized("no_asset_auto", language: language, ["pattern": pattern, "assets": list]))
        }
        let title = localized("asset_fallback", language: language, ["pattern": pattern])
        let options = metadata.assets.enumerated().map { pair in "\(pair.offset + 1)) \(pair.element.name)" }
        let index = session!.selectIndex(
            titleLines: title.components(separatedBy: "\n"),
            options: options,
            hint: nil,
            initialIndex: 0
        )
        return metadata.assets[index]
    }

    private static func findAppBundle(in directory: URL) throws -> URL? {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        while let element = enumerator?.nextObject() as? URL {
            if element.pathExtension == "app" {
                return element
            }
        }
        return nil
    }

    private static func releaseURL(_ tag: String?) -> String {
        if let tag, !tag.isEmpty {
            return "https://api.github.com/repos/\(GitHubClient.owner)/\(GitHubClient.repo)/releases/tags/\(tag)"
        }
        return "https://api.github.com/repos/\(GitHubClient.owner)/\(GitHubClient.repo)/releases/latest"
    }

    private static func relaunchApp(at url: URL, language: String, session: CursesSession?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.path]
        try? process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let warning = localized("relaunch_warn", language: language)
            if let session {
                session.log(warning)
            } else {
                print(warning)
            }
        }
    }

    private static func localized(_ key: String, language: String, _ replacements: [String: CustomStringConvertible] = [:]) -> String {
        Localization.string(key, language: language, replacements: replacements)
    }

    private static func promptForPassword(language: String) -> String {
        let prompt = localized("sudo_password_prompt", language: language)
        fputs(prompt, stderr)
        fflush(stderr)
        return readSecureLine() ?? ""
    }

    private static func readSecureLine() -> String? {
        guard let ttyIn = fopen("/dev/tty", "r"), let ttyOut = fopen("/dev/tty", "w") else {
            return nil
        }
        defer {
            fclose(ttyIn)
            fclose(ttyOut)
        }
        var oldState = termios()
        tcgetattr(fileno(ttyIn), &oldState)
        var newState = oldState
        newState.c_lflag &= ~tcflag_t(ECHO)
        tcsetattr(fileno(ttyIn), TCSANOW, &newState)
        defer { tcsetattr(fileno(ttyIn), TCSANOW, &oldState) }
        var buffer = [CChar](repeating: 0, count: 1024)
        let result = fgets(&buffer, Int32(buffer.count), ttyIn)
        fputs("\n", ttyOut)
        guard result != nil else { return nil }
        let rawBytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let raw = String(decoding: rawBytes, as: UTF8.self)
        return raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
    }

    private static func emitJSON(stage: String, message: String, elapsed: TimeInterval) {
        let payload: [String: Any] = [
            "stage": stage,
            "message": message,
            "elapsed_seconds": elapsed
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: []) {
            if let string = String(data: data, encoding: .utf8) {
                print(string)
            }
        }
    }
}

private final class ProgressPrinter {
    private var lastPercent: Int = -1
    private let prefix: String

    init(prefix: String) {
        self.prefix = prefix
    }

    func update(current: Int, total: Int?) {
        guard let total, total > 0 else {
            return
        }
        let percent = Int(Double(current) / Double(total) * 100.0)
        guard percent != lastPercent else { return }
        lastPercent = percent
        let message = String(format: "%@ %3d%% (%0.1f/%0.1f MB)", prefix, percent, Double(current) / 1_048_576.0, Double(total) / 1_048_576.0)
        print("\r\(message)", terminator: "")
        fflush(stdout)
    }

    func finish() {
        if lastPercent >= 0 {
            print("")
        }
    }
}
