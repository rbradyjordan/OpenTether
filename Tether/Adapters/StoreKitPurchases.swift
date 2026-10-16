import Foundation
import Observation
import StoreKit
import TetherCore

/// StoreKit 2 wrapper. Loads the credit products, purchases, hands the signed
/// transaction to the cloud (which applies the credits), and finishes.
@Observable @MainActor
final class StoreKitPurchases {
    private(set) var products: [Product] = []
    private(set) var isLoading = false
    private(set) var isPurchasing = false
    var lastError: String?

    private let cloud: () -> TetherCloudClient
    private var updates: Task<Void, Never>?

    init(cloud: @escaping () -> TetherCloudClient) {
        self.cloud = cloud
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                await self?.handle(result)
            }
        }
    }

    func loadProducts() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let loaded = try await Product.products(for: CreditProduct.allCases.map(\.rawValue))
            products = loaded.sorted { $0.price < $1.price }
        } catch {
            lastError = "Could not load products: \(error.localizedDescription)"
        }
    }

    func product(for credit: CreditProduct) -> Product? { products.first { $0.id == credit.rawValue } }

    /// Returns the updated credits state when the server applied the purchase.
    @discardableResult
    func purchase(_ product: Product) async -> CreditsState? {
        isPurchasing = true
        defer { isPurchasing = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                return await handle(verification)
            case .userCancelled, .pending:
                return nil
            @unknown default:
                return nil
            }
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func restore() async -> CreditsState? {
        do { try await AppStore.sync() } catch { lastError = error.localizedDescription }
        var latest: CreditsState?
        for await result in Transaction.currentEntitlements {
            if let state = await handle(result) { latest = state }
        }
        return latest
    }

    @discardableResult
    private func handle(_ result: VerificationResult<Transaction>) async -> CreditsState? {
        guard case .verified(let transaction) = result else { return nil }
        guard let credit = CreditProduct(rawValue: transaction.productID) else {
            await transaction.finish()
            return nil
        }
        let signed = result.jwsRepresentation
        let fallback = transaction.jsonRepresentation.base64EncodedString()
        do {
            let purchase = try await cloud().purchase(product: credit, transactionID: String(transaction.id),
                                                      signedTransaction: signed.isEmpty ? fallback : signed)
            await transaction.finish()
            return CreditsState(tier: CreditsState.Tier(rawValue: purchase.tier) ?? .free, balance: purchase.credits.balance,
                                monthlyGrant: purchase.credits.monthlyGrant, renewsAt: purchase.credits.renewsAt)
        } catch {
            // Leave unfinished so StoreKit redelivers it; the server replays idempotently.
            lastError = "Purchase recorded by the App Store but not yet applied: \(error)"
            return nil
        }
    }
}
