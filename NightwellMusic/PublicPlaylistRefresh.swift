import Foundation

extension MusicStore {
    func refreshPublicPlaylistState() async {
        await refreshPublishedPlaylists()
    }
}
