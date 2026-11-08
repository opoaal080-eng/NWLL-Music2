using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Media.Animation;
using System.Windows.Media.Effects;
using System.Windows.Threading;

namespace Nightwell.Native;

public partial class MainWindow {
 bool depthQueue;
 bool kineticLyrics=true;

 void MoveUpcomingQueueTrack(int from,int to){
  if(nextPreparing)nextCancellation?.Cancel();
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
   Text=depthQueue?"Объёмная очередь · листай все треки":$"{queue.Count} треков",
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

  // No regular list is constructed in depth mode. The parent Sheet already
  // scrolls, so nesting another ScrollViewer would clip the covers and footer.
  var content=new StackPanel{HorizontalAlignment=HorizontalAlignment.Stretch};
  panel.Children.Add(content);
  var deck=new Grid{
   Width=360,Height=316,HorizontalAlignment=HorizontalAlignment.Center,
   ClipToBounds=false,IsManipulationEnabled=true
  };
  content.Children.Add(deck);
  var hint=new TextBlock{
   Text="Нажми: слушать сейчас · удерживай: следующая · свайп: листать",
   Foreground=(Brush)FindResource("SecondaryBrush"),FontSize=12,
   TextWrapping=TextWrapping.Wrap,TextAlignment=TextAlignment.Center,
   Margin=new Thickness(0,10,0,8)
  };
  content.Children.Add(hint);
  var feedback=new TextBlock{
   FontSize=13,FontWeight=FontWeights.SemiBold,Foreground=Brushes.White,
   TextAlignment=TextAlignment.Center,Margin=new Thickness(0,6,0,7),
   Visibility=Visibility.Collapsed
  };
  content.Children.Add(feedback);

  var pager=new StackPanel{Orientation=Orientation.Horizontal,
   HorizontalAlignment=HorizontalAlignment.Center,Margin=new Thickness(0,6,0,6)};
  var previous=new Button{Content="‹",Width=48,Height=40,Margin=new Thickness(4),FontSize=20,Padding=new Thickness(0)};
  var position=new TextBlock{Width=130,Foreground=(Brush)FindResource("SecondaryBrush"),
   VerticalAlignment=VerticalAlignment.Center,TextAlignment=TextAlignment.Center,FontSize=12};
  var next=new Button{Content="›",Width=48,Height=40,Margin=new Thickness(4),FontSize=20,Padding=new Thickness(0)};
  pager.Children.Add(previous);pager.Children.Add(position);pager.Children.Add(next);
  content.Children.Add(pager);

  var window=Sheet("Очередь",panel,670,show);
  var artworkTasks=new Dictionary<string,Task<BitmapSource?>>(StringComparer.Ordinal);
  bool closed=false;
  window.Closed+=(_,_)=>closed=true;
  int cursor=0;
  string highlightedID="";
  DateTime lastBrowse=DateTime.MinValue;
  var noticeTimer=new DispatcherTimer{Interval=TimeSpan.FromMilliseconds(1550)};
  noticeTimer.Tick+=(_,_)=>{
   noticeTimer.Stop();highlightedID="";
   feedback.Visibility=Visibility.Collapsed;
   if(!closed)Redraw();
  };
  void ShowFeedback(string message,string trackId=""){
   noticeTimer.Stop();
   highlightedID=trackId;feedback.Text=message;
   feedback.Visibility=Visibility.Visible;feedback.Opacity=0;
   feedback.BeginAnimation(UIElement.OpacityProperty,
    new DoubleAnimation(0,1,TimeSpan.FromMilliseconds(160)));
   noticeTimer.Start();
  }

  // WPF UriSource does not send Nightwell login cookies. Always fetch image
  // bytes with the same authenticated HTTP client used by the real player.
  async Task<BitmapSource?> FetchArtwork(Track song){
   var candidates=new List<Uri>();
   if(!string.IsNullOrWhiteSpace(song.cover_url)
      && Uri.TryCreate(api.Origin,song.cover_url,out var external))
    candidates.Add(external);
   if(!string.IsNullOrWhiteSpace(song.id)
      && Uri.TryCreate(api.Origin,"api/covers/"+Uri.EscapeDataString(song.id),out var fallback)
      && !candidates.Contains(fallback))
    candidates.Add(fallback);
   foreach(var uri in candidates){
    if(uri.Scheme!=Uri.UriSchemeHttps && !(uri.Scheme==Uri.UriSchemeHttp && uri.IsLoopback))continue;
    try{
     var client=uri.Authority==api.Origin.Authority?api.HTTP:artworkHTTP;
     var bytes=await client.GetByteArrayAsync(uri,lifetime.Token);
     if(bytes.Length<100||bytes.Length>5*1024*1024)continue;
     return await Task.Run<BitmapSource>(()=>{
      using var stream=new MemoryStream(bytes);
      var bitmap=new BitmapImage();
      bitmap.BeginInit();
      bitmap.CacheOption=BitmapCacheOption.OnLoad;
      bitmap.DecodePixelWidth=480;
      bitmap.StreamSource=stream;
      bitmap.EndInit();
      bitmap.Freeze();
      return bitmap;
     },lifetime.Token);
    }catch(OperationCanceledException){return null;}
     catch{} // Invalid image or protected remote URL: try local cover endpoint.
   }
   return null;
  }
  async void LoadArtwork(Track song,Border frame,Image image,TextBlock fallback){
   string key=api.Origin.AbsoluteUri+"|"+song.id+"|"+song.cover_url;
   if(!artworkTasks.TryGetValue(key,out var task)){
    task=FetchArtwork(song);artworkTasks[key]=task;
   }
   try{
    var artwork=await task;
    if(closed||!deck.Children.Contains(frame)||artwork==null)return;
    image.Source=artwork;
    image.BeginAnimation(UIElement.OpacityProperty,
     new DoubleAnimation(0,1,TimeSpan.FromMilliseconds(230)));
    fallback.Visibility=Visibility.Collapsed;
   }catch{}
  }

  void Browse(int direction){
   int total=Math.Max(0,queue.Count-index-1);
   int target=Math.Clamp(cursor+direction,0,Math.Max(0,total-1));
   if(target==cursor)return;
   cursor=target;
   Redraw();
  }
  previous.Click+=(_,_)=>Browse(-1);
  next.Click+=(_,_)=>Browse(1);
  deck.PreviewMouseWheel+=(_,e)=>{
   if((DateTime.UtcNow-lastBrowse).TotalMilliseconds>=155){
    lastBrowse=DateTime.UtcNow;Browse(e.Delta<0?1:-1);
   }
   e.Handled=true;
  };
  deck.ManipulationCompleted+=(_,e)=>{
   double delta=e.TotalManipulation.Translation.X;
   if(Math.Abs(delta)>52){
    Browse(delta<0?1:-1);e.Handled=true;
   }
  };

  void MoveNext(int from,string trackId){
   if(roomCode.Length>0){ShowFeedback("Недоступно при совместном прослушивании");return;}
   if(from==index+1){ShowFeedback("Уже следующий в очереди",trackId);return;}
   if(from<=index+1||from>=queue.Count)return;
   MoveUpcomingQueueTrack(from,index+1);
   cursor=0;
   ShowFeedback("Следующий в очереди ✓",trackId);
   Redraw();
  }

  void Redraw(){
   deck.Children.Clear();
   int total=Math.Max(0,queue.Count-index-1);
   cursor=Math.Clamp(cursor,0,Math.Max(0,total-1));
   int first=index+1+cursor;
   pager.Visibility=total>1?Visibility.Visible:Visibility.Collapsed;
   previous.IsEnabled=cursor>0;
   next.IsEnabled=cursor<total-1;
   position.Text=$"{(total>0?cursor+1:0)} из {total}";

   int visible=Math.Min(3,Math.Max(0,queue.Count-first));
   for(int rank=visible-1;rank>=0;rank--){
    int from=first+rank;
    var song=queue[from];

    var frame=new Border{
     Width=250,Height=250,CornerRadius=new CornerRadius(21),
     BorderThickness=new Thickness(highlightedID==song.id?2:1),
     BorderBrush=new SolidColorBrush(highlightedID==song.id
      ?Color.FromRgb(239,239,255):Color.FromRgb(88,88,103)),
     Background=new SolidColorBrush(Color.FromRgb(28,28,36)),
     HorizontalAlignment=HorizontalAlignment.Center,
     VerticalAlignment=VerticalAlignment.Center,
     RenderTransform=new TransformGroup{Children={
      new ScaleTransform(1-rank*.055,1-rank*.055),
      new RotateTransform(rank*2.4),
      new TranslateTransform(rank*25,rank*11)
     }},
     RenderTransformOrigin=new Point(.5,.5),Cursor=Cursors.Hand,
     Effect=new DropShadowEffect{BlurRadius=15,ShadowDepth=6,Opacity=.35,Color=Colors.Black},
     ToolTip=$"{song.title}\n{song.artist}\nНажатие: играть · удержание: следующая"
    };

    var crop=new Grid{ClipToBounds=true};
    crop.SizeChanged+=(_,e)=>
     crop.Clip=new RectangleGeometry(new Rect(new Point(0,0),e.NewSize),19,19);
    var background=new Border{
     Background=new LinearGradientBrush(Color.FromRgb(72,68,96),
      Color.FromRgb(21,20,31),65)
    };
    crop.Children.Add(background);
    var fallback=new TextBlock{
     Text="N",FontSize=110,FontWeight=FontWeights.Light,
     Foreground=new SolidColorBrush(Color.FromArgb(65,255,255,255)),
     HorizontalAlignment=HorizontalAlignment.Center,
     VerticalAlignment=VerticalAlignment.Center,
     IsHitTestVisible=false
    };
    crop.Children.Add(fallback);
    var image=new Image{
     Stretch=Stretch.UniformToFill,Opacity=0,
     HorizontalAlignment=HorizontalAlignment.Stretch,
     VerticalAlignment=VerticalAlignment.Stretch,IsHitTestVisible=false
    };
    crop.Children.Add(image);
    var gradient=new LinearGradientBrush{
     StartPoint=new Point(0,0),EndPoint=new Point(0,1)
    };
    gradient.GradientStops.Add(new GradientStop(Color.FromArgb(0,6,6,11),0));
    gradient.GradientStops.Add(new GradientStop(Color.FromArgb(205,7,7,13),.38));
    gradient.GradientStops.Add(new GradientStop(Color.FromArgb(245,7,7,12),1));
    var footer=new Border{
     Height=82,VerticalAlignment=VerticalAlignment.Bottom,
     Background=gradient,Padding=new Thickness(13,17,13,9)
    };
    var labels=new StackPanel{Orientation=Orientation.Vertical};
    labels.Children.Add(new TextBlock{
     Text=song.title,TextTrimming=TextTrimming.CharacterEllipsis,
     TextWrapping=TextWrapping.NoWrap,FontWeight=FontWeights.SemiBold,
     Foreground=Brushes.White,FontSize=13,ToolTip=song.title
    });
    labels.Children.Add(new TextBlock{
     Text=song.artist,TextTrimming=TextTrimming.CharacterEllipsis,
     TextWrapping=TextWrapping.NoWrap,FontSize=11,
     Foreground=new SolidColorBrush(Color.FromRgb(203,203,215)),
     Margin=new Thickness(0,4,0,0),ToolTip=song.artist
    });
    footer.Child=labels;crop.Children.Add(footer);
    frame.Child=crop;
    Panel.SetZIndex(frame,visible-rank);
    deck.Children.Add(frame);
    LoadArtwork(song,frame,image,fallback);

    var hold=new DispatcherTimer{Interval=TimeSpan.FromMilliseconds(650)};
    bool held=false;
    Point start=default;
    hold.Tick+=(_,_)=>{
     hold.Stop();held=true;MoveNext(from,song.id);
    };
    frame.MouseRightButtonUp+=(_,e)=>{
     e.Handled=true;hold.Stop();held=true;MoveNext(from,song.id);
    };
    frame.MouseLeftButtonDown+=(_,e)=>{
     start=e.GetPosition(frame);held=false;hold.Start();
     frame.CaptureMouse();
     e.Handled=true;
    };
    frame.MouseMove+=(_,e)=>{
     if(e.LeftButton==MouseButtonState.Pressed&&
        Math.Abs(e.GetPosition(frame).X-start.X)>30)
      hold.Stop();
    };
    frame.MouseLeftButtonUp+=async(_,e)=>{
     hold.Stop();frame.ReleaseMouseCapture();
     if(held){e.Handled=true;return;}
     Point end=e.GetPosition(frame);
     double dx=end.X-start.X,dy=end.Y-start.Y;
     if(Math.Abs(dx)>48&&Math.Abs(dx)>Math.Abs(dy)){
      Browse(dx<0?1:-1);
     }else if(Math.Abs(dx)<15&&Math.Abs(dy)<15){
      if(roomCode.Length>0)await Guard(()=>RoomCommand("track",song.id));
      else{index=queue.IndexOf(song);PlayCurrent();}
      window.Close();
     }
     e.Handled=true;
    };
    frame.LostMouseCapture+=(_,_)=>hold.Stop();
   }
   if(visible==0)deck.Children.Add(new TextBlock{
    Text="Следующих треков пока нет",
    HorizontalAlignment=HorizontalAlignment.Center,
    VerticalAlignment=VerticalAlignment.Center,
    Foreground=(Brush)FindResource("SecondaryBrush")
   });
  }
  Redraw();
  return window;
 }
}
