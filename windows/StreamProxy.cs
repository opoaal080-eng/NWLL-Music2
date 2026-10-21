using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
namespace Nightwell.Native;
// Only authenticated audio endpoints are proxied; HTML and arbitrary URLs are rejected.
public sealed class StreamProxy:IDisposable {
 readonly HttpListener listener=new();readonly NativeAPI api;readonly string key=Guid.NewGuid().ToString("N");
 public string Base{get;}
 public StreamProxy(NativeAPI api){this.api=api;var probe=new TcpListener(IPAddress.Loopback,0);probe.Start();int port=((IPEndPoint)probe.LocalEndpoint).Port;probe.Stop();Base=$"http://127.0.0.1:{port}/{key}/";listener.Prefixes.Add($"http://127.0.0.1:{port}/");listener.Start();_=Serve();}
 public string URL(string path)=>Base+path.TrimStart('/');
 async Task Serve(){while(listener.IsListening){try{var c=await listener.GetContextAsync();_=Handle(c);}catch{break;}}}
 string Rewrite(string source,string path){
  var baseURI=new Uri(api.Origin,path);
  string Convert(string value){var uri=new Uri(baseURI,value);if(uri.Scheme!="https"||uri.Authority!=api.Origin.Authority||!(uri.AbsolutePath.StartsWith("/api/stream/")||uri.AbsolutePath.StartsWith("/api/soundcloud/media/")))throw new InvalidOperationException("Неизвестный адрес аудио");return URL(uri.PathAndQuery);}
  return string.Join("\n",source.Split('\n').Select(line=>{var trimmed=line.Trim();if(trimmed.StartsWith('#'))return Regex.Replace(line,"URI=\"([^\"]+)\"",m=>"URI=\""+Convert(m.Groups[1].Value)+"\"");return trimmed.Length==0?line:Convert(trimmed);}));
 }
 async Task Handle(HttpListenerContext context){try{
  var path=context.Request.RawUrl??"";string prefix="/"+key+"/";
  if(!path.StartsWith(prefix)||context.Request.HttpMethod!="GET"){context.Response.StatusCode=404;return;}path=path[prefix.Length..];
  if(!(path.StartsWith("api/stream/")||path.StartsWith("api/soundcloud/media/"))||path.Contains("..")){context.Response.StatusCode=404;return;}
  using var request=new HttpRequestMessage(HttpMethod.Get,path);if(context.Request.Headers["Range"] is string range)request.Headers.TryAddWithoutValidation("Range",range);
  using var response=await api.HTTP.SendAsync(request,HttpCompletionOption.ResponseHeadersRead);
  context.Response.StatusCode=(int)response.StatusCode;context.Response.ContentType=response.Content.Headers.ContentType?.ToString()??"application/octet-stream";
  if(response.Content.Headers.ContentRange!=null)context.Response.Headers["Content-Range"]=response.Content.Headers.ContentRange.ToString();
  if(context.Response.ContentType.Contains("mpegurl",StringComparison.OrdinalIgnoreCase)){
    var text=await response.Content.ReadAsStringAsync();var bytes=Encoding.UTF8.GetBytes(Rewrite(text,path));context.Response.ContentLength64=bytes.Length;await context.Response.OutputStream.WriteAsync(bytes);
  }else{if(response.Content.Headers.ContentLength is long length)context.Response.ContentLength64=length;await response.Content.CopyToAsync(context.Response.OutputStream);}
 }catch{try{context.Response.StatusCode=502;}catch{}}finally{try{context.Response.Close();}catch{}}}
 public void Dispose(){listener.Close();}
}
