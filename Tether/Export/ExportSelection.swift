import Foundation
import TetherCore

/// Which captures an export covers. Pure so it is unit-tested.
enum ExportScope: Hashable, Identifiable {
    case all
    case picks
    case rated(min: Int)
    case selected

    var id: String {
        switch self {
        case .all: return "all"
        case .picks: return "picks"
        case .rated(let n): return "rated\(n)"
        case .selected: return "selected"
        }
    }

    var title: String {
        switch self {
        case .all: return "All"
        case .picks: return "Picks"
        case .rated(let n): return "Rated ≥ \(n)"
        case .selected: return "Selected"
        }
    }

    static let presets: [ExportScope] = [.all, .picks, .rated(min: 3), .selected]

    func filter(_ items: [CaptureItem], selectedID: String?) -> [CaptureItem] {
        let ready = items.filter { $0.state.isReady }
        switch self {
        case .all: return ready.filter { $0.flag != .reject }
        case .picks: return ready.filter { $0.flag == .pick }
        case .rated(let n): return ready.filter { $0.rating >= n && $0.flag != .reject }
        case .selected:
            guard let selectedID, let item = ready.first(where: { $0.id == selectedID }) else { return [] }
            return ready.filter { $0.pairKey == item.pairKey }
        }
    }
}

enum ExportDestinationChoice: Hashable, Identifiable {
    case photos, files, share, ftp(String), cloud
    var id: String {
        switch self {
        case .photos: return "photos"
        case .files: return "files"
        case .share: return "share"
        case .ftp(let id): return "ftp-\(id)"
        case .cloud: return "cloud"
        }
    }
    var destination: ExportDestination {
        switch self {
        case .photos: return .photos
        case .files: return .files
        case .share: return .share
        case .ftp(let id): return .ftp(destinationID: id)
        case .cloud: return .cloudBatch
        }
    }
}
