import SwiftUI
import UIKit

// A native client of the existing Nightwell Together Go rooms.
// Audio stays inside the iOS NativePlayer; the server distributes state only.
struct TogetherTrack: Decodable, Identifiable {
    let id: String
    let title: String
    let artist: String
    let cover_url: String?
    let source: String?
    let duration: Double?
    var model: Track {
        Track(id: id, title: title, artist: artist, album: "Nightwell",
              duration: duration, cover_url: cover_url, source: source,
              is_remote: source == "audius" || source == "soundcloud")
    }
}
struct TogetherMember: Decodable, Identifiable {
    let id: String
    let name: String
    let online: Bool
}
struct TogetherRoom: Decodable {
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
    let version: UInt64
}
private struct TogetherEnvelope: Decodable { let room: TogetherRoom }
private struct TogetherResult: Decodable { let ok: Bool? }

@MainActor final class NightwellTogether: ObservableObject {
    static let shared = NightwellTogether()
    @Published private(set) var room: TogetherRoom?
    @Published var input = ""
    @Published var notice = ""
    @Published private(set) var busy = false
    private var api: MusicAPI?
    private weak var store: MusicStore?
    private var pollTask: Task<Void, Never>?
    private var applyingUntil = Date.distantPast
    private var lastCommandAt = Date.distantPast

    var joined: Bool { room != nil }
    var canControl: Bool {
        guard let room, let id = store?.account?.id else { return false }
        return id == room.owner || room.allow_control
    }
    var inviteLink: URL? {
        guard let room else { return nil }
        return URL(string: "https://music.nightwell.fun/?together=" + room.code)
    }
    func attach(_ store: MusicStore) { self.store = store; self.api = store.api }

    static func parseCode(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var value = text
        if let components = URLComponents(string: text),
           components.scheme == "https", components.host?.lowercased() == "music.nightwell.fun",
           let found = components.queryItems?.first(where: { $0.name == "together" })?.value {
            value = found
        } else if text.contains("://") { return nil }
        guard value.range(of: "^[A-Za-z0-9_-]{24}$", options: .regularExpression) != nil else { return nil }
        return value
    }

    func create() async {
        guard let store, store.account != nil, let api else { notice = "Войди в Nightwell Music."; return }
        busy = true; defer { busy = false }
        do {
            let response: TogetherEnvelope = try await api.request("/api/together/rooms", method: "POST", body: [:])
            activate(response.room)
            if let current = store.clock.current { await send("track", trackID: current.id) }
        } catch { notice = error.localizedDescription }
    }
    func join() async {
        guard let code = Self.parseCode(input) else { notice = "Вставь ссылку или код комнаты."; return }
        guard store?.account != nil, let api else { notice = "Сначала войди в Nightwell Music."; return }
        busy = true; defer { busy = false }
        do {
            let response: TogetherEnvelope = try await api.request("/api/together/rooms/" + code + "/join",
                                                                  method: "POST", body: [:])
            activate(response.room)
        } catch { notice = error.localizedDescription }
    }
    private func activate(_ value: TogetherRoom) {
        room = value; input = value.code; notice = "Комната подключена"
        pollTask?.cancel()
        let code = value.code
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.room?.code == code, let api = self.api else { break }
                do {
                    let response: TogetherEnvelope = try await api.request("/api/together/rooms/" + code, timeout: 10)
                    if Task.isCancelled { break }
                    self.room = response.room
                    self.apply(response.room)
                    self.notice = ""
                } catch {
                    self.notice = "Переподключаемся: " + error.localizedDescription
                }
                do { try await Task.sleep(nanoseconds: 1_500_000_000) } catch { break }
            }
        }
        apply(value)
    }
    private func apply(_ state: TogetherRoom) {
        guard let store, let source = state.track, store.account != nil else { return }
        let ownID = store.clock.id
        let needsTrack = ownID != source.id
        if needsTrack {
            applyingUntil = Date().addingTimeInterval(3)
            let models = state.queue.map(\.model)
            store.play(source.model, in: models.isEmpty ? [source.model] : models)
        }
        let player = NativePlayer.shared
        if state.playing {
            if !store.clock.playing { applyingUntil = Date().addingTimeInterval(2); player.play() }
        } else if store.clock.playing {
            applyingUntil = Date().addingTimeInterval(2)
            player.pause()
        }
        // Go's position_ms is evaluated at server_time_ms for every GET.
        let ageMs = max(0, Int64(Date().timeIntervalSince1970 * 1000) - state.server_time_ms)
        let expected = Double(state.position_ms + (state.playing ? min(ageMs, 1800) : 0)) / 1000
        if !needsTrack && store.clock.duration > 2 &&
           abs(store.clock.position - expected) > 1.3 {
            applyingUntil = Date().addingTimeInterval(2)
            player.seek(max(0, min(expected, store.clock.duration - 0.2)))
        }
    }
    func send(_ action: String, trackID: String? = nil, positionMS: Int64? = nil) async {
        guard canControl, let room, let api else { return }
        var body: [String: Any] = ["action": action]
        if let trackID { body["track_id"] = trackID }
        if let positionMS { body["position_ms"] = positionMS }
        do {
            let _: TogetherResult = try await api.request("/api/together/rooms/" + room.code + "/command",
                                                          method: "POST", body: body)
            lastCommandAt = Date()
        } catch { notice = error.localizedDescription }
    }
    func addCurrent() async {
        guard let room, let id = store?.clock.id, !id.isEmpty, let api else { return }
        do {
            let _: TogetherResult = try await api.request("/api/together/rooms/" + room.code + "/queue",
                                                          method: "POST", body: ["track_id": id])
            notice = "Добавлено в общую очередь"
        } catch { notice = error.localizedDescription }
    }
    func setEveryoneControl(_ allowed: Bool) async {
        guard let room, room.owner == store?.account?.id, let api else { return }
        do {
            let _: TogetherResult = try await api.request("/api/together/rooms/" + room.code + "/settings",
                                                          method: "POST", body: ["allow_control": allowed])
        } catch { notice = error.localizedDescription }
    }
    func leave() async {
        guard let room else { return }
        pollTask?.cancel(); pollTask = nil
        self.room = nil
        if let api {
            do {
                let _: TogetherResult = try await api.request("/api/together/rooms/" + room.code + "/leave",
                                                              method: "POST", body: [:])
            } catch { notice = error.localizedDescription }
        }
        notice = "Ты покинул комнату"
    }
    // Regular Nightwell controls continue to work while a room is active.
    func selectedTrack(_ track: Track) {
        guard canControl, Date() >= applyingUntil, room?.track?.id != track.id else { return }
        Task { await send("track", trackID: track.id) }
    }
    func playbackChanged(_ playing: Bool) {
        guard canControl, Date() >= applyingUntil,
              Date().timeIntervalSince(lastCommandAt) > 1.0,
              room?.playing != playing else { return }
        Task { await send(playing ? "play" : "pause") }
    }
}

