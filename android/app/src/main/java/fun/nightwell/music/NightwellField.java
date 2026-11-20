package fun.nightwell.music;

import android.content.Context;
import android.graphics.drawable.GradientDrawable;
import android.os.Build;
import android.widget.EditText;

/** Consistent Nightwell text field surface, selection and cursor. Keyboard remains system-owned. */
public final class NightwellField extends EditText {
    public NightwellField(Context context){
        super(context);
        setTextSize(15);
        NightwellDesign.styleField(context,this);
        if(Build.VERSION.SDK_INT>=29){
            GradientDrawable cursor=new GradientDrawable();
            cursor.setColor(NightwellDesign.PRIMARY);
            cursor.setSize(NightwellDesign.dp(context,2),NightwellDesign.dp(context,22));
            setTextCursorDrawable(cursor);
        }
        setHighlightColor(0x66f5f6f7);
    }
}
