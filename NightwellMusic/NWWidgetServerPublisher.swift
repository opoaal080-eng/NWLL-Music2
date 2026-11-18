import Foundation
import UIKit
import WidgetKit
import MediaPlayer

/// Mirror only non-sensitive playback metadata to the authenticated Nightwell
/// server. Updates occur when track/play state changes, not every audio tick.
/// The WidgetKit extension retrieves it independently using its paired token.
@MainActor final class NWWidgetServerPublisher {
    static let shared = NWWidgetServerPublisher()
    private var confirmedKey = ""
    private var attemptedKey = ""
    private var sendingKey: String?
    private var retryAt = Date.distantPast
    private var stateTask: Task<Void, Never>?
    private var coverConfirmedKey = ""
    private var coverSendingKey: String?
    private var coverRetryAt = Date.distantPast
    private var coverTask: Task<Void, Never>?

    private var selectedTheme: String {
        UserDefaults.standard.string(forKey: NightwellAppearance.storageKey) == NightwellAppearance.vice.rawValue
            ? NightwellAppearance.vice.rawValue : NightwellAppearance.standard.rawValue
    }

    /// The system now-playing center can already contain artwork even when the
    /// queue's Track has no cover_url. Validate its title to avoid a stale cover.
    private func artworkFromNowPlaying(for track: Track) -> UIImage? {
        guard let info = MPNowPlayingInfoCenter.default().nowPlayingInfo,
              let systemTitle = info[MPMediaItemPropertyTitle] as? String,
              systemTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(track.title.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame,
              let art = info[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork
        else { return nil }
        return art.image(at: CGSize(width: 300, height: 300))
    }

    private func compactJPEG(from image: UIImage) -> Data? {
        let target: CGFloat = 280
        let longestEdge = max(max(image.size.width, image.size.height), CGFloat(1))
        let ratio = min(CGFloat(1), target / longestEdge)
        let canvas = CGSize(width: max(CGFloat(1), image.size.width * ratio),
                            height: max(CGFloat(1), image.size.height * ratio))
        let rendered = UIGraphicsImageRenderer(size: canvas).image { _ in
            image.draw(in: CGRect(origin: .zero, size: canvas))
        }
        for quality in [0.76, 0.58, 0.38] {
            if let data = rendered.jpegData(compressionQuality: quality),
               data.count >= 100, data.count <= 220_000 { return data }
        }
        return nil
    }

    func publishForPairing(track: Track?, playing: Bool, account: String?, api: MusicAPI, origin: URL) async {
        retryAt = .distantPast
        coverRetryAt = .distantPast
        update(track: track, playing: playing, account: account, api: api, origin: origin, force: true)
        if let stateTask { await stateTask.value }
    }

    func hasPublished(track: Track, account: String?, origin: URL) -> Bool {
        guard let account else { return false }
        return confirmedKey.hasPrefix([origin.absoluteString, account, track.id, track.title, track.artist].joined(separator: "|") + "|")
    }

    func update(track: Track?, playing: Bool, account: String?, api: MusicAPI, origin: URL,
                force: Bool = false) {
        guard let account, !account.isEmpty else {
            stateTask?.cancel()
            coverTask?.cancel()
            sendingKey = nil
            coverSendingKey = nil
            confirmedKey = ""
            attemptedKey = ""
            coverConfirmedKey = ""
            coverRetryAt = .distantPast
            retryAt = .distantPast
            return
        }
        let id = track?.id ?? ""
        let title = track?.title ?? ""
        let artist = track?.artist ?? ""
        let theme = selectedTheme
        let signature = [origin.absoluteString, account, id, title, artist,
                         playing ? "1" : "0", theme].joined(separator: "|")
        if attemptedKey != signature {
            attemptedKey = signature
            retryAt = .distantPast
        }

        if (force || signature != confirmedKey), sendingKey != signature,
           Date() >= retryAt {
            stateTask?.cancel()
            sendingKey = signature
            stateTask = Task { [weak self] in
                do {
                    let _: OK = try await api.request("/api/widgets/state",
                        method: "POST", body: [
                            "track_id": String(id.prefix(100)),
                            "title": String(title.prefix(180)),
                            "artist": String(artist.prefix(180)),
                            "playing": playing && track != nil,
                            "theme": theme
                        ], timeout: 9)
                    guard !Task.isCancelled else { return }
                    self?.confirmedKey = signature
                    self?.retryAt = .distantPast
                    NWWidgetConfiguration.reload()
                } catch {
                    if !Task.isCancelled {
                        // Missing server module: retry infrequently, while new
                        // track changes may still trigger a fresh attempt.
                        if let failure = error as? RequestRetry.HTTPFailure,
                           failure.status == 404 {
                            self?.retryAt = Date().addingTimeInterval(90)
                        } else {
                            self?.retryAt = Date().addingTimeInterval(20)
                        }
                    }
                }
                if self?.sendingKey == signature { self?.sendingKey = nil }
            }
        }

        guard let track else { return }
        let coverKey = origin.absoluteString + "|" + account + "|" + id
        if coverKey != coverConfirmedKey, coverSendingKey != coverKey, Date() >= coverRetryAt {
            coverTask?.cancel()
            coverSendingKey = coverKey
            coverTask = Task { [weak self] in
                // Server must see the track ID before the artwork request.
                if let active = self?.stateTask { await active.value }
                guard !Task.isCancelled, self?.confirmedKey == signature else {
                    if self?.coverSendingKey == coverKey { self?.coverSendingKey = nil }
                    return
                }
                do {
                    var image: UIImage? = self?.artworkFromNowPlaying(for: track)
                    if image == nil, let url = CoverImagePipeline.coverURL(for: track, origin: origin) {
                        image = await CoverImagePipeline.shared.image(
                            for: url, maxPixel: 280, retryFailure: true)
                    }
                    // Older imports and local queue entries often have no cover_url.
                    // Keep the server's cover endpoint as a safe last resort.
                    if image == nil, !track.id.isEmpty,
                       let encoded = track.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                       let fallback = URL(string: "/api/covers/" + encoded, relativeTo: origin)?.absoluteURL {
                        image = await CoverImagePipeline.shared.image(
                            for: fallback, maxPixel: 280, retryFailure: true)
                    }
                    // MPNowPlayingInfoCenter may have been updated while the
                    // network requests above were running.
                    if image == nil { image = self?.artworkFromNowPlaying(for: track) }
                    guard let image, let jpeg = self?.compactJPEG(from: image) else {
                        throw URLError(.cannotDecodeContentData)
                    }
                    let _: OK = try await api.request("/api/widgets/cover", method: "POST",
                       body: ["track_id": String(track.id.prefix(100)),
                              "jpeg": jpeg.base64EncodedString()], timeout: 12)
                    guard !Task.isCancelled else { return }
                    self?.coverConfirmedKey = coverKey
                    self?.coverRetryAt = .distantPast
                    NWWidgetConfiguration.reload()
                } catch {
                    if !Task.isCancelled {
                        self?.coverRetryAt = Date().addingTimeInterval(40)
                    }
                }
                if self?.coverSendingKey == coverKey { self?.coverSendingKey = nil }
            }
        }
    }
}
