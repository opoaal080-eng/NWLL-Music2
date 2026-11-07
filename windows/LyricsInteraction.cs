using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;

namespace Nightwell.Native;

public partial class MainWindow {
 string displayedLyricsTrack="";
 readonly List<Button> syncedLyricButtons=new();

 void DisplaySyncedLyrics(JsonElement[] all,int activeIndex){
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
   syncedLyricButtons[i].Background=active?
    new SolidColorBrush(Color.FromArgb(62,185,185,185)):Brushes.Transparent;
   syncedLyricButtons[i].Foreground=active?
    Brushes.White:new SolidColorBrush(Color.FromRgb(159,159,159));
  }
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
