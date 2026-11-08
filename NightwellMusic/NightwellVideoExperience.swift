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
    @AppStorage("nw-animated-album-artwork") private var animated = true
    @State private var drifting = false

    var body: some View {
        Cover(track: track, origin: origin, pixelWidth: 1024)
            .frame(width: side, height: side)
            // Restrict movement to a few pixels, rather than enlarging the
            // artwork over the entire display.
            .scaleEffect(animated && !reduceMotion && drifting ? 1.055 : 1.008)
            .offset(x: animated && !reduceMotion && drifting ? -5 : 5,
                    y: animated && !reduceMotion && drifting ? 5 : -5)
            .animation(animated && !reduceMotion
                       ? .easeInOut(duration: 9).repeatForever(autoreverses: true)
                       : .none, value: drifting)
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
            .onAppear { drifting = true }
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
}

/// Preload clip availability on track selection, never when opening the menu.
/// Positive and negative results remain cached even across player presentations.
@MainActor
final class NightwellClipAvailabilityCache {
    static let shared = NightwellClipAvailabilityCache()
    private struct Entry {
        let url: URL?
        let validUntil: Date
    }
    private var entries: [String: Entry] = [:]
    private var pending: [String: Task<URL?, Never>] = [:]

    func lookup(track: Track, api: MusicAPI, origin: URL, accountID: String?) async -> URL? {
        if let direct = NightwellYouTubeLink.videoURL(from: track.source_url) {
            return direct
        }
        let key = origin.absoluteString + "|" + (accountID ?? "guest")
            + "|" + track.title.lowercased() + "|" + track.artist.lowercased()
        if let entry = entries[key], entry.validUntil > Date() {
            return entry.url
        }
        if let task = pending[key] {
            return await task.value
        }
        var query = URLComponents()
        query.path = "/api/music-videos/clip"
        query.queryItems = [
            URLQueryItem(name: "title", value: track.title),
            URLQueryItem(name: "artist", value: track.artist)
        ]
        guard let path = query.string else { return nil }
        // URLSession requests suspend; they do not block sheet presentation.
        let task = Task<URL?, Never> {
            do {
                let response: NightwellClipLookupResponse = try await api.request(path, timeout: 6)
                guard response.available == true else { return nil }
                return NightwellYouTubeLink.videoURL(from: response.video_id)
            } catch {
                return nil
            }
        }
        pending[key] = task
        let result = await task.value
        pending[key] = nil
        entries[key] = Entry(url: result,
                             validUntil: Date().addingTimeInterval(result == nil ? 900 : 21600))
        if entries.count > 300 {
            entries = entries.filter { $0.value.validUntil > Date() }
            if entries.count > 300 { entries.removeAll() }
        }
        return result
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
