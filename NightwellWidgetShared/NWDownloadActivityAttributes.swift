import Foundation
import ActivityKit

// Compiled into both the app and the existing WidgetKit extension.
struct NWDownloadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let active: Bool
        let total: Int
        let completed: Int
        let saved: Int
        let failed: Int
        let percent: Int

        init(active: Bool, total: Int, saved: Int, failed: Int, pendingFraction: Double) {
            self.active = active
            self.total = max(0, total)
            self.saved = max(0, saved)
            self.failed = max(0, failed)
            self.completed = min(self.total, self.saved + self.failed)
            let progress = self.total > 0 ?
                (Double(self.completed) + max(0, pendingFraction.isFinite ? pendingFraction : 0)) / Double(self.total) : 0
            self.percent = active ? min(99, max(0, Int((min(1, progress) * 100).rounded(.down)))) :
                (self.total > 0 ? 100 : 0)
        }

        var fraction: Double { Double(percent) / 100 }
        var title: String {
            active ? "Скачивание музыки" : (failed > 0 ? "Загрузка завершена с ошибками" : "Музыка скачана")
        }
    }
}
