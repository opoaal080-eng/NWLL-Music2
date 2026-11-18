import SwiftUI
import UIKit
import WidgetKit
import AppIntents

private struct NWWidgetPairCode: Decodable {
    let code: String
    let expires_in: Int
}
private struct NWWidgetAccessResponse: Decodable { let token: String }
private struct NWWidgetReadback: Decodable {
    let track_id: String
    let title: String
    let artist: String
    let has_cover: Bool
}

/// A one-time pairing flow. The user copies the code from their account
/// into the widget's own "Edit Widget" configuration on the home screen.
/// No App Group entitlement, shared cookie, or Apple ID is required.
struct NWWidgetSetupView: View {
    @Environment(\.nightwellAppearance) private var appearance
    @EnvironmentObject private var store: MusicStore
    @Environment(\.dismiss) private var dismiss
    let api: MusicAPI

    @State private var code = ""
    @State private var notice = ""
    @State private var busy = false
    @State private var copied = false
    @State private var revokeConfirmation = false
    @State private var configurationStatus = "Проверка ещё не выполнена"

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 9) {
                        Image(systemName: "square.grid.2x2")
                            .font(.system(size: 34, weight: .medium))
                            .foregroundStyle(.white)
                            .frame(width: 58, height: 58)
                            .background(.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 17))
                        Text("Виджеты Nightwell Music")
                            .font(.system(size: 26, weight: .bold))
                        Text("Показывай текущий трек, обложку и исполнителя на главном экране и экране блокировки iPhone.")
                            .font(.subheadline).foregroundStyle(.white.opacity(0.67))
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Привязка к аккаунту").font(.headline)
                        Text("Создай ключ NW2, удали старый виджет и добавь новый «Сейчас играет». Зажми его и вставь ключ в поле «Ключ доступа».")
                            .font(.subheadline).foregroundStyle(.white.opacity(0.72))
                        if !code.isEmpty {
                            Text(code)
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .tracking(0.5)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity)
                                .padding(14)
                                .background(.white.opacity(0.07),
                                            in: RoundedRectangle(cornerRadius: 14))
                            Button {
                                UIPasteboard.general.string = code
                                copied = true
                            } label: {
                                Label(copied ? "Скопировано" : "Скопировать ключ",
                                      systemImage: copied ? "checkmark" : "doc.on.doc")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            Text("Ключ действует до отзыва доступа и разрешает только чтение текущего трека. Не передавай его другим.")
                                .font(.caption).foregroundStyle(.white.opacity(0.61))
                        }
                        Button {
                            Task { await createCode() }
                        } label: {
                            HStack {
                                if busy { ProgressView().tint(.black) }
                                Text(busy ? "Получаем ключ…" : code.isEmpty ? "Создать ключ доступа" : "Создать новый ключ")
                            }
                            .font(.system(size: 15, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(appearance.accent)
                        .foregroundStyle(.black)
                        .disabled(busy || store.account == nil)
                    }
                    .padding(17)
                    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 21))

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Диагностика").font(.headline)
                        Text(configurationStatus).font(.subheadline)
                        Button {
                            Task { await inspectConfiguration() }
                        } label: {
                            Label("Проверить настройки виджета", systemImage: "stethoscope")
                        }.buttonStyle(.bordered)
                        Button {
                            Task {
                                await NWWidgetServerPublisher.shared.publishForPairing(
                                    track: store.clock.current, playing: store.clock.playing,
                                    account: store.account?.id, api: api, origin: store.origin)
                                NWWidgetConfiguration.reload()
                                await inspectConfiguration()
                            }
                        } label: {
                            Label("Обновить данные виджета", systemImage: "arrow.clockwise")
                        }.buttonStyle(.bordered)
                    }
                    .padding(17)
                    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 21))

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Управление доступом").font(.headline)
                        Text("Виджет получает только название трека, исполнителя, состояние воспроизведения и небольшую обложку. Он не получает пароль или данные подписки.")
                            .font(.caption).foregroundStyle(.white.opacity(0.66))
                        Button(role: .destructive) {
                            revokeConfirmation = true
                        } label: {
                            Label("Отключить все привязанные виджеты", systemImage: "xmark.shield")
                                .font(.subheadline.weight(.medium))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .disabled(busy || store.account == nil)
                    }
                    .padding(17)
                    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 21))

                    if !notice.isEmpty {
                        Text(notice)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                }
                .padding(20)
            }
            .background {
                NightwellThemedBackground { Color(white: 0.045) }.ignoresSafeArea()
            }
            .tint(appearance.accent)
            .navigationTitle("Виджеты")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { dismiss() }
                }
            }
            .confirmationDialog("Отключить все виджеты?", isPresented: $revokeConfirmation) {
                Button("Отключить", role: .destructive) { Task { await revoke() } }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Все ранее подключённые виджеты потеряют доступ, пока ты не создашь новый код.")
            }
        }
        .preferredColorScheme(.dark)
        .task { await inspectConfiguration() }
    }

    @MainActor private func inspectConfiguration() async {
        guard #available(iOS 18.0, *) else {
            configurationStatus = "Проверка сохранённого ключа доступна с iOS 18. На iOS 17 проверь поле ключа в настройках виджета."
            return
        }
        do {
            let widgets = try await WidgetCenter.shared.currentConfigurations()
            let latest = widgets.filter { $0.kind == NWWidgetConfiguration.kind }
            let legacy = widgets.filter { $0.kind == NWWidgetConfiguration.legacyKind }
            let valid = latest.filter {
                let intent = $0.widgetConfigurationIntent(of: NWNowPlayingConfigurationV2.self)
                return NWWidgetConfiguration.accessToken(intent?.accessKey) != nil
            }.count
            configurationStatus = "Новых виджетов: \(latest.count). Сохранён ключ: \(valid). Старых виджетов: \(legacy.count)."
        } catch {
            configurationStatus = "Ошибка чтения конфигураций iOS: " + error.localizedDescription
        }
    }

    @MainActor private func createCode() async {
        busy = true
        notice = ""
        defer { busy = false }
        do {
            let result: NWWidgetPairCode = try await api.request(
                "/api/widgets/pair-code", method: "POST", body: [:], timeout: 12)
            let access: NWWidgetAccessResponse = try await api.request(
                "/api/widgets/pair", method: "POST", body: ["code": result.code], timeout: 12)
            let key = "NW2." + access.token
            guard NWWidgetConfiguration.accessToken(key) != nil else {
                throw URLError(.cannotParseResponse)
            }
            copied = false
            notice = "Ключ создан. Проверяем получение трека через сервер."
            await NWWidgetServerPublisher.shared.publishForPairing(
                track: store.clock.current, playing: store.clock.playing,
                account: store.account?.id, api: api, origin: store.origin
            )
            var request = URLRequest(url: store.origin.appendingPathComponent("api/widgets/state"))
            request.setValue("Bearer " + access.token, forHTTPHeaderField: "Authorization")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            request.timeoutInterval = 12
            let config = URLSessionConfiguration.ephemeral
            config.httpShouldSetCookies = false
            let session = URLSession(configuration: config)
            defer { session.finishTasksAndInvalidate() }
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                notice = "Сервер не принял ключ: HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)."
                return
            }
            let remote = try JSONDecoder().decode(NWWidgetReadback.self, from: data)
            code = key
            notice = remote.track_id.isEmpty
                ? "Ключ проверен, но текущий трек отсутствует на сервере."
                : "Сервер подтвердил ключ и вернул трек: " + remote.title + " — " + remote.artist
            NWWidgetConfiguration.reload()
            await inspectConfiguration()
        } catch {
            if let failure = error as? RequestRetry.HTTPFailure, failure.status == 404 {
                notice = "Серверный модуль виджетов пока не установлен."
            } else {
                notice = "Не удалось создать или проверить ключ: " + error.localizedDescription
            }
        }
    }

    @MainActor private func revoke() async {
        busy = true
        notice = ""
        defer { busy = false }
        do {
            let _: OK = try await api.request("/api/widgets/revoke-all",
                                             method: "POST", body: [:], timeout: 12)
            code = ""
            notice = "Доступ всех виджетов отозван."
            NWWidgetConfiguration.reload()
        } catch {
            notice = "Не удалось отключить виджеты: " + error.localizedDescription
        }
    }
}
