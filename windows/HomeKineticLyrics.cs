using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Documents;
using System.Windows.Media;
using System.Threading;

namespace Nightwell.Native;

public partial class MainWindow {
 CancellationTokenSource? homeLyricsCancellation;
 JsonElement? homeLyricsPayload;
 string homeLyricsTrack="";
 int homeKineticLine=-2,homeKineticWord=-2;
 readonly List<Run> homeKineticRuns=new();

 void ResetHomeLyrics(Track track){
  homeLyricsCancellation?.Cancel();
  homeLyricsCancellation=CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
  homeLyricsTrack=track.id;
  homeLyricsPayload=null;
  homeKineticLine=-2;homeKineticWord=-2;
  homeKineticRuns.Clear();
  HomeKineticText.Inlines.Clear();
  _=LoadHomeLyricsAsync(track,homeLyricsCancellation.Token);
 }

 async Task LoadHomeLyricsAsync(Track track,CancellationToken token){
  if(track.id.Length==0||account.Length==0)return;
  try{
   var folder=Path.Combine(NativeAPI.Storage,"lyrics");
   Directory.CreateDirectory(folder);
   var cache=Path.Combine(folder,track.id+".json");
   JsonElement? loaded=null;
   if(File.Exists(cache)&&DateTime.UtcNow-File.GetLastWriteTimeUtc(cache)<TimeSpan.FromDays(30)){
    var text=await File.ReadAllTextAsync(cache,token);
    using var parsed=JsonDocument.Parse(text);
    if(parsed.RootElement.TryGetProperty("status",out var st)&&
       st.GetString()=="found")loaded=parsed.RootElement.Clone();
   }
   if(!loaded.HasValue){
    // A cheap, bounded retry handles Lyricsfile/LRCLIB lookup in progress.
    // Never hold the active audio stream or UI for lyrics.
    for(int round=0;round<4;round++){
     token.ThrowIfCancellationRequested();
     var response=await api.Request("api/lyrics/"+Uri.EscapeDataString(track.id),
       cancellation:token);
     if(currentID!=track.id)return;
     string status=response.TryGetProperty("status",out var state)?
      state.GetString()??"":"";
     if(status is "loading" or "pending" or "unavailable"){
      double seconds=response.TryGetProperty("retry_after",out var retry)?
       retry.GetDouble():3;
      await Task.Delay(TimeSpan.FromSeconds(Math.Clamp(seconds,2,15)),token);
      continue;
     }
     loaded=response;
     if(status is "found" or "instrumental"){
      try{await File.WriteAllTextAsync(cache,response.GetRawText(),token);}catch{}
     }
     break;
    }
   }
   if(token.IsCancellationRequested||currentID!=track.id||
      homeLyricsTrack!=track.id)return;
   homeLyricsPayload=loaded;
   homeKineticLine=-2;homeKineticWord=-2;
   UpdateHomeLyrics();
  }catch(OperationCanceledException){}
   catch{} // Missing lyrics must never interrupt playback.
 }

 void UpdateHomeLyrics(){
  if(HomeKineticText==null)return;
  if(!Home.IsVisible||!audioPlaying||!homeLyricsPayload.HasValue||
     homeLyricsTrack!=currentID){
   if(HomeKineticText.Inlines.Count>0){
    HomeKineticText.Inlines.Clear();
    homeKineticLine=-2;homeKineticWord=-2;
   }
   return;
  }
  var result=homeLyricsPayload.Value;
  if(!result.TryGetProperty("synced",out var flag)||!flag.GetBoolean()||
     !result.TryGetProperty("lines",out var lines)||
     lines.ValueKind!=JsonValueKind.Array)return;
  var all=lines.EnumerateArray().ToArray();
  double now=audioTime/1000.0;
  int index=Array.FindLastIndex(all,line=>
   line.TryGetProperty("time",out var stamp)&&stamp.GetDouble()<=now);
  if(index<0 || now-all[index].GetProperty("time").GetDouble()>4.5){
   if(HomeKineticText.Inlines.Count>0)HomeKineticText.Inlines.Clear();
   homeKineticLine=-2;homeKineticWord=-2;return;
  }
  int word=kineticLyrics?KineticWordAt(all,index,now):-1;
  if(homeKineticLine==index&&homeKineticWord==word)return;
  if(homeKineticLine!=index){
   homeKineticLine=index;
   homeKineticRuns.Clear();
   HomeKineticText.Inlines.Clear();
   var text=all[index].GetProperty("text").GetString()??"";
   var segments=text.Split(' ',StringSplitOptions.None);
   // Keep font/size fixed; only brushes change at word boundaries.
   foreach(var (part,i) in segments.Select((part,i)=>(part,i))){
    var run=new Run(part+(i+1<segments.Length?" ":""));
    homeKineticRuns.Add(run);
    HomeKineticText.Inlines.Add(run);
   }
  }
  homeKineticWord=word;
  for(int i=0;i<homeKineticRuns.Count;i++){
   var color=!kineticLyrics||i<=word?Brushes.White:LyricPendingBrush;
   if(!ReferenceEquals(homeKineticRuns[i].Foreground,color))
    homeKineticRuns[i].Foreground=color;
  }
 }
}
