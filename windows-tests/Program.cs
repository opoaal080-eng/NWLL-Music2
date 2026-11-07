using Nightwell.Native;
void Check(bool valid,string message){if(!valid)throw new Exception(message);}
var tracks=Enumerable.Range(0,24).Select(i=>new Track{id="t"+i,title="Song "+i,artist="Artist "+(i%4)}).ToList();
for(int seed=0;seed<100;seed++){
 var order=SmartQueue.Order(tracks.Concat(tracks.Take(3)),"t7",true,new Random(seed));
 Check(order.Count==24&&order.Select(t=>t.id).Distinct().Count()==24,"Lost or duplicated tracks");
 Check(order[0].id=="t7","Changed currently playing track");
 for(int i=1;i<order.Count-4;i++)Check(order[i].artist!=order[i-1].artist,"Repeated artist despite alternatives");
 var enhanced=SmartQueue.Enhance(order,tracks.Concat(Enumerable.Range(0,30).Select(i=>new Track{id="r"+i,title="New "+i,artist="New artist "+i})).ToList());
 Check(enhanced.Count==32,"Unexpected recommendation ratio");
 Check(enhanced.Where(t=>!t.Suggested).Select(t=>t.id).SequenceEqual(order.Select(t=>t.id)),"Suggestions changed original queue order");
 Check(enhanced.Select(t=>t.id).Distinct().Count()==enhanced.Count,"Duplicate recommendation");
 Check(enhanced[0].id=="t7","Suggestion replaced current track");
}
Check(SmartQueue.Order([],null,true).Count==0,"Empty queue");
Check(SmartQueue.Enhance(tracks.Take(2).ToList(),tracks.Skip(2).ToList()).Count==2,"Too many suggestions for tiny queue");
Console.WriteLine("Queue ordering passed: 100 seeds, duplicates, artist spacing, current track and suggestions");
namespace Nightwell.Native { public sealed record Track {public string id{get;set;}="";public string title{get;set;}="";public string artist{get;set;}="";public bool Suggested{get;set;}} }
