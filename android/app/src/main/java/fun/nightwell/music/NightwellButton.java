package fun.nightwell.music;

import android.content.Context;
import android.widget.Button;

/** Single reusable styled action control; no platform-themed button background. */
public final class NightwellButton extends Button {
    public NightwellButton(Context context){
        super(context);
        setAllCaps(false);
        setMinWidth(0);
        setMinimumWidth(0);
        setPadding(NightwellDesign.dp(context,10),0,NightwellDesign.dp(context,10),0);
        setTextSize(15);
        NightwellDesign.styleButton(context,this,true);
        setStateListAnimator(null);
    }
}
