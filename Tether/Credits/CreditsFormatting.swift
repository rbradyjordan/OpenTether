import Foundation
import TetherCore

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

    static func renewalText(_ state: CreditsState) -> String {
        guard let date = state.renewsAt else { return "\(state.monthlyGrant) free credits each month" }
        return "\(state.monthlyGrant) free credits renew \(date.formatted(date: .abbreviated, time: .omitted))"
    }
}
