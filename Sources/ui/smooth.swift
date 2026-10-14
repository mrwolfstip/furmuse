import SwiftUI
import UIKit

// shared helpers that make the app feel smooth: one spring, one ease, a press effect for buttons, and light haptics.

extension Animation {
    // the one spring used for taps, toggles and small state changes
    static var softspring: Animation { .spring(response: 0.32, dampingFraction: 0.82) }
    // the one ease used for screens and sections appearing
    static var softease: Animation { .easeInOut(duration: 0.28) }
}

enum Haptic {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func firm() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func select() { UISelectionFeedbackGenerator().selectionChanged() }
}

// buttons shrink a little while pressed and spring back
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.88
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
