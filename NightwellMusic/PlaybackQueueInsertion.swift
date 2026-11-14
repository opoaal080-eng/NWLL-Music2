// Manual requests sit ahead of the remaining source playlist. These edits
// never replace the current entry or reorder the unrequested source tracks.
enum PlaybackQueueInsertion {
    struct Edit<Element> {
        let tracks: [Element]
        let index: Int
        let queuedIDs: Set<String>
    }

    static func inserting<Element>(
        _ track: Element, into tracks: [Element], currentIndex: Int,
        queuedIDs: Set<String>, next: Bool = false, limit: Int = 1000,
        id: (Element) -> String
    ) -> Edit<Element>? {
        guard tracks.indices.contains(currentIndex) else { return nil }
        let requestedID = id(track)
        guard !requestedID.isEmpty, id(tracks[currentIndex]) != requestedID else { return nil }
        let alreadyPresent = tracks.contains { id($0) == requestedID }
        guard alreadyPresent || tracks.count < limit else { return nil }

        // Move an existing occurrence rather than creating duplicate IDs: queue
        // selection, metadata and restoration identify entries by track ID.
        let removedBeforeCurrent = tracks.prefix(currentIndex).filter { id($0) == requestedID }.count
        let remaining = tracks.filter { id($0) != requestedID }
        let index = currentIndex - removedBeforeCurrent
        let historyAndCurrent = Array(remaining.prefix(index + 1))
        let future = remaining.dropFirst(index + 1)
        var manual = future.filter { queuedIDs.contains(id($0)) }
        let source = future.filter { !queuedIDs.contains(id($0)) }
        if next { manual.insert(track, at: 0) }
        else { manual.append(track) }
        return Edit(tracks: historyAndCurrent + manual + source, index: index,
                    queuedIDs: Set(manual.map(id)))
    }

    // Manual requests remain first even when the source playlist is shuffled.
    static func nextQueuedIndex<Element>(
        in tracks: [Element], after index: Int, queuedIDs: Set<String>,
        id: (Element) -> String
    ) -> Int? {
        guard tracks.indices.contains(index) else { return nil }
        return tracks.indices.first { $0 > index && queuedIDs.contains(id(tracks[$0])) }
    }
}
