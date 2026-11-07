namespace Nightwell.Native;
public static class SmartQueue {
 public static List<Track> Order(IEnumerable<Track> source,string? current,bool smart,Random? random=null){
  random??=Random.Shared;var pool=source.DistinctBy(t=>t.id).OrderBy(_=>random.Next()).ToList();var result=new List<Track>();
  var playing=pool.Find(t=>t.id==current);if(playing!=null){result.Add(playing);pool.Remove(playing);}
  while(pool.Count>0){int pick=0;if(smart&&result.Count>0){var recent=result.TakeLast(2).Select(t=>Artist(t.artist)).ToHashSet();pick=pool.FindIndex(t=>!recent.Contains(Artist(t.artist)));if(pick<0)pick=pool.FindIndex(t=>Artist(t.artist)!=Artist(result[^1].artist));if(pick<0)pick=0;}result.Add(pool[pick]);pool.RemoveAt(pick);}return result;
 }
 public static List<Track> Enhance(List<Track> ordered,List<Track> recommendations){
  var ids=ordered.Select(t=>t.id).ToHashSet();var names=ordered.Select(Key).ToHashSet();var extra=recommendations.Where(t=>ids.Add(t.id)&&names.Add(Key(t))).Take(Math.Min(15,ordered.Count/3)).ToList();
  var result=new List<Track>();
  for(int i=0;i<ordered.Count;i++){result.Add(ordered[i]);if(i>0&&(i+1)%3==0&&extra.Count>0){int pick=extra.FindIndex(t=>Artist(t.artist)!=Artist(ordered[i].artist)&&(i+1==ordered.Count||Artist(t.artist)!=Artist(ordered[i+1].artist)));if(pick<0)continue;var suggestion=extra[pick] with {Suggested=true};extra.RemoveAt(pick);result.Add(suggestion);}}
  return result;
 }
 static string Artist(string value)=>value.Trim().ToUpperInvariant();
 static string Key(Track t)=>Artist(t.artist)+"|"+t.title.Trim().ToUpperInvariant();
}
