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
   AllowDrop=true};
  var controlHint=new TextBlock{Text="Двойной щелчок: воспроизвести · правая кнопка: играть следующим",
   Foreground=(Brush)FindResource("SecondaryBrush"),FontSize=12,
   TextWrapping=TextWrapping.Wrap,Margin=new Thickness(0,6,0,10)};
  content.Children.Add(controlHint);
  content.Children.Add(list);
  var window=Sheet("Очередь",panel,600,show);
  void Redraw(){
   deck.Children.Clear();
   int count=Math.Min(3,Math.Max(0,queue.Count-index-1));
   for(int rank=count-1;rank>=0;rank--){
    int from=index+1+rank;
    var song=queue[from];
    var frame=new Border{
     Width=245,Height=210,Background=new SolidColorBrush(Color.FromRgb(22,22,27)),
     CornerRadius=new CornerRadius(19),BorderThickness=new Thickness(1),
     BorderBrush=new SolidColorBrush(Color.FromRgb(65,65,70)),
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
      if(rank>0){
       MoveUpcomingQueueTrack(from,index+1);
       list.ItemsSource=null;list.ItemsSource=queue;Redraw();
      }
    };
    frame.MouseLeftButtonDown+=(_,e)=>{
      down=e.GetPosition(frame);held=false;longPress.Start();
    };
    frame.MouseLeave+=(_,_)=>longPress.Stop();
    frame.MouseLeftButtonUp+=async(_,e)=>{
      longPress.Stop();if(held)return;
      var delta=e.GetPosition(frame).X-down.X;
      if(rank==0&&Math.Abs(delta)>48&&queue.Count>index+2){
       MoveUpcomingQueueTrack(index+1,index+2);
       list.ItemsSource=null;list.ItemsSource=queue;Redraw();
      }else if(Math.Abs(delta)<=48&&e.ClickCount==2){
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
