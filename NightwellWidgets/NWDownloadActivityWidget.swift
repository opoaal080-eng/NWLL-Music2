import SwiftUI
import WidgetKit
import ActivityKit

struct NWDownloadActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NWDownloadActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Image(systemName: context.state.active ? "arrow.down.circle.fill" :
                        (context.state.failed > 0 ? "exclamationmark.circle.fill" : "checkmark.circle.fill"))
                    Text(context.state.title).font(.headline).lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(context.state.percent)%").font(.headline).monospacedDigit()
                }
                ProgressView(value: context.state.fraction).tint(.white)
                details(context.state)
            }
            .padding(16)
            .foregroundStyle(.white)
            .activityBackgroundTint(Color(white: 0.09))
            .activitySystemActionForegroundColor(.white)
            .widgetURL(URL(string: "nightwell://open/offline"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Nightwell", systemImage: "arrow.down.circle.fill")
                        .font(.caption.weight(.semibold)).lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text("\(context.state.percent)%").font(.headline).monospacedDigit()
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(context.state.title).font(.subheadline.weight(.medium)).lineLimit(1)
                        ProgressView(value: context.state.fraction).tint(.white)
                        details(context.state)
                    }
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.white)
            } compactTrailing: {
                Text("\(context.state.percent)%")
                    .font(.caption2.weight(.semibold)).monospacedDigit()
            } minimal: {
                ZStack {
                    Circle().stroke(.white.opacity(0.22), lineWidth: 2)
                    Circle().trim(from: 0, to: CGFloat(context.state.fraction))
                        .stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: "arrow.down").font(.system(size: 10, weight: .semibold))
                }.frame(width: 22, height: 22)
                .accessibilityLabel("Скачивание \(context.state.percent)%")
            }
            .widgetURL(URL(string: "nightwell://open/offline"))
            .keylineTint(.white)
        }
    }

    private func details(_ state: NWDownloadActivityAttributes.ContentState) -> some View {
        HStack {
            Text("Треки: \(state.completed) из \(state.total)")
            Spacer(minLength: 4)
            if state.failed > 0 { Text("Ошибок: \(state.failed)").foregroundStyle(.orange) }
            else { Text("Сохранено: \(state.saved)") }
        }
        .font(.caption2).monospacedDigit().foregroundStyle(.white.opacity(0.72))
    }
}
