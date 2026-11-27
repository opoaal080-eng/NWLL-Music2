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

    private(set) var content: (any MediaContentRepresentable)?

    private func republishContent() {
        guard let track else {
            if publishedContent != nil {
                publishedContent = nil
                content = nil
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
        // A distinct content identity on artwork arrival invalidates the
        // system's no-artwork snapshot. The media session and clock stay intact.
        let updated = MusicContent(
            id: track.id + "-art-" + String(artworkRevision),
            songTitle: track.title,
            artistName: track.artist,
            albumName: track.album,
            type: .audio,
            duration: track.duration > 0 ? .finite(track.duration) : nil,
            artwork: image
        )
        publishedContent = updated
        content = updated
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
    private var lastArtworkObject: UIImage?
    private var artworkTask: Task<Void, Never>?
    private var artworkGeneration = UUID()
    private var lastTrackID: String?
    private var artworkRetryAt = Date.distantPast
    private var artworkFailures = 0
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
        let cover = model.imageData.map { "\($0.count) Б" } ?? (artworkTask == nil ? "нет" : "кодирование")
        return "NP27: приложение \(app) · система \(system) · звук \(sound) · запрос \(request) · обложка \(cover)\(problem)"
    }

    private init() {}

    func update(track: NativeTrack?, playing: Bool, playbackIntent: Bool,
                elapsed: Double, artwork: UIImage?, queueCount: Int) {
        guard let track else {
            // A stopped player must not leave a stale system media session.
            activationTask?.cancel()
            activationTask = nil
            session = nil
            playbackRequested = false
            lastTrackID = nil
            lastArtworkObject = nil
            artworkRetryAt = .distantPast; artworkFailures = 0
            artworkTask?.cancel(); artworkTask = nil; artworkGeneration = UUID()
            lastActivationAttempt = .distantPast
            lastActivationError = ""
            model.update(track: nil, playing: false, position: 0, queueCount: 0)
            model.updateArtwork(nil)
            return
        }

        let next = NightwellNowPlayingTrack(track)
        let trackChanged = next.id != lastTrackID
        let artworkChanged = lastArtworkObject !== artwork
        if trackChanged {
            lastTrackID = next.id
            model.update(track: next, playing: playing, position: elapsed,
                         queueCount: queueCount, initialArtwork: nil)
        } else {
            model.update(track: next, playing: playing, position: elapsed,
                         queueCount: queueCount, initialArtwork: model.imageData)
        }
        if trackChanged || artworkChanged {
            artworkFailures = 0
            artworkRetryAt = .distantPast
        }
        let retryArtwork = artwork != nil && model.imageData == nil && artworkTask == nil &&
            artworkFailures < 3 && Date() >= artworkRetryAt
        if trackChanged || artworkChanged || retryArtwork {
            lastArtworkObject = artwork
            artworkTask?.cancel()
            artworkTask = nil
            let generation = UUID()
            artworkGeneration = generation
            if let image = artwork {
                let id = next.id
                artworkTask = Task { [weak self] in
                    let data = await Task.detached(priority: .utility) {
                        SystemArtworkEncoding.data(image)
                    }.value
                    guard !Task.isCancelled, let self, self.artworkGeneration == generation,
                          self.lastTrackID == id else { return }
                    self.artworkTask = nil
                    if let data, !data.isEmpty {
                        self.artworkFailures = 0
                        self.model.updateArtwork(data)
                    } else {
                        self.artworkFailures += 1
                        self.artworkRetryAt = Date().addingTimeInterval(2)
                        NSLog("Nightwell NowPlaying: artwork encoding failed")
                    }
                }
            } else {
                if artwork != nil {
                    artworkFailures += 1
                    artworkRetryAt = Date().addingTimeInterval(2)
                } else if model.imageData != nil {
                    model.updateArtwork(nil)
                }
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
