package fun.nightwell.music;

import android.content.Context;
import android.graphics.Typeface;
import android.view.Gravity;
import android.widget.ArrayAdapter;
import android.widget.LinearLayout;
import android.widget.TextView;

/** Full custom Nightwell selector with a NightwellDialog selection sheet. */
public final class NightwellPicker extends LinearLayout {
    private final TextView label;
    private ArrayAdapter<?> adapter;
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

    public void setAdapter(ArrayAdapter<?> options){
        adapter=options;
        selected=0;
        refresh();
    }
    public int getSelectedItemPosition(){return selected;}
    public Object getSelectedItem(){
        return adapter!=null&&adapter.getCount()>0?adapter.getItem(selected):null;
    }
    public void setSelection(int value){
        if(adapter==null||adapter.getCount()==0)return;
        selected=Math.max(0,Math.min(adapter.getCount()-1,value));
        refresh();
    }
    private void refresh(){
        Object selectedItem=getSelectedItem();
        label.setText(selectedItem==null?"Выбрать":selectedItem.toString());
        setContentDescription("Выбор: "+label.getText());
    }
    private void showChoices(){
        if(adapter==null||adapter.getCount()==0)return;
        CharSequence[] items=new CharSequence[adapter.getCount()];
        for(int i=0;i<items.length;i++){
            Object item=adapter.getItem(i);
            items[i]=(selected==i?"✓  ":"   ")+(item==null?"":item.toString());
        }
        new NightwellDialog.Builder(getContext()).setTitle("Выбрать вариант")
            .setItems(items,(dialog,position)->setSelection(position))
            .setNegativeButton("Отмена",null).show();
    }
}
