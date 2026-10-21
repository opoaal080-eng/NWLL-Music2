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
    @State private var selectedDetent: PresentationDetent = .height(370)
    private var externalPayments: Bool { Bundle.main.object(forInfoDictionaryKey: "NWExternalPremiumPayments") as? Bool ?? true }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let expiry = activeExpiry, expiry > Date().timeIntervalSince1970 {
                    activeContent(expiry: expiry)
                } else {
                Text("Nightwell Premium").font(.title2.bold())
                Text("150 ₽ за 30 дней. Без автопродления.").font(.headline)
                Text("Музыку можно слушать бесплатно. Premium открывает скачивания, эквалайзер с пресетами, оформление, умные плейлисты и статистику. Эквалайзер — в трёх точках плеера; оформление — в настройках; умные подборки — в плейлистах; статистика — в меню.")
                Text(message).accessibilityIdentifier("premium-status")
                DisclosureGroup("Условия Premium и реквизиты") {
                    Text(PremiumTerms.text).textSelection(.enabled).padding(.top, 10)
                }
                Text("Колосов Михаил Владимирович\nИНН 780626105592\nnightwell.music@gmail.com")
                Button { consent.toggle() } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: consent ? "checkmark.square.fill" : "square").font(.title3)
                        Text("Я ознакомился с условиями Premium и согласен с оплатой на указанный срок").multilineTextAlignment(.leading)
                    }.frame(minHeight: 44)
                }.buttonStyle(.plain).accessibilityIdentifier("premium-consent")
                    .accessibilityValue(consent ? "Отмечено" : "Не отмечено")
                Text("Оплата откроется на сайте в браузере. Войдите там в тот же аккаунт, что и в приложении, и подтвердите актуальные условия. Доступность оплаты проверяется на сайте.").font(.footnote)
                Button("Перейти к оплате на сайте") {
                    let origin = api.origin
                    guard consent, externalPayments, origin.scheme == "https",
                          let url = URL(string: "/premium.html", relativeTo: origin)?.absoluteURL else { return }
                    openURL(url) { opened in
                        if !opened { message = "Не удалось открыть браузер. Повторите попытку." }
                    }
                }.disabled(!consent || !externalPayments).accessibilityIdentifier("premium-pay")
                if !externalPayments { Text("Внешняя оплата отключена в этой сборке.").font(.footnote) }
                Button(checking ? "Проверяем…" : "Проверить оплату") { Task { await refresh() } }
                    .disabled(checking)
                Text("Возврат из браузера сам по себе не подтверждает оплату. Статус проверяет сервер.").font(.footnote)
                }
            }.padding(24)
        }.background(LinearGradient(colors: [nightwellViolet, Color.black], startPoint: .topLeading, endPoint: .bottomTrailing))
        .preferredColorScheme(.dark)
        .presentationDetents([.height(370), .height(620), .large], selection: $selectedDetent)
        .onChange(of: activeExpiry) { _, expiry in selectedDetent = expiry == nil ? .large : .height(370) }
        .onChange(of: showFeatures) { _, expanded in if activeExpiry != nil { selectedDetent = .height(expanded ? 620 : 370) } }
        .presentationDragIndicator(.visible)
        .task { await refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
    }
    @ViewBuilder private func activeContent(expiry: Double) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56, weight: .medium))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: activeExpiry)
                .accessibilityLabel("Подписка подтверждена")
            Text("Подписка активна").font(.title.bold()).multilineTextAlignment(.center)
            Text("Активна до " + Date(timeIntervalSince1970: expiry).formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "ru_RU"))))
                .foregroundStyle(.secondary)
            Button { withAnimation(.spring(response: 0.38, dampingFraction: 0.85)) { showFeatures.toggle() } } label: {
                Label("Функции Premium", systemImage: "square.grid.2x2")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain).padding(16).nightwellLiquidGlass(24)
            if showFeatures {
                VStack(alignment: .leading, spacing: 12) {
                    featureHint("arrow.down.circle", "Скачивания", "Откройте меню трека и нажмите «Скачать».")
                    featureHint("slider.horizontal.3", "Эквалайзер", "Откройте три точки в большом плеере.")
                    featureHint("paintpalette", "Оформление", "Откройте «Настройки» в меню приложения.")
                    featureHint("music.note.list", "Умные плейлисты", "Откройте раздел «Плейлисты» и выберите «Умные плейлисты».")
                    featureHint("chart.bar", "Статистика", "Откройте «Моя статистика» в меню приложения.")
                }.transition(.opacity.combined(with: .move(edge: .top)))
            }
            Button(checking ? "Проверяем…" : "Обновить статус") { Task { await refresh() } }.disabled(checking)
        }.frame(maxWidth: .infinity).padding(.vertical, 8)
    }
    @ViewBuilder private func featureHint(_ icon: String, _ title: String, _ hint: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).frame(width: 24).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(hint).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).nightwellLiquidGlass(24)
    }
    @MainActor private func refresh() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        do {
            let status: PremiumStatus = try await api.request("api/premium/me")
            activeExpiry = status.premium ? status.expires_at : nil
            selectedDetent = activeExpiry == nil ? .large : .height(showFeatures ? 620 : 370)
            if status.premium, let expiry = status.expires_at {
                message = "Premium активен до " + Date(timeIntervalSince1970: expiry).formatted(date: .abbreviated, time: .omitted)
            } else if status.test_premium {
                message = "Тестовый платёж подтверждён. Платная подписка не активирована."
            } else { message = "Активной подписки нет." }
        } catch { activeExpiry = nil; message = "Статус недоступен. Войдите в аккаунт и проверьте соединение." }
    }
}
