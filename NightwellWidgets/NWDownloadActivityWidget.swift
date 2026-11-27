import SwiftUI
import WidgetKit
import ActivityKit

struct NWDownloadActivityWidget: Widget {
    private typealias State = NWDownloadActivityAttributes.ContentState

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: NWDownloadActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: context.state.symbol)
                        .font(.system(size: 16, weight: .medium))
                    Text(context.state.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 4)
                    percentage(context.state, size: 15)
                        .layoutPriority(1)
                }
                progressBar(context.state, height: 4)
                HStack(spacing: 4) {
                    Text(context.state.countLabel)
                    Spacer(minLength: 3)
                    Text(context.state.resultLabel)
                        .foregroundStyle(context.state.failed > 0 ? Color.orange : Color.white.opacity(0.72))
                }
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .foregroundStyle(.white.opacity(0.72))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .foregroundStyle(.white)
            .activityBackgroundTint(Color(white: 0.09))
            .activitySystemActionForegroundColor(.white)
            .widgetURL(URL(string: "nightwell://open/offline"))
        } dynamicIsland: { context in
            DynamicIsland {
                // The cutout splits the top into two narrow areas. Do not
                // put a brand name or another long label in either one.
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: context.state.symbol)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.white)
                        .accessibilityLabel(context.state.title)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    percentage(context.state, size: 15)
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    // Keep to one short text row plus a fixed-height bar.
                    // System owns outer insets and the expanded height.
                    VStack(spacing: 6) {
                        HStack(spacing: 5) {
                            Text(context.state.islandTitle)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.65)
                            Spacer(minLength: 2)
                            Text(context.state.compactCount)
                                .font(.system(size: 11, weight: .medium))
                                .monospacedDigit()
                                .lineLimit(1)
                                .minimumScaleFactor(0.60)
                                .layoutPriority(1)
                                .foregroundStyle(.white.opacity(0.72))
                        }
                        progressBar(context.state, height: 3)
                    }
                    .foregroundStyle(.white)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(context.state.title + ", " + context.state.countLabel + ", " + context.state.resultLabel)
                }
            } compactLeading: {
                Image(systemName: context.state.symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
            } compactTrailing: {
                percentage(context.state, size: 11)
                    .foregroundStyle(.white)
            } minimal: {
                // With music playing iOS may offer only a tiny detached
                // island. Avoid a 22pt fixed frame; inset the stroke so it
                // cannot be clipped by the system-provided circular bounds.
                ZStack {
                    Circle().strokeBorder(.white.opacity(0.22), lineWidth: 1.5)
                    Circle().inset(by: 1)
                        .trim(from: 0, to: CGFloat(context.state.fraction))
                        .stroke(.white, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Image(systemName: context.state.active ? "arrow.down" :
                          (context.state.failed > 0 ? "exclamationmark" : "checkmark"))
                        .font(.system(size: 9, weight: .semibold))
                }
                .frame(width: 16, height: 16)
                .foregroundStyle(.white)
                .accessibilityLabel("\(context.state.title), \(context.state.percent)%")
            }
            .widgetURL(URL(string: "nightwell://open/offline"))
            .keylineTint(.white)
        }
    }

    private func percentage(_ state: State, size: CGFloat) -> some View {
        Text(verbatim: "\(state.percent)%")
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .allowsTightening(true)
    }

    private func progressBar(_ state: State, height: CGFloat) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.19))
                Capsule().fill(state.failed > 0 && !state.active ? Color.orange : Color.white)
                    .frame(width: geometry.size.width * CGFloat(state.fraction))
            }
        }
        .frame(height: height)
        .accessibilityLabel("Прогресс")
        .accessibilityValue("\(state.percent)%")
    }
}
