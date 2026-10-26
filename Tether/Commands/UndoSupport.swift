import SwiftUI
import UIKit

/// Undo / redo toolbar buttons titled with the editor's own edit titles
/// ("Undo Rate 5★"). Disabled, not hidden, so the layout never jumps.
struct UndoRedoButtons: View {
    @Environment(AppModel.self) private var app
    var model: LibraryModel

    var body: some View {
        Button { app.commands.undo() } label: { Label(model.undoTitle.map { "Undo \($0)" } ?? "Undo", systemImage: "arrow.uturn.backward") }
            .disabled(model.undoTitle == nil)
            .accessibilityLabel(model.undoTitle.map { "Undo \($0)" } ?? "Nothing to undo")
            .macToolbarTint()
        Button { app.commands.redo() } label: { Label(model.redoTitle.map { "Redo \($0)" } ?? "Redo", systemImage: "arrow.uturn.forward") }
            .disabled(model.redoTitle == nil)
            .accessibilityLabel(model.redoTitle.map { "Redo \($0)" } ?? "Nothing to redo")
            .macToolbarTint()
    }
}

/// iPhone shake-to-undo. A zero-size view controller that becomes first
/// responder and forwards the shake motion event.
struct ShakeDetector: UIViewControllerRepresentable {
    var onShake: () -> Void

    func makeUIViewController(context: Context) -> ShakeViewController {
        let vc = ShakeViewController()
        vc.onShake = onShake
        return vc
    }

    func updateUIViewController(_ vc: ShakeViewController, context: Context) { vc.onShake = onShake }
}

final class ShakeViewController: UIViewController {
    var onShake: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake { onShake?() } else { super.motionEnded(motion, with: event) }
    }
}
