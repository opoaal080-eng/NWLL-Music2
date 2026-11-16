using System;
using System.Collections.Concurrent;
using System.IO;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Nightwell.Native;

/// <summary>Artwork for any visible track, not only the actively playing item.
/// Recycling-aware: images are bound to their own track and don't display the old row's cover.</summary>
public sealed class NativeArtworkView : Image
{
    public NativeArtworkView()
    {
        Stretch = Stretch.UniformToFill;
        Loaded += (_, _) => RefreshArtwork();
        DataContextChanged += (_, _) => RefreshArtwork();
    }
    void RefreshArtwork()
    {
        if (Application.Current?.MainWindow is MainWindow window)
            window.AssignTrackArtwork(this);
    }
}

public partial class MainWindow
{
    readonly ConcurrentDictionary<string, BitmapSource> artworkThumbs = new();
    readonly ConcurrentDictionary<string, Task<BitmapSource?>> artworkPending = new();
    readonly ConcurrentQueue<string> artworkOrder = new();
    readonly SemaphoreSlim artworkNetworkSlots = new(4, 4);

    internal void AssignTrackArtwork(NativeArtworkView image)
    {
        if (image.DataContext is not Track track || string.IsNullOrWhiteSpace(track.id))
        {
            image.Tag = null;
            image.Source = null;
            return;
        }
        if (track.LocalPath != null && string.IsNullOrEmpty(track.cover_url))
        {
            image.Tag = null;
            image.Source = null;
            return;
        }
        if (api == null || !TryArtworkUri(track, out var uri))
        {
            image.Tag = null;
            image.Source = null;
            return;
        }
        var key = account + "|" + uri.AbsoluteUri;
        if (Equals(image.Tag, key) && image.Source != null) return;
        image.Tag = key;
        image.Source = null;
        if (artworkThumbs.TryGetValue(key, out var hit))
        {
            image.Source = hit;
            return;
        }
        _ = LoadArtworkRowAsync(image, key, uri);
    }

    bool TryArtworkUri(Track track, out Uri uri)
    {
        uri = null!;
        var source = string.IsNullOrWhiteSpace(track.cover_url)
            ? "api/covers/" + Uri.EscapeDataString(track.id)
            : track.cover_url.Trim();
        if (!Uri.TryCreate(api.Origin, source, out var candidate) ||
            candidate.Scheme != Uri.UriSchemeHttps ||
            candidate.UserInfo.Length != 0 ||
            candidate.AbsoluteUri.Length > 4096)
            return false;
        uri = candidate;
        return true;
    }

    async Task LoadArtworkRowAsync(NativeArtworkView image, string key, Uri uri)
    {
        try
        {
            var task = artworkPending.GetOrAdd(key, _ => DownloadArtworkThumbnailAsync(uri));
            var bitmap = await task;
            if (bitmap != null && Equals(image.Tag, key))
                image.Source = bitmap;
            // Once complete, the image belongs to the bounded memory cache.
            if (task.IsCompleted) artworkPending.TryRemove(key, out _);
        }
        catch (Exception) { /* A broken cover must never prevent a track from being displayed. */ }
    }

    async Task<BitmapSource?> DownloadArtworkThumbnailAsync(Uri uri)
    {
        var key = account + "|" + uri.AbsoluteUri;
        if (artworkThumbs.TryGetValue(key, out var hit)) return hit;
        await artworkNetworkSlots.WaitAsync();
        try
        {
            if (artworkThumbs.TryGetValue(key, out hit)) return hit;
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
            timeout.CancelAfter(TimeSpan.FromSeconds(11));
            var client = uri.Authority == api.Origin.Authority ? api.HTTP : artworkHTTP;
            using var request = new HttpRequestMessage(HttpMethod.Get, uri);
            using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token);
            if (!response.IsSuccessStatusCode || response.Content.Headers.ContentLength > 5 * 1024 * 1024)
                return null;
            if (response.Content.Headers.ContentType?.MediaType is not string type ||
                !type.StartsWith("image/", StringComparison.OrdinalIgnoreCase))
                return null;
            await using var input = await response.Content.ReadAsStreamAsync(timeout.Token);
            using var memory = new MemoryStream();
            var buffer = new byte[8192];
            int read;
            while ((read = await input.ReadAsync(buffer, timeout.Token)) > 0)
            {
                if (memory.Length + read > 5 * 1024 * 1024) return null;
                memory.Write(buffer, 0, read);
            }
            var bytes = memory.ToArray();
            if (bytes.Length < 100) return null;
            var decoded = await Task.Run(() =>
            {
                using var file = new MemoryStream(bytes);
                var image = new BitmapImage();
                image.BeginInit();
                image.CacheOption = BitmapCacheOption.OnLoad;
                image.DecodePixelWidth = 160;
                image.StreamSource = file;
                image.EndInit();
                image.Freeze();
                return (BitmapSource)image;
            }, timeout.Token);
            if (artworkThumbs.TryAdd(key, decoded))
            {
                artworkOrder.Enqueue(key);
                while (artworkThumbs.Count > 240 && artworkOrder.TryDequeue(out var oldKey))
                    artworkThumbs.TryRemove(oldKey, out _);
            }
            return decoded;
        }
        catch (OperationCanceledException) { return null; }
        catch (HttpRequestException) { return null; }
        catch (IOException) { return null; }
        catch (Exception) { return null; }
        finally { artworkNetworkSlots.Release(); }
    }
}
