using System;
using System.Linq;
using System.IO;
using System.Collections.Generic;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;

namespace Nightwell.Native;

public partial class MainWindow {
 string togetherCode="";
 JsonElement? togetherRoom;
 Window? togetherWindow;
 StackPanel? togetherPanel;
 TextBlock? togetherNotice;
 TextBox? togetherInput;
 bool togetherBusy;
 readonly DispatcherTimer togetherPoll=new(){Interval=TimeSpan.FromMilliseconds(1500)};
 long togetherSuppressUntil;
 int togetherVersion=-1;
 bool TogetherLive=>togetherCode.Length==24;
 bool TogetherMayControl {
  get {
   if(!TogetherLive||account.Length==0||!togetherRoom.HasValue)return false;
   var s=togetherRoom.Value;
   return s.GetProperty("owner").GetString()==account||
          s.GetProperty("allow_control").GetBoolean();
  }
 }
 static string? ParseTogetherCode(string? raw){
  if(string.IsNullOrWhiteSpace(raw))return null;
  raw=raw.Trim();
  if(Uri.TryCreate(raw,UriKind.Absolute,out var uri)){
   if(uri.Scheme!="https"||uri.Host!="music.nightwell.fun")return null;
   string? code=uri.Query.TrimStart('?').Split('&')
    .Select(v=>v.Split('=',2))
    .Where(v=>v.Length==2&&v[0]=="together")
    .Select(v=>Uri.UnescapeDataString(v[1])).FirstOrDefault();
   raw=code??"";
  }
  return System.Text.RegularExpressions.Regex.IsMatch(raw,@"^[A-Za-z0-9_-]{24}$")?raw:null;
 }
 Button TogetherButton(string text,Action click){
  var button=new Button{Content=text,Margin=new Thickness(0,7,0,0),MinHeight=40,
    Background=new SolidColorBrush(Color.FromRgb(46,42,60)),Foreground=Brushes.White};
  button.Click+=(_,_)=>click();return button;
 }
 TextBlock TogetherText(string text,int size=14) =>
  new(){Text=text,Foreground=Brushes.White,FontSize=size,TextWrapping=TextWrapping.Wrap,
   Margin=new Thickness(0,8,0,3)};
 void OpenTogether(){
  if(account.Length==0){Login();return;}
  if(togetherWindow!=null){togetherWindow.Activate();return;}
  togetherPanel=new StackPanel{Margin=new Thickness(22)};
  var scroll=new ScrollViewer{Content=togetherPanel,VerticalScrollBarVisibility=ScrollBarVisibility.Auto};
  togetherWindow=new Window{Title="Nightwell Together",Owner=this,Width=520,Height=650,
   WindowStartupLocation=WindowStartupLocation.CenterOwner,
   Background=new SolidColorBrush(Color.FromRgb(22,22,30)),Content=scroll};
  togetherWindow.Closed+=(_,_)=>{togetherWindow=null;togetherPanel=null;togetherNotice=null;togetherInput=null;};
  RenderTogether();togetherWindow.Show();
 }
 void TogetherMessage(string message){if(togetherNotice!=null)togetherNotice.Text=message;else Status.Text=message;}
 void RenderTogether(){
  if(togetherPanel==null)return;
  togetherPanel.Children.Clear();
  togetherPanel.Children.Add(TogetherText("Слушайте одну музыку на разных устройствах. Приглашение только по ссылке.",13));
  togetherNotice=TogetherText("",12);togetherPanel.Children.Add(togetherNotice);
  if(!TogetherLive){
   togetherPanel.Children.Add(TogetherButton("Создать комнату",()=>_=TogetherCreate()));
   togetherInput=new TextBox{Padding=new Thickness(10),Margin=new Thickness(0,12,0,8),
    Text=ParseTogetherCode(Clipboard.ContainsText()?Clipboard.GetText():"")??""};
   togetherPanel.Children.Add(TogetherText("Код или ссылка приглашения"));
   togetherPanel.Children.Add(togetherInput);
   togetherPanel.Children.Add(TogetherButton("Присоединиться",()=>_=TogetherJoin(togetherInput.Text)));
   return;
  }
  var room=togetherRoom;
  string now="Подключаемся к комнате…",artist="";
  int count=1;
  if(room.HasValue){
   var value=room.Value;
   if(value.TryGetProperty("track",out var track)&&track.ValueKind==JsonValueKind.Object){
    now=track.GetProperty("title").GetString()??"Выбери трек";
    artist=track.GetProperty("artist").GetString()??"";
   }else now="Добавь трек в общую очередь";
   count=value.GetProperty("members").GetArrayLength();
  }
  togetherPanel.Children.Add(TogetherText(now,19));
  if(artist.Length>0)togetherPanel.Children.Add(TogetherText(artist,13));
  togetherPanel.Children.Add(TogetherText($"Участники: {count}/10"));
  togetherPanel.Children.Add(TogetherButton("Скопировать ссылку",()=>{
   Clipboard.SetText("https://music.nightwell.fun/?together="+togetherCode);
   TogetherMessage("Ссылка скопирована");
  }));
  if(TogetherMayControl){
   togetherPanel.Children.Add(TogetherButton(room.HasValue&&room.Value.GetProperty("playing").GetBoolean()?"Пауза":"Воспроизвести",
    ()=>_=TogetherCommand(room.HasValue&&room.Value.GetProperty("playing").GetBoolean()?"pause":"play")));
   togetherPanel.Children.Add(TogetherButton("Предыдущий трек",()=>_=TogetherCommand("previous")));
   togetherPanel.Children.Add(TogetherButton("Следующий трек",()=>_=TogetherCommand("next")));
  }
  togetherPanel.Children.Add(TogetherButton("Добавить текущий трек",()=>_=TogetherQueueCurrent()));
  togetherPanel.Children.Add(TogetherButton("Вернуться к друзьям",()=>{if(togetherRoom.HasValue)TogetherSync(togetherRoom.Value,true);}));
  if(room.HasValue){
   var value=room.Value;
   if(value.GetProperty("owner").GetString()==account){
    var control=new CheckBox{Content="Разрешить управление всем",Foreground=Brushes.White,
     Margin=new Thickness(0,15,0,5),IsChecked=value.GetProperty("allow_control").GetBoolean()};
    control.Click+=(_,_)=>_=TogetherSetting(control.IsChecked==true);
    togetherPanel.Children.Add(control);
   }
   togetherPanel.Children.Add(TogetherText("Участники",16));
   foreach(var member in value.GetProperty("members").EnumerateArray()){
    var name=member.GetProperty("name").GetString()??"Участник";
    if(name.StartsWith("User-"))name="Участник";
    if(member.GetProperty("id").GetString()==value.GetProperty("owner").GetString())name+=" · ведущий";
    togetherPanel.Children.Add(TogetherText(name));
   }
   togetherPanel.Children.Add(TogetherText("Общая очередь",16));
   foreach(var track in value.GetProperty("queue").EnumerateArray().Take(70)){
    var title=(track.GetProperty("artist").GetString()??"")+" · "+(track.GetProperty("title").GetString()??"");
    var id=track.GetProperty("id").GetString()??"";
    if(TogetherMayControl)togetherPanel.Children.Add(TogetherButton("▶ "+title,()=>_=TogetherCommand("track",id)));
    else togetherPanel.Children.Add(TogetherText(title));
   }
  }
  togetherPanel.Children.Add(TogetherButton("Покинуть комнату",()=>_=TogetherLeave()));
 }
 async Task TogetherCreate(){
  try{
   var result=await api.Request("api/together/rooms","POST",new {});
   TogetherActivate(result.GetProperty("room"));
   if(Current!=null)await TogetherCommand("track",Current.id);
  }catch(Exception ex){TogetherMessage(ex.Message);}
 }
 async Task TogetherJoin(string value){
  var code=ParseTogetherCode(value);
  if(code==null){TogetherMessage("Вставь ссылку или код комнаты");return;}
  try{
   var result=await api.Request("api/together/rooms/"+code+"/join","POST",new {});
   TogetherActivate(result.GetProperty("room"));
  }catch(Exception ex){TogetherMessage(ex.Message);}
 }
 void TogetherActivate(JsonElement room){
  togetherRoom=room.Clone();togetherCode=room.GetProperty("code").GetString()??"";
  togetherVersion=-1;
  togetherPoll.Stop();
  togetherPoll.Tick-=TogetherPollTick;
  togetherPoll.Tick+=TogetherPollTick;
  togetherPoll.Start();
  RenderTogether();TogetherSync(room,true);
 }
 async void TogetherPollTick(object? sender,EventArgs args){
  if(togetherBusy||!TogetherLive||account.Length==0)return;
  togetherBusy=true;
  string code=togetherCode;
  try{
   var result=await api.Request("api/together/rooms/"+code);
   if(code!=togetherCode)return;
   var room=result.GetProperty("room");
   togetherRoom=room.Clone();
   TogetherSync(room,false);
   int version=room.GetProperty("version").GetInt32();
   if(version!=togetherVersion){togetherVersion=version;RenderTogether();}
  }catch(Exception){TogetherMessage("Переподключаемся к комнате…");}
  finally{togetherBusy=false;}
 }
 void TogetherSync(JsonElement room,bool force){
  if(!TogetherLive||account.Length==0)return;
  if(!room.TryGetProperty("track",out var song)||song.ValueKind!=JsonValueKind.Object)return;
  var id=song.GetProperty("id").GetString()??"";
  if(id.Length==0)return;
  long now=DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
  long expected=room.GetProperty("position_ms").GetInt64();
  bool remotePlaying=room.GetProperty("playing").GetBoolean();
  if(remotePlaying)expected+=Math.Max(0,now-room.GetProperty("updated_at_ms").GetInt64());
  expected=Math.Max(0,expected);
  bool changed=currentID!=id;
  if(changed){
   togetherSuppressUntil=Environment.TickCount64+4000;
   var list=new List<Track>();
   foreach(var item in room.GetProperty("queue").EnumerateArray()){
    var next=item.Deserialize<Track>();if(next!=null)list.Add(next);
   }
   if(!list.Any(t=>t.id==id)){var t=song.Deserialize<Track>();if(t!=null)list.Insert(0,t);}
   if(list.Count==0)return;
   queue=list;index=queue.FindIndex(t=>t.id==id);wave=false;shuffle=false;
   pendingSeek=expected/1000.0;restorePaused=!remotePlaying;
   PlayCurrent();
  }else if((force||Math.Abs(player.Time-expected)>1500)&&player.Length>0){
   togetherSuppressUntil=Environment.TickCount64+2200;
   player.Time=Math.Min(expected,Math.Max(0,player.Length-200));
  }
  if(remotePlaying&&!player.IsPlaying)player.Play();
  if(!remotePlaying&&player.IsPlaying)player.SetPause(true);
 }
 bool TogetherControl(string action,string? id=null,long? position=null){
  if(!TogetherLive)return false;
  if(!TogetherMayControl){Status.Text="Управление комнатой разрешено только ведущему";return true;}
  if(Environment.TickCount64<togetherSuppressUntil)return true;
  _=TogetherCommand(action,id,position);return true;
 }
 async Task TogetherCommand(string action,string? id=null,long? position=null){
  if(!TogetherMayControl)return;
  try{
   object body=id!=null?new {action,track_id=id}:position.HasValue?new{action,position_ms=position.Value}:(object)new{action};
   await api.Request("api/together/rooms/"+togetherCode+"/command","POST",body);
  }catch(Exception ex){TogetherMessage(ex.Message);}
 }
 async Task TogetherQueueCurrent(){
  if(Current==null){TogetherMessage("Сначала включи трек");return;}
  try{
   await api.Request("api/together/rooms/"+togetherCode+"/queue","POST",new {track_id=Current.id});
  }catch(Exception ex){TogetherMessage(ex.Message);}
 }
 async Task TogetherSetting(bool allow){
  try{await api.Request("api/together/rooms/"+togetherCode+"/settings","POST",new{allow_control=allow});}
  catch(Exception ex){TogetherMessage(ex.Message);}
 }
 async Task TogetherLeave(){
  string code=togetherCode;
  togetherCode="";togetherRoom=null;togetherPoll.Stop();RenderTogether();
  if(code.Length==0)return;
  try{await api.Request("api/together/rooms/"+code+"/leave","POST",new{});}
  catch(Exception ex){TogetherMessage(ex.Message);}
 }
}
