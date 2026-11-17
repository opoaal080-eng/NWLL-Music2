
import UIKit
import WidgetKit

/// WidgetKit cannot run the audio player. Share a snapshot of the active track.
@MainActor final class NightwellWidgetBridge {
    static let shared = NightwellWidgetBridge()
    private var lastKey = ""
    private var coverTask: Task<Void, Never>?

    func update(track: Track?, playing: Bool, origin: URL) {
        let key = [origin.absoluteString, track?.id ?? "", track?.title ?? "",
                   track?.artist ?? "", playing ? "1" : "0"].joined(separator: "|")
        guard key != lastKey else { return }
        lastKey = key
        coverTask?.cancel()
        let snapshot = NWWidgetState(trackID: track?.id ?? "",
                                     title: track?.title ?? "Твой ритм",
                                     artist: track?.artist ?? "Nightwell Music",
                                     playing: playing && track != nil,
                                     coverID: nil, updated: Date())
        guard NWWidgetStorage.write(snapshot) else { return }
        WidgetCenter.shared.reloadTimelines(ofKind: "nightwell.nowplaying")
        guard let track, let url = CoverImagePipeline.coverURL(for: track, origin: origin) else { return }
        coverTask = Task { [weak self] in
            let image = await CoverImagePipeline.shared.image(for: url, maxPixel: 280)
            guard !Task.isCancelled, self?.lastKey == key,
                  let jpeg = image?.jpegData(compressionQuality: 0.75),
                  NWWidgetStorage.saveCover(jpeg) else { return }
            let current = NWWidgetStorage.read()
            guard current.trackID == track.id else { return }
            if NWWidgetStorage.write(NWWidgetState(trackID: current.trackID,
                title: current.title, artist: current.artist, playing: current.playing,
                coverID: track.id, updated: Date())) {
                WidgetCenter.shared.reloadTimelines(ofKind: "nightwell.nowplaying")
            }
        }
    }
}
