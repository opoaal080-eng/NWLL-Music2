import Foundation

@main struct DeviceTransferMatcherTests {
    static func main() throws {
        let input = #"[{"title":"Звезда","artist":"Кино","duration":180},{"title":"Неведомая","artist":"Кино"},{"title":"Song","artist":"Artist","duration":180}]"#
        let catalog = #"[{"id":"one","title":"Кино - Звезда (Official Audio)","artist":"Uploader","duration":180},{"id":"two","title":"Song remix","artist":"Artist","duration":180},{"id":"three","title":"Song","artist":"Artist","duration":40}]"#
        let items = try DeviceTransferMatcher.match(prepared: input, catalogJSON: Data(catalog.utf8), mode: "wide")
        precondition(items.count == 3)
        precondition(items[0]["track_id"] as? String == "one")
        precondition(items[1]["track_id"] is NSNull)
        precondition(items[2]["track_id"] is NSNull)
        precondition(items[1]["reason"] as? String != nil)
        print("Device matching: composite performers, missing tracks, version/duration guards passed")
    }
}
