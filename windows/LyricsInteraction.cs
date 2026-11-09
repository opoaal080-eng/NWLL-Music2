using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Documents;
using System.Windows.Threading;

namespace Nightwell.Native;

public partial class MainWindow {
 string displayedLyricsTrack="";
 int renderedKineticWord=-2;
 int previousKineticLine=-2;
 readonly List<Button> syncedLyricButtons=new();
 readonly List<List<Run>> syncedLyricRuns=new();
 readonly DispatcherTimer lyricClock=new(){Interval=TimeSpan.FromMilliseconds(160)};
 bool lyricClockStarted;
 static readonly Brush LyricInactiveBrush=FreezeLyricBrush(159,159,159);
 static readonly Brush LyricPendingBrush=FreezeLyricBrush(162,162,171);
 static Brush FreezeLyricBrush(byte r,byte g,byte b){
  var brush=new SolidColorBrush(Color.FromRgb(r,g,b));brush.Freeze();return brush;
 }
 void StartLyricClock(){
  if(!lyricClockStarted){
   lyricClock.Tick+=(_,_)=>{
    if(player==null||!player.IsPlaying)return;
    if(!LyricsPanel.IsVisible&&!Home.IsVisible)return;
    try{
     audioTime=Math.Max(0,player.Time);
     if(LyricsPanel.IsVisible)SyncLyrics();
     if(Home.IsVisible)UpdateHomeLyrics();
    }catch{}
   };
   lyricClockStarted=true;
  }
  lyricClock.Start();
 }
 void StopLyricClock()=>lyricClock.Stop();

 static int KineticWordAt(JsonElement[] lines,int activeIndex,double clock){
  if(activeIndex<0||activeIndex>=lines.Length)return -1;
  var line=lines[activeIndex];
  string text=line.GetProperty("text").GetString()??"";
  double start=line.GetProperty("time").GetDouble();
  double end=activeIndex+1<lines.Length?
   lines[activeIndex+1].GetProperty("time").GetDouble():start+4;
  if(line.TryGetProperty("words",out var exact)&&exact.ValueKind==JsonValueKind.Array&&exact.GetArrayLength()>0){
   var combined=new System.Text.StringBuilder();
   bool valid=true;double previous=-1;
   foreach(var word in exact.EnumerateArray()){
    if(!word.TryGetProperty("text",out var wt)||wt.ValueKind!=JsonValueKind.String){valid=false;break;}
    combined.Append(wt.GetString());
    double at=double.NaN;
    if(word.TryGetProperty("start",out var a)&&a.ValueKind==JsonValueKind.Number)at=a.GetDouble();
    else if(word.TryGetProperty("time",out var t)&&t.ValueKind==JsonValueKind.Number)at=t.GetDouble();
    else if(word.TryGetProperty("start_ms",out var ms)&&ms.ValueKind==JsonValueKind.Number)at=ms.GetDouble()/1000.0;
    if(!double.IsFinite(at)||at<previous||at<start-.25||at>end+.5){valid=false;break;}
    previous=at;
   }
   if(valid&&string.Equals(combined.ToString().Trim(),text.Trim(),StringComparison.Ordinal)){
    // The timestamps are exact. The time before the first word is unhighlighted.
    int result=-1,index=0;
    foreach(var word in exact.EnumerateArray()){
     double at=word.TryGetProperty("start",out var st)?st.GetDouble():
      word.TryGetProperty("time",out var tm)?tm.GetDouble():
      word.GetProperty("start_ms").GetDouble()/1000.0;
     if(at<=clock)result=index;
     index++;
    }
    return result;
   }
  }
  var words=text.Split(' ',StringSplitOptions.RemoveEmptyEntries);
  if(words.Length==0)return -1;
  double total=0;var weights=new double[words.Length];
  for(int i=0;i<words.Length;i++){
   int letters=0,vowels=0;bool punctuation=false;
   foreach(char character in words[i]){
    if(char.IsLetter(character))letters++;
    if("aeiouyAEIOUYаеёиоуыэюяАЕЁИОУЫЭЮЯ".Contains(character))vowels++;
    if(",.!?:;".Contains(character))punctuation=true;
   }
   weights[i]=.55+Math.Min(letters,16)*.16+Math.Min(vowels,8)*.18+(punctuation?.20:0);
   total+=weights[i];
  }
  double duration=Math.Max(.3,end-start);
  double vocal=Math.Min(duration,Math.Max(1.1,words.Length*1.45));
  double fraction=Math.Clamp((clock-start)/vocal,0,.99999),accumulated=0;
  for(int i=0;i<weights.Length;i++){
   accumulated+=weights[i]/Math.Max(.01,total);
   if(fraction<accumulated)return i;
  }
  return words.Length-1;
 }

