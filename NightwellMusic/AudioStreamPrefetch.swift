import Foundation

/// One bounded, low-priority check of an upcoming stream. A playlist HTTP 200
/// is NOT proof that its audio segments can be fetched. Only a fetched media
/// response may short-circuit the later handoff check.
enum AudioStreamPrefetch {
    enum Outcome {
        case failed
        case manifestOnly
        case audioBytes

        var available: Bool {
            switch self {
            case .failed: return false
            case .manifestOnly, .audioBytes: return true
            }
        }
        var verifiedAudio: Bool {
            if case .audioBytes = self { return true }
            return false
        }
    }

    static let proofLifetime: TimeInterval = 25

    static func isFresh(_ verifiedUptime: TimeInterval,
                        now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        let elapsed = now - verifiedUptime
        return elapsed >= 0 && elapsed < proofLifetime
    }

    /// Supports a master playlist, media playlist, and the first relative
    /// media reference. Never treat an arbitrary HTML/JSON page as audio.
    static func firstPlaylistReference(_ text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard lines.first(where: { !$0.isEmpty }) == "#EXTM3U" else { return nil }
        for line in lines where !line.isEmpty && !line.hasPrefix("#") {
            return line
        }
        return nil
    }

    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        guard let schemeA = a.scheme?.lowercased(),
              let schemeB = b.scheme?.lowercased(),
              let hostA = a.host?.lowercased(),
              let hostB = b.host?.lowercased(),
              (schemeA == "https" || schemeA == "http"),
              schemeA == schemeB,
              hostA == hostB,
              a.user == nil, a.password == nil,
              b.user == nil, b.password == nil else { return false }
        let defaultPort = schemeA == "https" ? 443 : 80
        return (a.port ?? defaultPort) == (b.port ?? defaultPort)
    }

    private struct Sample {
        let data: Data
        let mediaType: String
    }

    private static func readSample(_ url: URL, headers: [String: String]) async -> Sample? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 6
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.allHTTPHeaderFields = headers
        request.setValue("bytes=0-8191", forHTTPHeaderField: "Range")
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  http.url == url else { return nil }
            let kind = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            let manifest = kind.contains("mpegurl") || kind.contains("m3u8") ||
                url.pathExtension.lowercased() == "m3u8"
            let limit = manifest ? 8192 : 2048
            var result = Data()
            for try await byte in bytes {
                if Task.isCancelled { return nil }
                result.append(byte)
                if result.count >= limit { break }
            }
            guard !result.isEmpty else { return nil }
            return Sample(data: result, mediaType: kind)
        } catch {
            return nil
        }
    }

    static func check(_ url: URL, origin: URL, cookies: [HTTPCookie]) async -> Outcome {
        if url.isFileURL { return .audioBytes }
        // Maintain the existing fallback for external media, but never reuse
        // it as proven/preloaded audio or forward the Nightwell session cookie.
        guard sameOrigin(url, origin) else { return .manifestOnly }
        let headers = HTTPCookie.requestHeaderFields(with: cookies)
        var candidate = url
        var sawManifest = false
        // At most: master -> variant -> first segment. No recursive playlists.
        for depth in 0...2 {
            if Task.isCancelled { return .failed }
            guard sameOrigin(candidate, origin),
                  let sample = await readSample(candidate, headers: headers) else {
                return sawManifest ? .manifestOnly : .failed
            }
            let prefix = String(data: sample.data.prefix(64), encoding: .utf8) ?? ""
            let isPlaylist = prefix.hasPrefix("#EXTM3U") ||
                sample.mediaType.contains("mpegurl") ||
                sample.mediaType.contains("m3u8") ||
                candidate.pathExtension.lowercased() == "m3u8"
            if isPlaylist {
                sawManifest = true
                guard depth < 2,
                      let text = String(data: sample.data, encoding: .utf8),
                      let reference = firstPlaylistReference(text),
                      let next = URL(string: reference, relativeTo: candidate)?.absoluteURL,
                      sameOrigin(next, origin) else { return .manifestOnly }
                candidate = next
                continue
            }
            if sample.mediaType.contains("text/html") ||
                sample.mediaType.contains("application/json") ||
                sample.mediaType.contains("text/plain") ||
                prefix.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{") ||
                prefix.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") {
                return .failed
            }
            // Reading even a few actual bytes from a media segment is a
            // stronger signal than AVURLAsset.isPlayable + a manifest alone.
            return sample.data.count >= 128 ? .audioBytes : .failed
        }
        return .manifestOnly
    }
}
