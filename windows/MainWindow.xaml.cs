using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using System.Text.Json;
using System.IO;
using System.Diagnostics;
using LibVLCSharp.Shared;
using Microsoft.Win32;

namespace Nightwell.Native;
public partial class MainWindow:Window {
 NativeAPI api=null!;StreamProxy proxy=null!;LibVLC vlc=null!;LibVLCSharp.Shared.MediaPlayer player=null!;
 readonly DispatcherTimer timer=new(){Interval=TimeSpan.FromMilliseconds(400)};
 int savePending;
 int normalization=0;
 double userVolume=1.0;
 long pausedAtMs;
 long stableDurationMs;
 // Keep the displayed scrubber pinned while LibVLC settles on pause.
 // Reset on explicit track changes and seeks, never on a stale timer tick.
 bool pauseVisualLocked;
 bool volumeSettingReady;
 CancellationTokenSource? searchCancellation;List<Track> catalog=[],shown=[],queue=[];List<Playlist> playlists=[];HashSet<string> likes=[];
 readonly Dictionary<string,List<Track>> ownedPlaylistCache=new();
  readonly HashSet<string> pendingLikeIDs=new(StringComparer.OrdinalIgnoreCase);
 readonly Dictionary<string,(string videoID,DateTime expires)> clipCache=new();
 readonly HashSet<string> clipRequests=new();
 string favoriteOrder="recent";bool premiumSortAllowed=false;
 string account="",screen="Главная",playlist="",currentID="";int index,repeat,shuffleMode;bool wave,refilling,downloading,scrubbing,shuffle,mixing;readonly Queue<string> mixRecent=new();double transition=.8;long lastPrevious;string previousID="";
 CancellationTokenSource? lyricsCancellation;JsonElement? currentLyrics;string lyricsID="";int renderedLyric=int.MinValue;long savedAt;double? pendingSeek;bool restorePaused;
 sealed record PlaybackState(string Origin,string Account,List<Track> Queue,string ID,double Position,int Repeat,bool Shuffle,bool Wave,int ShuffleMode=0);
 string ResumeFile=>Path.Combine(NativeAPI.Storage,"resume.json");
 PlaybackState? CapturePlayback()=>Current==null?null:new PlaybackState(origin,account,queue.ToList(),currentID,Math.Max(0,(pauseVisualLocked?pausedAtMs:audioTime)/1000.0),repeat,shuffle,wave,shuffleMode);
 void WritePlayback(PlaybackState state){try{
   var directory=Path.GetDirectoryName(ResumeFile)!;
   Directory.CreateDirectory(directory);
   string temp=ResumeFile+"."+Guid.NewGuid().ToString("N")+".tmp";
   try {File.WriteAllText(temp,JsonSerializer.Serialize(state));File.Move(temp,ResumeFile,true);}
   finally {if(File.Exists(temp))File.Delete(temp);}
 }catch{}}
 void SavePlayback(){var state=CapturePlayback();if(state!=null)WritePlayback(state);}
 void QueueSavePlayback(){
   if(System.Threading.Interlocked.CompareExchange(ref savePending,1,0)!=0)return;
   var state=CapturePlayback();
   if(state==null){System.Threading.Interlocked.Exchange(ref savePending,0);return;}
   _=Task.Run(()=>{try{WritePlayback(state);}finally{System.Threading.Interlocked.Exchange(ref savePending,0);}});
 }
 async Task RestorePlaybackAsync(){
  if(Current!=null)return;
  try {
    var restored=await Task.Run(()=>{
      if(!File.Exists(ResumeFile))return (state:(PlaybackState?)null,local:new Dictionary<string,Track>());
      var state=JsonSerializer.Deserialize<PlaybackState>(File.ReadAllText(ResumeFile));
      var local=ReadOffline().ToDictionary(t=>t.id);
      return (state,local);
    });
    var state=restored.state;
    if(state==null||state.Origin!=origin)return;
    queue=state.Queue.Where(t=>state.Account==account&&account.Length>0||restored.local.ContainsKey(t.id))
       .Select(t=>restored.local.GetValueOrDefault(t.id,t)).ToList();
    index=queue.FindIndex(t=>t.id==state.ID);if(index<0){queue=[];return;}
    repeat=state.Repeat;shuffle=state.Shuffle;shuffleMode=state.ShuffleMode>0?Math.Min(2,state.ShuffleMode):(shuffle?1:0);wave=state.Wave;
    pendingSeek=state.Position;restorePaused=true;PlayCurrent();
  }catch{}
}
 Track? Current=>queue.Count>0&&index>=0&&index<queue.Count?queue[index]:null;
 string origin="https://music.nightwell.fun/";
 public MainWindow(){InitializeComponent();IsEnabled=false;try{
 var prefs=JsonDocument.Parse(File.ReadAllText(Path.Combine(NativeAPI.Storage,"settings.json"))).RootElement;
 if(prefs.TryGetProperty("transition",out var tr))transition=tr.GetDouble();
 if(prefs.TryGetProperty("normalization",out var nl))normalization=Math.Clamp(nl.GetInt32(),0,100);
 if(prefs.TryGetProperty("volume",out var vu)&&vu.TryGetDouble(out var v))userVolume=Math.Clamp(v,0,1);
 if(prefs.TryGetProperty("depthQueue",out var dq))depthQueue=dq.GetBoolean();
 if(prefs.TryGetProperty("kineticLyrics",out var kl))kineticLyrics=kl.GetBoolean();
}catch{}
Loaded+=async(_,_)=>{try{if(IsDesignPreview){IsEnabled=true;await CaptureDesignPreviews();Close();return;}await Task.Run(()=>{api=new NativeAPI(origin);proxy=new StreamProxy(api);Core.Initialize();
var audioArgs=new List<string>{"--no-video","--no-xlib"};
if(normalization>0){
 // VLC's native PCM volume normalizer avoids a second decoder and works on HLS and files.
 audioArgs.Add("--audio-filter=normvol");
 audioArgs.Add("--norm-buff-size=20");
 audioArgs.Add("--norm-max-level="+(2.0-1.3*normalization/100.0).ToString(System.Globalization.CultureInfo.InvariantCulture));
}
vlc=new LibVLC(audioArgs.ToArray());player=new LibVLCSharp.Shared.MediaPlayer(vlc);
});IsEnabled=true;
VolumeSlider.Value=FullVolumeSlider.Value=userVolume*100;
MiniVolumeValue.Text=FullVolumeValue.Text=Math.Round(userVolume*100).ToString("0")+"%";
volumeSettingReady=true;
player.Volume=(int)Math.Round(userVolume*100);player.EndReached+=(_,_)=>Dispatcher.InvokeAsync(()=>Advance());player.EncounteredError+=(_,_)=>Dispatcher.InvokeAsync(()=>Status.Text="Не удалось воспроизвести трек. Проверь подключение и повтори попытку.");timer.Tick+=(_,_)=>Tick();timer.Start();StartLyricClock();
 Home.SizeChanged+=(_,_)=>{
  if(HomeKineticText!=null)
   HomeKineticText.FontSize=Home.ActualHeight<400?17:Home.ActualWidth>1000?28:24;
 };
 if(Environment.GetCommandLineArgs().Contains("--native-smoke")){
  await Task.Delay(1200);var bitmap=new RenderTargetBitmap((int)ActualWidth,(int)ActualHeight,96,96,PixelFormats.Pbgra32);bitmap.Render(this);var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bitmap));using(var file=File.Create("windows-native-smoke.png"))encoder.Save(file);Close();
 }else {await LoadAccount();await RestorePlaybackAsync();await InitializeMobileFeatures();}
}catch(Exception ex){Status.Text="Не удалось запустить плеер: "+ex.Message;if(IsDesignPreview||Environment.GetCommandLineArgs().Contains("--native-smoke")){File.WriteAllText("ui-preview-error.txt",ex.ToString());Environment.ExitCode=1;Close();}}};Closed+=(_,_)=>{if(!IsDesignPreview)QueueSavePlayback();timer.Stop();StopLyricClock();searchCancellation?.Cancel();lyricsCancellation?.Cancel();homeLyricsCancellation?.Cancel();lifetime.Cancel();_ = Task.Run(()=>{player?.Stop();player?.Dispose();vlc?.Dispose();proxy?.Dispose();api?.Dispose();});};}
 async Task Guard(Func<Task> action){try{await action();}catch(OperationCanceledException){}catch(Exception e){Status.Text=e.Message;}}
 List<Track> ParseTracks(JsonElement json)=>json.GetProperty("tracks").Deserialize<List<Track>>()??[];
 async Task LoadAccount(){
  await Guard(async()=>{
   var me=await api.Request("api/me");
   api.Csrf=me.GetProperty("csrf").GetString()??"";
   var previousAccount=account;
   account=me.GetProperty("user").ValueKind==JsonValueKind.Object
    ?me.GetProperty("user").GetProperty("id").GetString()??"":"";
   if(!string.Equals(previousAccount,account,StringComparison.Ordinal)){
    favoriteDetails.Clear();
    favoriteOrderIDs.Clear();
    favoriteLookupAttempts.Clear();
    likes.Clear();
   }
   if(account.Length==0){
    Status.Text="Войди в аккаунт или открой офлайн-файлы";
    return;
   }
   var owner=account;
   // Restore the authenticated user's last library before waiting for remote
   // catalogue, likes and playlists. Never reuse another account's snapshot.
   await RestoreLibraryCacheAsync(owner);
   _=LoadProfileAsync();
   int successful=0;
   async Task FetchTracks(){
    try{
     var result=await api.Request("api/tracks",cancellation:lifetime.Token);
     if(account!=owner||lifetime.IsCancellationRequested)return;
     catalog=ParseTracks(result);RememberFavoriteDetails(catalog);successful++;
     if(screen=="Избранное")Show("Избранное");
     else if(screen=="Поиск"&&SearchBox.Text.Trim().Length>=2){
      var query=SearchBox.Text.Trim();
      shown=RankSearchResults(catalog.Concat(ownedPlaylistCache.Values.SelectMany(x=>x)),query);
      Tracks.ItemsSource=shown;
     }
    }catch(OperationCanceledException){}catch(Exception e){if(account==owner)Status.Text="Каталог: "+e.Message;}
   }
   async Task Likes(){
    try{
     var result=await api.Request("api/likes",cancellation:lifetime.Token);
     if(account!=owner||lifetime.IsCancellationRequested)return;
     var ids=result.GetProperty("ids").Deserialize<List<string>>()??[];
     likes=ids.ToHashSet(StringComparer.OrdinalIgnoreCase);
     favoriteOrderIDs.Clear();favoriteOrderIDs.AddRange(ids.AsEnumerable().Reverse());
     foreach(var key in new[]{"tracks","items","favorites"}){
      if(result.TryGetProperty(key,out var value)&&value.ValueKind==JsonValueKind.Array)
       try{RememberFavoriteDetails(value.Deserialize<List<Track>>()??[]);}catch(JsonException){}
     }
     successful++;
     if(screen=="Избранное")Show("Избранное");
    }catch(OperationCanceledException){}catch(Exception e){if(account==owner)Status.Text="Избранное: "+e.Message;}
   }
   async Task Playlists(){
    try{
     var result=await api.Request("api/playlists",cancellation:lifetime.Token);
     if(account!=owner||lifetime.IsCancellationRequested)return;
     playlists=result.GetProperty("playlists").Deserialize<List<Playlist>>()??[];
     successful++;
     SidebarPlaylists.ItemsSource=playlists.ToList();
     _=WarmOwnedPlaylistsAsync(owner);
    }catch(OperationCanceledException){}catch(Exception e){if(account==owner)Status.Text="Плейлисты: "+e.Message;}
   }
   // Do not hold startup and playback restoration behind slow library APIs.
   // Start all sections after the authenticated cache is shown, then publish
   // each independently. The refresh owns its errors and account checks.
   async Task RefreshSections(){
    await Task.WhenAll(FetchTracks(),Likes(),Playlists());
    if(account!=owner||lifetime.IsCancellationRequested)return;
    if(successful>0){Status.Text="";SaveLibraryCacheAsync(owner);}
   }
   _=RefreshSections();
  });
 }
 void Show(string next){
  searchCancellation?.Cancel();
  screen=next;
  playlist="";
  if(next=="Главная"){
   librarySidebarOpen=false;
   LibrarySideColumn.Width=new GridLength(0);
   LibrarySidebar.Visibility=Visibility.Collapsed;
   SidebarToggle.Content="Медиатека";
   Library.Visibility=SidebarPlaylists.Visibility=Visibility.Collapsed;
   PlayerPage.Visibility=Visibility.Collapsed;
   Home.Visibility=Dock.Visibility=Ribbon.Visibility=Visibility.Visible;
   Ribbon.Focused=false;
   return;
  }
  librarySidebarOpen=true;
  LibrarySideColumn.Width=new GridLength(344);
  LibrarySidebar.Visibility=Visibility.Visible;
  SidebarToggle.Content="Скрыть медиатеку";
  if(PlayerPage.Visibility!=Visibility.Visible){
   Home.Visibility=Dock.Visibility=Visibility.Visible;
   Ribbon.Focused=false;
  }
  Ribbon.Visibility=Visibility.Visible;
  Heading.Text=next;
  Library.Visibility=next=="Плейлисты"?Visibility.Collapsed:Visibility.Visible;
  SidebarPlaylists.Visibility=next=="Плейлисты"?Visibility.Visible:Visibility.Collapsed;
  LibraryEyebrow.Text=next=="Поиск"?"НАХОДИ НОВОЕ":"ТВОЯ МУЗЫКА";
  EmptyStateTitle.Text=next=="Поиск"?"Найди свою музыку":next=="Офлайн"?"Музыка всегда с тобой":"Твоя музыка будет здесь";
  EmptyStateBody.Text=next=="Поиск"?"Введи название трека или имя исполнителя":next=="Офлайн"?"Скачай треки или добавь файлы с компьютера":"Добавляй любимые треки и возвращайся к ним";
  SearchOptions.Visibility=SearchBox.Visibility=next=="Поиск"?Visibility.Visible:Visibility.Collapsed;
  CollectionActions.Visibility=next=="Поиск"?Visibility.Collapsed:Visibility.Visible;
  if(next=="Поиск"){SearchBox.Focus();shown=[];}else if(next=="Избранное"){shown=VisibleFavoriteTracks();}else if(next=="Офлайн"){shown=[];_=LoadOfflineTracksAsync();}else if(next=="Плейлисты"){shown=[];}
  Tracks.ItemsSource=shown;
 }
 async Task LoadOfflineTracksAsync(){try{
  var local=await Task.Run(ReadOffline);
  if(screen!="Офлайн")return;
  shown=local;Tracks.ItemsSource=local;
 }catch(Exception ex){if(screen=="Офлайн")Status.Text="Не удалось открыть офлайн-файлы: "+ex.Message;}}
 void SearchClick(object sender,RoutedEventArgs e)=>Show("Поиск");
 async void ContinueOnDesktopClick(object sender,RoutedEventArgs e)=>await Guard(ContinueHere);
 async void SearchChanged(object sender,TextChangedEventArgs e){
  if(screen!="Поиск")return;
  searchCancellation?.Cancel();
  searchCancellation=new CancellationTokenSource();
  var cancellation=searchCancellation.Token;
  var query=SearchBox.Text.Trim();
  if(query.Length<2){shown=[];Tracks.ItemsSource=shown;return;}
  // Render known local tracks immediately. Debounce only the remote request,
  // not the first visual search result.
  try{
   shown=RankSearchResults(catalog.Concat(ownedPlaylistCache.Values.SelectMany(x=>x)),query);
   Tracks.ItemsSource=shown;
   await Task.Delay(180,cancellation);
   cancellation.ThrowIfCancellationRequested();
   Status.Text="Ищем полные версии…";
   for(int attempt=0;attempt<12;attempt++){
    var result=await api.Request("api/tracks?q="+Uri.EscapeDataString(query),cancellation:cancellation);
    cancellation.ThrowIfCancellationRequested();
    var fresh=ParseTracks(result);
    RememberFavoriteDetails(fresh);
    shown=RankSearchResults(catalog.Concat(ownedPlaylistCache.Values.SelectMany(x=>x))
      .Concat(fresh),query);
    Tracks.ItemsSource=shown;
    Status.Text=result.TryGetProperty("search_message",out var message)?message.GetString():"";
    if(!result.TryGetProperty("search_pending",out var pending)||!pending.GetBoolean())break;
    await Task.Delay(1500,cancellation);
   }
  }catch(OperationCanceledException){}catch(Exception ex){
    if(!cancellation.IsCancellationRequested)Status.Text=ex.Message;
  }
 }

 async Task SortFavorites(){
  await Guard(async()=>{
   var status=await api.Request("api/premium/me");
   premiumSortAllowed=status.TryGetProperty("premium",out var premium)&&premium.GetBoolean();
   if(!premiumSortAllowed){Status.Text="Сортировка доступна с Nightwell Premium";return;}
   var menu=new ContextMenu();
   foreach(var option in new[]{("Недавние","recent"),("По названию","title"),("По исполнителю","artist")}){
    var item=new MenuItem{Header=option.Item1};string selected=option.Item2;
    item.Click+=(_,_)=>{favoriteOrder=selected;Show("Избранное");};
    menu.Items.Add(item);
   }
   menu.PlacementTarget=this;menu.IsOpen=true;
  });
 }
 void NativeTransfer(){
  var panel=new StackPanel();
  var window=Sheet("Перенести музыку",panel,720,false);
  panel.Children.Add(Label("Перенести музыку"));
  panel.Children.Add(new TextBlock{Text="Поиск и нейросетевое сопоставление работают на ПК. Сервер выполняет только поиск треков и обычное сохранение плейлиста.",Foreground=Brushes.White,TextWrapping=TextWrapping.Wrap,Margin=new Thickness(0,0,0,9)});
  var name=new TextBox{Text="Перенос музыки",Padding=new Thickness(10)};panel.Children.Add(name);
  panel.Children.Add(Label("Режим поиска"));
  var mode=new ComboBox{ItemsSource=new[]{"Точный","Умный","Максимальный"},SelectedIndex=1};panel.Children.Add(mode);
  var choose=new Button{Content="Открыть JSON, CSV или TXT",Margin=new Thickness(0,12,0,8),Padding=new Thickness(8)};
  var input=new TextBox{AcceptsReturn=true,VerticalContentAlignment=VerticalAlignment.Top,TextWrapping=TextWrapping.Wrap,VerticalScrollBarVisibility=ScrollBarVisibility.Auto,Height=145};
  choose.Click+=(_,_)=>{
   var picker=new OpenFileDialog{Filter="Плейлисты|*.json;*.csv;*.txt|Все файлы|*.*"};
   if(picker.ShowDialog(this)==true){
    var bytes=File.ReadAllBytes(picker.FileName);
    if(bytes.Length>1024*1024){MessageBox.Show(this,"Максимальный размер файла 1 МБ");return;}
    input.Text=System.Text.Encoding.UTF8.GetString(bytes);
   }
  };
  panel.Children.Add(choose);panel.Children.Add(input);
  var progress=new TextBlock{Foreground=Brushes.White,Margin=new Thickness(0,14,0,12),TextWrapping=TextWrapping.Wrap};panel.Children.Add(progress);
  var start=new Button{Content="Найти треки на устройстве",Padding=new Thickness(12)};panel.Children.Add(start);
  var missingButton=new Button{Content="Показать ненайденные",Visibility=Visibility.Collapsed,Padding=new Thickness(10),Margin=new Thickness(0,8,0,0)};
  panel.Children.Add(missingButton);
  var cancel=new Button{Content="Остановить перенос",Visibility=Visibility.Collapsed,Padding=new Thickness(10),Margin=new Thickness(0,8,0,0)};
  panel.Children.Add(cancel);
  List<LocalNeuralTransferMatcher.Result>? matches=null;
  var saved=new HashSet<string>();string createdPlaylist="";
  CancellationTokenSource? cancelWork=null;
  missingButton.Click+=(_,_)=>{
   if(matches==null)return;
   var text=string.Join(Environment.NewLine,matches.Where(x=>x.Found==null).Select(x=>x.Original.Artist+" — "+x.Original.Title+" ("+x.Reason+")"));
   if(text.Length==0)return;
   Clipboard.SetText(text);
   MessageBox.Show(this,"Список ненайденных треков скопирован в буфер обмена.","Nightwell Music");
  };
  cancel.Click+=(_,_)=>cancelWork?.Cancel();
  window.Closed+=(_,_)=>cancelWork?.Cancel();
  start.Click+=async(_,_)=>{
   start.IsEnabled=false;
   cancelWork?.Dispose();cancelWork=new CancellationTokenSource();
   var token=cancelWork.Token;
   cancel.Visibility=Visibility.Visible;
   try {
    if(matches==null) {
     string title=name.Text.Trim(),raw=input.Text;
     if(title.Length==0||raw.Trim().Length==0)throw new InvalidDataException("Укажи название плейлиста и список треков.");
     var selected=new[]{"safe","balanced","wide"}[mode.SelectedIndex<0?1:mode.SelectedIndex];
     progress.Text="Разбираем список и обучаем локальную нейросеть…";
     var rows=await Task.Run(()=>LocalTransferInput.Parse(raw),token);
     var indexed=catalog.ToList();
     if(indexed.Count==0) {
      var response=await api.Request("api/tracks",cancellation:token);
      indexed=ParseTracks(response);
     }
     if(indexed.Count==0)throw new InvalidDataException("Каталог пуст. Проверь подключение.");
     var matcher=await Task.Run(()=>new LocalNeuralTransferMatcher(indexed),token);
     progress.Text="Сопоставляем треки на твоём ПК…";
     var result=await Task.Run(()=>rows.Select(row=>matcher.Match(row,selected)).ToList(),token);
     token.ThrowIfCancellationRequested();
     int extraSearches=0;
     // Cloud catalogue entries not present in the initial snapshot are found
     // by plain /api/tracks?q= requests. The NN always ranks results locally.
     for(int i=0;i<result.Count;i++){
      token.ThrowIfCancellationRequested();
      if(!window.IsVisible)return;
      if(result[i].Found!=null)continue;
      var limit=selected=="wide"?300:selected=="balanced"?180:80;
      if(extraSearches>=limit)break;
      extraSearches++;
      try {
       var row=rows[i];
       var query=row.Artist+" "+row.Title;
       var response=await api.Request("api/tracks?q="+Uri.EscapeDataString(query),cancellation:token);
       var choices=ParseTracks(response);
       var updated=matcher.Match(row,selected,choices);
       if(updated.Found!=null)result[i]=updated;
      } catch(OperationCanceledException){throw;}catch {}
      if(i%4==0)progress.Text=$"Локальный ИИ: проверено {i+1}/{result.Count} · найдено {result.Count(x=>x.Found!=null)}";
     }
     matches=result;
     missingButton.Visibility=matches.Any(x=>x.Found==null)?Visibility.Visible:Visibility.Collapsed;
     progress.Text=$"Готово: найдено {matches.Count(x=>x.Found!=null)} из {matches.Count}. Ненайденные можно скопировать. Нажми «Добавить» для сохранения.";
     start.Content="Добавить найденные треки";
    } else {
     token.ThrowIfCancellationRequested();
     var found=matches.Where(x=>x.Found!=null).Select(x=>x.Found!).DistinctBy(t=>t.id).ToList();
     if(found.Count==0)throw new InvalidDataException("Подходящих треков нет.");
     if(createdPlaylist.Length==0) {
      var playlist=await api.Request("api/playlists","POST",new{name=name.Text.Trim()},token);
      if(!playlist.TryGetProperty("id",out var id))throw new InvalidDataException("Сервер не вернул ID плейлиста.");
      createdPlaylist=id.GetString()??"";
     }
     if(createdPlaylist.Length==0)throw new InvalidDataException("Не удалось создать плейлист.");
     int failed=0;
     foreach(var track in found){
      token.ThrowIfCancellationRequested();
      if(!window.IsVisible)return;
      if(saved.Contains(track.id))continue;
      try {
       await api.Request("api/playlists/"+Uri.EscapeDataString(createdPlaylist)+"/tracks/"+Uri.EscapeDataString(track.id),"POST",new{},token);
       saved.Add(track.id);
      }catch(OperationCanceledException){throw;}catch {failed++;}
      if((saved.Count+failed)%5==0)progress.Text=$"Сохраняем с этого ПК: {saved.Count}/{found.Count} · ошибок {failed}";
     }
     progress.Text=$"Плейлист создан: {saved.Count} треков. Не найдено: {matches.Count(x=>x.Found==null)}. Ошибок сохранения: {failed}.";
     if(saved.Count==found.Count){
      start.Content="Перенос завершён";start.IsEnabled=false;
      _=LoadAccount();
     }else{start.Content="Повторить сохранение";start.IsEnabled=true;}
    }
   }catch(OperationCanceledException){progress.Text="Перенос остановлен. Уже сохранённые треки останутся в плейлисте.";start.IsEnabled=true;}
   catch(Exception ex){progress.Text="Ошибка: "+ex.Message;start.IsEnabled=true;}
   finally{cancel.Visibility=Visibility.Collapsed;}
  };
  window.Show();
 }

 void MenuClick(object sender,RoutedEventArgs e){
  var menu=new ContextMenu{
   MaxHeight=Math.Min(390,SystemParameters.WorkArea.Height-120),
   MaxWidth=260,
   MinWidth=205,
   PlacementTarget=(UIElement)sender,
   Placement=System.Windows.Controls.Primitives.PlacementMode.Bottom,
   StaysOpen=false
  };
  string[] entries=account.Length==0
   ?new[]{"Войти","Главная","Настройки"}
   :new[]{"Главная","Избранное","Плейлисты","Офлайн","Подборки дня",
      "Плейлисты в поиске","Слушать вместе","Настройки","Выйти"};
  foreach(var label in entries){
   var name=label;
   var item=new MenuItem{Header=name,Padding=new Thickness(12,9,12,9)};
   item.Click+=async(_,_)=>{
    if(name=="Подборки дня")await BrowsePlaylists(true);
    else if(name=="Плейлисты в поиске")await BrowsePlaylists(false);
    else if(name=="Слушать вместе")TogetherWindow();
    else if(name=="Настройки")Settings();
    else if(name=="Войти")Login();
    else if(name=="Выйти")await Guard(async()=>{
     await api.Request("api/logout","POST");api.Clear();
     await AudioCommand(()=>player.Stop());roomCode="";roomCancellation?.Cancel();
     queue=[];catalog=[];likes=[];playlists=[];account="";
     NavigationAvatar.Source=null;profileNickname="";Show("Главная");
    });
    else Show(name);
   };
   menu.Items.Add(item);
  }
  menu.IsOpen=true;
 }
 async void WaveClick(object sender,RoutedEventArgs e)=>await NewWave();
 async Task NewWave(){if(mixing)return;if(account.Length==0){Login();return;}seededWaveArtists.Clear();mixing=true;Status.Text="Подбираем…";try{await Guard(async()=>{var exclude=mixRecent.Concat(queue.Take(8).Select(t=>t.id)).Append(currentID).Where(id=>id.Length>0).Distinct().TakeLast(200);string nonce=Guid.NewGuid().ToString("N");var result=await api.Request(WaveRoute+"?mix="+nonce+WaveQuery+"&exclude="+Uri.EscapeDataString(string.Join(',',exclude)));var next=ParseTracks(result).Where(t=>t.id!=currentID&&!hiddenTracks.Contains(t.id)).ToList();if(next.Count==0&&currentID.Length>0)next=ParseTracks(await api.Request(WaveRoute+"?mix="+nonce+WaveQuery+"&exclude="+currentID)).Where(t=>t.id!=currentID).ToList();if(next.Count==0){Status.Text="Новых треков пока нет. Попробуй чуть позже.";return;}queue=next;index=0;wave=true;TakePlaybackHere();PlayCurrent();Status.Text="";});}finally{mixing=false;}}

 void VolumeChanged(object sender,RoutedPropertyChangedEventArgs<double> e){
    if(!volumeSettingReady || player==null || sender is not Slider slider)return;
    userVolume=Math.Clamp(slider.Value/100.0,0,1);
    if(!ReferenceEquals(slider,VolumeSlider))VolumeSlider.Value=userVolume*100;
    if(!ReferenceEquals(slider,FullVolumeSlider))FullVolumeSlider.Value=userVolume*100;
    MiniVolumeValue.Text=FullVolumeValue.Text=Math.Round(userVolume*100).ToString("0")+"%";
    _=AudioCommand(ApplyVolume);
    SaveSettings();
 }
 void ApplyVolume(){
    if(player==null)return;
    double gain=1;
    if(transition>0 && player.IsPlaying){
      double seconds=Math.Max(0,player.Time/1000.0);
      double duration=Math.Max(0,player.Length/1000.0);
      double span=duration>0.2?Math.Min(transition,duration/4):transition;
      if(span>0){
        gain=Math.Clamp(seconds/span,0,1);
        if(duration>0.2&&(index+1<queue.Count||wave||repeat>0))
          gain=Math.Min(gain,Math.Clamp((duration-seconds)/span,0,1));
      }
    }
    var volume=(int)Math.Round(100*Math.Clamp(userVolume*gain,0,1));
    if(player.Volume!=volume)player.Volume=volume;
 }
 async void ToggleClick(object sender,RoutedEventArgs e){
  if(Current==null){await NewWave();return;}
  if(roomCode.Length>0){await Guard(()=>RoomCommand(audioPlaying?"pause":"play"));return;}
  TakePlaybackHere();
  bool pausing=player.IsPlaying;
  if(pausing){
   pausedAtMs=Math.Max(pausedAtMs,Math.Max(0,audioTime));
   pauseVisualLocked=true;
  }else pauseVisualLocked=false;
  await AudioCommand(()=>{
   if(pausing){
    pausedAtMs=Math.Max(pausedAtMs,Math.Max(0,player.Time));
    player.Pause();
   }else player.Play();
  });
  if(pausing){
   audioTime=pausedAtMs;
   audioPlaying=false;
  }
  RefreshPlaybackUI();
 }
 async void TrackRowClick(object sender,MouseButtonEventArgs e){
  if(e.ChangedButton!=MouseButton.Left)return;
  // Preview catches clicks on artwork, artist, text and blank space, but
  // never turns an ellipsis/menu/scrollbar action into playback.
  DependencyObject? node=e.OriginalSource as DependencyObject;
  ListBoxItem? item=null;
  for(int depth=0;node!=null&&depth<32;depth++){
   if(node is System.Windows.Controls.Primitives.ButtonBase ||
      node is System.Windows.Controls.Primitives.ScrollBar ||
      node is System.Windows.Controls.Primitives.Thumb)return;
   if(node is ListBoxItem row){item=row;break;}
   node=node is Visual || node is System.Windows.Media.Media3D.Visual3D
      ?VisualTreeHelper.GetParent(node):LogicalTreeHelper.GetParent(node);
  }
  if(item?.DataContext is not Track t)return;
  Tracks.SelectedItem=t;
  if(roomCode.Length>0){await Guard(()=>RoomCommand("track",t.id));return;}
  TakePlaybackHere();
  queue=shown.ToList();index=queue.FindIndex(v=>v.id==t.id);
  if(index<0)return;
  wave=false;PlayCurrent();
 }
 void PlayCurrent(){nextCancellation?.Cancel();var t=Current;if(t==null)return;RememberFavoriteDetails([t]);_=PrefetchClipAsync(t);pausedAtMs=0;stableDurationMs=0;pauseVisualLocked=false;if(t.LocalPath==null&&account.Length==0){Login();return;}string path=StreamPath(t);_=AudioCommand(()=>{using var media=new Media(vlc,path,t.LocalPath==null?FromType.FromLocation:FromType.FromPath);player.Play(media);});lyricsCancellation?.Cancel();currentLyrics=null;lyricsID="";renderedLyric=int.MinValue;currentID=t.id;ActiveArtwork=null;Ribbon.ResetPalette();PlayerPage.Background=Brushes.Transparent;PlayingTrackId=t.id;UpdatePlaybackChrome();mixRecent.Enqueue(t.id);while(mixRecent.Count>120)mixRecent.Dequeue();MiniTitle.Text=FullTitle.Text=t.title;MiniArtist.Text=FullArtist.Text=t.artist;ResetHomeLyrics(t);LyricsText.Text="";LyricsPanel.Visibility=Visibility.Collapsed;Cover.Visibility=Visibility.Visible;if(Uri.TryCreate(api.Origin,t.cover_url??("api/covers/"+t.id),out var coverURI)&&coverURI.Scheme=="https")_=LoadCover(coverURI,t.id);else Cover.Source=MiniCover.Source=null;RecordTrackStart();_=Prefetch();Dock.BeginAnimation(OpacityProperty,new System.Windows.Media.Animation.DoubleAnimation(.6,1,TimeSpan.FromSeconds(.7)));}
 async Task LoadCover(Uri uri,string id){try{
 var bytes=await (uri.Authority==api.Origin.Authority?api.HTTP:artworkHTTP).GetByteArrayAsync(uri,lifetime.Token);
 if(bytes.Length>5*1024*1024||currentID!=id)return;
 var image=await Task.Run(()=>{
  var bitmap=new BitmapImage();
  bitmap.BeginInit();bitmap.CacheOption=BitmapCacheOption.OnLoad;
  bitmap.DecodePixelWidth=650;bitmap.StreamSource=new MemoryStream(bytes);
  bitmap.EndInit();bitmap.Freeze();return bitmap;
 });
 if(currentID==id){Cover.Source=MiniCover.Source=ActiveArtwork=image;var colors=await Task.Run(()=>ArtworkPalette(image));if(currentID==id)UpdateCoverBackdrop(colors.Item1,colors.Item2);}
}catch{}}
 async void NextClick(object sender,RoutedEventArgs e){if(nextRequestBusy)return;nextRequestBusy=true;try{await Guard(SafeNext);}finally{nextRequestBusy=false;}}
 async void PreviousClick(object sender,RoutedEventArgs e){if(roomCode.Length>0){await Guard(()=>RoomCommand("previous"));return;}if(Current==null)return;long now=Environment.TickCount64;if(audioTime>3000&&!(previousID==currentID&&now-lastPrevious<3000)){lastPrevious=now;previousID=currentID;_=AudioCommand(()=>player.Time=0);return;}previousID="";index=(index-1+queue.Count)%queue.Count;PlayCurrent();}
 void Advance(){if(nextPreparing||queue.Count==0)return;if(repeat==2){PlayCurrent();return;}if(wave&&index+1>=queue.Count){_=Refill(force:true);return;}if(shuffle&&queue.Count>1)index=ChooseShuffleIndex();else if(index+1<queue.Count)index++;else if(repeat==1)index=0;else return;PlayCurrent();}
 DateTime waveRefillAttempt=DateTime.MinValue;
 async Task Refill(bool force=false){
  if(refilling||!wave||account.Length==0)return;
  // Always throttle background polling; explicit Next and EndReached can
  // request a fresh batch immediately without opening a request loop.
  bool exhausted=index+1>=queue.Count;
  if(!force&&DateTime.UtcNow-waveRefillAttempt<TimeSpan.FromSeconds(20))return;
  waveRefillAttempt=DateTime.UtcNow;
  refilling=true;
  try{
   await Guard(async()=>{
    var exclude=string.Join(',',queue.TakeLast(150).Select(t=>t.id));
    var route=seededWaveArtists.Count>0?"api/wave":WaveRoute;
    var filter=WaveQuery.TrimStart('&')+"&exclude="+Uri.EscapeDataString(exclude)+
     (seededWaveArtists.Count>0?"&artists="+Uri.EscapeDataString(string.Join(",",seededWaveArtists)):"");
    var value=await api.Request(route+"?"+filter);
    if(!wave)return;
    var ids=queue.Select(t=>t.id).ToHashSet();
    var fresh=ParseTracks(value).Where(t=>ids.Add(t.id)).ToList();
    if(fresh.Count==0)return;
    queue.AddRange(fresh);
    QueueSavePlayback();
    // A silent player at an exhausted queue can resume from the next item.
    if(!audioPlaying&&!pauseVisualLocked&&!nextPreparing&&exhausted&&index+1<queue.Count){
     index++;PlayCurrent();
    }
   });
  }finally{refilling=false;}
 }
 async void Tick(){
  if(Current==null||sampleBusy)return; sampleBusy=true;
  try {var sample=await Task.Run(()=>(player.IsPlaying,player.Time,player.Length),lifetime.Token);audioPlaying=sample.IsPlaying;audioTime=sample.Time;audioLength=sample.Length;RefreshPlaybackUI();}catch(OperationCanceledException){}catch{}finally{sampleBusy=false;}
 }
 void RefreshPlaybackUI(){
  if(Environment.TickCount64-savedAt>15000){savedAt=Environment.TickCount64;QueueSavePlayback();}
  if(pendingSeek.HasValue&&audioLength>0){
    var target=(long)(Math.Clamp(pendingSeek.Value,0,Math.Max(0,audioLength/1000.0-.2))*1000);
    _=AudioCommand(()=>player.Time=target);pausedAtMs=target;pendingSeek=null;
    if(restorePaused){restorePaused=false;_=AudioCommand(()=>{player.SetPause(true);player.Mute=false;});}
  }
  bool playing=audioPlaying;
  if(audioLength>1000)stableDurationMs=audioLength;
  long displayDurationMs=audioLength>1000?audioLength:Math.Max(1,stableDurationMs);
  long positionMs=Math.Max(0,audioTime);
  if(playing&&!pauseVisualLocked&&positionMs>0)pausedAtMs=positionMs;
  // Freeze even when LibVLC reports a nonzero but older timestamp.
  if(pauseVisualLocked||(!playing&&pausedAtMs>0&&displayDurationMs>0))
   positionMs=Math.Max(0,pausedAtMs);
  double duration=Math.Max(1,displayDurationMs/1000.0),position=positionMs/1000.0;
  SyncLyrics();
  UpdateHomeLyrics();
  MiniLike.Content=likes.Contains(currentID)?"♥":"♡";
  MiniProgress.Width=Math.Max(0,Dock.ActualWidth-32)*Math.Clamp(positionMs/(double)Math.Max(1,displayDurationMs),0,1);
  MiniPlay.Content=HomePlay.Content=FullPlay.Content=playing?"\uE769":"\uE768";
  UpdatePlaybackChrome();
  if(!scrubbing){FullSeek.Maximum=duration;FullSeek.Value=Math.Min(duration,position);}
  FullTime.Text=$"{Time(position)}    /    {Time(duration)}";
  // Volume callbacks already apply direct changes. Only poll the engine
  // during a timed fade: otherwise this was a redundant background job
  // on every 400ms playback tick.
  if(transition>0&&playing) _=AudioCommand(ApplyVolume);
  // Start replenishment before only a handful of tracks remain.
  if(wave&&queue.Count-index<18&&!refilling)_=Refill();
  UpdateListening();
  if(Environment.TickCount64-lastPrefetch>12000){lastPrefetch=Environment.TickCount64;_=Prefetch();}
 }
 string Time(double s)=>$"{(int)s/60}:{(int)s%60:00}";
 void SeekStart(object sender,MouseButtonEventArgs e)=>scrubbing=true;
 async void SeekEnd(object sender,MouseButtonEventArgs e){
  if(roomCode.Length>0){scrubbing=false;await Guard(()=>RoomCommand("seek",position:FullSeek.Value));return;}
  long target=Math.Max(0,(long)(FullSeek.Value*1000));
  // A deliberate backwards seek replaces the frozen pause anchor.
  pausedAtMs=target;
  audioTime=target;
  pauseVisualLocked=!player.IsPlaying;
  _=AudioCommand(()=>player.Time=target);
  scrubbing=false;
  RefreshPlaybackUI();
 }
 void ShuffleClick(object sender,RoutedEventArgs e){
  shuffleMode=(shuffleMode+1)%3;shuffle=shuffleMode!=0;
  Status.Text=new[]{"Перемешивание выключено","Обычное перемешивание","Умное перемешивание"}[shuffleMode];
  UpdatePlaybackChrome();QueueSavePlayback();
 }
 void RepeatClick(object sender,RoutedEventArgs e){repeat=(repeat+1)%3;Status.Text=new[]{"Повтор выключен","Повтор очереди","Повтор трека"}[repeat];UpdatePlaybackChrome();}
 void OpenPlayerClick(object sender,MouseButtonEventArgs e){if(Current==null)return;Home.Visibility=Dock.Visibility=Visibility.Collapsed;PlayerPage.Visibility=Visibility.Visible;Ribbon.Visibility=Visibility.Visible;Ribbon.Focused=true;}
 void ClosePlayerClick(object sender,RoutedEventArgs e)=>ReturnFromPlayer();
 void ReturnFromPlayer(){
  PlayerPage.Visibility=Visibility.Collapsed;
  Home.Visibility=Dock.Visibility=Visibility.Visible;
  Ribbon.Visibility=Visibility.Visible;
  Ribbon.Focused=false;
 }
 void CurrentMenuClick(object sender,RoutedEventArgs e){if(Current!=null)TrackMenu(Current,(UIElement)sender);}
 void TrackMenuClick(object sender,RoutedEventArgs e){if(sender is Button b&&b.Tag is Track t)TrackMenu(t,b);}
 void TrackMenu(Track t,UIElement owner){var menu=new ContextMenu();void Add(string label,Func<Task> run){var item=new MenuItem{Header=label};item.Click+=async(_,_)=>await Guard(run);menu.Items.Add(item);}Add("Твой ритм по треку",()=>StartRhythmAsync([t],t));
  if(clipCache.TryGetValue(t.id,out var clip)&&clip.expires>DateTime.UtcNow&&clip.videoID.Length>0)
   Add("Клип",()=>ShowClipAsync(t,clip.videoID));
  else _=PrefetchClipAsync(t);
  Add(likes.Contains(t.id)?"Убрать из избранного":"В избранное",()=>Like(t));Add("Скачать",()=>Download([t]));Add("Поделиться",()=>{Clipboard.SetText(new Uri(api.Origin,"track/"+t.id).AbsoluteUri);Status.Text="Ссылка скопирована";return Task.CompletedTask;});Add("Текст песни",()=>Lyrics(t));Add("Открыть исполнителя",()=>ArtistProfile(t.artist));Add("Качество звука",()=>{QualityMenu(owner);return Task.CompletedTask;});Add("Больше не предлагать",()=>{hiddenTracks.Add(t.id);SaveMobileSettings();return Task.CompletedTask;});var lists=new MenuItem{Header="Добавить в плейлист"};foreach(var p in playlists){var item=new MenuItem{Header=p.name};item.Click+=async(_,_)=>await Guard(async()=>{await api.Request("api/playlists/"+p.id+"/tracks/"+t.id,"POST");});lists.Items.Add(item);}menu.Items.Add(lists);menu.PlacementTarget=owner;menu.IsOpen=true;}
 async void LikeClick(object sender,RoutedEventArgs e){if(Current!=null)await Guard(()=>Like(Current));}
 async Task Like(Track t){
  if(account.Length==0){Login();return;}
  if(!pendingLikeIDs.Add(t.id))return;
  try{
   bool remove=likes.Contains(t.id);
   await api.Request("api/likes/"+Uri.EscapeDataString(t.id),remove?"DELETE":"POST");
   if(remove){
    likes.Remove(t.id);favoriteOrderIDs.RemoveAll(id=>id==t.id);
   }else{
    RememberFavoriteDetails([t]);
    likes.Add(t.id);favoriteOrderIDs.RemoveAll(id=>id==t.id);
    favoriteOrderIDs.Insert(0,t.id);
    if(autoDownload)_=Download([t]);
   }
   SaveLibraryCacheAsync(account);
   UpdatePlaybackChrome();
   if(screen=="Избранное")Show("Избранное");
  }finally{pendingLikeIDs.Remove(t.id);}
 }
 async Task Lyrics(Track t){
  Home.Visibility=Library.Visibility=Dock.Visibility=Visibility.Collapsed;PlayerPage.Visibility=LyricsPanel.Visibility=Visibility.Visible;Ribbon.Visibility=Visibility.Visible;Ribbon.Focused=true;Cover.Visibility=Visibility.Collapsed;StartLyricClock();
  if(lyricsID==t.id&&currentLyrics.HasValue){SyncLyrics();return;}
  lyricsCancellation?.Cancel();lyricsCancellation=new();var token=lyricsCancellation.Token;lyricsID=t.id;currentLyrics=null;renderedLyric=int.MinValue;SyncedLyricsLines.Visibility=Visibility.Collapsed;LyricsText.Visibility=Visibility.Visible;LyricsText.Text="Ищем подходящий текст…";
  string folder=Path.Combine(NativeAPI.Storage,"lyrics");Directory.CreateDirectory(folder);string cache=Path.Combine(folder,t.id+".json");
  try{
   if(File.Exists(cache)&&DateTime.UtcNow-File.GetLastWriteTimeUtc(cache)<TimeSpan.FromDays(30)){var cached=JsonDocument.Parse(await File.ReadAllTextAsync(cache,token)).RootElement.Clone();if(cached.TryGetProperty("status",out var st)&&st.GetString()=="found"){currentLyrics=cached;SyncLyrics();return;}}
   for(int round=0;round<20;round++){
    var result=await api.Request("api/lyrics/"+t.id,cancellation:token);if(currentID!=t.id)return;
    string status=result.TryGetProperty("status",out var state)?state.GetString()??"":"";
    if(status is "loading" or "pending" or "unavailable"){double delay=result.TryGetProperty("retry_after",out var retry)?retry.GetDouble():3;await Task.Delay(TimeSpan.FromSeconds(Math.Clamp(delay,2,60)),token);continue;}
    currentLyrics=result;renderedLyric=int.MinValue;SyncLyrics();if(status is "found" or "instrumental")await File.WriteAllTextAsync(cache,result.GetRawText(),token);return;
   }
   LyricsText.Text="Поиск текста временно недоступен. Открой текст ещё раз чуть позже.";lyricsID="";
  }catch(OperationCanceledException){}catch{if(currentID==t.id){lyricsID="";LyricsText.Text="Не удалось загрузить текст. Повтори позже.";}}
 }
 void SyncLyrics(){
  if(!currentLyrics.HasValue||lyricsID!=currentID)return;
  var result=currentLyrics.Value;
  if(syncLyrics&&result.TryGetProperty("synced",out var synced)&&synced.GetBoolean()&&result.TryGetProperty("lines",out var lines)){
   var all=lines.EnumerateArray().ToArray();
   int activeIndex=Array.FindLastIndex(all,line=>line.GetProperty("time").GetDouble()<=audioTime/1000.0);
   int activeWord=kineticLyrics&&activeIndex>=0
    ?KineticWordAt(all,activeIndex,audioTime/1000.0):-1;
   if(renderedLyric==activeIndex&&renderedKineticWord==activeWord&&displayedLyricsTrack==currentID&&syncedLyricButtons.Count==all.Length)return;
   renderedLyric=activeIndex;renderedKineticWord=activeWord;
   DisplaySyncedLyrics(all,activeIndex,activeWord);
  }else{
   SyncedLyricsLines.Visibility=Visibility.Collapsed;
   LyricsText.Visibility=Visibility.Visible;
   LyricsText.Text=result.TryGetProperty("plain",out var plain)?plain.GetString():"Текст пока не найден";
  }
 }
 void QueueClick(object sender,RoutedEventArgs e)=>QueueWindow();
 EmbeddedSheet QueueWindow(bool show=true)=>QueueWithDepthSetting(show);
 void BackgroundClick(object sender,RoutedEventArgs e){backgroundOnly=true;Header.Visibility=Dock.Visibility=HomeControls.Visibility=HomeHeading.Visibility=Visibility.Collapsed;PlaybackBadge.Visibility=Status.Visibility=Visibility.Collapsed;HeaderRow.Height=new GridLength(0);MouseDoubleClick-=RestoreBackground;MouseDoubleClick+=RestoreBackground;}
 void RestoreBackground(object sender,MouseButtonEventArgs e){LeaveBackgroundMode();Show("Главная");}
 void ShowPlaylists()=>Show("Плейлисты");
 void CollectionClick(object sender,RoutedEventArgs e){if(screen=="Плейлисты"&&playlist.Length==0){ShowPlaylists();return;}if(screen=="Избранное"){
 var favoritesMenu=new ContextMenu();
 var sortItem=new MenuItem{Header="Сортировать избранное"};sortItem.Click+=async(_,_)=>await SortFavorites();favoritesMenu.Items.Add(sortItem);
 var shareItem=new MenuItem{Header="Поделиться избранным"};shareItem.Click+=async(_,_)=>await Guard(ShareCollectionAsync);favoritesMenu.Items.Add(shareItem);
 favoritesMenu.PlacementTarget=(UIElement)sender;favoritesMenu.IsOpen=true;return;
}var menu=new ContextMenu();if(playlist.Length>0&&screen=="Плейлисты"){
  var rhythm=new MenuItem{Header="Твой ритм по плейлисту"};
  rhythm.Click+=async(_,_)=>await Guard(()=>StartRhythmAsync(shown.ToList(),null));
  menu.Items.Add(rhythm);
 }
 var get=new MenuItem{Header="Скачать всё"};get.Click+=async(_,_)=>await Download(shown.ToList());menu.Items.Add(get);if(playlist.Length>0&&screen!="Избранное"&&screen!="Офлайн"){var publish=new MenuItem{Header="Опубликовать в поиске"};publish.Click+=async(_,_)=>await Guard(async()=>{await api.Request("api/community-playlists/publish","POST",new{playlist_id=playlist});Status.Text="Плейлист опубликован";});menu.Items.Add(publish);var unpublish=new MenuItem{Header="Снять с публикации"};unpublish.Click+=async(_,_)=>await Guard(async()=>{await api.Request("api/community-playlists/publish/"+playlist,"DELETE");Status.Text="Публикация снята";});menu.Items.Add(unpublish);}if(screen=="Офлайн"){var import=new MenuItem{Header="Добавить файлы"};import.Click+=(_,_)=>Import();menu.Items.Add(import);}else{var share=new MenuItem{Header="Поделиться"};share.Click+=async(_,_)=>await Guard(ShareCollectionAsync);menu.Items.Add(share);}menu.PlacementTarget=(UIElement)sender;menu.IsOpen=true;}
 string OfflineRoot=>Path.Combine(NativeAPI.Storage,"offline");
 List<Track> ReadOffline(){Directory.CreateDirectory(OfflineRoot);var result=new List<Track>();foreach(var f in Directory.GetFiles(OfflineRoot,"*.json")){try{var t=JsonSerializer.Deserialize<Track>(File.ReadAllText(f));if(t?.LocalPath!=null&&File.Exists(t.LocalPath)&&ValidAudio(t.LocalPath))result.Add(t);}catch{}}return result;}
 async void Import(){var picker=new OpenFileDialog{Multiselect=true,Filter="Аудиофайлы|*.mp3;*.m4a;*.aac;*.flac;*.wav;*.ogg"};if(picker.ShowDialog()!=true)return;var selectedFiles=picker.FileNames;await Guard(async()=>{await Task.Run(()=>{Directory.CreateDirectory(OfflineRoot);foreach(var file in selectedFiles){string id="local_"+Guid.NewGuid().ToString("N"),target=Path.Combine(OfflineRoot,id+Path.GetExtension(file));File.Copy(file,target);var t=new Track{id=id,title=Path.GetFileNameWithoutExtension(file),artist="На этом устройстве",LocalPath=target};File.WriteAllText(Path.Combine(OfflineRoot,id+".json"),JsonSerializer.Serialize(t));}});Show("Офлайн");});}
 async Task Download(List<Track> tracks){
  if(downloading)return;
  if(account.Length==0){Login();return;}
  downloading=true;
  Directory.CreateDirectory(OfflineRoot);
  Status.Text=$"Загрузка {tracks.Count} треков…";
  using var slots=new SemaphoreSlim(2,2);
  async Task<int> DownloadOne(Track t){
   await slots.WaitAsync(lifetime.Token);
   string? staging=null;
   try{
    if(!System.Text.RegularExpressions.Regex.IsMatch(t.id,@"^[A-Za-z0-9_-]{1,80}$"))
     return -1;
    string target=Path.Combine(OfflineRoot,t.id+".m4a");
    if((t.LocalPath!=null&&File.Exists(t.LocalPath)&&ValidAudio(t.LocalPath))||
       ValidAudio(target))return 1;
    bool ready=false;
    for(int attempt=0;attempt<24;attempt++){
     lifetime.Token.ThrowIfCancellationRequested();
     var preparation=await api.Request("api/offline-export/"+t.id,cancellation:lifetime.Token);
     string state=preparation.TryGetProperty("status",out var status)
       ?status.GetString()??"":"";
     if(state=="ready"){ready=true;break;}
     if(state=="error")throw new IOException(
       preparation.TryGetProperty("error",out var problem)?problem.GetString():"Не удалось подготовить трек");
     await Task.Delay(1500,lifetime.Token);
    }
    if(!ready)throw new IOException("Подготовка аудио заняла слишком много времени");
    using var downloadDeadline=CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
    downloadDeadline.CancelAfter(TimeSpan.FromMinutes(2));
    using var response=await api.HTTP.GetAsync("api/offline-export/"+t.id+
      "?download=true",System.Net.Http.HttpCompletionOption.ResponseHeadersRead,
      downloadDeadline.Token);
    response.EnsureSuccessStatusCode();
    if(response.Content.Headers.ContentType?.MediaType?.Contains("json")==true)
     throw new IOException("Аудио ещё не готово");
    if(response.Content.Headers.ContentLength>32*1024*1024)
     throw new IOException("Слишком большой файл");
    staging=target+"."+Guid.NewGuid().ToString("N")+".tmp";
    await using(var output=File.Create(staging)){
     await using var input=await response.Content.ReadAsStreamAsync(lifetime.Token);
     byte[] buffer=new byte[32768];int count;long size=0;
     while((count=await input.ReadAsync(buffer,lifetime.Token))>0){
      size+=count;
      if(size>32*1024*1024)throw new IOException("Слишком большой файл");
      await output.WriteAsync(buffer.AsMemory(0,count),lifetime.Token);
     }
    }
    if(!ValidAudio(staging))throw new IOException("Сервер вернул повреждённое аудио");
    File.Move(staging,target,true);
    File.WriteAllText(Path.Combine(OfflineRoot,t.id+".json"),
       JsonSerializer.Serialize(t with {LocalPath=target}));
    return 0;
   }catch(OperationCanceledException){return -1;}
    catch(Exception){return -1;}
   finally{
    if(staging!=null)try{File.Delete(staging);}catch(IOException){}
    slots.Release();
   }
  }
  try{
   var jobs=tracks.Select(t=>Task.Run(()=>DownloadOne(t),lifetime.Token)).ToArray();
   var results=await Task.WhenAll(jobs);
   var added=results.Count(x=>x==0);
   var skipped=results.Count(x=>x==1);
   var failed=results.Count(x=>x<0);
   Status.Text=$"Скачано: {added} · уже сохранено: {skipped} · ошибок: {failed}";
  }catch(OperationCanceledException){Status.Text="Загрузка отменена";}
   finally{downloading=false;}
 }
 void Login(){
  var panel=new StackPanel();panel.Children.Add(Label("Войти в Nightwell"));
  panel.Children.Add(new TextBlock{Text="Твоя музыка на всех устройствах",Foreground=(Brush)FindResource("SecondaryBrush"),Margin=new Thickness(0,0,0,12)});
  panel.Children.Add(Label("Email"));var email=new TextBox{Tag="you@example.com"};panel.Children.Add(email);
  panel.Children.Add(Label("Пароль"));var password=new PasswordBox();panel.Children.Add(password);
  var codeLabel=Label("Код из письма");codeLabel.Visibility=Visibility.Collapsed;panel.Children.Add(codeLabel);
  var code=new TextBox{Visibility=Visibility.Collapsed,Tag="Введи код"};panel.Children.Add(code);
  var note=new TextBlock{TextWrapping=TextWrapping.Wrap,Foreground=(Brush)FindResource("SecondaryBrush"),FontSize=12,Margin=new Thickness(0,12,0,4)};panel.Children.Add(note);
  string challenge="",action="login";var window=Sheet("Войти в Nightwell",panel,580);
  var login=new Button{Content="Войти",Style=(Style)FindResource("PrimaryButton"),Margin=new Thickness(0,12,0,4)};
  var register=new Button{Content="Создать аккаунт",Style=(Style)FindResource("QuietButton")};var resend=new Button{Content="Отправить код ещё раз",Visibility=Visibility.Collapsed,Style=(Style)FindResource("QuietButton")};panel.Children.Add(login);panel.Children.Add(register);panel.Children.Add(resend);
  async Task Submit(bool create,bool repeatCode=false){login.IsEnabled=register.IsEnabled=resend.IsEnabled=false;try{
   if(challenge.Length==0)action=create?"register":"login";
   object body=challenge.Length==0?new{email=email.Text,password=password.Password,supports_email_codes=true}:repeatCode?new{challenge_id=challenge,resend=true}:new{challenge_id=challenge,code=code.Text.Trim()};
   var response=await api.Request("api/"+action,"POST",body);
   if(response.TryGetProperty("challenge",out var next)&&next.ValueKind==JsonValueKind.Object){challenge=next.GetProperty("id").GetString()!;code.Visibility=codeLabel.Visibility=resend.Visibility=Visibility.Visible;register.Visibility=Visibility.Collapsed;email.IsEnabled=password.IsEnabled=false;login.Content="Подтвердить код";note.Text="Введи код из письма";return;}
   if(response.TryGetProperty("csrf",out var csrf))api.Csrf=csrf.GetString()??"";window.Close();await LoadAccount();await InitializeMobileFeatures();
  }catch(Exception ex){note.Text=ex.Message;}finally{login.IsEnabled=register.IsEnabled=resend.IsEnabled=true;}}
  login.Click+=async(_,_)=>await Submit(false);register.Click+=async(_,_)=>await Submit(true);resend.Click+=async(_,_)=>await Submit(false,true);
 }
 EmbeddedSheet Settings(bool show=true){
  var panel=new StackPanel();panel.Children.Add(Label("Настройки"));
  panel.Children.Add(new TextBlock{Text="Воспроизведение и твоя медиатека",Foreground=(Brush)FindResource("SecondaryBrush"),Margin=new Thickness(0,0,0,16)});
  var customization=new StackPanel();
  customization.Children.Add(Label("Кастомизация"));
  var deckToggle=new CheckBox{Content="Объёмная очередь · стопка обложек",IsChecked=depthQueue};
  deckToggle.Click+=(_,_)=>{depthQueue=deckToggle.IsChecked==true;SaveSettings();};
  customization.Children.Add(deckToggle);
  customization.Children.Add(new TextBlock{Text="Если выключить, останется привычный список. Обложки на Windows не анимируются.",
    TextWrapping=TextWrapping.Wrap,Foreground=(Brush)FindResource("SecondaryBrush"),Margin=new Thickness(0,4,0,10)});
  var kineticToggle=new CheckBox{Content="Кинетический текст песен",IsChecked=kineticLyrics};
  kineticToggle.Click+=(_,_)=>{kineticLyrics=kineticToggle.IsChecked==true;renderedLyric=int.MinValue;SaveSettings();};
  customization.Children.Add(kineticToggle);
  panel.Children.Add(SettingsCard(customization));
  var playback=new StackPanel();
  var label=Label($"Переход между треками · {transition:0.0} с");
  var slider=new Slider{Minimum=0,Maximum=5,Value=transition,TickFrequency=.1,IsSnapToTickEnabled=true,Margin=new Thickness(0,4,0,16)};
  slider.ValueChanged+=(_,_)=>{transition=slider.Value;label.Text=$"Переход между треками · {transition:0.0} с";SaveSettings();};playback.Children.Add(label);playback.Children.Add(slider);
  var loudLabel=Label($"Одинаковая громкость · {normalization}%");
  var loud=new Slider{Minimum=0,Maximum=100,Value=normalization,TickFrequency=10,IsSnapToTickEnabled=true,Margin=new Thickness(0,4,0,8)};
  loud.ValueChanged+=(_,_)=>{normalization=(int)loud.Value;loudLabel.Text=$"Одинаковая громкость · {normalization}%";SaveSettings();};playback.Children.Add(loudLabel);playback.Children.Add(loud);
  playback.Children.Add(new TextBlock{Text="Выравнивает тихие и громкие записи. Для применения перезапусти приложение.",TextWrapping=TextWrapping.Wrap,Foreground=(Brush)FindResource("SecondaryBrush"),FontSize=12,LineHeight=19,Margin=new Thickness(0,4,0,4)});
  panel.Children.Add(SettingsCard(playback));
  if(account.Length>0)AddProfileSettings(panel);
  var transfer=new StackPanel();
  transfer.Children.Add(Label("Перенос музыки"));
  var importButton=new Button{Content="Импортировать плейлисты",Style=(Style)FindResource("QuietButton")};
  importButton.Click+=(_,_)=>NativeTransfer();
  transfer.Children.Add(importButton);
  panel.Children.Add(SettingsCard(transfer));
  var library=new StackPanel();
  var downloadToggle=new CheckBox{Content="Автозагрузка избранного",IsChecked=autoDownload};downloadToggle.Click+=(_,_)=>{autoDownload=downloadToggle.IsChecked==true;SaveMobileSettings();};library.Children.Add(downloadToggle);
  var lyricsToggle=new CheckBox{Content="Текст в такт",IsChecked=syncLyrics};lyricsToggle.Click+=(_,_)=>{syncLyrics=lyricsToggle.IsChecked==true;renderedLyric=int.MinValue;SaveMobileSettings();};library.Children.Add(lyricsToggle);panel.Children.Add(SettingsCard(library));
  var window=Sheet("Настройки",panel,600,false);var done=new Button{Content="Готово",Style=(Style)FindResource("PrimaryButton"),MinWidth=112,HorizontalAlignment=HorizontalAlignment.Right,Margin=new Thickness(0,16,0,0)};done.Click+=(_,_)=>window.Close();panel.Children.Add(done);if(show)window.Show();return window;
 }
 Border SettingsCard(UIElement content)=>new(){Background=(Brush)FindResource("InputBrush"),BorderBrush=(Brush)FindResource("LineBrush"),BorderThickness=new Thickness(1),CornerRadius=new CornerRadius(14),Padding=new Thickness(18,8,18,12),Margin=new Thickness(0,8,0,0),Child=content};
 CancellationTokenSource? settingsDebounce;
 void SaveSettings(){
  string data=JsonSerializer.Serialize(new{origin,transition,normalization,volume=userVolume,depthQueue,kineticLyrics});settingsDebounce?.Cancel();settingsDebounce=new();var token=settingsDebounce.Token;
  _=Task.Run(async()=>{try{await Task.Delay(300,token);await settingsGate.WaitAsync(token);try{Directory.CreateDirectory(NativeAPI.Storage);string file=Path.Combine(NativeAPI.Storage,"settings.json");await File.WriteAllTextAsync(file+".tmp",data,token);token.ThrowIfCancellationRequested();File.Move(file+".tmp",file,true);}finally{settingsGate.Release();}}catch(OperationCanceledException){}catch{}});
 }
 void Prompt(string title,string hint,Func<string,Task> run){
  var panel=new StackPanel();panel.Children.Add(Label(title));panel.Children.Add(Label(hint));var value=new TextBox();panel.Children.Add(value);
  var save=new Button{Content="Сохранить",Style=(Style)FindResource("PrimaryButton"),Margin=new Thickness(0,20,0,0)};panel.Children.Add(save);var window=Sheet(title,panel,310);
  save.Click+=async(_,_)=>{save.IsEnabled=false;try{await Guard(()=>run(value.Text));window.Close();}finally{save.IsEnabled=true;}};
 }
}
