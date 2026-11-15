using System;
using System.IO;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

namespace Nightwell.Native;

// Interactive media must not inherit the long import/offline-transfer deadline.
// These limits bound waiting/failure; the host still has to prepare a real stream.
internal static class MediaRequestPolicy {
 internal static readonly TimeSpan MetadataDeadline = TimeSpan.FromSeconds(12);
 internal static readonly TimeSpan ArtworkDeadline = TimeSpan.FromSeconds(10);
 internal static readonly TimeSpan StreamHeadersDeadline = TimeSpan.FromSeconds(15);
 internal static readonly TimeSpan StreamIdleDeadline = TimeSpan.FromSeconds(20);
 internal const int MaxArtworkBytes = 5 * 1024 * 1024;

 internal static TimeSpan? MetadataTimeout(string path,string method="GET") {
  if(!string.Equals(method,"GET",StringComparison.OrdinalIgnoreCase))return null;
  var clean=path.TrimStart('/');int split=clean.IndexOf('?');
  string route=split<0?clean:clean[..split];
  if(route=="api/artists"||route=="api/artists/profile")return MetadataDeadline;
  if(route!="api/tracks"||split<0)return null;
  foreach(var parameter in clean[(split+1)..].Split('&'))
   if(parameter.StartsWith("q=",StringComparison.Ordinal))return MetadataDeadline;
  return null;
 }

 internal static async Task<byte[]> ReadArtworkAsync(HttpClient client,Uri uri,
     CancellationToken cancellation,TimeSpan? deadline=null) {
  using var budget=CancellationTokenSource.CreateLinkedTokenSource(cancellation);
  budget.CancelAfter(deadline??ArtworkDeadline);
  try {
   using var response=await client.GetAsync(uri,HttpCompletionOption.ResponseHeadersRead,budget.Token).ConfigureAwait(false);
   response.EnsureSuccessStatusCode();
   if(response.Content.Headers.ContentLength>MaxArtworkBytes)throw new IOException("Слишком большая обложка");
   var type=response.Content.Headers.ContentType?.MediaType;
   if(type!=null&&!type.StartsWith("image/",StringComparison.OrdinalIgnoreCase)&&!type.Equals("application/octet-stream",StringComparison.OrdinalIgnoreCase))throw new IOException("Сервер не вернул изображение");
   await using var input=await response.Content.ReadAsStreamAsync(budget.Token).ConfigureAwait(false);
   return await ReadLimitedAsync(input,MaxArtworkBytes,budget.Token).ConfigureAwait(false);
  } catch(OperationCanceledException) when(!cancellation.IsCancellationRequested&&budget.IsCancellationRequested) {
   throw new IOException("Обложка пока недоступна: источник не ответил вовремя");
  }
 }

 internal static async Task<byte[]> ReadLimitedAsync(Stream input,int maxBytes,CancellationToken cancellation) {
  using var output=new MemoryStream();byte[] buffer=new byte[16384];
  while(true) {
   int count=await input.ReadAsync(buffer.AsMemory(),cancellation).ConfigureAwait(false);
   if(count==0)break;
   if(output.Length+count>maxBytes)throw new IOException("Ответ источника слишком большой");
   output.Write(buffer,0,count);
  }
  return output.ToArray();
 }

 // A new idle deadline per chunk permits tracks of any duration. A single total
 // timeout would incorrectly stop healthy playback after a short interval.
 internal static async Task CopyWithIdleTimeoutAsync(Stream input,Stream output,
     CancellationToken cancellation,TimeSpan? idleDeadline=null) {
  byte[] buffer=new byte[32768];
  while(true) {
   using var idle=CancellationTokenSource.CreateLinkedTokenSource(cancellation);
   idle.CancelAfter(idleDeadline??StreamIdleDeadline);
   try {
    int count=await input.ReadAsync(buffer.AsMemory(),idle.Token).ConfigureAwait(false);
    if(count==0)break;
    await output.WriteAsync(buffer.AsMemory(0,count),idle.Token).ConfigureAwait(false);
   } catch(OperationCanceledException) when(!cancellation.IsCancellationRequested&&idle.IsCancellationRequested) {
    throw new IOException("Источник аудио перестал передавать данные");
   }
  }
 }
}
