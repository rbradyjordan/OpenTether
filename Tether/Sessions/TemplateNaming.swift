import Foundation
import TetherCore

/// Thin wrapper over `SessionTemplate.sessionName` so the New Session sheet can
/// preview a pattern while the user is still typing it, and so the expansion
/// rules are unit-tested from the app side.
enum TemplateNaming {
    static let placeholders = ["{date}", "{name}", "{camera}", "{n}"]

    static func expand(_ template: WorkspaceMemory.SessionTemplate, camera: CameraIdentity?, index: Int, now: Date = Date()) -> String {
        template.sessionName(camera: camera, index: index, now: now)
    }

    /// Preview for a pattern that is not saved yet. Mirrors the core rules
    /// (`yyyy-MM-dd`, zero-padded `{n}`) but takes a plain camera name.
    static func preview(pattern: String, templateName: String, cameraName: String?, index: Int, now: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return pattern
            .replacingOccurrences(of: "{date}", with: f.string(from: now))
            .replacingOccurrences(of: "{name}", with: templateName)
            .replacingOccurrences(of: "{camera}", with: (cameraName?.isEmpty == false ? cameraName! : "Camera"))
            .replacingOccurrences(of: "{n}", with: String(format: "%03d", index))
            .trimmingCharacters(in: .whitespaces)
    }

    /// Next `{n}`: one more than the sessions that already exist.
    static func nextIndex(sessionCount: Int) -> Int { max(1, sessionCount + 1) }
}
