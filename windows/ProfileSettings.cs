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
 async Task RefreshPremiumNavigationAsync(){
  string owner=account;
  bool active=false;
  try{
   if(owner.Length>0){
    var result=await api.Request("api/premium/me");
    active=result.TryGetProperty("premium",out var premium)&&premium.GetBoolean()
     &&result.TryGetProperty("expires_at",out var expires)
     &&expires.ValueKind==JsonValueKind.Number
     &&expires.GetDouble()>DateTimeOffset.UtcNow.ToUnixTimeSeconds();
   }
  }catch{
   // When the server is unavailable, show the Premium entry instead of claiming access.
  }
  if(owner!=account)return;
  premiumSortAllowed=active;
  PremiumDockButton.Visibility=active?Visibility.Collapsed:Visibility.Visible;
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
