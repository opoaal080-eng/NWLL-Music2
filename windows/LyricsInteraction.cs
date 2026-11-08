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

 void DisplaySyncedLyrics(JsonElement[] all,int activeIndex,int activeWord){
  if(displayedLyricsTrack!=currentID||syncedLyricButtons.Count!=all.Length){
   displayedLyricsTrack=currentID;
   syncedLyricButtons.Clear();
   SyncedLyricsLines.Children.Clear();
   foreach(var entry in all){
    var seconds=entry.GetProperty("time").GetDouble();
    var text=entry.GetProperty("text").GetString()??"";
    var content=new TextBlock{
     Text=text,TextAlignment=TextAlignment.Center,
     TextWrapping=TextWrapping.Wrap,FontSize=18
    };
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
   }
  }
  LyricsText.Visibility=Visibility.Collapsed;
  SyncedLyricsLines.Visibility=Visibility.Visible;
  for(int i=0;i<syncedLyricButtons.Count;i++){
   bool active=i==activeIndex;
   var button=syncedLyricButtons[i];
   button.Background=active?
    new SolidColorBrush(Color.FromArgb(50,185,185,185)):Brushes.Transparent;
   button.Foreground=active?
    Brushes.White:new SolidColorBrush(Color.FromRgb(159,159,159));
   if(button.Content is not TextBlock line)continue;
   string text=all[i].GetProperty("text").GetString()??"";
   line.Inlines.Clear();
   line.FontSize=active?21:18;
   line.Effect=active&&kineticLyrics?new DropShadowEffect{
     Color=Colors.White,BlurRadius=12,Opacity=.30,ShadowDepth=0
   }:null;
   if(active&&kineticLyrics){
    string[] words=text.Split(' ',StringSplitOptions.RemoveEmptyEntries);
    var repeated=all.Count(e=>string.Equals(
     e.GetProperty("text").GetString(),text,StringComparison.OrdinalIgnoreCase))>1;
    for(int k=0;k<words.Length;k++){
     var run=new Run(words[k]+(k+1<words.Length?" ":"")){
      Foreground=k<=activeWord?Brushes.White:new SolidColorBrush(Color.FromRgb(162,162,171)),
      FontSize=k==activeWord?(repeated?25:23):21,
      FontWeight=k==activeWord?FontWeights.ExtraBold:FontWeights.SemiBold
     };
     line.Inlines.Add(run);
    }
   }else line.Inlines.Add(new Run(text));
   if(active&&i!=previousKineticLine&&kineticLyrics){
    line.BeginAnimation(UIElement.OpacityProperty,new DoubleAnimation(.65,1,
     TimeSpan.FromMilliseconds(260)));
   }
  }
  previousKineticLine=activeIndex;
  if(activeIndex>=0&&activeIndex<syncedLyricButtons.Count){
   var target=syncedLyricButtons[activeIndex];
   Dispatcher.BeginInvoke(new Action(()=>{if(target.IsLoaded&&LyricsPanel.IsVisible)target.BringIntoView();}),DispatcherPriority.Background);
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
