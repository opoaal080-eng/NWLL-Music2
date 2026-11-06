using System.Text.Json;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
namespace Nightwell.Native;
public partial class MainWindow {
 string roomCode="";CancellationTokenSource? roomCancellation;TextBlock? roomNote;
 void TogetherWindow(){
  var panel=new StackPanel{Margin=new Thickness(24)};panel.Children.Add(Label("Слушать вместе"));panel.Children.Add(Label("Создай комнату или вставь ссылку приглашения"));
  var input=new TextBox();panel.Children.Add(input);roomNote=Label(roomCode.Length>0?"Комната подключена":"Нет активной комнаты");panel.Children.Add(roomNote);
  void Add(string text,Func<Task> action){var b=new Button{Content=text};b.Click+=async(_,_)=>{b.IsEnabled=false;try{await Guard(action);}finally{b.IsEnabled=true;}};panel.Children.Add(b);}
  Add("Создать комнату",async()=>{var result=await api.Request("api/together/rooms","POST");await ActivateRoom(result);if(Current!=null)await RoomCommand("track",Current.id);});
  Add("Присоединиться",async()=>{var code=input.Text.Trim();if(Uri.TryCreate(code,UriKind.Absolute,out var uri)){var match=Regex.Match(uri.Query,@"(?:\?|&)together=([A-Za-z0-9_-]{24})(?:&|$)");code=match.Groups[1].Value;}if(!Regex.IsMatch(code,@"^[A-Za-z0-9_-]{24}$"))throw new InvalidOperationException("Вставь ссылку приглашения или код комнаты");await ActivateRoom(await api.Request("api/together/rooms/"+code+"/join","POST"));});
  Add("Скопировать приглашение",()=>{if(roomCode.Length>0)Clipboard.SetText(new Uri(api.Origin,"?together="+roomCode).AbsoluteUri);return Task.CompletedTask;});
  Add("Добавить текущий трек в общую очередь",async()=>{if(roomCode.Length>0&&Current!=null)await api.Request("api/together/rooms/"+roomCode+"/queue","POST",new{track_id=Current.id});});
  Add("Разрешить управление участникам",async()=>{if(roomCode.Length>0)await api.Request("api/together/rooms/"+roomCode+"/settings","POST",new{allow_control=true});});
  Add("Управляет только ведущий",async()=>{if(roomCode.Length>0)await api.Request("api/together/rooms/"+roomCode+"/settings","POST",new{allow_control=false});});
  Add("Выйти из комнаты",async()=>{var code=roomCode;roomCode="";roomCancellation?.Cancel();if(code.Length>0)await api.Request("api/together/rooms/"+code+"/leave","POST");if(roomNote!=null)roomNote.Text="Ты вышел из комнаты";});
  Sheet("Слушать вместе",panel,670);
 }
 async Task ActivateRoom(JsonElement response){
  roomCancellation?.Cancel();roomCode=response.GetProperty("room").GetProperty("code").GetString()!;roomCancellation=CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);await ApplyRoom(response.GetProperty("room"));_=PollRoom(roomCode,roomCancellation.Token);
 }
 async Task PollRoom(string code,CancellationToken token){
  while(!token.IsCancellationRequested&&roomCode==code){try{await Task.Delay(1500,token);var response=await api.Request("api/together/rooms/"+code,cancellation:token);if(roomCode==code)await ApplyRoom(response.GetProperty("room"));}catch(OperationCanceledException){return;}catch{if(roomNote!=null)roomNote.Text="Нет связи с комнатой. Переподключаемся.";}}
 }
 async Task RoomCommand(string action,string? track=null,double? position=null){if(roomCode.Length==0)return;await api.Request("api/together/rooms/"+roomCode+"/command","POST",new{action,track_id=track,position_ms=position.HasValue?(long?)(position.Value*1000):null});await ApplyRoom((await api.Request("api/together/rooms/"+roomCode)).GetProperty("room"));}
 async Task ApplyRoom(JsonElement room){
  if(roomNote!=null)roomNote.Text="Участников: "+room.GetProperty("members").GetArrayLength()+"\n"+string.Join("\n",room.GetProperty("queue").EnumerateArray().Select(t=>t.GetProperty("title").GetString()));
  if(room.GetProperty("track").ValueKind!=JsonValueKind.Object)return;
  var t=room.GetProperty("track").Deserialize<Track>()!;bool playing=room.GetProperty("playing").GetBoolean();long position=room.GetProperty("position_ms").GetInt64();
  if(playing)position+=Math.Max(0,room.GetProperty("server_time_ms").GetInt64()-room.GetProperty("updated_at_ms").GetInt64());
  if(currentID!=t.id){queue=room.GetProperty("queue").Deserialize<List<Track>>()??[];if(!queue.Any(x=>x.id==t.id))queue.Insert(0,t);index=queue.FindIndex(x=>x.id==t.id);pendingSeek=position/1000.0;restorePaused=!playing;PlayCurrent();}
  else if(audioLength>0){long target=position;await AudioCommand(()=>{if(Math.Abs(player.Time-target)>1500)player.Time=target;if(playing&&!player.IsPlaying)player.Play();else if(!playing&&player.IsPlaying)player.SetPause(true);});}
 }
}
