using System.Text.Json;
namespace Nightwell.Native;
public partial class MainWindow {
 bool liveOwner,liveBusy;CancellationTokenSource? liveCancellation;
 readonly string deviceID=NativeAPI.DeviceID;
 void StartDeviceSync(){liveCancellation?.Cancel();liveCancellation=CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);_=DeviceSyncLoop(liveCancellation.Token);}
 async Task DeviceSyncLoop(CancellationToken token){
  while(!token.IsCancellationRequested){try{await Task.Delay(5000,token);if(account.Length==0||roomCode.Length>0||liveBusy)continue;liveBusy=true;
   try{var remote=await api.Request("api/playback/state",cancellation:token);
    if(liveOwner&&Current!=null&&Current.LocalPath==null){
     string owner=remote.GetProperty("device_id").GetString()??"";
     // A competing device's newer ownership pauses this device until an explicit action.
     if(lastLiveRevision>=0&&owner!=deviceID&&remote.GetProperty("revision").GetInt64()>lastLiveRevision){liveOwner=false;await AudioCommand(()=>player.SetPause(true));Status.Text="Музыка играет на другом устройстве. В меню можно продолжить здесь.";continue;}
     var body=new{device_id=deviceID,revision=remote.GetProperty("revision").GetInt64(),takeover=owner!=deviceID,track_id=currentID,queue=queue.Where(t=>t.LocalPath==null).Take(950).Select(t=>t.id).ToArray(),position=Math.Max(0,audioTime/1000.0),playing=audioPlaying,repeat,shuffle,wave};
     var result=await api.Request("api/playback/state","PUT",body,token);lastLiveRevision=result.GetProperty("revision").GetInt64();
    }
   }finally{liveBusy=false;}
  }catch(OperationCanceledException){return;}catch{liveBusy=false;}}
 }
 long lastLiveRevision=-1;
 void TakePlaybackHere(){liveOwner=true;lastLiveRevision=-1;}
}
