using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Microsoft.Win32;

namespace Nightwell.Native;

public partial class MainWindow {
 string profileNickname="";
 bool premiumVerified;
 string premiumVerifiedOwner="";
 async Task RefreshPremiumNavigationAsync(){
  string owner=account;
  if(owner!=premiumVerifiedOwner){
   premiumVerified=false;
   premiumSortAllowed=false;
   premiumVerifiedOwner=owner;
   PremiumDockButton.Visibility=owner.Length==0?Visibility.Visible:Visibility.Collapsed;
  }
  if(owner.Length==0)return;
  try{
   var result=await api.Request("api/premium/me");
   bool active=result.TryGetProperty("premium",out var premium)&&premium.GetBoolean()
    &&result.TryGetProperty("expires_at",out var expires)
    &&expires.ValueKind==JsonValueKind.Number
    &&expires.GetDouble()>DateTimeOffset.UtcNow.ToUnixTimeSeconds();
   if(owner!=account)return;
   premiumSortAllowed=active;
   premiumVerified=true;
   PremiumDockButton.Visibility=active?Visibility.Collapsed:Visibility.Visible;
  }catch{
   // Keep the last confirmed entitlement, including the hidden Premium tab.
   // A temporary HTTP failure must not rebuild the navigation bar.
  }
 }
 async Task<bool> RegisterAccountDeviceAsync(){
  if(account.Length==0)return true;
  try{
   await api.Request("api/devices/register","POST",new{
    device_id=NativeAPI.DeviceID,platform="windows",name=NativeAPI.DeviceLabel
   });
   return true;
  }catch(IOException error)when(error.Message.Contains("HTTP 404")){
   // The device module has not been installed on an older server yet.
   return true;
  }catch(Exception error){
   Status.Text="Не удалось зарегистрировать устройство: "+error.Message;
   return false;
  }
 }
 void AccountDevicesWindow(){
  if(account.Length==0){Login();return;}
  var panel=new StackPanel{Margin=new Thickness(22,12,22,12)};
  var status=new TextBlock{Text="Загружаем устройства…",TextWrapping=TextWrapping.Wrap,
   Margin=new Thickness(0,0,0,12)};
  panel.Children.Add(status);
  var list=new StackPanel();
  var scroll=new ScrollViewer{Content=list,MaxHeight=390,
   VerticalScrollBarVisibility=ScrollBarVisibility.Auto};
  panel.Children.Add(scroll);
  var window=Sheet("Мои устройства",panel,590,false);
  async Task Reload(){
   try{
    var response=await api.Request("api/devices");
    if(!window.IsVisible)return;
    var count=response.GetProperty("count").GetInt32();
    var limit=response.GetProperty("limit").GetInt32();
    status.Text=$"Подключено: {count} из {limit}";
    list.Children.Clear();
    foreach(var item in response.GetProperty("devices").EnumerateArray()){
     string id=item.GetProperty("id").GetString()??"";
     string name=item.GetProperty("name").GetString()??"Устройство";
     bool current=item.GetProperty("current").GetBoolean();
     bool blocked=item.GetProperty("blocked").GetBoolean();
     var row=new StackPanel{Margin=new Thickness(0,8,0,8)};
     row.Children.Add(new TextBlock{Text=name+(current?" · Это устройство":"")+
       (blocked?" · Недоступно":""),FontWeight=FontWeights.SemiBold,
       TextWrapping=TextWrapping.Wrap});
     var remove=new Button{Content="Отключить устройство",
       Margin=new Thickness(0,6,0,0),
       Style=(Style)FindResource("QuietButton")};
     remove.Click+=async(_,_)=>{
      remove.IsEnabled=false;
      try{
       await api.Request("api/devices/"+Uri.EscapeDataString(id),"DELETE");
       await Reload();
      }catch(Exception error){
       status.Text="Не удалось удалить устройство: "+error.Message;
      }finally{remove.IsEnabled=true;}
     };
     row.Children.Add(remove);
     list.Children.Add(row);
    }
   }catch(Exception error){
    status.Text="Управление устройствами недоступно. Проверь сервер: "+error.Message;
   }
  }
  window.Show();
  _=Reload();
 }
 void ProfileWindow(){
  if(account.Length==0){Login();return;}
  var panel=new StackPanel{Margin=new Thickness(22,12,22,12)};
  AddProfileSettings(panel);
  if(premiumSortAllowed){
   var premium=new Button{Content="✧  Nightwell Premium · Подписка активна",
    Style=(Style)FindResource("QuietButton"),Margin=new Thickness(0,12,0,0)};
   premium.Click+=(_,_)=>PremiumWindow();
   panel.Children.Add(premium);
  }
  var devices=new Button{Content="Мои устройства",Style=(Style)FindResource("QuietButton"),
   Margin=new Thickness(0,12,0,0)};
  devices.Click+=(_,_)=>AccountDevicesWindow();
  panel.Children.Add(devices);
  var logout=new Button{Content="Выйти из аккаунта",
   Style=(Style)FindResource("QuietButton"),Margin=new Thickness(0,14,0,0)};
  panel.Children.Add(logout);
  var window=Sheet("Профиль",panel,570,false);
  logout.Click+=async(_,_)=>{
   logout.IsEnabled=false;
   try{
    await api.Request("api/logout","POST");
    api.Clear();
    await AudioCommand(()=>player.Stop());
    roomCode="";roomCancellation?.Cancel();
    queue=[];catalog=[];likes=[];playlists=[];account="";
    NavigationAvatar.Source=null;profileNickname="";premiumSortAllowed=false;
    PremiumDockButton.Visibility=Visibility.Visible;
    window.Close();Show("Главная");
   }catch(Exception ex){
    Status.Text="Не удалось выйти из аккаунта: "+ex.Message;
   }finally{
    logout.IsEnabled=true;
   }
  };
  window.Show();
 }
 void PremiumWindow(){
  var panel=new StackPanel{Margin=new Thickness(24,14,24,20)};
  panel.Children.Add(Label("Nightwell Premium"));
  var premiumStatus=new TextBlock{
   Text=premiumSortAllowed?"Подписка активна":"Подписка неактивна",
   TextWrapping=TextWrapping.Wrap,Margin=new Thickness(0,14,0,14)
  };
  panel.Children.Add(premiumStatus);
  var manage=new Button{Content="Открыть управление подпиской",
   Style=(Style)FindResource("PrimaryButton")};
  manage.Click+=(_,_)=>{
   try{
    var url=new Uri(api.Origin,"premium.html");
    if(url.Scheme!=Uri.UriSchemeHttps)throw new InvalidOperationException("Требуется HTTPS");
    System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(url.AbsoluteUri){UseShellExecute=true});
   }catch(Exception ex){Status.Text="Не удалось открыть подписку: "+ex.Message;}
  };
  panel.Children.Add(manage);
  var refresh=new Button{Content="Проверить подписку",Margin=new Thickness(0,10,0,0)};
  refresh.Click+=async(_,_)=>{
   refresh.IsEnabled=false;
   try{
    await RefreshPremiumNavigationAsync();
    premiumStatus.Text=premiumSortAllowed?"Подписка активна":"Подписка неактивна";
   }finally{refresh.IsEnabled=true;}
  };
  panel.Children.Add(refresh);
  Sheet("Nightwell Premium",panel,370);
 }
 async Task LoadProfileAsync(TextBox? edit=null){
  if(account.Length==0){NavigationAvatar.Source=null;return;}
  try{
   var profile=await api.Request("api/profile/me");
   profileNickname=profile.TryGetProperty("nickname",out var name)?name.GetString()??"":"";
   if(edit!=null)edit.Text=profileNickname;
   string? path=profile.TryGetProperty("avatar_url",out var value)&&value.ValueKind==JsonValueKind.String?value.GetString():null;
   if(string.IsNullOrWhiteSpace(path)){
    NavigationAvatar.Source=null;
    return;
   }
   if(!Uri.TryCreate(api.Origin,path,out var uri)||uri.Scheme!=Uri.UriSchemeHttps||
      !uri.Authority.Equals(api.Origin.Authority,StringComparison.OrdinalIgnoreCase))return;
   byte[] image=await api.HTTP.GetByteArrayAsync(uri,lifetime.Token);
   if(image.Length>768*1024||image.Length==0)return;
   var bitmap=await Task.Run(()=>{
    var picture=new BitmapImage();
    picture.BeginInit();picture.CacheOption=BitmapCacheOption.OnLoad;
    picture.DecodePixelWidth=128;picture.StreamSource=new MemoryStream(image);
    picture.EndInit();picture.Freeze();
    return picture;
   },lifetime.Token);
   if(account.Length>0)NavigationAvatar.Source=bitmap;
  }catch(Exception){
   // The old server does not have the optional profile endpoints.
  }
 }
 void AddProfileSettings(StackPanel panel){
  var fields=new StackPanel();
  fields.Children.Add(Label("Профиль"));
  var nickname=new TextBox{Text=profileNickname,Tag="Ник, от 2 до 32 символов",
   MaxLength=32,Margin=new Thickness(0,0,0,8)};
  fields.Children.Add(nickname);
  var save=new Button{Content="Сохранить ник",Style=(Style)FindResource("PrimaryButton")};
  save.Click+=async(_,_)=>{
   save.IsEnabled=false;
   try{
    var response=await api.Request("api/profile/me","PUT",
       new{nickname=nickname.Text.Trim()});
    profileNickname=response.GetProperty("nickname").GetString()??"";
    Status.Text="Ник обновлён";
   }catch(Exception error){Status.Text="Не удалось сохранить ник: "+error.Message;}
   finally{save.IsEnabled=true;}
  };
  fields.Children.Add(save);
  var avatar=new Button{Content="Выбрать аватар",Margin=new Thickness(0,10,0,0)};
  avatar.Click+=async(_,_)=>{
   var file=new OpenFileDialog{Filter="Изображения|*.png;*.jpg;*.jpeg;*.webp",Multiselect=false};
   if(file.ShowDialog(this)!=true)return;
   avatar.IsEnabled=false;
   try{
    var source=await File.ReadAllBytesAsync(file.FileName,lifetime.Token);
    if(source.Length>12*1024*1024)throw new IOException("Выбери изображение меньше 12 МБ");
    var jpeg=await Task.Run(()=>{
     using var stream=new MemoryStream(source);
     var bitmap=new BitmapImage();
     bitmap.BeginInit();bitmap.CacheOption=BitmapCacheOption.OnLoad;
     bitmap.DecodePixelWidth=512;bitmap.StreamSource=stream;
     bitmap.EndInit();bitmap.Freeze();
     var encoder=new JpegBitmapEncoder{QualityLevel=72};
     encoder.Frames.Add(BitmapFrame.Create(bitmap));
     using var output=new MemoryStream();encoder.Save(output);return output.ToArray();
    },lifetime.Token);
    if(jpeg.Length>768*1024)throw new IOException("Аватар слишком большой");
    await api.Request("api/profile/avatar","POST",new{
     mime="image/jpeg",avatar_base64=Convert.ToBase64String(jpeg)
    });
    await LoadProfileAsync();
    Status.Text="Аватар обновлён";
   }catch(Exception error){Status.Text="Ошибка аватара: "+error.Message;}
   finally{avatar.IsEnabled=true;}
  };
  fields.Children.Add(avatar);
  panel.Children.Add(SettingsCard(fields));
  _=LoadProfileAsync(nickname);
 }
}
