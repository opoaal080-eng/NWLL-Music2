using System.IO;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Nightwell.Native;

// Entire parser, candidate index and trainable feed-forward ranker stay on this PC.
// The server is used only for catalog/search reads and standard playlist writes.
internal static class LocalTransferInput {
 public sealed record Row(string Title,string Artist,double Duration,string? ISRC=null);
 static string Field(JsonElement value, params string[] keys) {
  foreach(var key in keys) if(value.ValueKind==JsonValueKind.Object&&value.TryGetProperty(key,out var item)) {
   if(item.ValueKind==JsonValueKind.String)return item.GetString()??"";
   if(item.ValueKind==JsonValueKind.Object&&item.TryGetProperty("name",out var name))return name.GetString()??"";
   if(item.ValueKind==JsonValueKind.Array)return string.Join(", ",item.EnumerateArray().Select(x=>x.ValueKind==JsonValueKind.String?x.GetString():x.ValueKind==JsonValueKind.Object&&x.TryGetProperty("name",out var n)?n.GetString():"").Where(x=>!string.IsNullOrWhiteSpace(x)));
  }
  return "";
 }
 public static List<Row> Parse(string input) {
  if(Encoding.UTF8.GetByteCount(input)>1024*1024)throw new InvalidDataException("Максимальный размер файла 1 МБ.");
  var result=new List<Row>();
  void Add(string title,string artist,double duration=0,string? isrc=null) {
   title=title.Trim();artist=artist.Trim();
   if(title.Length==0||artist.Length==0||title.Length>300||artist.Length>300)throw new InvalidDataException("Проверь название и исполнителя трека.");
   if(result.Count>=1000)throw new InvalidDataException("Переноси до 1000 треков за раз.");
   var code=(isrc??"").Trim().ToUpperInvariant();
   result.Add(new Row(title,artist,duration,Regex.IsMatch(code,@"^[A-Z]{2}[A-Z0-9]{3}[0-9]{7}$")?code:null));
  }
  var raw=input.Trim().TrimStart('\uFEFF');
  if(raw.StartsWith("[")||raw.StartsWith("{")) {
   using var json=JsonDocument.Parse(raw);
   var root=json.RootElement;
   JsonElement tracks=root;
   if(root.ValueKind==JsonValueKind.Object) {
    if(root.TryGetProperty("tracks",out var list)||root.TryGetProperty("items",out list)||root.TryGetProperty("audios",out list))tracks=list;
    else if(root.TryGetProperty("playlist",out var playlist)&&playlist.ValueKind==JsonValueKind.Object&&playlist.TryGetProperty("tracks",out var playlistTracks))tracks=playlistTracks;
    else if(root.TryGetProperty("response",out var response)&&response.ValueKind==JsonValueKind.Object&&response.TryGetProperty("items",out var responseTracks))tracks=responseTracks;
    else throw new InvalidDataException("В JSON требуется массив tracks, items или audios.");
   }
   if(tracks.ValueKind!=JsonValueKind.Array)throw new InvalidDataException("В JSON требуется массив треков.");
   foreach(var entry in tracks.EnumerateArray()) {
    var row=entry;
    if(entry.ValueKind==JsonValueKind.Object){
     foreach(var key in new[]{"track","audio","song"})
      if(entry.TryGetProperty(key,out var nested)&&nested.ValueKind==JsonValueKind.Object){row=nested;break;}
    }
    var title=Field(row,"title","name");
    var artist=Field(row,"artist","artists","performer","artist_name","artistName");
    double duration=0;
    foreach(var key in new[]{"duration","duration_ms","durationMs"})if(row.TryGetProperty(key,out var v)&&v.ValueKind==JsonValueKind.Number) {
     duration=v.GetDouble();if(key!="duration")duration/=1000;break;
    }
    string? isrc=null;
    if(row.TryGetProperty("isrc",out var code)&&code.ValueKind==JsonValueKind.String)isrc=code.GetString();
    else foreach(var key in new[]{"external_ids","externalIds"})
      if(row.TryGetProperty(key,out var details)&&details.ValueKind==JsonValueKind.Object&&details.TryGetProperty("isrc",out var value)&&value.ValueKind==JsonValueKind.String){isrc=value.GetString();break;}
    Add(title,artist,duration,isrc);
   }
  } else {
   var lines=raw.Split('\n').Select(x=>x.TrimEnd('\r')).Where(x=>!string.IsNullOrWhiteSpace(x)).ToArray();
   if(lines.Length==0)throw new InvalidDataException("Список пуст.");
   char separator=lines[0].Contains('\t')?'\t':lines[0].Contains(';')?';':',';
   var headers=SplitCSV(lines[0],separator).Select(Normalize).ToArray();
   var name=Array.FindIndex(headers,h=>new[]{"title","track","name","song","название","трек"}.Contains(h));
   var artist=Array.FindIndex(headers,h=>new[]{"artist","artists","исполнитель","исполнители"}.Contains(h));
   var isrc=Array.FindIndex(headers,h=>h=="isrc");
   var duration=Array.FindIndex(headers,h=>new[]{"duration","durationms","длительность"}.Contains(h));
   if(name>=0&&artist>=0) {
    foreach(var line in lines.Skip(1)){
     var cells=SplitCSV(line,separator);
     if(cells.Count<=Math.Max(name,artist))continue;
     double seconds=0;
     if(duration>=0&&duration<cells.Count&&double.TryParse(cells[duration],NumberStyles.Float,CultureInfo.InvariantCulture,out var parsed))
      seconds=headers[duration]=="durationms"?parsed/1000:parsed;
     Add(cells[name],cells[artist],seconds,isrc>=0&&isrc<cells.Count?cells[isrc]:null);
    }
   } else {
    foreach(var line in lines) {
     var cut=Regex.Match(line,@"\s+[—–-]\s+|\t");
     if(!cut.Success)throw new InvalidDataException("Нужен формат «Исполнитель — Название» или CSV с заголовками.");
     Add(line[(cut.Index+cut.Length)..],line[..cut.Index]);
    }
   }
  }
  var unique=result.DistinctBy(x=>Normalize(x.Artist)+"|"+Normalize(x.Title)).ToList();
  if(unique.Count==0)throw new InvalidDataException("Нет треков для переноса.");
  return unique;
 }
 static List<string> SplitCSV(string line,char delimiter) {
  var fields=new List<string>();var value=new StringBuilder();bool quoted=false;
  for(int i=0;i<line.Length;i++) {
   char c=line[i];
   if(c=='"') {if(quoted&&i+1<line.Length&&line[i+1]=='"'){value.Append('"');i++;}else quoted=!quoted;}
   else if(c==delimiter&&!quoted){fields.Add(value.ToString());value.Clear();}
   else value.Append(c);
  }
  fields.Add(value.ToString());return fields;
 }
 public static IEnumerable<string> SearchQueries(Row row) {
  var cleaned=Regex.Replace(row.Title,@"\([^)]*(?:official|video|audio|lyrics?|visualizer)[^)]*\)"," ",RegexOptions.IgnoreCase);
  cleaned=Regex.Replace(cleaned,@"\b(?:feat\.?|ft\.?|featuring)\s+.+$"," ",RegexOptions.IgnoreCase);
  cleaned=Regex.Replace(cleaned,@"\b(?:official|music video|lyrics? video|visualizer|audio)\b"," ",RegexOptions.IgnoreCase);
  cleaned=Regex.Replace(cleaned,@"\s+"," ").Trim();
  var unique=new HashSet<string>();
  foreach(var candidate in new[]{row.Artist+" "+row.Title,row.Artist+" "+cleaned,cleaned,row.Title}) {
   var text=candidate.Trim();
   if(text.Length==0||!unique.Add(Normalize(text)))continue;
   yield return text;
   if(unique.Count>=3)yield break;
  }
 }
 public static string Normalize(string text) {
  text=text.Normalize(NormalizationForm.FormKC).ToLowerInvariant().Replace('ё','е');
  const string ru="абвгдежзийклмнопрстуфхцчшщыэюя";
  string[] lat={"a","b","v","g","d","e","zh","z","i","y","k","l","m","n","o","p","r","s","t","u","f","h","ts","ch","sh","sch","y","e","yu","ya"};
  var b=new StringBuilder();
  foreach(var ch in text) {
   int pos=ru.IndexOf(ch);
   if(pos>=0)b.Append(lat[pos]);
   else b.Append(char.IsLetterOrDigit(ch)?ch:' ');
  }
  return Regex.Replace(b.ToString(),@"\s+"," ").Trim();
 }
}

