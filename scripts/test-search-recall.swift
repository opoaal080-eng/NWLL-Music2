import Foundation

private struct Track {
    let id: String
    let title: String
    let artist: String
}
@main struct SearchRecallTests {
    static func main() {
        let exact = Track(id:"exact",title:"Звезда по имени Солнце",artist:"Кино")
        let partial = Track(id:"owned",title:"Звезда по имени Солнце (Live)",artist:"Кино")
        let filler = (0..<320).map { Track(id:"f\($0)",title:"Звезда по имени Солнце коллекция \($0)",artist:"Архив") }
        let all = [partial] + filler + [exact]
        func rank(_ query:String) -> [Track] {
            NightwellSearch.ordered(all,query:query,priorityIDs:["owned"],limit:140,
                id:{$0.id},title:{$0.title},artist:{$0.artist})
        }
        for query in ["Звезда по имени Солнце", "«ЗВЕЗДА ПО ИМЕНИ СОЛНЦЕ»", "Кино — Звезда по имени Солнце", "Zvezda po imeni Solntse"] {
            precondition(rank(query).first?.id == "exact", "Exact hit lost: \(query)")
        }
        precondition(rank("Звезда по имени Солнце Live").first?.id == "owned")
        let typo = NightwellSearch.Query("Звезда по имени Солнц")
        precondition(typo.score(title:exact.title,artist:exact.artist)>0)
        precondition(NightwellSearch.Query("Blnding Lights").score(title:"Blinding Lights",artist:"Performer")>0)
        precondition(NightwellSearch.Query("Live Forever").score(title:"Live Forever",artist:"Group")==10000)
        precondition(NightwellSearch.Query("Song").score(title:"Song (Official Audio)",artist:"Singer")>=9500)
        var pool = NightwellSearch.Pool<Track>()
        pool.merge([exact],id:{$0.id});pool.merge([partial],id:{$0.id});pool.merge([],id:{$0.id})
        precondition(pool.all.map(\.id)==["exact","owned"], "Later source erased earlier source")
        pool.merge([Track(id:"exact",title:exact.title,artist:"Updated")],id:{$0.id})
        precondition(pool.all.count==2 && pool.all.first?.artist=="Updated")
        let variants=NightwellSearch.queries("«Кино — Звезда по имени Солнце»")
        precondition(variants.contains("Кино Звезда по имени Солнце"))
        precondition(variants.contains("kino zvezda po imeni solntse"))
        let noLocalMatch=NightwellSearch.ordered(all,query:"Unrelated track",localOnly:true,
            id:{$0.id},title:{$0.title},artist:{$0.artist})
        precondition(noLocalMatch.isEmpty)
        print("Search: exact hit beyond 320 results, relevance before ownership, typography/transliteration, typos, versions and merged source snapshots passed")
    }
}
