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
    private var lastPlaying = false
    private var activationTask: Task<Void, Never>?

    private init() {}

    func update(track: NativeTrack?, playing: Bool, elapsed: Double,
                artwork: MPMediaItemArtwork?, queueCount: Int) {
        if session == nil, track != nil {
            session = MediaSession(model)
        }

        let next = track.map(NightwellNowPlayingTrack.init)
        let trackChanged = next?.id != lastTrackID
        let artworkChanged = lastArtworkObject !== artwork
        if trackChanged || artworkChanged {
            lastTrackID = next?.id
            lastArtworkObject = artwork
            // The legacy player already fetched the cover. Reuse it rather
            // than making a second request from a protected SoundCloud URL.
            let data = artwork?
                .image(at: CGSize(width: 512, height: 512))?
                .jpegData(compressionQuality: 0.86)
            model.updateArtwork(data)
        }

        model.update(track: next, playing: playing, position: elapsed,
                     queueCount: queueCount)

        // A system-primary Now Playing session must exist before the user
        // swipes Home, so iOS can own the Dynamic Island transition. Asking
        // only for application-primary does not guarantee system presentation.
        // Audio is already active by the time the transport becomes audible.
        if playing, !lastPlaying, let session {
            activationTask?.cancel()
            activationTask = Task { @MainActor in
                do {
                    if UIApplication.shared.applicationState == .active {
                        // Apple requires this call while the app is foreground.
                        try await session.requestToBecomeSystemPrimary()
                    } else {
                        // A background launch can only publish app-primary.
                        try await session.requestToBecomeApplicationPrimary()
                    }
                } catch {
                    NSLog("Nightwell NowPlaying: media session activation failed: \(error)")
                }
            }
        }
        lastPlaying = playing
    }
}
#endif
