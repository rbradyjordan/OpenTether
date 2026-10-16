import Foundation
import TetherCore

/// The export sheet's live quote line: "24 photos · 3 credits · 21 watermarked".
/// `watermark` is the segment the UI tints `warn`.
struct ExportQuoteLine: Equatable {
    var lead: String
    var watermark: String?

    var text: String { [lead, watermark].compactMap { $0 }.joined(separator: " · ") }
}

enum CreditsFormatting {
    /// "3 credits · 2 watermarked", "Free (Pro)", "No credits needed"…
    static func quoteText(_ q: CreditsState.Quote, tier: CreditsState.Tier) -> String {
        if tier == .pro { return "Included in Pro" }
        if q.totalItems == 0 { return "Nothing to export" }
        var parts: [String] = []
        parts.append(q.credits == 1 ? "1 credit" : "\(q.credits) credits")
        if q.watermarkedItems > 0 { parts.append("\(q.watermarkedItems) watermarked") }
        return parts.joined(separator: " · ")
    }

    /// One line that updates as the scope changes.
    static func quoteLine(photos: Int, quote q: CreditsState.Quote, tier: CreditsState.Tier) -> ExportQuoteLine {
        if photos == 0 { return ExportQuoteLine(lead: "Nothing to export", watermark: nil) }
        let count = photos == 1 ? "1 photo" : "\(photos) photos"
        if tier == .pro { return ExportQuoteLine(lead: "\(count) · included in Pro", watermark: nil) }
        let credits = q.credits == 1 ? "1 credit" : "\(q.credits) credits"
        let watermark = q.watermarkedItems > 0 ? "\(q.watermarkedItems) watermarked" : nil
        return ExportQuoteLine(lead: "\(count) · \(credits)", watermark: watermark)
    }

    static func renewalText(_ state: CreditsState) -> String {
        guard let date = state.renewsAt else { return "\(state.monthlyGrant) free credits each month" }
        return "\(state.monthlyGrant) free credits renew \(date.formatted(date: .abbreviated, time: .omitted))"
    }
}
