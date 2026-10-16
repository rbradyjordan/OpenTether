import Foundation
import TetherCore

/// Which captures an export covers. Pure so it is unit-tested.
enum ExportScope: Hashable, Identifiable {
    case all
    case picks
    case rated(min: Int)
    case selected
    /// The library's multi-selection, by count (the ids travel separately).
    case selection(Int)
    /// Everything in the open collection.
    case collection

    var id: String {
        switch self {
        case .all: return "all"
        case .picks: return "picks"
        case .rated(let n): return "rated\(n)"
        case .selected: return "selected"
        case .selection: return "selection"
        case .collection: return "collection"
        }
    }

    var title: String {
        switch self {
        case .all: return "All"
        case .picks: return "Picks"
        case .rated(let n): return "Rated ≥ \(n)"
        case .selected: return "Selected"
        case .selection(let n): return "Selection (\(n))"
        case .collection: return "This collection"
        }
    }

    static let presets: [ExportScope] = [.all, .picks, .rated(min: 3), .selected]

    /// Presets for a sheet opened from the library: the selection and the
    /// collection replace the single-frame "Selected".
    static func presets(selectionCount: Int, inCollection: Bool) -> [ExportScope] {
        var out: [ExportScope] = [.all, .picks, .rated(min: 3)]
        if selectionCount > 0 { out.append(.selection(selectionCount)) }
        if inCollection { out.append(.collection) }
        if selectionCount == 0, !inCollection { out.append(.selected) }
        return out
    }

    /// Restores the remembered scope id ("picks", "rated4", "selection"…).
    static func from(memory id: String, selectionCount: Int, inCollection: Bool) -> ExportScope? {
        switch id {
        case "all": return .all
        case "picks": return .picks
        case "selected": return .selected
        case "selection": return selectionCount > 0 ? .selection(selectionCount) : nil
        case "collection": return inCollection ? .collection : nil
        default:
            guard id.hasPrefix("rated"), let n = Int(id.dropFirst(5)) else { return nil }
            return .rated(min: n)
        }
    }

    func filter(_ items: [CaptureItem], selectedID: String?, selectionIDs: Set<String> = []) -> [CaptureItem] {
        let ready = items.filter { $0.state.isReady }
        switch self {
        case .all, .collection: return ready.filter { $0.flag != .reject }
        case .picks: return ready.filter { $0.flag == .pick }
        case .rated(let n): return ready.filter { $0.rating >= n && $0.flag != .reject }
        case .selected:
            guard let selectedID, let item = ready.first(where: { $0.id == selectedID }) else { return [] }
            return ready.filter { $0.pairKey == item.pairKey }
        case .selection:
            return ready.filter { selectionIDs.contains($0.id) }
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

    init(_ destination: ExportDestination) {
        switch destination {
        case .photos: self = .photos
        case .files: self = .files
        case .share: self = .share
        case .ftp(let id): self = .ftp(id)
        case .cloudBatch: self = .cloud
        }
    }
}