internal sealed class LocalNeuralTransferMatcher {
 public sealed record Result(LocalTransferInput.Row Original,Track? Found,double Confidence,string Reason);
 readonly Dictionary<string,List<Track>> titleIndex=new(), artistIndex=new();
 readonly List<Track> catalog;
 readonly double[,] hiddenWeights=new double[12,9];
 readonly double[] hiddenBias=new double[12], outputWeights=new double[12];
 double outputBias;
 const int F=9;
 static string Key(string value)=>LocalTransferInput.Normalize(value);
 static string[] Words(string s)=>s.Split(' ',StringSplitOptions.RemoveEmptyEntries);
 static double TokenScore(string a,string b) {
  var left=Words(a).ToHashSet();var right=Words(b).ToHashSet();
  if(left.Count==0||right.Count==0)return 0;
  return (double)left.Intersect(right).Count()/Math.Max(left.Count,right.Count);
 }
 static double Dice(string a,string b) {
  if(a==b)return 1;
  if(a.Length<2||b.Length<2)return 0;
  var grams=new HashSet<string>();for(int i=0;i<a.Length-1;i++)grams.Add(a.Substring(i,2));
  var other=new HashSet<string>();for(int i=0;i<b.Length-1;i++)other.Add(b.Substring(i,2));
  return 2.0*grams.Intersect(other).Count()/Math.Max(1,grams.Count+other.Count);
 }
 static double Similarity(string a,string b) {
  if(a==b)return 1;
  if(a.Length==0||b.Length==0||a.Length>180||b.Length>180)return 0;
  var p=Enumerable.Range(0,b.Length+1).ToArray();
  for(int i=1;i<=a.Length;i++) {
   var c=new int[b.Length+1];c[0]=i;
   for(int j=1;j<=b.Length;j++)c[j]=Math.Min(Math.Min(p[j]+1,c[j-1]+1),p[j-1]+(a[i-1]==b[j-1]?0:1));
   p=c;
  }
  return Math.Max(0,1.0-(double)p[b.Length]/Math.Max(a.Length,b.Length));
 }
 static readonly HashSet<string> Versions=new(new[]{"live","remix","remaster","remastered","acoustic","instrumental","cover","karaoke","sped","slowed","edit","reverb"});
 static string VersionKey(string t)=>string.Join(" ",Words(t).Where(x=>Versions.Contains(x)).OrderBy(x=>x));
 static double[] Features(LocalTransferInput.Row row,Track candidate) {
  var title=Key(row.Title);var artist=Key(row.Artist);
  var ct=Key(candidate.title);var ca=Key(candidate.artist);
  var duration=row.Duration>0&&candidate.duration>0
   ?Math.Max(0,1-Math.Abs(row.Duration-candidate.duration)/Math.Max(14,row.Duration*.13)):1;
  return new[]{Similarity(title,ct),Similarity(artist,ca),TokenScore(title,ct),TokenScore(artist,ca),
   Dice(title,ct),Dice(artist,ca),duration,VersionKey(title)==VersionKey(ct)?1.0:0.0,
   title==ct&&artist==ca?1.0:0.0};
 }
 static double Sigmoid(double x)=>1.0/(1.0+Math.Exp(-Math.Clamp(x,-30,30)));
 double Predict(double[] x,out double[] acts) {
  acts=new double[12];
  double sum=outputBias;
  for(int j=0;j<12;j++) {
   double a=hiddenBias[j];
   for(int i=0;i<F;i++)a+=hiddenWeights[j,i]*x[i];
   acts[j]=Math.Tanh(a);sum+=outputWeights[j]*acts[j];
  }
  return Sigmoid(sum);
 }
 void Learn(double[] x,double target,double rate) {
  double predicted=Predict(x,out var hidden);
  double gradient=predicted-target;
  var old=(double[])outputWeights.Clone();
  for(int j=0;j<12;j++) {
   outputWeights[j]-=rate*gradient*hidden[j];
   double back=gradient*old[j]*(1-hidden[j]*hidden[j]);
   for(int i=0;i<F;i++)hiddenWeights[j,i]-=rate*back*x[i];
   hiddenBias[j]-=rate*back;
  }
  outputBias-=rate*gradient;
 }
 public LocalNeuralTransferMatcher(IEnumerable<Track> tracks) {
  catalog=tracks.Where(x=>!string.IsNullOrWhiteSpace(x.id)&&!string.IsNullOrWhiteSpace(x.title)).DistinctBy(x=>x.id).Take(200000).ToList();
  var rng=new Random(89411);
  for(int j=0;j<12;j++)for(int i=0;i<F;i++)hiddenWeights[j,i]=(rng.NextDouble()-.5)*.6;
  for(int j=0;j<12;j++)outputWeights[j]=(rng.NextDouble()-.5)*.6;
  static void Add(Dictionary<string,List<Track>> index,string key,Track t) {
   if(key.Length==0)return;
   if(!index.TryGetValue(key,out var items))index[key]=items=new List<Track>();
   if(items.Count<400)items.Add(t);
  }
  foreach(var t in catalog) {
   Add(titleIndex,Key(t.title),t);Add(artistIndex,Key(t.artist),t);
   foreach(var word in Words(Key(t.title)).Where(x=>x.Length>=3).Take(6))Add(titleIndex,word,t);
  }
  // A tiny 9→12→1 neural ranker, trained on this device using generated
  // positive and negative catalog pairs. No cloud AI or model download.
  var samples=new List<(double[] X,double Y)>();
  for(int i=0;i<Math.Min(1800,catalog.Count);i++) {
   var t=catalog[i];
   var baseRow=new LocalTransferInput.Row(t.title,t.artist,t.duration);
   samples.Add((Features(baseRow,t),1));
   if(t.title.Length>4) {
    var altered=new LocalTransferInput.Row(t.title.Replace("  "," ").Replace("("," ").Replace(")"," "),t.artist,t.duration);
    samples.Add((Features(altered,t),1));
   }
   if(catalog.Count>1) {
    var another=catalog[(i+1+rng.Next(catalog.Count-1))%catalog.Count];
    samples.Add((Features(baseRow,another),0));
    var wrong=new LocalTransferInput.Row(t.title,another.artist,t.duration);
    samples.Add((Features(wrong,t),0));
   }
  }
  for(int pass=0;pass<5;pass++) {
   for(int i=samples.Count-1;i>0;i--){int j=rng.Next(i+1);(samples[i],samples[j])=(samples[j],samples[i]);}
   foreach(var sample in samples)Learn(sample.X,sample.Y,.055);
  }
 }
 public Result Match(LocalTransferInput.Row row,string mode,IEnumerable<Track>? extra=null) {
  var title=Key(row.Title);var artist=Key(row.Artist);
  var possibilities=new Dictionary<string,Track>();
  void Include(IEnumerable<Track> entries){foreach(var t in entries)if(possibilities.Count<900)possibilities.TryAdd(t.id,t);}
  if(titleIndex.TryGetValue(title,out var same))Include(same);
  if(artistIndex.TryGetValue(artist,out var performer))Include(performer);
  foreach(var word in Words(title).Where(x=>x.Length>=3).Take(4))if(titleIndex.TryGetValue(word,out var words))Include(words);
  // Fuzzy index fallback handles missing letters and small typos.
  // Only inspect short token keys, keeping expensive scoring local.
  if(possibilities.Count<40) {
   var parts=Words(title).Where(x=>x.Length>=4).Take(5).ToArray();
   if(parts.Length>0)foreach(var pair in titleIndex) {
    if(pair.Key.Length<4||pair.Key.Contains(' '))continue;
    if(!parts.Any(part=>Similarity(part,pair.Key)>=.72))continue;
    Include(pair.Value.Take(80));
    if(possibilities.Count>=900)break;
   }
  }
  if(extra!=null) {
   // Search results are directly relevant to this query: always consider them.
   foreach(var candidate in extra)possibilities[candidate.id]=candidate;
  }
  // Exact artist/title matches must not be rejected as ambiguous duplicates.
  // Still honor the duration check to avoid selecting the wrong recording.
  foreach(var candidate in possibilities.Values) {
   if(Key(candidate.title)!=title||Key(candidate.artist)!=artist)continue;
   if(row.Duration>0&&candidate.duration>0&&Math.Abs(row.Duration-candidate.duration)>Math.Max(14,row.Duration*.13))continue;
   return new Result(row,candidate,1,"");
  }
  var scores=new List<(Track T,double S,double Title,double Artist)>();
  foreach(var t in possibilities.Values) {
   var x=Features(row,t);
   if(x[7]<1)continue;
   double minimumTitle=mode=="safe"?.94:mode=="wide"?.79:.86;
   double minimumArtist=mode=="safe"?.89:mode=="wide"?.69:.79;
   if(x[0]<minimumTitle||x[1]<minimumArtist)continue;
   var prediction=Predict(x,out _);
   var confidence=.40*x[0]+.23*x[1]+.22*prediction+.15*x[2];
   scores.Add((t,confidence,x[0],x[1]));
  }
  scores.Sort((a,b)=>b.S.CompareTo(a.S));
  if(scores.Count==0)return new Result(row,null,0,"Не найдено надёжного совпадения");
  var first=scores[0];
  double gap=scores.Count>1?first.S-scores[1].S:1;
  double threshold=mode=="safe"?.91:mode=="wide"?.80:.85;
  if(first.S<threshold)return new Result(row,null,first.S,"Совпадение слишком неточное");
  if(gap<.022&&first.S<.985)return new Result(row,null,first.S,"Несколько похожих версий, нужна проверка");
  if(row.Duration>0&&first.T.duration>0&&Math.Abs(row.Duration-first.T.duration)>Math.Max(14,row.Duration*.13))
   return new Result(row,null,first.S,"Не совпадает длительность");
  return new Result(row,first.T,first.S,"");
 }
}
