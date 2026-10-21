package fun.nightwell.music;

import android.graphics.Color;
import android.graphics.drawable.GradientDrawable;
import android.view.View;

/** Opaque Android surface. No scenery sampling, blur or reflective borders. */
final class NativeSurfaceDrawable extends GradientDrawable {
    NativeSurfaceDrawable(View view,float corners){
        setColor(Color.rgb(32,34,40));
        setCornerRadius(Math.min(corners,18)*view.getResources().getDisplayMetrics().density);
    }
}
