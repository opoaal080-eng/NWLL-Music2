using System.Buffers;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;

namespace Nightwell.Native;

// A private loopback relay: LibVLC cannot use the app's authenticated HttpClient.
// Only the authenticated audio API endpoints are exposed locally.
public sealed class StreamProxy : IDisposable
{
    readonly HttpListener listener = new();
    readonly NativeAPI api;
    readonly string key = Guid.NewGuid().ToString("N");
    readonly CancellationTokenSource stop = new();
    public string Base { get; }

    public StreamProxy(NativeAPI api)
    {
        this.api = api;
        var probe = new TcpListener(IPAddress.Loopback, 0);
        probe.Start();
        int port = ((IPEndPoint)probe.LocalEndpoint).Port;
        probe.Stop();
        Base = $"http://127.0.0.1:{port}/{key}/";
        listener.Prefixes.Add($"http://127.0.0.1:{port}/");
        listener.Start();
        _ = Serve();
    }

    public string URL(string path) => Base + path.TrimStart('/');

    static bool IsAudioPath(string path)
    {
        // /api/audio-cache holds cached HLS playlists and media segments.
        // Reject path traversal and keep the loopback endpoint narrowly scoped.
        path = path.TrimStart('/');
        if (path.Contains("..", StringComparison.Ordinal) ||
            path.Contains('\\') || path.Contains('%'))
            return false;
        return path.StartsWith("api/audio-quality/stream/", StringComparison.Ordinal) ||
               path.StartsWith("api/stream/", StringComparison.Ordinal) ||
               path.StartsWith("api/soundcloud/media/", StringComparison.Ordinal) ||
               path.StartsWith("api/audio-cache/", StringComparison.Ordinal);
    }

    string Rewrite(string source, string path)
    {
        var baseURI = new Uri(api.Origin, path);
        string ConvertAddress(string value)
        {
            var uri = new Uri(baseURI, value);
            if (uri.Scheme != Uri.UriSchemeHttps ||
                uri.Authority != api.Origin.Authority ||
                !IsAudioPath(uri.AbsolutePath))
                throw new InvalidOperationException("Неизвестный адрес сегмента аудио");
            return URL(uri.PathAndQuery.TrimStart('/'));
        }
        return string.Join("\n", source.Split('\n').Select(line =>
        {
            var trimmed = line.Trim();
            if (trimmed.StartsWith('#'))
                return Regex.Replace(line, "URI=\"([^\"]+)\"", m =>
                    "URI=\"" + ConvertAddress(m.Groups[1].Value) + "\"");
            return trimmed.Length == 0 ? line : ConvertAddress(trimmed);
        }));
    }

    async Task Serve()
    {
        while (listener.IsListening && !stop.IsCancellationRequested)
        {
            try
            {
                var context = await listener.GetContextAsync();
                _ = Handle(context);
            }
            catch (HttpListenerException) { break; }
            catch (ObjectDisposedException) { break; }
        }
    }

    static bool IsApprovedQualityRedirect(Uri url) =>
        url.Scheme == Uri.UriSchemeHttps &&
        url.UserInfo.Length == 0 &&
        url.IsDefaultPort &&
        (url.Host.Equals("playback.media-streaming.soundcloud.cloud", StringComparison.OrdinalIgnoreCase) ||
         url.Host.Equals("cf-hls-media.sndcdn.com", StringComparison.OrdinalIgnoreCase)) &&
        url.AbsolutePath.EndsWith(".m3u8", StringComparison.OrdinalIgnoreCase);

