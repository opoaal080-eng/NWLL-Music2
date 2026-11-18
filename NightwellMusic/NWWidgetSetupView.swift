import SwiftUI
import UIKit
import WidgetKit

/// The widget generates its own private credential. No configuration
/// parameter, shared container, or bearer token is copied by the user.
struct NWWidgetSetupView: View {
    @Environment(\.nightwellAppearance) private var appearance
    @EnvironmentObject private var store: MusicStore
    @Environment(\.dismiss) private var dismiss
    let api: MusicAPI
    let initialCode: String?

    @State private var code = ""
    @State private var notice = ""
    @State private var busy = false
    @State private var revokeConfirmation = false
    @State private var status = "Проверка ещё не выполнена"

    private var normalized: String {
        code.uppercased().filter { $0.isASCII && $0.isHexDigit }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Label("Виджеты Nightwell Music", systemImage: "square.grid.2x2")
                        .font(.system(size: 25, weight: .bold))
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Подключить виджет").font(.headline)
                        Text("Добавь виджет «Сейчас играет» и нажми на него. Nightwell Music откроет это окно с уже вставленным кодом, а также скопирует его. Вводить символы вручную не нужно.")
                            .font(.subheadline).foregroundStyle(.white.opacity(0.72))
                        TextField("XXXX-XXXX-XXXX-XXXX", text: $code)
                            .font(.system(size: 17, weight: .semibold, design: .monospaced))
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .padding(13)
                            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                        Button {
                            Task { await connectWidget() }
                        } label: {
                            HStack {
                                if busy { ProgressView().tint(.black) }
                                Text(busy ? "Подключаем…" : "Подключить")
                            }
                            .font(.system(size: 15, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(appearance.accent).foregroundStyle(.black)
                        .disabled(busy || store.account == nil || normalized.count != 16)
                        Text("Код действует 15 минут. Сам ключ доступа остаётся внутри виджета и не отображается.")
                            .font(.caption).foregroundStyle(.white.opacity(0.62))
                    }
                    .padding(17)
                    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 21))
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Диагностика").font(.headline)
                        Text(status).font(.subheadline)
                        Button {
                            Task { await refresh() }
                        } label: {
                            Label("Обновить данные виджета", systemImage: "arrow.clockwise")
                        }.buttonStyle(.bordered)
                        Text("iOS сама выбирает момент перерисовки виджета. Запрос обновления не гарантирует мгновенную смену трека.")
                            .font(.caption).foregroundStyle(.white.opacity(0.65))
                    }
                    .padding(17)
                    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 21))
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Управление доступом").font(.headline)
                        Text("Виджет получает только название трека, исполнителя, состояние воспроизведения и обложку.")
                            .font(.caption).foregroundStyle(.white.opacity(0.66))
                        Button(role: .destructive) {
                            revokeConfirmation = true
                        } label: {
                            Label("Отключить все привязанные виджеты", systemImage: "xmark.shield")
                        }
                        .disabled(busy || store.account == nil)
                    }
                    .padding(17)
                    .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 21))
                    if !notice.isEmpty {
                        Text(notice).font(.subheadline).foregroundStyle(.white.opacity(0.85))
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
                ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } }
            }
            .confirmationDialog("Отключить все виджеты?", isPresented: $revokeConfirmation) {
                Button("Отключить", role: .destructive) { Task { await revoke() } }
                Button("Отмена", role: .cancel) {}
            } message: {
                Text("Все ранее подключённые виджеты потеряют доступ.")
            }
        }
        .preferredColorScheme(.dark)
        .task {
            if let initialCode, !initialCode.isEmpty {
                code = initialCode
                notice = "Код автоматически перенесён из виджета. Нажми «Подключить»."
            }
            await inspect()
        }
        .onChange(of: initialCode) { _, next in
            if let next, !next.isEmpty { code = next }
        }
    }

    @MainActor private func inspect() async {
        guard #available(iOS 18.0, *) else {
            status = "Проверка количества виджетов доступна с iOS 18."
            return
        }
        do {
            let configs = try await WidgetCenter.shared.currentConfigurations()
            let latest = configs.filter { $0.kind == NWWidgetConfiguration.kind }.count
            let old = configs.filter {
                $0.kind == NWWidgetConfiguration.previousKind || $0.kind == NWWidgetConfiguration.legacyKind
            }.count
            status = "Новых виджетов: \(latest). Старых: \(old)."
        } catch { status = "Ошибка диагностики iOS: " + error.localizedDescription }
    }

    @MainActor private func refresh() async {
        await NWWidgetServerPublisher.shared.publishForPairing(
            track: store.clock.current, playing: store.clock.playing,
            account: store.account?.id, api: api, origin: store.origin)
        NWWidgetConfiguration.reload()
        await inspect()
    }

    @MainActor private func connectWidget() async {
        busy = true
        notice = ""
        defer { busy = false }
        do {
            let _: OK = try await api.request("/api/widgets/device/claim",
                method: "POST", body: ["code": normalized], timeout: 12)
            code = ""
            await refresh()
            notice = "Сервер подтвердил подключение. Виджету отправлен запрос обновления."
        } catch {
            if let failure = error as? RequestRetry.HTTPFailure, failure.status == 404 {
                notice = "Обнови серверный модуль до V3."
            } else {
                notice = "Не удалось подключить: " + error.localizedDescription
            }
        }
    }

    @MainActor private func revoke() async {
        busy = true
        defer { busy = false }
        do {
            let _: OK = try await api.request("/api/widgets/revoke-all",
                method: "POST", body: [:], timeout: 12)
            code = ""
            notice = "Доступ всех виджетов отозван."
            NWWidgetConfiguration.reload()
        } catch { notice = error.localizedDescription }
    }
}