struct NightwellTogetherSheet: View {
    @EnvironmentObject private var store: MusicStore
    @ObservedObject var together: NightwellTogether
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    Text("Один трек на разных устройствах. Приглашение только по ссылке.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    if store.account == nil {
                        Text("Для комнаты нужно войти в аккаунт Nightwell.")
                            .foregroundStyle(.orange)
                        Button("Войти") { dismiss(); store.authPresented = true }
                    } else if let room = together.room {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(room.track?.title ?? "Добавь первый трек").font(.title3.bold())
                            Text(room.track?.artist ?? "Очередь пуста").foregroundStyle(.secondary)
                            Text("Участников: \(room.members.count) из 10")
                                .font(.caption).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                            .padding().background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18))
                        HStack(spacing: 10) {
                            control("backward.end.fill", "previous")
                            control(room.playing ? "pause.fill" : "play.fill", room.playing ? "pause" : "play")
                            control("forward.end.fill", "next")
                        }
                        Button("Вернуться к друзьям") {
                            Task { await together.send("seek", positionMS: Int64(store.clock.position * 1000)) }
                        }
                        .disabled(!together.canControl)
                        Button("Добавить текущий трек в очередь") { Task { await together.addCurrent() } }
                            .disabled(store.clock.id.isEmpty)
                        if let link = together.inviteLink {
                            ShareLink(item: link) { Label("Пригласить по ссылке", systemImage: "square.and.arrow.up") }
                            Button("Скопировать ссылку") { UIPasteboard.general.url = link }
                        }
                        if room.owner == store.account?.id {
                            Toggle("Разрешить всем управлять", isOn: Binding(
                                get: { together.room?.allow_control ?? false },
                                set: { allowed in Task { await together.setEveryoneControl(allowed) } }
                            ))
                        }
                        Text("Участники").font(.headline)
                        ForEach(room.members) { person in
                            HStack {
                                Circle().fill(person.online ? Color.green : Color.gray).frame(width: 7, height: 7)
                                Text(person.id == store.account?.id ? "Ты" : person.name)
                                if person.id == room.owner { Text("ведущий").font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                        Text("Общая очередь").font(.headline)
                        ForEach(room.queue) { track in
                            Button { Task { await together.send("track", trackID: track.id) } } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(track.title).foregroundStyle(.primary)
                                    Text(track.artist).font(.caption).foregroundStyle(.secondary)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.disabled(!together.canControl)
                        }
                        Button("Покинуть комнату", role: .destructive) { Task { await together.leave() } }
                    } else {
                        TextField("Ссылка-приглашение или код", text: $together.input)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .padding(12).background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        Button("Вставить из буфера") { together.input = UIPasteboard.general.string ?? "" }
                        Button("Присоединиться") { Task { await together.join() } }.disabled(together.busy)
                        Button("Создать комнату") { Task { await together.create() } }.disabled(together.busy)
                            .buttonStyle(.borderedProminent)
                    }
                    if !together.notice.isEmpty {
                        Text(together.notice).font(.caption).foregroundStyle(.secondary)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }
            .navigationTitle("Слушать вместе")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Закрыть") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
        .onAppear { together.attach(store) }
    }
    private func control(_ symbol: String, _ command: String) -> some View {
        Button { Task { await together.send(command) } } label: {
            Image(systemName: symbol).font(.title2)
                .frame(maxWidth: .infinity).padding(14)
                .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
        }.disabled(!together.canControl || together.room?.track == nil)
    }
}
