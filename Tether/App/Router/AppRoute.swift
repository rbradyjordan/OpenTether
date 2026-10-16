import Foundation
import TetherCore

enum AppTab: Hashable {
    case shoot, sessions, settings
}

/// Navigation destinations pushed inside the Connect / Sessions / Settings stacks.
enum AppRoute: Hashable {
    case usb
    case wifi
    case ftpReceiver
    case brandGuides
    case brandGuide(CameraVendor)
    case diagnostics(wired: Bool)
    case sessionDetail(String)
    case credits
    case ftpDestinations
    case exportProgress(sessionID: String?)
    case ptpLog
    case testedCameras
    case privacy
    case about
}

/// Sheets presented from the shoot screen.
enum ShootSheet: Identifiable {
    case looks, colorMatch, export, exportProgress, compare, property(TetherProperty), reconnect, newSession
    var id: String {
        switch self {
        case .looks: return "looks"
        case .colorMatch: return "colorMatch"
        case .export: return "export"
        case .exportProgress: return "exportProgress"
        case .compare: return "compare"
        case .property(let p): return "property-\(p.rawValue)"
        case .reconnect: return "reconnect"
        case .newSession: return "newSession"
        }
    }
}
