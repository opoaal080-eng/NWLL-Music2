package fun.nightwell.music;

import android.content.Context;
import android.graphics.Typeface;
import android.view.Gravity;
import android.widget.LinearLayout;
import android.widget.TextView;

/** Full custom Nightwell selector with a NightwellDialog selection sheet. */
public final class NightwellPicker extends LinearLayout {
    private final TextView label;
    private CharSequence[] items=new CharSequence[0];
    private int selected;

    public NightwellPicker(Context context){
        super(context);
        setOrientation(HORIZONTAL);
        setGravity(Gravity.CENTER_VERTICAL);
        setMinimumHeight(NightwellDesign.dp(context,54));
        setPadding(NightwellDesign.dp(context,16),0,NightwellDesign.dp(context,16),0);
        setBackground(NightwellDesign.ripple(context,NightwellDesign.FIELD,17,true));
        label=new TextView(context);
        label.setTextColor(NightwellDesign.PRIMARY);
        label.setTextSize(15);
        label.setTypeface(Typeface.create("sans-serif-medium",0));
        label.setSingleLine(true);
        label.setEllipsize(android.text.TextUtils.TruncateAt.END);
        addView(label,new LayoutParams(0,-2,1));
        TextView arrow=new TextView(context);
        arrow.setText("⌄");
        arrow.setTextColor(NightwellDesign.MUTED);
        arrow.setTextSize(23);
        arrow.setGravity(Gravity.CENTER);
        addView(arrow,new LayoutParams(NightwellDesign.dp(context,27),NightwellDesign.dp(context,38)));
        setOnClickListener(v->showChoices());
        setFocusable(true);
    }

    public void setItems(CharSequence[] options){
        items=options==null?new CharSequence[0]:options.clone();
        selected=0;
        refresh();
    }
    public int getSelectedItemPosition(){return selected;}
    public Object getSelectedItem(){
        return items.length>0?items[selected]:null;
    }
    public void setSelection(int value){
        if(items.length==0)return;
        selected=Math.max(0,Math.min(items.length-1,value));
        refresh();
    }
    private void refresh(){
        Object selectedItem=getSelectedItem();
        label.setText(selectedItem==null?"Выбрать":selectedItem.toString());
        setContentDescription("Выбор: "+label.getText());
    }
    private void showChoices(){
        if(items.length==0)return;
        CharSequence[] shown=new CharSequence[items.length];
        for(int i=0;i<items.length;i++){
            shown[i]=(selected==i?"✓  ":"   ")+items[i];
        }
        new NightwellDialog.Builder(getContext()).setTitle("Выбрать вариант")
            .setItems(shown,(dialog,position)->setSelection(position))
            .setNegativeButton("Отмена",null).show();
    }
}
