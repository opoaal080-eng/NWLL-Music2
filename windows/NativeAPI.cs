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
 public string DeviceToken{get;private set;}="";
 public void ClearDeviceSession()=>DeviceToken="";
 public NativeAPI(string origin){Origin=new Uri(origin);Directory.CreateDirectory(Storage);try{var value=Encoding.UTF8.GetString(ProtectedData.Unprotect(File.ReadAllBytes(Path.Combine(Storage,"session")),null,DataProtectionScope.CurrentUser));var parts=value.Split('\n',2);if(parts.Length==2&&parts[0]==Origin.AbsoluteUri)cookies.SetCookies(Origin,parts[1]);}catch{}HTTP=new HttpClient(new HttpClientHandler{CookieContainer=cookies,AllowAutoRedirect=false}){BaseAddress=Origin,Timeout=TimeSpan.FromSeconds(180)};}
 public async Task<JsonElement> Request(string path,string method="GET",object? body=null,CancellationToken cancellation=default){
  using var budget=CancellationTokenSource.CreateLinkedTokenSource(cancellation);
  if(MediaRequestPolicy.MetadataTimeout(path,method) is TimeSpan deadline)budget.CancelAfter(deadline);
  try{
   using var request=new HttpRequestMessage(new HttpMethod(method),path);
   if(DeviceToken.Length>0)request.Headers.TryAddWithoutValidation("X-NW-Device-Token",DeviceToken);
   if(method!="GET"){request.Headers.Add("X-CSRF-Token",Csrf);request.Content=new StringContent(JsonSerializer.Serialize(body??new{}),Encoding.UTF8,"application/json");}
   using var response=await HTTP.SendAsync(request,budget.Token).ConfigureAwait(false);
   var raw=await response.Content.ReadAsStringAsync(budget.Token).ConfigureAwait(false);
   using var doc=JsonDocument.Parse(raw);
   if(!response.IsSuccessStatusCode)throw new HttpRequestException(doc.RootElement.TryGetProperty("error",out var e)?e.GetString():doc.RootElement.TryGetProperty("detail",out var d)?d.GetString():"Ошибка сервера",null,response.StatusCode);
   if(path is "api/login" or "api/register"){var value=Origin.AbsoluteUri+"\n"+cookies.GetCookieHeader(Origin);File.WriteAllBytes(Path.Combine(Storage,"session"),ProtectedData.Protect(Encoding.UTF8.GetBytes(value),null,DataProtectionScope.CurrentUser));}
   return doc.RootElement.Clone();
  }catch(OperationCanceledException) when(!cancellation.IsCancellationRequested&&budget.IsCancellationRequested){throw new IOException("Сервис не ответил вовремя. Попробуй повторить поиск.");}
 }

 public async Task BindDevice(string account){
  ClearDeviceSession();
  if(string.IsNullOrWhiteSpace(account))return;
  string key=Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(Origin.AbsoluteUri+"|"+account)));
  string file=Path.Combine(Storage,"device-"+key+".dat");
  string? previousId=null, previousToken=null;
  if(File.Exists(file)){
   var raw=ProtectedData.Unprotect(await File.ReadAllBytesAsync(file),null,DataProtectionScope.CurrentUser);
   using var old=JsonDocument.Parse(raw);
   previousId=old.RootElement.GetProperty("device_id").GetString();
   previousToken=old.RootElement.GetProperty("device_token").GetString();
   if(string.IsNullOrWhiteSpace(previousId)||string.IsNullOrWhiteSpace(previousToken))
    throw new IOException("Сохранённый ключ устройства повреждён.");
   DeviceToken=previousToken;
  }
  try{
   var payload=new Dictionary<string,object?>{{"platform","windows"},{"name",Environment.MachineName}};
   if(previousId!=null&&previousToken!=null){
    payload["device_id"]=previousId;
    payload["device_token"]=previousToken;
   }
   var result=await Request("api/devices/register","POST",payload);
   if(!result.GetProperty("ok").GetBoolean())throw new IOException("Сервер не подтвердил устройство.");
   var id=result.GetProperty("device_id").GetString()??throw new IOException("Не указан ID устройства.");
   var token=result.GetProperty("device_token").GetString()??throw new IOException("Не выдан ключ устройства.");
   var bytes=ProtectedData.Protect(Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new{device_id=id,device_token=token})),null,DataProtectionScope.CurrentUser);
   await File.WriteAllBytesAsync(file,bytes);
   DeviceToken=token;
  }catch(HttpRequestException error) when(error.StatusCode==System.Net.HttpStatusCode.NotFound){
   // The account-access module is not deployed on older servers.
   ClearDeviceSession();
  }
 }

 public void Clear(){Csrf="";DeviceToken="";foreach(Cookie c in cookies.GetCookies(Origin))c.Expired=true;try{File.Delete(Path.Combine(Storage,"session"));}catch{}}
 public void Dispose()=>HTTP.Dispose();
}
public sealed record Track {
 [System.Text.Json.Serialization.JsonIgnore] public string DisplayDuration=>double.IsFinite(duration)&&duration>0?$"{(int)duration/60}:{(int)duration%60:00}":"";
 public string id {get;set;}="";public string title{get;set;}="";public string artist{get;set;}="";public string? cover_url{get;set;}public string? source{get;set;}public bool is_remote{get;set;}public double duration{get;set;}public string? LocalPath{get;set;}
}
public sealed record Playlist {public string id{get;set;}="";public string name{get;set;}="";}
