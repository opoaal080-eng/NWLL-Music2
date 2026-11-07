using System.Globalization;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
namespace Nightwell.Native;
public partial class MainWindow {
 bool IsDesignPreview=>Environment.GetCommandLineArgs().Contains("--design-preview");
 async Task CaptureDesignPreviews(){
  Directory.CreateDirectory("ui-previews");Width=1120;Height=800;
  Status.Text="";Ribbon.PreviewPhase=1.4;await PreviewWindow(this,"01-home");
  Ribbon.Playing=true;Ribbon.Intensity=.8;Ribbon.PreviewPhase=4.2;await PreviewWindow(this,"12-ambient-playing");
  Ribbon.PreviewPhase=9.4;await PreviewWindow(this,"13-ambient-motion");
  BackgroundClick(this,new RoutedEventArgs());await PreviewWindow(this,"14-background-only");
  LogoHome.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));if(Home.Visibility!=Visibility.Visible||Header.Visibility!=Visibility.Visible||HeaderRow.Height.Value!=58)throw new InvalidOperationException("Logo did not restore the home screen");
  Ribbon.Playing=false;Ribbon.PreviewPhase=1.4;
  var demo=new List<Track>{
   new(){id="preview-1",title="Тихий город",artist="Nightwell Sessions",duration=218},
   new(){id="preview-2",title="Северный свет",artist="Midnight Radio",duration=192},
   new(){id="preview-3",title="Поздний рейс",artist="Nightwell Sessions",duration=246},
   new(){id="preview-4",title="Ещё одна ночь",artist="Nocturne",duration=205},
   new(){id="preview-5",title="Оставаться собой",artist="Midnight Radio",duration=228},
   new(){id="preview-6",title="Пока город спит",artist="Nocturne",duration=184}
  };
  catalog=demo;likes=demo.Select(t=>t.id).ToHashSet();queue=demo;index=0;currentID=demo[0].id;
  MiniTitle.Text=FullTitle.Text=demo[0].title;MiniArtist.Text=FullArtist.Text=demo[0].artist;MiniCover.Source=Cover.Source=ActiveArtwork=PreviewCover();PlayingTrackId=currentID;audioPlaying=true;shuffle=true;repeat=2;UpdatePlaybackChrome();
  Show("Избранное");Tracks.SelectedIndex=1;await PreviewWindow(this,"02-library-selection");
  SearchOptions.Visibility=SearchBox.Visibility=Visibility.Visible;Heading.Text="Поиск";SearchBox.Text="Nightwell";await PreviewWindow(this,"03-search");
  Home.Visibility=Library.Visibility=Dock.Visibility=Visibility.Collapsed;PlayerPage.Visibility=Visibility.Visible;Ribbon.Visibility=Visibility.Visible;Ribbon.Focused=true;
  FullSeek.Maximum=218;FullSeek.Value=86;FullTime.Text="1:26    /    3:38";FullPlay.Content="\uE769";FullVolumeSlider.Value=VolumeSlider.Value=72;FullVolumeValue.Text=MiniVolumeValue.Text="72%";
  await PreviewWindow(this,"04-player");Width=800;Height=620;await PreviewWindow(this,"05-player-compact");
  Width=1120;Height=800;
  using var lyrics=JsonDocument.Parse("{\"plain\":\"Город засыпает, огни не спешат.\\nВ каждом окне свой маленький мир.\\nМузыка рядом, и время звучит.\"}");
  LyricsText.Text=lyrics.RootElement.GetProperty("plain").GetString();LyricsPanel.Visibility=Visibility.Visible;await PreviewWindow(this,"06-lyrics");LyricsPanel.Visibility=Visibility.Collapsed;
  var settings=Settings(false);settings.Show();await PreviewWindow(settings,"07-settings");settings.Close();
  account="preview";tasteArtists=["Nightwell Sessions","Nocturne"];await TasteSettings();
  var taste=Application.Current.Windows.OfType<Window>().Last(w=>w!=this);await PreviewWindow(taste,"08-taste");
  var scroll=(ScrollViewer)taste.Content;scroll.ScrollToBottom();await Dispatcher.InvokeAsync(()=>{},DispatcherPriority.Render);
  var combo=((StackPanel)scroll.Content).Children.OfType<ComboBox>().Last();combo.BringIntoView();combo.IsDropDownOpen=true;await Task.Delay(200);taste.UpdateLayout();
  var popup=(Popup)combo.Template.FindName("PART_Popup",combo);if(popup.Child is FrameworkElement drop)await PreviewElement(drop,"09-dropdown");combo.IsDropDownOpen=false;taste.Close();
  var queueWindow=QueueWindow(false);queueWindow.Show();await PreviewWindow(queueWindow,"10-queue");queueWindow.Close();
  LogoHome.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));if(Home.Visibility!=Visibility.Visible||PlayerPage.Visibility!=Visibility.Collapsed||currentID!=demo[0].id)throw new InvalidOperationException("Logo navigation changed playback");
  Ribbon.Visibility=Visibility.Collapsed;await Dispatcher.InvokeAsync(()=>{},DispatcherPriority.Render);long frames=Ribbon.RenderedFrames;await Task.Delay(200);if(Ribbon.RenderedFrames!=frames)throw new InvalidOperationException("Hidden background is still rendering");Ribbon.Visibility=Visibility.Visible;
  Login();var login=Application.Current.Windows.OfType<Window>().Last(w=>w!=this);await PreviewWindow(login,"11-login");login.Close();
  File.WriteAllText("ui-previews/checks.json",JsonSerializer.Serialize(new{theme="monochrome-ambient",states=14,logoNavigation=true,hiddenBackgroundStopped=true,networkRequests=0,compactWidth=800,compactHeight=620,primaryContrast=Contrast(BrushHex("TextBrush"),BrushHex("SurfaceBrush")),secondaryContrast=Contrast(BrushHex("SecondaryBrush"),BrushHex("InputBrush"))}));
 }
 string BrushHex(string key){var color=((SolidColorBrush)FindResource(key)).Color;return $"{color.R:X2}{color.G:X2}{color.B:X2}";}
 async Task PreviewWindow(Window window,string name){await Task.Delay(120);window.UpdateLayout();await Dispatcher.InvokeAsync(()=>{},DispatcherPriority.Render);await PreviewElement(window,name);}
 async Task PreviewElement(FrameworkElement element,string name){
  element.UpdateLayout();await Dispatcher.InvokeAsync(()=>{},DispatcherPriority.Render);
  int width=(int)Math.Ceiling(element.ActualWidth),height=(int)Math.Ceiling(element.ActualHeight);if(width<1||height<1)throw new InvalidOperationException("Empty preview: "+name);
  var bitmap=new RenderTargetBitmap(width,height,96,96,PixelFormats.Pbgra32);bitmap.Render(element);var png=new PngBitmapEncoder();png.Frames.Add(BitmapFrame.Create(bitmap));using var output=File.Create("ui-previews/"+name+".png");png.Save(output);
 }
 static double Contrast(string a,string b){double Light(string hex){double Linear(int offset){var c=Convert.ToInt32(hex.Substring(offset,2),16)/255.0;return c<=.04045?c/12.92:Math.Pow((c+.055)/1.055,2.4);}return .2126*Linear(0)+.7152*Linear(2)+.0722*Linear(4);}var x=Light(a);var y=Light(b);return Math.Round((Math.Max(x,y)+.05)/(Math.Min(x,y)+.05),2);}
 static ImageSource PreviewCover(){
  var drawing=new DrawingGroup();using(var dc=drawing.Open()){
   dc.DrawRectangle(new LinearGradientBrush(Color.FromRgb(57,57,57),Color.FromRgb(22,22,22),45),null,new Rect(0,0,360,360));
   dc.DrawEllipse(new SolidColorBrush(Color.FromArgb(28,168,168,168)),null,new Point(256,118),144,144);
   dc.DrawEllipse(null,new Pen(new SolidColorBrush(Color.FromRgb(91,91,91)),1.5),new Point(180,180),104,104);
   dc.DrawEllipse(null,new Pen(new SolidColorBrush(Color.FromRgb(71,71,71)),1),new Point(180,180),122,122);
   var face=new Typeface("Segoe UI");var text=new FormattedText("NIGHTWELL",CultureInfo.InvariantCulture,FlowDirection.LeftToRight,face,26,new SolidColorBrush(Color.FromRgb(215,215,215)),1);dc.DrawText(text,new Point(104,154));
   var caption=new FormattedText("S E S S I O N S",CultureInfo.InvariantCulture,FlowDirection.LeftToRight,face,12,new SolidColorBrush(Color.FromRgb(166,166,166)),1);dc.DrawText(caption,new Point(131,195));
  }drawing.Freeze();var image=new DrawingImage(drawing);image.Freeze();return image;
 }
}
