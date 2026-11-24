import UIKit
import WidgetKit

/// Copies a small now-playing snapshot to the signed App Group. Widgets have
/// no authority to connect to the live audio process or to read the login.
@MainActor final class NightwellWidgetBridge {
    static let shared = NightwellWidgetBridge()
    private var lastWrittenKey = ""
    private var failedAt = Date.distantPast
    private var coverTask: Task<Void, Never>?

    func update(track: Track?, playing: Bool, origin: URL, force: Bool = false) {
        let key = [origin.absoluteString, track?.id ?? "", track?.title ?? "",
                   track?.artist ?? "", playing ? "1" : "0"].joined(separator: "|")
        guard force || key != lastWrittenKey else { return }
        if !NWWidgetStorage.isAvailable {
            // A missing entitlement is a signing/provisioning issue, not a
            // network problem. Retry after foregrounding or changing tracks.
            if Date().timeIntervalSince(failedAt) > 20 {
                failedAt = .now
                NSLog("Nightwell widgets: App Group unavailable. Sign app and widget extension with group.fun.nightwell.music in both provisioning profiles.")
            }
            return
        }

        // Don't throw away an already downloaded cover when merely pausing.
        let previous = NWWidgetStorage.read()
        let sameCover = track != nil && previous.trackID == track?.id &&
                        previous.coverID == track?.id
        let next = NWWidgetState(
            trackID: track?.id ?? "",
            title: track?.title ?? "Твой ритм",
            artist: track?.artist ?? "Nightwell Music",
            playing: playing && track != nil,
            coverID: sameCover ? track?.id : nil,
            updated: .now
        )
        guard NWWidgetStorage.write(next) else {
            if Date().timeIntervalSince(failedAt) > 20 {
                failedAt = .now
                NSLog("Nightwell widgets: failed to persist shared state; will retry.")
            }
            return
        }
        lastWrittenKey = key // Only mark success after a real shared-file write.
        NWWidgetConfiguration.reloadNowPlaying()

        coverTask?.cancel()
        guard !sameCover, let track else { return }
        coverTask = Task { [weak self] in
            // WidgetKit and the Now Playing media session use different
            // transports. Both must load downloaded art without reaching
            // the remote cover CDN when the phone has no network.
            var image: UIImage?
            if track._offline == true {
                let owner = track._offline_account ?? "device"
                image = await Task.detached(priority: .utility) {
                    OfflineStore.cover(origin: origin, account: owner, id: track.id)
                }.value
            }
            if image == nil,
               let url = CoverImagePipeline.coverURL(for: track, origin: origin) {
                image = await CoverImagePipeline.shared.image(for: url, maxPixel: 280)
                if track._offline == true, let image {
                    let owner = track._offline_account ?? "device"
                    Task.detached(priority: .utility) {
                        try? OfflineStore.saveCover(image, origin: origin,
                                                    account: owner, id: track.id)
                    }
                }
            }
            guard !Task.isCancelled,
                  self?.lastWrittenKey == key,
                  let jpeg = image?.jpegData(compressionQuality: 0.78),
                  NWWidgetStorage.saveCover(jpeg) else { return }

            let current = NWWidgetStorage.read()
            guard current.trackID == track.id else { return }
            let result = NWWidgetState(
                trackID: current.trackID, title: current.title,
                artist: current.artist, playing: current.playing,
                coverID: track.id, updated: .now
            )
            if NWWidgetStorage.write(result) {
                NWWidgetConfiguration.reloadNowPlaying()
            }
        }
    }
}
