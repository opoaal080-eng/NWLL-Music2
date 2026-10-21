package fun.nightwell.music;
import android.content.*;
public final class DownloadReceiver extends BroadcastReceiver {
    @Override public void onReceive(Context context,Intent intent){
        if(android.app.DownloadManager.ACTION_DOWNLOAD_COMPLETE.equals(intent.getAction()))BackgroundDownloads.completed(context,goAsync());
    }
}
