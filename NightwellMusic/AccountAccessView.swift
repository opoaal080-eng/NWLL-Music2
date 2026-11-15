import Foundation
import Security
import SwiftUI
import UIKit

// The server authenticates this secret against the current session. The old playback
// hand-off identifier is intentionally not used as an access credential.
struct AccountDeviceCredential: Codable {
    let device_id: String
    let device_token: String
}

enum AccountDeviceVault {
    private static let service = "fun.nightwell.music.account-device.v1"
    private static func key(_ origin: URL, _ account: String) -> String {
        (origin.host ?? origin.absoluteString) + "|" + account
    }
    static func read(origin: URL, account: String) throws -> AccountDeviceCredential? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key(origin, account),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let result = SecItemCopyMatching(query as CFDictionary, &item)
        if result == errSecItemNotFound { return nil }
        guard result == errSecSuccess, let data = item as? Data else {
            throw APIError(message: "Не удалось открыть защищённый ключ устройства.")
        }
        return try JSONDecoder().decode(AccountDeviceCredential.self, from: data)
    }
    static func save(_ credential: AccountDeviceCredential, origin: URL, account: String) throws {
        let data = try JSONEncoder().encode(credential)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key(origin, account)
        ]
        let changes: [String: Any] = [kSecValueData as String: data]
        let updated = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        if updated == errSecItemNotFound {
            var newItem = query
            newItem[kSecValueData as String] = data
            newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(newItem as CFDictionary, nil) == errSecSuccess else {
                throw APIError(message: "Не удалось сохранить ключ устройства в Keychain.")
            }
        } else if updated != errSecSuccess {
            throw APIError(message: "Не удалось обновить ключ устройства в Keychain.")
        }
    }
}

struct DeviceRegistration: Decodable {
    let ok: Bool
    let device_id: String
    let device_token: String
    let limit: Int
}
struct AccessDeviceList: Decodable {
    let limit: Int
    let count: Int
    let devices: [AccessDevice]
}
struct AccessDevice: Identifiable, Decodable {
    let id: String
    let name: String
    let platform: String
    let current: Bool
    let blocked: Bool
}
struct AccountAccessStatus: Decodable {
    let premium: Bool
    let source: String
    let device_limit: Int
    let billing_owner: Bool
    let expires_at: Double?
}
struct AccessFamilyMember: Identifiable, Decodable {
    let account_id: String
    let role: String
    var id: String { account_id }
}
struct AccessPendingInvite: Identifiable, Decodable {
    let id: String
    let expires_at: Double
}
struct AccessFamily: Decodable {
    let role: String
    let members: [AccessFamilyMember]
    let pending_invites: [AccessPendingInvite]?
    let available_invites: Int?
    let active: Bool?
}
struct AccessFamilyState: Decodable {
    let family: AccessFamily?
    let access: AccountAccessStatus
}
struct AccessInvitation: Decodable {
    let invite_url: String
}
struct AccessJoined: Decodable {
    let family: AccessFamily
    let access: AccountAccessStatus
}

