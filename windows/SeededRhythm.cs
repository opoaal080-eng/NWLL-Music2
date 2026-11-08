using System.IO;
using System.Linq;
using System.Text.Json;
using System.Windows;
using Microsoft.Web.WebView2.Wpf;

namespace Nightwell.Native;

public partial class MainWindow {
 readonly List<string> seededWaveArtists=new();

 string OwnedCachePath(string id){
  string safe=new string(id.Where(char.IsLetterOrDigit).Take(80).ToArray());
  return Path.Combine(NativeAPI.Storage,"owned-playlists",account,safe+".json");
 }
 void SaveOwnedPlaylistCache(string id,List<Track> tracks){
  try{
   string file=OwnedCachePath(id);
   Directory.CreateDirectory(Path.GetDirectoryName(file)!);
   if(tracks.Count<=3000)File.WriteAllText(file,JsonSerializer.Serialize(tracks));
  }catch{}
 }
 async Task WarmOwnedPlaylistsAsync(string owner){
  // Warm at most 24 playlists so desktop startup and the user's server are
  // never held up by large library-index requests.
  foreach(var item in playlists.Take(24)){
   if(account!=owner||lifetime.IsCancellationRequested)return;
   var id=item.id;
   try{
    var path=OwnedCachePath(id);
    List<Track>? cached=null;
    if(File.Exists(path)){
     cached=await Task.Run(()=>JsonSerializer.Deserialize<List<Track>>(File.ReadAllText(path)));
     if(cached!=null)ownedPlaylistCache[id]=cached;
    }
    if(cached==null||DateTime.UtcNow-File.GetLastWriteTimeUtc(path)>TimeSpan.FromHours(24)){
     var value=await api.Request("api/playlists/"+Uri.EscapeDataString(id)+"/tracks",cancellation:lifetime.Token);
     var fetched=ParseTracks(value);
     if(account!=owner)return;
     ownedPlaylistCache[id]=fetched;
     SaveOwnedPlaylistCache(id,fetched);
    }
    if(screen=="Поиск"&&SearchBox.Text.Trim().Length>=2){
      string query=SearchBox.Text.Trim();
      shown=RankSearchResults(shown.Concat(ownedPlaylistCache.Values.SelectMany(x=>x)),query);
      Tracks.ItemsSource=shown;
    }
   }catch(OperationCanceledException){return;}catch{}
   await Task.Delay(180);
  }
 }
 List<Track> RankSearchResults(IEnumerable<Track> input,string query){
  var owned=new HashSet<string>(likes,StringComparer.OrdinalIgnoreCase);
  foreach(var t in ownedPlaylistCache.Values.SelectMany(x=>x))owned.Add(t.id);
  var terms=query.Split(' ',StringSplitOptions.RemoveEmptyEntries|StringSplitOptions.TrimEntries);
  return input.Where(t=>
      (t.title+" "+t.artist).Contains(query,StringComparison.OrdinalIgnoreCase)
      || terms.All(q=>(t.title+" "+t.artist).Contains(q,StringComparison.OrdinalIgnoreCase)))
   .Where(t=>!string.IsNullOrEmpty(t.id))
   .GroupBy(t=>t.id,StringComparer.OrdinalIgnoreCase).Select(g=>g.First())
   .OrderByDescending(t=>owned.Contains(t.id))
   .ThenByDescending(t=>t.title.Equals(query,StringComparison.OrdinalIgnoreCase))
   .ThenByDescending(t=>t.title.Contains(query,StringComparison.OrdinalIgnoreCase))
   .Take(200).ToList();
 }

 static List<string> ArtistsForSeeds(IEnumerable<Track> input)=>
  input.Where(t=>!string.IsNullOrWhiteSpace(t.artist))
   .GroupBy(t=>t.artist,StringComparer.OrdinalIgnoreCase)
   .OrderByDescending(g=>g.Count()).Take(4).Select(g=>g.Key).ToList();

 List<Track> RankSeeded(IEnumerable<Track> input,IReadOnlyList<Track> seeds){
  var seedIds=seeds.Select(t=>t.id).ToHashSet(StringComparer.OrdinalIgnoreCase);
  var artists=seeds.Select(t=>t.artist).ToHashSet(StringComparer.OrdinalIgnoreCase);
  var albums=seeds.Where(t=>!string.IsNullOrEmpty(t.album)).Select(t=>t.album!)
   .ToHashSet(StringComparer.OrdinalIgnoreCase);
  var terms=seeds.Take(60).SelectMany(t=>(t.title+" "+t.artist)
   .Split(' ',StringSplitOptions.RemoveEmptyEntries|StringSplitOptions.TrimEntries))
   .Where(w=>w.Length>=4).ToHashSet(StringComparer.OrdinalIgnoreCase);
  var candidates=input.Where(t=>!seedIds.Contains(t.id)&&!hiddenTracks.Contains(t.id))
   .GroupBy(t=>t.id,StringComparer.OrdinalIgnoreCase).Select(g=>g.First())
   .Select((t,i)=>{
     double score=artists.Contains(t.artist)?7:0;
     if(t.album!=null&&albums.Contains(t.album))score+=4;
     score+=(t.title+" "+t.artist).Split(' ',StringSplitOptions.RemoveEmptyEntries)
      .Count(terms.Contains)*.65;
     return (track:t,score,index:i);
   })
   .Where(x=>x.score>=.65)
   .OrderByDescending(x=>x.score).ThenBy(x=>x.index).ToList();
  List<Track> answer=[];
  var usage=new Dictionary<string,int>(StringComparer.OrdinalIgnoreCase);
  foreach(var candidate in candidates){
   if(answer.Count>=100)break;
   var artist=candidate.track.artist;
   if(usage.GetValueOrDefault(artist)>=5)continue;
   answer.Add(candidate.track);usage[artist]=usage.GetValueOrDefault(artist)+1;
  }
  if(answer.Count<8)
   foreach(var candidate in candidates)
    if(answer.Count<100&&!answer.Any(t=>t.id==candidate.track.id))answer.Add(candidate.track);
  return answer;
 }

