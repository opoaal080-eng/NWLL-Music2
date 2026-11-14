using System.Net;
using System.Net.Http;
using System.Text;
using System.Text.Json;
using System.Security.Cryptography;
using System.IO;

namespace Nightwell.Native;
public sealed class NativeAPI:IDisposable {
 public static readonly string Storage=Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),"NightwellMusicNative");
 public static readonly string DeviceID=LoadDeviceID();
 static string LoadDeviceID(){
  Directory.CreateDirectory(Storage);
  var path=Path.Combine(Storage,"device-id.dat");
  try{
   var data=ProtectedData.Unprotect(File.ReadAllBytes(path),null,DataProtectionScope.CurrentUser);
   var value=Encoding.UTF8.GetString(data);
   if(System.Text.RegularExpressions.Regex.IsMatch(value,@"^windows-[a-f0-9]{32}$"))return value;
  }catch{}
  var created="windows-"+Guid.NewGuid().ToString("N");
  File.WriteAllBytes(path,ProtectedData.Protect(Encoding.UTF8.GetBytes(created),
      null,DataProtectionScope.CurrentUser));
  return created;
 }
 public static string DeviceLabel=Environment.MachineName.Length>80
     ?Environment.MachineName[..80]:Environment.MachineName;
 public Uri Origin {get;}
 public HttpClient HTTP {get;}
 readonly CookieContainer cookies=new();
 public string Csrf="";
 public NativeAPI(string origin){Origin=new Uri(origin);Directory.CreateDirectory(Storage);try{var value=Encoding.UTF8.GetString(ProtectedData.Unprotect(File.ReadAllBytes(Path.Combine(Storage,"session")),null,DataProtectionScope.CurrentUser));var parts=value.Split('\n',2);if(parts.Length==2&&parts[0]==Origin.AbsoluteUri)cookies.SetCookies(Origin,parts[1]);}catch{}HTTP=new HttpClient(new HttpClientHandler{CookieContainer=cookies,AllowAutoRedirect=false}){BaseAddress=Origin,Timeout=TimeSpan.FromSeconds(180)};HTTP.DefaultRequestHeaders.Add("X-NW-Device-ID",DeviceID);HTTP.DefaultRequestHeaders.Add("X-NW-Device-Platform","windows");}
 public async Task<JsonElement> Request(string path,string method="GET",object? body=null,CancellationToken cancellation=default){
  // Keep the shared HttpClient's longer timeout for streaming downloads.
  // Small JSON calls must not hang the library UI for three minutes.
  using var deadline=CancellationTokenSource.CreateLinkedTokenSource(cancellation);
  deadline.CancelAfter(path.StartsWith("api/offline-export/",StringComparison.Ordinal)?TimeSpan.FromSeconds(45):
      path.StartsWith("api/tracks",StringComparison.Ordinal)?TimeSpan.FromSeconds(30):
      TimeSpan.FromSeconds(22));
  using var request=new HttpRequestMessage(new HttpMethod(method),path);
  if(method!="GET"){
    request.Headers.Add("X-CSRF-Token",Csrf);
    request.Content=new StringContent(JsonSerializer.Serialize(body??new{}),Encoding.UTF8,"application/json");
  }
  using var response=await HTTP.SendAsync(request,deadline.Token).ConfigureAwait(false);
  var raw=await response.Content.ReadAsStringAsync(deadline.Token).ConfigureAwait(false);
  // POST/DELETE may validly return HTTP 204 or an empty body.
  if(!response.IsSuccessStatusCode){
    string message="Ошибка сервера: HTTP "+(int)response.StatusCode;
    if(!string.IsNullOrWhiteSpace(raw)){
      try {
        using var errorDoc=JsonDocument.Parse(raw);
        if(errorDoc.RootElement.TryGetProperty("error",out var e))message=e.GetString()??message;
      }catch(JsonException){}
    }
    throw new IOException(message);
  }
  JsonElement value;
  if(string.IsNullOrWhiteSpace(raw)){
    using var empty=JsonDocument.Parse("{}");
    value=empty.RootElement.Clone();
  }else{
    using var doc=JsonDocument.Parse(raw);
    value=doc.RootElement.Clone();
  }
  if(path is "api/login" or "api/register"){
    var cookie=Origin.AbsoluteUri+"\n"+cookies.GetCookieHeader(Origin);
    File.WriteAllBytes(Path.Combine(Storage,"session"),
      ProtectedData.Protect(Encoding.UTF8.GetBytes(cookie),null,DataProtectionScope.CurrentUser));
  }
  return value;
 }
 public void Clear(){Csrf="";foreach(Cookie c in cookies.GetCookies(Origin))c.Expired=true;try{File.Delete(Path.Combine(Storage,"session"));}catch{}}
 public void Dispose()=>HTTP.Dispose();
}
public sealed record Track {
 [System.Text.Json.Serialization.JsonIgnore] public string DisplayDuration=>double.IsFinite(duration)&&duration>0?$"{(int)duration/60}:{(int)duration%60:00}":"";
 public string id {get;set;}="";public string title{get;set;}="";public string artist{get;set;}="";public string? album{get;set;}public string? cover_url{get;set;}public string? source{get;set;}public string? source_url{get;set;}public bool is_remote{get;set;}public double duration{get;set;}public string? LocalPath{get;set;}
}
public sealed record Playlist {public string id{get;set;}="";public string name{get;set;}="";}

