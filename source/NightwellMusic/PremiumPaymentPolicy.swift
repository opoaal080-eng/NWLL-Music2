import Foundation

// Browser redirects cannot grant access. Close checkout only when this account
// has a new, unexpired entitlement confirmed by the authenticated server API.
enum PremiumPaymentPolicy {
    static func shouldClose(expectedAccount: String, currentAccount: String?, premium: Bool,
                            expiry: Double?, previousExpiry: Double, now: Double) -> Bool {
        guard !expectedAccount.isEmpty, currentAccount == expectedAccount, premium,
              let expiry, expiry.isFinite, previousExpiry.isFinite, now.isFinite else { return false }
        return expiry > now && expiry > previousExpiry
    }
}
