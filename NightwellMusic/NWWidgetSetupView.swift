import SwiftUI
import UIKit
import WidgetKit

private struct NWWidgetPairCode: Decodable {
    let code: String
    let expires_in: Int
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
                        Text("Создай одноразовый код, затем зажми виджет «Сейчас играет», нажми «Изменить виджет» и вставь код в поле «Код привязки».")
                            .font(.subheadline).foregroundStyle(.white.opacity(0.72))
                        if !code.isEmpty {
                            Text(code)
                                .font(.system(size: 20, weight: .semibold, design: .monospaced))
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
                                Label(copied ? "Скопировано" : "Скопировать код",
                                      systemImage: copied ? "checkmark" : "doc.on.doc")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            Text("Код действует 10 минут и используется один раз. После подключения виджету не потребуется повторный ввод.")
                                .font(.caption).foregroundStyle(.white.opacity(0.61))
                        }
                        Button {
                            Task { await createCode() }
                        } label: {
                            HStack {
                                if busy { ProgressView().tint(.black) }
                                Text(busy ? "Получаем код…" : code.isEmpty ? "Создать код привязки" : "Создать новый код")
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
    }

    @MainActor private func createCode() async {
        busy = true
        notice = ""
        defer { busy = false }
        do {
            let result: NWWidgetPairCode = try await api.request(
                "/api/widgets/pair-code", method: "POST", body: [:], timeout: 12)
            code = result.code
            copied = false
            notice = "Код готов. Добавь виджет, зажми его и выбери «Изменить виджет». Вставь код в поле привязки."
            await NWWidgetServerPublisher.shared.publishForPairing(
                track: store.clock.current, playing: store.clock.playing,
                account: store.account?.id, api: api, origin: store.origin
            )
            if let track = store.clock.current {
                let status = NWWidgetServerPublisher.shared.hasPublished(track: track, account: store.account?.id, origin: store.origin)
                notice += status ? "\nТекущий трек передан серверу." : "\nНе удалось подтвердить передачу трека. Проверь соединение с сервером."
            }
        } catch {
            if let failure = error as? RequestRetry.HTTPFailure, failure.status == 404 {
                notice = "Серверный модуль виджетов пока не установлен."
            } else {
                notice = "Не удалось создать код: " + error.localizedDescription
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
            WidgetCenter.shared.reloadTimelines(ofKind: "nightwell.nowplaying")
        } catch {
            notice = "Не удалось отключить виджеты: " + error.localizedDescription
        }
    }
}
