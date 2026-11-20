#if canImport(NowPlaying)
import Foundation
import MediaPlayer
import NowPlaying
import Observation
import UIKit

// iOS 27's native media session replaces MPNowPlayingInfoCenter and
// MPRemoteCommandCenter on supported devices. Older OS releases keep the
// existing MediaPlayer implementation in NativePlayer.swift.
@available(iOS 27.0, *)
struct NightwellNowPlayingTrack: Equatable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let duration: Double

    init(_ track: NativeTrack) {
        id = track.id
        title = track.title
        artist = track.artist
        album = track.album
        duration = track.duration.isFinite && track.duration > 0 ? track.duration : 0
    }
}

@available(iOS 27.0, *)
@Observable
@MainActor
final class NightwellNowPlayingModel: MediaSessionRepresentable {
    let id = "fun.nightwell.music.local-session"
    private(set) var track: NightwellNowPlayingTrack?
    private(set) var isPlaying = false
    private(set) var elapsedTime: TimeInterval = 0
    private(set) var snapshotDate: Date = .now
    private(set) var imageData: Data?
    private(set) var artworkRevision = 0
    private(set) var canNavigate = false

    var content: (any MediaContentRepresentable)? {
        guard let track else { return nil }
        let image: Artwork? = imageData.map { data in
            Artwork(id: track.id + "-" + String(artworkRevision)) { _ in
                try ArtworkRepresentation(data: data)
            }
        }
        return MusicContent(
            id: track.id,
            songTitle: track.title,
            artistName: track.artist,
            albumName: track.album,
            type: .audio,
            duration: track.duration > 0 ? .finite(track.duration) : nil,
            artwork: image
        )
    }

    var playbackSnapshot: MediaPlaybackSnapshot? {
        guard track != nil else { return nil }
        return MediaPlaybackSnapshot(
            state: isPlaying ? .playing() : .paused,
            elapsedTime: elapsedTime,
            timestamp: snapshotDate
        )
    }

    var commands: [MediaCommand] {
        [
            .play { NativePlayer.shared.play() },
            .pause { NativePlayer.shared.pause() },
            .previous { NativePlayer.shared.step(-1) }.enabled(canNavigate),
            .next { NativePlayer.shared.step(1) }.enabled(canNavigate),
            .seekToPosition { position in NativePlayer.shared.seek(position) }
        ]
    }

    func update(track newTrack: NightwellNowPlayingTrack?,
                playing: Bool,
                position: Double,
                queueCount: Int) {
        if track != newTrack {
            track = newTrack
        }
        let newPlaying = newTrack != nil && playing
        let playbackChanged = isPlaying != newPlaying
        if playbackChanged { isPlaying = newPlaying }
        let seekPosition = position.isFinite ? max(0, position) : 0
        if abs(elapsedTime - seekPosition) >= 0.5 || playbackChanged {
            elapsedTime = seekPosition
            snapshotDate = .now
        }
        let newCanNavigate = queueCount > 1
        if canNavigate != newCanNavigate { canNavigate = newCanNavigate }
    }

    func updateArtwork(_ data: Data?) {
        imageData = data
        artworkRevision &+= 1
    }
}

@available(iOS 27.0, *)
@MainActor
final class NightwellNowPlayingBridge27 {
    static let shared = NightwellNowPlayingBridge27()

    private let model = NightwellNowPlayingModel()
    private var session: MediaSession<NightwellNowPlayingModel>?
    private var lastArtworkObject: MPMediaItemArtwork?
    private var lastTrackID: String?
    private var playbackRequested = false
    private var activationTask: Task<Void, Never>?
    private var lastActivationAttempt = Date.distantPast
    private var lastActivationError = ""
    private var wasForeground = true

    var diagnostics: String {
        guard let session else { return "NP27: сессии нет" }
        let app = session.isApplicationPrimary ? "да" : "нет"
        let system = session.isSystemPrimary ? "да" : "нет"
        let sound = model.isPlaying ? "да" : "нет"
        let request = playbackRequested ? "да" : "нет"
        let problem = lastActivationError.isEmpty ? "" : " · ошибка: \(lastActivationError)"
        return "NP27: приложение \(app) · система \(system) · звук \(sound) · запрос \(request)\(problem)"
    }

    private init() {}

    func update(track: NativeTrack?, playing: Bool, playbackIntent: Bool,
                elapsed: Double, artwork: MPMediaItemArtwork?, queueCount: Int) {
        guard let track else {
            // A stopped player must not leave a stale system media session.
            activationTask?.cancel()
            activationTask = nil
            session = nil
            playbackRequested = false
            lastTrackID = nil
            lastArtworkObject = nil
            lastActivationAttempt = .distantPast
            lastActivationError = ""
            model.update(track: nil, playing: false, position: 0, queueCount: 0)
            model.updateArtwork(nil)
            return
        }

        if session == nil {
            session = MediaSession(model)
        }

        let next = NightwellNowPlayingTrack(track)
        let trackChanged = next.id != lastTrackID
        let artworkChanged = lastArtworkObject !== artwork
        if trackChanged || artworkChanged {
            lastTrackID = next.id
            lastArtworkObject = artwork
            let data = artwork?
                .image(at: CGSize(width: 512, height: 512))?
                .jpegData(compressionQuality: 0.86)
            model.updateArtwork(data)
        }
        model.update(track: next, playing: playing, position: elapsed,
                     queueCount: queueCount)

        // Publication must start when playback is requested, not only once
        // the stream has become audible. Otherwise a buffering track may
        // miss the home-screen/Dynamic Island handoff.
        playbackRequested = playbackIntent
        guard playbackIntent, let session else { return }

        let foreground = UIApplication.shared.applicationState == .active
        if foreground && !wasForeground {
            lastActivationAttempt = .distantPast
        }
        wasForeground = foreground
        let needsPrimary = !session.isApplicationPrimary ||
            (foreground && !session.isSystemPrimary)
        guard needsPrimary,
              Date().timeIntervalSince(lastActivationAttempt) >= 6 else { return }
        lastActivationAttempt = .now
        activationTask?.cancel()
        activationTask = Task { @MainActor in
            do {
                // Apple's documented first step for a local Now Playing session.
                try await session.requestToBecomeApplicationPrimary()
                if !Task.isCancelled && UIApplication.shared.applicationState == .active &&
                    !session.isSystemPrimary {
                    try await session.requestToBecomeSystemPrimary()
                }
                if !Task.isCancelled { self.lastActivationError = "" }
            } catch {
                if !Task.isCancelled {
                    self.lastActivationError = String(describing: error)
                    NSLog("Nightwell NowPlaying activation: \(error)")
                }
            }
        }
    }
}
#endif
