import Foundation

func ensure(_ predicate: @autoclosure () -> Bool, _ message: String) {
    if !predicate() { fatalError(message) }
}

let remotelyUploaded = ArtistAttribution.resolve(
    title: "Клава Кока - Покинула чат", artist: "some_upload_account",
    source: "soundcloud", remote: true)
ensure(remotelyUploaded.artist == "Клава Кока", "must credit performer from title")
ensure(remotelyUploaded.title == "Покинула чат", "must clean artist prefix from title")
ensure(remotelyUploaded.uploader == "some_upload_account", "must preserve upload attribution")

let unnamed = ArtistAttribution.resolve(
    title: "Покинула чат", artist: "random uploader", source: "soundcloud")
ensure(unnamed.artist == ArtistAttribution.unknown, "uploader must not become artist")
ensure(!unnamed.attributed, "uncredited remote song must not open a fake artist profile")

let realMetadata = ArtistAttribution.resolve(
    title: "Песня", artist: "uploaded_by_99", source: "soundcloud",
    performer: "Настоящий артист")
ensure(realMetadata.artist == "Настоящий артист", "explicit performer wins")
let collaboration = ArtistAttribution.resolve(
    title: "Клава Кока, NILETTO — Краш", artist: "music_uploader", remote: true)
ensure(collaboration.artist == "Клава Кока, NILETTO", "collaborations should survive")
ensure(collaboration.title == "Краш", "should remove artist name from title")

let local = ArtistAttribution.resolve(title: "Песня", artist: "Исполнитель", source: "local")
ensure(local.artist == "Исполнитель", "keep local tags")

let version = ArtistAttribution.resolve(title: "Песня - Remix", artist: "someUploader", source: "soundcloud")
ensure(version.artist == ArtistAttribution.unknown, "do not take track name as artist")
ensure(ArtistAttribution.isRemote(source: nil, sourceURL: "https://soundcloud.com/example/track", remote: nil),
       "remote source URLs should be detected")
print("Artist attribution regression tests passed")


let sample = """
{"id":"track_one","title":"Клава Кока - Покинула чат",
 "artist":"uploader_123","source":"soundcloud","is_remote":true}
"""
let decoded = try JSONDecoder().decode(Track.self, from: Data(sample.utf8))
ensure(decoded.title == "Покинула чат", "decoded title must strip artist prefix")
ensure(decoded.artist == "Клава Кока", "decoder must not display uploader")
ensure(decoded.uploader == "uploader_123", "upload account must be preserved separately")
let encoded = try JSONEncoder().encode(decoded)
let restored = try JSONDecoder().decode(Track.self, from: encoded)
ensure(restored.artist == decoded.artist, "cached artist must survive repeated decoding")
ensure(restored.title == decoded.title, "cached title must survive repeated decoding")
let unknownRaw = """
{"id":"track_two","title":"Загадочный трек",
 "artist":"dj_uploads_999","source":"soundcloud","is_remote":true}
"""
let unknownTrack = try JSONDecoder().decode(Track.self, from: Data(unknownRaw.utf8))
ensure(unknownTrack.artist == ArtistAttribution.unknown, "decode cannot credit a random uploader")
