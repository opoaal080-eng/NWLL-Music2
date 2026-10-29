import Foundation

private struct Example {
    let id: String
    let title: String
    let artist: String
}

@main
struct CheckRecommendations {
    static func main() {
        let tracks = [
            Example(id: "remix", title: "Ночной ритм (Ремикс)", artist: "Исполнитель"),
            Example(id: "studio", title: "Ночной ритм", artist: "Исполнитель"),
            Example(id: "live", title: "Ночной ритм (Концерт)", artist: "Исполнитель"),
            Example(id: "other", title: "Другая песня", artist: "Другая группа")
        ]
        func rank(_ query: String) -> [Example] {
            RecommendationOrder.rankSearch(tracks, query: query, title: { $0.title }, artist: { $0.artist })
        }
        precondition(rank("Ночной ритм").first?.id == "studio", "Original should beat an unrequested version")
        precondition(rank("Ночной ритм Ремикс").first?.id == "remix", "Explicit remix queries must still work")
        let blockedArtist = RecommendationOrder.arrange(tracks, hiddenArtists: ["исполнитель"],
            identity: { $0.id }, title: { $0.title }, artist: { $0.artist })
        precondition(blockedArtist.map(\.id) == ["other"], "Blocked artists must never reach autoplay")
        let blockedTrack = RecommendationOrder.arrange(tracks, hidden: ["studio"],
            identity: { $0.id }, title: { $0.title }, artist: { $0.artist })
        precondition(!blockedTrack.contains(where: { $0.id == "studio" }), "Disliked track leaked")
        let noDuplicates = RecommendationOrder.arrange([
            Example(id: "one", title: "Same", artist: "Artist"),
            Example(id: "two", title: "SAME!", artist: "Artist"),
            Example(id: "three", title: "New", artist: "Other")],
            identity: { $0.id }, title: { $0.title }, artist: { $0.artist })
        precondition(noDuplicates.count == 2, "Duplicate recordings must be collapsed")
        let first = SkipFeedback.next(nil, now: 1000)
        precondition(!SkipFeedback.blocked(first, now: 1000))
        let second = SkipFeedback.next(first, now: 2000)
        precondition(SkipFeedback.blocked(second, now: 2000))
        precondition(!SkipFeedback.blocked(second, now: 2000 + 48 * 3600))
        precondition(RecommendationOrder.presentedSearchResults(current: [1,2], incoming: [Int](), pending: true) == [1,2])
        precondition(RecommendationOrder.presentedSearchResults(current: [1,2], incoming: [Int](), pending: false).isEmpty)
        print("Recommendation ranking, preferences, search fallback and cooldown passed")
    }
}
