import AppKit
import Foundation

final class VoiceManager {
    static let shared = VoiceManager()

    private let synthesizer = NSSpeechSynthesizer()
    private weak var appStore: AppStore?
    private var pendingAnnouncement: DispatchWorkItem?

    private init() {}

    func bind(appStore: AppStore) {
        self.appStore = appStore
    }

    func announceSelection(item: LaunchpadItem?) {
        guard let store = appStore, store.voiceFeedbackEnabled else { return }

        pendingAnnouncement?.cancel()

        let work = DispatchWorkItem { [weak self] in
            self?.speak(for: item)
        }
        pendingAnnouncement = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    func stop() {
        pendingAnnouncement?.cancel()
        pendingAnnouncement = nil
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking()
        }
    }

    private func speak(for item: LaunchpadItem?) {
        guard let store = appStore, store.voiceFeedbackEnabled else { return }

        let phrase: String?
        switch item {
        case .app(let app):
            phrase = String(format: store.localized(.voiceAnnouncementAppFormat), app.name)
        case .folder(let folder):
            phrase = String(format: store.localized(.voiceAnnouncementFolderFormat), folder.name)
        default:
            phrase = nil
        }

        guard let phrase, !phrase.isEmpty else { return }

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking()
        }
        synthesizer.startSpeaking(phrase)
    }
}