 async Task StartRhythmAsync(IEnumerable<Track> songs,Track? source){
  if(mixing)return;
  if(account.Length==0){Login();return;}
  var seeds=songs.Where(t=>!string.IsNullOrEmpty(t.id)).Take(400).ToList();
  if(seeds.Count==0){Status.Text="В плейлисте нет треков для подборки";return;}
  mixing=true;Status.Text="Подбираем похожую музыку…";
  try{
   var authors=ArtistsForSeeds(seeds);
   var candidates=catalog.Concat(shown).Concat(queue)
    .Concat(ownedPlaylistCache.Values.SelectMany(x=>x)).ToList();
   var picked=await Task.Run(()=>RankSeeded(candidates,seeds));
   if(picked.Count<24){
    var ids=string.Join(',',seeds.Take(100).Select(t=>t.id));
    var url="api/wave?artists="+Uri.EscapeDataString(string.Join(",",authors))
      +"&exclude="+Uri.EscapeDataString(ids);
    try{
     var response=await api.Request(url,cancellation:lifetime.Token);
     picked=await Task.Run(()=>RankSeeded(candidates.Concat(ParseTracks(response)),seeds));
    }catch{} // Local matches remain usable.
   }
   if(picked.Count==0){Status.Text="Похожая музыка пока не найдена";return;}
   var next=source==null?picked:
     new List<Track>{source}.Concat(picked.Where(t=>t.id!=source.id)).ToList();
   seededWaveArtists.Clear();seededWaveArtists.AddRange(authors);
   wave=true;queue=next;index=0;
   PlayCurrent();Status.Text="";
  }finally{mixing=false;}
 }

 async Task PrefetchClipAsync(Track track){
  if(string.IsNullOrWhiteSpace(track.id)||account.Length==0)return;
  if(clipCache.TryGetValue(track.id,out var cached)&&cached.expires>DateTime.UtcNow)return;
  if(!clipRequests.Add(track.id))return;
  try{
   string? id=null;
   var url="api/music-videos/clip?title="+Uri.EscapeDataString(track.title)
     +"&artist="+Uri.EscapeDataString(track.artist);
   var response=await api.Request(url,cancellation:lifetime.Token);
   if(response.TryGetProperty("available",out var available)&&available.GetBoolean()){
    var candidate=response.GetProperty("video_id").GetString()??"";
    if(System.Text.RegularExpressions.Regex.IsMatch(candidate,@"^[A-Za-z0-9_-]{11}$"))id=candidate;
   }
   clipCache[track.id]=(id??"",DateTime.UtcNow.Add(id==null?TimeSpan.FromMinutes(15):TimeSpan.FromHours(6)));
  }catch{
   clipCache[track.id]=("",DateTime.UtcNow.AddMinutes(5));
  }finally{clipRequests.Remove(track.id);}
 }

 async Task ShowClipAsync(Track track,string id){
  if(!System.Text.RegularExpressions.Regex.IsMatch(id,@"^[A-Za-z0-9_-]{11}$"))return;
  await AudioCommand(()=>player.SetPause(true));
  // Show the normal YouTube page with its original soundtrack inside the
  // application. No video is downloaded or re-encoded by Nightwell.
  var window=new Window{
   Title="Клип · "+track.title,Owner=this,
   Width=920,Height=560,MinWidth=480,MinHeight=360,
   WindowStartupLocation=WindowStartupLocation.CenterOwner,
   Background=System.Windows.Media.Brushes.Black
  };
  var viewer=new WebView2();
  window.Content=viewer;
  window.Loaded+=async (_,_)=>{
   try{
    await viewer.EnsureCoreWebView2Async();
    viewer.CoreWebView2.Navigate("https://www.youtube.com/watch?v="+id);
   }catch(Exception ex){
    window.Title="Не удалось открыть клип: "+ex.Message;
   }
  };
  window.Closed+=(_,_)=>viewer.Dispose();
  window.Show();
 }
}
