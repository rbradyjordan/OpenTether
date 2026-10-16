import StoreKit
import SwiftUI
import TetherCore

struct CreditsView: View {
    @Environment(AppModel.self) private var app
    @State private var busy = false

    var body: some View {
        let credits = app.credits
        ScrollView {
            VStack(spacing: 12) {
                SectionCard(title: credits.tier == .pro ? "Pro" : "Free tier", systemImage: credits.tier == .pro ? "star.circle.fill" : "person.circle") {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(credits.balance)").font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
                        Text("credits").foregroundStyle(Theme.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                    Text(CreditsFormatting.renewalText(credits)).font(.footnote).foregroundStyle(Theme.textSecondary)
                    if let id = app.settings.accountID { Text("Account \(id)").font(.caption2.monospaced()).foregroundStyle(Theme.textSecondary) }
                }
                SectionCard(title: "How it works", systemImage: "info.circle") {
                    Text("Every clean JPEG export costs 1 credit; AI colour match costs \(CreditsState.colorMatchCost). You get \(credits.monthlyGrant) free each month. When they run out, exports still work but carry a translucent TETHER watermark. RAW files and session storage never cost anything. Pro removes the watermark and the counting.")
                        .font(.footnote)
                }
                SectionCard(title: "Buy", systemImage: "cart") {
                    if app.purchases.products.isEmpty {
                        HStack { if app.purchases.isLoading { ProgressView().controlSize(.small) }; Text(app.purchases.isLoading ? "Loading products…" : "Products unavailable right now.").font(.subheadline) }
                    }
                    ForEach(app.purchases.products, id: \.id) { product in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(CreditProduct(rawValue: product.id)?.displayName ?? product.displayName).font(.subheadline.weight(.medium))
                                Text(CreditProduct(rawValue: product.id)?.detail ?? product.description).font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                            Spacer()
                            Button(product.displayPrice) {
                                Task {
                                    busy = true
                                    if let state = await app.purchases.purchase(product) { app.credits = state }
                                    busy = false
                                }
                            }
                            .buttonStyle(.borderedProminent).controlSize(.small).disabled(busy || app.purchases.isPurchasing)
                            .accessibilityLabel("Buy \(CreditProduct(rawValue: product.id)?.displayName ?? product.displayName) for \(product.displayPrice)")
                        }
                    }
                    Button("Restore purchases") {
                        Task { if let state = await app.purchases.restore() { app.credits = state } }
                    }
                    .font(.footnote)
                    if let error = app.purchases.lastError { Text(error).font(.caption).foregroundStyle(Theme.danger) }
                }
                if app.cloudReachable == false {
                    Text("The Tether cloud is unreachable; balances shown are the last known values.").font(.caption).foregroundStyle(Theme.warning)
                }
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle("Credits")
        .task {
            await app.purchases.loadProducts()
            await app.refreshCredits()
        }
    }
}
