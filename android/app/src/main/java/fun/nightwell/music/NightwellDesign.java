package fun.nightwell.music;

import android.content.Context;
import android.content.res.ColorStateList;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.Drawable;
import android.graphics.drawable.GradientDrawable;
import android.graphics.drawable.RippleDrawable;
import android.os.Build;
import android.view.View;
import android.view.WindowInsets;
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

    // Shared 4dp rhythm and control geometry; visual constants stay in one place.
    static final int SPACE_1 = 4;
    static final int SPACE_2 = 8;
    static final int SPACE_3 = 12;
    static final int SPACE_4 = 16;
    static final int SPACE_5 = 20;
    static final int SPACE_6 = 24;
    static final int RADIUS_SMALL = 12;
    static final int RADIUS_CONTROL = 16;
    static final int RADIUS_CARD = 22;
    static final int RADIUS_SHEET = 24;
    static final int MIN_TOUCH = 48;
    static final int FIELD_HEIGHT = 52;
    static final int LIST_ROW_HEIGHT = 64;

    private NightwellDesign() { }

    static boolean animationsEnabled() {
        return android.animation.ValueAnimator.areAnimatorsEnabled();
    }

    /** Honor cutouts in landscape and the keyboard in every screen, without padding the scenery. */
    static void applySafeArea(View content, int horizontal, int topSpace, int bottomSpace) {
        content.setOnApplyWindowInsetsListener((view, insets) -> {
            int top, bottom, left, right;
            if (Build.VERSION.SDK_INT >= 30) {
                android.graphics.Insets bars = insets.getInsets(
                    WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout());
                android.graphics.Insets ime = insets.getInsets(WindowInsets.Type.ime());
                top = bars.top;
                bottom = Math.max(bars.bottom, ime.bottom);
                left = bars.left;
                right = bars.right;
            } else {
                top = insets.getSystemWindowInsetTop();
                bottom = insets.getSystemWindowInsetBottom();
                left = insets.getSystemWindowInsetLeft();
                right = insets.getSystemWindowInsetRight();
                if (Build.VERSION.SDK_INT >= 28 && insets.getDisplayCutout() != null) {
                    android.view.DisplayCutout cutout = insets.getDisplayCutout();
                    top = Math.max(top, cutout.getSafeInsetTop());
                    bottom = Math.max(bottom, cutout.getSafeInsetBottom());
                    left = Math.max(left, cutout.getSafeInsetLeft());
                    right = Math.max(right, cutout.getSafeInsetRight());
                }
            }
            view.setPadding(dp(view.getContext(), horizontal) + left,
                dp(view.getContext(), topSpace) + top,
                dp(view.getContext(), horizontal) + right,
                dp(view.getContext(), bottomSpace) + bottom);
            return insets;
        });
        content.requestApplyInsets();
    }

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
        return new RippleDrawable(ColorStateList.valueOf(fill==PRIMARY?0x26000000:0x2affffff),content,mask);
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
        label.setIncludeFontPadding(false);
    }

    static void label(TextView label) {
        label.setTextColor(SECONDARY);
        label.setTypeface(Typeface.create("sans-serif-medium",Typeface.NORMAL));
        label.setIncludeFontPadding(false);
    }

    static void styleField(Context context,TextView field) {
        field.setTextColor(PRIMARY);
        field.setBackground(ripple(context,FIELD,RADIUS_CONTROL,true));
        field.setPadding(dp(context,SPACE_4),dp(context,SPACE_3),dp(context,SPACE_4),dp(context,SPACE_3));
        field.setMinHeight(dp(context,FIELD_HEIGHT));
        if(field instanceof android.widget.EditText) {
            ((android.widget.EditText)field).setHintTextColor(MUTED);
        }
    }

    static void styleButton(Context context,View view,boolean primary) {
        view.setBackground(ripple(context,primary?PRIMARY:RAISED,primary?RADIUS_CARD:RADIUS_CONTROL,!primary));
        view.setMinimumHeight(dp(context,MIN_TOUCH));
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
