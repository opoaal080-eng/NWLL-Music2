import SwiftUI
import AVFoundation
import SafariServices
import UniformTypeIdentifiers

/// A user-selected, authorized short video is stored on the iPhone, never
/// uploaded, downloaded from YouTube, or transcoded on the Nightwell server.
enum NightwellCanvasStore {
    private static let maxBytes = 60 * 1024 * 1024
    private static func destination(for trackID: String) throws -> URL {
        guard trackID.range(of: #"^[A-Za-z0-9_-]{1,100}$"#,
                            options: .regularExpression) != nil else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("NightwellCanvas", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(trackID + ".mp4")
    }

    static func video(for trackID: String) -> URL? {
        guard let path = try? destination(for: trackID),
              FileManager.default.fileExists(atPath: path.path) else { return nil }
        return path
    }

    static func save(_ imported: URL, trackID: String) throws {
        let granted = imported.startAccessingSecurityScopedResource()
        defer { if granted { imported.stopAccessingSecurityScopedResource() } }
        let source = try imported.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard source.isRegularFile == true,
              let bytes = source.fileSize, bytes > 0 && bytes <= maxBytes else {
            throw NSError(domain: "NightwellCanvas", code: 413, userInfo: [
                NSLocalizedDescriptionKey: "Выбери MP4 или MOV не больше 60 МБ."
            ])
        }
        let output = try destination(for: trackID)
        let temporary = output.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString + ".tmp")
        do {
            try FileManager.default.copyItem(at: imported, to: temporary)
            if FileManager.default.fileExists(atPath: output.path) {
                _ = try FileManager.default.replaceItemAt(output, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: output)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    static func delete(trackID: String) {
        if let path = try? destination(for: trackID) {
            try? FileManager.default.removeItem(at: path)
        }
    }
}

final class NightwellLoopVideoView: UIView {
    private var videoLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    private let queue = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var loadedURL: URL?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        videoLayer.videoGravity = .resizeAspectFill
        videoLayer.player = queue
        queue.isMuted = true
        queue.actionAtItemEnd = .none
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    func configure(url: URL, active: Bool) {
        if loadedURL != url {
            queue.pause()
            looper = nil
            queue.removeAllItems()
            loadedURL = url
            looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: url))
        }
        active ? queue.play() : queue.pause()
    }
    func stop() {
        queue.pause()
        looper = nil
        queue.removeAllItems()
    }
    deinit { queue.pause() }
}

struct NightwellCanvasVideo: UIViewRepresentable {
    let url: URL
    let active: Bool
    func makeUIView(context: Context) -> NightwellLoopVideoView {
        let view = NightwellLoopVideoView(frame: .zero)
        view.configure(url: url, active: active)
        return view
    }
    func updateUIView(_ view: NightwellLoopVideoView, context: Context) {
        view.configure(url: url, active: active)
    }
    static func dismantleUIView(_ view: NightwellLoopVideoView, coordinator: ()) {
        view.stop()
    }
}

/// Spotify Canvas-like presentation: one edge-to-edge video or gently moving
/// album artwork. The Nightwell controls remain visible above it.
struct NightwellCanvasBackground: View {
    let track: Track?
    let origin: URL
    let revision: Int
    @AppStorage("nw-animated-album-artwork") private var animated = true
    @Environment(\.scenePhase) private var scene
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drift = false

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let id = track?.id, let video = NightwellCanvasStore.video(for: id) {
                    NightwellCanvasVideo(url: video, active: scene == .active && !reduceMotion)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                } else {
                    Cover(track: track, origin: origin, pixelWidth: 1024)
                        .frame(width: geo.size.width * 1.25, height: geo.size.height * 1.25)
                        .scaleEffect(animated && !reduceMotion && drift ? 1.12 : 1.02)
                        .offset(x: animated && !reduceMotion && drift ? -18 : 12,
                                y: animated && !reduceMotion && drift ? 12 : -17)
                        .animation(animated && !reduceMotion ?
                            .easeInOut(duration: 12).repeatForever(autoreverses: true)
                            : nil, value: drift)
                }
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.38), location: 0),
                    .init(color: .black.opacity(0.08), location: 0.29),
                    .init(color: .black.opacity(0.18), location: 0.52),
                    .init(color: .black.opacity(0.75), location: 0.83),
                    .init(color: .black.opacity(0.92), location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .id((track?.id ?? "none") + "-" + String(revision))
        .onAppear { drift = true }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct NightwellSafariURL: Identifiable {
    let id = UUID()
    let value: URL
}

/// YouTube clips remain in the official player. We don't cut their video,
/// silence their audio, obscure player controls, or loop them behind Nightwell.
struct NightwellYouTubeClip: View {
    let track: Track
    @Environment(\.dismiss) private var dismiss
    @State private var userURL = ""
    @State private var selected: NightwellSafariURL?
    @State private var error = ""

    private var searchURL: URL {
        var components = URLComponents(string: "https://www.youtube.com/results")!
        components.queryItems = [URLQueryItem(name: "search_query",
            value: track.artist + " " + track.title + " official music video")]
        return components.url!
    }

    static func videoID(from text: String) -> String? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let idRegex = #"^[A-Za-z0-9_-]{11}$"#
        if clean.range(of: idRegex, options: .regularExpression) != nil { return clean }
        guard let u = URLComponents(string: clean), u.scheme == "https",
              let host = u.host?.lowercased(),
              ["youtube.com","www.youtube.com","m.youtube.com","youtu.be",
               "www.youtu.be","youtube-nocookie.com","www.youtube-nocookie.com"]
                .contains(host) else { return nil }
        let parts = u.path.split(separator: "/").map(String.init)
        let value: String?
        if host.contains("youtu.be") { value = parts.first }
        else if parts.first == "watch" {
            value = u.queryItems?.first(where: { $0.name == "v" })?.value
        } else if ["shorts","embed","live"].contains(parts.first ?? "") {
            value = parts.count > 1 ? parts[1] : nil
        } else { value = nil }
        guard let value, value.range(of: idRegex, options: .regularExpression) != nil
        else { return nil }
        return value
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                Text(track.title).font(.title3.bold())
                Text(track.artist).foregroundStyle(.secondary)
                Text("Найди официальный клип и открой его в YouTube. Видео не будет заменять звук Nightwell и не нагружает музыкальный сервер.")
                    .font(.subheadline).foregroundStyle(.secondary)
                Link(destination: searchURL) {
                    Label("Найти клип на YouTube", systemImage: "play.rectangle")
                        .frame(maxWidth: .infinity, minHeight: 54)
                }.buttonStyle(.borderedProminent)
                HStack {
                    TextField("Ссылка на видео", text: $userURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .textFieldStyle(.roundedBorder)
                    Button("Открыть") {
                        guard let id = Self.videoID(from: userURL),
                              let url = URL(string: "https://www.youtube.com/watch?v=" + id) else {
                            error = "Вставь ссылку youtube.com или youtu.be."
                            return
                        }
                        error = ""
                        selected = NightwellSafariURL(value: url)
                    }.buttonStyle(.bordered)
                }
                if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.orange) }
                Spacer()
            }
            .padding(20)
            .navigationTitle("Клип YouTube")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) {
                Button("Закрыть") { dismiss() }
            }}
            .sheet(item: $selected) { item in
                NightwellSafariVideo(url: item.value)
                    .ignoresSafeArea()
            }
        }
        .preferredColorScheme(.dark)
    }
}

struct NightwellSafariVideo: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
