using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using LibVLCSharp.Shared;
using Microsoft.Win32;

namespace Nightwell.Native;

// Pages and menus belong to the application layout, never to desktop popups.
public sealed class WorkspaceSheet {
 readonly MainWindow owner;
 public Grid Content {get;}
 public event EventHandler? Closed;
 public WorkspaceSheet(MainWindow owner,string title,StackPanel panel){
  this.owner=owner;panel.Margin=new Thickness(24,4,24,24);
  Content=new Grid();Content.RowDefinitions.Add(new RowDefinition{Height=GridLength.Auto});Content.RowDefinitions.Add(new RowDefinition());
  var header=new DockPanel{Margin=new Thickness(20,16,20,10)};
  var close=new Button{Content="×",Style=(Style)owner.FindResource("IconButton"),ToolTip="Закрыть"};close.Click+=(_,_)=>Close();DockPanel.SetDock(close,Dock.Right);header.Children.Add(close);
  header.Children.Add(new TextBlock{Text=title,FontSize=22,FontWeight=FontWeights.SemiBold,VerticalAlignment=VerticalAlignment.Center});
  Content.Children.Add(header);var scroll=new ScrollViewer{Content=panel,VerticalScrollBarVisibility=ScrollBarVisibility.Auto,HorizontalScrollBarVisibility=ScrollBarVisibility.Disabled};Grid.SetRow(scroll,1);Content.Children.Add(scroll);
 }
 public void Show()=>owner.PresentSheet(this);
 public void Activate()=>Show();
 public void Close(){owner.DismissSheet(this);Closed?.Invoke(this,EventArgs.Empty);}
}

public sealed record LibraryEntry(string Title,string Subtitle,Track? Track=null,string PlaylistID="");

public partial class MainWindow {
 readonly List<WorkspaceSheet> sheets=[];
 string railSection="Избранное",railPlaylist="",railTitle="";
 List<Track> railTracks=[];
 int railRequest;
 string profileName="",profileAvatar="";
 bool railHidden;
 int shuffleMode,shuffleRevision;
 List<Track>? unshuffled;
 readonly SemaphoreSlim thumbnailGate=new(4,4);
 readonly Dictionary<string,Task<ImageSource?>> thumbnails=new();

