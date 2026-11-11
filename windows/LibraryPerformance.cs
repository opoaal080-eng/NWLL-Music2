using System.IO;
using System.Text.Json;
using System.Threading;

namespace Nightwell.Native;

public partial class MainWindow {
 // Preserve liked track metadata even if the account /api/tracks catalogue
 // is partial. This is also used by Search and other transient sources.
 readonly Dictionary<string,Track> favoriteDetails=new(StringComparer.OrdinalIgnoreCase);
 readonly List<string> favoriteOrderIDs=[];
 readonly Dictionary<string,DateTime> favoriteLookupAttempts=new(StringComparer.OrdinalIgnoreCase);
 bool recoveringFavoriteDetails;
 readonly SemaphoreSlim librarySaveGate=new(1,1);
 int librarySaveVersion;
 sealed record LibraryCacheSnapshot(
  string Origin,string Account,DateTime SavedAt,
  List<Track> Tracks,List<string> Likes,List<Playlist> Playlists,
  List<Track>? FavoriteDetails=null,List<string>? FavoriteOrder=null);

 static string LibraryCacheFile=>Path.Combine(NativeAPI.Storage,"library-snapshot-v2.json");

 void RememberFavoriteDetails(IEnumerable<Track> tracks){
  foreach(var t in tracks){
   if(string.IsNullOrWhiteSpace(t.id)||string.IsNullOrWhiteSpace(t.title)||
      t.title=="Трек из избранного")continue;
   favoriteDetails[t.id]=t;
  }
  // Keep only a bounded index, preserving all entries currently liked.
  if(favoriteDetails.Count>5500){
   foreach(var id in favoriteDetails.Keys.Where(x=>!likes.Contains(x))
              .Take(favoriteDetails.Count-4500).ToList())
    favoriteDetails.Remove(id);
  }
 }

 List<Track> VisibleFavoriteTracks(){
  RememberFavoriteDetails(catalog);
  RememberFavoriteDetails(queue);
  foreach(var playlistTracks in ownedPlaylistCache.Values)
   RememberFavoriteDetails(playlistTracks);
  var ids=favoriteOrderIDs.Where(likes.Contains)
    .Concat(likes).Distinct(StringComparer.OrdinalIgnoreCase);
  var result=ids.Select(id=>favoriteDetails.TryGetValue(id,out var track)
       ?track:new Track{id=id,title="Трек из избранного",
                          artist="Загружаем сведения"}).ToList();
  if(premiumSortAllowed&&favoriteOrder=="title")
   result=result.OrderBy(t=>t.title,StringComparer.CurrentCultureIgnoreCase).ToList();
  else if(premiumSortAllowed&&favoriteOrder=="artist")
   result=result.OrderBy(t=>t.artist,StringComparer.CurrentCultureIgnoreCase).ToList();
  _=RecoverFavoriteDetailsAsync();
  return result;
 }

 async Task RecoverFavoriteDetailsAsync(){
  if(recoveringFavoriteDetails||account.Length==0||api==null||lifetime.IsCancellationRequested)return;
  var owner=account;
  var now=DateTime.UtcNow;
  var missing=likes.Where(id=>!favoriteDetails.ContainsKey(id)&&
    (!favoriteLookupAttempts.TryGetValue(id,out var attempt)||
        now-attempt>TimeSpan.FromMinutes(3))).Take(8).ToList();
  if(missing.Count==0)return;
  recoveringFavoriteDetails=true;
  try{
   foreach(var id in missing){
    if(lifetime.IsCancellationRequested||owner!=account)return;
    favoriteLookupAttempts[id]=DateTime.UtcNow;
    if(!System.Text.RegularExpressions.Regex.IsMatch(id,@"^[A-Za-z0-9_-]{1,80}$"))
      continue;
    try{
     var result=await api.Request("api/shared-track/"+Uri.EscapeDataString(id),
                                  cancellation:lifetime.Token);
     if(owner!=account)return;
     if(result.TryGetProperty("tracks",out var values)&&
        values.ValueKind==JsonValueKind.Array){
      var tracks=values.Deserialize<List<Track>>()??[];
      RememberFavoriteDetails(tracks.Where(t=>t.id==id));
     } else if(result.TryGetProperty("track",out var item)&&
                item.ValueKind==JsonValueKind.Object) {
      var track=item.Deserialize<Track>();
      if(track?.id==id)RememberFavoriteDetails([track]);
     }
    }catch(OperationCanceledException){return;}catch(Exception){}
   }
   if(owner==account&&screen=="Избранное"){
    var visible=VisibleFavoriteTracksWithoutRefresh();
    shown=visible;Tracks.ItemsSource=visible;
    SaveLibraryCacheAsync(owner);
   }
  }finally{recoveringFavoriteDetails=false;}
 }

