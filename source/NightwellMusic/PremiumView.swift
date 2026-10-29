import SwiftUI
import SafariServices

private struct PremiumRenewal: Decodable {
    let auto_renewal: String
    let has_lava_subscription: Bool
}

private struct PremiumStatus: Decodable {
    let premium: Bool
    let test_premium: Bool
    let expires_at: Double?
}

// External website checkout for direct IPA distribution, not an App Store build.
struct PremiumView: View {
    let api: MusicAPI
    @Environment(\.scenePhase) private var scenePhase
    @State private var message = "Проверяем подписку…"
    @State private var consent = false
    @State private var checking = false
    @State private var paying = false
    @State private var payment: PremiumPaymentSession?
    @State private var activeExpiry: Double?
    @State private var isActivePremium = false
    @State private var statusChecked = false
    @State private var statusAvailable = false
    @State private var showFeatures = false
    @State private var renewal: PremiumRenewal?
    @State private var cancellingRenewal = false
    @State private var confirmCancellation = false
    @State private var renewalMessage = ""
    @State private var selectedDetent: PresentationDetent = .height(362)
    private var externalPayments: Bool { Bundle.main.object(forInfoDictionaryKey: "NWExternalPremiumPayments") as? Bool ?? true }

    var body: some View {
        Group {
            if !statusChecked {
                verificationSheet
            } else if isActivePremium && (activeExpiry == nil || activeExpiry! > Date().timeIntervalSince1970) {
                activeSheet(expiry: activeExpiry)
            } else if !statusAvailable {
                verificationSheet
            } else {
                inactiveSheet
            }
        }
        .modifier(NightwellSheetSurface(gradient: LinearGradient(colors: [nightwellViolet, Color.black], startPoint: .topLeading, endPoint: .bottomTrailing)))
        .ignoresSafeArea(.container, edges: .bottom)
        .preferredColorScheme(.dark)
        
        .presentationDetents([.height(362), .large], selection: $selectedDetent)
        .presentationDragIndicator(.hidden)
        .task { await refresh() }
        .confirmationDialog("Отключить автопродление?", isPresented: $confirmCancellation) {
            Button("Отключить автопродление", role: .destructive) {
                Task { await cancelRenewal() }
            }
            Button("Оставить включённым", role: .cancel) {}
        } message: {
            Text("Premium останется доступен до конца оплаченного периода.")
        }
        .sheet(item: $payment, onDismiss: { Task { await refresh() } }) { session in
            PremiumPaymentBrowser(url: session.url) { payment = nil }
                .ignoresSafeArea()
                .presentationDetents([.large])
        }
        .task(id: payment?.id) {
            if let session = payment { await watchPayment(session) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
    }

    private var handle: some View {
        Capsule().fill(.white.opacity(0.45)).frame(width: 57, height: 4).padding(.top, 10)
    }

    private var verificationSheet: some View {
        VStack(spacing: 20) {
            handle
            Spacer(minLength: 8)
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.system(size: 44, weight: .ultraLight)).foregroundStyle(.white.opacity(0.75))
            Text(statusChecked ? "Не удалось проверить подписку" : "Проверяем Nightwell Premium…")
                .font(.system(size: 21, weight: .semibold)).multilineTextAlignment(.center)
            if !statusChecked {
                ProgressView().tint(.white)
            } else {
                Text(message).foregroundStyle(.white.opacity(0.65)).multilineTextAlignment(.center)
                Button(checking ? "Проверяем…" : "Повторить проверку") { Task { await refresh() } }
                    .buttonStyle(.borderedProminent).tint(Color(white: 0.24)).disabled(checking)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24).background(Color(white: 0.07))
    }

    @ViewBuilder private func activeSheet(expiry: Double?) -> some View {
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
                        if let expiry {
                            Text("Активна до " + Date(timeIntervalSince1970: expiry).formatted(.dateTime.day().month(.wide).year().locale(Locale(identifier: "ru_RU"))))
                                .foregroundStyle(.white.opacity(0.62))
                                .font(.system(size: 17, weight: .regular))
                        } else {
                            Text("Статус подтверждён сервером")
                                .foregroundStyle(.white.opacity(0.62))
                                .font(.system(size: 17, weight: .regular))
                        }
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

                    VStack(spacing: 10) {
                        Text(renewal?.auto_renewal == "disabled" ? "Автопродление отключено" :
                             renewal == nil ? "Не удалось получить статус автопродления" :
                             renewal?.has_lava_subscription == true ? "Автопродление доступно для управления" :
                             "Нет подтверждённой подписки с автопродлением")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.72))
                        if renewal?.auto_renewal != "disabled" {
                            Button(cancellingRenewal ? "Отключаем…" : "Отключить автопродление") {
                                if renewal?.has_lava_subscription == true {
                                    confirmCancellation = true
                                } else {
                                    renewalMessage = "Сервер не подтвердил подписку с автопродлением. Проверьте статус оплаты в Lava."
                                }
                            }
                            .buttonStyle(.bordered)
                            .disabled(cancellingRenewal || checking)
                        }
                        if !renewalMessage.isEmpty {
                            Text(renewalMessage).font(.footnote).foregroundStyle(.white.opacity(0.75))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(14)
                    .nightwellLiquidGlass(24)
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
            LinearGradient(colors: [Color(white: 0.10).opacity(0.92), Color.black.opacity(0.95)], startPoint: .topLeading, endPoint: .bottomTrailing)
        )
    }

    private var inactiveSheet: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                handle.frame(maxWidth: .infinity)
                Text("Nightwell Premium").font(.title2.bold())
                Text("Выберите тариф и оформите подписку на странице оплаты.").font(.headline)
                Text("Музыку можно слушать бесплатно. Premium открывает скачивания, эквалайзер с пресетами, оформление, умные плейлисты и статистику.")
                Text(message).accessibilityIdentifier("premium-status")
                DisclosureGroup("Условия Premium") {
                    Text(PremiumTerms.text).textSelection(.enabled).padding(.top, 10)
                }
                .padding(16)
                .nightwellLiquidGlass(24)
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
                Text("30 дней за 150 ₽. Оплата откроется в приложении. После подтверждения платежа окно закроется автоматически.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                Button(paying ? "Создаём счёт…" : "Оплатить") {
                    Task { await checkout() }
                }
                .buttonStyle(.borderedProminent)
                .tint(pumpkin)
                .disabled(!consent || !externalPayments || paying || checking)
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

    @MainActor private func checkout() async {
        guard consent, externalPayments, statusChecked, statusAvailable, !isActivePremium,
              !paying, !checking else { return }
        paying = true
        defer { paying = false }
        do {
            let identity: Identity = try await api.request("api/me")
            guard identity.user != nil else { throw APIError(message: "Войди в аккаунт перед оплатой.") }
            await api.setCSRF(identity.csrf)
            let before: PremiumStatus = try await api.request("api/premium/me")
            if before.premium {
                isActivePremium = true
                statusChecked = true
                statusAvailable = true
                activeExpiry = before.expires_at
                message = "Premium уже активен."
                return
            }
            struct Checkout: Decodable { let confirmation_url: String }
            let result: Checkout = try await api.request("api/premium/lava/checkout", method: "POST")
            guard let url = URL(string: result.confirmation_url), url.scheme == "https",
                  let host = url.host, ["lava.top", "app.lava.top", "gate.lava.top"].contains(host),
                  url.user == nil, url.password == nil else {
                throw APIError(message: "Сервер вернул неверную ссылку оплаты.")
            }
            guard let owner = identity.user?.id else { return }
            message = "Ожидаем подтверждения оплаты."
            payment = PremiumPaymentSession(url: url, accountID: owner,
                                            previousExpiry: before.premium ? (before.expires_at ?? 0) : 0)
        } catch {
            message = error.localizedDescription
        }
    }

    @MainActor private func watchPayment(_ session: PremiumPaymentSession) async {
        // Only the authenticated Nightwell API can confirm payment. Browser URLs,
        // page text and a manually closed sheet are never payment confirmation.
        while !Task.isCancelled, payment?.id == session.id {
            if scenePhase == .active {
                do {
                    let identity: Identity = try await api.request("api/me")
                    guard !Task.isCancelled, payment?.id == session.id else { return }
                    guard identity.user?.id == session.accountID else {
                        payment = nil
                        activeExpiry = nil
                        isActivePremium = false
                        statusChecked = true
                        statusAvailable = false
                        message = "Аккаунт изменился. Открой Premium заново."
                        return
                    }
                    await api.setCSRF(identity.csrf)
                    struct Verified: Decodable { let expires_at: Double? }
                    let _: Verified? = try? await api.request("api/premium/lava/verify", method: "POST")
                    try Task.checkCancellation()
                    let current: PremiumStatus = try await api.request("api/premium/me")
                    guard !Task.isCancelled, payment?.id == session.id else { return }
                    let after: Identity = try await api.request("api/me")
                    guard !Task.isCancelled, payment?.id == session.id else { return }
                    guard after.user?.id == session.accountID else {
                        payment = nil
                        activeExpiry = nil
                        isActivePremium = false
                        statusChecked = true
                        statusAvailable = false
                        message = "Аккаунт изменился. Открой Premium заново."
                        return
                    }
                    if PremiumPaymentPolicy.shouldClose(expectedAccount: session.accountID,
                            currentAccount: after.user?.id, premium: current.premium,
                            expiry: current.expires_at, previousExpiry: session.previousExpiry,
                            now: Date().timeIntervalSince1970) {
                        activeExpiry = current.expires_at
                        isActivePremium = true
                        statusChecked = true
                        statusAvailable = true
                        message = "Оплата подтверждена. Premium активен."
                        payment = nil
                        return
                    }
                } catch is CancellationError {
                    return
                } catch {
                    // A slow webhook or a network failure must leave checkout open.
                }
            }
            do { try await Task.sleep(for: .seconds(4)) }
            catch { return }
        }
    }

    @MainActor private func cancelRenewal() async {
        guard !cancellingRenewal, renewal?.has_lava_subscription == true else { return }
        cancellingRenewal = true
        defer { cancellingRenewal = false }
        do {
            let identity: Identity = try await api.request("api/me")
            await api.setCSRF(identity.csrf)
            struct Cancelled: Decodable { let auto_renewal: String }
            let response: Cancelled = try await api.request("api/premium/lava/cancel-renewal", method: "POST")
            guard response.auto_renewal == "disabled" else { throw CancellationError() }
            renewalMessage = "Будущие списания отключены. Оплаченный период сохранён."
            let status: PremiumRenewal = try await api.request("api/premium/lava/renewal")
            renewal = status
        } catch {
            renewalMessage = "Отмена не подтверждена. Проверьте подключение и попробуйте снова."
        }
    }

    @MainActor private func refresh() async {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--native-smoke-premium") {
            activeExpiry = 1824076800
            isActivePremium = true; statusAvailable = true; statusChecked = true
            return
        }
        #endif
        guard !checking else { return }
        checking = true
        defer { checking = false; statusChecked = true }
        do {
            let identity: Identity = try await api.request("api/me")
            guard identity.user != nil else {
                isActivePremium = false
                activeExpiry = nil
                statusAvailable = false
                renewal = nil
                message = "Войди в аккаунт, чтобы проверить Premium."
                return
            }
            await api.setCSRF(identity.csrf)
            // Read cached server entitlement before contacting the payment provider.
            // The provider can time out, but a subscriber must still see their status.
            var status: PremiumStatus = try await api.request("api/premium/me")
            if !status.premium {
                struct Verified: Decodable { let expires_at: Double? }
                if let verified: Verified = try? await api.request("api/premium/lava/verify", method: "POST"),
                   let expiry = verified.expires_at, expiry > Date().timeIntervalSince1970 {
                    status = try await api.request("api/premium/me")
                }
            }
            isActivePremium = status.premium
            activeExpiry = status.premium ? status.expires_at : nil
            statusAvailable = true
            renewal = status.premium ? (try? await api.request("api/premium/lava/renewal")) : nil
            if status.premium {
                if let expiry = status.expires_at {
                    message = "Premium активен до " + Date(timeIntervalSince1970: expiry).formatted(date: .abbreviated, time: .omitted)
                } else {
                    message = "Premium активен."
                }
            } else if status.test_premium {
                message = "Тестовый платёж подтверждён. Платная подписка не активирована."
            } else {
                message = "Активной подписки нет."
            }
        } catch {
            // Keep previously verified Premium in a temporary outage.
            // Never replace it with a checkout form when verification fails.
            if !isActivePremium || (activeExpiry != nil && activeExpiry! <= Date().timeIntervalSince1970) {
                isActivePremium = false
                activeExpiry = nil
            }
            statusAvailable = false
            message = "Не удалось связаться с сервером. Повтори проверку статуса."
        }
    }
}


private struct PremiumPaymentSession: Identifiable {
    let id = UUID()
    let url: URL
    let accountID: String
    let previousExpiry: Double
}

private struct PremiumPaymentBrowser: UIViewControllerRepresentable {
    let url: URL
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onClose: onClose) }

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.delegate = context.coordinator
        controller.dismissButtonStyle = .close
        controller.preferredControlTintColor = .white
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let onClose: () -> Void
        init(onClose: @escaping () -> Void) { self.onClose = onClose }
        func safariViewControllerDidFinish(_ controller: SFSafariViewController) { onClose() }
    }
}
