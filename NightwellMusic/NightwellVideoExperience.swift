import SwiftUI
import Foundation

/// Only the artwork moves in Nightwell's player. No local clips and no
/// YouTube video are used as a playback background.
struct NightwellAnimatedArtworkBackground: View {
    let track: Track?
    let origin: URL

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("nw-animated-album-artwork") private var animate = true
    @State private var floating = false

    var body: some View {
        GeometryReader { geometry in
            let side = max(geometry.size.width, geometry.size.height) * 1.28
            ZStack {
                Color.black
                Cover(track: track, origin: origin, pixelWidth: 1024)
                    .frame(width: side, height: side)
                    .scaleEffect(animate && !reduceMotion && floating ? 1.14 : 1.015)
                    .offset(
                        x: animate && !reduceMotion && floating ? -16 : 14,
                        y: animate && !reduceMotion && floating ? 14 : -17)
                    .animation(animate && !reduceMotion
                               ? .easeInOut(duration: 10).repeatForever(autoreverses: true)
                               : .none, value: floating)
                LinearGradient(stops: [
                    .init(color: .black.opacity(0.28), location: 0),
                    .init(color: .black.opacity(0.05), location: 0.33),
                    .init(color: .black.opacity(0.12), location: 0.48),
                    .init(color: .black.opacity(0.72), location: 0.83),
                    .init(color: .black.opacity(0.91), location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .id(track?.id)
        .onAppear { floating = true }
        .onChange(of: track?.id) { _ in
            floating = false
            DispatchQueue.main.async { floating = true }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
