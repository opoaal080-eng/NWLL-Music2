using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Threading;

namespace Nightwell.Native;

public partial class MainWindow
{
    int desiredVolume = -1;
    int appliedVolume = -1;
    int volumeWorkerRunning;
    int lastKnownVolume = -1;

    // Calculate transitions from the last playback sample, never from a native
    // LibVLC getter on the WPF thread. Many callers used to queue a separate
    // native command every 400 ms even when the effective volume was unchanged.
    void ScheduleVolumeUpdate()
    {
        if (player == null || lifetime.IsCancellationRequested || IsDesignPreview) return;
        double gain = 1;
        if (transition > 0 && audioPlaying)
        {
            double seconds = Math.Max(0, audioTime / 1000.0);
            double duration = Math.Max(0, audioLength / 1000.0);
            double span = duration > .2 ? Math.Min(transition, duration / 4) : transition;
            if (span > 0)
            {
                gain = Math.Clamp(seconds / span, 0, 1);
                if (duration > .2 && (index + 1 < queue.Count || wave || repeat > 0))
                    gain = Math.Min(gain, Math.Clamp((duration - seconds) / span, 0, 1));
            }
        }
        var target = (int)Math.Round(100 * Math.Clamp(userVolume * gain, 0, 1));
        Volatile.Write(ref desiredVolume, target);
        if (target == Volatile.Read(ref appliedVolume)) return;
        if (Interlocked.CompareExchange(ref volumeWorkerRunning, 1, 0) == 0)
            _ = FlushVolumeAsync();
    }

    async Task FlushVolumeAsync()
    {
        try
        {
            while (!lifetime.IsCancellationRequested)
            {
                int target = Volatile.Read(ref desiredVolume);
                if (target == Volatile.Read(ref appliedVolume)) break;
                await audioGate.WaitAsync(lifetime.Token);
                try
                {
                    // Serialize all LibVLC access with playback commands.
                    await Task.Run(() =>
                    {
                        var active = player;
                        if (active == null) return;
                        if (lastKnownVolume != target)
                        {
                            active.Volume = target;
                            lastKnownVolume = target;
                        }
                    }, lifetime.Token);
                    Volatile.Write(ref appliedVolume, target);
                }
                finally { audioGate.Release(); }
                if (target == Volatile.Read(ref desiredVolume)) break;
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            Volatile.Write(ref appliedVolume, Volatile.Read(ref desiredVolume));
            _ = Task.Run(() => AppendResponsivenessLog("Audio volume command: " + ex.GetType().Name));
        }
        finally
        {
            Interlocked.Exchange(ref volumeWorkerRunning, 0);
            if (!lifetime.IsCancellationRequested &&
                Volatile.Read(ref desiredVolume) != Volatile.Read(ref appliedVolume) &&
                Interlocked.CompareExchange(ref volumeWorkerRunning, 1, 0) == 0)
                _ = FlushVolumeAsync();
        }
    }

    // The monitor is diagnostic only. It does not call native audio functions,
    // touches no UI elements from a worker, and never blocks the dispatcher.
    void StartResponsivenessMonitor()
    {
        if (IsDesignPreview || Environment.GetCommandLineArgs().Contains("--native-smoke")) return;
        _ = MonitorDispatcherAsync();
    }

    async Task MonitorDispatcherAsync()
    {
        while (!lifetime.IsCancellationRequested)
        {
            try
            {
                await Task.Delay(2500, lifetime.Token).ConfigureAwait(false);
                long queued = Stopwatch.GetTimestamp();
                await Dispatcher.InvokeAsync(() =>
                {
                    long lagMs = (long)(Stopwatch.GetElapsedTime(queued).TotalMilliseconds);
                    if (lagMs < 1500) return;
                    string view = PlayerPage.IsVisible ? "player" :
                        Library.IsVisible ? "library" : "home";
                    _ = Task.Run(() => AppendResponsivenessLog(
                        $"UI pause {lagMs}ms; view={view}; active_audio={audioPlaying}; tracks={shown.Count}"));
                }, DispatcherPriority.Background).Task;
            }
            catch (OperationCanceledException) { break; }
            catch { if (lifetime.IsCancellationRequested) break; }
        }
    }

    static readonly object diagnosticsGate = new();
    static void AppendResponsivenessLog(string message)
    {
        try
        {
            lock (diagnosticsGate)
            {
                Directory.CreateDirectory(NativeAPI.Storage);
                var path = Path.Combine(NativeAPI.Storage, "performance.log");
                if (File.Exists(path) && new FileInfo(path).Length > 256 * 1024)
                    File.Move(path, path + ".old", true);
                File.AppendAllText(path, DateTimeOffset.Now.ToString("O") +
                    " " + message + Environment.NewLine);
            }
        }
        catch { } // Logging must never affect application responsiveness.
    }
}
