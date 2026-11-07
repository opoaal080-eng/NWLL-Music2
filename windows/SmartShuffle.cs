namespace Nightwell.Native;

public partial class MainWindow {
 // A compact smart shuffle: avoid repeated tracks, spread artists out,
 // and give the remaining candidates randomness without restarting a sequence.
 int ChooseSmartShuffleIndex(){
  if(queue.Count<2)return index;
  var history=mixRecent.ToArray();
  var recentArtists=new HashSet<string>(StringComparer.OrdinalIgnoreCase);
  foreach(var id in history.TakeLast(6)){
   var previous=queue.FirstOrDefault(t=>t.id==id);
   if(previous!=null&&!string.IsNullOrWhiteSpace(previous.artist))
    recentArtists.Add(previous.artist);
  }
  double best=double.NegativeInfinity;
  int selected=-1;
  for(int i=0;i<queue.Count;i++){
   if(i==index||queue[i].id==currentID)continue;
   var track=queue[i];
   int last=Array.LastIndexOf(history,track.id);
   double recentlyPlayedPenalty=last<0?0:6.0*(last+1)/Math.Max(1,history.Length);
   double sameArtistPenalty=Current!=null&&
      string.Equals(Current.artist,track.artist,StringComparison.OrdinalIgnoreCase)?3.0:0;
   double recentArtistPenalty=recentArtists.Contains(track.artist)?1.5:0;
   double score=Random.Shared.NextDouble()*1.75
      -recentlyPlayedPenalty-sameArtistPenalty-recentArtistPenalty;
   if(score>best){best=score;selected=i;}
  }
  return selected>=0?selected:(index+1)%queue.Count;
 }
}