 void InitializeWorkspace(){
  Thumbnail.Loader=LoadThumbnail;
  SizeChanged+=(_,_)=>{CloseMenu();ResizeRail();};
  EventManager.RegisterClassHandler(typeof(ComboBox),LoadedEvent,new RoutedEventHandler((sender,_)=>{
   if(sender is ComboBox combo){combo.DropDownOpened-=FitDropDown;combo.DropDownOpened+=FitDropDown;}
  }));
 }
 void FitDropDown(object? sender,EventArgs e){
  if(sender is not ComboBox combo)return;
  var point=combo.TranslatePoint(new Point(),WorkspaceRoot);
  double below=WorkspaceRoot.ActualHeight-point.Y-combo.ActualHeight-12,above=point.Y-12;
  combo.MaxDropDownHeight=Math.Max(40,Math.Min(180,Math.Max(below,above)));
  if(combo.Template.FindName("PART_Popup",combo) is System.Windows.Controls.Primitives.Popup popup){
   popup.Placement=System.Windows.Controls.Primitives.PlacementMode.Custom;
   popup.CustomPopupPlacementCallback=(size,target,offset)=>new[]{new System.Windows.Controls.Primitives.CustomPopupPlacement(new Point(Math.Min(0,WorkspaceRoot.ActualWidth-point.X-size.Width-8),below>=size.Height?combo.ActualHeight:-size.Height),System.Windows.Controls.Primitives.PopupPrimaryAxis.None)};
  }
 }
 internal void PresentSheet(WorkspaceSheet sheet){
  CloseMenu();sheets.Remove(sheet);sheets.Add(sheet);RenderSheet();
 }
 internal void DismissSheet(WorkspaceSheet sheet){sheets.Remove(sheet);RenderSheet();}
 void RenderSheet(){SheetHost.Children.Clear();SheetHost.Visibility=sheets.Count>0?Visibility.Visible:Visibility.Collapsed;if(sheets.Count>0)SheetHost.Children.Add(sheets[^1].Content);}
 void CloseSheets(){foreach(var sheet in sheets.ToArray().Reverse())sheet.Close();}
 bool CloseWorkspaceLayer(){if(MenuLayer.Visibility==Visibility.Visible){CloseMenu();return true;}if(sheets.Count>0){sheets[^1].Close();return true;}return false;}
 void CloseMenu(){MenuLayer.Children.Clear();MenuLayer.Visibility=Visibility.Collapsed;}
 void OpenMenu(ContextMenu menu,UIElement anchor){
  var items=menu.Items.OfType<MenuItem>().ToList();
  void ShowItems(List<MenuItem> list,Action? back=null){
   CloseMenu();MenuLayer.Visibility=Visibility.Visible;
   var backdrop=new Border{Background=Brushes.Transparent,Width=WorkspaceRoot.ActualWidth,Height=WorkspaceRoot.ActualHeight};backdrop.MouseLeftButtonDown+=(_,_)=>CloseMenu();MenuLayer.Children.Add(backdrop);
   var panel=new StackPanel{Margin=new Thickness(6)};
   if(back!=null){var previous=new Button{Content="‹  Назад",Style=(Style)FindResource("QuietButton"),HorizontalContentAlignment=HorizontalAlignment.Left};previous.Click+=(_,_)=>back();panel.Children.Add(previous);}
   foreach(var item in list){var b=new Button{Content=Convert.ToString(item.Header)+(item.HasItems?"   ›":""),Style=(Style)FindResource("QuietButton"),HorizontalContentAlignment=HorizontalAlignment.Left,Padding=new Thickness(12,8,12,8),MinHeight=36,IsEnabled=item.IsEnabled};
    b.Click+=(_,_)=>{if(item.HasItems){ShowItems(item.Items.OfType<MenuItem>().ToList(),()=>ShowItems(list,back));return;}CloseMenu();item.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent,item));};panel.Children.Add(b);
   }
   double width=Math.Min(264,Math.Max(180,WorkspaceRoot.ActualWidth-16)),height=Math.Min(362,Math.Max(100,WorkspaceRoot.ActualHeight-24));
   var scroll=new ScrollViewer{Content=panel,MaxHeight=height,VerticalScrollBarVisibility=ScrollBarVisibility.Auto,HorizontalScrollBarVisibility=ScrollBarVisibility.Disabled};
   var box=new Border{Width=width,CornerRadius=new CornerRadius(16),Background=new SolidColorBrush(Color.FromRgb(29,29,29)),BorderBrush=new SolidColorBrush(Color.FromRgb(65,65,65)),BorderThickness=new Thickness(1),Child=scroll};
   MenuLayer.Children.Add(box);box.Measure(new Size(width,height));
   Point point;try{point=anchor.TranslatePoint(new Point(0,anchor.RenderSize.Height+6),WorkspaceRoot);}catch{point=new Point(WorkspaceRoot.ActualWidth-width-8,50);}
   Canvas.SetLeft(box,Math.Clamp(point.X,8,Math.Max(8,WorkspaceRoot.ActualWidth-width-8)));Canvas.SetTop(box,Math.Clamp(point.Y,8,Math.Max(8,WorkspaceRoot.ActualHeight-box.DesiredSize.Height-8)));box.Focus();
  }
  ShowItems(items);
 }

 void ResizeRail(){bool visible=account.Length>0&&!railHidden;LibraryRail.Visibility=visible?Visibility.Visible:Visibility.Collapsed;RailColumn.Width=new GridLength(visible?(ActualWidth<960?250:300):0);}
 void OpenRail(string section){railHidden=false;railSection=section;railPlaylist="";railRequest++;RefreshLibraryRail();}
 void CloseRailClick(object sender,RoutedEventArgs e){railHidden=true;ResizeRail();}
 void RailLikesClick(object sender,RoutedEventArgs e)=>OpenRail("Избранное");
 void RailPlaylistsClick(object sender,RoutedEventArgs e)=>OpenRail("Плейлисты");
 async void RailSortClick(object sender,RoutedEventArgs e)=>await SortFavorites();
 async void ContinuePhoneClick(object sender,RoutedEventArgs e){if(account.Length==0){Login();return;}ContinuePhoneButton.IsEnabled=false;try{await Guard(ContinueHere);}finally{ContinuePhoneButton.IsEnabled=true;}}
 void RefreshLibraryRail(){
  ResizeRail();ContinuePhoneButton.Visibility=account.Length>0?Visibility.Visible:Visibility.Collapsed;
  RailSort.Visibility=railSection=="Избранное"?Visibility.Visible:Visibility.Collapsed;RailBack.Visibility=railPlaylist.Length>0?Visibility.Visible:Visibility.Collapsed;
  if(railSection=="Избранное"){
   var rank=likeOrder.Select((id,i)=>(id,i)).ToDictionary(t=>t.id,t=>t.i);
   railTracks=catalog.Where(t=>likes.Contains(t.id)).OrderBy(t=>rank.GetValueOrDefault(t.id,int.MaxValue)).ToList();
   if(premiumSortAllowed&&favoriteOrder=="title")railTracks=railTracks.OrderBy(t=>t.title,StringComparer.CurrentCultureIgnoreCase).ToList();
   if(premiumSortAllowed&&favoriteOrder=="artist")railTracks=railTracks.OrderBy(t=>t.artist,StringComparer.CurrentCultureIgnoreCase).ToList();
  }
  RailList.ItemsSource=railSection=="Плейлисты"&&railPlaylist.Length==0?playlists.Select(p=>new LibraryEntry(p.name,"Плейлист",null,p.id)).ToList():railTracks.Select(t=>new LibraryEntry(t.title,t.artist,t)).ToList();
  RailEmpty.Visibility=RailList.Items.Count==0?Visibility.Visible:Visibility.Collapsed;
 }
 async void RailSelectionChanged(object sender,SelectionChangedEventArgs e){
  if(RailList.SelectedItem is not LibraryEntry {PlaylistID.Length:>0} entry)return;
  int ticket=++railRequest;RailEmpty.Text="Загружаем треки";RailEmpty.Visibility=Visibility.Visible;
  await Guard(async()=>{var data=ParseTracks(await api.Request("api/playlists/"+Uri.EscapeDataString(entry.PlaylistID)+"/tracks"));if(ticket!=railRequest)return;railPlaylist=entry.PlaylistID;railTitle=entry.Title;railTracks=data;RefreshLibraryRail();});
  if(ticket==railRequest){RailEmpty.Text="В плейлисте пока нет треков";RailEmpty.Visibility=RailList.Items.Count==0?Visibility.Visible:Visibility.Collapsed;}
 }
 async void RailDoubleClick(object sender,MouseButtonEventArgs e){if(RailList.SelectedItem is LibraryEntry {Track:not null} entry){if(roomCode.Length>0){await Guard(()=>RoomCommand("track",entry.Track.id));return;}queue=railTracks.ToList();index=queue.FindIndex(t=>t.id==entry.Track.id);wave=false;unshuffled=null;TakePlaybackHere();PrepareQueueOrder();PlayCurrent();}}
 void RailActionsClick(object sender,RoutedEventArgs e){
  var menu=new ContextMenu();void Add(string title,Func<Task> action){var item=new MenuItem{Header=title};item.Click+=async(_,_)=>await Guard(action);menu.Items.Add(item);}
  if(railSection=="Плейлисты"&&railPlaylist.Length==0){Add("Создать плейлист",()=>{Prompt("Новый плейлист","Название",async name=>{await api.Request("api/playlists","POST",new{name});await LoadAccount();});return Task.CompletedTask;});}
  else{
   var tracks=railTracks.ToList();var id=railPlaylist;var kind=railSection=="Избранное"?"likes":"playlist";
   Add("Воспроизвести",()=>{if(tracks.Count>0){queue=tracks;index=0;wave=false;unshuffled=null;PrepareQueueOrder();PlayCurrent();}return Task.CompletedTask;});
   Add("Скачать всё",()=>Download(tracks));Add("Поделиться ссылкой",()=>ShareCollection(kind,id));
   if(id.Length>0)Add("Опубликовать в поиске",async()=>{await api.Request("api/community-playlists/publish","POST",new{playlist_id=id});Status.Text="Плейлист опубликован";});
  }OpenMenu(menu,RailActions);
 }
 async Task ShareCollection(string kind,string id){var result=await api.Request("api/shares","POST",new{kind,playlist_id=id});var path=result.GetProperty("path").GetString();if(!Uri.TryCreate(api.Origin,path,out var uri)||uri.Authority!=api.Origin.Authority||uri.Scheme!=api.Origin.Scheme)throw new IOException("Сервер вернул неверную ссылку");Clipboard.SetText(uri.AbsoluteUri);Status.Text="Ссылка на подборку скопирована";}

 async Task LoadProfile(){string owner=account;profileName=profileAvatar="";if(account.Length>0)try{var p=await api.Request("api/profile");if(account!=owner)return;profileName=p.GetProperty("nickname").GetString()??"";profileAvatar=p.GetProperty("avatar_url").GetString()??"";}catch{}RefreshProfileButton();}
 void RefreshProfileButton(){AvatarImage.Source=null;AvatarInitial.Text=account.Length==0?"♙":profileName.Length>0?System.Globalization.StringInfo.GetNextTextElement(profileName).ToUpperInvariant():"N";NavigationMenu.ToolTip=profileName.Length>0?profileName:"Меню";if(profileAvatar.Length>0)Thumbnail.SetTrack(AvatarImage,new Track{id="profile:"+account,cover_url=profileAvatar});else Thumbnail.SetTrack(AvatarImage,null);}
 void AddProfileSettings(StackPanel panel){
  if(account.Length==0)return;
  string owner=account;var profile=new StackPanel();profile.Children.Add(Label("Профиль"));var name=new TextBox{Text=profileName,MaxLength=40,Tag="Никнейм"};profile.Children.Add(name);
  var note=Label("");profile.Children.Add(note);
  var save=new Button{Content="Сохранить ник"};save.Click+=async(_,_)=>{save.IsEnabled=false;try{var result=await api.Request("api/profile","PUT",new{nickname=name.Text.Trim()});if(account!=owner)return;profileName=result.GetProperty("nickname").GetString()??"";RefreshProfileButton();note.Text="Ник сохранён";}catch(Exception ex){note.Text=ex.Message;}finally{save.IsEnabled=true;}};profile.Children.Add(save);
  var upload=new Button{Content="Выбрать аватарку"};upload.Click+=async(_,_)=>{
   var picker=new OpenFileDialog{Filter="Изображение|*.jpg;*.jpeg;*.png;*.webp;*.bmp"};if(picker.ShowDialog(this)!=true)return;upload.IsEnabled=false;
   try{var data=await Task.Run(()=>{if(new FileInfo(picker.FileName).Length>12*1024*1024)throw new IOException("Выбери изображение до 12 МБ");using var input=File.OpenRead(picker.FileName);var bitmap=new BitmapImage();bitmap.BeginInit();bitmap.CacheOption=BitmapCacheOption.OnLoad;bitmap.DecodePixelWidth=512;bitmap.StreamSource=input;bitmap.EndInit();bitmap.Freeze();var encoder=new JpegBitmapEncoder{QualityLevel=88};encoder.Frames.Add(BitmapFrame.Create(bitmap));using var output=new MemoryStream();encoder.Save(output);return Convert.ToBase64String(output.ToArray());});
    var p=await api.Request("api/profile/avatar","POST",new{image=data});if(account!=owner)return;profileAvatar=p.GetProperty("avatar_url").GetString()??"";RefreshProfileButton();note.Text="Аватарка обновлена";
   }catch(Exception ex){note.Text=ex.Message;}finally{upload.IsEnabled=true;}
  };profile.Children.Add(upload);
  var remove=new Button{Content="Удалить аватарку"};remove.Click+=async(_,_)=>{try{await api.Request("api/profile/avatar","DELETE");if(account!=owner)return;profileAvatar="";RefreshProfileButton();note.Text="Аватарка удалена";}catch(Exception ex){note.Text=ex.Message;}};profile.Children.Add(remove);panel.Children.Add(SettingsCard(profile));
 }
 async Task<ImageSource?> LoadThumbnail(Track track){
  if(IsDesignPreview)return PreviewCover();if(api==null)return null;
  string key=api.Origin+"|"+track.id+"|"+track.cover_url;
  if(thumbnails.TryGetValue(key,out var existing))return await existing;
  if(thumbnails.Count>256)thumbnails.Clear();var work=Fetch();thumbnails[key]=work;var result=await work;if(result==null)thumbnails.Remove(key);return result;
  async Task<ImageSource?> Fetch(){
   await thumbnailGate.WaitAsync(lifetime.Token);try{
    string path=string.IsNullOrWhiteSpace(track.cover_url)?"api/covers/"+Uri.EscapeDataString(track.id):track.cover_url;
    if(!Uri.TryCreate(api.Origin,path,out var uri)||uri.Scheme!="https")return null;
    using var response=await (uri.Authority==api.Origin.Authority?api.HTTP:artworkHTTP).GetAsync(uri,System.Net.Http.HttpCompletionOption.ResponseHeadersRead,lifetime.Token);
    if(!response.IsSuccessStatusCode||response.Content.Headers.ContentLength>5*1024*1024)return null;
    using var input=await response.Content.ReadAsStreamAsync(lifetime.Token);using var output=new MemoryStream();byte[] buffer=new byte[16384];int n;while((n=await input.ReadAsync(buffer,lifetime.Token))>0){if(output.Length+n>5*1024*1024)return null;output.Write(buffer,0,n);}var bytes=output.ToArray();
    return await Task.Run(()=>{var bitmap=new BitmapImage();bitmap.BeginInit();bitmap.CacheOption=BitmapCacheOption.OnLoad;bitmap.DecodePixelWidth=112;bitmap.StreamSource=new MemoryStream(bytes);bitmap.EndInit();bitmap.Freeze();return (ImageSource)bitmap;});
   }catch{return null;}finally{thumbnailGate.Release();}
  }
 }
 void AttachPlayerEvents(LibVLCSharp.Shared.MediaPlayer instance){instance.EndReached+=(_,_)=>Dispatcher.InvokeAsync(()=>{if(ReferenceEquals(player,instance))Advance();});instance.EncounteredError+=(_,_)=>Dispatcher.InvokeAsync(()=>{if(ReferenceEquals(player,instance))Status.Text="Не удалось воспроизвести трек";});}

 void PrepareQueueOrder(){
  if(queue.Count==0)return;var current=queue[index];unshuffled=queue.Where(t=>!t.Suggested).ToList();
  if(shuffleMode>0){queue=SmartQueue.Order(unshuffled,current.id,shuffleMode==2);index=0;}
 }
 async Task ChangeShuffle(){
  if(nextPreparing)return;int revision=++shuffleRevision;shuffleMode=(shuffleMode+1)%3;shuffle=shuffleMode>0;
  var current=Current;var original=unshuffled??queue.Where(t=>!t.Suggested).ToList();unshuffled=original;
  if(shuffleMode==0){queue=original.ToList();if(current!=null&&!queue.Any(t=>t.id==current.id))queue.Insert(0,current);index=current==null?0:Math.Max(0,queue.FindIndex(t=>t.id==current.id));}
  else{queue=SmartQueue.Order(original,current?.id,shuffleMode==2);if(current!=null&&!queue.Any(t=>t.id==current.id))queue.Insert(0,current);index=0;}
  UpdatePlaybackChrome();Status.Text=new[]{"Исходный порядок","Перемешивание без повторов","Умное перемешивание · подбираем дополнения"}[shuffleMode];
  if(shuffleMode!=2||account.Length==0||queue.Count<3)return;
  var expected=currentID;var owner=account;
  try{var response=await api.Request("api/recommendations?exclude="+Uri.EscapeDataString(string.Join(',',queue.Select(t=>t.id).Concat(mixRecent).TakeLast(200)))+WaveQuery);
   if(revision!=shuffleRevision||currentID!=expected||account!=owner||shuffleMode!=2)return;
   queue=SmartQueue.Enhance(queue,ParseTracks(response).Where(t=>!hiddenTracks.Contains(t.id)&&!mixRecent.Contains(t.id)).ToList());Status.Text="Умное перемешивание · ✦ рекомендации в очереди";
  }catch{if(revision==shuffleRevision)Status.Text="Умное перемешивание · треки разнесены по исполнителям. Рекомендации пока недоступны.";}
 }
}

public static class Thumbnail {
 public static Func<Track,Task<ImageSource?>>? Loader;
 public static readonly DependencyProperty TrackProperty=DependencyProperty.RegisterAttached("Track",typeof(Track),typeof(Thumbnail),new PropertyMetadata(null,Changed));
 public static Track? GetTrack(DependencyObject value)=>(Track?)value.GetValue(TrackProperty);
 public static void SetTrack(DependencyObject value,Track? track)=>value.SetValue(TrackProperty,track);
 static async void Changed(DependencyObject value,DependencyPropertyChangedEventArgs e){if(value is not Image image)return;image.Source=null;if(e.NewValue is not Track track||Loader==null)return;try{var bitmap=await Loader(track);if(ReferenceEquals(GetTrack(image),track))image.Source=bitmap;}catch{}}
}
