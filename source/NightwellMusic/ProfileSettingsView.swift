import SwiftUI
import UIKit
import PhotosUI
import CryptoKit

struct NightwellProfile: Decodable {
    let user_id: String
    let nickname: String
    let avatar_url: String?
}

@MainActor
extension MusicStore {
    // Scoped per server and account. Private cache makes the avatar visible
    // immediately at launch, before any profile API request finishes.
    private func profileCacheScope(userID: String, server: URL) -> String {
        let digest = SHA256.hash(data: Data((server.absoluteString + "|" + userID).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func profileCachePath(userID: String, server: URL) -> URL {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("nightwell-profile-images", isDirectory: true)
        return folder.appendingPathComponent(profileCacheScope(userID: userID, server: server) + ".jpg")
    }

    private func cachedNicknameKey(userID: String, server: URL) -> String {
        "nightwell-profile-nick-" + profileCacheScope(userID: userID, server: server)
    }

    func restoreCachedProfile() {
        guard let userID = account?.id else {
            profileNickname = ""
            profileAvatar = nil
            return
        }
        profileNickname = UserDefaults.standard.string(
            forKey: cachedNicknameKey(userID: userID, server: origin)) ?? ""
        let url = profileCachePath(userID: userID, server: origin)
        if let data = try? Data(contentsOf: url),
           data.count <= 768 * 1024, let image = UIImage(data: data) {
            profileAvatar = image
        } else {
            profileAvatar = nil
        }
    }

    private func cacheAvatar(_ data: Data, userID: String, server: URL) {
        guard !data.isEmpty, data.count <= 768 * 1024 else { return }
        let url = profileCachePath(userID: userID, server: server)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    func refreshProfile(force: Bool = false) async {
        guard let userID = account?.id else {
            profileNickname = ""
            profileAvatar = nil
            profileLoadError = nil
            return
        }
        let server = origin
        let scope = server.absoluteString + "|" + userID
        // Startup, the account-change observer, and opening the profile
        // sheet can all request this endpoint at once. A brief throttle
        // prevents duplicate traffic without blocking the explicit Retry.
        if profileLoading && profileLastRequestScope == scope { return }
        if !force && profileLastRequestScope == scope &&
            Date().timeIntervalSince(profileLastRequestAt) < 20 { return }

        let token = UUID()
        profileLastRequestScope = scope
        profileLastRequestAt = Date()
        profileRequestToken = token
        profileLoading = true
        profileLoadError = nil
        defer {
            if profileRequestToken == token {
                profileLoading = false
                profileRequestToken = nil
            }
        }

        let details: NightwellProfile
        do {
            details = try await api.request("/api/profile/me", timeout: 12)
        } catch {
            guard !Task.isCancelled, profileRequestToken == token,
                  account?.id == userID, origin == server else { return }
            // Distinguish a missing/unauthorized profile endpoint from an
            // actual loss of connectivity to the Nightwell music server.
            if let response = error as? RequestRetry.HTTPFailure {
                switch response.status {
                case 401, 403:
                    profileLoadError = "Доступ к API профиля отклонён (HTTP \(response.status)). Проверь вход в аккаунт."
                case 404:
                    profileLoadError = "Основной сервер доступен, но API профиля не найден (HTTP 404). Требуется /api/profile/me."
                case 429:
                    profileLoadError = "Слишком много запросов к профилю (HTTP 429). Повтори немного позже."
                case 500...599:
                    profileLoadError = "API профиля ответил с ошибкой HTTP \(response.status). Музыка может работать отдельно."
                default:
                    profileLoadError = "Не удалось обновить профиль (HTTP \(response.status))."
                }
            } else if error is DecodingError {
                profileLoadError = "Сервер вернул неподдерживаемый формат данных профиля."
            } else {
                profileLoadError = "Ошибка запроса профиля: " + error.localizedDescription
            }
            // Keep the saved nickname and avatar. A profile-specific failure
            // must never hide the user's locally restored account.
            return
        }
        guard !Task.isCancelled, profileRequestToken == token,
              account?.id == userID, origin == server else { return }
        profileNickname = details.nickname
        profileLoadError = nil
        UserDefaults.standard.set(details.nickname,
            forKey: cachedNicknameKey(userID: userID, server: server))

        guard let path = details.avatar_url, !path.isEmpty,
              let url = URL(string: path, relativeTo: server)?.absoluteURL,
              url.scheme == "https", url.host == server.host else {
            // No avatar is a valid profile, not a server error.
            profileAvatar = nil
            try? FileManager.default.removeItem(
                at: profileCachePath(userID: userID, server: server))
            return
        }
        // Avatar bytes are optional and fetched independently from metadata.
        // A failing cover/image endpoint must not mark the profile offline.
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 12
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled, profileRequestToken == token,
                  account?.id == userID, origin == server else { return }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  !data.isEmpty, data.count <= 768 * 1024,
                  let image = UIImage(data: data) else { return }
            profileAvatar = image
            cacheAvatar(data, userID: userID, server: server)
        } catch {
            // The cached avatar stays visible. Profile metadata loaded fine.
        }
    }

    func saveProfileNickname(_ nickname: String) async throws {
        guard let userID = account?.id else {
            throw NSError(domain: "Nightwell", code: 401)
        }
        let server = origin
        let response: NightwellProfile = try await api.request(
            "/api/profile/me", method: "PUT", body: ["nickname": nickname])
        guard account?.id == userID, origin == server else { return }
        profileNickname = response.nickname
        UserDefaults.standard.set(response.nickname,
            forKey: cachedNicknameKey(userID: userID, server: server))
    }

    func saveProfileAvatar(_ data: Data) async throws {
        guard let userID = account?.id else {
            throw NSError(domain: "Nightwell", code: 401)
        }
        let server = origin
        let compressed = UIImage(data: data)?.scaledProfileJPEG()
        guard let compressed, compressed.count <= 768 * 1024 else {
            throw NSError(domain: "Nightwell", code: 413,
                          userInfo: [NSLocalizedDescriptionKey: "Фото слишком большое"])
        }
        let _: NightwellProfile = try await api.request(
            "/api/profile/avatar", method: "POST",
            body: ["mime": "image/jpeg",
                   "avatar_base64": compressed.base64EncodedString()])
        guard account?.id == userID, origin == server else { return }

        // Update immediately and persist locally. A subsequent fetch cannot
        // restore the old photo while a reverse proxy catches up.
        profileAvatar = UIImage(data: compressed)
        cacheAvatar(compressed, userID: userID, server: server)
        await refreshProfile()
        guard account?.id == userID, origin == server else { return }
        profileAvatar = UIImage(data: compressed)
    }
}

private extension UIImage {
    func scaledProfileJPEG() -> Data? {
        let limit: CGFloat = 512
        let factor = min(1,limit/max(max(size.width,size.height),1))
        let dimensions = CGSize(width:max(1,size.width*factor),height:max(1,size.height*factor))
        let renderer = UIGraphicsImageRenderer(size:dimensions)
        let image = renderer.image { _ in draw(in: CGRect(origin:.zero,size:dimensions)) }
        return image.jpegData(compressionQuality:0.78)
    }
}

/// A neutral, softly lit backdrop used only by the menu and profile sheets.
struct NightwellMonochromeGlassBackground: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                LinearGradient(
                    colors: [Color(white: 0.14), Color(white: 0.045), .black,
                             Color(white: 0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Circle()
                    .fill(Color.white.opacity(0.115))
                    .frame(width: proxy.size.width * 1.12)
                    .blur(radius: 90)
                    .offset(x: -proxy.size.width * 0.34,
                            y: -proxy.size.height * 0.42)
                Circle()
                    .fill(Color.white.opacity(0.055))
                    .frame(width: proxy.size.width * 0.85)
                    .blur(radius: 88)
                    .offset(x: proxy.size.width * 0.42,
                            y: proxy.size.height * 0.37)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Subtle liquid-glass surface with white edge lighting and a dark base.
/// Keeping it scoped to two sheets avoids changing the rest of the player.
private struct NightwellMonochromeGlassModifier: ViewModifier {
    let radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                shape.fill(.ultraThinMaterial)
                    .overlay {
                        shape.fill(LinearGradient(
                            colors: [Color.white.opacity(0.09),
                                     Color.white.opacity(0.025),
                                     Color.white.opacity(0.055)],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        ))
                    }
            }
            .overlay {
                shape.strokeBorder(LinearGradient(
                    colors: [Color.white.opacity(0.30), Color.white.opacity(0.08),
                             Color.white.opacity(0.17)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ), lineWidth: 0.85)
            }
            .shadow(color: .black.opacity(0.19), radius: 16, y: 8)
    }
}

extension View {
    func nightwellMonochromeGlass(radius: CGFloat = 20) -> some View {
        modifier(NightwellMonochromeGlassModifier(radius: radius))
    }
}

struct ProfileSettingsView: View {
    @EnvironmentObject private var store: MusicStore
    @State private var nickname = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var notice = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(.white.opacity(0.84))
                Text("Профиль")
                    .font(.system(size: 18, weight: .semibold))
            }
            HStack(spacing: 12) {
                Group {
                    if let image = store.profileAvatar {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Image(systemName: "person.crop.circle.fill")
                            .resizable().scaledToFit()
                            .foregroundStyle(.white.opacity(0.72))
                    }
                }
                .frame(width: 58, height: 58)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.32), lineWidth: 1))
                .shadow(color: .black.opacity(0.20), radius: 9, y: 4)
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    HStack(spacing: 8) {
                        Image(systemName: "photo.badge.plus")
                        Text("Изменить аватар")
                    }
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .nightwellMonochromeGlass(radius: 15)
                }
                .buttonStyle(.plain)
                .disabled(busy)
            }
            if let profileError = store.profileLoadError {
                Text(profileError)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.64))
                Button("Повторить загрузку профиля") {
                    Task { await store.refreshProfile(); nickname = store.profileNickname }
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
            }
            TextField("Ник, от 2 до 32 символов", text: $nickname)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(.white)
                .tint(.white)
                .padding(12)
                .nightwellMonochromeGlass(radius: 14)
            Button(busy ? "Сохраняем…" : "Сохранить ник") {
                busy = true
                Task {
                    do { try await store.saveProfileNickname(nickname); notice = "Профиль сохранён" }
                    catch { notice = "Не удалось сохранить ник: " + error.localizedDescription }
                    busy = false
                }
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white.opacity(0.95))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .nightwellMonochromeGlass(radius: 15)
            .buttonStyle(.plain)
            .disabled(busy || nickname.trimmingCharacters(in: .whitespacesAndNewlines).count < 2)
            .opacity(busy || nickname.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 ? 0.55 : 1)
            if !notice.isEmpty {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.68))
            }
            Divider().overlay(.white.opacity(0.12)).padding(.vertical, 6)
            HStack {
                Label("Мои устройства", systemImage: "iphone.and.arrow.forward")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Button {
                    Task { await store.refreshAccountDevices() }
                } label: {
                    Image(systemName: "arrow.clockwise").frame(width: 36, height: 36)
                }
                .accessibilityLabel("Обновить устройства")
            }
            if store.accountDeviceSupported {
                Text("Подключено: \(store.accountDevices.count) из \(store.accountDeviceLimit)")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.62))
                ForEach(store.accountDevices) { device in
                    HStack(spacing: 10) {
                        Image(systemName: device.platform == "ios" ? "iphone" :
                              device.platform == "android" ? "smartphone" : "desktopcomputer")
                            .font(.system(size: 18))
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(device.name + (device.current ? " · Это устройство" : ""))
                                .font(.subheadline.weight(.medium))
                            Text(device.blocked ? "Лимит подписки превышен" :
                                 "Последний вход: " + Date(timeIntervalSince1970: device.last_seen)
                                     .formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        Button("Удалить", role: .destructive) {
                            Task { await store.removeAccountDevice(device.id) }
                        }
                        .font(.caption).buttonStyle(.borderless)
                    }
                    .padding(.vertical, 7)
                }
            } else if !store.accountDeviceNotice.isEmpty {
                Text(store.accountDeviceNotice)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
            }

        }
        .padding(.horizontal, 17)
        .padding(.vertical, 15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nightwellMonochromeGlass(radius: 25)
        .task { await store.refreshProfile(); nickname = store.profileNickname; await store.refreshAccountDevices() }
        .onChange(of:selectedPhoto) { next in
            guard let next, !busy else { return }
            busy=true
            Task {
                defer {
                    busy=false
                    // Reset the system picker selection. Without this, picking
                    // the exact same photo a second time produces no change.
                    selectedPhoto=nil
                }
                do {
                    guard let data=try await next.loadTransferable(type:Data.self) else {
                        throw NSError(domain:"Nightwell",code:400,userInfo:[NSLocalizedDescriptionKey:"Фото не открылось"])
                    }
                    try await store.saveProfileAvatar(data)
                    notice="Аватар обновлён"
                } catch { notice="Не удалось обновить аватар: "+error.localizedDescription }
            }
        }
    }
}
