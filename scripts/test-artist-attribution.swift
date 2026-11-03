import Foundation

func ensure(_ predicate: @autoclosure () -> Bool, _ message: String) {
    if !predicate() { fatalError(message) }
}

@main struct ArtistAttributionRegression {
    static func main() throws {
let remotelyUploaded = ArtistAttribution.resolve(
    title: "Клава Кока - Покинула чат", artist: "some_upload_account",
    source: "soundcloud", remote: true)
ensure(remotelyUploaded.artist == "Клава Кока", "must credit performer from title")
ensure(remotelyUploaded.title == "Покинула чат", "must clean artist prefix from title")
ensure(remotelyUploaded.uploader == "some_upload_account", "must preserve upload attribution")

let unnamed = ArtistAttribution.resolve(
    title: "Покинула чат", artist: "random uploader", source: "soundcloud")
ensure(unnamed.artist == "random uploader", "fall back to track artist field")
ensure(unnamed.attributed, "nonempty artist can open profile")

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
ensure(version.artist == "someUploader", "version title does not override artist field")
ensure(ArtistAttribution.isRemote(source: nil, sourceURL: "https://soundcloud.com/example/track", remote: nil),
       "remote source URLs should be detected")
print("Artist attribution regression tests passed")


    }
}
