import SwiftUI
import AppKit

// MARK: - Color Extensions
extension Color {
    static var launchpadBorder: Color {
        Color(.systemBlue)
    }
}

// MARK: - Font Extensions
extension Font {
    static var `default`: Font {
        .system(size: 11, weight: .medium)
    }
}

// MARK: - View Extensions for Glass Effect
extension View {
    @ViewBuilder
    func liquidGlass<S: Shape>(in shape: S, isEnabled: Bool = true) -> some View {
        if #available(macOS 26.0, iOS 18.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }

    @ViewBuilder
    func liquidGlass(isEnabled: Bool = true) -> some View {
        if #available(macOS 26.0, iOS 18.0, *) {
            self.glassEffect(.regular)
        } else {
            self.background(.ultraThinMaterial)
        }
    }
}
 
