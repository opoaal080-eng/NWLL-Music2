import Foundation
import SwiftUI
import UIKit

// Mirrors the existing Nightwell "together" room protocol used by Windows.
struct TogetherMember: Decodable {
    init(from decoder: Decoder) throws {}
}

struct TogetherRoomState: Decodable {
    let code: String
    let members: [TogetherMember]
    let queue: [Track]
    let track: Track?
    let playing: Bool
    let position_ms: Double
    let server_time_ms: Double
    let updated_at_ms: Double
    let allow_control: Bool?
}

private struct TogetherRoomResponse: Decodable {
    let room: TogetherRoomState
}

@MainActor final class NightwellTogetherSession: ObservableObject {
    @Published private(set) var room: TogetherRoomState?
    @Published private(set) var busy = false
    @Published private(set) var status = "Нет активной комнаты"
    @Published var error: String?

    private var pollTask: Task<Void, Never>?
    private var roomOwnerID: String?

    var code: String { room?.code ?? "" }
    var joined: Bool { room != nil }

    static func invitationCode(from raw: String, origin: URL) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate: String
        if let components = URLComponents(string: value), let scheme = components.scheme {
            if scheme == "https", components.host?.lowercased() == origin.host?.lowercased() {
                candidate = components.queryItems?.first(where: { $0.name == "together" })?.value ?? ""
            } else if scheme == "nightwell", components.host == "together" {
                candidate = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            } else {
                return nil
            }
        } else {
            candidate = value
        }
        guard candidate.count == 24,
              candidate.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return nil }
        return candidate
    }

    func invitationURL(origin: URL) -> URL? {
        guard !code.isEmpty,
              var components = URLComponents(url: origin, resolvingAgainstBaseURL: false) else { return nil }
        components.path = "/"
        components.queryItems = [URLQueryItem(name: "together", value: code)]
        return components.url
    }

    func create(store: MusicStore) async {
        guard let account = store.account else { store.authPresented = true; return }
        busy = true
        defer { busy = false }
        do {
            let response: TogetherRoomResponse = try await store.api.request(
                "/api/together/rooms", method: "POST", timeout: 12
            )
            activate(response.room, accountID: account.id, store: store)
            if !store.clock.id.isEmpty {
                await command("track", trackID: store.clock.id, store: store)
            }
        } catch {
            self.error = "Не удалось создать комнату: " + error.localizedDescription
        }
    }

    func join(_ input: String, store: MusicStore) async {
        guard let account = store.account else { store.authPresented = true; return }
        guard let nextCode = Self.invitationCode(from: input, origin: store.origin) else {
            error = "Вставь ссылку приглашения или код комнаты из 24 символов."
            return
        }
        busy = true
        defer { busy = false }
        do {
            let response: TogetherRoomResponse = try await store.api.request(
                "/api/together/rooms/" + nextCode + "/join", method: "POST", timeout: 12
            )
            activate(response.room, accountID: account.id, store: store)
        } catch {
            self.error = "Не удалось подключиться: " + error.localizedDescription
        }
    }

    private func activate(_ newRoom: TogetherRoomState, accountID: String, store: MusicStore) {
        pollTask?.cancel()
        roomOwnerID = accountID
        apply(newRoom, store: store)
        let expectedCode = newRoom.code
        pollTask = Task { [weak self, weak store] in
            guard let self, let store else { return }
            while !Task.isCancelled && self.code == expectedCode {
                do { try await Task.sleep(nanoseconds: 1_500_000_000) }
                catch { return }
                guard !Task.isCancelled, self.code == expectedCode,
                      store.account?.id == accountID else { break }
                await self.refresh(store: store)
            }
            if store.account?.id != accountID { self.clearLocalRoom() }
        }
    }

    func refresh(store: MusicStore) async {
        guard !code.isEmpty else { return }
        do {
            let response: TogetherRoomResponse = try await store.api.request(
                "/api/together/rooms/" + code, timeout: 8
            )
            guard response.room.code == code else { return }
            apply(response.room, store: store)
        } catch {
            status = "Связь с комнатой потеряна. Переподключаемся."
        }
    }

    private func apply(_ next: TogetherRoomState, store: MusicStore) {
        guard roomOwnerID == store.account?.id else { return }
        room = next
        status = "Участников: \(next.members.count)"
        guard let track = next.track else { return }

        let positionMS = max(0, next.position_ms
            + (next.playing ? max(0, next.server_time_ms - next.updated_at_ms) : 0))
        let expectedSeconds = positionMS / 1000.0
        if store.clock.id != track.id {
            var allTracks = next.queue
            if !allTracks.contains(where: { $0.id == track.id }) {
                allTracks.insert(track, at: 0)
            }
            NativePlayer.shared.prepare([
                "id": track.id,
                "queue": allTracks.map(\.dictionary),
                "account": store.account?.id ?? "device",
                "position": positionMS,
                "wave": false
            ], origin: store.origin, cookies: HTTPCookieStorage.shared.cookies(for: store.origin) ?? [])
            if next.playing { NativePlayer.shared.play() }
        } else {
            // Do not seek on small fluctuations: constant seeking causes stutters.
            if abs(store.clock.position - expectedSeconds) > 1.5 {
                NativePlayer.shared.seek(expectedSeconds)
            }
            if next.playing && !store.clock.playing {
                NativePlayer.shared.play()
            } else if !next.playing && store.clock.playing {
                NativePlayer.shared.pause()
            }
        }
    }

    func command(_ action: String, trackID: String? = nil, positionSeconds: Double? = nil,
                 store: MusicStore) async {
        guard !code.isEmpty else { return }
        var payload: [String: Any] = ["action": action]
        if let trackID { payload["track_id"] = trackID }
        if let positionSeconds { payload["position_ms"] = Int64(positionSeconds * 1000) }
        do {
            let _: OK = try await store.api.request(
                "/api/together/rooms/" + code + "/command",
                method: "POST", body: payload, timeout: 9
            )
            await refresh(store: store)
        } catch {
            self.error = "Не удалось управлять комнатой: " + error.localizedDescription
        }
    }

    func addCurrent(store: MusicStore) async {
        guard !code.isEmpty, !store.clock.id.isEmpty else { return }
        do {
            let _: OK = try await store.api.request(
                "/api/together/rooms/" + code + "/queue", method: "POST",
                body: ["track_id": store.clock.id], timeout: 10
            )
            await refresh(store: store)
        } catch {
            self.error = "Не удалось добавить трек: " + error.localizedDescription
        }
    }

    func allowGuestControl(_ enabled: Bool, store: MusicStore) async {
        guard !code.isEmpty else { return }
        do {
            let _: OK = try await store.api.request(
                "/api/together/rooms/" + code + "/settings", method: "POST",
                body: ["allow_control": enabled], timeout: 9
            )
            await refresh(store: store)
        } catch {
            self.error = "Не удалось изменить права: " + error.localizedDescription
        }
    }

    func leave(store: MusicStore) async {
        let oldCode = code
        clearLocalRoom()
        guard !oldCode.isEmpty else { return }
        do {
            let _: OK = try await store.api.request(
                "/api/together/rooms/" + oldCode + "/leave", method: "POST", timeout: 8
            )
        } catch {
            self.error = "Не удалось уведомить сервер о выходе: " + error.localizedDescription
        }
    }

    func clearLocalRoom() {
        pollTask?.cancel()
        pollTask = nil
        room = nil
        roomOwnerID = nil
        status = "Нет активной комнаты"
    }
}

