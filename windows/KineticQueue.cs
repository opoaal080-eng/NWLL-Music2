using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace Nightwell.Native;

public partial class MainWindow {
 bool depthQueue;
 bool kineticLyrics=true;

 void MoveUpcomingQueueTrack(int from,int to){
  if(nextPreparing){
   nextCancellation?.Cancel();
  }
  if(roomCode.Length>0){Status.Text="Сначала выйди из совместного прослушивания";return;}
  if(from<=index||to<=index||from<0||to<0||from>=queue.Count||to>=queue.Count||from==to)return;
  var current=Current;
  var song=queue[from];queue.RemoveAt(from);queue.Insert(to,song);
  if(current!=null)index=queue.IndexOf(current);
  QueueSavePlayback();
  Status.Text="Порядок следующих треков изменён";
 }

 EmbeddedSheet QueueWithDepthSetting(bool show=true){
  var panel=new StackPanel();
  panel.Children.Add(Label("Очередь воспроизведения"));
  panel.Children.Add(new TextBlock{
   Text=depthQueue?"Стопка следующих обложек · перетаскивай строки для изменения порядка":$"{queue.Count} треков",
   Foreground=(Brush)FindResource("SecondaryBrush"),
   TextWrapping=TextWrapping.Wrap,Margin=new Thickness(0,0,0,16)
  });
  if(!depthQueue){
   var regular=new ListBox{ItemsSource=queue,ItemTemplate=Tracks.ItemTemplate,Height=400};
   panel.Children.Add(regular);
   var normal=Sheet("Очередь",panel,570,show);
   regular.MouseDoubleClick+=async(_,_)=>{
    if(regular.SelectedItem is not Track t)return;
    if(roomCode.Length>0)await Guard(()=>RoomCommand("track",t.id));
    else{index=queue.IndexOf(t);PlayCurrent();}
    normal.Close();
   };
   return normal;
  }
  var scroll=new ScrollViewer{Height=480,VerticalScrollBarVisibility=ScrollBarVisibility.Auto};
  var content=new StackPanel();
  scroll.Content=content;
  panel.Children.Add(scroll);
  var deck=new Grid{Height=248,ClipToBounds=false};
  content.Children.Add(deck);
  var list=new ListBox{ItemsSource=queue,ItemTemplate=Tracks.ItemTemplate,Height=205,
   AllowDrop=true,Visibility=Visibility.Collapsed};
  var controlHint=new TextBlock{Text="Нажатие: играть сейчас · удержание или правая кнопка: следующая · свайп: порядок",
   Foreground=(Brush)FindResource("SecondaryBrush"),FontSize=12,
   TextWrapping=TextWrapping.Wrap,Margin=new Thickness(0,6,0,10)};
  content.Children.Add(controlHint);
  content.Children.Add(list);
  // The ordinary ListBox is deliberately hidden while the album deck is enabled.
  int deckPage=0;
  string highlightedID="";
  var feedback=new TextBlock{
   Text="",FontSize=13,FontWeight=FontWeights.SemiBold,
   Foreground=Brushes.White,TextAlignment=TextAlignment.Center,
   Margin=new Thickness(0,5,0,8),Visibility=Visibility.Collapsed
  };
  content.Children.Add(feedback);
  var pager=new StackPanel{Orientation=Orientation.Horizontal,
   HorizontalAlignment=HorizontalAlignment.Center,Margin=new Thickness(0,4,0,2)};
  var previousPage=new Button{Content="‹",Width=48,Height=38,Margin=new Thickness(4)};
  var pageCounter=new TextBlock{Foreground=(Brush)FindResource("SecondaryBrush"),
   VerticalAlignment=VerticalAlignment.Center,TextAlignment=TextAlignment.Center,
   Width=110,FontSize=12};
  var nextPage=new Button{Content="›",Width=48,Height=38,Margin=new Thickness(4)};
  pager.Children.Add(previousPage);pager.Children.Add(pageCounter);pager.Children.Add(nextPage);
  content.Children.Add(pager);
  var window=Sheet("Очередь",panel,600,show);
  var noticeTimer=new DispatcherTimer{Interval=TimeSpan.FromMilliseconds(1550)};
  noticeTimer.Tick+=(_,_)=>{
   noticeTimer.Stop();feedback.Visibility=Visibility.Collapsed;highlightedID="";
   Redraw();
  };
  void ShowFeedback(string message,string trackID=""){
   noticeTimer.Stop();
   highlightedID=trackID;feedback.Text=message;
   feedback.Visibility=Visibility.Visible;
   feedback.Opacity=0;
   feedback.BeginAnimation(UIElement.OpacityProperty,
    new System.Windows.Media.Animation.DoubleAnimation(0,1,TimeSpan.FromMilliseconds(170)));
   noticeTimer.Start();
  }
  previousPage.Click+=(_,_)=>{deckPage=Math.Max(0,deckPage-1);Redraw();};
  nextPage.Click+=(_,_)=>{deckPage++;Redraw();};
  void MoveNext(int from,string trackID){
   if(roomCode.Length>0){ShowFeedback("Недоступно при совместном прослушивании");return;}
   if(from==index+1){ShowFeedback("Уже следующий в очереди",trackID);return;}
   if(from<=index+1||from>=queue.Count)return;
   MoveUpcomingQueueTrack(from,index+1);
   deckPage=0;
   ShowFeedback("Следующий в очереди ✓",trackID);
   Redraw();
  }
  void Redraw(){
   deck.Children.Clear();
   int total=Math.Max(0,queue.Count-index-1);
   int totalPages=Math.Max(1,(total+2)/3);
   deckPage=Math.Clamp(deckPage,0,totalPages-1);
   int pageStart=index+1+deckPage*3;
   pager.Visibility=total>3?Visibility.Visible:Visibility.Collapsed;
   previousPage.IsEnabled=deckPage>0;
   nextPage.IsEnabled=deckPage<totalPages-1;
   pageCounter.Text=$"{Math.Min(total,deckPage*3+1)}–{Math.Min(total,(deckPage+1)*3)} из {total}";
   int count=Math.Min(3,Math.Max(0,queue.Count-pageStart));
   for(int rank=count-1;rank>=0;rank--){
    int from=pageStart+rank;
    var song=queue[from];
    var frame=new Border{
     Width=245,Height=210,Background=new SolidColorBrush(Color.FromRgb(22,22,27)),
     CornerRadius=new CornerRadius(19),
     BorderThickness=new Thickness(highlightedID==song.id?2.5:1),
     BorderBrush=new SolidColorBrush(highlightedID==song.id
      ?Color.FromRgb(241,241,255):Color.FromRgb(65,65,70)),
     HorizontalAlignment=HorizontalAlignment.Center,
     VerticalAlignment=VerticalAlignment.Center,
     RenderTransform=new TransformGroup{Children={
      new ScaleTransform(1-rank*.065,1-rank*.065),
      new RotateTransform(-rank*3),new TranslateTransform(rank*16,rank*9)
     }},RenderTransformOrigin=new Point(.5,.5),Cursor=Cursors.Hand
    };
    var image=new Image{Stretch=Stretch.UniformToFill};
    try{
     var url=new Uri(api.Origin,"api/covers/"+Uri.EscapeDataString(song.id));
     if(url.Scheme==Uri.UriSchemeHttps&&url.Authority==api.Origin.Authority){
      var picture=new BitmapImage();
      picture.BeginInit();picture.UriSource=url;picture.DecodePixelWidth=360;
      picture.CacheOption=BitmapCacheOption.OnLoad;picture.EndInit();
      image.Source=picture;
     }
    }catch{}
    var crop=new Grid{ClipToBounds=true};
    crop.Children.Add(image);
    var label=new Border{Background=new SolidColorBrush(Color.FromArgb(225,18,18,24)),
     Height=62,VerticalAlignment=VerticalAlignment.Bottom,Padding=new Thickness(10,7,10,6)};
    label.Child=new TextBlock{Text=song.title+"\n"+song.artist,
     TextTrimming=TextTrimming.CharacterEllipsis,TextWrapping=TextWrapping.NoWrap,
     Foreground=Brushes.White,FontSize=12,FontWeight=FontWeights.SemiBold};
    crop.Children.Add(label);frame.Child=crop;
    Panel.SetZIndex(frame,count-rank);
    deck.Children.Add(frame);
    var longPress=new DispatcherTimer{Interval=TimeSpan.FromMilliseconds(650)};
    bool held=false;Point down=default;
    longPress.Tick+=(_,_)=>{
      longPress.Stop();held=true;
      MoveNext(from,song.id);
    };
    frame.MouseRightButtonUp+=(_,e)=>{
      e.Handled=true;
      MoveNext(from,song.id);
    };
    frame.MouseLeftButtonDown+=(_,e)=>{
      down=e.GetPosition(frame);held=false;longPress.Start();
    };
    frame.MouseLeave+=(_,_)=>longPress.Stop();
    frame.MouseLeftButtonUp+=async(_,e)=>{
      longPress.Stop();if(held)return;
      var delta=e.GetPosition(frame).X-down.X;
      if(rank==0&&Math.Abs(delta)>48&&queue.Count>from+1){
       int source=delta<0?from+1:from;
       int target=delta<0?from:from+1;
       MoveUpcomingQueueTrack(source,target);
       ShowFeedback("Порядок обновлён",song.id);
       Redraw();
      }else if(Math.Abs(delta)<=48){
       // One normal click plays immediately; a completed hold never falls through.
       if(roomCode.Length>0)await Guard(()=>RoomCommand("track",song.id));
       else{index=queue.IndexOf(song);PlayCurrent();}
       window.Close();
      }
    };
   }
   if(count==0)deck.Children.Add(new TextBlock{Text="Следующие треки появятся здесь",
    HorizontalAlignment=HorizontalAlignment.Center,VerticalAlignment=VerticalAlignment.Center,
    Foreground=(Brush)FindResource("SecondaryBrush")});
  }
  Redraw();
  list.MouseDoubleClick+=async(_,_)=>{
   if(list.SelectedItem is not Track song)return;
   if(roomCode.Length>0)await Guard(()=>RoomCommand("track",song.id));
   else{index=queue.IndexOf(song);PlayCurrent();}
   window.Close();
  };
  var menu=new ContextMenu();
  var next=new MenuItem{Header="Играть следующим"};
  next.Click+=(_,_)=>{
   if(list.SelectedItem is not Track track)return;
   MoveUpcomingQueueTrack(queue.IndexOf(track),index+1);
   list.ItemsSource=null;list.ItemsSource=queue;Redraw();
  };
  menu.Items.Add(next);
  list.ContextMenu=menu;
  list.PreviewMouseMove+=(_,e)=>{
   if(e.LeftButton==MouseButtonState.Pressed&&list.SelectedItem is Track t){
    DragDrop.DoDragDrop(list,t,DragDropEffects.Move);
   }
  };
  list.Drop+=(_,e)=>{
   if(!e.Data.GetDataPresent(typeof(Track)))return;
   var source=e.Data.GetData(typeof(Track)) as Track;
   var target=(e.OriginalSource as FrameworkElement)?.DataContext as Track
    ??list.SelectedItem as Track;
   if(source==null||target==null)return;
   MoveUpcomingQueueTrack(queue.IndexOf(source),queue.IndexOf(target));
   list.ItemsSource=null;list.ItemsSource=queue;Redraw();
  };
  return window;
 }
}
