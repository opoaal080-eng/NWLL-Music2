using System.IO;
using System.Net.Http;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Nightwell.Native;

public partial class MainWindow {
 readonly Dictionary<string,Task<ImageSource?>> thumbnailTasks=new();
 // Failed/missing covers should not trigger a fresh HTTP request every
 // time a virtualized row scrolls back into view.
 readonly Dictionary<string,DateTime> thumbnailRetryAfter=new();
 readonly SemaphoreSlim thumbnailSlots=new(4,4);

 void TrackThumbnailLoaded(object sender,RoutedEventArgs e){
  if(sender is Image image)_=BindTrackThumbnailAsync(image);
 }
 void TrackThumbnailContextChanged(object sender,DependencyPropertyChangedEventArgs e){
  if(sender is Image image)_=BindTrackThumbnailAsync(image);
 }
 async Task BindTrackThumbnailAsync(Image image){
  image.Source=null;
  if(api==null||lifetime.IsCancellationRequested||image.DataContext is not Track track)return;
  Uri? uri;
  string path=track.cover_url??("api/covers/"+Uri.EscapeDataString(track.id));
  if(!Uri.TryCreate(api.Origin,path,out uri)||uri.Scheme!=Uri.UriSchemeHttps)return;

  if(track.id==currentID&&ActiveArtwork is ImageSource currentArt){
   if(ReferenceEquals(image.DataContext,track))image.Source=currentArt;
   return;
  }
  string key=uri.AbsoluteUri;
  if(thumbnailRetryAfter.TryGetValue(key,out var retryAt)){
   if(DateTime.UtcNow<retryAt)return;
   thumbnailRetryAfter.Remove(key);
   thumbnailTasks.Remove(key);
  }
  if(!thumbnailTasks.TryGetValue(key,out var task)){
   if(thumbnailTasks.Count>=256){
    foreach(var old in thumbnailTasks.Where(pair=>pair.Value.IsCompleted)
      .Take(40).Select(pair=>pair.Key).ToArray()){
     thumbnailTasks.Remove(old);
     thumbnailRetryAfter.Remove(old);
    }
   }
   task=FetchThumbnailAsync(uri);
   thumbnailTasks[key]=task;
  }
  var bitmap=await task;
  if(thumbnailTasks.TryGetValue(key,out var pending)&&ReferenceEquals(pending,task)){
   if(bitmap==null)thumbnailRetryAfter[key]=DateTime.UtcNow.AddSeconds(25);
   else thumbnailRetryAfter.Remove(key);
  }
  if(ReferenceEquals(image.DataContext,track))image.Source=bitmap;
 }
 async Task<ImageSource?> FetchThumbnailAsync(Uri uri){
  try{
   await thumbnailSlots.WaitAsync(lifetime.Token);
   try{
    using var timeout=CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
    timeout.CancelAfter(TimeSpan.FromSeconds(15));
    var http=uri.Authority==api.Origin.Authority?api.HTTP:artworkHTTP;
    using var response=await http.GetAsync(uri,HttpCompletionOption.ResponseHeadersRead,timeout.Token);
    if(!response.IsSuccessStatusCode||response.Content.Headers.ContentLength>6*1024*1024)return null;
    var bytes=await response.Content.ReadAsByteArrayAsync(timeout.Token);
    if(bytes.Length==0||bytes.Length>6*1024*1024)return null;
    return await Task.Run<ImageSource>(() => {
     using var memory=new MemoryStream(bytes);
     var image=new BitmapImage();
     image.BeginInit();
     image.CacheOption=BitmapCacheOption.OnLoad;
     image.DecodePixelWidth=96;
     image.StreamSource=memory;
     image.EndInit();
     image.Freeze();
     return image;
    },timeout.Token);
   }finally{thumbnailSlots.Release();}
  }catch(OperationCanceledException){return null;}
   catch(HttpRequestException){return null;}
   catch(Exception){return null;}
 }
}
