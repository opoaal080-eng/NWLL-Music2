import SwiftUI
import UIKit
import PhotosUI

struct NightwellProfile: Decodable {
    let user_id: String
    let nickname: String
    let avatar_url: String?
}

@MainActor
extension MusicStore {
    func refreshProfile() async {
        guard account != nil else { profileNickname = ""; profileAvatar = nil; return }
        do {
            let details: NightwellProfile = try await api.request("/api/profile/me")
            profileNickname = details.nickname
            if let path = details.avatar_url,
               let url = URL(string: path, relativeTo: origin)?.absoluteURL,
               url.scheme == "https", url.host == origin.host {
                // Avatar URLs are public and previously had a five-minute cache TTL.
                // Always revalidate after changing a photo, even against older servers.
                var request = URLRequest(url: url)
                request.cachePolicy = .reloadIgnoringLocalCacheData
                request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
                let (data,response) = try await URLSession.shared.data(for: request)
                if let r = response as? HTTPURLResponse, r.statusCode == 200,
                   data.count <= 768*1024, let image=UIImage(data:data) {
                    profileAvatar = image
                }
            } else { profileAvatar = nil }
        } catch {
            // Profile routes are an optional extension to older installations.
        }
    }

    func saveProfileNickname(_ nickname: String) async throws {
        guard account != nil else { throw NSError(domain:"Nightwell",code:401) }
        let response: NightwellProfile = try await api.request(
            "/api/profile/me", method:"PUT", body:["nickname":nickname])
        profileNickname = response.nickname
    }

    func saveProfileAvatar(_ data: Data) async throws {
        guard account != nil else { throw NSError(domain:"Nightwell",code:401) }
        let compressed = UIImage(data:data)?.scaledProfileJPEG()
        guard let compressed, compressed.count <= 768*1024 else {
            throw NSError(domain:"Nightwell",code:413,userInfo:[NSLocalizedDescriptionKey:"Фото слишком большое"])
        }
        let owner = account?.id
        let _: NightwellProfile = try await api.request(
            "/api/profile/avatar", method:"POST",
            body:["mime":"image/jpeg","avatar_base64":compressed.base64EncodedString()])
        guard owner == account?.id else { return }
        // Update immediately from the pixels we just uploaded, even if an old
        // reverse proxy temporarily serves a stale image for the same URL.
        profileAvatar = UIImage(data: compressed)
        await refreshProfile()
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