struct AccountAccessView: View {
    let api: MusicAPI
    let accountID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var devices: AccessDeviceList?
    @State private var family: AccessFamilyState?
    @State private var message = ""
    @State private var loading = false
    @State private var inviteInput = ""
    @State private var invitationURL: URL?
    @State private var pendingRemoval: AccessDevice?
    @State private var pendingMember: AccessFamilyMember?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if accountID == nil {
                        Text("Войди в аккаунт, чтобы управлять устройствами и семьёй.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                        if loading { ProgressView().tint(.white) }
                        if let devices {
                            GroupBox("Мои устройства · \(devices.count) из \(devices.limit)") {
                                VStack(alignment: .leading, spacing: 14) {
                                    ForEach(devices.devices) { device in
                                        HStack(spacing: 12) {
                                            Image(systemName: device.platform == "ios" ? "iphone" :
                                                  device.platform == "android" ? "apps.iphone" :
                                                  device.platform == "windows" ? "desktopcomputer" : "globe")
                                                .frame(width: 28)
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(device.name).font(.subheadline.weight(.medium))
                                                Text(device.blocked ? "Заблокировано лимитом" :
                                                     device.current ? "Это устройство" : device.platform.capitalized)
                                                    .font(.caption).foregroundStyle(device.blocked ? .orange : .secondary)
                                            }
                                            Spacer()
                                            if !device.current {
                                                Button(role: .destructive) { pendingRemoval = device } label: {
                                                    Image(systemName: "trash").padding(8)
                                                }.buttonStyle(.plain)
                                            }
                                        }
                                    }
                                }.padding(.vertical, 5)
                            }
                        }
                        if let state = family {
                            GroupBox("Семейный Premium") {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(state.access.premium ?
                                         (state.access.source == "family" ? "Premium через семью" : "Premium активен") :
                                         "Семейный Premium не активен")
                                        .font(.headline)
                                    Text("У каждого аккаунта своя музыка и свой лимит устройств.")
                                        .font(.footnote).foregroundStyle(.secondary)
                                    if let group = state.family {
                                        Text("Участники: \(group.members.count) из 3")
                                        ForEach(group.members) { member in
                                            HStack {
                                                Image(systemName: member.role == "owner" ? "crown" : "person")
                                                Text(member.account_id == accountID ? "Вы" : member.account_id)
                                                    .font(.caption)
                                                    .lineLimit(1)
                                                Spacer()
                                                if group.role == "owner" && member.role != "owner" {
                                                    Button("Исключить", role: .destructive) {
                                                        pendingMember = member
                                                    }.font(.caption)
                                                }
                                            }
                                        }
                                        if group.role == "owner" {
                                            Text("Свободных приглашений: \(group.available_invites ?? 0)")
                                                .font(.footnote).foregroundStyle(.secondary)
                                            Button("Создать приглашение") { Task { await createInvite() } }
                                                .disabled((group.available_invites ?? 0) < 1 || loading)
                                            if let url = invitationURL {
                                                ShareLink(item: url) {
                                                    Label("Отправить ссылку", systemImage: "square.and.arrow.up")
                                                }
                                            }
                                            ForEach(group.pending_invites ?? []) { item in
                                                HStack {
                                                    Text("Приглашение · до \(Date(timeIntervalSince1970: item.expires_at).formatted(date: .abbreviated, time: .omitted))")
                                                        .font(.caption)
                                                    Spacer()
                                                    Button("Отозвать", role: .destructive) {
                                                        Task { await act("api/family/invitations/" + item.id, method: "DELETE") }
                                                    }.font(.caption)
                                                }
                                            }
                                            Button("Распустить семью", role: .destructive) {
                                                Task { await act("api/family", method: "DELETE") }
                                            }
                                        } else {
                                            Button("Выйти из семьи", role: .destructive) {
                                                Task { await act("api/family/leave", method: "POST") }
                                            }
                                        }
                                    } else {
                                        if state.access.billing_owner {
                                            Button("Создать приглашение") { Task { await createInvite() } }
                                                .disabled(loading)
                                            if let url = invitationURL {
                                                ShareLink(item: url) {
                                                    Label("Отправить ссылку", systemImage: "square.and.arrow.up")
                                                }
                                            }
                                        }
                                        Text("Приглашение можно принять по ссылке от владельца Premium.")
                                            .font(.footnote).foregroundStyle(.secondary)
                                    }
                                    TextField("Ссылка или код приглашения", text: $inviteInput)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                        .textFieldStyle(.roundedBorder)
                                    Button("Принять приглашение") { Task { await acceptInvite() } }
                                        .disabled(inviteInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loading)
                                }.padding(.vertical, 5)
                            }
                        }
                    }
                }
                .padding(18)
            }
            .navigationTitle("Устройства и семья")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await refresh() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }.disabled(loading || accountID == nil)
                }
            }
            .task { await refresh() }
            .confirmationDialog("Удалить устройство?", isPresented: Binding(
                get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }
            )) {
                if let device = pendingRemoval {
                    Button("Удалить \(device.name)", role: .destructive) {
                        pendingRemoval = nil
                        Task { await act("api/devices/" + device.id, method: "DELETE") }
                    }
                }
            } message: { Text("Для повторного входа на удалённом устройстве потребуется авторизация.") }
            .confirmationDialog("Исключить участника?", isPresented: Binding(
                get: { pendingMember != nil }, set: { if !$0 { pendingMember = nil } }
            )) {
                if let member = pendingMember {
                    Button("Исключить", role: .destructive) {
                        pendingMember = nil
                        Task { await act("api/family/members/" + member.account_id, method: "DELETE") }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    @MainActor private func refresh() async {
        guard accountID != nil, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let registered: AccessDeviceList = try await api.request("api/devices")
            let current: AccessFamilyState = try await api.request("api/family")
            devices = registered
            family = current
            message = ""
        } catch {
            message = error.localizedDescription
        }
    }
    @MainActor private func act(_ path: String, method: String) async {
        guard !loading else { return }
        loading = true
        do {
            let _: OK = try await api.request(path, method: method)
            loading = false
            await refresh()
        } catch {
            loading = false
            message = error.localizedDescription
        }
    }
    @MainActor private func createInvite() async {
        guard !loading else { return }
        loading = true
        do {
            let result: AccessInvitation = try await api.request("api/family/invitations", method: "POST")
            invitationURL = URL(string: result.invite_url)
            loading = false
            await refresh()
        } catch {
            loading = false
            message = error.localizedDescription
        }
    }
    @MainActor private func acceptInvite() async {
        guard !loading else { return }
        let raw = inviteInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let token: String
        if let components = URLComponents(string: raw),
           let fragment = components.fragment, fragment.hasPrefix("invite=") {
            token = String(fragment.dropFirst("invite=".count))
        } else {
            token = raw
        }
        guard token.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil else {
            message = "Неверная ссылка приглашения."
            return
        }
        loading = true
        do {
            let _: AccessJoined = try await api.request("api/family/invitations/accept",
                                                         method: "POST", body: ["token": token])
            inviteInput = ""
            loading = false
            await refresh()
        } catch {
            loading = false
            message = error.localizedDescription
        }
    }
}
