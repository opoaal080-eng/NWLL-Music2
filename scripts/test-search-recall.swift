import Foundation

private struct Track {
    let id: String
    let title: String
    let artist: String
    var duration: Double? = nil
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
        precondition(NightwellSearch.Query("The Weeknd Blnding Lights").score(title:"Blinding Lights",artist:"The Weeknd")>0,
                     "A typo in an artist-and-title query must retain the intended track")
        precondition(NightwellSearch.Query("Blnding Lights The Weeknd").score(title:"Blinding Lights",artist:"The Weeknd")>0)
        precondition(NightwellSearch.Query("Live Forever").score(title:"Live Forever",artist:"Group")==10000)
        precondition(NightwellSearch.Query("Song").score(title:"Song (Official Audio)",artist:"Singer")>=9500)
        let versions = [Track(id:"studio",title:"Song",artist:"Singer"),
                        Track(id:"live",title:"Song (Live at Wembley)",artist:"Singer")]
        let requestedLive = NightwellSearch.ordered(versions,query:"Song Live",priorityIDs:["studio"],
            id:{$0.id},title:{$0.title},artist:{$0.artist})
        precondition(requestedLive.first?.id == "live", "A requested live version must outrank an owned studio version")
        let remixQuery = NightwellSearch.Query("Song (DJ One Remix)")
        precondition(remixQuery.score(title:"Song (DJ One Remix Version)",artist:"Singer") >
                     remixQuery.score(title:"Song (DJ Two Remix)",artist:"Singer"),
                     "Requested remix credits must affect relevance")
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

        // Metadata from the user's Nightwell/SoundCloud comparison. Local
        // same-title hits must not hide the provider's relevant original.
        let screenshotQuery = "грустный дэнс"
        let localTitles = [Track(id:"instasamka",title:"Грустный дэнс",artist:"INSTASAMKA"),
                           Track(id:"upload",title:"грустный дэнс",artist:"RusMusiac"),
                           Track(id:"luna",title:"Грустный Дэнс",artist:"ЛУНА")]
        let original = Track(id:"artik",title:"Грустный дэнс (при уч. Артем Качер)",artist:"Artik & Anna Asti",duration:189)
        precondition(NightwellSearch.Query(screenshotQuery).score(title:original.title,artist:original.artist) ==
                     NightwellSearch.Query(screenshotQuery).score(title:localTitles[0].title,artist:localTitles[0].artist),
                     "A featuring credit must not demote the original song below a bare same-title upload")
        var screenshotPool = NightwellSearch.Pool<Track>()
        screenshotPool.merge(localTitles,id:{$0.id})
        screenshotPool.mergeProvider([original,localTitles[2]],queryPriority:0,id:{$0.id})
        screenshotPool.mergeProvider([localTitles[0],original],queryPriority:1,id:{$0.id})
        let screenshotResults = NightwellSearch.ordered(screenshotPool.all,query:screenshotQuery,
            priorityIDs:["instasamka"],providerRanks:screenshotPool.providerRanks,
            id:{$0.id},title:{$0.title},artist:{$0.artist})
        precondition(screenshotResults.prefix(2).map(\.id) == ["artik","luna"],
                     "Fresh literal provider relevance must outrank cached/owned positions: \(screenshotResults.map(\.id))")
        screenshotPool.mergeProvider([Track(id:"unrelated",title:"Другая песня",artist:"Artik")],queryPriority:0,id:{$0.id})
        let relevanceFirst = NightwellSearch.ordered(screenshotPool.all,query:screenshotQuery,
            providerRanks:screenshotPool.providerRanks,id:{$0.id},title:{$0.title},artist:{$0.artist})
        precondition(relevanceFirst.first?.id != "unrelated", "Provider order must not overrule query relevance")
        var snapshots = NightwellSearch.Pool<Track>()
        snapshots.merge(localTitles,id:{$0.id})
        snapshots.mergeProvider([localTitles[0]],queryPriority:0,id:{$0.id})
        snapshots.mergeProvider([original],queryPriority:0,id:{$0.id})
        let latestSnapshot = NightwellSearch.ordered(snapshots.all,query:screenshotQuery,
            providerRanks:snapshots.providerRanks,id:{$0.id},title:{$0.title},artist:{$0.artist})
        precondition(latestSnapshot.first?.id == "artik" && latestSnapshot.contains(where:{$0.id == "instasamka"}),
                     "Latest provider order must win without discarding an earlier pending snapshot")
        precondition(Set(snapshots.providerRanks.values).count == snapshots.providerRanks.count,
                     "Provider rank collisions must not restore stale local positions")

