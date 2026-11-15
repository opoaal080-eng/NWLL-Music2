import Foundation
import Security
import SwiftUI
import UIKit

// A device credential is issued by the server. A local identifier is never
// treated as proof of device ownership.
struct NWDeviceRegistration: Codable {
    let device_id: String
    let device_token: String
}
enum NWDeviceCredentials {
    static func key(_ origin: URL, _ account: String) -> String {
        (origin.host ?? "") + "|" + account
    }
    static func load(_ key: String) -> NWDeviceRegistration? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "fun.nightwell.music.device-access",
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(NWDeviceRegistration.self, from: data)
    }
    static func save(_ item: NWDeviceRegistration, key: String) throws {
        let data = try JSONEncoder().encode(item)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "fun.nightwell.music.device-access",
            kSecAttrAccount as String: key
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw APIError(message: "Не удалось сохранить ключ устройства в Keychain")
            }
        } else if status != errSecSuccess {
            throw APIError(message: "Не удалось обновить ключ устройства в Keychain")
        }
    }
    static func installAudioCookie(_ token: String, origin: URL) {
        guard let host = origin.host,
              let cookie = HTTPCookie(properties: [
                .domain: host, .path: "/", .name: "nw_device_token",
                .value: token, .secure: "TRUE",
                .expires: Date(timeIntervalSinceNow: 365 * 86400),
                HTTPCookiePropertyKey(rawValue: "HttpOnly"): "TRUE"
              ]) else { return }
        HTTPCookieStorage.shared.setCookie(cookie)
    }
}

private struct NWAccessInfo: Decodable {
    let premium: Bool
    let source: String
    let device_limit: Int
    let billing_owner: Bool
}
private struct NWDeviceList: Decodable {
    let limit: Int
    let count: Int
    let devices: [NWDevice]
}
private struct NWDevice: Identifiable, Decodable {
    let id: String
    let name: String
    let platform: String
    let current: Bool
    let blocked: Bool
}
private struct NWFamilyEnvelope: Decodable {
    let family: NWFamily?
    let access: NWAccessInfo
}
private struct NWFamily: Decodable {
    struct Member: Decodable, Identifiable {
        let account_id: String
        let role: String
        var id: String { account_id }
    }
    struct Invitation: Decodable, Identifiable {
        let id: String
        let expires_at: Double
    }
    let role: String
    let members: [Member]
    let capacity: Int
    let pending_invites: [Invitation]?
}
private struct NWInvite: Decodable { let invite_url: String }

struct AccountAccessView: View {
    let api: MusicAPI
    @Environment(\.dismiss) private var dismiss
    @State private var devices: NWDeviceList?
    @State private var family: NWFamilyEnvelope?
    @State private var loading = false
    @State private var error = ""
    @State private var inviteURL = ""
    @State private var inviteInput = ""
    @State private var pendingDevice: String?
    @State private var confirmDissolve = false
    @State private var confirmLeave = false

