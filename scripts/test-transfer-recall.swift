import Foundation

@main struct TransferRecallTests {
    static func check(_ value:Bool,_ message:String) { if !value { print(message); exit(1) } }
    static func main() throws {
        let data=try Data(contentsOf:URL(fileURLWithPath:"scripts/fixtures/transfer-recall.json"))
        let cases=try JSONSerialization.jsonObject(with:data) as! [[String:Any]]
        for item in cases {
            let input=try JSONSerialization.data(withJSONObject:[item["query"]!])
            let candidates=try JSONSerialization.data(withJSONObject:item["candidates"]!)
            let rows=try DeviceNeuralTransferMatcher.match(prepared:String(decoding:input,as:UTF8.self),catalogJSON:candidates,mode:item["mode"] as? String ?? "wide")
            let actual=rows[0]["track_id"] as? String, expected=item["expected"] as? String
            check(actual==expected,"\(item["name"]!): expected \(String(describing:expected)), got \(String(describing:actual)); \(rows)")
        }
        let target:[String:Any] = ["id":"target","title":"Лунная дорожка","artist":"Северный берег","duration":204]
        var large=(0..<1200).map { ["id":"other\($0)","title":"Лунная дорожка \($0)","artist":"Архив \($0)","duration":204] as [String:Any] }
        large.append(target)
        for title in ["Лунная дорожка","Лунная доржка"] {
            let query:[[String:Any]] = [["title":title,"artist":"Северный берг","duration":204]]
            let result=try DeviceNeuralTransferMatcher.match(prepared:String(decoding:JSONSerialization.data(withJSONObject:query),as:UTF8.self),catalogJSON:JSONSerialization.data(withJSONObject:large),mode:"wide")
            precondition(result[0]["track_id"] as? String=="target","Large catalogue candidate recall: \(result)")
        }
        let model=try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:"scripts/fixtures/transfer-model-v2.json"))) as! [String:Any]
        for row in model["parity"] as! [[String:Any]] {
            let prediction=TransferNeuralModel.predict(row["features"] as! [Double])
            precondition(abs(prediction-(row["probability"] as! Double))<0.000001,"Swift inference differs from trained model")
        }
        precondition(TransferNeuralModel.predict([.nan])==0)
        print("Transfer: \(cases.count) curated recording cases, large catalogue recall and model export parity passed")
    }
}
