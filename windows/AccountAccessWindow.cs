using System.Net.Http;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace Nightwell.Native;

public partial class MainWindow {
 void AccountAccessWindow(){
  if(account.Length==0){Login();return;}
  var viewer=account;
  var panel=new StackPanel();
  panel.Children.Add(Label("Устройства и семья"));
  var note=new TextBlock{Text="Загружаем данные…",TextWrapping=TextWrapping.Wrap,Margin=new Thickness(0,0,0,12),Foreground=(Brush)FindResource("SecondaryBrush")};
  panel.Children.Add(note);
  var deviceSection=new StackPanel();
  var familySection=new StackPanel();
  panel.Children.Add(deviceSection);
  panel.Children.Add(familySection);
  var refreshButton=new Button{Content="Обновить",Margin=new Thickness(0,14,0,0)};
  panel.Children.Add(refreshButton);
  var window=Sheet("Устройства и семья",panel,720);

  void Action(StackPanel target,string label,Func<Task> run){
   var button=new Button{Content=label,HorizontalAlignment=HorizontalAlignment.Stretch,
    HorizontalContentAlignment=HorizontalAlignment.Left,Margin=new Thickness(0,5,0,0),
    Padding=new Thickness(12,10,12,10)};
   button.Click+=async (_,_)=>{
    button.IsEnabled=false;
    try{await run();}catch(Exception ex){note.Text=ex.Message;}
    finally{button.IsEnabled=true;}
   };
   target.Children.Add(button);
  }
  bool Confirm(string question)=>MessageBox.Show(window,question,"Nightwell Music",
   MessageBoxButton.YesNo,MessageBoxImage.Warning)==MessageBoxResult.Yes;
  async Task Command(string path,string method="POST",object? payload=null){
   await api.Request(path,method,payload);
   await Refresh();
  }
  async Task Refresh(){
   if(account!=viewer||!window.IsVisible)return;
   refreshButton.IsEnabled=false;
   note.Text="Обновляем данные…";
   try{
    var registered=await api.Request("api/devices");
    var status=await api.Request("api/family");
    if(account!=viewer||!window.IsVisible)return;
    deviceSection.Children.Clear();
    familySection.Children.Clear();
    int limit=registered.GetProperty("limit").GetInt32();
    int count=registered.GetProperty("count").GetInt32();
    deviceSection.Children.Add(Label($"Мои устройства · {count} из {limit}"));
    foreach(var device in registered.GetProperty("devices").EnumerateArray()){
     string id=device.GetProperty("id").GetString()??"";
     string name=device.GetProperty("name").GetString()??"Устройство";
     bool current=device.GetProperty("current").GetBoolean();
     bool blocked=device.GetProperty("blocked").GetBoolean();
     string state=blocked?" · заблокировано":current?" · это устройство":"";
     if(current)deviceSection.Children.Add(new TextBlock{
      Text=name+state,Margin=new Thickness(8,9,0,5),TextWrapping=TextWrapping.Wrap});
     else Action(deviceSection,name+state+" · удалить",async()=>{
      if(Confirm("Удалить устройство? На нём понадобится новый вход."))
       await Command("api/devices/"+Uri.EscapeDataString(id),"DELETE");
     });
    }
    var access=status.GetProperty("access");
    string source=access.GetProperty("source").GetString()??"free";
    bool billing=access.GetProperty("billing_owner").GetBoolean();
    familySection.Children.Add(Label("Семейный Premium"));
    familySection.Children.Add(new TextBlock{Text=source=="family"?"Premium через семью":
     source=="direct"?"Личный Premium активен":"Нет активного Premium",
     Margin=new Thickness(8,0,0,10)});
    JsonElement? group=status.TryGetProperty("family",out var family)&&family.ValueKind==JsonValueKind.Object?family:null;
    bool owner=group.HasValue&&(group.Value.GetProperty("role").GetString()=="owner");
    if(group.HasValue){
     var members=group.Value.GetProperty("members");
     familySection.Children.Add(Label($"Участники · {members.GetArrayLength()} из 3"));
     foreach(var member in members.EnumerateArray()){
      string id=member.GetProperty("account_id").GetString()??"";
      string role=member.GetProperty("role").GetString()??"member";
      string title=id==viewer?"Вы":id;
      if(owner&&role!="owner")
       Action(familySection,title+" · исключить",async()=>{
        if(Confirm("Исключить участника из семьи?"))
         await Command("api/family/members/"+Uri.EscapeDataString(id),"DELETE");
       });
      else familySection.Children.Add(new TextBlock{Text=title,Margin=new Thickness(8,7,0,7)});
     }
     if(owner){
      if(group.Value.TryGetProperty("pending_invites",out var pending))
       foreach(var invitation in pending.EnumerateArray()){
        string id=invitation.GetProperty("id").GetString()??"";
        Action(familySection,"Отозвать приглашение",()=>Command("api/family/invitations/"+Uri.EscapeDataString(id),"DELETE"));
       }
      Action(familySection,"Распустить семью",async()=>{
       if(Confirm("Распустить семью? Все участники потеряют семейный доступ."))
        await Command("api/family","DELETE");
      });
     }else{
      Action(familySection,"Выйти из семьи",async()=>{
       if(Confirm("Выйти из семьи?"))await Command("api/family/leave");
      });
     }
    }
    if(billing&&(!group.HasValue||(owner&&group.Value.GetProperty("available_invites").GetInt32()>0)))
     Action(familySection,"Создать приглашение",async()=>{
      var invite=await api.Request("api/family/invitations","POST",new{});
      string url=invite.GetProperty("invite_url").GetString()??"";
      if(!url.StartsWith("https://",StringComparison.Ordinal))throw new IOException("Сервер не вернул ссылку.");
      Clipboard.SetText(url);
      note.Text="Ссылка приглашения скопирована. Передай её только нужному человеку.";
      await Refresh();
      note.Text="Ссылка создана и скопирована в буфер обмена.";
     });
    familySection.Children.Add(Label("Вступить по приглашению"));
    var input=new TextBox{Tag="Ссылка или код приглашения",Margin=new Thickness(0,2,0,6)};
    familySection.Children.Add(input);
    Action(familySection,"Принять приглашение",async()=>{
     string raw=input.Text.Trim();
     int at=raw.IndexOf("#invite=",StringComparison.Ordinal);
     string token=at>=0?raw[(at+8)..]:raw;
     if(!Regex.IsMatch(token,@"^[A-Za-z0-9_-]{43}$"))throw new IOException("Неверная ссылка приглашения.");
     await Command("api/family/invitations/accept","POST",new{token});
     input.Text="";
    });
    note.Text="Каждый аккаунт хранит свои треки и плейлисты отдельно.";
   }catch(Exception ex){note.Text="Не удалось получить данные: "+ex.Message;}
   finally{refreshButton.IsEnabled=true;}
  }
  refreshButton.Click+=async(_,_)=>await Refresh();
  _=Refresh();
 }
}
