
import SwiftUI
import WidgetKit

private struct NWEntry: TimelineEntry {
    let date: Date
    let snapshot: NWWidgetState
    let cover: Data?
}
private struct NWProvider: TimelineProvider {
    func placeholder(in context: Context) -> NWEntry {
        NWEntry(date: .now, snapshot: NWWidgetState(trackID: "preview",
            title: "Музыка этой ночи", artist: "Nightwell Music",
            playing: true, coverID: nil, updated: .now), cover: nil)
    }
    func getSnapshot(in context: Context, completion: @escaping (NWEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : current())
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<NWEntry>) -> Void) {
        // WidgetKit may delay refreshes, but request a reasonable fallback
        // when the app cannot actively notify the extension.
        completion(Timeline(entries: [current()], policy: .after(Date().addingTimeInterval(300))))
    }
    private func current() -> NWEntry {
        let data = NWWidgetStorage.read()
        return NWEntry(date: .now, snapshot: data, cover: NWWidgetStorage.cover(for: data))
    }
}
private let surface = Color(red: 0.055, green: 0.055, blue: 0.065)

private struct NWArtwork: View {
    let data: Data?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 15).fill(.white.opacity(0.11))
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Text("N").font(.system(size: 45, weight: .black, design: .rounded))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 15))
    }
}

private struct NWPlayerWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: NWEntry
    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                ZStack {
                    Circle().stroke(.white.opacity(0.5), lineWidth: 1.5)
                    Text("N").font(.system(size: 25, weight: .black, design: .rounded))
                }.padding(3)
            case .accessoryRectangular:
                HStack(spacing: 7) {
                    Image(systemName: entry.snapshot.playing ? "waveform" : "music.note")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.snapshot.trackID.isEmpty ? "Nightwell Music" : entry.snapshot.title)
                            .font(.caption.weight(.bold)).lineLimit(1)
                        Text(entry.snapshot.artist).font(.caption2).lineLimit(1)
                    }
                }
            case .systemMedium:
                HStack(spacing: 14) {
                    NWArtwork(data: entry.cover).frame(width: 115, height: 115)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("NIGHTWELL MUSIC")
                            .font(.system(size: 10, weight: .bold)).tracking(1.1)
                            .foregroundStyle(.white.opacity(0.55))
                        Spacer(minLength: 1)
                        Text(entry.snapshot.title).font(.system(size: 19, weight: .bold)).lineLimit(2)
                        Text(entry.snapshot.artist).font(.subheadline).lineLimit(1)
                            .foregroundStyle(.white.opacity(0.65))
                        Spacer(minLength: 1)
                        Image(systemName: entry.snapshot.trackID.isEmpty ? "music.note" :
                          (entry.snapshot.playing ? "waveform" : "pause.fill"))
                            .foregroundStyle(.white.opacity(0.7))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.padding(16)
            case .systemLarge:
                VStack(alignment: .leading, spacing: 11) {
                    Text("NIGHTWELL").font(.system(size: 15, weight: .black)).tracking(2)
                    GeometryReader { proxy in
                        NWArtwork(data: entry.cover)
                            .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                    Text(entry.snapshot.title).font(.title3.bold()).lineLimit(1)
                    Text(entry.snapshot.artist).font(.subheadline).lineLimit(1)
                        .foregroundStyle(.white.opacity(0.65))
                }.padding(18)
            default:
                VStack(alignment: .leading, spacing: 6) {
                    Text("N").font(.system(size: 18, weight: .black, design: .rounded))
                    Spacer(minLength: 0)
                    NWArtwork(data: entry.cover).frame(width: 58, height: 58)
                    Text(entry.snapshot.title).font(.system(size: 14, weight: .bold)).lineLimit(2)
                    Text(entry.snapshot.artist).font(.system(size: 11)).lineLimit(1)
                        .foregroundStyle(.white.opacity(0.65))
                }.padding(15)
            }
        }
        .foregroundStyle(.white)
        .containerBackground(for: .widget) { surface }
        .widgetURL(URL(string: "nightwell://open/player"))
    }
}

private struct NWShortcut: View {
    let label: String
    let symbol: String
    let destination: String
    var body: some View {
        Link(destination: URL(string: "nightwell://open/" + destination)!) {
            HStack(spacing: 7) {
                Image(systemName: symbol).frame(width: 16)
                Text(label).font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.system(size: 9))
            }
            .padding(10).background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
        }
        .foregroundStyle(.white)
    }
}
private struct NWQuickWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var body: some View {
        Group {
            if family == .systemSmall {
                VStack(alignment: .leading, spacing: 9) {
                    Text("N").font(.system(size: 38, weight: .black, design: .rounded))
                    Spacer()
                    Text("Твой ритм").font(.headline)
                    Text("Открыть Nightwell Music")
                        .font(.caption2).foregroundStyle(.white.opacity(0.6))
                }.padding(15).widgetURL(URL(string: "nightwell://open/home"))
            } else {
                VStack(alignment: .leading, spacing: 11) {
                    Text("NIGHTWELL").font(.system(size: 14, weight: .black)).tracking(1.5)
                    HStack(spacing: 8) {
                        VStack(spacing: 8) {
                            NWShortcut(label: "Избранное", symbol: "heart.fill", destination: "likes")
                            NWShortcut(label: "Поиск", symbol: "magnifyingglass", destination: "search")
                        }
                        VStack(spacing: 8) {
                            NWShortcut(label: "Твой ритм", symbol: "waveform", destination: "home")
                            NWShortcut(label: "Офлайн", symbol: "arrow.down.circle", destination: "offline")
                        }
                    }
                }.padding(15)
            }
        }
        .foregroundStyle(.white)
        .containerBackground(for: .widget) { surface }
    }
}
private struct NWNowPlaying: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "nightwell.nowplaying", provider: NWProvider()) { entry in
            NWPlayerWidgetView(entry: entry)
        }
        .configurationDisplayName("Сейчас играет")
        .description("Название, исполнитель и обложка текущего трека.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryCircular, .accessoryRectangular])
    }
}
private struct NWQuickAccess: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "nightwell.quickaccess", provider: NWProvider()) { _ in
            NWQuickWidgetView()
        }
        .configurationDisplayName("Быстрый доступ")
        .description("Поиск, избранное, офлайн и главный экран.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
@main struct NightwellWidgets: WidgetBundle {
    var body: some Widget {
        NWNowPlaying()
        NWQuickAccess()
    }
}