struct NightwellTogetherSheet: View {
    @ObservedObject var session: NightwellTogetherSession
    @ObservedObject var store: MusicStore
    @Environment(\.dismiss) private var dismiss
    @State private var inviteInput = ""

    private func action(_ title: String, icon: String, busy: Bool = false,
                        run: @escaping () async -> Void) -> some View {
        Button {
            Task { await run() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).frame(width: 24)
                Text(title)
                Spacer(minLength: 4)
                if busy { ProgressView().tint(.white) }
            }
            .font(.system(size: 15, weight: .semibold))
            .padding(16)
            .foregroundStyle(.white)
            .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .disabled(busy)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Музыка в синхроне с друзьями, без чата. Пригласи по ссылке или присоединись к комнате.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.68))

                    if store.account == nil {
                        action("Войти, чтобы слушать вместе", icon: "person.crop.circle") {
                            dismiss()
                            store.authPresented = true
                        }
                    } else if !session.joined {
                        action("Создать комнату", icon: "plus.circle.fill", busy: session.busy) {
                            await session.create(store: store)
                        }
                        TextField("Ссылка приглашения или код комнаты", text: $inviteInput)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textFieldStyle(.plain)
                            .font(.system(size: 15))
                            .padding(16)
                            .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
                        action("Присоединиться", icon: "person.2.fill", busy: session.busy) {
                            await session.join(inviteInput, store: store)
                        }
                    } else {
                        HStack {
                            Image(systemName: "person.2.wave.2")
                            Text(session.status)
                            Spacer(minLength: 0)
                        }
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.80))

                        Text("Комната \(session.code)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.48))
                            .textSelection(.enabled)

                        if let url = session.invitationURL(origin: store.origin) {
                            ShareLink(item: url) {
                                Label("Пригласить по ссылке", systemImage: "square.and.arrow.up")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(16)
                                    .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
                            }
                            .tint(.white)
                            action("Скопировать приглашение", icon: "doc.on.doc") {
                                UIPasteboard.general.url = url
                            }
                        }

                        if let track = session.room?.track {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Сейчас звучит").font(.caption).foregroundStyle(.secondary)
                                Text(track.title).font(.headline)
                                Text(track.artist).font(.subheadline).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
                        }
                        HStack(spacing: 12) {
                            Button {
                                Task { await session.command("previous", store: store) }
                            } label: {
                                Image(systemName: "backward.end.fill")
                                    .frame(maxWidth: .infinity, minHeight: 52)
                            }
                            Button {
                                Task { await session.command(session.room?.playing == true ? "pause" : "play", store: store) }
                            } label: {
                                Image(systemName: session.room?.playing == true ? "pause.fill" : "play.fill")
                                    .frame(maxWidth: .infinity, minHeight: 52)
                            }
                            Button {
                                Task { await session.command("next", store: store) }
                            } label: {
                                Image(systemName: "forward.end.fill")
                                    .frame(maxWidth: .infinity, minHeight: 52)
                            }
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 19))
                        .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))

                        action("Добавить текущий трек в общую очередь", icon: "text.badge.plus") {
                            await session.addCurrent(store: store)
                        }
                        if let entries = session.room?.queue, !entries.isEmpty {
                            Text("Общая очередь").font(.headline).padding(.top, 6)
                            ForEach(entries) { track in
                                Button {
                                    Task { await session.command("track", trackID: track.id, store: store) }
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "music.note")
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(track.title).lineLimit(1)
                                            Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        Spacer(minLength: 0)
                                    }
                                    .padding(12)
                                    .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 12))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        action("Разрешить управление участникам", icon: "person.2") {
                            await session.allowGuestControl(true, store: store)
                        }
                        action("Управляет только ведущий", icon: "lock") {
                            await session.allowGuestControl(false, store: store)
                        }
                        action("Выйти из комнаты", icon: "rectangle.portrait.and.arrow.right") {
                            await session.leave(store: store)
                        }
                    }
                }
                .padding(20)
            }
            .background {
                LinearGradient(colors: [Color(white: 0.13), Color(white: 0.03), .black],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()
            }
            .navigationTitle("Слушать вместе")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Закрыть") { dismiss() }.foregroundStyle(.white)
                }
            }
            .alert("Слушать вместе", isPresented: Binding(
                get: { session.error != nil },
                set: { if !$0 { session.error = nil } }
            )) {
                Button("Понятно") { session.error = nil }
            } message: {
                Text(session.error ?? "")
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}
