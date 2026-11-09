package fun.nightwell.music;

import android.graphics.drawable.GradientDrawable;
import android.view.View;

/** Shared card surface, aligned to Nightwell's modern Android design language. */
final class NativeSurfaceDrawable extends GradientDrawable {
    NativeSurfaceDrawable(View view,float corners){
        setColor(NightwellDesign.SURFACE);
        setCornerRadius(NightwellDesign.dp(view.getContext(),Math.min(corners,24)));
        setStroke(Math.max(1,NightwellDesign.dp(view.getContext(),1)),NightwellDesign.BORDER);
    }
}
