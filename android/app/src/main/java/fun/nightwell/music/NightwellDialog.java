package fun.nightwell.music;

import android.app.Dialog;
import android.content.Context;
import android.content.DialogInterface;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.ColorDrawable;
import android.os.Bundle;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowManager;
import android.widget.Button;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

/**
 * Completely Nightwell-drawn modal surface, actions and selection list.
 * Does not use the platform AlertDialog layout, action buttons or list rows.
 * Dialog's window is retained for IME focus, accessibility and Back handling.
 */
public final class NightwellDialog extends Dialog {
    public static final int BUTTON_POSITIVE = -1;
    public static final int BUTTON_NEGATIVE = -2;
    public static final int BUTTON_NEUTRAL = -3;

    private final CharSequence heading, description;
    private final View customView;
    private final CharSequence[] choices;
    private final DialogInterface.OnClickListener choiceListener;
    private final CharSequence positiveText, negativeText, neutralText;
    private final DialogInterface.OnClickListener positiveAction, negativeAction, neutralAction;
    private Button positive, negative, neutral;

    private NightwellDialog(Builder b) {
        super(b.context, android.R.style.Theme_Translucent_NoTitleBar);
        heading=b.heading;description=b.description;customView=b.view;
        choices=b.choices;choiceListener=b.choiceListener;
        positiveText=b.positiveText;negativeText=b.negativeText;neutralText=b.neutralText;
        positiveAction=b.positiveAction;negativeAction=b.negativeAction;neutralAction=b.neutralAction;
    }

    private int dp(float value){return NightwellDesign.dp(getContext(),value);}

    private TextView text(CharSequence value, int sp, boolean headline) {
        TextView view=new TextView(getContext());
        view.setText(value);
        view.setTextSize(sp);
        view.setTextColor(headline?NightwellDesign.PRIMARY:NightwellDesign.SECONDARY);
        view.setIncludeFontPadding(false);
        view.setTypeface(Typeface.create(headline?"sans-serif-medium":"sans-serif",headline?Typeface.BOLD:Typeface.NORMAL));
        return view;
    }

    private static final class LimitedHeightFrame extends FrameLayout {
        LimitedHeightFrame(Context context){super(context);}
        @Override protected void onMeasure(int widthSpec,int heightSpec){
            int max=(int)(getResources().getDisplayMetrics().heightPixels*.63f);
            int mode=View.MeasureSpec.getMode(heightSpec);
            int available=mode==View.MeasureSpec.UNSPECIFIED?max:
                Math.min(max,View.MeasureSpec.getSize(heightSpec));
            super.onMeasure(widthSpec,View.MeasureSpec.makeMeasureSpec(
                Math.max(0,available),View.MeasureSpec.AT_MOST));
        }
    }

    @Override protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        final Context context=getContext();
        LinearLayout sheet=new LinearLayout(context);
        sheet.setOrientation(LinearLayout.VERTICAL);
        sheet.setPadding(dp(20),dp(18),dp(20),dp(18));
        sheet.setBackground(NightwellDesign.surface(context,NightwellDesign.SURFACE,26,true));
        sheet.setFocusableInTouchMode(true);

        if(heading!=null&&heading.length()>0){
            TextView title=text(heading,21,true);
            title.setPadding(dp(2),dp(2),dp(2),dp(12));
            sheet.addView(title,new LinearLayout.LayoutParams(-1,-2));
        }
        if(description!=null&&description.length()>0){
            TextView message=text(description,15,false);
            message.setLineSpacing(dp(3),1f);
            message.setPadding(dp(2),dp(2),dp(2),dp(12));
            sheet.addView(message,new LinearLayout.LayoutParams(-1,-2));
        }

        if(customView!=null){
            if(customView.getParent() instanceof ViewGroup){
                ((ViewGroup)customView.getParent()).removeView(customView);
            }
            LimitedHeightFrame content=new LimitedHeightFrame(context);
            content.setClipToPadding(false);
            View scrollable=customView;
            if(!(customView instanceof ScrollView)){
                ScrollView wrapper=new ScrollView(context);
                wrapper.setFillViewport(false);
                wrapper.setVerticalScrollBarEnabled(false);
                wrapper.addView(customView,new ScrollView.LayoutParams(-1,-2));
                scrollable=wrapper;
            }
            content.addView(scrollable,new FrameLayout.LayoutParams(-1,-2));
            sheet.addView(content,new LinearLayout.LayoutParams(-1,-2));
        } else if(choices!=null){
            ScrollView scrolling=new ScrollView(context);
            scrolling.setFillViewport(false);
            scrolling.setVerticalScrollBarEnabled(false);
            LinearLayout list=new LinearLayout(context);list.setOrientation(LinearLayout.VERTICAL);
            for(int i=0;i<choices.length;i++){
                final int index=i;
                TextView item=text(choices[i],16,false);
                item.setTextColor(NightwellDesign.PRIMARY);
                item.setGravity(Gravity.CENTER_VERTICAL);
                item.setMinHeight(dp(54));
                item.setPadding(dp(16),dp(10),dp(16),dp(10));
                item.setBackground(NightwellDesign.ripple(context,NightwellDesign.RAISED,15,true));
                LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(-1,-2);
                lp.bottomMargin=dp(7);
                list.addView(item,lp);
                item.setOnClickListener(v->{
                    dismiss();
                    if(choiceListener!=null)choiceListener.onClick(this,index);
                });
            }
            scrolling.addView(list);
            LimitedHeightFrame holder=new LimitedHeightFrame(context);
            holder.addView(scrolling,new FrameLayout.LayoutParams(-1,-2));
            sheet.addView(holder,new LinearLayout.LayoutParams(-1,-2));
        }

