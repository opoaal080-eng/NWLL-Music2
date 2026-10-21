import Foundation

struct Track: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var artist: String
    var album: String?
    var duration: Double?
    var cover_url: String?
    var source: String?
    var source_url: String?
    var is_remote: Bool?
    var _offline: Bool?
    var _offline_account: String?
    var _offline_lyrics: Lyrics?
    var dictionary: [String: Any] {
        guard let data = try? JSONEncoder().encode(self), let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return value
    }
}
struct Playlist: Identifiable, Codable { let id: String; let name: String }
struct Account: Codable { let id: String; let email: String; let is_admin: Bool? }
struct Identity: Codable { let user: Account?; let csrf: String? }
struct TrackResult: Codable {
    var tracks: [Track]
    var message: String?
    var search_pending: Bool?
    var search_retry_after: Double?
    var search_message: String?
}
struct LikeResult: Codable { let ids: [String] }
struct PlaylistResult: Codable { let playlists: [Playlist] }
struct Lyrics: Codable, Equatable {
    struct Line: Codable, Equatable { let time: Double; let text: String }
    var status: String?
    var plain: String?
    var lines: [Line]?
    var synced: Bool?
    var source: String?
    var retry_after: Double?
    var message: String?
    var lookup_complete: Bool?
    var searching: Bool { status == "loading" || status == "pending" }
}
struct ShareResult: Codable { let path: String }
struct OK: Codable { var ok: Bool? }
struct APIError: LocalizedError { let message: String; var errorDescription: String? { message } }

protocol LyricsService: Sendable {
    func fetchLyrics(_ id: String) async throws -> Lyrics
}

actor MusicAPI: LyricsService {
    let origin: URL
    private let session: URLSession
    private var csrf = ""
    init(origin: URL) {
        self.origin = origin
        let config = URLSessionConfiguration.default
        config.httpCookieStorage = .shared
        config.httpShouldSetCookies = true
        config.timeoutIntervalForRequest = 25
        config.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024, diskCapacity: 40 * 1024 * 1024, diskPath: "native-api")
        session = URLSession(configuration: config)
    }
    func setCSRF(_ value: String?) { csrf = value ?? "" }
    func request<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> T {
        guard let url = URL(string: path, relativeTo: origin), url.host == origin.host, url.scheme == "https" else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if method != "GET" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(csrf, forHTTPHeaderField: "X-CSRF-Token")
            request.httpBody = try JSONSerialization.data(withJSONObject: body ?? [:])
        }
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw APIError(message: message ?? "Сервер недоступен. Повтори попытку.")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    func downloadSupportAttachment(ticketID: String, attachmentID: String) async throws -> URL {
        guard let url = URL(string: "api/support/tickets/" + ticketID + "/attachments/" + attachmentID, relativeTo: origin) else { throw URLError(.badURL) }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError(message: "Не удалось открыть вложение")
        }
        guard data.count <= 10 * 1024 * 1024 else { throw APIError(message: "Файл слишком большой") }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: destination, options: .atomic)
        return destination
    }
    func uploadSupportAttachment(ticketID: String, name: String, data: Data) async throws {
        guard !data.isEmpty, data.count <= 10 * 1024 * 1024 else { throw APIError(message: "Максимум 10 МБ") }
        guard let url = URL(string: "api/support/tickets/" + ticketID + "/attachments", relativeTo: origin) else { throw URLError(.badURL) }
        let boundary = "Nightwell" + UUID().uuidString
        var body = Data()
        body.append(Data(("--" + boundary + "\r\nContent-Disposition: form-data; name=\"file\"; filename=\"" + name.replacingOccurrences(of: "\"", with: "_") + "\"\r\nContent-Type: application/octet-stream\r\n\r\n").utf8))
        body.append(data)
        body.append(Data(("\r\n--" + boundary + "--\r\n").utf8))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(csrf, forHTTPHeaderField: "X-CSRF-Token")
        request.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (responseData, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let obj = (try? JSONSerialization.jsonObject(with: responseData) as? [String: Any])
            throw APIError(message: obj?["error"] as? String ?? "Не удалось прикрепить файл")
        }
    }
    func fetchLyrics(_ id: String) async throws -> Lyrics { try await request("/api/lyrics/" + id) }
    func export(_ id: String) async throws -> Data {
        let url = URL(string: "api/offline-export/" + id + "?download=true&wait=true", relativeTo: origin)!
        var request = URLRequest(url: url); request.timeoutInterval = 300
        let (file, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw APIError(message: "Трек пока нельзя скачать") }
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= OfflineStore.limit else { throw APIError(message: "Слишком большой файл") }
        return try Data(contentsOf: file)
    }
}