        let screenshotVariants = NightwellSearch.queries(screenshotQuery)
        let primaryTargets = screenshotVariants.map { $0+"|soundcloud" }
        let backupTargets = screenshotVariants.map { $0+"|audius" }
        var completedPlan = NightwellSearch.RequestPlan(queries:screenshotVariants)
        var completedQueries: [String] = []
        while let request = completedPlan.next(now:0) {
            completedQueries.append(request.query+"|"+request.provider)
            precondition(request.path.contains("&provider="+request.provider), "Search request omitted its explicit source")
            completedPlan.received(request,pending:false,retryAfter:nil,relevant:true,now:0)
        }
        precondition(completedQueries == primaryTargets && completedPlan.isComplete,
                     "A valid SoundCloud result must keep Audius as a backup and still search the other primary variants")
        var emptyPrimary = NightwellSearch.RequestPlan(queries:screenshotVariants)
        var fallbackOrder: [String] = []
        while let request = emptyPrimary.next(now:0) {
            fallbackOrder.append(request.query+"|"+request.provider)
            emptyPrimary.received(request,pending:false,retryAfter:nil,relevant:request.provider == "audius",now:0)
        }
        precondition(fallbackOrder == primaryTargets + backupTargets && emptyPrimary.isComplete,
                     "Audius must run only after all primary variants have no relevant results")
        var pendingPlan = NightwellSearch.RequestPlan(queries:screenshotVariants)
        var pendingQueries: [String] = []
        while let request = pendingPlan.next(now:0) {
            pendingQueries.append(request.query+"|"+request.provider)
            precondition(request.delay.isFinite)
            pendingPlan.received(request,pending:true,retryAfter:.infinity,now:0)
        }
        precondition(Array(pendingQueries.prefix(primaryTargets.count)) == primaryTargets,
                     "One pending query consumed retries before other primary variants got their first request")
        precondition(pendingQueries.count == 18 && !pendingPlan.isComplete,
                     "Pending search must remain incomplete and bounded")
        precondition(pendingQueries.suffix(backupTargets.count).elementsEqual(backupTargets),
                     "Primary retries must leave a bounded opportunity for the backup source")
        var delayedPrimary = NightwellSearch.RequestPlan(queries:[screenshotQuery])
        let firstRequest = delayedPrimary.next(now:0)!
        delayedPrimary.received(firstRequest,pending:true,retryAfter:1,relevant:false,now:0)
        let secondRequest = delayedPrimary.next(now:1)!
        precondition(secondRequest.provider == "soundcloud", "A pending primary source was skipped")
        delayedPrimary.received(secondRequest,pending:false,retryAfter:nil,relevant:true,now:1)
        precondition(delayedPrimary.next(now:1) == nil && delayedPrimary.isComplete,
                     "Successful delayed primary should not start the backup")
        var timedOutPrimary = NightwellSearch.RequestPlan(queries:[screenshotQuery])
        var timeoutOrder: [String] = []
        while let request = timedOutPrimary.next(now:0) {
            timeoutOrder.append(request.provider)
            timedOutPrimary.received(request,pending:request.provider == "soundcloud",retryAfter:1,
                relevant:request.provider == "audius",now:0)
        }
        precondition(timeoutOrder.last == "audius" && timeoutOrder.count <= 18 && timedOutPrimary.isComplete,
                     "A permanently pending primary must not prevent a completed fallback")
        var failedPlan = NightwellSearch.RequestPlan(queries:screenshotVariants)
        var failedCalls = 0
        while let request = failedPlan.next(now:0) {
            failedCalls += 1
            failedPlan.failed(request,now:0)
        }
        precondition(failedCalls == min(18,(primaryTargets.count + backupTargets.count) * 2) && !failedPlan.isComplete,
                     "Each failed query should get one bounded retry, with Audius available after primary failure")
        print("Search: screenshot recall, featured credits, primary SoundCloud, Audius fallback, snapshots, pending limits and retries passed")
    }
}
