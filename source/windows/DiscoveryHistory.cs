using System.IO;
using System.Text.Json;
using System.Text;
using System.Text.RegularExpressions;

namespace Nightwell.Native;

/// <summary>
/// Per-account 14-day record of actual playback, independent of the limited server mix.
/// IDs and normalized track signatures prevent repeated uploads from cycling daily.
/// </summary>
internal sealed class DiscoveryHistory {
    private sealed record Entry(string Origin, string Account, string Id, string Recording, DateTimeOffset At);
    private readonly string path = Path.Combine(NativeAPI.Storage, "discovery-history-v2.json");
    private List<Entry> entries = [];

    public DiscoveryHistory() {
        try { entries = JsonSerializer.Deserialize<List<Entry>>(File.ReadAllText(path)) ?? []; }
        catch { entries = []; }
        Prune();
    }

    private void Prune() {
        var now=DateTimeOffset.UtcNow;
        entries=entries.Where(e=>e.At>=now.AddDays(-14)&&e.At<=now.AddMinutes(5)).TakeLast(1600).ToList();
    }

    private static string Key(string value) {
        var normalized=(value??"").ToLowerInvariant().Normalize(NormalizationForm.FormD);
        return string.Concat(normalized.Where(c => Char.IsLetterOrDigit(c))).Normalize(NormalizationForm.FormC);
    }

    public static string Fingerprint(Track song) {
        var title=song.title.Trim();
        var artist=song.artist;
        foreach (var divider in new[] {" - ", " – ", " — "}) {
            var marker=title.IndexOf(divider,StringComparison.Ordinal);
            if(marker>0&&marker<65) {
                artist=title[..marker];
                title=title[(marker+divider.Length)..];
                break;
            }
        }
        title=Regex.Replace(title,@"\s*[\[(](official\s+(audio|video)|lyrics?|visuali[sz]er|4k|hd|music\s+video)[\])]", "", RegexOptions.IgnoreCase);
        return Key(artist)+"|"+Key(title);
    }

    private List<Entry> Matching(string origin,string account) {
        Prune();
        return entries.Where(e=>e.Origin==origin&&e.Account==account).ToList();
    }

    public HashSet<string> Ids(string origin,string account)=>
        Matching(origin,account).Select(e=>e.Id).ToHashSet(StringComparer.Ordinal);

    public HashSet<string> Recordings(string origin,string account)=>
        Matching(origin,account).Select(e=>e.Recording).ToHashSet(StringComparer.Ordinal);

    public IEnumerable<string> Recent(string origin,string account,int limit=160)=>
        Matching(origin,account).AsEnumerable().Reverse().Take(limit).Select(e=>e.Id);

    public void Remember(string origin,string account,Track song) {
        if(string.IsNullOrEmpty(song.id))return;
        Prune();
        var fp=Fingerprint(song);
        entries.RemoveAll(e=>e.Origin==origin&&e.Account==account&&
            (e.Id==song.id||e.Recording==fp));
        entries.Add(new Entry(origin,account,song.id,fp,DateTimeOffset.UtcNow));
        entries=entries.TakeLast(1600).ToList();
        try {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var temp=path+".tmp";
            File.WriteAllText(temp,JsonSerializer.Serialize(entries));
            File.Move(temp,path,true);
        } catch { /* Cannot block playback when storage is inaccessible. */ }
    }
}