    private var owner: Bool { family?.family?.role == "owner" }
    private var directPremium: Bool {
        family?.access.premium == true && family?.access.source == "direct"
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 19) {
                    if !error.isEmpty {
                        Text(error).foregroundStyle(.red).font(.footnote)
                    }
                    if let access = family?.access {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Доступ").font(.headline)
                            Text(access.premium ? "Nightwell Premium" : "Бесплатный аккаунт")
                                .font(.title3.bold())
                            Text(access.source == "family" ? "Подписка предоставлена семьёй" :
                                 access.source == "direct" ? "Личная подписка" : "Без подписки")
                                .foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Мои устройства").font(.headline)
                            Spacer()
                            if let devices { Text("\(devices.count)/\(devices.limit)").foregroundStyle(.secondary) }
                        }
                        ForEach(devices?.devices ?? []) { device in
                            HStack(spacing: 12) {
                                Image(systemName: device.platform == "ios" ? "iphone" :
                                      device.platform == "android" ? "smartphone" :
                                      device.platform == "windows" ? "desktopcomputer" : "globe")
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(device.name).font(.subheadline.weight(.medium))
                                    Text(device.blocked ? "Заблокировано лимитом" :
                                         device.current ? "Это устройство" : device.platform)
                                        .font(.caption).foregroundStyle(device.blocked ? .orange : .secondary)
                                }
                                Spacer()
                                Button(role: .destructive) { pendingDevice = device.id } label: {
                                    Image(systemName: "trash").padding(8)
                                }.accessibilityLabel("Удалить устройство")
                            }.padding(10).background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 13))
                        }
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Семейный Premium").font(.headline)
                        Text("Три личных аккаунта: владелец и два участника. Избранное и плейлисты не объединяются.")
                            .font(.footnote).foregroundStyle(.secondary)
                        if let state = family?.family {
                            ForEach(state.members) { member in
                                HStack {
                                    Text(member.account_id == state.members.first?.account_id ? "Владелец" : "Участник")
                                    Spacer()
                                    Text(member.account_id).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    if owner && member.role != "owner" {
                                        Button(role: .destructive) {
                                            Task { await perform("api/family/members/" + member.account_id, method: "DELETE") }
                                        } label: { Image(systemName: "xmark.circle") }
                                    }
                                }
                            }
                            if owner {
                                ForEach(state.pending_invites ?? []) { invitation in
                                    HStack {
                                        Text("Приглашение ожидает")
                                        Spacer()
                                        Button("Отозвать") {
                                            Task { await perform("api/family/invitations/" + invitation.id, method: "DELETE") }
                                        }.font(.caption)
                                    }
                                }
                                Button("Создать ссылку-приглашение") { Task { await createInvite() } }
                                    .disabled(loading || !directPremium)
                                if !inviteURL.isEmpty {
                                    ShareLink(item: inviteURL) { Label("Поделиться приглашением", systemImage: "square.and.arrow.up") }
                                    Text("Ссылка действует 7 дней и предназначена одному человеку.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Button("Распустить семью", role: .destructive) { confirmDissolve = true }
                            } else {
                                Button("Покинуть семью", role: .destructive) { confirmLeave = true }
                            }
                        } else {
                            if directPremium {
                                Button("Создать семейное приглашение") { Task { await createInvite() } }
                                    .disabled(loading)
                                if !inviteURL.isEmpty {
                                    ShareLink(item: inviteURL) { Label("Поделиться приглашением", systemImage: "square.and.arrow.up") }
                                }
                            }
                            TextField("Ссылка или код приглашения", text: $inviteInput)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .textFieldStyle(.roundedBorder)
                            Button("Принять приглашение") { Task { await acceptInvite() } }
                                .disabled(loading || inviteInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                }
                .padding(20)
            }
            .background(Color.black)
            .foregroundStyle(.white)
            .navigationTitle("Устройства и семья")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(loading)
                }
            }
            .task { await reload() }
            .confirmationDialog("Удалить устройство и отозвать его сессии?", isPresented: Binding(
                get: { pendingDevice != nil }, set: { if !$0 { pendingDevice = nil } })) {
                Button("Удалить", role: .destructive) {
                    if let id = pendingDevice {
                        Task { await perform("api/devices/" + id, method: "DELETE") }
                    }
                    pendingDevice = nil
                }
                Button("Отмена", role: .cancel) { pendingDevice = nil }
            }
            .confirmationDialog("Распустить семью?", isPresented: $confirmDissolve) {
                Button("Распустить", role: .destructive) { Task { await perform("api/family", method: "DELETE") } }
            }
            .confirmationDialog("Покинуть семью?", isPresented: $confirmLeave) {
                Button("Выйти", role: .destructive) { Task { await perform("api/family/leave", method: "POST") } }
            }
        }
        .preferredColorScheme(.dark)
    }
    private func reload() async {
        loading = true
        defer { loading = false }
        do {
            async let myDevices: NWDeviceList = api.request("api/devices")
            async let myFamily: NWFamilyEnvelope = api.request("api/family")
            (devices, family) = try await (myDevices, myFamily)
            error = ""
        } catch {
            self.error = error.localizedDescription
        }
    }
    private func perform(_ path: String, method: String) async {
        loading = true
        do {
            let _: OK = try await api.request(path, method: method)
            loading = false
            await reload()
        } catch {
            loading = false
            self.error = error.localizedDescription
        }
    }
    private func createInvite() async {
        loading = true
        do {
            let response: NWInvite = try await api.request("api/family/invitations", method: "POST")
            inviteURL = response.invite_url
            loading = false
            await reload()
        } catch {
            loading = false
            self.error = error.localizedDescription
        }
    }
    private func acceptInvite() async {
        let raw = inviteInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = raw.components(separatedBy: "#invite=").last ?? raw
        guard token.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil else {
            error = "Неверная ссылка-приглашение"
            return
        }
        loading = true
        do {
            let _: NWFamilyEnvelope = try await api.request("api/family/invitations/accept",
                                                           method: "POST", body: ["token": token])
            inviteInput = ""
            loading = false
            await reload()
        } catch {
            loading = false
            self.error = error.localizedDescription
        }
    }
}
