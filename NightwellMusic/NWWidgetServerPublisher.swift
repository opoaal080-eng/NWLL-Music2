import Foundation
import UIKit
import WidgetKit

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
        let signature = [origin.absoluteString, account, id, title, artist,
                         playing ? "1" : "0"].joined(separator: "|")
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
                            "playing": playing && track != nil
                        ], timeout: 9)
                    guard !Task.isCancelled else { return }
                    self?.confirmedKey = signature
                    self?.retryAt = .distantPast
                    WidgetCenter.shared.reloadTimelines(ofKind: "nightwell.nowplaying")
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

        guard let track, let url = CoverImagePipeline.coverURL(for: track, origin: origin)
        else { return }
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
                    guard let image = await CoverImagePipeline.shared.image(for: url, maxPixel: 256),
                          let jpeg = image.jpegData(compressionQuality: 0.68),
                          jpeg.count <= 220_000 else {
                        throw URLError(.cannotDecodeContentData)
                    }
                    let _: OK = try await api.request("/api/widgets/cover", method: "POST",
                       body: ["track_id": String(track.id.prefix(100)),
                              "jpeg": jpeg.base64EncodedString()], timeout: 12)
                    guard !Task.isCancelled else { return }
                    self?.coverConfirmedKey = coverKey
                    self?.coverRetryAt = .distantPast
                    WidgetCenter.shared.reloadTimelines(ofKind: "nightwell.nowplaying")
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
