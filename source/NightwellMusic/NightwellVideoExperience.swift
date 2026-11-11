import SwiftUI
import Foundation
import WebKit

/// Only the artwork moves in Nightwell's player. No local clips and no
/// YouTube video are used as a playback background.
struct NightwellAnimatedCover: View {
    let track: Track?
    let origin: URL
    let side: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("nw-animated-album-artwork") private var animated = true
    @State private var drifting = false

    private var motionEnabled: Bool {
        animated && !reduceMotion && scenePhase == .active
    }

    var body: some View {
        Cover(track: track, origin: origin, pixelWidth: 1024)
            .frame(width: side, height: side)
            // Full-screen-only motion: slow zoom, diagonal drift and a subtle
            // tilt. No animation is applied to the separate classic artwork.
            .scaleEffect(motionEnabled ? (drifting ? 1.085 : 1.035) : 1.008)
            .rotationEffect(.degrees(motionEnabled ? (drifting ? 0.45 : -0.45) : 0))
            .offset(x: motionEnabled ? (drifting ? -9 : 9) : 0,
                    y: motionEnabled ? (drifting ? 8 : -8) : 0)
            .animation(.easeOut(duration: 0.3), value: motionEnabled)
            .frame(width: side, height: side)
            // The image is taller than the display and cropped at the
            // screen boundary. Its original top/bottom lie just offscreen,
            // with only a soft vertical fade visible on the device.
            .mask {
                LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .white.opacity(0.10), location: 0.06),
                    .init(color: .white.opacity(0.42), location: 0.16),
                    .init(color: .white.opacity(0.88), location: 0.27),
                    .init(color: .white, location: 0.36),
                    .init(color: .white, location: 0.64),
                    .init(color: .white.opacity(0.88), location: 0.73),
                    .init(color: .white.opacity(0.42), location: 0.84),
                    .init(color: .white.opacity(0.10), location: 0.94),
                    .init(color: .clear, location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }
            .id(track?.id)
            .task(id: "\(track?.id ?? "")|\(motionEnabled)") {
                drifting = false
                guard motionEnabled else { return }
                do { try await Task.sleep(nanoseconds: 65_000_000) }
                catch { return }
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 8.5).repeatForever(autoreverses: true)) {
                    drifting = true
                }
            }
            .accessibilityLabel(track?.title ?? "Обложка трека")
    }
}

/// Validates links returned by the Nightwell server or already attached to
/// track metadata. Arbitrary search pages and unsupported hosts never appear
/// as a "Клип" action.
enum NightwellYouTubeLink {
    static func videoID(from raw: String?) -> String? {
        guard let raw else { return nil }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let matcher = #"^[A-Za-z0-9_-]{11}$"#
        if text.range(of: matcher, options: .regularExpression) != nil {
            return text
        }
        guard let url = URLComponents(string: text), url.scheme == "https",
              let host = url.host?.lowercased(), [
                "youtube.com", "www.youtube.com", "m.youtube.com",
                "youtu.be", "www.youtu.be", "youtube-nocookie.com",
                "www.youtube-nocookie.com"
              ].contains(host) else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        let id: String?
        if host == "youtu.be" || host == "www.youtu.be" {
            id = parts.first
        } else if parts.first == "watch" {
            id = url.queryItems?.first(where: { $0.name == "v" })?.value
        } else if ["shorts", "embed", "live"].contains(parts.first ?? "") {
            id = parts.count > 1 ? parts[1] : nil
        } else {
            id = nil
        }
        guard let id, id.range(of: matcher, options: .regularExpression) != nil else { return nil }
        return id
    }

    static func videoURL(from raw: String?) -> URL? {
        guard let id = videoID(from: raw) else { return nil }
        return URL(string: "https://www.youtube.com/watch?v=" + id)
    }
}

struct NightwellClipLookupResponse: Decodable {
    var available: Bool?
    var video_id: String?
    var title: String?
    var channel: String?
    var message: String?
}

/// Found clips are public YouTube IDs, so keeping the verified result on disk
/// does not retain any audio or video. Transient API failures never become
/// long-lived "no clip" results.
@MainActor
final class NightwellClipAvailabilityCache {
    static let shared = NightwellClipAvailabilityCache()
    private struct Entry {
        let url: URL?
        let validUntil: Date
    }
    private struct StoredClip: Codable {
        let videoID: String
        let validUntil: Date
    }
    private enum Outcome {
        case found(URL)
        case absent
        case unavailable
    }
    private static let storageKey = "nightwell.verified-youtube-clips.v1"
    private var entries: [String: Entry] = [:]
    private var pending: [String: Task<Outcome, Never>] = [:]
    private lazy var verified: [String: StoredClip] = {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let saved = try? JSONDecoder().decode([String: StoredClip].self, from: data)
        else { return [:] }
        return saved.filter {
            $0.value.validUntil > Date() &&
            NightwellYouTubeLink.videoID(from: $0.value.videoID) != nil
        }
    }()