        if(positiveText!=null||negativeText!=null||neutralText!=null){
            LinearLayout actions=new LinearLayout(context);
            actions.setOrientation(LinearLayout.HORIZONTAL);
            actions.setGravity(Gravity.END|Gravity.CENTER_VERTICAL);
            LinearLayout.LayoutParams actionParams=new LinearLayout.LayoutParams(-1,-2);
            actionParams.topMargin=dp(16);
            sheet.addView(actions,actionParams);
            if(negativeText!=null)negative=addButton(actions,negativeText,BUTTON_NEGATIVE,negativeAction,false);
            if(neutralText!=null)neutral=addButton(actions,neutralText,BUTTON_NEUTRAL,neutralAction,false);
            if(positiveText!=null)positive=addButton(actions,positiveText,BUTTON_POSITIVE,positiveAction,true);
        }

        setContentView(sheet);
        Window window=getWindow();
        if(window!=null){
            window.setBackgroundDrawable(new ColorDrawable(Color.TRANSPARENT));
            window.setDimAmount(.76f);
            window.addFlags(WindowManager.LayoutParams.FLAG_DIM_BEHIND);
            window.setGravity(Gravity.CENTER);
            window.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_RESIZE);
            window.setLayout(Math.min(dp(520),getResources().getDisplayMetrics().widthPixels-dp(28)),
                WindowManager.LayoutParams.WRAP_CONTENT);
        }
    }

    private Button addButton(LinearLayout row,CharSequence caption,int which,DialogInterface.OnClickListener callback,boolean primary){
        NightwellButton button=new NightwellButton(getContext());
        button.setText(caption);
        button.setTextSize(13);
        button.setMinHeight(dp(48));
        if(!primary){
            button.setTextColor(NightwellDesign.PRIMARY);
            button.setBackground(NightwellDesign.ripple(getContext(),NightwellDesign.RAISED,15,true));
        }
        LinearLayout.LayoutParams lp=new LinearLayout.LayoutParams(0,dp(48),1);
        lp.leftMargin=dp(5);
        row.addView(button,lp);
        button.setOnClickListener(v->{
            if(callback!=null)callback.onClick(this,which);
            dismiss();
        });
        return button;
    }

    public Button getButton(int which) {
        switch(which){
            case BUTTON_POSITIVE:return positive;
            case BUTTON_NEGATIVE:return negative;
            case BUTTON_NEUTRAL:return neutral;
            default:return null;
        }
    }

    public static final class Builder {
        private final Context context;
        private CharSequence heading, description;
        private View view;
        private CharSequence[] choices;
        private DialogInterface.OnClickListener choiceListener;
        private CharSequence positiveText, negativeText, neutralText;
        private DialogInterface.OnClickListener positiveAction, negativeAction, neutralAction;

        public Builder(Context context){this.context=context;}
        public Builder setTitle(CharSequence title){heading=title;return this;}
        public Builder setMessage(CharSequence message){description=message;return this;}
        public Builder setView(View content){view=content;return this;}
        public Builder setItems(CharSequence[] values,DialogInterface.OnClickListener action){
            choices=values;choiceListener=action;return this;
        }
        public Builder setPositiveButton(CharSequence text,DialogInterface.OnClickListener action){
            positiveText=text;positiveAction=action;return this;
        }
        public Builder setNegativeButton(CharSequence text,DialogInterface.OnClickListener action){
            negativeText=text;negativeAction=action;return this;
        }
        public Builder setNeutralButton(CharSequence text,DialogInterface.OnClickListener action){
            neutralText=text;neutralAction=action;return this;
        }
        public NightwellDialog create(){return new NightwellDialog(this);}
        public NightwellDialog show(){NightwellDialog dialog=create();dialog.show();return dialog;}
    }
}
