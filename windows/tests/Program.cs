using System.Net;
using System.Net.Http.Headers;
using Nightwell.Native;

static class Tests {
 static void Check(bool condition,string message){if(!condition)throw new Exception(message);}
 static async Task Expect<T>(Func<Task> action,string message)where T:Exception{
  try{await action();}catch(T){return;}throw new Exception(message);
 }
 static async Task Main(){
  Check(MediaRequestPolicy.MetadataTimeout("api/tracks?q=artist")==TimeSpan.FromSeconds(12),"Search metadata needs a bounded deadline");
  Check(MediaRequestPolicy.MetadataTimeout("/api/artists/profile?name=a")==TimeSpan.FromSeconds(12),"Artist profile budget");
  Check(MediaRequestPolicy.MetadataTimeout("api/artists?q=a")!=null,"Artist directory budget");
  Check(MediaRequestPolicy.MetadataTimeout("api/tracks")==null,"Full library must not get a short search deadline");
  Check(MediaRequestPolicy.MetadataTimeout("api/imports/job-1")==null,"Long-running imports retain their existing policy");
  Check(MediaRequestPolicy.MetadataTimeout("api/offline-export/track?download=true")==null,"Offline downloads must not inherit the interactive deadline");
  Check(MediaRequestPolicy.MetadataTimeout("api/tracks?q=x","POST")==null,"Mutations retain their existing policy");
  using(var client=new HttpClient(new FakeHandler(_=>Response(new MemoryStream(new byte[]{1,2,3}))))){
   var bytes=await MediaRequestPolicy.ReadArtworkAsync(client,new Uri("https://example.test/cover"),CancellationToken.None);
   Check(bytes.SequenceEqual(new byte[]{1,2,3}),"Valid artwork body");
  }
  using(var client=new HttpClient(new FakeHandler(_=>Response(new SlowStream(1,2000))))){
   await Expect<IOException>(()=>MediaRequestPolicy.ReadArtworkAsync(client,new Uri("https://example.test/cover"),CancellationToken.None,TimeSpan.FromMilliseconds(40)),"Artwork deadline must include body reading, not only headers");
  }
  using(var client=new HttpClient(new FakeHandler(_=>{var r=Response(new MemoryStream());r.Content.Headers.ContentLength=MediaRequestPolicy.MaxArtworkBytes+1;return r;}))){
   await Expect<IOException>(()=>MediaRequestPolicy.ReadArtworkAsync(client,new Uri("https://example.test/cover"),CancellationToken.None),"Reject oversized artwork before allocation");
  }
  using(var client=new HttpClient(new FakeHandler(_=>{var r=Response(new MemoryStream());r.Content.Headers.ContentType=new MediaTypeHeaderValue("application/json");return r;}))){
   await Expect<IOException>(()=>MediaRequestPolicy.ReadArtworkAsync(client,new Uri("https://example.test/cover"),CancellationToken.None),"Do not accept an API error document as artwork");
  }
  using(var cancelled=new CancellationTokenSource())using(var client=new HttpClient(new FakeHandler(_=>Response(new SlowStream(1,2000))))){
   cancelled.Cancel();
   await Expect<OperationCanceledException>(()=>MediaRequestPolicy.ReadArtworkAsync(client,new Uri("https://example.test/cover"),cancelled.Token),"User cancellation must not become a misleading source timeout");
  }
  await Expect<IOException>(()=>MediaRequestPolicy.ReadLimitedAsync(new MemoryStream(new byte[6]),5,CancellationToken.None),"Bodies without Content-Length still need a size bound");
  using(var output=new MemoryStream()){
   await MediaRequestPolicy.CopyWithIdleTimeoutAsync(new SlowStream(5,100),output,CancellationToken.None,TimeSpan.FromMilliseconds(300));
   Check(output.Length==5,"Healthy audio may run longer than one idle deadline");
  }
  await Expect<IOException>(()=>MediaRequestPolicy.CopyWithIdleTimeoutAsync(new SlowStream(1,2000),new MemoryStream(),CancellationToken.None,TimeSpan.FromMilliseconds(40)),"A stalled first audio byte must not wait minutes");
  Console.WriteLine("Media network budgets, body bounds, cancellation and streaming-idle checks passed.");
 }
 static HttpResponseMessage Response(Stream stream)=>new(HttpStatusCode.OK){Content=new StreamContent(stream){Headers={ContentType=new MediaTypeHeaderValue("image/png")}}};
 sealed class FakeHandler(Func<HttpRequestMessage,HttpResponseMessage> respond):HttpMessageHandler{
  protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken cancellationToken){cancellationToken.ThrowIfCancellationRequested();return Task.FromResult(respond(request));}
 }
 sealed class SlowStream(int chunks,int delay):Stream{
  int remaining=chunks;
  public override async ValueTask<int> ReadAsync(Memory<byte> buffer,CancellationToken cancellationToken=default){
   if(remaining==0)return 0;
   await Task.Delay(delay,cancellationToken);remaining--;buffer.Span[0]=1;return 1;
  }
  public override Task<int> ReadAsync(byte[] buffer,int offset,int count,CancellationToken cancellationToken)=>ReadAsync(buffer.AsMemory(offset,count),cancellationToken).AsTask();
  public override bool CanRead=>true;public override bool CanSeek=>false;public override bool CanWrite=>false;public override long Length=>throw new NotSupportedException();public override long Position{get=>throw new NotSupportedException();set=>throw new NotSupportedException();}
  public override int Read(byte[] buffer,int offset,int count)=>throw new NotSupportedException();public override void Flush()=>throw new NotSupportedException();public override long Seek(long offset,SeekOrigin origin)=>throw new NotSupportedException();public override void SetLength(long value)=>throw new NotSupportedException();public override void Write(byte[] buffer,int offset,int count)=>throw new NotSupportedException();
 }
}
