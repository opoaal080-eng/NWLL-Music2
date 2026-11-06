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
 bool volumeSettingReady;
 CancellationTokenSource? searchCancellation;List<Track> catalog=[],shown=[],queue=[];List<Playlist> playlists=[];HashSet<string> likes=[];
 string favoriteOrder="recent";bool premiumSortAllowed=false;
 string account="",screen="Главная",playlist="",currentID="";int index,repeat;bool wave,refilling,downloading,scrubbing,shuffle,mixing;readonly Queue<string> mixRecent=new();double transition=.8;long lastPrevious;string previousID="";
 CancellationTokenSource? lyricsCancellation;JsonElement? currentLyrics;string lyricsID="";int renderedLyric=int.MinValue;long savedAt;double? pendingSeek;bool restorePaused;
 sealed record PlaybackState(string Origin,string Account,List<Track> Queue,string ID,double Position,int Repeat,bool Shuffle,bool Wave);
 string ResumeFile=>Path.Combine(NativeAPI.Storage,"resume.json");
 PlaybackState? CapturePlayback()=>Current==null?null:new PlaybackState(origin,account,queue.ToList(),currentID,Math.Max(0,audioTime/1000.0),repeat,shuffle,wave);
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
    repeat=state.Repeat;shuffle=state.Shuffle;wave=state.Wave;
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
}catch{}
Loaded+=async(_,_)=>{try{await Task.Run(()=>{api=new NativeAPI(origin);proxy=new StreamProxy(api);Core.Initialize();
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
player.Volume=(int)Math.Round(userVolume*100);player.EndReached+=(_,_)=>Dispatcher.InvokeAsync(()=>Advance());player.EncounteredError+=(_,_)=>Dispatcher.InvokeAsync(()=>Status.Text="Не удалось воспроизвести трек. Проверь подключение и повтори попытку.");timer.Tick+=(_,_)=>Tick();timer.Start();
 if(Environment.GetCommandLineArgs().Contains("--native-smoke")){
  await Task.Delay(1200);var bitmap=new RenderTargetBitmap((int)ActualWidth,(int)ActualHeight,96,96,PixelFormats.Pbgra32);bitmap.Render(this);var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bitmap));using(var file=File.Create("windows-native-smoke.png"))encoder.Save(file);Close();
 }else {await LoadAccount();await RestorePlaybackAsync();await InitializeMobileFeatures();}
}catch(Exception ex){Status.Text="Не удалось запустить плеер: "+ex.Message;}};Closed+=(_,_)=>{QueueSavePlayback();timer.Stop();searchCancellation?.Cancel();lyricsCancellation?.Cancel();lifetime.Cancel();_ = Task.Run(()=>{player?.Stop();player?.Dispose();vlc?.Dispose();proxy?.Dispose();api?.Dispose();});};}
 async Task Guard(Func<Task> action){try{await action();}catch(OperationCanceledException){}catch(Exception e){Status.Text=e.Message;}}
 List<Track> ParseTracks(JsonElement json)=>json.GetProperty("tracks").Deserialize<List<Track>>()??[];
 async Task LoadAccount(){await Guard(async()=>{var me=await api.Request("api/me");api.Csrf=me.GetProperty("csrf").GetString()??"";account=me.GetProperty("user").ValueKind==JsonValueKind.Object?me.GetProperty("user").GetProperty("id").GetString()??"":"";if(account.Length==0){Status.Text="Войди в аккаунт или открой офлайн-файлы";return;}var tasks=await Task.WhenAll(api.Request("api/tracks"),api.Request("api/likes"),api.Request("api/playlists"));catalog=ParseTracks(tasks[0]);likes=tasks[1].GetProperty("ids").Deserialize<HashSet<string>>()??[];playlists=tasks[2].GetProperty("playlists").Deserialize<List<Playlist>>()??[];Status.Text="";if(screen!="Поиск")Show(screen);});}
 void Show(string next){searchCancellation?.Cancel();screen=next;playlist="";Dock.Visibility=Visibility.Visible;Home.Visibility=next=="Главная"?Visibility.Visible:Visibility.Collapsed;Library.Visibility=next=="Главная"?Visibility.Collapsed:Visibility.Visible;PlayerPage.Visibility=Visibility.Collapsed;Heading.Text=next;SearchBox.Visibility=next=="Поиск"?Visibility.Visible:Visibility.Collapsed;CollectionActions.Visibility=next=="Поиск"?Visibility.Collapsed:Visibility.Visible;if(next=="Поиск"){SearchBox.Focus();shown=[];}else if(next=="Избранное"){shown=catalog.Where(t=>likes.Contains(t.id)).ToList();if(premiumSortAllowed&&favoriteOrder=="title")shown=shown.OrderBy(t=>t.title,StringComparer.CurrentCultureIgnoreCase).ToList();else if(premiumSortAllowed&&favoriteOrder=="artist")shown=shown.OrderBy(t=>t.artist,StringComparer.CurrentCultureIgnoreCase).ToList();}else if(next=="Офлайн"){shown=[];_=LoadOfflineTracksAsync();}Tracks.ItemsSource=shown;if(next=="Плейлисты")ShowPlaylists();}
 async Task LoadOfflineTracksAsync(){try{
  var local=await Task.Run(ReadOffline);
  if(screen!="Офлайн")return;
  shown=local;Tracks.ItemsSource=local;
 }catch(Exception ex){if(screen=="Офлайн")Status.Text="Не удалось открыть офлайн-файлы: "+ex.Message;}}
 void SearchClick(object sender,RoutedEventArgs e)=>Show("Поиск");
 async void SearchChanged(object sender,TextChangedEventArgs e){if(screen!="Поиск")return;searchCancellation?.Cancel();searchCancellation=new();var cancellation=searchCancellation.Token;string query=SearchBox.Text.Trim();if(query.Length==0){Tracks.ItemsSource=new List<Track>();return;}await Guard(async()=>{await Task.Delay(300,cancellation);var local=await Task.Run(()=>catalog.Where(t=>(t.title+" "+t.artist).Contains(query,StringComparison.OrdinalIgnoreCase)).ToList(),cancellation);cancellation.ThrowIfCancellationRequested();shown=local;Tracks.ItemsSource=shown;Status.Text="Ищем полные версии…";for(int i=0;i<30;i++){var result=await api.Request("api/tracks?q="+Uri.EscapeDataString(query),cancellation:cancellation);cancellation.ThrowIfCancellationRequested();shown=ParseTracks(result);Tracks.ItemsSource=shown;Status.Text=result.TryGetProperty("search_message",out var message)?message.GetString():"";if(!result.TryGetProperty("search_pending",out var pending)||!pending.GetBoolean())break;await Task.Delay(2000,cancellation);}});}

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
  var window=new Window{Title="Nightwell · Перенести музыку",Width=570,Height=620,WindowStartupLocation=WindowStartupLocation.CenterOwner,Owner=this,Background=new SolidColorBrush(Color.FromRgb(26,20,39))};
  var panel=new StackPanel{Margin=new Thickness(22)};
  TextBlock Label(string value){return new TextBlock{Text=value,Foreground=Brushes.White,Margin=new Thickness(0,10,0,7),FontSize=15};}
  panel.Children.Add(Label("Перенести музыку"));
  var name=new TextBox{Text="Перенос музыки",Padding=new Thickness(10)};panel.Children.Add(name);
  panel.Children.Add(Label("Режим поиска"));
  var mode=new ComboBox{ItemsSource=new[]{"Точный","Умный","Максимальный"},SelectedIndex=1};panel.Children.Add(mode);
  var choose=new Button{Content="Открыть JSON, CSV или TXT",Margin=new Thickness(0,12,0,8),Padding=new Thickness(8)};
  var input=new TextBox{AcceptsReturn=true,TextWrapping=TextWrapping.Wrap,VerticalScrollBarVisibility=ScrollBarVisibility.Auto,Height=175};
  choose.Click+=(_,_)=>{var picker=new OpenFileDialog{Filter="Плейлисты|*.json;*.csv;*.txt|Все файлы|*.*"};if(picker.ShowDialog(window)==true){var data=File.ReadAllBytes(picker.FileName);if(data.Length>1024*1024){MessageBox.Show(window,"Максимальный размер файла 1 МБ");return;}input.Text=System.Text.Encoding.UTF8.GetString(data);}};
  panel.Children.Add(choose);panel.Children.Add(input);
  var progress=new TextBlock{Foreground=Brushes.White,Margin=new Thickness(0,14,0,12),TextWrapping=TextWrapping.Wrap};panel.Children.Add(progress);
  var start=new Button{Content="Найти треки",Padding=new Thickness(12)};panel.Children.Add(start);string readyKey="";
  start.Click+=async(_,_)=>{
   start.IsEnabled=false;
   try{
    if(readyKey.Length>0){await api.Request("api/imports/"+readyKey+"/commit","POST",new{});progress.Text="Сохраняем плейлист…";return;}
    string[] codes={"safe","balanced","wide"};progress.Text="Запускаем поиск…";
    var response=await api.Request("api/imports","POST",new{provider="yandex",name=name.Text,url="",text=input.Text,mode=codes[mode.SelectedIndex]});
    string key=response.GetProperty("id").GetString()??"";
    while(window.IsVisible){
     var status=await api.Request("api/imports/"+key);
     var state=status.GetProperty("state").GetString()??"";
     progress.Text=$"Проверено: {status.GetProperty("progress").GetInt32()} / {status.GetProperty("total").GetInt32()} · Найдено: {status.GetProperty("matched").GetInt32()}";
     if(state=="ready"||state=="error"){
      readyKey=key;start.Content="Добавить найденные треки";start.IsEnabled=true;
      break;
     }
     if(state=="done"||state=="cancelled")break;
     await Task.Delay(1800);
    }
   }catch(Exception ex){progress.Text=ex.Message;start.IsEnabled=true;}
  };
  window.Content=new ScrollViewer{Content=panel,VerticalScrollBarVisibility=ScrollBarVisibility.Auto};window.Show();
 }

 void MenuClick(object sender,RoutedEventArgs e){var menu=new ContextMenu();foreach(var name in new[]{"Главная","Поиск","Избранное","Плейлисты","Подборки дня","Плейлисты в поиске","Настроить подборку","Слушать вместе","Продолжить с телефона","Перенести музыку","Сортировка избранного · Premium","Офлайн","Настройки",account.Length==0?"Войти":"Выйти"}){var value=name;var item=new MenuItem{Header=value};item.Click+=async(_,_)=>{if(value=="Подборки дня")await BrowsePlaylists(true);else if(value=="Плейлисты в поиске")await BrowsePlaylists(false);else if(value=="Настроить подборку")await TasteSettings();else if(value=="Слушать вместе")TogetherWindow();else if(value=="Продолжить с телефона")await ContinueHere();else if(value=="Сортировка избранного · Premium")await SortFavorites();else if(value=="Перенести музыку")NativeTransfer();else if(value=="Настройки")Settings();else if(value=="Войти")Login();else if(value=="Выйти")await Guard(async()=>{await api.Request("api/logout","POST");api.Clear();await AudioCommand(()=>player.Stop());roomCode="";roomCancellation?.Cancel();queue=[];catalog=[];likes=[];playlists=[];account="";Show("Главная");});else Show(value);};menu.Items.Add(item);}menu.PlacementTarget=(UIElement)sender;menu.IsOpen=true;}
 async void WaveClick(object sender,RoutedEventArgs e)=>await NewWave();
 async Task NewWave(){if(mixing)return;if(account.Length==0){Login();return;}mixing=true;Status.Text="Подбираем…";try{await Guard(async()=>{var exclude=mixRecent.Concat(queue.Take(8).Select(t=>t.id)).Append(currentID).Where(id=>id.Length>0).Distinct().TakeLast(200);string nonce=Guid.NewGuid().ToString("N");var result=await api.Request(WaveRoute+"?mix="+nonce+WaveQuery+"&exclude="+Uri.EscapeDataString(string.Join(',',exclude)));var next=ParseTracks(result).Where(t=>t.id!=currentID&&!hiddenTracks.Contains(t.id)).ToList();if(next.Count==0&&currentID.Length>0)next=ParseTracks(await api.Request(WaveRoute+"?mix="+nonce+WaveQuery+"&exclude="+currentID)).Where(t=>t.id!=currentID).ToList();if(next.Count==0){Status.Text="Новых треков пока нет. Попробуй чуть позже.";return;}queue=next;index=0;wave=true;PlayCurrent();Status.Text="";});}finally{mixing=false;}}

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
 async void ToggleClick(object sender,RoutedEventArgs e){if(Current==null){await NewWave();return;}if(roomCode.Length>0){await Guard(()=>RoomCommand(audioPlaying?"pause":"play"));return;}await AudioCommand(()=>{if(player.IsPlaying){pausedAtMs=Math.Max(0,player.Time);player.Pause();}else player.Play();});}
 void TrackDoubleClick(object sender,MouseButtonEventArgs e){if(Tracks.SelectedItem is Track t){queue=shown.ToList();index=queue.FindIndex(v=>v.id==t.id);wave=false;PlayCurrent();}}
 void PlayCurrent(){nextCancellation?.Cancel();var t=Current;if(t==null)return;pausedAtMs=0;if(t.LocalPath==null&&account.Length==0){Login();return;}string path=StreamPath(t);_=AudioCommand(()=>{using var media=new Media(vlc,path,t.LocalPath==null?FromType.FromLocation:FromType.FromPath);player.Play(media);});lyricsCancellation?.Cancel();currentLyrics=null;lyricsID="";renderedLyric=int.MinValue;currentID=t.id;mixRecent.Enqueue(t.id);while(mixRecent.Count>120)mixRecent.Dequeue();MiniTitle.Text=FullTitle.Text=t.title;MiniArtist.Text=FullArtist.Text=t.artist;LyricsText.Text="";LyricsPanel.Visibility=Visibility.Collapsed;Cover.Visibility=Visibility.Visible;if(Uri.TryCreate(api.Origin,t.cover_url??("api/covers/"+t.id),out var coverURI)&&coverURI.Scheme=="https")_=LoadCover(coverURI,t.id);else Cover.Source=MiniCover.Source=null;RecordTrackStart();Dock.BeginAnimation(OpacityProperty,new System.Windows.Media.Animation.DoubleAnimation(.6,1,TimeSpan.FromSeconds(.7)));}
 async Task LoadCover(Uri uri,string id){try{
 var bytes=await (uri.Authority==api.Origin.Authority?api.HTTP:artworkHTTP).GetByteArrayAsync(uri,lifetime.Token);
 if(bytes.Length>5*1024*1024||currentID!=id)return;
 var image=await Task.Run(()=>{
  var bitmap=new BitmapImage();
  bitmap.BeginInit();bitmap.CacheOption=BitmapCacheOption.OnLoad;
  bitmap.DecodePixelWidth=650;bitmap.StreamSource=new MemoryStream(bytes);
  bitmap.EndInit();bitmap.Freeze();return bitmap;
 });
 if(currentID==id)Cover.Source=MiniCover.Source=image;
}catch{}}
 async void NextClick(object sender,RoutedEventArgs e){if(nextRequestBusy)return;nextRequestBusy=true;try{await Guard(SafeNext);}finally{nextRequestBusy=false;}}
 void PreviousClick(object sender,RoutedEventArgs e){if(Current==null)return;long now=Environment.TickCount64;if(audioTime>3000&&!(previousID==currentID&&now-lastPrevious<3000)){lastPrevious=now;previousID=currentID;_=AudioCommand(()=>player.Time=0);return;}previousID="";index=(index-1+queue.Count)%queue.Count;PlayCurrent();}
 void Advance(){if(nextPreparing||queue.Count==0)return;if(repeat==2){PlayCurrent();return;}if(wave&&index+1>=queue.Count){_=Refill();return;}if(shuffle&&queue.Count>1)index=(index+Random.Shared.Next(1,queue.Count))%queue.Count;else if(index+1<queue.Count)index++;else if(repeat==1)index=0;else return;PlayCurrent();}
 async Task Refill(){if(refilling||!wave||account.Length==0)return;refilling=true;await Guard(async()=>{var exclude=string.Join(',',queue.TakeLast(150).Select(t=>t.id));var value=await api.Request(WaveRoute+"?"+WaveQuery.TrimStart('&')+"&exclude="+Uri.EscapeDataString(exclude));var ids=queue.Select(t=>t.id).ToHashSet();var fresh=ParseTracks(value).Where(t=>!ids.Contains(t.id)).ToList();queue.AddRange(fresh);if(!audioPlaying&&!nextPreparing&&index+1<queue.Count){index++;PlayCurrent();}});refilling=false;}
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
  long positionMs=Math.Max(0,audioTime);
  if(playing&&positionMs>0)pausedAtMs=positionMs;
  if(!playing&&positionMs==0&&pausedAtMs>0&&audioLength>0)positionMs=pausedAtMs;
  double duration=Math.Max(1,audioLength/1000.0),position=positionMs/1000.0;
  SyncLyrics();
  MiniLike.Content=likes.Contains(currentID)?"♥":"♡";
  MiniProgress.Width=Math.Max(0,Dock.ActualWidth-22)*Math.Clamp(positionMs/(double)Math.Max(1,audioLength),0,1);
  MiniPlay.Content=HomePlay.Content=FullPlay.Content=playing?"Ⅱ":"▶";
  Ribbon.Playing=playing;
  if(!scrubbing){FullSeek.Maximum=duration;FullSeek.Value=Math.Min(duration,position);}
  FullTime.Text=$"{Time(position)}    /    {Time(duration)}";
  _=AudioCommand(ApplyVolume);
  if(wave&&queue.Count-index<8&&!refilling)_=Refill();
  UpdateListening();
  if(Environment.TickCount64-lastPrefetch>12000){lastPrefetch=Environment.TickCount64;_=Prefetch();}
 }
 string Time(double s)=>$"{(int)s/60}:{(int)s%60:00}";
 void SeekStart(object sender,MouseButtonEventArgs e)=>scrubbing=true;
 void SeekEnd(object sender,MouseButtonEventArgs e){long position=(long)(FullSeek.Value*1000);_=AudioCommand(()=>player.Time=position);scrubbing=false;}
 void ShuffleClick(object sender,RoutedEventArgs e){shuffle=!shuffle;Status.Text=shuffle?"Перемешивание включено":"Перемешивание выключено";}
 void RepeatClick(object sender,RoutedEventArgs e){repeat=(repeat+1)%3;Status.Text=new[]{"Повтор выключен","Повтор очереди","Повтор трека"}[repeat];}
 void OpenPlayerClick(object sender,MouseButtonEventArgs e){if(Current==null)return;Home.Visibility=Library.Visibility=Dock.Visibility=Visibility.Collapsed;PlayerPage.Visibility=Visibility.Visible;}
 void ClosePlayerClick(object sender,RoutedEventArgs e)=>Show(screen);
 void CurrentMenuClick(object sender,RoutedEventArgs e){if(Current!=null)TrackMenu(Current,(UIElement)sender);}
 void TrackMenuClick(object sender,RoutedEventArgs e){if(sender is Button b&&b.Tag is Track t)TrackMenu(t,b);}
 void TrackMenu(Track t,UIElement owner){var menu=new ContextMenu();void Add(string label,Func<Task> run){var item=new MenuItem{Header=label};item.Click+=async(_,_)=>await Guard(run);menu.Items.Add(item);}Add(likes.Contains(t.id)?"Убрать из избранного":"В избранное",()=>Like(t));Add("Скачать",()=>Download([t]));Add("Поделиться",()=>{Clipboard.SetText(new Uri(api.Origin,"track/"+t.id).AbsoluteUri);Status.Text="Ссылка скопирована";return Task.CompletedTask;});Add("Текст песни",()=>Lyrics(t));Add("Открыть исполнителя",()=>ArtistProfile(t.artist));Add("Качество звука",()=>{QualityMenu(owner);return Task.CompletedTask;});Add("Больше не предлагать",()=>{hiddenTracks.Add(t.id);SaveMobileSettings();return Task.CompletedTask;});var lists=new MenuItem{Header="Добавить в плейлист"};foreach(var p in playlists){var item=new MenuItem{Header=p.name};item.Click+=async(_,_)=>await Guard(async()=>{await api.Request("api/playlists/"+p.id+"/tracks/"+t.id,"POST");});lists.Items.Add(item);}menu.Items.Add(lists);menu.PlacementTarget=owner;menu.IsOpen=true;}
 async void LikeClick(object sender,RoutedEventArgs e){if(Current!=null)await Guard(()=>Like(Current));}
 async Task Like(Track t){if(account.Length==0){Login();return;}bool remove=likes.Contains(t.id);await api.Request("api/likes/"+t.id,remove?"DELETE":"POST");if(remove)likes.Remove(t.id);else {likes.Add(t.id);if(autoDownload)_=Download([t]);}}
 async Task Lyrics(Track t){
  Home.Visibility=Library.Visibility=Dock.Visibility=Visibility.Collapsed;PlayerPage.Visibility=LyricsPanel.Visibility=Visibility.Visible;Cover.Visibility=Visibility.Collapsed;
  if(lyricsID==t.id&&currentLyrics.HasValue){SyncLyrics();return;}
  lyricsCancellation?.Cancel();lyricsCancellation=new();var token=lyricsCancellation.Token;lyricsID=t.id;currentLyrics=null;renderedLyric=int.MinValue;LyricsText.Text="Ищем подходящий текст…";
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
 void SyncLyrics(){if(!currentLyrics.HasValue||lyricsID!=currentID)return;var result=currentLyrics.Value;if(syncLyrics&&result.TryGetProperty("synced",out var synced)&&synced.GetBoolean()&&result.TryGetProperty("lines",out var lines)){double position=audioTime/1000.0;var all=lines.EnumerateArray().ToArray();int activeIndex=Array.FindLastIndex(all,l=>l.GetProperty("time").GetDouble()<=position);if(renderedLyric==activeIndex)return;renderedLyric=activeIndex;var active=activeIndex>=0?all[activeIndex]:default;LyricsText.Text=string.Join("\n\n",lines.EnumerateArray().Select(l=>(active.ValueKind!=JsonValueKind.Undefined&&l.GetProperty("time").GetDouble()==active.GetProperty("time").GetDouble()?"▶  ":"")+l.GetProperty("text").GetString()));}else LyricsText.Text=result.TryGetProperty("plain",out var plain)?plain.GetString():"Текст пока не найден";}
 void QueueClick(object sender,RoutedEventArgs e){var window=new Window{Title="Очередь",Width=580,Height=600,Owner=this,Background=new SolidColorBrush(Color.FromRgb(24,15,35))};var list=new ListBox{ItemsSource=queue,DisplayMemberPath="title"};list.MouseDoubleClick+=(_,_)=>{if(list.SelectedItem is Track t){index=queue.IndexOf(t);PlayCurrent();window.Close();}};window.Content=list;window.ShowDialog();}
 void BackgroundClick(object sender,RoutedEventArgs e){Header.Visibility=Dock.Visibility=HomeControls.Visibility=HomeHeading.Visibility=Visibility.Collapsed;MouseDoubleClick+=RestoreBackground;}
 void RestoreBackground(object sender,MouseButtonEventArgs e){Header.Visibility=Dock.Visibility=HomeControls.Visibility=HomeHeading.Visibility=Visibility.Visible;MouseDoubleClick-=RestoreBackground;}
 void ShowPlaylists(){var menu=new ContextMenu();foreach(var p in playlists){var item=new MenuItem{Header=p.name};item.Click+=async(_,_)=>await Guard(async()=>{playlist=p.id;screen=p.name;Heading.Text=p.name;shown=ParseTracks(await api.Request("api/playlists/"+p.id+"/tracks"));Tracks.ItemsSource=shown;});menu.Items.Add(item);}var add=new MenuItem{Header="＋ Создать плейлист"};add.Click+=(_,_)=>Prompt("Новый плейлист","Название",async name=>{await api.Request("api/playlists","POST",new{name});await LoadAccount();});menu.Items.Add(add);menu.PlacementTarget=CollectionActions;menu.IsOpen=true;}
 void CollectionClick(object sender,RoutedEventArgs e){if(screen=="Плейлисты"){ShowPlaylists();return;}var menu=new ContextMenu();var get=new MenuItem{Header="Скачать всё"};get.Click+=async(_,_)=>await Download(shown.ToList());menu.Items.Add(get);if(playlist.Length>0&&screen!="Избранное"&&screen!="Офлайн"){var publish=new MenuItem{Header="Опубликовать в поиске"};publish.Click+=async(_,_)=>await Guard(async()=>{await api.Request("api/community-playlists/publish","POST",new{playlist_id=playlist});Status.Text="Плейлист опубликован";});menu.Items.Add(publish);var unpublish=new MenuItem{Header="Снять с публикации"};unpublish.Click+=async(_,_)=>await Guard(async()=>{await api.Request("api/community-playlists/publish/"+playlist,"DELETE");Status.Text="Публикация снята";});menu.Items.Add(unpublish);}if(screen=="Офлайн"){var import=new MenuItem{Header="Добавить файлы"};import.Click+=(_,_)=>Import();menu.Items.Add(import);}else{var share=new MenuItem{Header="Поделиться"};share.Click+=async(_,_)=>await Guard(async()=>{var response=await api.Request("api/shares","POST",new{kind=screen=="Избранное"?"likes":"playlist",playlist_id=playlist});Clipboard.SetText(new Uri(api.Origin,response.GetProperty("path").GetString()!).AbsoluteUri);Status.Text="Ссылка скопирована";});menu.Items.Add(share);}menu.PlacementTarget=(UIElement)sender;menu.IsOpen=true;}
 string OfflineRoot=>Path.Combine(NativeAPI.Storage,"offline");
 List<Track> ReadOffline(){Directory.CreateDirectory(OfflineRoot);var result=new List<Track>();foreach(var f in Directory.GetFiles(OfflineRoot,"*.json")){try{var t=JsonSerializer.Deserialize<Track>(File.ReadAllText(f));if(t?.LocalPath!=null&&File.Exists(t.LocalPath)&&ValidAudio(t.LocalPath))result.Add(t);}catch{}}return result;}
 async void Import(){var picker=new OpenFileDialog{Multiselect=true,Filter="Аудиофайлы|*.mp3;*.m4a;*.aac;*.flac;*.wav;*.ogg"};if(picker.ShowDialog()!=true)return;var selectedFiles=picker.FileNames;await Guard(async()=>{await Task.Run(()=>{Directory.CreateDirectory(OfflineRoot);foreach(var file in selectedFiles){string id="local_"+Guid.NewGuid().ToString("N"),target=Path.Combine(OfflineRoot,id+Path.GetExtension(file));File.Copy(file,target);var t=new Track{id=id,title=Path.GetFileNameWithoutExtension(file),artist="На этом устройстве",LocalPath=target};File.WriteAllText(Path.Combine(OfflineRoot,id+".json"),JsonSerializer.Serialize(t));}});Show("Офлайн");});}
 async Task Download(List<Track> tracks){if(downloading)return;if(account.Length==0){Login();return;}downloading=true;Directory.CreateDirectory(OfflineRoot);int added=0,skip=0,failed=0;try{foreach(var t in tracks){if(t.LocalPath!=null||File.Exists(Path.Combine(OfflineRoot,t.id+".json"))){skip++;continue;}Status.Text=$"Загрузка {added+skip+failed+1} / {tracks.Count}";try{bool ready=false;for(int attempt=0;attempt<100;attempt++){var preparation=await api.Request("api/offline-export/"+t.id);string state=preparation.GetProperty("status").GetString()??"";if(state=="ready"){ready=true;break;}if(state=="error")throw new IOException(preparation.GetProperty("error").GetString());await Task.Delay(3000);}if(!ready)throw new IOException("Подготовка аудио заняла слишком много времени");using var response=await api.HTTP.GetAsync("api/offline-export/"+t.id+"?download=true",System.Net.Http.HttpCompletionOption.ResponseHeadersRead);response.EnsureSuccessStatusCode();if(response.Content.Headers.ContentType?.MediaType?.Contains("json")==true)throw new IOException("Аудио ещё не готово. Повтори загрузку.");if(response.Content.Headers.ContentLength>32*1024*1024)throw new IOException("Слишком большой файл");string target=Path.Combine(OfflineRoot,t.id+".m4a");await using(var file=File.Create(target+".tmp")){await using var input=await response.Content.ReadAsStreamAsync();byte[] buffer=new byte[16384];int count;long size=0;while((count=await input.ReadAsync(buffer))>0){size+=count;if(size>32*1024*1024)throw new IOException("Слишком большой файл");await file.WriteAsync(buffer.AsMemory(0,count));}}if(!await Task.Run(()=>ValidAudio(target+".tmp")))throw new IOException("Сервер вернул повреждённое аудио");File.Move(target+".tmp",target,true);File.WriteAllText(Path.Combine(OfflineRoot,t.id+".json"),JsonSerializer.Serialize(t with{LocalPath=target}));added++;}catch{failed++;}}Status.Text=$"Скачано: {added} · уже сохранено: {skip} · ошибок: {failed}";}finally{downloading=false;}}
 void Login(){
  var panel=new StackPanel{Margin=new Thickness(24)};var email=new TextBox{Margin=new Thickness(0,8,0,8)};var password=new PasswordBox();var code=new TextBox{Visibility=Visibility.Collapsed,Margin=new Thickness(0,8,0,8)};var note=Label("Email и пароль");panel.Children.Add(note);panel.Children.Add(email);panel.Children.Add(password);panel.Children.Add(code);
  string challenge="",action="login";var window=Sheet("Войти в Nightwell",panel,420);var login=new Button{Content="Войти"};var register=new Button{Content="Регистрация"};var resend=new Button{Content="Отправить код ещё раз",Visibility=Visibility.Collapsed};panel.Children.Add(login);panel.Children.Add(register);panel.Children.Add(resend);
  async Task Submit(bool create,bool repeatCode=false){login.IsEnabled=register.IsEnabled=resend.IsEnabled=false;try{
   if(challenge.Length==0)action=create?"register":"login";
   object body=challenge.Length==0?new{email=email.Text,password=password.Password,supports_email_codes=true}:repeatCode?new{challenge_id=challenge,resend=true}:new{challenge_id=challenge,code=code.Text.Trim()};
   var response=await api.Request("api/"+action,"POST",body);
   if(response.TryGetProperty("challenge",out var next)&&next.ValueKind==JsonValueKind.Object){challenge=next.GetProperty("id").GetString()!;code.Visibility=resend.Visibility=Visibility.Visible;register.Visibility=Visibility.Collapsed;email.IsEnabled=password.IsEnabled=false;login.Content="Подтвердить код";note.Text="Введи код из письма";return;}
   if(response.TryGetProperty("csrf",out var csrf))api.Csrf=csrf.GetString()??"";window.Close();await LoadAccount();await InitializeMobileFeatures();
  }catch(Exception ex){note.Text=ex.Message;}finally{login.IsEnabled=register.IsEnabled=resend.IsEnabled=true;}}
  login.Click+=async(_,_)=>await Submit(false);register.Click+=async(_,_)=>await Submit(true);resend.Click+=async(_,_)=>await Submit(false,true);
 }
 void Settings(){
 var panel=new StackPanel{Margin=new Thickness(24)};
 panel.Children.Add(new TextBlock{Text="Воспроизведение",FontSize=20,FontWeight=FontWeights.SemiBold});
 var label=new TextBlock{Text=$"Переход между треками · {transition:0.0} с",Margin=new Thickness(0,16,0,0)};
 var slider=new Slider{Minimum=0,Maximum=5,Value=transition,TickFrequency=.1,IsSnapToTickEnabled=true,Margin=new Thickness(0,8,0,16)};
 slider.ValueChanged+=(_,_)=>{transition=slider.Value;label.Text=$"Переход между треками · {transition:0.0} с";SaveSettings();};
 panel.Children.Add(label);panel.Children.Add(slider);
 var downloadToggle=new CheckBox{Content="Автозагрузка избранного",IsChecked=autoDownload,Margin=new Thickness(0,8,0,8)};downloadToggle.Click+=(_,_)=>{autoDownload=downloadToggle.IsChecked==true;SaveMobileSettings();};panel.Children.Add(downloadToggle);
 var lyricsToggle=new CheckBox{Content="Текст в такт",IsChecked=syncLyrics,Margin=new Thickness(0,8,0,8)};lyricsToggle.Click+=(_,_)=>{syncLyrics=lyricsToggle.IsChecked==true;renderedLyric=int.MinValue;SaveMobileSettings();};panel.Children.Add(lyricsToggle);
 var loudLabel=new TextBlock{Text=$"Одинаковая громкость · {normalization}%",Margin=new Thickness(0,8,0,0)};
 var loud=new Slider{Minimum=0,Maximum=100,Value=normalization,TickFrequency=10,IsSnapToTickEnabled=true,Margin=new Thickness(0,8,0,10)};
 loud.ValueChanged+=(_,_)=>{normalization=(int)loud.Value;loudLabel.Text=$"Одинаковая громкость · {normalization}%";SaveSettings();};
 panel.Children.Add(loudLabel);panel.Children.Add(loud);
 panel.Children.Add(new TextBlock{Text="0%: выкл. Чем выше значение, тем сильнее выравниваются тихие и громкие записи. Для применения перезапусти Nightwell Music.",TextWrapping=TextWrapping.Wrap,Foreground=Brushes.LightGray,Margin=new Thickness(0,0,0,18)});
 var w=new Window{Title="Nightwell · Настройки",Width=510,Height=500,Owner=this,Background=new SolidColorBrush(Color.FromRgb(18,21,27)),Content=panel};
 var done=new Button{Content="Готово",HorizontalAlignment=HorizontalAlignment.Right};
 done.Click+=(_,_)=>w.Close();panel.Children.Add(done);w.ShowDialog();
 }
 void SaveSettings(){try{
  Directory.CreateDirectory(NativeAPI.Storage);
  string data=JsonSerializer.Serialize(new{origin,transition,normalization,volume=userVolume});
  _=Task.Run(()=>{try{File.WriteAllText(Path.Combine(NativeAPI.Storage,"settings.json"),data);}catch{}});
 }catch{}}
 void Prompt(string title,string hint,Func<string,Task> run){var panel=new StackPanel{Margin=new Thickness(24)};var value=new TextBox();panel.Children.Add(new TextBlock{Text=hint});panel.Children.Add(value);var button=new Button{Content="Сохранить"};panel.Children.Add(button);var w=new Window{Title=title,Owner=this,Width=420,Height=210,Content=panel};button.Click+=async(_,_)=>{await Guard(()=>run(value.Text));w.Close();};w.ShowDialog();}
}

