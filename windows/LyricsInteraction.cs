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
    var words=text.Split(' ',StringSplitOptions.None);
    for(int k=0;k<words.Length;k++){
     var run=new Run(words[k]+(k+1<words.Length?" ":"")){
      Foreground=new SolidColorBrush(Color.FromRgb(159,159,159))
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
  for(int i=0;i<syncedLyricButtons.Count;i++){
   bool active=i==activeIndex;
   var button=syncedLyricButtons[i];
   button.Background=active?
    new SolidColorBrush(Color.FromArgb(50,185,185,185)):Brushes.Transparent;
   button.Foreground=active?
    Brushes.White:new SolidColorBrush(Color.FromRgb(159,159,159));
   if(button.Content is not TextBlock line)continue;
   line.Effect=active&&kineticLyrics?new DropShadowEffect{
    Color=Colors.White,BlurRadius=10,Opacity=.24,ShadowDepth=0
   }:null;
   for(int word=0;word<syncedLyricRuns[i].Count;word++){
    var run=syncedLyricRuns[i][word];
    run.Foreground=active
     ? (kineticLyrics && word>activeWord
       ? new SolidColorBrush(Color.FromRgb(162,162,171)) : Brushes.White)
     : new SolidColorBrush(Color.FromRgb(159,159,159));
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
