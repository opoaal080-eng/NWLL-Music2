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
    // Publish a stored @Observable content value. The previous computed
    // property could be evaluated lazily for the expanded player while the
    // compact Dynamic Island kept an earlier no-artwork snapshot.
    private(set) var publishedContent: MusicContent?
    private(set) var contentUpdateSerial = 0
    private(set) var canNavigate = false
    // Publish transport state, clock and timestamp as one observable value.
    // System controls must never combine a new Pause with an old running clock.
    private(set) var playbackSnapshot: MediaPlaybackSnapshot?

    var content: (any MediaContentRepresentable)? { publishedContent }

    private func republishContent() {
        guard let track else {
            if publishedContent != nil {
                publishedContent = nil
                contentUpdateSerial &+= 1
            }
            return
        }
        let image: Artwork? = imageData.map { data in
            Artwork(id: track.id + "-" + String(artworkRevision)) { _ in
                try ArtworkRepresentation(data: data)
            }
        }
        // One single assignment triggers NowPlaying observation even when the
        // title and track identifier are unchanged and only the cover changes.
        publishedContent = MusicContent(
            id: track.id,
            songTitle: track.title,
            artistName: track.artist,
            albumName: track.album,
            type: .audio,
            duration: track.duration > 0 ? .finite(track.duration) : nil,
            artwork: image
        )
        contentUpdateSerial &+= 1
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
                queueCount: Int,
                initialArtwork: Data? = nil) {
        let trackChanged = track != newTrack
        if trackChanged {
            // Set metadata and cover together, so the lock screen cannot
            // snapshot the preceding track's artwork with the next song.
            track = newTrack
            imageData = newTrack == nil ? nil : initialArtwork
            artworkRevision &+= 1
            republishContent()
        }
        let newPlaying = newTrack != nil && playing
        let playbackChanged = isPlaying != newPlaying
        if playbackChanged { isPlaying = newPlaying }
        let seekPosition = position.isFinite ? max(0, position) : 0
        if newTrack == nil {
            elapsedTime = 0
            if playbackSnapshot != nil { playbackSnapshot = nil }
        } else if trackChanged || playbackChanged || playbackSnapshot == nil || abs(elapsedTime - seekPosition) >= 0.5 {
            elapsedTime = seekPosition
            snapshotDate = .now
            playbackSnapshot = MediaPlaybackSnapshot(
                state: newPlaying ? .playing() : .paused,
                elapsedTime: elapsedTime,
                timestamp: snapshotDate
            )
        }
        let newCanNavigate = queueCount > 1
        if canNavigate != newCanNavigate { canNavigate = newCanNavigate }
    }

    func updateArtwork(_ data: Data?) {
        imageData = data
        artworkRevision &+= 1
        // The tiny Dynamic Island view doesn't always re-evaluate a computed
        // content getter when a request handler's underlying bytes change.
        // Replace the published content explicitly for every new artwork ID.
        republishContent()
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

        let next = NightwellNowPlayingTrack(track)
        let trackChanged = next.id != lastTrackID
        let artworkChanged = lastArtworkObject !== artwork
        // Do not send a temporary content update for the previous track,
        // then a second content update for this track. That race could leave
        // the compact lock-screen card on the NW placeholder.
        if trackChanged {
            lastTrackID = next.id
            lastArtworkObject = artwork
            let data = artwork?
                .image(at: CGSize(width: 512, height: 512))?
                .jpegData(compressionQuality: 0.86)
            model.update(track: next, playing: playing, position: elapsed,
                         queueCount: queueCount, initialArtwork: data)
        } else {
            model.update(track: next, playing: playing, position: elapsed,
                         queueCount: queueCount, initialArtwork: model.imageData)
            if artworkChanged {
                lastArtworkObject = artwork
                let data = artwork?
                    .image(at: CGSize(width: 512, height: 512))?
                    .jpegData(compressionQuality: 0.86)
                model.updateArtwork(data)
            }
        }
        if session == nil {
            session = MediaSession(model)
        }

        // Publication must start when playback is requested, not only once
        // the stream has become audible. Otherwise a buffering track may
        // miss the home-screen/Dynamic Island handoff.
        playbackRequested = playbackIntent
        guard let session else { return }

        // A local media session is system-owned automatically when playback
        // becomes active. Apple explicitly advises against forcing
        // requestToBecomeSystemPrimary() for ordinary on-device playback.
        // It can return internalFailure even after iOS has promoted us.
        if session.isApplicationPrimary {
            // Clear stale errors after the system confirms the session.
            lastActivationError = ""
            return
        }
        guard playbackIntent,
              Date().timeIntervalSince(lastActivationAttempt) >= 6 else { return }
        lastActivationAttempt = .now
        activationTask?.cancel()
        activationTask = Task { @MainActor in
            do {
                try await session.requestToBecomeApplicationPrimary()
                if !Task.isCancelled && session.isApplicationPrimary {
                    self.lastActivationError = ""
                }
            } catch {
                if !Task.isCancelled {
                    // A delayed response can fail after the session has
                    // already become application-primary on its own.
                    self.lastActivationError = session.isApplicationPrimary
                        ? "" : String(describing: error)
                    if !self.lastActivationError.isEmpty {
                        NSLog("Nightwell NowPlaying app-primary: \(error)")
                    }
                }
            }
        }
    }
}
#endif
