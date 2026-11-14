import Foundation
import SwiftUI
import Security
import UIKit

struct NightwellDevice: Decodable, Identifiable {
    let device_id: String
    let name: String
    let platform: String
    let created_at: Int
    let last_seen: Int
    let current: Bool
    let enabled: Bool
    var id: String { device_id }
}

struct NightwellDeviceList: Decodable {
    let devices: [NightwellDevice]
    let limit: Int
    let count: Int
    let premium: Bool
}

/// Random, app-specific identity. Stored in Keychain, which normally survives
/// reinstalls on the same iPhone. Never expose hardware IDs or the Apple ID.
enum NightwellDeviceIdentity {
    private static let service = "fun.nightwell.music.device"
    private static let account = "account-device-id"

    static var id: String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data,
           let saved = String(data: data, encoding: .utf8),
           saved.hasPrefix("ios_"), saved.count < 130 {
            return saved
        }
        if let saved = UserDefaults.standard.string(forKey: service),
           saved.hasPrefix("ios_") { return saved }
        let created = "ios_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(created.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        SecItemAdd(add as CFDictionary, nil)
        UserDefaults.standard.set(created, forKey: service)
        return created
    }

    @MainActor static func register(using api: MusicAPI) async throws -> NightwellDeviceList {
        try await api.request("api/devices/register", method: "POST", body: [
            "device_id": id,
            "name": String(UIDevice.current.name.prefix(80)),
            "platform": "ios"
        ], timeout: 10)
    }
}

@MainActor
struct NightwellDevicesView: View {
    @EnvironmentObject private var store: MusicStore
    @Environment(\.dismiss) private var dismiss
    @State private var list: NightwellDeviceList?
    @State private var message = ""
    @State private var busy = false
    @State private var removeID: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let list {
                        Text("Подключено устройств: \(list.count) из \(list.limit)")
                            .font(.headline)
                        Text(list.premium ? "Лимит по активной подписке: 5 устройств." :
                                             "Без подписки доступно 2 устройства. С Premium до 5.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        ForEach(list.devices) { device in
                            HStack(spacing: 12) {
                                Image(systemName: device.platform == "ios" ? "iphone" :
                                      device.platform == "android" ? "smartphone" :
                                      device.platform == "windows" ? "desktopcomputer" : "globe")
                                    .font(.title3).frame(width: 30)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(device.name).font(.body.weight(.medium))
                                    Text(device.current ? "Это устройство" :
                                         device.enabled ? "Подключено" : "Лимит превышен")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(Date(timeIntervalSince1970: TimeInterval(device.last_seen))
                                        .formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Отключить", role: .destructive) { removeID = device.device_id }
                                    .font(.caption)
                                    .disabled(busy)
                            }
                            .padding(14)
                            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 17))
                        }
                    } else if busy {
                        ProgressView("Загружаем устройства…")
                    }
                    if !message.isEmpty {
                        Text(message).font(.footnote).foregroundStyle(.orange)
                    }
                }
                .padding(18)
            }
            .navigationTitle("Мои устройства")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
            .task(id: store.account?.id) { await load() }
            .confirmationDialog("Отключить устройство от аккаунта?",
                                isPresented: Binding(get: { removeID != nil },
                                                     set: { if !$0 { removeID = nil } })) {
                Button("Отключить", role: .destructive) {
                    guard let id = removeID else { return }
                    removeID = nil
                    Task { await remove(id) }
                }
                Button("Отмена", role: .cancel) { removeID = nil }
            } message: {
                Text("Сеансы этого устройства будут завершены. Для нового входа понадобится свободное место.")
            }
        }
        .preferredColorScheme(.dark)
    }

    private func load() async {
        guard store.account != nil else { return }
        busy = true
        defer { busy = false }
        do {
            let fetched: NightwellDeviceList = try await store.api.request("api/devices", timeout: 10)
            list = fetched
            message = ""
        } catch {
            message = (error as? RequestRetry.HTTPFailure)?.status == 404
                ? "Сервер ещё не поддерживает управление устройствами."
                : error.localizedDescription
        }
    }

    private func remove(_ id: String) async {
        busy = true
        defer { busy = false }
        do {
            let _: DeviceRemovalResult = try await store.api.request(
                "api/devices/" + id, method: "DELETE")
            if id == NightwellDeviceIdentity.id {
                message = "Это устройство отключено. Войди в аккаунт заново."
                list = nil
            } else {
                await load()
            }
        } catch {
            message = error.localizedDescription
        }
    }

    private struct DeviceRemovalResult: Decodable { let ok: Bool }
}
