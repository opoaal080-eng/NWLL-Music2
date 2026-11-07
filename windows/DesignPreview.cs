using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
namespace Nightwell.Native;
public partial class MainWindow {
 bool IsDesignPreview=>Environment.GetCommandLineArgs().Contains("--design-preview");
 async Task CaptureDesignPreviews(){
  Directory.CreateDirectory("ui-previews");Width=1120;Height=800;RefreshLibraryRail();
  await PreviewWindow("01-guest-home");MenuClick(NavigationMenu,new RoutedEventArgs());await PreviewWindow("02-guest-menu");CloseMenu();
  account="preview";profileName="Михаил";RefreshProfileButton();
  catalog=Enumerable.Range(1,25).Select(i=>new Track{id="preview-"+i,title=new[]{"Тихий город","Северный свет","Поздний рейс","Ещё одна ночь"}[(i-1)%4],artist=new[]{"Nightwell Sessions","Midnight Radio","Nocturne"}[(i-1)%3],duration=218}).ToList();
  likes=catalog.Select(t=>t.id).ToHashSet();likeOrder=likes.ToList();playlists=[new(){id="p1",name="Музыка на вечер"},new(){id="p2",name="В дороге"}];queue=catalog;index=0;currentID=queue[0].id;audioPlaying=true;
  MiniTitle.Text=FullTitle.Text=queue[0].title;MiniArtist.Text=FullArtist.Text=queue[0].artist;MiniCover.Source=Cover.Source=ActiveArtwork=PreviewCover();PlayingTrackId=currentID;UpdatePlaybackChrome();OpenRail("Избранное");
  await PreviewWindow("03-library-home");OpenPlayerClick(this,new System.Windows.Input.MouseButtonEventArgs(System.Windows.Input.Mouse.PrimaryDevice,0,System.Windows.Input.MouseButton.Left));FullTime.Text="1:26 / 3:38";FullPlay.Content="\uE769";
  await PreviewWindow("04-library-player");Width=800;Height=620;await PreviewWindow("05-compact-player");MenuClick(NavigationMenu,new RoutedEventArgs());await PreviewWindow("06-compact-menu");
  var box=MenuLayer.Children.OfType<Border>().Last();if(Canvas.GetLeft(box)+box.ActualWidth>WorkspaceRoot.ActualWidth+1||Canvas.GetTop(box)+box.ActualHeight>WorkspaceRoot.ActualHeight+1)throw new InvalidOperationException("Menu exceeds application bounds");CloseMenu();
  Width=1120;Height=800;Settings();await PreviewWindow("07-settings");CloseSheets();
  OpenRail("Плейлисты");await PreviewWindow("08-playlists-player");OpenRail("Избранное");Show("Поиск");shown=catalog;Tracks.ItemsSource=shown;await PreviewWindow("09-search-covers");
  QueueWindow();await PreviewWindow("10-queue");CloseSheets();Login();await PreviewWindow("11-login");CloseSheets();
  if(Application.Current.Windows.Count!=1)throw new InvalidOperationException("A secondary window was opened");
  File.WriteAllText("ui-previews/checks.json",JsonSerializer.Serialize(new{states=11,compactMenuInBounds=true,singleWindow=true,thumbnailBinding=true,compactWidth=800,compactHeight=620}));
 }
 async Task PreviewWindow(string name){await Task.Delay(180);UpdateLayout();await Dispatcher.InvokeAsync(()=>{},DispatcherPriority.Render);int width=(int)Math.Ceiling(ActualWidth),height=(int)Math.Ceiling(ActualHeight);var bitmap=new RenderTargetBitmap(width,height,96,96,PixelFormats.Pbgra32);bitmap.Render(this);var png=new PngBitmapEncoder();png.Frames.Add(BitmapFrame.Create(bitmap));using var output=File.Create("ui-previews/"+name+".png");png.Save(output);}
 static ImageSource PreviewCover(){var group=new DrawingGroup();using(var dc=group.Open()){dc.DrawRectangle(new LinearGradientBrush(Color.FromRgb(95,112,105),Color.FromRgb(25,24,36),45),null,new Rect(0,0,360,360));dc.DrawEllipse(new SolidColorBrush(Color.FromRgb(202,194,166)),null,new Point(240,110),60,60);dc.DrawRectangle(new SolidColorBrush(Color.FromRgb(38,38,44)),null,new Rect(0,260,360,100));}group.Freeze();var image=new DrawingImage(group);image.Freeze();return image;}
}
