import UIKit

enum HapticFeedback {
    @MainActor static func shutter() { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
    @MainActor static func light() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    @MainActor static func selection() { UISelectionFeedbackGenerator().selectionChanged() }
    @MainActor static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    @MainActor static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
    @MainActor static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
}