    async Task Handle(HttpListenerContext context)
    {
        try
        {
            string raw = context.Request.RawUrl ?? "";
            string prefix = "/" + key + "/";
            bool head = context.Request.HttpMethod == "HEAD";
            if (!raw.StartsWith(prefix, StringComparison.Ordinal) ||
                (context.Request.HttpMethod != "GET" && !head))
            {
                context.Response.StatusCode = 404;
                return;
            }
            var path = raw[prefix.Length..];
            var resource = path.Split('?', 2)[0];
            if (!IsAudioPath(resource))
            {
                context.Response.StatusCode = 404;
                return;
            }

            using var request = new HttpRequestMessage(head ? HttpMethod.Head : HttpMethod.Get, path);
            if (context.Request.Headers["Range"] is string range)
                request.Headers.TryAddWithoutValidation("Range", range);

            // Do not buffer media in HttpClient. HLS segments can start relaying
            // immediately rather than waiting for the whole source response.
            using var response = await api.HTTP.SendAsync(
                request, HttpCompletionOption.ResponseHeadersRead, stop.Token);

            if ((int)response.StatusCode >= 300 && (int)response.StatusCode < 400)
            {
                Uri? location = response.Headers.Location;
                if (location != null)
                {
                    location = location.IsAbsoluteUri ? location : new Uri(api.Origin, location);
                    if (location.Scheme == Uri.UriSchemeHttps &&
                        location.Authority == api.Origin.Authority &&
                        IsAudioPath(location.AbsolutePath))
                    {
                        context.Response.Redirect(URL(location.PathAndQuery));
                        return;
                    }
                    if (IsApprovedQualityRedirect(location))
                    {
                        // A signed, public SoundCloud HLS rendition. No cookies or
                        // account credentials are passed to the CDN.
                        context.Response.Redirect(location.AbsoluteUri);
                        return;
                    }
                }
                context.Response.StatusCode = 502;
                return;
            }

            context.Response.StatusCode = (int)response.StatusCode;
            context.Response.ContentType =
                response.Content.Headers.ContentType?.ToString() ?? "application/octet-stream";
            if (response.Content.Headers.ContentRange is { } rangeHeader)
                context.Response.Headers["Content-Range"] = rangeHeader.ToString();
            if (response.Headers.AcceptRanges.Count != 0)
                context.Response.Headers["Accept-Ranges"] =
                    string.Join(", ", response.Headers.AcceptRanges);
            if (!response.IsSuccessStatusCode || head)
            {
                if (response.Content.Headers.ContentLength is long size)
                    context.Response.ContentLength64 = size;
                return;
            }

            bool playlist = context.Response.ContentType.Contains(
                "mpegurl", StringComparison.OrdinalIgnoreCase) ||
                resource.EndsWith(".m3u8", StringComparison.OrdinalIgnoreCase);

            if (playlist)
            {
                // Rewriting is necessary for protected cached segments.
                var manifest = await response.Content.ReadAsStringAsync(stop.Token);
                var bytes = Encoding.UTF8.GetBytes(Rewrite(manifest, resource));
                context.Response.ContentType = "application/vnd.apple.mpegurl";
                context.Response.ContentLength64 = bytes.Length;
                await context.Response.OutputStream.WriteAsync(bytes, stop.Token);
            }
            else
            {
                if (response.Content.Headers.ContentLength is long length)
                    context.Response.ContentLength64 = length;
                else context.Response.SendChunked = true;

                await using var input = await response.Content.ReadAsStreamAsync(stop.Token);
                var buffer = ArrayPool<byte>.Shared.Rent(32 * 1024);
                try
                {
                    int read;
                    while ((read = await input.ReadAsync(buffer, stop.Token)) > 0)
                        await context.Response.OutputStream.WriteAsync(
                            buffer.AsMemory(0, read), stop.Token);
                }
                finally { ArrayPool<byte>.Shared.Return(buffer); }
            }
        }
        catch (OperationCanceledException) { }
        catch (HttpListenerException) { }
        catch (IOException) { }
        catch
        {
            try { context.Response.StatusCode = 502; } catch { }
        }
        finally
        {
            try { context.Response.Close(); } catch { }
        }
    }

    public void Dispose()
    {
        stop.Cancel();
        listener.Close();
        stop.Dispose();
    }
}
