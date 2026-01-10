import AppKit
import Foundation

enum SoundEvent {
    case launchpadOpen
    case launchpadClose
    case navigation
}

struct SystemSoundOption: Identifiable, Hashable {
    let id: String
    let displayName: String
}

final class SoundManager {
    static let shared = SoundManager()

    private weak var appStore: AppStore?
    private var baseSounds: [String: NSSound] = [:]

    private init() {}

    func bind(appStore: AppStore) {
        self.appStore = appStore
    }

    func play(_ event: SoundEvent) {
        DispatchQueue.main.async { [weak self] in
            self?.playInternal(event: event)
        }
    }

    func preview(systemSoundNamed name: String) {
        guard !name.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            _ = self?.playSystemSound(named: name, respectToggle: false)
        }
    }

    private func playInternal(event: SoundEvent) {
        guard let store = appStore, store.soundEffectsEnabled else { return }
        if store.voiceFeedbackEnabled, event == .navigation {
            return
        }
        guard let name = soundName(for: event), !name.isEmpty else { return }
        _ = playSystemSound(named: name, respectToggle: false)
    }

    private func soundName(for event: SoundEvent) -> String? {
        guard let store = appStore else { return nil }
        switch event {
        case .launchpadOpen:
            return store.soundLaunchpadOpenSound
        case .launchpadClose:
            return store.soundLaunchpadCloseSound
        case .navigation:
            return store.soundNavigationSound
        }
    }

    @discardableResult
    private func playSystemSound(named name: String, respectToggle: Bool) -> Bool {
        if respectToggle {
            guard appStore?.soundEffectsEnabled == true else { return false }
        }
        guard let sound = makeSound(named: name) else { return false }
        sound.volume = 1.0
        return sound.play()
    }

    private func makeSound(named name: String) -> NSSound? {
        if let base = baseSounds[name], let copy = base.copy() as? NSSound {
            return copy
        }

        if let url = urlForSystemSound(named: name), let sound = NSSound(contentsOf: url, byReference: true) {
            baseSounds[name] = sound
            return sound.copy() as? NSSound ?? sound
        }

        if let sound = NSSound(named: NSSound.Name(name)) {
            baseSounds[name] = sound
            return sound.copy() as? NSSound ?? sound
        }

        return nil
    }

    private func urlForSystemSound(named name: String) -> URL? {
        let baseURL = URL(fileURLWithPath: "/System/Library/Sounds")
        for ext in ["aiff", "caf"] {
            let url = baseURL.appendingPathComponent("\(name).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    static let systemSoundOptions: [SystemSoundOption] = [
        SystemSoundOption(id: "Basso", displayName: "Basso"),
        SystemSoundOption(id: "Blow", displayName: "Blow"),
        SystemSoundOption(id: "Bottle", displayName: "Bottle"),
        SystemSoundOption(id: "Frog", displayName: "Frog"),
        SystemSoundOption(id: "Funk", displayName: "Funk"),
        SystemSoundOption(id: "Glass", displayName: "Glass"),
        SystemSoundOption(id: "Hero", displayName: "Hero"),
        SystemSoundOption(id: "Morse", displayName: "Morse"),
        SystemSoundOption(id: "Ping", displayName: "Ping"),
        SystemSoundOption(id: "Pop", displayName: "Pop"),
        SystemSoundOption(id: "Purr", displayName: "Purr"),
        SystemSoundOption(id: "Sosumi", displayName: "Sosumi"),
        SystemSoundOption(id: "Submarine", displayName: "Submarine"),
        SystemSoundOption(id: "Tink", displayName: "Tink")
    ]

    private static let systemSoundSet: Set<String> = Set(systemSoundOptions.map { $0.id })

    static func isValidSystemSoundName(_ name: String) -> Bool {
        systemSoundSet.contains(name)
    }
}
