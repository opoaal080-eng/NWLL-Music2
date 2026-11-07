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