 // Same assembly without scheduling another lookup from the completion path.
 List<Track> VisibleFavoriteTracksWithoutRefresh(){
  var ids=favoriteOrderIDs.Where(likes.Contains)
      .Concat(likes).Distinct(StringComparer.OrdinalIgnoreCase);
  var found=ids.Select(id=>favoriteDetails.TryGetValue(id,out var t)
      ?t:new Track{id=id,title="Трек из избранного",
                    artist="Загружаем сведения"}).ToList();
  if(premiumSortAllowed&&favoriteOrder=="title")
   found=found.OrderBy(t=>t.title,StringComparer.CurrentCultureIgnoreCase).ToList();
  else if(premiumSortAllowed&&favoriteOrder=="artist")
   found=found.OrderBy(t=>t.artist,StringComparer.CurrentCultureIgnoreCase).ToList();
  return found;
 }

 async Task RestoreLibraryCacheAsync(string owner){
  try{
   var cache=await Task.Run(()=>{
    if(!File.Exists(LibraryCacheFile) ||
       new FileInfo(LibraryCacheFile).Length>6*1024*1024)return null;
    return JsonSerializer.Deserialize<LibraryCacheSnapshot>(
       File.ReadAllText(LibraryCacheFile));
   });
   if(cache==null||cache.Origin!=origin||cache.Account!=owner||
      cache.SavedAt>DateTime.UtcNow.AddMinutes(5)||
      cache.SavedAt<DateTime.UtcNow.AddDays(-30)||account!=owner)return;
   catalog=cache.Tracks??[];
   likes=(cache.Likes??[]).ToHashSet(StringComparer.OrdinalIgnoreCase);
   playlists=cache.Playlists??[];
   favoriteDetails.Clear();
   RememberFavoriteDetails(cache.FavoriteDetails??[]);
   favoriteOrderIDs.Clear();
   favoriteOrderIDs.AddRange(cache.FavoriteOrder??cache.Likes??[]);
   SidebarPlaylists.ItemsSource=playlists.ToList();
   if(screen=="Избранное")Show("Избранное");
   else if(screen=="Плейлисты")Show("Плейлисты");
  }catch{} // A corrupt cache cannot block the network refresh.
 }

 void SaveLibraryCacheAsync(string owner){
  if(account!=owner)return;
  var stamp=Interlocked.Increment(ref librarySaveVersion);
  var details=favoriteDetails.Values.Where(t=>likes.Contains(t.id))
     .Take(2500).ToList();
  var data=new LibraryCacheSnapshot(origin,owner,DateTime.UtcNow,
   catalog.Take(2500).ToList(),likes.ToList(),playlists.ToList(),
   details,favoriteOrderIDs.ToList());
  _=Task.Run(async()=>{
   string? pending=null;
   try{
    var payload=JsonSerializer.Serialize(data);
    if(payload.Length>6*1024*1024)return;
    await librarySaveGate.WaitAsync(lifetime.Token);
    try{
     if(stamp!=Volatile.Read(ref librarySaveVersion))return;
     Directory.CreateDirectory(NativeAPI.Storage);
     pending=LibraryCacheFile+"."+Guid.NewGuid().ToString("N")+".tmp";
     await File.WriteAllTextAsync(pending,payload,lifetime.Token);
     if(stamp==Volatile.Read(ref librarySaveVersion))
      File.Move(pending,LibraryCacheFile,true);
    }finally{librarySaveGate.Release();}
   }catch(OperationCanceledException){}catch(IOException){}
    catch(UnauthorizedAccessException){}
   finally{
    if(pending!=null)try{File.Delete(pending);}catch(IOException){}
   }
  });
 }
}
