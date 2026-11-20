import XCTest
@testable import NightwellMusic

final class AudioStreamPrefetchTests: XCTestCase {
    func testProofExpiresAndRejectsClockRollback() {
        XCTAssertTrue(AudioStreamPrefetch.isFresh(100, now: 124))
        XCTAssertFalse(AudioStreamPrefetch.isFresh(100, now: 125))
        XCTAssertFalse(AudioStreamPrefetch.isFresh(100, now: 160))
        XCTAssertFalse(AudioStreamPrefetch.isFresh(100, now: 99))
    }

    func testMediaPlaylistReference() {
        let playlist = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:7
        #EXTINF:6.0,
        segment0.ts
        #EXTINF:7.0,
        segment1.ts
        """
        XCTAssertEqual(AudioStreamPrefetch.firstPlaylistReference(playlist), "segment0.ts")
        XCTAssertNil(AudioStreamPrefetch.firstPlaylistReference("<html>login</html>"))
    }

    func testMasterPlaylistReference() {
        let master = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=128000
        low/playlist.m3u8
        """
        XCTAssertEqual(AudioStreamPrefetch.firstPlaylistReference(master), "low/playlist.m3u8")
        XCTAssertNil(AudioStreamPrefetch.firstPlaylistReference("#EXTM3U\n#EXT-X-ENDLIST"))
    }

    func testProbeHostBoundary() {
        let origin = URL(string: "https://music.nightwell.fun/")!
        XCTAssertTrue(AudioStreamPrefetch.sameOrigin(origin,
            URL(string: "https://music.nightwell.fun/api/stream/track")!))
        XCTAssertTrue(AudioStreamPrefetch.sameOrigin(origin,
            URL(string: "https://music.nightwell.fun:443/media/segment.ts")!))
        XCTAssertFalse(AudioStreamPrefetch.sameOrigin(origin,
            URL(string: "http://music.nightwell.fun/api/stream/track")!))
        XCTAssertFalse(AudioStreamPrefetch.sameOrigin(origin,
            URL(string: "https://cdn.nightwell.fun/media/segment.ts")!))
        XCTAssertFalse(AudioStreamPrefetch.sameOrigin(origin,
            URL(string: "https://music.nightwell.fun:8443/media/segment.ts")!))
        XCTAssertFalse(AudioStreamPrefetch.sameOrigin(origin,
            URL(string: "https://user:pass@music.nightwell.fun/")!))
    }
}
