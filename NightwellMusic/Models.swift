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

    // The original posting account is kept separately for diagnostics; it is not an artist.
    var uploader: String?
    var performer: String?
    var artist_credit: String?
    var metadata_artist: String?
    var _artist_checked: Bool?

    init(id: String, title: String, artist: String, album: String? = nil,
         duration: Double? = nil, cover_url: String? = nil, source: String? = nil,
         source_url: String? = nil, is_remote: Bool? = nil, _offline: Bool? = nil,
         _offline_account: String? = nil, _offline_lyrics: Lyrics? = nil,
         uploader: String? = nil, performer: String? = nil, artist_credit: String? = nil,
         metadata_artist: String? = nil,
         _artist_checked: Bool? = nil) {
        self.id = id; self.title = title; self.artist = artist
        self.album = album; self.duration = duration; self.cover_url = cover_url
        self.source = source; self.source_url = source_url; self.is_remote = is_remote
        self._offline = _offline; self._offline_account = _offline_account
        self._offline_lyrics = _offline_lyrics
        self.uploader = uploader; self.performer = performer
        self.artist_credit = artist_credit; self.metadata_artist = metadata_artist
        self._artist_checked = _artist_checked
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, artist, album, duration, cover_url, source, source_url, is_remote
        case _offline, _offline_account, _offline_lyrics, uploader, performer, artist_credit, metadata_artist, _artist_checked
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .id)
        let title = try c.decode(String.self, forKey: .title)
        let artist = try c.decode(String.self, forKey: .artist)
        let album = try c.decodeIfPresent(String.self, forKey: .album)
        let duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        let cover = try c.decodeIfPresent(String.self, forKey: .cover_url)
        let source = try c.decodeIfPresent(String.self, forKey: .source)
        let sourceURL = try c.decodeIfPresent(String.self, forKey: .source_url)
        let isRemote = try c.decodeIfPresent(Bool.self, forKey: .is_remote)
        let offline = try c.decodeIfPresent(Bool.self, forKey: ._offline)
        let offlineAccount = try c.decodeIfPresent(String.self, forKey: ._offline_account)
        let lyrics = try c.decodeIfPresent(Lyrics.self, forKey: ._offline_lyrics)
        let storedUploader = try c.decodeIfPresent(String.self, forKey: .uploader)
        let performer = try c.decodeIfPresent(String.self, forKey: .performer)
        let credit = try c.decodeIfPresent(String.self, forKey: .artist_credit)
        let metadataArtist = try c.decodeIfPresent(String.self, forKey: .metadata_artist)
        let previouslyChecked = try c.decodeIfPresent(Bool.self, forKey: ._artist_checked) == true
        let parsed = ArtistAttribution.resolve(
            title: title, artist: artist, source: source, sourceURL: sourceURL,
            remote: isRemote, performer: performer, artistCredit: credit,
            metadataArtist: metadataArtist
        )
        self.init(
            id: id, title: previouslyChecked ? title : parsed.title,
            artist: previouslyChecked ? artist : parsed.artist,
            album: album, duration: duration, cover_url: cover,
            source: source, source_url: sourceURL, is_remote: isRemote,
            _offline: offline, _offline_account: offlineAccount, _offline_lyrics: lyrics,
            uploader: storedUploader ?? (previouslyChecked ? nil : parsed.uploader),
            performer: performer, artist_credit: credit,
            metadata_artist: metadataArtist, _artist_checked: true
        )
    }

    var dictionary: [String: Any] {
        guard let data = try? JSONEncoder().encode(self),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return value
    }
}
struct Playlist: Identifiable, Codable { let id: String; let name: String }
struct CommunityPlaylist: Identifiable, Decodable {
    let id: String
    let name: String
    let author: String
    let count: Int
    let cover_url: String?
    let source_playlist_id: String?
}
struct CommunityPlaylistResults: Decodable { let playlists: [CommunityPlaylist] }
struct CommunityPlaylistDetailResponse: Decodable {
    struct Detail: Decodable {
        let id: String
        let name: String
        let tracks: [Track]
    }
    let playlist: Detail
}
struct MusicTasteResponse: Decodable {
    let artists: [String]
    let configured: Bool
}
struct MusicTasteSuggestions: Decodable { let artists: [ArtistDirectoryItem] }
struct CommunityPlaylist: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let author: String
    let count: Int
    let cover_url: String?
    let published_at: Double?
    let source_playlist_id: String?
    let tracks: [Track]?
}
struct CommunityPlaylistResults: Decodable { let playlists: [CommunityPlaylist] }
struct CommunityPlaylistDetail: Decodable { let playlist: CommunityPlaylist }
struct CommunityPublication: Decodable { let id: String; let name: String; let published: Bool }
struct SavedCommunityPlaylist: Decodable { let id: String; let name: String }
struct Account: Codable { let id: String; let email: String; let is_admin: Bool? }
struct Identity: Codable { let user: Account?; let csrf: String? }
struct TrackResult: Codable {
    var tracks: [Track]
    var message: String?
    var search_pending: Bool?
    var search_retry_after: Double?
    var search_message: String?
}
struct ArtistDirectoryItem: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    var image_url: String?
    var track_count: Int?
    var source: String?
}
struct ArtistDirectoryResults: Codable { let artists: [ArtistDirectoryItem] }
struct ArtistDirectoryProfile: Codable {
    let artist: ArtistDirectoryItem
    let tracks: [Track]
    let total: Int?
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
    func request<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil, timeout: TimeInterval? = nil) async throws -> T {
        guard let url = URL(string: path, relativeTo: origin), url.host == origin.host, url.scheme == "https" else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let timeout { request.timeoutInterval = timeout }
        if method != "GET" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(csrf, forHTTPHeaderField: "X-CSRF-Token")
            request.httpBody = try JSONSerialization.data(withJSONObject: body ?? [:])
        }
        return try await RequestRetry.run(readOnly: method == "GET") {
            let (data, response) = try await self.session.data(for: request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard (200..<300).contains(http.statusCode) else {
                let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                let message = payload?["error"] as? String ?? payload?["detail"] as? String
                throw RequestRetry.HTTPFailure(status: http.statusCode,
                    message: message ?? "Сервер недоступен. Повтори попытку.")
            }
            return try JSONDecoder().decode(T.self, from: data)
        }
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



struct EmailChallenge: Decodable {
    let id: String
    let action: String
    let email_hint: String
    let expires_at: Double
    let resend_at: Double
}

struct EmailAuthResponse: Decodable {
    let user: Account?
    let csrf: String?
    let challenge: EmailChallenge?
}


