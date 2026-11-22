package fun.nightwell.music;

import android.content.Context;
import android.graphics.Typeface;
import android.view.Gravity;
import android.view.View;
import android.widget.LinearLayout;
import android.widget.TextView;

/** The mini-player sits above three independently focusable primary destinations. */
final class NightwellTabBar extends LinearLayout {
    interface Listener { void select(int tab); }
    private static final String[] LABELS = {"Главная", "Поиск", "Медиатека"};
    private static final String[] ICONS = {"home", "search", "library"};
    private final NavigationMenuIcon[] icons = new NavigationMenuIcon[LABELS.length];
    private final TextView[] captions = new TextView[LABELS.length];
    private Listener listener;

    NightwellTabBar(Context context) {
        super(context);
        setOrientation(HORIZONTAL);
        for (int i = 0; i < LABELS.length; i++) {
            final int index = i;
            LinearLayout tab = new LinearLayout(context);
            tab.setOrientation(VERTICAL);
            tab.setGravity(Gravity.CENTER);
            tab.setContentDescription("Вкладка «" + LABELS[i] + "»");
            tab.setFocusable(true);
            tab.setOnClickListener(v -> { if (listener != null) listener.select(index); });
            tab.setBackground(NightwellDesign.plainButton(context, 14));
            icons[i] = new NavigationMenuIcon(context, ICONS[i], 0xffffffff);
            tab.addView(icons[i], new LayoutParams(dp(23), dp(23)));
            TextView label = new TextView(context);
            label.setIncludeFontPadding(false);
            label.setTextSize(11);
            label.setSingleLine();
            label.setText(LABELS[i]);
            label.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
            captions[i] = label;
            LayoutParams caption = new LayoutParams(-2, -2);
            caption.topMargin = dp(4);
            tab.addView(label, caption);
            addView(tab, new LayoutParams(0, -1, 1));
        }
        setActive(0);
    }

    private int dp(int value) { return NightwellDesign.dp(getContext(), value); }
    void setListener(Listener value) { listener = value; }
    void setActive(int index) {
        for (int i = 0; i < LABELS.length; i++) {
            boolean selected = i == index;
            int color = selected ? 0xffffffff : 0xff818185;
            getChildAt(i).setSelected(selected);
            icons[i].setSelected(selected);
            icons[i].setColor(color);
            captions[i].setTextColor(color);
            captions[i].setTypeface(Typeface.create(selected ? "sans-serif-medium" : "sans-serif", 0));
        }
    }
}
