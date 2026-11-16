using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Security.Cryptography;
using System.IO;

namespace Nightwell.Native;
public sealed class NativeAPI:IDisposable {
 public static readonly string Storage=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"NightwellMusicNative");
 public Uri Origin {get;}
 public HttpClient HTTP {get;}
 readonly CookieContainer cookies=new();
 public string Csrf="";
 string activeAccount = "";
 SavedDevice? currentDevice;
 sealed record SavedDevice(string Origin, string Account, string Id, string Token);
 string DevicePath(string account){
  byte[] hash=SHA256.HashData(Encoding.UTF8.GetBytes(Origin.AbsoluteUri+"|"+account));
  return Path.Combine(Storage,"device-"+Convert.ToHexString(hash)+".bin");
 }
 public void SetDeviceAccount(string account){
  activeAccount=account;
  currentDevice=null;
  HTTP.DefaultRequestHeaders.Remove("X-NW-Device-Token");
  if(string.IsNullOrEmpty(account))return;
  try{
   var data=ProtectedData.Unprotect(File.ReadAllBytes(DevicePath(account)),null,DataProtectionScope.CurrentUser);
   var saved=JsonSerializer.Deserialize<SavedDevice>(data);
   if(saved?.Account==account&&saved.Origin==Origin.AbsoluteUri&&saved.Token.Length>=32){
    currentDevice=saved;HTTP.DefaultRequestHeaders.TryAddWithoutValidation("X-NW-Device-Token",saved.Token);
   }
  }catch{}
 }
 public async Task RegisterWindowsDevice(CancellationToken cancellation=default){
  if(activeAccount.Length==0)return;
  object body=currentDevice==null
   ?new {platform="windows",name=Environment.MachineName}
   :new {platform="windows",name=Environment.MachineName,device_id=currentDevice.Id,device_token=currentDevice.Token};
  JsonElement response=await Request("api/devices/register","POST",body,cancellation);
  string id=response.GetProperty("device_id").GetString()??throw new IOException("Не получен идентификатор устройства");
  string token=response.GetProperty("device_token").GetString()??throw new IOException("Не получен ключ устройства");
  var record=new SavedDevice(Origin.AbsoluteUri,activeAccount,id,token);
  byte[] protectedData=ProtectedData.Protect(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(record)),null,DataProtectionScope.CurrentUser);
  File.WriteAllBytes(DevicePath(activeAccount),protectedData);
  currentDevice=record;
  HTTP.DefaultRequestHeaders.Remove("X-NW-Device-Token");
  HTTP.DefaultRequestHeaders.TryAddWithoutValidation("X-NW-Device-Token",token);
 }
 public NativeAPI(string origin){Origin=new Uri(origin);Directory.CreateDirectory(Storage);try{var value=Encoding.UTF8.GetString(ProtectedData.Unprotect(File.ReadAllBytes(Path.Combine(Storage,"session")),null,DataProtectionScope.CurrentUser));var parts=value.Split('\n',2);if(parts.Length==2&&parts[0]==Origin.AbsoluteUri)cookies.SetCookies(Origin,parts[1]);}catch{}HTTP=new HttpClient(new HttpClientHandler{CookieContainer=cookies,AllowAutoRedirect=false}){BaseAddress=Origin,Timeout=TimeSpan.FromSeconds(180)};}
 public async Task<JsonElement> Request(string path,string method="GET",object? body=null,CancellationToken cancellation=default){using var request=new HttpRequestMessage(new HttpMethod(method),path);if(method!="GET"){request.Headers.Add("X-CSRF-Token",Csrf);request.Content=new StringContent(JsonSerializer.Serialize(body??new{}),Encoding.UTF8,"application/json");}using var response=await HTTP.SendAsync(request,cancellation).ConfigureAwait(false);var raw=await response.Content.ReadAsStringAsync(cancellation).ConfigureAwait(false);using var doc=JsonDocument.Parse(raw);if(!response.IsSuccessStatusCode)throw new IOException(doc.RootElement.TryGetProperty("error",out var e)?e.GetString():"Ошибка сервера");if(path is "api/login" or "api/register"){var value=Origin.AbsoluteUri+"\n"+cookies.GetCookieHeader(Origin);File.WriteAllBytes(Path.Combine(Storage,"session"),ProtectedData.Protect(Encoding.UTF8.GetBytes(value),null,DataProtectionScope.CurrentUser));}return doc.RootElement.Clone();}
 public void Clear(){Csrf="";SetDeviceAccount("");foreach(Cookie c in cookies.GetCookies(Origin))c.Expired=true;try{File.Delete(Path.Combine(Storage,"session"));}catch{}}
 public void Dispose()=>HTTP.Dispose();
}
public sealed record Track {
 [System.Text.Json.Serialization.JsonIgnore] public string DisplayDuration=>double.IsFinite(duration)&&duration>0?$"{(int)duration/60}:{(int)duration%60:00}":"";
 public string id {get;set;}="";public string title{get;set;}="";public string artist{get;set;}="";public string? cover_url{get;set;}public string? source{get;set;}public bool is_remote{get;set;}public double duration{get;set;}public string? LocalPath{get;set;}
}
public sealed record Playlist {public string id{get;set;}="";public string name{get;set;}="";}