    private func saveVerified() {
        let now = Date()
        verified = verified.filter { $0.value.validUntil > now }
        if verified.count > 500 {
            let newest = verified.sorted { $0.value.validUntil > $1.value.validUntil }
            verified = Dictionary(uniqueKeysWithValues: newest.prefix(500).map { ($0.key, $0.value) })
        }
        guard let data = try? JSONEncoder().encode(verified) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }

    func lookup(track: Track, api: MusicAPI, origin: URL, accountID: String?,
                forceRefresh: Bool = false) async -> URL? {
        if let direct = NightwellYouTubeLink.videoURL(from: track.source_url) {
            return direct
        }
        // The video is independent of the account; don't lose it on sign-out.
        let key = origin.absoluteString + "|" +
            track.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() + "|" +
            track.artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let now = Date()
        if let saved = verified[key], saved.validUntil > now,
           let url = NightwellYouTubeLink.videoURL(from: saved.videoID) {
            return url
        }
        if !forceRefresh, let entry = entries[key], entry.validUntil > now {
            return entry.url
        }
        if let task = pending[key] {
            if case let .found(url) = await task.value { return url }
            return nil
        }
        var query = URLComponents()
        query.path = "/api/music-videos/clip"
        query.queryItems = [
            URLQueryItem(name: "title", value: track.title),
            URLQueryItem(name: "artist", value: track.artist)
        ]
        guard let path = query.string else { return nil }
        let task = Task<Outcome, Never> {
            do {
                let response: NightwellClipLookupResponse = try await api.request(path, timeout: 8)
                if response.available == true,
                   let url = NightwellYouTubeLink.videoURL(from: response.video_id) {
                    return .found(url)
                }
                // Quota exhaustion, missing API key and temporary server
                // failures must not hide a known clip for 15 minutes.
                return response.message == nil ? .absent : .unavailable
            } catch {
                return .unavailable
            }
        }
        pending[key] = task
        let outcome = await task.value
        pending[key] = nil
        switch outcome {
        case let .found(url):
            let expiry = Date().addingTimeInterval(7 * 24 * 3600)
            entries[key] = Entry(url: url, validUntil: expiry)
            if let id = NightwellYouTubeLink.videoID(from: url.absoluteString) {
                verified[key] = StoredClip(videoID: id, validUntil: expiry)
                saveVerified()
            }
            return url
        case .absent:
            entries[key] = Entry(url: nil, validUntil: Date().addingTimeInterval(120))
            return nil
        case .unavailable:
            // No negative cache: allow a new attempt when connectivity returns.
            entries.removeValue(forKey: key)
            return nil
        }
    }
}

struct NightwellClipScreen: View {
    let clipURL: URL
    let title: String
    let origin: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                if let videoID = NightwellYouTubeLink.videoID(from: clipURL.absoluteString) {
                    NightwellYouTubeEmbed(videoID: videoID, origin: origin)
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .background(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                Text(title).font(.headline).lineLimit(2)
                Text("Видео воспроизводится во встроенном плеере YouTube с оригинальным звуком.")
                    .font(.footnote).foregroundStyle(.secondary)
                Link("Открыть в YouTube", destination: clipURL)
                    .font(.subheadline)
                Spacer()
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Клип")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }
}

/// Official YouTube iframe playback with original audio and untouched controls.
/// Loading a local HTML document with an HTTPS base URL identifies the host
/// application to YouTube so embeds do not fail with error 153.
struct NightwellYouTubeEmbed: UIViewRepresentable {
    let videoID: String
    let origin: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        guard NightwellYouTubeLink.videoID(from: videoID) == videoID else { return }
        let baseURL = (origin.scheme == "https") ? origin : URL(string: "https://music.nightwell.fun")!
        guard context.coordinator.loadedVideoID != videoID else { return }
        context.coordinator.loadedVideoID = videoID
        let html = """
        <!doctype html>
        <html lang="ru"><head>
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta name="referrer" content="strict-origin-when-cross-origin">
        <style>
        html,body {margin:0;padding:0;background:#000;width:100%;height:100%;overflow:hidden}
        iframe {position:absolute;top:0;left:0;width:100%;height:100%;border:0}
        </style>
        </head><body>
        <iframe src="https://www.youtube-nocookie.com/embed/\(videoID)?autoplay=0&amp;playsinline=1&amp;controls=1"
          title="YouTube video player"
          allow="accelerometer; autoplay; encrypted-media; gyroscope; picture-in-picture; fullscreen"
          referrerpolicy="strict-origin-when-cross-origin"
          allowfullscreen></iframe>
        </body></html>
        """
        web.loadHTMLString(html, baseURL: baseURL)
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.stopLoading()
        web.loadHTMLString("", baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var loadedVideoID: String?

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url,
               url.scheme == "https" {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction,
                     windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url, url.scheme == "https" {
                UIApplication.shared.open(url)
            }
            return nil
        }
    }
}
