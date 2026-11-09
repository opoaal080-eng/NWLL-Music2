using System.IO;
using System.Text.Json;

namespace Nightwell.Native;

public partial class MainWindow {
 // Each account's validated library is available before remote sections finish.
 // Cache is never used as a login token or as proof of server authorization.
 sealed record LibraryCacheSnapshot(
  string Origin,string Account,DateTime SavedAt,
  List<Track> Tracks,List<string> Likes,List<Playlist> Playlists);

 static string LibraryCacheFile=>Path.Combine(NativeAPI.Storage,"library-snapshot-v2.json");

 async Task RestoreLibraryCacheAsync(string owner){
  try{
   var cache=await Task.Run(()=>{
    if(!File.Exists(LibraryCacheFile) ||
       new FileInfo(LibraryCacheFile).Length>6*1024*1024)return null;
    return JsonSerializer.Deserialize<LibraryCacheSnapshot>(File.ReadAllText(LibraryCacheFile));
   });
   if(cache==null||cache.Origin!=origin||cache.Account!=owner||
      cache.SavedAt>DateTime.UtcNow.AddMinutes(5)||
      cache.SavedAt<DateTime.UtcNow.AddDays(-30)||account!=owner)return;
   catalog=cache.Tracks??[];
   likes=(cache.Likes??[]).ToHashSet(StringComparer.OrdinalIgnoreCase);
   playlists=cache.Playlists??[];
   SidebarPlaylists.ItemsSource=playlists.ToList();
   if(screen=="Избранное")Show("Избранное");
   else if(screen=="Плейлисты")Show("Плейлисты");
  }catch{} // A corrupt cache must never prevent a server refresh.
 }

 void SaveLibraryCacheAsync(string owner){
  if(account!=owner)return;
  var data=new LibraryCacheSnapshot(
   origin,owner,DateTime.UtcNow,
   catalog.Take(2500).ToList(),likes.ToList(),playlists.ToList());
  _=Task.Run(()=>{
   try{
    var payload=JsonSerializer.Serialize(data);
    if(payload.Length>6*1024*1024)return;
    Directory.CreateDirectory(NativeAPI.Storage);
    var destination=LibraryCacheFile;
    var pending=destination+".tmp";
    File.WriteAllText(pending,payload);
    File.Move(pending,destination,true);
   }catch{} // Disk errors must not affect playback or UI.
  });
 }
}
