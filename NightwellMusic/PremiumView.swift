import SwiftUI

private struct PremiumStatus: Decodable {
    let premium: Bool
    let test_premium: Bool
    let expires_at: Double?
}

// External website checkout for direct IPA distribution, not an App Store build.
struct PremiumView: View {
    let api: MusicAPI
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @State private var message = "Проверяем подписку…"
    @State private var consent = false
    @State private var checking = false
    @State private var activeExpiry: Double?
    @State private var showFeatures = false
    @State private var selectedDetent: PresentationDetent = .height(362)
    private var externalPayments: Bool { Bundle.main.object(forInfoDictionaryKey: "NWExternalPremiumPayments") as? Bool ?? true }

    var body: some View {
        Group {
            if let expiry = activeExpiry, expiry > Date().timeIntervalSince1970 {
                activeSheet(expiry: expiry)
            } else {
                inactiveSheet
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .fill(LinearGradient(colors: [nightwellViolet, Color.black], startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .padding(.horizontal, 8)
        .padding(.bottom, 8)
        .ignoresSafeArea(.container, edges: .bottom)
        .preferredColorScheme(.dark)
        .presentationBackground(.clear)
        .presentationDetents([.height(362), .large], selection: $selectedDetent)
        .presentationDragIndicator(.hidden)
        .task { await refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
    }

    private var handle: some View {
        Capsule().fill(.white.opacity(0.45)).frame(width: 57, height: 4).padding(.top, 10)
    }

    @ViewBuilder private func activeSheet(expiry: Double) -> some View {
        VStack(spacing: 0) {
            handle
            ScrollView(showsIndicators: false) {
                VStack(spacing: 16) {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(colors: [Color(red: 0.34, green: 0.96, blue: 0.52), Color.green], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 54, height: 54)
                            .shadow(color: Color.green.opacity(0.28), radius: 18, y: 6)
                        Image(systemName: "checkmark")
                            .font(.system(size: 32, weight: .bold))
                            .foregroundStyle(.black.opacity(0.78))
                    }
                    .padding(.top, 26)

                    VStack(spacing: 6) {
                        Text("Подписка активна")
                            .font(.system(size: 26, weight: .bold))
                            .multilineTextAlignment(.center)
                        Text("Активна до " + Date(timeIntervalSince1970: expiry).formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "ru_RU"))))
                            .foregroundStyle(.white.opacity(0.62))
                            .font(.system(size: 17, weight: .regular))
                    }

                    Button {
                        withAnimation(.spring(response: 0.36, dampingFraction: 0.85)) { showFeatures.toggle() }
                    } label: {
                        Label("Функции Premium", systemImage: "square.grid.2x2")
                            .font(.system(size: 17, weight: .regular))
                            .foregroundStyle(.white.opacity(0.88))
                            .frame(maxWidth: .infinity, minHeight: 49, alignment: .leading)
                            .padding(.horizontal, 18)
                    }
                    .buttonStyle(.plain)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .nightwellLiquidGlass(24)

                    if showFeatures {
                        VStack(alignment: .leading, spacing: 8) {
                            featureHint("arrow.down.circle", "Скачивания", "Откройте меню трека и нажмите «Скачать»." )
                            featureHint("slider.horizontal.3", "Эквалайзер", "Откройте три точки в большом плеере.")
                            featureHint("paintpalette", "Оформление", "Откройте «Настройки» в меню приложения.")
                            featureHint("music.note.list", "Умные плейлисты", "Откройте раздел «Плейлисты» и выберите «Умные плейлисты»." )
                            featureHint("chart.bar", "Статистика", "Откройте «Моя статистика» в меню приложения.")
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    Button(checking ? "Проверяем…" : "Обновить статус") {
                        Task { await refresh() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(Color.blue)
                    .disabled(checking)
                    .padding(.bottom, 8)
                }
                .padding(.horizontal, 23)
                .padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(
            LinearGradient(colors: [Color(red: 0.24, green: 0.10, blue: 0.40).opacity(0.92), Color.black.opacity(0.95)], startPoint: .topLeading, endPoint: .bottomTrailing)
        )
    }

    private var inactiveSheet: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                handle.frame(maxWidth: .infinity)
                Text("Nightwell Premium").font(.title2.bold())
                Text("150 ₽ за 30 дней. Без автопродления.").font(.headline)
                Text("Музыку можно слушать бесплатно. Premium открывает скачивания, эквалайзер с пресетами, оформление, умные плейлисты и статистику.")
                Text(message).accessibilityIdentifier("premium-status")
                DisclosureGroup("Условия Premium и реквизиты") {
                    Text(PremiumTerms.text).textSelection(.enabled).padding(.top, 10)
                }
                .padding(16)
                .nightwellLiquidGlass(24)
                Text("Колосов Михаил Владимирович\nИНН 780626105592\nnightwell.music@gmail.com")
                    .foregroundStyle(.white.opacity(0.82))
                Button {
                    consent.toggle()
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: consent ? "checkmark.square.fill" : "square").font(.title3)
                        Text("Я ознакомился с условиями Premium и согласен с оплатой на указанный срок").multilineTextAlignment(.leading)
                    }
                    .frame(minHeight: 44)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .nightwellLiquidGlass(24)
                Text("Оплата откроется на сайте в браузере. Войдите там в тот же аккаунт, что и в приложении, и подтвердите актуальные условия.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                Button("Перейти к оплате на сайте") {
                    let origin = api.origin
                    guard consent, externalPayments, origin.scheme == "https",
                          let url = URL(string: "/premium.html", relativeTo: origin)?.absoluteURL else { return }
                    openURL(url) { opened in if !opened { message = "Не удалось открыть браузер. Повторите попытку." } }
                }
                .buttonStyle(.borderedProminent)
                .tint(pumpkin)
                .disabled(!consent || !externalPayments)
                Button(checking ? "Проверяем…" : "Проверить оплату") { Task { await refresh() } }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                    .disabled(checking)
            }
            .padding(10)
        }
        .background(Color.clear)
    }

    @ViewBuilder private func featureHint(_ icon: String, _ title: String, _ hint: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).frame(width: 24).foregroundStyle(pumpkin)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(hint).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nightwellLiquidGlass(24)
    }

    @MainActor private func refresh() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--native-smoke-premium") {
            activeExpiry = 1824076800; return
        }
        #endif
        guard !checking else { return }
        checking = true
        defer { checking = false }
        do {
            let status: PremiumStatus = try await api.request("api/premium/me")
            activeExpiry = status.premium ? status.expires_at : nil
            if status.premium, let expiry = status.expires_at {
                message = "Premium активен до " + Date(timeIntervalSince1970: expiry).formatted(date: .abbreviated, time: .omitted)
            } else if status.test_premium {
                message = "Тестовый платёж подтверждён. Платная подписка не активирована."
            } else {
                message = "Активной подписки нет."
            }
        } catch {
            activeExpiry = nil
            message = "Статус недоступен. Войдите в аккаунт и проверьте соединение."
        }
    }
}
