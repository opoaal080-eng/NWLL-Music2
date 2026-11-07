using System.IO;
using System.Net.Http;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using LibVLCSharp.Shared;

namespace Nightwell.Native;
public partial class MainWindow {
 readonly CancellationTokenSource lifetime=new();
 readonly SemaphoreSlim audioGate=new(1,1);
 static readonly HttpClient artworkHTTP=new(){Timeout=TimeSpan.FromSeconds(12)};
 bool qualityReady,nextRequestBusy,sampleBusy,audioPlaying,nextPreparing,tasteLoaded,autoDownload,syncLyrics=true;
 long audioTime,audioLength,lastPrefetch;
 string quality="auto",character="balanced",mood="any",language="any";
 List<string> tasteArtists=[];
 HashSet<string> hiddenTracks=[];
 CancellationTokenSource? nextCancellation;
 string WaveRoute=>tasteLoaded?"api/wave-artists/mix":"api/wave";
 string WaveQuery=>"&character="+character+"&mood="+mood+"&language="+language;
 async Task AudioCommand(Action command){
  try{await audioGate.WaitAsync(lifetime.Token);try{await Task.Run(command,lifetime.Token);}finally{audioGate.Release();}}
  catch(OperationCanceledException){}catch(Exception ex){if(!lifetime.IsCancellationRequested)Status.Text=ex.Message;}
 }
 string StreamPath(Track t)=>t.LocalPath??proxy.URL(
  qualityReady&&(quality=="economy"||quality=="high")&&(t.source=="soundcloud"||t.is_remote)?"api/audio-quality/stream/"+Uri.EscapeDataString(t.id)+"?quality="+quality+"&format=hls":
  "api/stream/"+Uri.EscapeDataString(t.id)+"?cache=1&format="+(t.is_remote||t.source=="soundcloud"?"hls":"file"));
 async Task SafeNext(){
  if(nextPreparing||queue.Count==0)return;
  if(roomCode.Length>0){await RoomCommand("next");return;}
  if(index+1>=queue.Count&&wave)await Refill();
  int next=repeat==2?index:shuffle&&queue.Count>1?ChooseSmartShuffleIndex():index+1;
  if(next>=queue.Count){if(repeat==1)next=0;else return;}
  var track=queue[next];nextPreparing=true;nextCancellation?.Cancel();nextCancellation=CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
  var token=nextCancellation.Token;var expected=currentID;LibVLCSharp.Shared.MediaPlayer? staged=null;
  Status.Text="Готовим следующий трек…";
  try {
   string path=StreamPath(track);
   staged=await Task.Run(()=>{var candidate=new LibVLCSharp.Shared.MediaPlayer(vlc){Mute=true};using var media=new Media(vlc,path,track.LocalPath==null?FromType.FromLocation:FromType.FromPath);candidate.Play(media);return candidate;},token);
   var candidate=staged;
   await Task.Run(async()=>{
    var deadline=DateTime.UtcNow.AddSeconds(25);
    while(candidate.Time<=0){token.ThrowIfCancellationRequested();if(candidate.State==VLCState.Error)throw new IOException("Следующий трек недоступен");if(DateTime.UtcNow>deadline)throw new IOException("Трек пока не готов. Текущий продолжает играть.");await Task.Delay(100,token);}
    candidate.SetPause(true);
   },token);
   token.ThrowIfCancellationRequested();if(currentID!=expected)return;
   var previous=player;player=candidate;staged=null;index=next;
   player.EndReached+=(_,_)=>Dispatcher.InvokeAsync(()=>Advance());
   player.EncounteredError+=(_,_)=>Dispatcher.InvokeAsync(()=>Status.Text="Не удалось воспроизвести трек");
   currentID=track.id;ActiveArtwork=null;PlayingTrackId=currentID;Ribbon.ResetPalette();UpdatePlaybackChrome();TakePlaybackHere();pausedAtMs=0;MiniTitle.Text=FullTitle.Text=track.title;MiniArtist.Text=FullArtist.Text=track.artist;
   lyricsCancellation?.Cancel();currentLyrics=null;lyricsID="";renderedLyric=int.MinValue;
   Cover.Source=MiniCover.Source=null;LyricsPanel.Visibility=Visibility.Collapsed;Cover.Visibility=Visibility.Visible;
   if(Uri.TryCreate(api.Origin,track.cover_url??("api/covers/"+track.id),out var uri)&&uri.Scheme=="https")_=LoadCover(uri,track.id);
   await AudioCommand(()=>{previous.Stop();previous.Dispose();candidate.Volume=(int)(userVolume*100);candidate.Mute=false;candidate.Play();});
   RecordTrackStart();mixRecent.Enqueue(track.id);while(mixRecent.Count>120)mixRecent.Dequeue();Status.Text="";_=Prefetch();
  }finally{if(staged!=null){var unused=staged;_=Task.Run(()=>{unused.Stop();unused.Dispose();});}nextPreparing=false;}
 }
 async Task Prefetch(){
  if(account.Length==0)return;
  var ids=queue.Skip(index+1).Take(12).Where(t=>t.LocalPath==null).Select(t=>t.id).ToArray();
  if(ids.Length==0)return;
  try{await api.Request("api/preload","POST",new{ids,current_id=currentID},lifetime.Token);}catch{}
 }
 async Task InitializeMobileFeatures(){
  StartDeviceSync();
  try{var json=await File.ReadAllTextAsync(Path.Combine(NativeAPI.Storage,"mobile-settings.json"));using var doc=JsonDocument.Parse(json);var d=doc.RootElement;
   quality=d.GetProperty("quality").GetString()??"auto";character=d.GetProperty("character").GetString()??"balanced";mood=d.GetProperty("mood").GetString()??"any";language=d.GetProperty("language").GetString()??"any";
   hiddenTracks=d.GetProperty("hidden").Deserialize<HashSet<string>>()??[];autoDownload=d.GetProperty("autoDownload").GetBoolean();syncLyrics=d.GetProperty("syncLyrics").GetBoolean();
  }catch{}
  if(account.Length==0)return;
  try{await api.Request("api/audio-quality/options",cancellation:lifetime.Token);qualityReady=true;}catch{qualityReady=false;}
  try{var state=await api.Request("api/wave-artists/preferences",cancellation:lifetime.Token);tasteArtists=state.GetProperty("artists").Deserialize<List<string>>()??[];tasteLoaded=true;
   if(!state.GetProperty("configured").GetBoolean())await TasteSettings();
  }catch{}
 }
 readonly SemaphoreSlim settingsGate=new(1,1);
 void SaveMobileSettings(){
  string text=JsonSerializer.Serialize(new{quality,character,mood,language,hidden=hiddenTracks,autoDownload,syncLyrics});
  _=Task.Run(async()=>{await settingsGate.WaitAsync();try{Directory.CreateDirectory(NativeAPI.Storage);await File.WriteAllTextAsync(Path.Combine(NativeAPI.Storage,"mobile-settings.json"),text);}catch{}finally{settingsGate.Release();}});
 }
 Window Sheet(string title,StackPanel panel,int height=570,bool show=true){
  panel.Margin=new Thickness(28);
  var window=new Window{Title="Nightwell · "+title,Width=560,MinWidth=440,Height=Math.Min(height,SystemParameters.WorkArea.Height-40),MaxHeight=SystemParameters.WorkArea.Height-24,Owner=this,ShowInTaskbar=false,WindowStartupLocation=WindowStartupLocation.CenterOwner,Style=(Style)FindResource(typeof(Window)),Content=new ScrollViewer{Content=panel,VerticalScrollBarVisibility=ScrollBarVisibility.Auto,HorizontalScrollBarVisibility=ScrollBarVisibility.Disabled}};
  window.Loaded+=(_,_)=>{if(panel.Children.Count>0&&panel.Children[0] is TextBlock heading){heading.FontSize=24;heading.FontWeight=FontWeights.SemiBold;heading.Margin=new Thickness(0,0,0,8);}};
  if(show)window.Show();return window;
 }
 static TextBlock Label(string text)=>new(){Text=text,FontSize=14,FontWeight=FontWeights.Medium,Margin=new Thickness(0,16,0,8),TextWrapping=TextWrapping.Wrap};
 async Task TasteSettings(){
  if(account.Length==0){Login();return;}
  var panel=new StackPanel{Margin=new Thickness(24)};panel.Children.Add(Label("Настроить подборку"));
  panel.Children.Add(Label("Любимые артисты, по одному в строке"));var artists=new TextBox{Text=string.Join("\n",tasteArtists),AcceptsReturn=true,VerticalContentAlignment=VerticalAlignment.Top,Height=120,VerticalScrollBarVisibility=ScrollBarVisibility.Auto};panel.Children.Add(artists);
  var search=new TextBox{Tag="Имя исполнителя",Margin=new Thickness(0,10,0,4)};panel.Children.Add(search);var results=new WrapPanel();
  var find=new Button{Content="Найти артистов"};panel.Children.Add(find);panel.Children.Add(results);
  find.Click+=async(_,_)=>{find.IsEnabled=false;try{var response=await api.Request("api/wave-artists/suggestions?q="+Uri.EscapeDataString(search.Text)+"&limit=20");results.Children.Clear();foreach(var entry in response.GetProperty("artists").EnumerateArray()){string name=entry.GetProperty("name").GetString()!;var button=new Button{Content="＋ "+name};button.Click+=(_,_)=>{var names=artists.Text.Split('\n',StringSplitOptions.TrimEntries|StringSplitOptions.RemoveEmptyEntries).ToList();if(!names.Contains(name,StringComparer.OrdinalIgnoreCase))names.Add(name);artists.Text=string.Join("\n",names);button.Content="✓ "+name;};results.Children.Add(button);}}catch(Exception ex){Status.Text=ex.Message;}finally{find.IsEnabled=true;}};
  var selected=new List<ComboBox>();
  foreach(var group in new[]{new[]{"Характер","balanced","discover","favorites"},new[]{"Настроение","any","energetic","calm","happy","sad"},new[]{"Язык","any","ru","foreign","instrumental"}}){
   panel.Children.Add(Label(group[0]));var labels=group[0]=="Характер"?new[]{"На мой вкус","Открытия","Избранное"}:group[0]=="Настроение"?new[]{"Любое","Бодрое","Спокойное","Весёлое","Грустное"}:new[]{"Любой","Русский","Иностранный","Без слов"};
   var combo=new ComboBox{ItemsSource=labels,SelectedIndex=Array.IndexOf(group,selected.Count==0?character:selected.Count==1?mood:language)-1,Tag=group.Skip(1).ToArray()};if(combo.SelectedIndex<0)combo.SelectedIndex=0;selected.Add(combo);panel.Children.Add(combo);
  }
  var note=Label("");panel.Children.Add(note);var save=new Button{Content="Сохранить"};panel.Children.Add(save);var window=Sheet("Твой вкус",panel,650);
  save.Click+=async(_,_)=>{save.IsEnabled=false;try{var names=artists.Text.Split('\n',StringSplitOptions.TrimEntries|StringSplitOptions.RemoveEmptyEntries).Distinct(StringComparer.OrdinalIgnoreCase).Take(50).ToArray();await api.Request("api/wave-artists/preferences","PUT",new{artists=names});tasteArtists=names.ToList();tasteLoaded=true;
   character=((string[])selected[0].Tag)[selected[0].SelectedIndex];mood=((string[])selected[1].Tag)[selected[1].SelectedIndex];language=((string[])selected[2].Tag)[selected[2].SelectedIndex];SaveMobileSettings();window.Close();
  }catch(Exception ex){note.Text=ex.Message;}finally{save.IsEnabled=true;}};await Task.CompletedTask;
 }
 void QualityMenu(UIElement owner){var menu=new ContextMenu();foreach(var option in new[]{("Авто","auto"),("Низкое","economy"),("Среднее","standard"),("Высокое","high")}){var item=new MenuItem{Header=option.Item1};item.Click+=(_,_)=>{quality=option.Item2;SaveMobileSettings();Status.Text="Качество: "+option.Item1+". Применится к следующему треку.";};menu.Items.Add(item);}menu.PlacementTarget=owner;menu.IsOpen=true;}
 async void TasteClick(object sender,RoutedEventArgs e)=>await Guard(TasteSettings);
 void CloseLyricsClick(object sender,RoutedEventArgs e){LyricsPanel.Visibility=Visibility.Collapsed;Cover.Visibility=Visibility.Visible;}
 async void CoverLyricsClick(object sender,System.Windows.Input.MouseButtonEventArgs e){if(Current!=null)await Guard(()=>Lyrics(Current));}
 async void FullArtistClick(object sender,System.Windows.Input.MouseButtonEventArgs e){if(Current!=null)await Guard(()=>ArtistProfile(Current.artist));}
 async void SearchPlaylistsClick(object sender,RoutedEventArgs e)=>await Guard(()=>BrowsePlaylists(false,SearchBox.Text));
 async void SearchArtistsClick(object sender,RoutedEventArgs e)=>await Guard(async()=>{var response=await api.Request("api/artists?q="+Uri.EscapeDataString(SearchBox.Text)+"&limit=30");var panel=new StackPanel{Margin=new Thickness(24)};var window=Sheet("Исполнители",panel);foreach(var artist in response.GetProperty("artists").EnumerateArray()){string name=artist.GetProperty("name").GetString()!;var b=new Button{Content=name};b.Click+=async(_,_)=>{window.Close();await Guard(()=>ArtistProfile(name));};panel.Children.Add(b);}});
 async Task ArtistProfile(string credit){
  var names=Regex.Split(credit,@"\s*(?:,|&|feat\.?|ft\.?| x | / )\s*",RegexOptions.IgnoreCase).Where(x=>x.Length>0).ToArray();
  if(names.Length>1){var panel=new StackPanel{Margin=new Thickness(22)};var window=Sheet("Выбери исполнителя",panel,320);foreach(var name in names){var b=new Button{Content=name};b.Click+=async(_,_)=>{window.Close();await Guard(()=>ArtistProfile(name));};panel.Children.Add(b);}return;}
  var response=await api.Request("api/artists/profile?name="+Uri.EscapeDataString(credit));
  Show("Исполнитель");Heading.Text=credit;shown=ParseTracks(response);Tracks.ItemsSource=shown;
  if(response.TryGetProperty("artist",out var artist)&&artist.TryGetProperty("image_url",out var image)&&Uri.TryCreate(image.GetString(),UriKind.Absolute,out var uri)&&uri.Scheme=="https"){
   var panel=new StackPanel{Margin=new Thickness(22)};var picture=new Image{Height=240,Stretch=Stretch.Uniform};panel.Children.Add(picture);panel.Children.Add(Label(credit));Sheet("Исполнитель",panel,360);
   var bytes=await artworkHTTP.GetByteArrayAsync(uri);var bitmap=await Task.Run(()=>{using var stream=new MemoryStream(bytes);var b=new BitmapImage();b.BeginInit();b.CacheOption=BitmapCacheOption.OnLoad;b.DecodePixelWidth=480;b.StreamSource=stream;b.EndInit();b.Freeze();return b;});picture.Source=bitmap;
  }
 }
 async Task BrowsePlaylists(bool daily,string query=""){
  var response=await api.Request(daily?"api/daily-public-playlists":"api/community-playlists?q="+Uri.EscapeDataString(query)+"&limit=30");
  var panel=new StackPanel{Margin=new Thickness(24)};var window=Sheet(daily?"Подборки дня":"Плейлисты в поиске",panel);
  if(!daily){var search=new TextBox{Text=query};panel.Children.Add(search);var button=new Button{Content="Найти"};button.Click+=async(_,_)=>await Guard(async()=>{await BrowsePlaylists(false,search.Text);window.Close();});panel.Children.Add(button);}
  foreach(var value in response.GetProperty("playlists").EnumerateArray()){
   var entry=value.Clone();var id=entry.GetProperty("id").GetString()!;var name=entry.GetProperty("name").GetString()!;
   var open=new Button{Content=name};panel.Children.Add(open);open.Click+=async(_,_)=>await Guard(async()=>{
    var data=entry.TryGetProperty("tracks",out var raw)?raw.Deserialize<List<Track>>()??[]:ParseTracks(await api.Request("api/community-playlists/"+id));
    Show(name);shown=data;Tracks.ItemsSource=data;window.Close();
   });
   var save=new Button{Content="♡ Сохранить в мои плейлисты"};panel.Children.Add(save);save.Click+=async(_,_)=>await Guard(async()=>{save.IsEnabled=false;try{await api.Request((daily?"api/daily-public-playlists/":"api/community-playlists/")+id+"/save","POST",daily?new{track_ids=entry.GetProperty("tracks").Deserialize<List<Track>>()!.Select(t=>t.id).ToArray()}:null);save.Content="Сохранено";await LoadAccount();}catch{save.IsEnabled=true;throw;}});
  }
 }
 string listeningID="",listeningSession=Guid.NewGuid().ToString("N");double listenedSeconds;long lastListenTick=Environment.TickCount64,lastListeningReport;
 void RecordTrackStart(){if(listeningID.Length>0)_=ReportListening(true);listeningID=currentID;listenedSeconds=0;listeningSession=Guid.NewGuid().ToString("N");lastListenTick=Environment.TickCount64;}
 void UpdateListening(){var now=Environment.TickCount64;if(audioPlaying)listenedSeconds+=Math.Clamp((now-lastListenTick)/1000.0,0,1);lastListenTick=now;if(now-lastListeningReport>30000){lastListeningReport=now;_=ReportListening(false);}}
 async Task ReportListening(bool skipped){if(account.Length==0||listeningID.Length==0||listenedSeconds<1)return;var body=new{session_id=listeningSession,track_id=listeningID,seconds=listenedSeconds,skipped};try{await api.Request("api/listening","POST",body,lifetime.Token);}catch{}}
 static bool ValidAudio(string path){try{using var stream=File.OpenRead(path);if(stream.Length<128)return false;Span<byte> header=stackalloc byte[12];if(stream.Read(header)<12)return false;return header[0]==0xff||(header[0]==73&&header[1]==68&&header[2]==51)||System.Text.Encoding.ASCII.GetString(header[4..8])=="ftyp"||System.Text.Encoding.ASCII.GetString(header[..4]) is "OggS" or "fLaC" or "RIFF";}catch{return false;}}
 async Task ContinueHere(){
  var remote=await api.Request("api/playback/state");var id=remote.GetProperty("track_id").GetString();if(string.IsNullOrEmpty(id)){Status.Text="На других устройствах пока ничего не играет";return;}
  var tracks=ParseTracks(await api.Request("api/playback/queue"));int target=tracks.FindIndex(t=>t.id==id);if(target<0)throw new IOException("Трек больше недоступен");
  await api.Request("api/playback/state","PUT",new{device_id=deviceID,revision=remote.GetProperty("revision").GetInt64(),takeover=true,track_id=id,queue=tracks.Select(t=>t.id).ToArray(),position=remote.GetProperty("position").GetDouble(),playing=remote.GetProperty("playing").GetBoolean(),repeat=remote.GetProperty("repeat").GetInt32(),shuffle=remote.GetProperty("shuffle").GetBoolean(),wave=remote.GetProperty("wave").GetBoolean()});
  TakePlaybackHere();queue=tracks;index=target;pendingSeek=remote.GetProperty("position").GetDouble();restorePaused=!remote.GetProperty("playing").GetBoolean();PlayCurrent();
 }
}
