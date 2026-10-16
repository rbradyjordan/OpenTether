import StoreKit
import SwiftUI
import TetherCore

/// Balance as a display numeral, then pack cards. Light scheme (system).
struct CreditsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var busy = false

    var body: some View {
        let credits = app.credits
        ScrollView {
            VStack(spacing: TetherSpace.m) {
                balanceCard(credits)
                howItWorks(credits)
                packs
                if app.cloudReachable == false {
                    Label("The Open Tether cloud is unreachable; balances shown are the last known values.", systemImage: "exclamationmark.triangle.fill")
                        .font(TetherFont.hud).foregroundStyle(TetherColor.warn)
                }
            }
            .padding(TetherSpace.l)
        }
        .background(TetherColor.surface1)
        .navigationTitle("Credits")
        .task {
            await app.purchases.loadProducts()
            await app.refreshCredits()
        }
    }

    private func balanceCard(_ credits: CreditsState) -> some View {
        VStack(alignment: .leading, spacing: TetherSpace.s) {
            HStack {
                Text(credits.tier == .pro ? "Pro" : "Free tier").tetherCaption().foregroundStyle(TetherColor.ink2)
                Spacer()
                if credits.tier == .pro { TonePill(text: "No watermark", tone: .ok, systemImage: "star.circle.fill") }
            }
            HStack(alignment: .firstTextBaseline, spacing: TetherSpace.s) {
                Text("\(credits.balance)")
                    .font(.system(size: 56, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(TetherColor.ink0)
                    .contentTransition(.numericText())
                    .animation(Motion.spring(TetherMotion.snap, reduce: reduceMotion), value: credits.balance)
                Text(credits.balance == 1 ? "credit" : "credits").font(TetherFont.title).foregroundStyle(TetherColor.ink1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(credits.balance) credits")
            Text(CreditsFormatting.renewalText(credits)).font(TetherFont.callout).foregroundStyle(TetherColor.ink1)
            if let id = app.settings.accountID {
                Text("Account \(id)").font(TetherFont.hud).foregroundStyle(TetherColor.ink2)
            }
        }
        .padding(TetherSpace.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tetherCard()
    }

    private func howItWorks(_ credits: CreditsState) -> some View {
        SectionCard(title: "How it works", systemImage: "info.circle") {
            Text("Every clean JPEG export costs 1 credit; AI colour match costs \(CreditsState.colorMatchCost). You get \(credits.monthlyGrant) free each month. When they run out, exports still work but carry a translucent TETHER watermark. RAW files and session storage never cost anything. Pro removes the watermark and the counting.")
                .font(TetherFont.callout).foregroundStyle(TetherColor.ink1)
        }
    }

    private var packs: some View {
        VStack(alignment: .leading, spacing: TetherSpace.m) {
            Text("Buy").tetherCaption().foregroundStyle(TetherColor.ink2).padding(.horizontal, TetherSpace.xs)
            if app.purchases.products.isEmpty {
                HStack(spacing: TetherSpace.s) {
                    if app.purchases.isLoading { ProgressView().controlSize(.small) }
                    Text(app.purchases.isLoading ? "Loading products…" : "Products unavailable right now.")
                        .font(TetherFont.callout).foregroundStyle(TetherColor.ink1)
                }
                .padding(TetherSpace.l).frame(maxWidth: .infinity, alignment: .leading).tetherCard()
            }
            ForEach(app.purchases.products, id: \.id) { product in
                PackCard(name: CreditProduct(rawValue: product.id)?.displayName ?? product.displayName,
                         detail: CreditProduct(rawValue: product.id)?.detail ?? product.description,
                         price: product.displayPrice,
                         disabled: busy || app.purchases.isPurchasing) {
                    Task {
                        busy = true
                        if let state = await app.purchases.purchase(product) { app.credits = state }
                        busy = false
                    }
                }
            }
            Button("Restore purchases") {
                Task { if let state = await app.purchases.restore() { app.credits = state } }
            }
            .font(TetherFont.hud)
            .frame(minHeight: TetherHit.min)
            .padding(.horizontal, TetherSpace.xs)
            if let error = app.purchases.lastError {
                Text(error).font(TetherFont.hud).foregroundStyle(TetherColor.danger)
            }
        }
    }
}

private struct PackCard: View {
    var name: String
    var detail: String
    var price: String
    var disabled: Bool
    var buy: () -> Void

    var body: some View {
        HStack(spacing: TetherSpace.l) {
            VStack(alignment: .leading, spacing: TetherSpace.xs) {
                Text(name).font(TetherFont.headline).foregroundStyle(TetherColor.ink0)
                Text(detail).font(TetherFont.callout).foregroundStyle(TetherColor.ink1)
            }
            Spacer(minLength: TetherSpace.s)
            Button(price, action: buy)
                .buttonStyle(.borderedProminent)
                .tint(TetherColor.accent)
                .font(TetherFont.hud)
                .frame(minHeight: TetherHit.min)
                .disabled(disabled)
                .accessibilityLabel("Buy \(name) for \(price)")
        }
        .padding(TetherSpace.l)
        .tetherCard()
    }
}
