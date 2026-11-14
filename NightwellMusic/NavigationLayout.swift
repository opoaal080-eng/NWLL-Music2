import Foundation

enum NavigationLayout: String, CaseIterable, Identifiable {
    case belowPlayer
    case menu

    static let storageKey = "nw-navigation-layout"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .belowPlayer: return "Под миниплеером"
        case .menu: return "Через меню"
        }
    }

    var detail: String {
        switch self {
        case .belowPlayer: return "Главная, поиск и медиатека — под миниплеером."
        case .menu: return "Главная, поиск, медиатека и другие разделы открываются через кнопку меню. Аватарка сразу открывает профиль."
        }
    }

    var showsTabs: Bool { self != .menu }
}
