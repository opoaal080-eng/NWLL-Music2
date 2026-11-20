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
    let device_id: String?
    let device_token: String?
    let limit: Int?
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
    @State private var confirmDissolve = false
    @State private var confirmLeave = false

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 17) {
                    if accountID == nil {
                        Text("Войди в аккаунт, чтобы управлять устройствами и семьёй.")
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.75))
                            .padding(18)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .nightwellMonochromeGlass(radius: 25)
                    } else {
                        if !message.isEmpty {
                            Label(message, systemImage: "info.circle")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.83))
                                .padding(15)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .nightwellMonochromeGlass(radius: 18)
                        }
                        devicesSection
                        familySection
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
            // An independent header avoids iOS 27 compressing or clipping
            // custom glass buttons inside NavigationStack toolbar slots.
            .safeAreaInset(edge: .top, spacing: 0) {
                ZStack {
                    Text("Устройства и семья")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, 58)
                    HStack {
                        Button { dismiss() } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 46, height: 46)
                                .nightwellMonochromeGlass(radius: 23)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Закрыть")
                        Spacer(minLength: 0)
                        Button { Task { await refresh() } } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 46, height: 46)
                                .nightwellMonochromeGlass(radius: 23)
                        }
                        .buttonStyle(.plain)
                        .disabled(loading || accountID == nil)
                        .opacity(loading || accountID == nil ? 0.55 : 1)
                        .accessibilityLabel("Обновить устройства и семью")
                    }
                }
                .frame(height:54)
                .padding(.horizontal,18)
                .padding(.vertical,7)
                .background(.black.opacity(0.16))
            }
            .background { NightwellMonochromeGlassBackground() }
            .toolbar(.hidden, for: .navigationBar)
            .task { await refresh() }
            .confirmationDialog("Удалить устройство?", isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            )) {
                if let device = pendingRemoval {
                    Button("Удалить " + device.name, role: .destructive) {
                        pendingRemoval = nil
                        Task { await act("api/devices/" + device.id, method: "DELETE") }
                    }
                }
                Button("Отмена", role: .cancel) { pendingRemoval = nil }
            } message: {
                Text("Для повторного входа на удалённом устройстве потребуется авторизация.")
            }
            .confirmationDialog("Исключить участника?", isPresented: Binding(
                get: { pendingMember != nil },
                set: { if !$0 { pendingMember = nil } }
            )) {
                if let member = pendingMember {
                    Button("Исключить из семьи", role: .destructive) {
                        pendingMember = nil
                        Task { await act("api/family/members/" + member.account_id, method: "DELETE") }
                    }
                }
                Button("Отмена", role: .cancel) { pendingMember = nil }
            } message: {
                Text("Участник потеряет доступ к семейному Premium.")
            }
            .confirmationDialog("Распустить семью?", isPresented: $confirmDissolve) {
                Button("Распустить семью", role: .destructive) {
                    Task { await act("api/family", method: "DELETE") }
                }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Все приглашённые участники потеряют семейный Premium.")
            }
            .confirmationDialog("Выйти из семьи?", isPresented: $confirmLeave) {
                Button("Выйти из семьи", role: .destructive) {
                    Task { await act("api/family/leave", method: "POST") }
                }
                Button("Отмена", role: .cancel) {}
            }
        }
        .tint(.white)
        .preferredColorScheme(.dark)
    }

    private func heading(_ text: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .frame(width: 28)
                .foregroundStyle(.white.opacity(0.87))
            Text(text)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.white)
            Spacer(minLength: 0)
        }
    }

    private func actionLabel(_ title: String, icon: String, destructive: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 23)
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .multilineTextAlignment(.leading)
            Spacer(minLength: 0)
        }
        .foregroundStyle(destructive ? Color(red: 1.0, green: 0.55, blue: 0.55) : .white)
        .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
        .padding(.horizontal, 14)
        .nightwellMonochromeGlass(radius: 17)
    }

    private func action(_ title: String, icon: String, disabled: Bool = false,
                        destructive: Bool = false, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            actionLabel(title, icon: icon, destructive: destructive)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1.0)
    }

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 15) {
            heading("Мои устройства", icon: "iphone.and.arrow.forward")
            if let devices {
                Text("Подключено: \(devices.count) из \(devices.limit)")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.62))
                if devices.devices.isEmpty {
                    Text("Пока нет привязанных устройств.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.66))
                } else {
                    ForEach(devices.devices) { device in
                        deviceRow(device)
                    }
                }
            } else if loading {
                ProgressView("Загружаем устройства")
                    .tint(.white)
                    .foregroundStyle(.white.opacity(0.75))
            } else {
                Text("Список устройств пока недоступен.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nightwellMonochromeGlass(radius: 25)
    }

    private func deviceRow(_ device: AccessDevice) -> some View {
        HStack(spacing: 12) {
            Image(systemName: device.platform == "ios" ? "iphone" :
                  device.platform == "android" ? "apps.iphone" :
                  device.platform == "windows" ? "desktopcomputer" : "globe")
                .font(.system(size: 19))
                .frame(width: 30)
                .foregroundStyle(.white.opacity(0.85))
            VStack(alignment: .leading, spacing: 4) {
                Text(device.name)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(device.blocked ? "Заблокировано лимитом" :
                     device.current ? "Это устройство" : device.platform.capitalized)
                    .font(.system(size: 12))
                    .foregroundStyle(device.blocked ? Color.orange : .white.opacity(0.58))
            }
            Spacer(minLength: 8)
            if !device.current {
                Button { pendingRemoval = device } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 16))
                        .foregroundStyle(.white.opacity(0.88))
                        .frame(width: 40, height: 40)
                        .nightwellMonochromeGlass(radius: 14)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Удалить устройство " + device.name)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(12)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var familySection: some View {
        VStack(alignment: .leading, spacing: 15) {
            heading("Семейный Premium", icon: "person.2")
            if let state = family {
                HStack(spacing: 10) {
                    Image(systemName: state.access.premium ? "checkmark.seal.fill" : "star")
                        .foregroundStyle(.white.opacity(0.88))
                    Text(state.access.premium ?
                         (state.access.source == "family" ? "Premium через семью" : "Premium активен") :
                         "Семейный Premium не активен")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .padding(.vertical, 4)
                Text("У каждого аккаунта своя музыка, плейлисты и лимит устройств.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.63))
                    .fixedSize(horizontal: false, vertical: true)

                if let group = state.family {
                    membersSection(group)
                    if group.role == "owner" {
                        ownerActions(group)
                    } else {
                        action("Выйти из семьи", icon: "rectangle.portrait.and.arrow.right",
                               disabled: loading, destructive: true) {
                            confirmLeave = true
                        }
                    }
                } else {
                    if state.access.billing_owner {
                        action("Создать приглашение", icon: "person.badge.plus",
                               disabled: loading) { Task { await createInvite() } }
                        shareInvitation
                    }
                    invitationEntry
                }
            } else if loading {
                ProgressView("Загружаем семейный Premium")
                    .tint(.white)
                    .foregroundStyle(.white.opacity(0.75))
            } else {
                Text("Данные семейной подписки пока недоступны.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.65))
            }
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nightwellMonochromeGlass(radius: 25)
    }

    private func membersSection(_ group: AccessFamily) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Участники · \(group.members.count) из 3")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.74))
                .padding(.top, 5)
            ForEach(group.members) { member in
                HStack(spacing: 11) {
                    Image(systemName: member.role == "owner" ? "crown" : "person.crop.circle")
                        .font(.system(size: 18))
                        .frame(width: 27)
                    Text(member.account_id == accountID ? "Вы" : member.account_id)
                        .font(.system(size: 14, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 8)
                    if group.role == "owner" && member.role != "owner" {
                        Button { pendingMember = member } label: {
                            Image(systemName: "person.crop.circle.badge.minus")
                                .font(.system(size: 17))
                                .frame(width: 40, height: 40)
                                .nightwellMonochromeGlass(radius: 14)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Исключить участника")
                    }
                }
                .foregroundStyle(.white.opacity(0.9))
                .padding(11)
                .background(.white.opacity(0.045),
                            in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
        }
    }

    private func ownerActions(_ group: AccessFamily) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Свободных приглашений: \(group.available_invites ?? 0)")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.65))
            action("Создать приглашение", icon: "person.badge.plus",
                   disabled: (group.available_invites ?? 0) < 1 || loading) {
                Task { await createInvite() }
            }
            shareInvitation
            ForEach(group.pending_invites ?? []) { invite in
                HStack(spacing: 10) {
                    Image(systemName: "envelope")
                        .frame(width: 25)
                    Text("Действует до " + Date(timeIntervalSince1970: invite.expires_at)
                        .formatted(date: .abbreviated, time: .omitted))
                        .font(.system(size: 12))
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Button {
                        Task { await act("api/family/invitations/" + invite.id, method: "DELETE") }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 38, height: 38)
                            .nightwellMonochromeGlass(radius: 13)
                    }
                    .buttonStyle(.plain)
                    .disabled(loading)
                    .accessibilityLabel("Отозвать приглашение")
                }
                .foregroundStyle(.white.opacity(0.82))
                .padding(10)
                .background(.white.opacity(0.045),
                            in: RoundedRectangle(cornerRadius: 17, style: .continuous))
            }
            action("Распустить семью", icon: "person.2.slash",
                   disabled: loading, destructive: true) {
                confirmDissolve = true
            }
        }
    }

    @ViewBuilder private var shareInvitation: some View {
        if let url = invitationURL {
            ShareLink(item: url) {
                actionLabel("Поделиться приглашением", icon: "square.and.arrow.up")
            }
            .buttonStyle(.plain)
        }
    }

    private var invitationEntry: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Присоединиться по приглашению")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.78))
            TextField("Ссылка или код приглашения", text: $inviteInput)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .tint(.white)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.plain)
                .padding(.horizontal, 15)
                .frame(minHeight: 51)
                .nightwellMonochromeGlass(radius: 17)
            action("Принять приглашение", icon: "checkmark.circle",
                   disabled: loading || inviteInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                Task { await acceptInvite() }
            }
        }
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
