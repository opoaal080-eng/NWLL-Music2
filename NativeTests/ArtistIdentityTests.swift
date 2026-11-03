import XCTest
@testable import NightwellMusic

final class ArtistIdentityTests: XCTestCase {
    func testTitleArtistWinsOverSoundCloudUploader() {
        let song = Track(id: "a", title: "Audiosoulz - Dancefloor",
                         artist: "RandomUploader", source: "soundcloud",
                         source_url: "https://soundcloud.com/random/track")
        let profile = ArtistIdentity.selection(for: song)
        XCTAssertEqual(profile?.name, "Audiosoulz")
        XCTAssertEqual(profile?.titleDerived, true)
    }

    func testUploaderIsNeverAnArtistByItself() {
        let song = Track(id: "a", title: "Dancefloor", artist: "random uploader",
                         source: "soundcloud")
        XCTAssertNil(ArtistIdentity.selection(for: song))
    }

    func testSoundCloudUploaderOtherSongsDoNotJoinProfile() throws {
        let seed = Track(id: "1", title: "Audiosoulz - Missing",
                         artist: "Uploader", source: "soundcloud")
        let profile = try XCTUnwrap(ArtistIdentity.selection(for: seed))
        let byAnotherArtist = Track(id: "2", title: "Different Artist - Another Song",
                                    artist: "Uploader", source: "soundcloud")
        let matching = Track(id: "3", title: "Audiosoulz - Dancefloor",
                             artist: "OtherUploadAccount", source: "soundcloud")
        XCTAssertFalse(ArtistIdentity.belongs(byAnotherArtist, to: profile))
        XCTAssertTrue(ArtistIdentity.belongs(matching, to: profile))
        XCTAssertEqual(ArtistIdentity.unique([seed, seed, byAnotherArtist, matching], for: profile).count, 2)
    }

    func testDedicatedArtistNameOverridesCloudAccount() {
        var song = Track(id: "1", title: "Missing", artist: "Some account", source: "soundcloud")
        song.artist_name = "Audiosoulz"
        let artist = ArtistIdentity.selection(for: song)
        XCTAssertEqual(artist?.name, "Audiosoulz")
        XCTAssertNotNil(artist)
    }

    func testGenericUploadAccountsAreExcluded() {
        let song = Track(id: "1", title: "Weekend Mix",
                         artist: "Music", source: "soundcloud")
        XCTAssertNil(ArtistIdentity.selection(for: song))
    }
}
