package fun.nightwell.music;
import android.content.Context;
import android.graphics.*;
import android.graphics.drawable.GradientDrawable;

/** Shared neutral backdrop for Home, Search, Favorites, Playlists and Offline. */
final class NativeSceneryDrawable extends GradientDrawable {
    NativeSceneryDrawable(Context context){super(Orientation.TL_BR,new int[]{0xff101012,0xff060606,Color.BLACK});}
}
