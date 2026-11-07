using System.Net.Http;
using System.Windows;

namespace Nightwell.Native;

public partial class MainWindow {
 async Task ShareCollectionAsync(){
  var kind=screen=="Избранное"?"likes":"playlist";
  if(kind=="playlist"&&string.IsNullOrWhiteSpace(playlist)){
   Status.Text="Сначала выбери плейлист в медиатеке.";
   return;
  }
  try{
   var result=await api.Request("api/shares","POST",new{kind,playlist_id=playlist});
   string path=result.TryGetProperty("path",out var raw)?raw.GetString()?.Trim()??"":"";
   if(path.Length>0&&!path.Contains('\n')&&!path.Contains('\r')
      &&Uri.TryCreate(api.Origin,path,out var link)
      &&link.Scheme==Uri.UriSchemeHttps
      &&link.Authority.Equals(api.Origin.Authority,StringComparison.OrdinalIgnoreCase)){
    // The share may have been created by the API but its public page must work too.
    using var timeout=new CancellationTokenSource(TimeSpan.FromSeconds(10));
    using var response=await artworkHTTP.GetAsync(link,HttpCompletionOption.ResponseHeadersRead,timeout.Token);
    if(response.IsSuccessStatusCode&&response.RequestMessage?.RequestUri?.Host==api.Origin.Host){
     Clipboard.SetText(link.AbsoluteUri);
     Status.Text="Ссылка на плейлист скопирована.";
     return;
    }
   }
  }catch(Exception){
   // Older servers do not have /api/shares or a public share landing page.
   // Never put a broken invented playlist URL on the clipboard.
  }
  var tracks=shown.ToList();
  if(tracks.Count==0&&kind=="playlist"){
   try{
    var result=await api.Request("api/playlists/"+Uri.EscapeDataString(playlist)+"/tracks");
    tracks=ParseTracks(result);
   }catch{}
  }
  if(tracks.Count==0){
   Status.Text="Не удалось получить треки для отправки. Проверь подключение.";
   return;
  }
  string label=kind=="likes"?"Избранное Nightwell Music":Heading.Text;
  var text=new List<string>{"🎵 "+label,"Nightwell Music",""};
  for(int i=0;i<Math.Min(300,tracks.Count);i++)
   text.Add((i+1)+". "+tracks[i].artist+" — "+tracks[i].title);
  if(tracks.Count>300)text.Add("И ещё "+(tracks.Count-300)+" треков");
  Clipboard.SetText(string.Join(Environment.NewLine,text));
  Status.Text="Сервер не выдал рабочую ссылку. Список треков скопирован для отправки.";
 }
}
