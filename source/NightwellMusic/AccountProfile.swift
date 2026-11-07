import SwiftUI
import PhotosUI
import ImageIO

struct AccountProfile: Codable, Equatable {
    var nickname = ""
    var avatar_url = ""
}

extension MusicStore {
    func refreshProfile() async {
        guard let owner = account?.id else { profile = AccountProfile(); return }
        do {
            let result: AccountProfile = try await api.request("api/profile")
            if account?.id == owner { profile = result }
        } catch { if account?.id == owner { profile = AccountProfile() } }
    }
}

struct AccountAvatar: View {
    @EnvironmentObject var store: MusicStore
    var body: some View {
        ZStack {
            Circle().fill(.white.opacity(0.10))
            if store.account == nil {
                Image(systemName: "person.crop.circle").font(.system(size: 27)).foregroundStyle(.white.opacity(0.85))
            } else {
                Text(store.profile.nickname.first.map { String($0).uppercased() } ?? "N").font(.system(size: 18, weight: .semibold))
                if !store.profile.avatar_url.isEmpty {
                    AsyncImage(url: URL(string: store.profile.avatar_url, relativeTo: store.origin)) { image in image.resizable().scaledToFill() } placeholder: { Color.clear }
                }
            }
        }.frame(width: 42, height: 42).clipShape(Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.20), lineWidth: 1))
            .task(id: store.account?.id) { await store.refreshProfile() }
    }
}

struct AccountProfileEditor: View {
    @EnvironmentObject var store: MusicStore
    @State private var nickname = ""
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var saving = false
    @State private var notice = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Профиль", systemImage: "person.crop.circle").font(.system(size: 18, weight: .semibold))
            HStack(spacing: 14) {
                AccountAvatar()
                PhotosPicker(selection: $selectedPhoto, matching: .images) { Text("Выбрать аватарку") }
                    .disabled(saving)
            }
            TextField("Никнейм", text: $nickname).textInputAutocapitalization(.never).autocorrectionDisabled()
                .padding(12).background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
            Button(saving ? "Сохраняем" : "Сохранить ник") { Task { await saveName() } }.disabled(saving)
            if !store.profile.avatar_url.isEmpty {
                Button("Удалить аватарку") { Task { await removeAvatar() } }.disabled(saving)
            }
            if !notice.isEmpty { Text(notice).font(.caption).foregroundStyle(.secondary) }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 26))
            .task { await store.refreshProfile(); nickname = store.profile.nickname }
            .onChange(of: selectedPhoto) { item in Task { await upload(item) } }
    }
    @MainActor private func saveName() async {
        guard !saving, let owner = store.account?.id else { return }
        let value = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...40).contains(value.count) else { notice = "Ник должен содержать от 2 до 40 символов"; return }
        saving = true; defer { saving = false }
        do { let result: AccountProfile = try await store.api.request("api/profile", method: "PUT", body: ["nickname": value]); if store.account?.id == owner { store.profile = result; notice = "Ник сохранён" } }
        catch { notice = error.localizedDescription }
    }
    @MainActor private func upload(_ item: PhotosPickerItem?) async {
        guard let item, !saving, let owner = store.account?.id else { return }
        saving = true; defer { saving = false; selectedPhoto = nil }
        do {
            guard let data = try await item.loadTransferable(type: Data.self), data.count <= 12 * 1024 * 1024,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 512] as CFDictionary),
                  let jpeg = UIImage(cgImage: thumbnail).jpegData(compressionQuality: 0.88) else { throw APIError(message: "Выбери изображение до 12 МБ") }
            let result: AccountProfile = try await store.api.request("api/profile/avatar", method: "POST", body: ["image": jpeg.base64EncodedString()])
            if store.account?.id == owner { store.profile = result; notice = "Аватарка обновлена" }
        } catch { notice = error.localizedDescription }
    }
    @MainActor private func removeAvatar() async {
        guard !saving, let owner = store.account?.id else { return }
        saving = true; defer { saving = false }
        do { let result: AccountProfile = try await store.api.request("api/profile/avatar", method: "DELETE"); if store.account?.id == owner { store.profile = result; notice = "Аватарка удалена" } }
        catch { notice = error.localizedDescription }
    }
}
