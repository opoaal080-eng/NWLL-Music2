import Foundation

struct Track {
    let id: String
    let title: String
    let artist: String
    var album: String? = nil
    var source: String? = nil
}

@main struct SourceRecommendationTests {
    static func main() {
        let backup = Track(id:"ai",title:"Moon Lights",artist:"Favorite Artist",source:"audius")
        let primary = Track(id:"sc",title:"Moon Lights",artist:"Other Artist",source:"soundcloud")
        func arrange(_ values:[Track], hidden:Set<String> = []) -> [Track] {
            RecommendationOrder.arrange(values,recent:["sc"],hidden:hidden,
                identity:{$0.id},title:{$0.title},artist:{$0.artist},source:{$0.source})
        }
        precondition(arrange([backup,primary]).map(\.id) == ["sc","ai"],
                     "Taste, freshness and incoming order must not promote the backup above a usable primary")
        precondition(arrange([backup,primary],hidden:["sc"]).map(\.id) == ["ai"],
                     "A filtered primary must leave the backup available")
        let duplicate = Track(id:"sc-copy",title:backup.title,artist:backup.artist,source:"soundcloud")
        precondition(arrange([backup,duplicate]).map(\.id) == ["sc-copy"],
                     "Duplicate collapse must keep the primary source even if Audius arrived first")
        let seed = Track(id:"seed",title:"Moon Lights",artist:"Favorite Artist")
        let seeded = NightwellSeededRhythm.ranked(candidates:[backup,primary],seeds:[seed])
        precondition(seeded.map(\.id) == ["sc","ai"],
                     "Seeded mixes must preserve source priority before stronger fallback artist affinity")
        precondition(NightwellSeededRhythm.ranked(candidates:[backup,primary],seeds:[seed],limit:1).first?.id == "sc")
        precondition(NightwellSeededRhythm.ranked(candidates:[backup,primary],seeds:[seed],hidden:["sc"]).first?.id == "ai")
        precondition(NightwellSeededRhythm.ranked(candidates:[backup,duplicate],seeds:[seed]).map(\.id) == ["sc-copy"])
        let unrelated = Track(id:"unrelated",title:"Different",artist:"Unknown",source:"soundcloud")
        precondition(NightwellSeededRhythm.ranked(candidates:[unrelated,backup],seeds:[seed]).map(\.id) == ["ai"],
                     "Unrelated SoundCloud rows must not prevent a relevant Audius fallback")
        let albumSeed = Track(id:"album-seed",title:"Seed Song",artist:"Seed Artist",album:"Seed Album")
        let albumBackup = Track(id:"album-ai",title:"Other Track",artist:"Other Artist",album:"Seed Album",source:"audius")
        let ineligiblePrimary = Track(id:"album-sc",title:"Other Track",artist:"Other Artist",album:"SoundCloud",source:"soundcloud")
        precondition(NightwellSeededRhythm.ranked(candidates:[albumBackup,ineligiblePrimary],seeds:[albumSeed]).map(\.id) == ["album-ai"],
                     "An ineligible primary copy must not consume the identity of an eligible fallback recording")
        print("Source priority: generated queues, seeded mixes, duplicate copies, filtering and Audius fallback passed")
    }
}
