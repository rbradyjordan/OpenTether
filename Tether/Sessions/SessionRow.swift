import SwiftUI
import TetherCore

struct SessionRow: View {
    var session: ShootSession
    var counts: SessionStore.SessionCounts

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(session.status == .ended ? Theme.textSecondary : Theme.accent).frame(width: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.name).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(2)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(counts.total)").font(.title3.weight(.semibold).monospacedDigit())
                if counts.picks > 0 { Label("\(counts.picks)", systemImage: "flag.fill").font(.caption2).foregroundStyle(Theme.success) }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(session.name), \(counts.total) frames, \(counts.picks) picks, \(session.status.rawValue)")
    }

    private var icon: String {
        switch session.transport {
        case .usb?: return "cable.connector"
        case .ptpip?, .ricohHTTP?: return "wifi"
        case .ftpPush?: return "arrow.down.doc"
        case nil: return "rectangle.stack"
        }
    }

    private var subtitle: String {
        var parts = [session.createdAt.formatted(date: .abbreviated, time: .shortened)]
        if let camera = session.camera { parts.append(camera.displayName) }
        if session.status != .ended { parts.append(session.status.rawValue.capitalized) }
        if let tag = session.workflowTag, !tag.isEmpty { parts.append("#\(tag)") }
        return parts.joined(separator: " · ")
    }
}
