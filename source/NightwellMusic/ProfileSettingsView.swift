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

    func refreshProfile() async {
        guard let userID = account?.id else {
            profileNickname = ""
            profileAvatar = nil
            profileLoadError = "Войди в аккаунт, чтобы загрузить сохранённый профиль."
            return
        }
        profileLoadError = nil
        let server = origin
        do {
            let details: NightwellProfile = try await api.request("/api/profile/me")
            guard account?.id == userID, origin == server else { return }
            profileLoadError = nil
            profileNickname = details.nickname
            UserDefaults.standard.set(details.nickname,
                forKey: cachedNicknameKey(userID: userID, server: server))
            guard let path = details.avatar_url, !path.isEmpty,
                  let url = URL(string: path, relativeTo: server)?.absoluteURL,
                  url.scheme == "https", url.host == server.host else {
                profileAvatar = nil
                profileLoadError = "На сервере пока нет аватарки для этого аккаунта."
                try? FileManager.default.removeItem(
                    at: profileCachePath(userID: userID, server: server))
                return
            }

            // A stable avatar URL was previously cached by the proxy. Revalidate
            // explicitly, while retaining the cached photo if the network fails.
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard account?.id == userID, origin == server else { return }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  !data.isEmpty, data.count <= 768 * 1024,
                  let image = UIImage(data: data) else { return }
            profileAvatar = image
            profileLoadError = nil
            cacheAvatar(data, userID: userID, server: server)
        } catch {
            // Keep the last local image and report why a fresh install could
            // not restore the avatar from the server.
            profileLoadError = "Не удалось загрузить профиль: " + error.localizedDescription
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

struct ProfileSettingsView: View {
    @EnvironmentObject private var store: MusicStore
    @State private var nickname = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var notice = ""
    @State private var busy = false

    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Label("Профиль",systemImage:"person.crop.circle")
                .font(.system(size:18,weight:.semibold))
            HStack(spacing:12) {
                Group {
                    if let image=store.profileAvatar {
                        Image(uiImage:image).resizable().scaledToFill()
                    } else {
                        Image(systemName:"person.crop.circle.fill")
                            .resizable().scaledToFit().foregroundStyle(.white.opacity(0.7))
                    }
                }
                .frame(width:58,height:58).clipShape(Circle())
                PhotosPicker(selection:$selectedPhoto, matching:.images) {
                    Text("Изменить аватар").font(.system(size:15))
                }.disabled(busy)
            }
            if let profileError = store.profileLoadError {
                Text(profileError).font(.caption).foregroundStyle(.secondary)
                Button("Повторить загрузку профиля") {
                    Task { await store.refreshProfile(); nickname = store.profileNickname }
                }.font(.system(size: 13, weight: .medium))
            }
            TextField("Ник, от 2 до 32 символов",text:$nickname)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(12).background(.white.opacity(0.09),in:RoundedRectangle(cornerRadius:12))
            Button(busy ? "Сохраняем…" : "Сохранить ник") {
                busy=true
                Task {
                    do { try await store.saveProfileNickname(nickname); notice="Профиль сохранён" }
                    catch { notice="Не удалось сохранить ник: "+error.localizedDescription }
                    busy=false
                }
            }.disabled(busy || nickname.trimmingCharacters(in:.whitespacesAndNewlines).count < 2)
            if !notice.isEmpty { Text(notice).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(16)
        .background(.white.opacity(0.035),in:RoundedRectangle(cornerRadius:24))
        .task { await store.refreshProfile();nickname=store.profileNickname }
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