 void DisplaySyncedLyrics(JsonElement[] all,int activeIndex,int activeWord){
  bool rebuilding=displayedLyricsTrack!=currentID||syncedLyricButtons.Count!=all.Length;
  if(rebuilding){
   displayedLyricsTrack=currentID;
   previousKineticLine=-2;
   syncedLyricButtons.Clear();
   syncedLyricRuns.Clear();
   SyncedLyricsLines.Children.Clear();
   foreach(var entry in all){
    var seconds=entry.GetProperty("time").GetDouble();
    var text=entry.GetProperty("text").GetString()??"";
    var content=new TextBlock{
     TextAlignment=TextAlignment.Center,TextWrapping=TextWrapping.Wrap,
     FontSize=20,FontWeight=FontWeights.SemiBold
    };
    // Create the glyph layout once per track. Highlighting changes only colors,
    // never Inline runs, font weights or sizes that could rewrap the lyrics.
    var runs=new List<Run>();
    string[] words=text.Split(' ',StringSplitOptions.None);
    if(entry.TryGetProperty("words",out var exact)&&exact.ValueKind==JsonValueKind.Array){
     var segments=exact.EnumerateArray().Select(w=>w.TryGetProperty("text",out var t)?t.GetString()??"":"").ToArray();
     if(segments.Length>0&&string.Equals(string.Concat(segments).Trim(),text.Trim(),StringComparison.Ordinal))
      words=segments;
    }
    bool explicitSpaces=entry.TryGetProperty("words",out var timed)&&timed.ValueKind==JsonValueKind.Array
      && words.Length==timed.GetArrayLength();
    for(int k=0;k<words.Length;k++){
     var run=new Run(words[k]+(!explicitSpaces&&k+1<words.Length?" ":"")){
      Foreground=LyricInactiveBrush
     };
     content.Inlines.Add(run);
     runs.Add(run);
    }
    var button=new Button{
     Content=content,Tag=seconds,Cursor=Cursors.Hand,
     Style=(Style)FindResource("QuietButton"),
     HorizontalContentAlignment=HorizontalAlignment.Stretch,
     Padding=new Thickness(12,10,12,10),
     Margin=new Thickness(0,2,0,2),
     Background=Brushes.Transparent,
     Foreground=new SolidColorBrush(Color.FromRgb(159,159,159))
    };
    button.Click+=SyncedLyricClick;
    SyncedLyricsLines.Children.Add(button);
    syncedLyricButtons.Add(button);
    syncedLyricRuns.Add(runs);
   }
  }
  LyricsText.Visibility=Visibility.Collapsed;
  SyncedLyricsLines.Visibility=Visibility.Visible;
  bool changedLine=activeIndex!=previousKineticLine;
  // Update only the previously active and currently active rows.
  // All others retain their cached text and brush, even on a 160ms clock.
  var affected=rebuilding
   ?Enumerable.Range(0,syncedLyricButtons.Count)
   :changedLine
    ?new[]{previousKineticLine,activeIndex}.AsEnumerable()
    :new[]{activeIndex}.AsEnumerable();
  foreach(int i in affected.Distinct()){
   if(i<0||i>=syncedLyricButtons.Count)continue;
   bool active=i==activeIndex;
   var button=syncedLyricButtons[i];
   if(rebuilding||changedLine){
    button.Background=active?
     new SolidColorBrush(Color.FromArgb(50,185,185,185)):Brushes.Transparent;
    button.Foreground=active?Brushes.White:LyricInactiveBrush;
   }
   if(button.Content is not TextBlock line)continue;
   if(rebuilding||changedLine){
    line.Effect=active&&kineticLyrics?new DropShadowEffect{
     Color=Colors.White,BlurRadius=10,Opacity=.24,ShadowDepth=0
    }:null;
   }
   for(int word=0;word<syncedLyricRuns[i].Count;word++){
    var run=syncedLyricRuns[i][word];
    Brush target=active
     ?(kineticLyrics&&word>activeWord?LyricPendingBrush:Brushes.White)
     :LyricInactiveBrush;
    if(!ReferenceEquals(run.Foreground,target))run.Foreground=target;
   }
   if(active&&changedLine&&kineticLyrics){
    line.BeginAnimation(UIElement.OpacityProperty,
     new DoubleAnimation(.72,1,TimeSpan.FromMilliseconds(230)));
   }
  }
  previousKineticLine=activeIndex;
  // Scrolling is permitted only when the active LINE changes, never each word.
  if(changedLine&&activeIndex>=0&&activeIndex<syncedLyricButtons.Count){
   var target=syncedLyricButtons[activeIndex];
   Dispatcher.BeginInvoke(new Action(()=>{
    if(target.IsLoaded&&LyricsPanel.IsVisible)target.BringIntoView();
   }),DispatcherPriority.Background);
  }
 }
 async void SyncedLyricClick(object sender,RoutedEventArgs e){
  if(sender is not Button button||button.Tag is not double seconds)return;
  if(roomCode.Length>0){
   await Guard(()=>RoomCommand("seek",position:seconds));
   return;
  }
  pendingSeek=null;
  await AudioCommand(()=>player.Time=(long)(Math.Max(0,seconds)*1000));
 }
}
