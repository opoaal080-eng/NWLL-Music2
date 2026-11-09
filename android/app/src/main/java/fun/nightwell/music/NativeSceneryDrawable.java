package fun.nightwell.music;
import android.content.Context;
import android.graphics.drawable.GradientDrawable;

/** Neutral chrome for all pages except Home and the cover-colour full player. */
final class NativeSceneryDrawable extends GradientDrawable {
    NativeSceneryDrawable(Context context){
        super(Orientation.TOP_BOTTOM,new int[]{
            NightwellDesign.BACKGROUND,0xff0b0c0e,NightwellDesign.BACKGROUND});
    }
}
