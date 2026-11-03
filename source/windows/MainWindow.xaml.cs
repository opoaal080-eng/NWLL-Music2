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
 NativeAPI api;StreamProxy proxy;readonly LibVLC vlc;readonly LibVLCSharp.Shared.MediaPlayer player;
 readonly DispatcherTimer timer=new(){Interval=TimeSpan.FromMilliseconds(400)};
 int savePending;
 int normalization=0;
 double userVolume=1.0;
 long pausedAtMs;
 bool volumeSettingReady;
 readonly DiscoveryHistory discovery=new();
 CancellationTokenSource? warmNextCancellation;
 Action? refreshQueueView;
 readonly List<string> playedOrder=[];
 int playedCursor=-1;
 sealed record QueueRow(Track Song,int Position,string Display);
 CancellationTokenSource? searchCancellation;List<Track> catalog=[],shown=[],queue=[];List<Playlist> playlists=[];HashSet<string> likes=[];
 string favoriteOrder="recent";bool premiumSortAllowed=false;
 string account="",screen="Главная",playlist="",currentID="";int index,repeat;bool wave,refilling,downloading,scrubbing,shuffle,mixing;readonly Queue<string> mixRecent=new();double transition=.8;long lastPrevious;string previousID="";
 CancellationTokenSource? lyricsCancellation;JsonElement? currentLyrics;string lyricsID="";int renderedLyric=int.MinValue;long savedAt;double? pendingSeek;bool restorePaused;
 sealed record PlaybackState(string Origin,string Account,List<Track> Queue,string ID,double Position,int Repeat,bool Shuffle,bool Wave);
 string ResumeFile=>Path.Combine(NativeAPI.Storage,"resume.json");
 PlaybackState? CapturePlayback()=>Current==null?null:new PlaybackState(origin,account,queue.ToList(),currentID,Math.Max(0,player.Time/1000.0),repeat,shuffle,wave);
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
 public MainWindow(){InitializeComponent();try{
 var prefs=JsonDocument.Parse(File.ReadAllText(Path.Combine(NativeAPI.Storage,"settings.json"))).RootElement;
 if(prefs.TryGetProperty("transition",out var tr))transition=tr.GetDouble();
 if(prefs.TryGetProperty("normalization",out var nl))normalization=Math.Clamp(nl.GetInt32(),0,100);
 if(prefs.TryGetProperty("volume",out var vu)&&vu.TryGetDouble(out var v))userVolume=Math.Clamp(v,0,1);
}catch{}
api=new NativeAPI(origin);proxy=new StreamProxy(api);Core.Initialize();
var audioArgs=new List<string>{"--no-video","--no-xlib"};
if(normalization>0){
 // VLC's native PCM volume normalizer avoids a second decoder and works on HLS and files.
 audioArgs.Add("--audio-filter=normvol");
 audioArgs.Add("--norm-buff-size=20");
 audioArgs.Add("--norm-max-level="+(2.0-1.3*normalization/100.0).ToString(System.Globalization.CultureInfo.InvariantCulture));
}
vlc=new LibVLC(audioArgs.ToArray());player=new LibVLCSharp.Shared.MediaPlayer(vlc);
VolumeSlider.Value=FullVolumeSlider.Value=userVolume*100;
MiniVolumeValue.Text=FullVolumeValue.Text=Math.Round(userVolume*100).ToString("0")+"%";
volumeSettingReady=true;
player.Volume=(int)Math.Round(userVolume*100);player.EndReached+=(_,_)=>Dispatcher.InvokeAsync(()=>Advance());player.EncounteredError+=(_,_)=>Dispatcher.InvokeAsync(()=>Status.Text="Не удалось воспроизвести трек. Проверь подключение и повтори попытку.");timer.Tick+=(_,_)=>Tick();timer.Start();Loaded+=async(_,_)=>{
 if(Environment.GetCommandLineArgs().Contains("--native-smoke")){
  await Task.Delay(1200);var bitmap=new RenderTargetBitmap((int)ActualWidth,(int)ActualHeight,96,96,PixelFormats.Pbgra32);bitmap.Render(this);var encoder=new PngBitmapEncoder();encoder.Frames.Add(BitmapFrame.Create(bitmap));using(var file=File.Create("windows-native-smoke.png"))encoder.Save(file);Close();
 }else {await LoadAccount();await RestorePlaybackAsync();}
};Closed+=(_,_)=>{SavePlayback();timer.Stop();searchCancellation?.Cancel();lyricsCancellation?.Cancel();player.Stop();player.Dispose();vlc.Dispose();proxy.Dispose();api.Dispose();};}
 async Task Guard(Func<Task> action){try{await action();}catch(OperationCanceledException){}catch(Exception e){Status.Text=e.Message;}}
 List<Track> ParseTracks(JsonElement json)=>json.GetProperty("tracks").Deserialize<List<Track>>()??[];
 async Task LoadAccount(){await Guard(async()=>{var me=await api.Request("api/me");api.Csrf=me.GetProperty("csrf").GetString()??"";account=me.GetProperty("user").ValueKind==JsonValueKind.Object?me.GetProperty("user").GetProperty("id").GetString()??"":"";if(account.Length==0){Status.Text="Войди в аккаунт или открой офлайн-файлы";return;}var tasks=await Task.WhenAll(api.Request("api/tracks"),api.Request("api/likes"),api.Request("api/playlists"));catalog=ParseTracks(tasks[0]);likes=tasks[1].GetProperty("ids").Deserialize<HashSet<string>>()??[];playlists=tasks[2].GetProperty("playlists").Deserialize<List<Playlist>>()??[];Status.Text="";if(screen!="Поиск")Show(screen);});}
 void Show(string next){searchCancellation?.Cancel();screen=next;Dock.Visibility=Visibility.Visible;Home.Visibility=next=="Главная"?Visibility.Visible:Visibility.Collapsed;Library.Visibility=next=="Главная"?Visibility.Collapsed:Visibility.Visible;PlayerPage.Visibility=Visibility.Collapsed;Heading.Text=next;SearchBox.Visibility=next=="Поиск"?Visibility.Visible:Visibility.Collapsed;CollectionActions.Visibility=next=="Поиск"?Visibility.Collapsed:Visibility.Visible;if(next=="Поиск"){SearchBox.Focus();shown=[];}else if(next=="Избранное"){shown=catalog.Where(t=>likes.Contains(t.id)).ToList();if(premiumSortAllowed&&favoriteOrder=="title")shown=shown.OrderBy(t=>t.title,StringComparer.CurrentCultureIgnoreCase).ToList();else if(premiumSortAllowed&&favoriteOrder=="artist")shown=shown.OrderBy(t=>t.artist,StringComparer.CurrentCultureIgnoreCase).ToList();}else if(next=="Офлайн"){shown=[];_=LoadOfflineTracksAsync();}Tracks.ItemsSource=shown;if(next=="Плейлисты")ShowPlaylists();}
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

 void MenuClick(object sender,RoutedEventArgs e){var menu=new ContextMenu();foreach(var name in new[]{"Главная","Поиск","Избранное","Плейлисты","Перенести музыку","Сортировка избранного · Premium","Офлайн","Настройки",account.Length==0?"Войти":"Выйти"}){var value=name;var item=new MenuItem{Header=value};item.Click+=async(_,_)=>{if(value=="Сортировка избранного · Premium")await SortFavorites();else if(value=="Перенести музыку")NativeTransfer();else if(value=="Настройки")Settings();else if(value=="Войти")Login();else if(value=="Выйти")await Guard(async()=>{await api.Request("api/logout","POST");api.Clear();player.Stop();queue=[];catalog=[];likes=[];playlists=[];account="";Show("Главная");});else Show(value);};menu.Items.Add(item);}menu.PlacementTarget=(UIElement)sender;menu.IsOpen=true;}
 async void WaveClick(object sender,RoutedEventArgs e)=>await NewWave();
 async Task NewWave(){
  if(mixing)return;
  if(account.Length==0){Login();return;}
  mixing=true;Status.Text="Подбираем новые треки…";
  try{
   await Guard(async()=>{
    string owner=account;
    var heard=discovery.Ids(origin,owner);
    var heardRecordings=discovery.Recordings(origin,owner);
    var excluded=queue.Take(30).Select(t=>t.id).Concat(discovery.Recent(origin,owner,150))
        .Concat(mixRecent.Reverse()).Append(currentID)
        .Where(v=>!string.IsNullOrEmpty(v)).Distinct().Take(190).ToArray();
    var already=new HashSet<string>(queue.Select(t=>t.id));
    var found=new List<Track>();
    for(int attempt=0;attempt<3&&found.Count<15;attempt++){
     var nonce=Guid.NewGuid().ToString("N");
     var result=await api.Request("api/wave?mix="+nonce+
         "&exclude="+Uri.EscapeDataString(string.Join(",",excluded)));
     if(account!=owner)return;
     foreach(var track in ParseTracks(result)){
      if(track.id==currentID||already.Contains(track.id)||heard.Contains(track.id)
          ||heardRecordings.Contains(DiscoveryHistory.Fingerprint(track))||
          found.Any(t=>t.id==track.id))continue;
      found.Add(track);
     }
    }
    if(found.Count==0){
     Status.Text="Свежих треков по этим настройкам пока нет. Измени настройки подборки.";
     return;
    }
    if(shuffle&&found.Count>1){
     var first=found[0];
     found=[first,..found.Skip(1).OrderBy(_=>Random.Shared.Next())];
    }
    queue=found;index=0;wave=true;playedOrder.Clear();playedCursor=-1;refreshQueueView?.Invoke();PlayCurrent();Status.Text="";
   });
  }finally{mixing=false;}
 }

 void VolumeChanged(object sender,RoutedPropertyChangedEventArgs<double> e){
    if(!volumeSettingReady || player==null || sender is not Slider slider)return;
    userVolume=Math.Clamp(slider.Value/100.0,0,1);
    if(!ReferenceEquals(slider,VolumeSlider))VolumeSlider.Value=userVolume*100;
    if(!ReferenceEquals(slider,FullVolumeSlider))FullVolumeSlider.Value=userVolume*100;
    MiniVolumeValue.Text=FullVolumeValue.Text=Math.Round(userVolume*100).ToString("0")+"%";
    ApplyVolume();
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
 void ToggleClick(object sender,RoutedEventArgs e){if(Current==null){_=NewWave();return;}if(player.IsPlaying){pausedAtMs=Math.Max(0,player.Time);player.Pause();}else player.Play();}
 void TrackDoubleClick(object sender,MouseButtonEventArgs e){
  if(Tracks.SelectedItem is Track t){
   queue=shown.ToList();index=queue.FindIndex(v=>v.id==t.id);
   wave=false;playedOrder.Clear();playedCursor=-1;PlayCurrent();
  }
 }
 void PlayCurrent(){var t=Current;if(t==null)return;
   if(playedCursor<0||playedCursor>=playedOrder.Count||playedOrder[playedCursor]!=t.id){
    if(playedCursor+1<playedOrder.Count)
     playedOrder.RemoveRange(playedCursor+1,playedOrder.Count-playedCursor-1);
    playedOrder.Add(t.id);playedCursor=playedOrder.Count-1;
   }
   refreshQueueView?.Invoke();
   pausedAtMs=0;if(t.LocalPath==null&&account.Length==0){Login();return;}string path=t.LocalPath??proxy.URL("api/stream/"+t.id+"?cache=1&format="+(t.is_remote||t.source=="soundcloud"?"hls":"file"));using var media=new Media(vlc,path,t.LocalPath==null?FromType.FromLocation:FromType.FromPath);player.Play(media);lyricsCancellation?.Cancel();currentLyrics=null;lyricsID="";renderedLyric=int.MinValue;currentID=t.id;mixRecent.Enqueue(t.id);while(mixRecent.Count>120)mixRecent.Dequeue();discovery.Remember(origin,account,t);WarmNext();MiniTitle.Text=FullTitle.Text=t.title;MiniArtist.Text=FullArtist.Text=t.artist;LyricsText.Text="";LyricsPanel.Visibility=Visibility.Collapsed;Cover.Visibility=Visibility.Visible;if(t.cover_url!=null&&Uri.TryCreate(api.Origin,t.cover_url,out var coverURI)&&coverURI.Authority==api.Origin.Authority)_=LoadCover(coverURI,t.id);else Cover.Source=MiniCover.Source=null;Dock.BeginAnimation(OpacityProperty,new System.Windows.Media.Animation.DoubleAnimation(.6,1,TimeSpan.FromSeconds(.7)));}
 async Task LoadCover(Uri uri,string id){try{
 var bytes=await api.HTTP.GetByteArrayAsync(uri);
 if(bytes.Length>5*1024*1024||currentID!=id)return;
 var image=await Task.Run(()=>{
  var bitmap=new BitmapImage();
  bitmap.BeginInit();bitmap.CacheOption=BitmapCacheOption.OnLoad;
  bitmap.DecodePixelWidth=650;bitmap.StreamSource=new MemoryStream(bytes);
  bitmap.EndInit();bitmap.Freeze();return bitmap;
 });
 if(currentID==id)Cover.Source=MiniCover.Source=image;
}catch{}}
 void NextClick(object sender,RoutedEventArgs e)=>Advance();
 void PreviousClick(object sender,RoutedEventArgs e){
  if(Current==null)return;
  long now=Environment.TickCount64;
  if(player.Time>3000&&!(previousID==currentID&&now-lastPrevious<3000)){
   lastPrevious=now;previousID=currentID;player.Time=0;return;
  }
  previousID="";
  if(playedCursor>0){
   var previous=playedOrder[--playedCursor];
   int where=queue.FindIndex(t=>t.id==previous);
   if(where>=0){index=where;PlayCurrent();return;}
   playedCursor++;
  }
  if(shuffle)return;
  if(index>0){index--;PlayCurrent();}
 }
 void Advance(){
   if(queue.Count==0)return;
   if(repeat==2){PlayCurrent();return;}
   if(wave&&index+1>=queue.Count){_=Refill();return;}
   // Follow the listened order after Back, then continue the shuffled queue.
   if(playedCursor+1<playedOrder.Count){
    var nextPlayed=playedOrder[++playedCursor];
    int where=queue.FindIndex(t=>t.id==nextPlayed);
    if(where>=0){index=where;PlayCurrent();return;}
    playedCursor--;
   }
   if(index+1<queue.Count)index++;
   else if(repeat==1)index=0;
   else return;
   PlayCurrent();
  }
 async Task Refill(){
  if(refilling||!wave||account.Length==0)return;
  refilling=true;
  try{
   await Guard(async()=>{
    string owner=account;
    var existing=queue.Select(t=>t.id).ToHashSet();
    var heard=discovery.Ids(origin,owner);
    var heardRecordings=discovery.Recordings(origin,owner);
    var exclusions=queue.TakeLast(45).Select(t=>t.id)
        .Concat(discovery.Recent(origin,owner,125))
        .Concat(mixRecent.Reverse())
        .Where(id=>id.Length>0).Distinct().Take(190).ToArray();
    var fresh=new List<Track>();
    for(int attempt=0;attempt<3&&fresh.Count<12;attempt++){
     var value=await api.Request("api/wave?mix="+Guid.NewGuid().ToString("N")+
         "&exclude="+Uri.EscapeDataString(string.Join(",",exclusions)));
     if(!wave||account!=owner)return;
     foreach(var track in ParseTracks(value)){
      if(existing.Contains(track.id)||heard.Contains(track.id)||
         heardRecordings.Contains(DiscoveryHistory.Fingerprint(track))||
         fresh.Any(t=>t.id==track.id))continue;
      fresh.Add(track);
     }
    }
    if(fresh.Count==0){Status.Text="Пока не удалось найти свежие треки, поиск повторится.";return;}
    if(shuffle)fresh=fresh.OrderBy(_=>Random.Shared.Next()).ToList();
    // The queue grows without pruning previously played songs.
    queue.AddRange(fresh);refreshQueueView?.Invoke();
    WarmNext();
    if(!player.IsPlaying&&index+1<queue.Count){index++;PlayCurrent();}
    Status.Text="";
   });
  }finally{refilling=false;}
 }
 void WarmNext(){
  warmNextCancellation?.Cancel();
  warmNextCancellation?.Dispose();
  warmNextCancellation=null;
  if(index+1>=queue.Count||account.Length==0)return;
  var song=queue[index+1];
  if(song.LocalPath!=null)return;
  var cancel=new CancellationTokenSource();warmNextCancellation=cancel;
  _=Task.Run(async()=>{
   try{
    await Task.Delay(1100,cancel.Token);
    if(cancel.IsCancellationRequested)return;
    await api.Request("api/preload","POST",new {ids=new[]{song.id}},cancel.Token);
   }catch(OperationCanceledException){}catch{ /* Prefetch cannot block playback. */ }
  });
 }

 void Tick(){
  if(Current==null)return;
  if(Environment.TickCount64-savedAt>15000){savedAt=Environment.TickCount64;QueueSavePlayback();}
  if(pendingSeek.HasValue&&player.Length>0){
    var target=(long)(Math.Clamp(pendingSeek.Value,0,Math.Max(0,player.Length/1000.0-.2))*1000);
    player.Time=target;pausedAtMs=target;pendingSeek=null;
    if(restorePaused){restorePaused=false;player.SetPause(true);player.Mute=false;}
  }
  bool playing=player.IsPlaying;
  long positionMs=Math.Max(0,player.Time);
  if(playing&&positionMs>0)pausedAtMs=positionMs;
  if(!playing&&positionMs==0&&pausedAtMs>0&&player.Length>0)positionMs=pausedAtMs;
  double duration=Math.Max(1,player.Length/1000.0),position=positionMs/1000.0;
  SyncLyrics();
  MiniLike.Content=likes.Contains(currentID)?"♥":"♡";
  MiniProgress.Width=Math.Max(0,Dock.ActualWidth-22)*Math.Clamp(positionMs/(double)Math.Max(1,player.Length),0,1);
  MiniPlay.Content=HomePlay.Content=FullPlay.Content=playing?"Ⅱ":"▶";
  Ribbon.Playing=playing;
  if(!scrubbing){FullSeek.Maximum=duration;FullSeek.Value=Math.Min(duration,position);}
  FullTime.Text=$"{Time(position)}    /    {Time(duration)}";
  ApplyVolume();
  if(wave&&queue.Count-index<8&&!refilling)_=Refill();
 }
 string Time(double s)=>$"{(int)s/60}:{(int)s%60:00}";
 void SeekStart(object sender,MouseButtonEventArgs e)=>scrubbing=true;
 void SeekEnd(object sender,MouseButtonEventArgs e){player.Time=(long)(FullSeek.Value*1000);scrubbing=false;}
 void ShuffleClick(object sender,RoutedEventArgs e){
  shuffle=!shuffle;
  if(shuffle&&index+2<queue.Count){
   var past=queue.Take(index+1).ToList();
   var upcoming=queue.Skip(index+1).OrderBy(_=>Random.Shared.Next()).ToList();
   queue=[..past,..upcoming];
   refreshQueueView?.Invoke();
  }
  WarmNext();
  Status.Text=shuffle?"Перемешивание включено":"Перемешивание выключено";
 }
 void RepeatClick(object sender,RoutedEventArgs e){repeat=(repeat+1)%3;Status.Text=new[]{"Повтор выключен","Повтор очереди","Повтор трека"}[repeat];}
 void OpenPlayerClick(object sender,MouseButtonEventArgs e){if(Current==null)return;Home.Visibility=Library.Visibility=Dock.Visibility=Visibility.Collapsed;PlayerPage.Visibility=Visibility.Visible;}
 void ClosePlayerClick(object sender,RoutedEventArgs e)=>Show(screen);
 void CurrentMenuClick(object sender,RoutedEventArgs e){if(Current!=null)TrackMenu(Current,(UIElement)sender);}
 void TrackMenuClick(object sender,RoutedEventArgs e){if(sender is Button b&&b.Tag is Track t)TrackMenu(t,b);}
 void TrackMenu(Track t,UIElement owner){var menu=new ContextMenu();void Add(string label,Func<Task> run){var item=new MenuItem{Header=label};item.Click+=async(_,_)=>await Guard(run);menu.Items.Add(item);}Add(likes.Contains(t.id)?"Убрать из избранного":"В избранное",()=>Like(t));Add("Скачать",()=>Download([t]));Add("Поделиться",()=>{Clipboard.SetText(new Uri(api.Origin,"track/"+t.id).AbsoluteUri);Status.Text="Ссылка скопирована";return Task.CompletedTask;});Add("Текст песни",()=>Lyrics(t));var lists=new MenuItem{Header="Добавить в плейлист"};foreach(var p in playlists){var item=new MenuItem{Header=p.name};item.Click+=async(_,_)=>await Guard(async()=>{await api.Request("api/playlists/"+p.id+"/tracks/"+t.id,"POST");});lists.Items.Add(item);}menu.Items.Add(lists);menu.PlacementTarget=owner;menu.IsOpen=true;}
 async void LikeClick(object sender,RoutedEventArgs e){if(Current!=null)await Guard(()=>Like(Current));}
 async Task Like(Track t){if(account.Length==0){Login();return;}bool remove=likes.Contains(t.id);await api.Request("api/likes/"+t.id,remove?"DELETE":"POST");if(remove)likes.Remove(t.id);else likes.Add(t.id);}
 async Task Lyrics(Track t){
  Home.Visibility=Library.Visibility=Visibility.Collapsed;PlayerPage.Visibility=LyricsPanel.Visibility=Visibility.Visible;Cover.Visibility=Visibility.Collapsed;
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
 void SyncLyrics(){if(!currentLyrics.HasValue||lyricsID!=currentID)return;var result=currentLyrics.Value;if(result.TryGetProperty("synced",out var synced)&&synced.GetBoolean()&&result.TryGetProperty("lines",out var lines)){double position=player.Time/1000.0;var all=lines.EnumerateArray().ToArray();int activeIndex=Array.FindLastIndex(all,l=>l.GetProperty("time").GetDouble()<=position);if(renderedLyric==activeIndex)return;renderedLyric=activeIndex;var active=activeIndex>=0?all[activeIndex]:default;LyricsText.Text=string.Join("\n\n",lines.EnumerateArray().Select(l=>(active.ValueKind!=JsonValueKind.Undefined&&l.GetProperty("time").GetDouble()==active.GetProperty("time").GetDouble()?"▶  ":"")+l.GetProperty("text").GetString()));}else LyricsText.Text=result.TryGetProperty("plain",out var plain)?plain.GetString():"Текст пока не найден";}
 void QueueClick(object sender,RoutedEventArgs e){
  var window=new Window{Title="Очередь",Width=620,Height=670,Owner=this,
    Background=new SolidColorBrush(Color.FromRgb(17,17,17))};
  var panel=new DockPanel{Margin=new Thickness(16)};
  var header=new TextBlock{FontSize=18,FontWeight=FontWeights.Bold,
    Foreground=Brushes.White,Margin=new Thickness(8,8,8,16)};
  DockPanel.SetDock(header,Dock.Top);
  panel.Children.Add(header);
  var list=new ListBox{
    Background=new SolidColorBrush(Color.FromRgb(28,28,28)),
    Foreground=Brushes.White,BorderThickness=new Thickness(0),
    DisplayMemberPath="Display"
  };
  System.Windows.Controls.VirtualizingStackPanel.SetIsVirtualizing(list,true);
  System.Windows.Controls.VirtualizingStackPanel.SetVirtualizationMode(list,
    System.Windows.Controls.VirtualizationMode.Recycling);
  ScrollViewer.SetCanContentScroll(list,true);
  void Refresh(){
   var selected=list.SelectedItem as QueueRow;
   var entries=queue.Select((song,i)=>new QueueRow(song,i,
     (i==index?"▶  СЕЙЧАС  ":i<index?"✓  ":"   ")+
     song.title+"  ·  "+song.artist)).ToList();
   header.Text=$"Очередь · {entries.Count} треков · впереди {Math.Max(0,entries.Count-index-1)}";
   list.ItemsSource=entries;
   if(selected!=null)list.SelectedIndex=Math.Min(selected.Position,entries.Count-1);
   else if(index>=0&&index<entries.Count)list.ScrollIntoView(entries[index]);
  }
  refreshQueueView=Refresh;
  window.Closed+=(_,_)=>{refreshQueueView=null;};
  list.MouseDoubleClick+=(_,_)=>{
   if(list.SelectedItem is QueueRow choice){
    index=choice.Position;PlayCurrent();window.Close();
   }
  };
  panel.Children.Add(list);
  window.Content=panel;Refresh();window.ShowDialog();
 }
 void BackgroundClick(object sender,RoutedEventArgs e){Header.Visibility=Dock.Visibility=Visibility.Collapsed;MouseDoubleClick+=RestoreBackground;}
 void RestoreBackground(object sender,MouseButtonEventArgs e){Header.Visibility=Dock.Visibility=Visibility.Visible;MouseDoubleClick-=RestoreBackground;}
 void ShowPlaylists(){var menu=new ContextMenu();foreach(var p in playlists){var item=new MenuItem{Header=p.name};item.Click+=async(_,_)=>await Guard(async()=>{playlist=p.id;screen=p.name;Heading.Text=p.name;shown=ParseTracks(await api.Request("api/playlists/"+p.id+"/tracks"));Tracks.ItemsSource=shown;});menu.Items.Add(item);}var add=new MenuItem{Header="＋ Создать плейлист"};add.Click+=(_,_)=>Prompt("Новый плейлист","Название",async name=>{await api.Request("api/playlists","POST",new{name});await LoadAccount();});menu.Items.Add(add);menu.PlacementTarget=CollectionActions;menu.IsOpen=true;}
 void CollectionClick(object sender,RoutedEventArgs e){if(screen=="Плейлисты"){ShowPlaylists();return;}var menu=new ContextMenu();var get=new MenuItem{Header="Скачать всё"};get.Click+=async(_,_)=>await Download(shown.ToList());menu.Items.Add(get);if(screen=="Офлайн"){var import=new MenuItem{Header="Добавить файлы"};import.Click+=(_,_)=>Import();menu.Items.Add(import);}else{var share=new MenuItem{Header="Поделиться"};share.Click+=async(_,_)=>await Guard(async()=>{var response=await api.Request("api/shares","POST",new{kind=screen=="Избранное"?"likes":"playlist",playlist_id=playlist});Clipboard.SetText(new Uri(api.Origin,response.GetProperty("path").GetString()!).AbsoluteUri);Status.Text="Ссылка скопирована";});menu.Items.Add(share);}menu.PlacementTarget=(UIElement)sender;menu.IsOpen=true;}
 string OfflineRoot=>Path.Combine(NativeAPI.Storage,"offline");
 List<Track> ReadOffline(){Directory.CreateDirectory(OfflineRoot);var result=new List<Track>();foreach(var f in Directory.GetFiles(OfflineRoot,"*.json")){try{var t=JsonSerializer.Deserialize<Track>(File.ReadAllText(f));if(t?.LocalPath!=null&&File.Exists(t.LocalPath))result.Add(t);}catch{}}return result;}
 void Import(){var picker=new OpenFileDialog{Multiselect=true,Filter="Аудиофайлы|*.mp3;*.m4a;*.aac;*.flac;*.wav;*.ogg"};if(picker.ShowDialog()!=true)return;Directory.CreateDirectory(OfflineRoot);foreach(var file in picker.FileNames){string id="local_"+Guid.NewGuid().ToString("N"),target=Path.Combine(OfflineRoot,id+Path.GetExtension(file));File.Copy(file,target);var t=new Track{id=id,title=Path.GetFileNameWithoutExtension(file),artist="На этом устройстве",LocalPath=target};File.WriteAllText(Path.Combine(OfflineRoot,id+".json"),JsonSerializer.Serialize(t));}Show("Офлайн");}
 async Task Download(List<Track> tracks){if(downloading)return;if(account.Length==0){Login();return;}downloading=true;Directory.CreateDirectory(OfflineRoot);int added=0,skip=0,failed=0;try{foreach(var t in tracks){if(t.LocalPath!=null||File.Exists(Path.Combine(OfflineRoot,t.id+".json"))){skip++;continue;}Status.Text=$"Загрузка {added+skip+failed+1} / {tracks.Count}";try{bool ready=false;for(int attempt=0;attempt<100;attempt++){var preparation=await api.Request("api/offline-export/"+t.id);string state=preparation.GetProperty("status").GetString()??"";if(state=="ready"){ready=true;break;}if(state=="error")throw new IOException(preparation.GetProperty("error").GetString());await Task.Delay(3000);}if(!ready)throw new IOException("Подготовка аудио заняла слишком много времени");using var response=await api.HTTP.GetAsync("api/offline-export/"+t.id+"?download=true",System.Net.Http.HttpCompletionOption.ResponseHeadersRead);response.EnsureSuccessStatusCode();if(response.Content.Headers.ContentType?.MediaType?.Contains("json")==true)throw new IOException("Аудио ещё не готово. Повтори загрузку.");if(response.Content.Headers.ContentLength>32*1024*1024)throw new IOException("Слишком большой файл");string target=Path.Combine(OfflineRoot,t.id+".m4a");await using(var file=File.Create(target+".tmp")){await using var input=await response.Content.ReadAsStreamAsync();byte[] buffer=new byte[16384];int count;long size=0;while((count=await input.ReadAsync(buffer))>0){size+=count;if(size>32*1024*1024)throw new IOException("Слишком большой файл");await file.WriteAsync(buffer.AsMemory(0,count));}}File.Move(target+".tmp",target,true);File.WriteAllText(Path.Combine(OfflineRoot,t.id+".json"),JsonSerializer.Serialize(t with{LocalPath=target}));added++;}catch{failed++;}}Status.Text=$"Скачано: {added} · уже сохранено: {skip} · ошибок: {failed}";}finally{downloading=false;}}
 void Login(){var panel=new StackPanel{Margin=new Thickness(24)};var email=new TextBox{Margin=new Thickness(0,10,0,10)};var password=new PasswordBox{Padding=new Thickness(12)};var note=new TextBlock{Text="Email и пароль",Margin=new Thickness(0,0,0,10)};panel.Children.Add(note);panel.Children.Add(email);panel.Children.Add(password);var window=new Window{Title="Войти в Nightwell",Width=440,Height=300,Content=panel,Owner=this,Background=new SolidColorBrush(Color.FromRgb(24,15,35))};foreach(bool register in new[]{false,true}){var button=new Button{Content=register?"Регистрация":"Войти"};button.Click+=async(_,_)=>{button.IsEnabled=false;try{var response=await api.Request(register?"api/register":"api/login","POST",new{email=email.Text,password=password.Password});api.Csrf=response.GetProperty("csrf").GetString()??"";window.Close();await LoadAccount();}catch(Exception e){note.Text=e.Message;}finally{button.IsEnabled=true;}};panel.Children.Add(button);}window.ShowDialog();}
 void Settings(){
 var panel=new StackPanel{Margin=new Thickness(24)};
 panel.Children.Add(new TextBlock{Text="Воспроизведение",FontSize=20,FontWeight=FontWeights.SemiBold});
 var label=new TextBlock{Text=$"Переход между треками · {transition:0.0} с",Margin=new Thickness(0,16,0,0)};
 var slider=new Slider{Minimum=0,Maximum=5,Value=transition,TickFrequency=.1,IsSnapToTickEnabled=true,Margin=new Thickness(0,8,0,16)};
 slider.ValueChanged+=(_,_)=>{transition=slider.Value;label.Text=$"Переход между треками · {transition:0.0} с";SaveSettings();};
 panel.Children.Add(label);panel.Children.Add(slider);
 var loudLabel=new TextBlock{Text=$"Одинаковая громкость · {normalization}%",Margin=new Thickness(0,8,0,0)};
 var loud=new Slider{Minimum=0,Maximum=100,Value=normalization,TickFrequency=10,IsSnapToTickEnabled=true,Margin=new Thickness(0,8,0,10)};
 loud.ValueChanged+=(_,_)=>{normalization=(int)loud.Value;loudLabel.Text=$"Одинаковая громкость · {normalization}%";SaveSettings();};
 panel.Children.Add(loudLabel);panel.Children.Add(loud);
 panel.Children.Add(new TextBlock{Text="0%: выкл. Чем выше значение, тем сильнее выравниваются тихие и громкие записи. Для применения перезапусти Nightwell Music.",TextWrapping=TextWrapping.Wrap,Foreground=Brushes.LightGray,Margin=new Thickness(0,0,0,18)});
 var w=new Window{Title="Nightwell · Настройки",Width=510,Height=370,Owner=this,Background=new SolidColorBrush(Color.FromRgb(18,21,27)),Content=panel};
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
