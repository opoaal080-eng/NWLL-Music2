using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
namespace Nightwell.Native;
public partial class MainWindow {
 public static readonly DependencyProperty PlayingTrackIdProperty=DependencyProperty.Register(nameof(PlayingTrackId),typeof(string),typeof(MainWindow),new PropertyMetadata(""));
 public static readonly DependencyProperty ActiveArtworkProperty=DependencyProperty.Register(nameof(ActiveArtwork),typeof(ImageSource),typeof(MainWindow));
 public string PlayingTrackId{get=>(string)GetValue(PlayingTrackIdProperty);set=>SetValue(PlayingTrackIdProperty,value);}
 public ImageSource? ActiveArtwork{get=>(ImageSource?)GetValue(ActiveArtworkProperty);set=>SetValue(ActiveArtworkProperty,value);}
 bool backgroundOnly;
 void LogoHomeClick(object sender,RoutedEventArgs e){LeaveBackgroundMode();Show("Главная");}
 void LeaveBackgroundMode(){backgroundOnly=false;Status.ClearValue(VisibilityProperty);Header.Visibility=HomeControls.Visibility=PlaybackBadge.Visibility=Visibility.Visible;HomeHeading.Visibility=Visibility.Collapsed;HeaderRow.Height=new GridLength(58);MouseDoubleClick-=RestoreBackground;}
 void UpdateCoverBackdrop(Color primary,Color secondary){
  Ribbon.SetPalette(primary,secondary);
  var brush=new RadialGradientBrush{
   Center=new Point(.48,.15),
   GradientOrigin=new Point(.48,.15),
   RadiusX=.95,RadiusY=1.15
  };
  brush.GradientStops.Add(new GradientStop(Color.FromArgb(118,primary.R,primary.G,primary.B),0));
  brush.GradientStops.Add(new GradientStop(Color.FromArgb(55,secondary.R,secondary.G,secondary.B),.53));
  brush.GradientStops.Add(new GradientStop(Color.FromArgb(0,11,11,11),1));
  PlayerPage.Background=brush;
  Home.Background=brush;
 }
 void UpdatePlaybackChrome(){
  PlayingTrackId=currentID;Ribbon.Playing=audioPlaying;Ribbon.Intensity=userVolume;Ribbon.Focused=PlayerPage.Visibility==Visibility.Visible;
  FullLike.Content=MiniLike.Content=likes.Contains(currentID)?"♥":"♡";
  FullLike.ToolTip=MiniLike.ToolTip=likes.Contains(currentID)?"Убрать из избранного":"В избранное";
  PlaybackBadgeText.Text=Current==null?"ТВОЙ ПОТОК":audioPlaying?"СЕЙЧАС ИГРАЕТ":"НА ПАУЗЕ";
  PlaybackDot.Opacity=audioPlaying?1:.4;
  SetMode(ShuffleButton,shuffle);SetMode(RepeatButton,repeat>0);RepeatOne.Visibility=repeat==2?Visibility.Visible:Visibility.Collapsed;
  RepeatButton.ToolTip=new[]{"Повтор выключен","Повтор очереди","Повтор трека"}[repeat];
 }
 void SetMode(Button button,bool active){if(button.Tag is bool previous&&previous==active)return;button.Tag=active;button.Background=active?(Brush)FindResource("SelectionBrush"):Brushes.Transparent;button.Foreground=(Brush)FindResource(active?"AccentBrush":"TextBrush");button.BorderBrush=active?(Brush)FindResource("LineBrush"):Brushes.Transparent;}
 void InterfaceKeyDown(object sender,KeyEventArgs e){
  if(Keyboard.FocusedElement is TextBox or PasswordBox or ComboBox)return;
  if(e.Key==Key.Escape){if(visibleSheet!=null)HideEmbeddedSheet(visibleSheet);else if(backgroundOnly){LeaveBackgroundMode();Show("Главная");}else if(LyricsPanel.Visibility==Visibility.Visible)CloseLyricsClick(sender,e);else if(PlayerPage.Visibility==Visibility.Visible)ReturnFromPlayer();else Show("Главная");e.Handled=true;}
  else if(e.Key==Key.Space&&Keyboard.FocusedElement is not System.Windows.Controls.Primitives.ButtonBase){ToggleClick(sender,e);e.Handled=true;}
 }
 static (Color,Color) ArtworkPalette(BitmapSource source){
  try{var tiny=new TransformedBitmap(source,new ScaleTransform(24.0/source.PixelWidth,24.0/source.PixelHeight));var converted=new FormatConvertedBitmap(tiny,PixelFormats.Bgra32,null,0);byte[] pixels=new byte[24*24*4];converted.CopyPixels(pixels,96,0);
   double r=0,g=0,b=0,total=0;for(int i=0;i<pixels.Length;i+=4){if(pixels[i+3]<120)continue;double hi=Math.Max(pixels[i],Math.Max(pixels[i+1],pixels[i+2])),lo=Math.Min(pixels[i],Math.Min(pixels[i+1],pixels[i+2]));if(hi<28||lo>224)continue;double weight=.3+(hi-lo)/255.0;r+=pixels[i+2]*weight;g+=pixels[i+1]*weight;b+=pixels[i]*weight;total+=weight;}
   if(total>0){
    byte Bound(double value)=>(byte)Math.Clamp(22+value/total*.74,32,188);
    var primary=Color.FromRgb(Bound(r),Bound(g),Bound(b));
    var secondary=Color.FromRgb(
     (byte)Math.Clamp(primary.R*.65+primary.B*.22,28,170),
     (byte)Math.Clamp(primary.G*.72+primary.R*.16,28,170),
     (byte)Math.Clamp(primary.B*.74+primary.G*.14,28,170));
    return(primary,secondary);
   }
  }catch{}
  return(Color.FromRgb(123,123,123),Color.FromRgb(106,106,106));
 }
}
public sealed class TrackMatchConverter:IMultiValueConverter {
 public object Convert(object[] values,Type targetType,object parameter,CultureInfo culture)=>values.Length>1&&values[0] is string id&&id.Length>0&&values[1] is string playing&&id==playing;
 public object[] ConvertBack(object value,Type[] targetTypes,object parameter,CultureInfo culture)=>throw new NotSupportedException();
}
public sealed class CurrentArtworkConverter:IMultiValueConverter {
 public object? Convert(object[] values,Type targetType,object parameter,CultureInfo culture)=>values.Length>2&&values[0] is string id&&values[1] is string playing&&id==playing&&values[2] is ImageSource image?image:null;
 public object[] ConvertBack(object value,Type[] targetTypes,object parameter,CultureInfo culture)=>throw new NotSupportedException();
}
public sealed class TrackCountConverter:IValueConverter {
 public object Convert(object value,Type targetType,object parameter,CultureInfo culture){int count=value is int n?n:0;string word=count%100 is >=11 and <=14?"треков":count%10==1?"трек":count%10 is >=2 and <=4?"трека":"треков";return count+" "+word;}
 public object ConvertBack(object value,Type targetType,object parameter,CultureInfo culture)=>throw new NotSupportedException();
}
