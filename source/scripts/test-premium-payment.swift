import Foundation

@main
struct PremiumPaymentChecks {
    static func main() {
        let now = 1_000.0
        func closes(_ user: String? = "owner", _ paid: Bool = true,
                    _ expiry: Double? = 2_000, _ baseline: Double = 0) -> Bool {
            PremiumPaymentPolicy.shouldClose(expectedAccount: "owner", currentAccount: user,
                premium: paid, expiry: expiry, previousExpiry: baseline, now: now)
        }
        precondition(closes(), "New confirmed entitlement must close checkout")
        precondition(!closes("other"), "Another account must not close checkout")
        precondition(!closes(nil), "Logged-out session must not close checkout")
        precondition(!closes("owner", false), "Pending/failed payment must stay open")
        precondition(!closes("owner", true, nil), "Missing expiry must stay open")
        precondition(!closes("owner", true, 900), "Expired entitlement must stay open")
        precondition(!closes("owner", true, 2_000, 2_000), "Old subscription must not close new checkout")
        precondition(closes("owner", true, 3_000, 2_000), "Confirmed renewal must close checkout")
        precondition(!closes("owner", true, Double.nan), "NaN expiry must stay open")
        precondition(!closes("owner", true, Double.infinity), "Infinite expiry must stay open")
        print("10 Premium payment confirmation checks passed")
    }
}
