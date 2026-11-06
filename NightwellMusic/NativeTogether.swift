import SwiftUI
import Foundation

private struct TogetherTrack: Decodable, Identifiable {
    let id: String
    let title: String
    let artist: String
    let cover_url: String?
    let source: String?
    let duration: Double?
    var native: Track {
        Track(id: id, title: title, artist: artist, album: "Nightwell",
              duration: duration, cover_url: cover_url, source: source,
              is_remote: source == "audius" || source == "soundcloud")
    }
}
private struct TogetherMember: Decodable, Identifiable {
    let id: String
    let name: String
    let online: Bool
}
private struct TogetherRoom: Decodable {
    let code: String
    let owner: String
    let members: [TogetherMember]
    let track: TogetherTrack?
    let queue: [TogetherTrack]
    let playing: Bool
    let position_ms: Int64
    let updated_at_ms: Int64
    let server_time_ms: Int64
    let allow_control: Bool
}
private struct TogetherResponse: Decodable { let room: TogetherRoom }
private struct TogetherOK: Decodable { let ok: Bool }

@MainActor final class NativeTogether: ObservableObject {
    @Published private(set) var roomCode: String?
    @Published private(set) var title = "Нет активной комнаты"
    @Published private(set) var artist = ""
    @Published private(set) var participantCount = 0
    @Published private(set) var members: [String] = []
    @Published private(set) var queue: [String] = []
    @Published private(set) var playing = false
    @Published private(set) var allowControl = true
    @Published private(set) var ownerID = ""
    @Published var invite = ""
    @Published var notice = ""
    private var room: TogetherRoom?
    private var loop: Task<Void, Never>?
    private var mutedUntil = Date.distantPast
    private var lastVersion = 0
    private var expectedTrack = ""
    var inviteURL: URL? {
        guard let roomCode else { return nil }
        return URL(string: "https://music.nightwell.fun/?together=" + roomCode)
    }
    func canControl(_ store: MusicStore) -> Bool {
        store.account != nil && (store.account?.id == ownerID || allowControl)
    }
    static func code(from text: String) -> String? {
        let value: String
        if let url = URL(string: text), let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
           let fromURL = components.queryItems?.first(where: { $0.name == "together" })?.value {
            value = fromURL
        } else { value = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard value.range(of: "^[A-Za-z0-9_-]{24}$", options: .regularExpression) != nil else { return nil }
        return value
    }
    func create(_ store: MusicStore) async {
        guard store.account != nil else { store.authPresented = true; return }
        do {
            let response: TogetherResponse = try await store.api.request("/api/together/rooms", method: "POST")
            activate(response.room, store)
            if let track = store.clock.current { await command("track", store: store, trackID: track.id) }
        } catch { notice = error.localizedDescription }
    }
    func join(_ store: MusicStore) async {
        guard store.account != nil else { store.authPresented = true; return }
        guard let code = Self.code(from: invite) else { notice = "Вставь ссылку приглашения или код комнаты"; return }
        do {
            let response: TogetherResponse = try await store.api.request("/api/together/rooms/" + code + "/join", method: "POST")
            activate(response.room, store)
        } catch { notice = error.localizedDescription }
    }
    private func activate(_ state: TogetherRoom, _ store: MusicStore) {
        loop?.cancel()
        roomCode = state.code
        lastVersion = 0
        update(state, store)
        loop = Task { [weak self] in
            while let self, !Task.isCancelled, self.roomCode == state.code, store.account != nil {
                await self.refresh(store)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }
    private func refresh(_ store: MusicStore) async {
        guard let roomCode else { return }
        do {
            let result: TogetherResponse = try await store.api.request("/api/together/rooms/" + roomCode, timeout: 8)
            guard self.roomCode == roomCode else { return }
            update(result.room, store)
        } catch { notice = "Нет связи с комнатой. Переподключаемся." }
    }
    private func update(_ state: TogetherRoom, _ store: MusicStore) {
        room = state
        title = state.track?.title ?? "Добавь трек в общую очередь"
        artist = state.track?.artist ?? ""
        participantCount = state.members.count
        members = state.members.map { ($0.name.hasPrefix("User-") ? "Участник " + String($0.name.suffix(5)) : $0.name) + ($0.id == state.owner ? " · ведущий" : "") }
        queue = state.queue.map { $0.artist + " · " + $0.title }
        playing = state.playing
        allowControl = state.allow_control
        ownerID = state.owner
        synchronize(state, store)
        notice = "Комната подключена"
    }
    private func synchronize(_ state: TogetherRoom, _ store: MusicStore) {
        guard let track = state.track else { return }
        let nowMS = Int64(Date().timeIntervalSince1970 * 1000)
        let desired = max(0, Double(state.position_ms + (state.playing ? max(0, nowMS - state.updated_at_ms) : 0)) / 1000)
        let changed = store.clock.id != track.id
        if changed {
            mutedUntil = Date().addingTimeInterval(4)
            expectedTrack = track.id
            var tracks = state.queue.map(\.native)
            if !tracks.contains(where: { $0.id == track.id }) { tracks.insert(track.native, at: 0) }
            store.play(track.native, in: tracks)
            NativePlayer.shared.seek(desired)
        } else if abs(store.clock.position - desired) > 1.5 {
            mutedUntil = Date().addingTimeInterval(2)
            NativePlayer.shared.seek(desired)
        }
        if state.playing && !store.clock.playing { mutedUntil = Date().addingTimeInterval(2); NativePlayer.shared.play() }
        if !state.playing && store.clock.playing { mutedUntil = Date().addingTimeInterval(2); NativePlayer.shared.pause() }
    }
    func command(_ action: String, store: MusicStore, trackID: String? = nil, position: Double? = nil) async {
        guard let code = roomCode, canControl(store) else { return }
        var data: [String: Any] = ["action": action]
        if let trackID { data["track_id"] = trackID }
        if let position { data["position_ms"] = Int64(position * 1000) }
        do {
            let _: TogetherOK = try await store.api.request("/api/together/rooms/" + code + "/command", method: "POST", body: data)
            await refresh(store)
        } catch { notice = error.localizedDescription }
    }
    func addCurrent(_ store: MusicStore) async {
        guard let code = roomCode, let id = store.clock.current?.id else { notice = "Сначала включи трек"; return }
        do {
            let _: TogetherOK = try await store.api.request("/api/together/rooms/" + code + "/queue", method: "POST", body: ["track_id": id])
            await refresh(store)
        } catch { notice = error.localizedDescription }
    }
    func setAllowControl(_ value: Bool, store: MusicStore) async {
        guard let code = roomCode, ownerID == store.account?.id else { return }
        do {
            let _: TogetherOK = try await store.api.request("/api/together/rooms/" + code + "/settings", method: "POST", body: ["allow_control": value])
            await refresh(store)
        } catch { notice = error.localizedDescription }
    }
    func localTrackChanged(_ id: String, store: MusicStore) {
        guard !id.isEmpty, Date() > mutedUntil, roomCode != nil, canControl(store), id != room?.track?.id else { return }
        Task { await command("track", store: store, trackID: id) }
    }
    func localPlayingChanged(_ state: Bool, store: MusicStore) {
        guard Date() > mutedUntil, roomCode != nil, canControl(store), room?.track?.id == store.clock.id, room?.playing != state else { return }
        Task { await command(state ? "play" : "pause", store: store) }
    }
    func leave(_ store: MusicStore) async {
        guard let code = roomCode else { return }
        loop?.cancel(); loop = nil
        roomCode = nil; room = nil; title = "Нет активной комнаты"; notice = "Ты вышел из комнаты"
        do {
            let _: TogetherOK = try await store.api.request("/api/together/rooms/" + code + "/leave", method: "POST")
        } catch { notice = error.localizedDescription }
    }
}

struct NativeTogetherView: View {
    @EnvironmentObject private var store: MusicStore
    @ObservedObject var together: NativeTogether
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Слушайте один трек на разных устройствах. Приглашение только по ссылке.")
                        .foregroundStyle(.secondary)
                    if together.roomCode == nil {
                        Button("Создать комнату") { Task { await together.create(store) } }
                            .buttonStyle(.borderedProminent)
                        TextField("Вставь ссылку или код комнаты", text: $together.invite)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .padding(14).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        Button("Присоединиться") { Task { await together.join(store) } }.buttonStyle(.bordered)
                    } else {
                        Text(together.title).font(.title3.bold())
                        Text(together.artist).foregroundStyle(.secondary)
                        Text("Участников: \(together.participantCount)/10")
                        if let url = together.inviteURL {
                            ShareLink(item: url) { Label("Пригласить по ссылке", systemImage: "square.and.arrow.up") }
                                .buttonStyle(.borderedProminent)
                        }
                        HStack {
                            Button { Task { await together.command("previous", store: store) } } label: { Image(systemName: "backward.end.fill") }
                            Button { Task { await together.command(together.playing ? "pause" : "play", store: store) } } label: { Image(systemName: together.playing ? "pause.fill" : "play.fill") }
                            Button { Task { await together.command("next", store: store) } } label: { Image(systemName: "forward.end.fill") }
                        }.buttonStyle(.bordered).disabled(!together.canControl(store))
                        HStack {
                            Button("Добавить текущий трек") { Task { await together.addCurrent(store) } }
                            Button("Вернуться к друзьям") { Task { await together.command("play", store: store) } }
                        }.buttonStyle(.bordered)
                        if together.ownerID == store.account?.id {
                            Toggle("Разрешить управление всем", isOn: Binding(
                                get: { together.allowControl },
                                set: { value in Task { await together.setAllowControl(value, store: store) } }))
                        }
                        Text("Участники").font(.headline)
                        ForEach(together.members, id: \.self) { Text($0).font(.subheadline) }
                        Text("Общая очередь").font(.headline)
                        ForEach(together.queue, id: \.self) { Text($0).font(.subheadline) }
                        Button("Покинуть комнату", role: .destructive) { Task { await together.leave(store) } }
                    }
                    if !together.notice.isEmpty {
                        Text(together.notice).font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(20)
            }
            .navigationTitle("Nightwell Together")
            .preferredColorScheme(.dark)
        }
    }
}
