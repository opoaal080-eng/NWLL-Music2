import Foundation
import AppIntents
import WidgetKit

enum NWWidgetConfiguration {
    static let kind = "nightwell.nowplaying.v3"
    static let previousKind = "nightwell.nowplaying.v2"
    static let legacyKind = "nightwell.nowplaying"
    // Preserve case: the scoped token is base64url, NOT a hexadecimal code.
    static func accessToken(_ input: String?) -> String? {
        guard let input else { return nil }
        let key = input.filter { !$0.isWhitespace }
        guard key.hasPrefix("NW2."), key.count >= 40, key.count <= 94 else { return nil }
        let token = String(key.dropFirst(4))
        return token.utf8.allSatisfy { b in
            (65...90).contains(b) || (97...122).contains(b) ||
            (48...57).contains(b) || b == 45 || b == 95
        } ? token : nil
    }
    static func reload() {
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
        WidgetCenter.shared.reloadTimelines(ofKind: previousKind)
        WidgetCenter.shared.reloadTimelines(ofKind: legacyKind)
        WidgetCenter.shared.reloadTimelines(ofKind: "nightwell.quickaccess")
    }
}

// Compiled into both the host application and widget extension.
struct NWNowPlayingConfigurationV2: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Сейчас играет"
    static var description = IntentDescription("Вставь ключ NW2 из профиля Nightwell Music.")
    @Parameter(title: "Ключ доступа")
    var accessKey: String?
}
