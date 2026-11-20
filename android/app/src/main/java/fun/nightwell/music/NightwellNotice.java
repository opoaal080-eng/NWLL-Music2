package fun.nightwell.music;

import android.app.Activity;
import android.content.Context;
import android.os.Handler;
import android.os.Looper;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.FrameLayout;
import android.widget.TextView;

/** Nightwell's own in-app notification instead of an Android Toast. */
public final class NightwellNotice {
    public static final int LENGTH_SHORT=0;
    public static final int LENGTH_LONG=1;
    private static final String TAG="nightwell-in-app-notice";
    private final Context context;
    private final CharSequence message;
    private final int duration;

    private NightwellNotice(Context context,CharSequence message,int duration){
        this.context=context;this.message=message;this.duration=duration;
    }
    public static NightwellNotice makeText(Context context,CharSequence message,int duration){
        return new NightwellNotice(context,message,duration);
    }
    public void show(){
        new Handler(Looper.getMainLooper()).post(()->{
            if(!(context instanceof Activity))return;
            Activity activity=(Activity)context;
            if(activity.isFinishing()||activity.isDestroyed())return;
            View content=activity.findViewById(android.R.id.content);
            if(!(content instanceof FrameLayout))return;
            FrameLayout root=(FrameLayout)content;
            View previous=root.findViewWithTag(TAG);
            if(previous!=null)root.removeView(previous);
            TextView notice=new TextView(activity);
            notice.setTag(TAG);
            notice.setText(message);
            notice.setTextColor(NightwellDesign.PRIMARY);
            notice.setTextSize(14);
            notice.setGravity(Gravity.CENTER);
            notice.setPadding(dp(activity,19),dp(activity,14),dp(activity,19),dp(activity,14));
            notice.setBackground(NightwellDesign.surface(activity,NightwellDesign.RAISED,19,true));
            notice.setElevation(dp(activity,16));
            notice.setMaxLines(4);
            FrameLayout.LayoutParams lp=new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,ViewGroup.LayoutParams.WRAP_CONTENT,
                Gravity.BOTTOM|Gravity.CENTER_HORIZONTAL);
            lp.leftMargin=dp(activity,20);
            lp.rightMargin=dp(activity,20);
            lp.bottomMargin=dp(activity,100);
            root.addView(notice,lp);
            notice.setAlpha(0f);notice.setTranslationY(dp(activity,22));
            notice.animate().alpha(1f).translationY(0).setDuration(190).start();
            notice.announceForAccessibility(message);
            notice.postDelayed(()->{
                if(notice.getParent()!=root)return;
                notice.animate().alpha(0f).translationY(dp(activity,12)).setDuration(200)
                    .withEndAction(()->{if(notice.getParent()==root)root.removeView(notice);}).start();
            },duration==LENGTH_LONG?4500:2600);
        });
    }
    private static int dp(Context context,int n){return NightwellDesign.dp(context,n);}
}
