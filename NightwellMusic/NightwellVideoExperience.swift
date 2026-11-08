import SwiftUI
import WebKit

/// Lightweight Ken Burns artwork movement. The cover remains a native image;
/// no video generation, transcoding, network polling or server processing.
struct NightwellAnimatedCover: View {
    let track: Track?
    let origin: URL
    let side: CGFloat
    @AppStorage("nw-animated-album-artwork") private var enabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drifting = false

    var body: some View {
        ZStack {
            Cover(track: track, origin: origin, pixelWidth: 1024)
                .frame(width: side, height: side)
                .scaleEffect(enabled && !reduceMotion && drifting ? 1.095 : 1.015)
                .offset(x: enabled && !reduceMotion && drifting ? -8 : 5,
                        y: enabled && !reduceMotion && drifting ? 5 : -6)
                .animation(enabled && !reduceMotion ?
                           .easeInOut(duration: 8.5).repeatForever(autoreverses: true)
                           : .default, value: drifting)
            if enabled && !reduceMotion {
                LinearGradient(
                    colors: [.clear, Color.white.opacity(0.045), .clear],
                    startPoint: drifting ? .topLeading : .bottomLeading,
                    endPoint: drifting ? .bottomTrailing : .topTrailing
                )
                .animation(.easeInOut(duration: 11).repeatForever(autoreverses: true),
                           value: drifting)
                .allowsHitTesting(false)
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .onAppear { drifting = true }
        .onChange(of: track?.id) { _ in
            drifting = false
            DispatchQueue.main.async { drifting = true }
        }
        .accessibilityLabel(track.map { "Анимированная обложка: " + $0.title } ?? "Обложка")
    }
}

struct NightwellYouTubeClip: View {
    let track: Track
    let api: MusicAPI
    let server: URL

    @Environment(\.dismiss) private var dismiss
    @State private var videoID: String?
    @State private var videoTitle = ""
    @State private var videoChannel = ""
    @State private var pastedLink = ""
    @State private var loading = true
    @State private var notice = ""
    @State private var invalidLink = false

    private struct Match: Decodable {
        let video_id: String?
        let title: String?
        let channel: String?
        let available: Bool?
        let message: String?
    }

    private var searchURL: URL {
        var parts = URLComponents(string: "https://www.youtube.com/results")!
        parts.queryItems = [URLQueryItem(name: "search_query",
                                        value: track.artist + " " + track.title + " official music video")]
        return parts.url!
    }

    static func videoID(from text: String) -> String? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil {
            return raw
        }
        guard let url = URLComponents(string: raw),
              url.scheme == "https",
              let host = url.host?.lowercased() else { return nil }
        let allowed = ["youtube.com", "www.youtube.com", "m.youtube.com",
                       "youtube-nocookie.com", "www.youtube-nocookie.com",
                       "youtu.be", "www.youtu.be"]
        guard allowed.contains(host) else { return nil }
        let parts = url.path.split(separator: "/")
        let value: String?
        if host.hasSuffix("youtu.be") { value = parts.first.map(String.init) }
        else if parts.first == "watch" {
            value = url.queryItems?.first(where: { $0.name == "v" })?.value
        } else if ["shorts", "embed", "live"].contains(parts.first.map(String.init) ?? "") {
            value = parts.dropFirst().first.map(String.init)
        } else { value = nil }
        guard let value, value.range(of: #"^[A-Za-z0-9_-]{11}$"#,
                                     options: .regularExpression) != nil else { return nil }
        return value
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title).font(.headline).lineLimit(2)
                        Text(track.artist).font(.subheadline).foregroundStyle(.secondary)
                    }
                    if let videoID {
                        NightwellOfficialYouTubePlayer(videoID: videoID, baseURL: server)
                            .frame(maxWidth: .infinity)
                            .frame(height: 230)
                            .accessibilityLabel("Официальный проигрыватель YouTube")
                        if !videoTitle.isEmpty {
                            Text(videoTitle).font(.subheadline.bold())
                        }
                        if !videoChannel.isEmpty {
                            Text("Канал: " + videoChannel)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else if loading {
                        HStack { ProgressView(); Text("Проверяем наличие клипа…") }
                            .frame(maxWidth: .infinity, minHeight: 210)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            Image(systemName: "play.rectangle").font(.system(size: 32))
                            Text("Клип пока не выбран").font(.headline)
                            Text(notice.isEmpty
                                 ? "Найди подходящий клип на YouTube и вставь ссылку ниже."
                                 : notice)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(minHeight: 140)
                    }
                    Link(destination: searchURL) {
                        Label("Найти клип на YouTube", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity)
                            .padding(12)
                    }
                    .buttonStyle(.bordered)
                    HStack(spacing: 8) {
                        TextField("Вставь ссылку на YouTube", text: $pastedLink)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .textFieldStyle(.roundedBorder)
                        Button("Открыть") {
                            if let value = Self.videoID(from: pastedLink) {
                                videoID = value
                                videoTitle = ""
                                videoChannel = ""
                                invalidLink = false
                            } else {
                                invalidLink = true
                            }
                        }
                        .disabled(pastedLink.trimmingCharacters(in: .whitespaces).isEmpty)
                        .buttonStyle(.borderedProminent)
                    }
                    if invalidLink {
                        Text("Нужна действительная ссылка youtube.com или youtu.be.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Text("Клип открывается только по твоему нажатию, со стандартными кнопками YouTube. Музыка Nightwell при открытии останавливается, чтобы звуковые дорожки не накладывались.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .padding(18)
            }
            .navigationTitle("Клип YouTube")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task(id: track.id) {
            loading = true
            notice = ""
            videoID = nil
            defer { loading = false }
            do {
                let title = track.title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                let artist = track.artist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
                let match: Match = try await api.request(
                    "api/music-videos/clip?title=" + title + "&artist=" + artist, timeout: 8)
                guard !Task.isCancelled else { return }
                if let found = match.video_id, Self.videoID(from: found) != nil {
                    videoID = found
                    videoTitle = match.title ?? ""
                    videoChannel = match.channel ?? ""
                } else {
                    notice = match.message ?? "Автоматический поиск пока не настроен."
                }
            } catch {
                notice = "Автоматический поиск недоступен. Можно найти клип в YouTube и вставить ссылку."
            }
        }
    }
}

/// Only the official YouTube embed is rendered: never download, extract, hide
/// player controls or substitute a Nightwell audio stream for its soundtrack.
struct NightwellOfficialYouTubePlayer: UIViewRepresentable {
    let videoID: String
    let baseURL: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.allowsPictureInPictureMediaPlayback = false
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        web.navigationDelegate = context.coordinator
        return web
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateUIView(_ web: WKWebView, context: Context) {
        guard context.coordinator.loadedID != videoID else { return }
        context.coordinator.loadedID = videoID
        guard NightwellYouTubeClip.videoID(from: videoID) != nil else { return }
        let iframe = "https://www.youtube-nocookie.com/embed/" + videoID
            + "?autoplay=0&playsinline=1&controls=1&fs=1"
        let html = """
        <!doctype html><html><head><meta name="viewport"
        content="width=device-width, initial-scale=1, maximum-scale=1"></head>
        <body style="margin:0;background:black;overflow:hidden">
        <iframe src="\(iframe)" frameborder="0" allow="encrypted-media; fullscreen; picture-in-picture"
        allowfullscreen style="position:absolute;inset:0;width:100%;height:100%;border:0"></iframe>
        </body></html>
        """
        web.loadHTMLString(html, baseURL: baseURL)
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.stopLoading()
        web.loadHTMLString("", baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedID: String?
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated,
               let url = action.request.url {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
