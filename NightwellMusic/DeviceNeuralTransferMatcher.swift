import Foundation

/// Optional on-device neural matching for playlist transfers.
/// No neural model, training data or track list is sent to an AI server.
enum DeviceNeuralTransferMatcher {
    private struct Candidate {
        let id: String
        let rawTitle: String
        let rawArtist: String
        let title: String
        let artist: String
        let duration: Double
    }

    private static let versionWords: Set<String> = [
        "live", "remix", "remiks", "concert", "acoustic", "akustika",
        "instrumental", "karaoke", "cover", "kaver", "remaster",
        "remastered", "sped", "slowed", "edit", "reverb"
    ]
    private static let russian = Array("абвгдежзийклмнопрстуфхцчшщыэюя")
    private static let latin = ["a", "b", "v", "g", "d", "e", "zh", "z", "i", "y", "k",
                                "l", "m", "n", "o", "p", "r", "s", "t", "u", "f", "h",
                                "ts", "ch", "sh", "sch", "y", "e", "yu", "ya"]
    private static let transliteration: [Character: String] =
        Dictionary(uniqueKeysWithValues: zip(russian, latin))

    private static func key(_ value: String) -> String {
        let source = value.precomposedStringWithCompatibilityMapping.lowercased()
            .replacingOccurrences(of: "ё", with: "е")
            .replacingOccurrences(
                of: #"\b(?:official\s+(?:music\s+)?(?:video|audio)|lyrics?\s+video|official|lyrics?|hq|hd|4k)\b"#,
                with: " ", options: .regularExpression)
        let letters = source.map { character -> String in
            if let replacement = transliteration[character] { return replacement }
            return character.isLetter || character.isNumber ? String(character) : " "
        }.joined()
        return letters.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
    private static func tokens(_ value: String) -> Set<String> {
        Set(value.split(separator: " ").map(String.init))
    }
    private static func overlap(_ left: String, _ right: String) -> Double {
        let a = tokens(left), b = tokens(right)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        return Double(a.intersection(b).count) / Double(max(a.count, b.count))
    }
    private static func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        guard !a.isEmpty, !b.isEmpty, a.count <= 140, b.count <= 140 else { return 0 }
        let x = Array(a), y = Array(b)
        var previous = Array(0...y.count)
        for i in x.indices {
            var current = [i + 1] + [Int](repeating: 0, count: y.count)
            for j in y.indices {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1,
                                     previous[j] + (x[i] == y[j] ? 0 : 1))
            }
            previous = current
        }
        return max(0, 1 - Double(previous[y.count]) / Double(max(x.count, y.count)))
    }
    private static func version(_ s: String) -> Set<String> {
        tokens(s).intersection(versionWords)
    }
    private static func vector(_ title: String, _ artist: String, _ duration: Double,
                               _ candidate: Candidate) -> [Double] {
        let dt = duration > 0 && candidate.duration > 0
            ? max(0, 1 - abs(duration - candidate.duration) / max(14, duration * 0.13)) : 1.0
        return [similarity(title, candidate.title), similarity(artist, candidate.artist),
                overlap(title, candidate.title), overlap(artist, candidate.artist),
                dt, version(title) == version(candidate.title) ? 1 : 0,
                title == candidate.title ? 1 : 0, artist == candidate.artist ? 1 : 0]
    }

    // Eight inputs, ten hidden tanh units, one sigmoid output. Train from
    // the user's downloaded catalogue on the device, not in the cloud.
    private struct Network {
        var inputWeights = [[Double]](repeating: [Double](repeating: 0, count: 8), count: 10)
        var inputBias = [Double](repeating: 0, count: 10)
        var outputWeights = [Double](repeating: 0, count: 10)
        var outputBias = 0.0

        init() {
            var seed: UInt64 = 0x9e3779b97f4a7c15
            func random() -> Double {
                seed = seed &* 2862933555777941757 &+ 3037000493
                return Double((seed >> 32) & 0xffff) / 65535.0 - 0.5
            }
            for j in 0..<10 {
                for i in 0..<8 { inputWeights[j][i] = random() * 0.6 }
                outputWeights[j] = random() * 0.6
            }
        }
        private static func sigmoid(_ value: Double) -> Double {
            1 / (1 + exp(-max(-30, min(30, value))))
        }
        func predict(_ features: [Double]) -> Double {
            var sum = outputBias
            for j in 0..<10 {
                var weighted = inputBias[j]
                for i in 0..<8 { weighted += inputWeights[j][i] * features[i] }
                sum += outputWeights[j] * tanh(weighted)
            }
            return Self.sigmoid(sum)
        }
        mutating func learn(_ features: [Double], label: Double) {
            var hidden = [Double](repeating: 0, count: 10)
            var sum = outputBias
            for j in 0..<10 {
                var weighted = inputBias[j]
                for i in 0..<8 { weighted += inputWeights[j][i] * features[i] }
                hidden[j] = tanh(weighted)
                sum += outputWeights[j] * hidden[j]
            }
            let gradient = Self.sigmoid(sum) - label
            let oldOutput = outputWeights
            for j in 0..<10 {
                outputWeights[j] -= 0.055 * gradient * hidden[j]
                let hiddenGradient = gradient * oldOutput[j] * (1 - hidden[j] * hidden[j])
                for i in 0..<8 { inputWeights[j][i] -= 0.055 * hiddenGradient * features[i] }
                inputBias[j] -= 0.055 * hiddenGradient
            }
            outputBias -= 0.055 * gradient
        }
    }

    /// The standard matcher wins whenever it already found a trustworthy ID.
    /// Neural ranking only tries to recover missing or ambiguous entries.
    static func match(prepared: String, catalogJSON: Data,
                      mode: String = "balanced") throws -> [[String: Any]] {
        var base = try DeviceTransferMatcher.match(
            prepared: prepared, catalogJSON: catalogJSON, mode: mode)
        guard base.contains(where: { $0["track_id"] as? String == nil }) else { return base }
        guard let catalog = try JSONSerialization.jsonObject(with: catalogJSON) as? [[String: Any]]
        else { return base }

        var candidates: [Candidate] = []
        var byTitle: [String: [Int]] = [:], byArtist: [String: [Int]] = [:]
        func index(_ table: inout [String: [Int]], key: String, value: Int) {
            guard !key.isEmpty, table[key, default: []].count < 350 else { return }
            table[key, default: []].append(value)
        }
        for item in catalog.prefix(80_000) {
            guard let id = item["id"] as? String, !id.isEmpty, id.count <= 100,
                  let rawTitle = item["title"] as? String,
                  let rawArtist = item["artist"] as? String else { continue }
            let title = key(rawTitle), artist = key(rawArtist)
            guard !title.isEmpty, !artist.isEmpty else { continue }
            let candidate = Candidate(id: id, rawTitle: rawTitle, rawArtist: rawArtist,
                                      title: title, artist: artist,
                                      duration: (item["duration"] as? NSNumber)?.doubleValue ?? 0)
            let n = candidates.count
            candidates.append(candidate)
            index(&byTitle, key: title, value: n)
            index(&byArtist, key: artist, value: n)
            for word in title.split(separator: " ").prefix(6) where word.count >= 4 {
                index(&byTitle, key: String(word), value: n)
            }
        }
        guard candidates.count >= 2 else { return base }

        var network = Network()
        // Bounded local training avoids taking minutes or exhausting memory
        // on battery-powered devices. No remote model or GPU is required.
        let training = Array(candidates.prefix(800))
        for _ in 0..<4 {
            try Task.checkCancellation()
            for (i, sample) in training.enumerated() {
                if i.isMultiple(of: 64) { try Task.checkCancellation() }
                let positive = vector(sample.title, sample.artist, sample.duration, sample)
                network.learn(positive, label: 1)
                let another = training[(i + 17) % training.count]
                network.learn(vector(sample.title, sample.artist, sample.duration, another), label: 0)
                network.learn(vector(sample.title, another.artist, sample.duration, sample), label: 0)
            }
        }

        for row in base.indices {
            if row.isMultiple(of: 8) { try Task.checkCancellation() }
            guard base[row]["track_id"] as? String == nil,
                  let rawTitle = base[row]["title"] as? String,
                  let rawArtist = base[row]["artist"] as? String else { continue }
            let title = key(rawTitle), artist = key(rawArtist)
            let duration = (base[row]["duration"] as? NSNumber)?.doubleValue ?? 0
            var possible = Set(byTitle[title] ?? [])
            possible.formUnion((byArtist[artist] ?? []).prefix(160))
            for word in title.split(separator: " ").prefix(4) where word.count >= 4 {
                possible.formUnion((byTitle[String(word)] ?? []).prefix(120))
            }
            // Fuzzy recovery: consider title tokens even if one is misspelled or missing.
            // Keep the candidate set bounded for mobile CPU/battery use.
            if possible.count < 40 {
                let queryWords = title.split(separator: " ").map(String.init)
                    .filter { $0.count >= 4 }
                if !queryWords.isEmpty {
                    for (token, positions) in byTitle {
                        guard token.count >= 4,
                              queryWords.contains(where: { similarity($0, token) >= 0.72 })
                        else { continue }
                        possible.formUnion(positions.prefix(80))
                        if possible.count >= 900 { break }
                    }
                }
            }
            // When a remote query yields a small set, rank every candidate.
            // An otherwise correct track may have typos in both artist and title.
            if candidates.count <= 250 { possible.formUnion(candidates.indices) }
            var scored: [(Double, Int)] = []
            for n in possible.sorted().prefix(500) {
                let candidate = candidates[n]
                let input = vector(title, artist, duration, candidate)
                let titleMin = mode == "wide" ? 0.76 : mode == "safe" ? 0.90 : 0.82
                let artistMin = mode == "wide" ? 0.68 : mode == "safe" ? 0.87 : 0.78
                guard input[0] >= titleMin, input[1] >= artistMin, input[5] == 1 else { continue }
                if duration > 0, candidate.duration > 0,
                   abs(duration - candidate.duration) > max(14, duration * 0.13) { continue }
                let probability = network.predict(input)
                let confidence = 0.39 * input[0] + 0.22 * input[1]
                               + 0.24 * probability + 0.15 * input[2]
                scored.append((confidence, n))
            }
            scored.sort { $0.0 > $1.0 }
            let minimum = mode == "wide" ? 0.82 : mode == "safe" ? 0.92 : 0.87
            guard let first = scored.first, first.0 >= minimum else { continue }
            if scored.count > 1 && first.0 < 0.985 && first.0 - scored[1].0 < 0.025 { continue }
            let winner = candidates[first.1]
            base[row]["track_id"] = winner.id
            base[row]["found_title"] = winner.rawTitle
            base[row]["found_artist"] = winner.rawArtist
            base[row]["reason"] = ""
        }
        return base
    }
}
