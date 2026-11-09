package fun.nightwell.music;

import android.content.Context;
import android.content.res.ColorStateList;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.RippleDrawable;
import android.util.TypedValue;
import android.view.View;
import android.widget.TextView;

/** Nightwell Music Android design tokens: restrained, accessible, near-black surfaces. */
final class NightwellDesign {
    static final int BACKGROUND = 0xff08090b;
    static final int SURFACE = 0xff17191c;
    static final int RAISED = 0xff202226;
    static final int FIELD = 0xff1c1e22;
    static final int BORDER = 0xff34373d;
    static final int PRIMARY = 0xfff5f6f7;
    static final int MUTED = 0xffa3a7ae;
    static final int SECONDARY = 0xffd5d8dd;
    static final int ACCENT = 0xffeeeeef;
    static final int DANGER = 0xffe9a7ac;
    static final int SELECTED = 0xff292c31;

    private NightwellDesign() { }

    static int dp(Context context,float value) {
        return Math.round(value*context.getResources().getDisplayMetrics().density);
    }

    static GradientDrawable surface(Context c,int fill,float radius,boolean border) {
        GradientDrawable d=new GradientDrawable();
        d.setColor(fill);
        d.setCornerRadius(dp(c,radius));
        if(border)d.setStroke(Math.max(1,dp(c,1)),BORDER);
        return d;
    }

    static Drawable ripple(Context c,int fill,float radius,boolean border) {
        GradientDrawable content=surface(c,fill,radius,border);
        GradientDrawable mask=surface(c,Color.WHITE,radius,false);
        return new RippleDrawable(ColorStateList.valueOf(0x25ffffff),content,mask);
    }

    static void headline(TextView label) {
        label.setTextColor(PRIMARY);
        label.setTypeface(Typeface.create("sans-serif",Typeface.BOLD));
        label.setLetterSpacing(-.025f);
        label.setIncludeFontPadding(false);
    }

    static void detail(TextView label) {
        label.setTextColor(MUTED);
        label.setTypeface(Typeface.create("sans-serif",Typeface.NORMAL));
    }

    static void label(TextView label) {
        label.setTextColor(SECONDARY);
        label.setTypeface(Typeface.create("sans-serif-medium",Typeface.NORMAL));
    }

    static void styleField(Context context,TextView field) {
        field.setTextColor(PRIMARY);
        field.setBackground(ripple(context,FIELD,17,true));
        field.setPadding(dp(context,16),dp(context,13),dp(context,16),dp(context,13));
        field.setMinHeight(dp(context,52));
        if(field instanceof android.widget.EditText) {
            ((android.widget.EditText)field).setHintTextColor(MUTED);
        }
    }

    static void styleButton(Context context,View view,boolean primary) {
        view.setBackground(ripple(context,primary?PRIMARY:RAISED,primary?18:16,!primary));
        view.setMinimumHeight(dp(context,48));
        if(view instanceof TextView) {
            ((TextView)view).setTextColor(primary?BACKGROUND:PRIMARY);
            ((TextView)view).setTypeface(Typeface.create("sans-serif-medium",Typeface.NORMAL));
        }
    }

    static View hairline(Context c) {
        View line=new View(c);
        line.setBackgroundColor(BORDER);
        return line;
    }
}
