import Foundation

@main struct TransferFeatureExporter {
    static func main() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let rows = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
        let features: [[Double]] = rows.map { row in
            let query = TransferMetadata(row["query"] as! [String: Any])
            let candidate = TransferMetadata(row["candidate"] as! [String: Any])
            return TransferSimilarity.compare(query,candidate)?.features ?? Array(repeating: 0,count: 16)
        }
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: features))
    }
}
