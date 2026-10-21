import SwiftUI
import UniformTypeIdentifiers
import QuickLook
import PhotosUI
import UIKit

private struct SupportPreviewItem: Identifiable { let id = UUID(); let url: URL }
private struct SupportFilePreview: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}
private struct TicketList: Decodable { let tickets: [SupportTicket] }
private struct SupportAttachment: Identifiable, Decodable {
    let id: String
    let name: String
    let size: Int
}
private struct SupportTicket: Identifiable, Decodable {
    let id: String
    let subject: String
    let status: String
    let messages: [SupportMessage]?
    let attachments: [SupportAttachment]?
}
private struct SupportMessage: Identifiable, Decodable {
    let id: String
    let author_role: String
    let body: String
}
private struct TicketCreated: Decodable { let id: String }

struct NativeSupportView: View {
    @EnvironmentObject private var store: MusicStore
    let close: () -> Void
    @State private var adminMode = false
    @State private var tickets: [SupportTicket] = []
    @State private var selected: SupportTicket?
    @State private var subject = ""
    @State private var message = ""
    @State private var kind = "question"
    @State private var error = ""
    @State private var busy = false
    @State private var importFile = false
    @State private var uploading = false
    @State private var previewItem: SupportPreviewItem?
    @State private var showAttachmentSources = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var showGallery = false
    @State private var attachmentStatus = ""
    private let statuses = ["new", "in_progress", "waiting_user", "resolved", "closed"]
    private let statusNames = ["new": "Новое", "in_progress": "В работе", "waiting_user": "Ожидает ответа", "resolved": "Решено", "closed": "Закрыто"]
    private var isAdmin: Bool { store.account?.is_admin == true }
    private func path(_ id: String) -> String {
        "/api/support/" + (adminMode ? "admin/" : "") + "tickets/" + id
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if isAdmin {
                        Picker("Режим", selection: $adminMode) {
                            Text("Мои").tag(false)
                            Text("Администрирование").tag(true)
                        }.pickerStyle(.segmented).padding(8).frostedGlass().onChange(of: adminMode) { _ in selected = nil; Task { await refresh() } }
                    }
                    if !error.isEmpty { Text(error).foregroundStyle(pumpkin) }
                    if let ticket = selected {
                        Text(ticket.subject).font(.title3.bold()).foregroundStyle(.white)
                        Text(statusNames[ticket.status] ?? ticket.status).font(.subheadline.weight(.semibold)).foregroundStyle(pumpkin)
                        ForEach(ticket.messages ?? []) { entry in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(entry.author_role == "admin" ? "Поддержка" : "Пользователь").font(.caption).foregroundStyle(pumpkin)
                                Text(entry.body)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding().frostedGlass()
                        }
                        if !attachmentStatus.isEmpty { Text(attachmentStatus).font(.caption).foregroundStyle(pumpkin) }
                        ForEach(ticket.attachments ?? []) { attachment in
                            Button { Task { await preview(ticket.id, attachment) } } label: { Label(attachment.name, systemImage: "doc") }.tint(pumpkin)
                        }
                        if ticket.status != "closed" {
                            Button { showAttachmentSources = true } label: { Label(uploading ? "Загрузка…" : "Прикрепить файл до 10 МБ", systemImage: "paperclip") }.buttonStyle(.borderedProminent).tint(pumpkin).disabled(uploading)
                            TextField(adminMode ? "Ответ пользователю" : "Дополнить обращение", text: $message, axis: .vertical)
                                .lineLimit(3...7).padding().frostedGlass()
                            Button("Отправить") { Task { await reply(ticket.id) } }.buttonStyle(.borderedProminent).tint(pumpkin).disabled(message.isEmpty || busy)
                        }
                        if adminMode {
                            ForEach(statuses, id: \.self) { status in
                                Button(statusNames[status] ?? status) { Task { await updateStatus(ticket.id, status) } }
                            }
                        }
                        Button("К списку") { selected = nil }
                    } else {
                        if !adminMode {
                            Text("Новое обращение").font(.title3.bold()).foregroundStyle(.white)
                            Text("После создания обращения можно прикрепить изображения и документы до 10 МБ.").font(.caption).foregroundStyle(.secondary)
                            TextField("Тема", text: $subject).padding().frostedGlass()
                            Picker("Категория", selection: $kind) {
                                Text("Вопрос").tag("question")
                                Text("Ошибка").tag("bug")
                                Text("Предложение").tag("suggestion")
                                Text("Аккаунт").tag("account")
                                Text("Другое").tag("other")
                            }.tint(pumpkin).padding(10).frostedGlass()
                            TextField("Описание", text: $message, axis: .vertical)
                                .lineLimit(3...7).padding().frostedGlass()
                            Button("Создать обращение") { Task { await create() } }.buttonStyle(.borderedProminent).tint(pumpkin)
                                .disabled(subject.count < 4 || message.count < 5 || busy)
                        }
                        Text(adminMode ? "Все обращения" : "Мои обращения").font(.title3.bold()).foregroundStyle(.white)
                        ForEach(tickets) { item in
                            Button { Task { await open(item.id) } } label: {
                                HStack { Text(item.subject); Spacer(); Text(statusNames[item.status] ?? item.status).font(.caption) }
                                    .frame(maxWidth: .infinity).padding().frostedGlass()
                            }.buttonStyle(.plain)
                        }
                    }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }.background(Color.clear)
                .navigationTitle("Обращения")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { close() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .bold))
                                .frame(width: 30, height: 30)
                                .nightwellLiquidGlass(15)
                        }.tint(pumpkin)
                    }
                }
        }
                .nightwellLiquidGlass(32)
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .sheet(item: $previewItem) { item in
            NavigationStack {
                SupportFilePreview(url: item.url)
                    .navigationTitle("Вложение")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { previewItem = nil } label: { Image(systemName: "xmark").fontWeight(.semibold) }
                                .accessibilityLabel("Закрыть вложение")
                                .tint(pumpkin)
                        }
                    }
            }
            .presentationDetents([.large])
        }
        .confirmationDialog("Откуда прикрепить?", isPresented: $showAttachmentSources) {
            Button("Выбрать из файлов") { importFile = true }
            Button("Выбрать из галереи") { showGallery = true }
        }
        .photosPicker(isPresented: $showGallery, selection: $selectedPhoto, matching: .images)
        .onChange(of: selectedPhoto) { item in
            guard let item, let ticket = selected else { return }
            Task {
                uploading = true
                attachmentStatus = "Загрузка изображения…"
                defer { uploading = false; selectedPhoto = nil }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw APIError(message: "Не удалось получить фотографию")
                    }
                    guard let image = UIImage(data: data), let jpeg = image.jpegData(compressionQuality: 0.85) else {
                        throw APIError(message: "Не удалось обработать изображение")
                    }
                    try await store.api.uploadSupportAttachment(ticketID: ticket.id, name: UUID().uuidString + ".jpg", data: jpeg)
                    await open(ticket.id)
                    attachmentStatus = "Фото прикреплено"
                } catch { attachmentStatus = "Ошибка: " + error.localizedDescription }
            }
        }
        .fileImporter(isPresented: $importFile, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            guard let ticket = selected else { return }
            Task {
                uploading = true
                defer { uploading = false }
                do {
                    let files = try result.get()
                    guard !files.isEmpty else { return }
                    var completed = 0
                    for (index, file) in files.enumerated() {
                        attachmentStatus = "Загрузка \(index + 1) из \(files.count)…"
                        let accessed = file.startAccessingSecurityScopedResource()
                        defer { if accessed { file.stopAccessingSecurityScopedResource() } }
                        var coordinationError: NSError?
                        var readError: Error?
                        var data: Data?
                        let coordinator = NSFileCoordinator(filePresenter: nil)
                        coordinator.coordinate(readingItemAt: file, options: [], error: &coordinationError) { readableURL in
                            do { data = try Data(contentsOf: readableURL) }
                            catch { readError = error }
                        }
                        if let coordinationError { throw coordinationError }
                        if let readError { throw readError }
                        guard let data else { throw APIError(message: "Не удалось прочитать выбранный файл") }
                        guard data.count <= 10 * 1024 * 1024 else {
                            throw APIError(message: "Файл \(file.lastPathComponent) больше 10 МБ")
                        }
                        try await store.api.uploadSupportAttachment(ticketID: ticket.id, name: file.lastPathComponent, data: data)
                        completed += 1
                    }
                    await open(ticket.id)
                    attachmentStatus = "Прикреплено файлов: \(completed)"
                } catch {
                    attachmentStatus = "Ошибка загрузки: " + error.localizedDescription
                }
            }
        }
        .background(Color.clear)
        .nightwellLiquidGlass(32)
        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
        .task { await refresh() }
    }
    private func preview(_ id: String, _ attachment: SupportAttachment) async {
        do {
            let downloaded = try await store.api.downloadSupportAttachment(ticketID: id, attachmentID: attachment.id)
            let destination = downloaded.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + "-" + attachment.name)
            try FileManager.default.moveItem(at: downloaded, to: destination)
            previewItem = SupportPreviewItem(url: destination)
        } catch { self.error = error.localizedDescription }
    }
    private func refresh() async {
        do {
            let result: TicketList = try await store.api.request("/api/support/" + (adminMode ? "admin/" : "") + "tickets")
            tickets = result.tickets
            error = ""
        } catch { self.error = error.localizedDescription }
    }
    private func open(_ id: String) async {
        do {
            let item: SupportTicket = try await store.api.request(path(id))
            selected = item
            error = ""
        } catch { self.error = error.localizedDescription }
    }
    private func create() async {
        busy = true; defer { busy = false }
        do {
            let result: TicketCreated = try await store.api.request("/api/support/tickets", method: "POST",
                body: ["subject": subject, "kind": kind, "body": message])
            subject = ""; message = ""
            await refresh(); await open(result.id)
        } catch { self.error = error.localizedDescription }
    }
    private func reply(_ id: String) async {
        busy = true; defer { busy = false }
        do {
            let _: OK = try await store.api.request(path(id) + "/messages", method: "POST", body: ["body": message])
            message = ""; await open(id); await refresh()
        } catch { self.error = error.localizedDescription }
    }
    private func updateStatus(_ id: String, _ status: String) async {
        do {
            let _: OK = try await store.api.request(path(id) + "/status", method: "PATCH", body: ["status": status])
            await open(id); await refresh()
        } catch { self.error = error.localizedDescription }
    }
}
