package fun.nightwell.music;

import android.content.Context;
import android.view.Gravity;
import android.view.ViewGroup;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.text.TextUtils;
import org.json.JSONObject;

/**
 * Recyclable queue cell. Binding is side-effect free: scrolling never recreates
 * every child view or retains the state of the previously bound track.
 */
final class NightwellQueueRow extends LinearLayout {
    private final TextView index;
    private final TextView title;
    private final TextView artist;

    NightwellQueueRow(Context context) {
        super(context);
        setOrientation(HORIZONTAL);
        setGravity(Gravity.CENTER_VERTICAL);
        setMinimumHeight(NightwellDesign.dp(context, NightwellDesign.LIST_ROW_HEIGHT));
        int horizontal = NightwellDesign.dp(context, NightwellDesign.SPACE_3);
        int vertical = NightwellDesign.dp(context, NightwellDesign.SPACE_2);
        setPadding(horizontal, vertical, horizontal, vertical);

        index = new TextView(context);
        index.setTextSize(13);
        index.setGravity(Gravity.CENTER);
        index.setIncludeFontPadding(false);
        addView(index, new LayoutParams(
            NightwellDesign.dp(context, 34), NightwellDesign.dp(context, 48)));

        LinearLayout labels = new LinearLayout(context);
        labels.setOrientation(VERTICAL);
        labels.setGravity(Gravity.CENTER_VERTICAL);
        labels.setPadding(NightwellDesign.dp(context, NightwellDesign.SPACE_3), 0, 0, 0);
        addView(labels, new LayoutParams(0, ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        title = new TextView(context);
        title.setTextSize(14);
        title.setSingleLine(true);
        title.setEllipsize(TextUtils.TruncateAt.END);
        NightwellDesign.headline(title);
        labels.addView(title, new LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));

        artist = new TextView(context);
        artist.setTextSize(12);
        artist.setSingleLine(true);
        artist.setEllipsize(TextUtils.TruncateAt.END);
        artist.setPadding(0, NightwellDesign.dp(context, NightwellDesign.SPACE_1), 0, 0);
        NightwellDesign.detail(artist);
        labels.addView(artist, new LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
    }

    void bind(JSONObject track, int position, String currentId) {
        String id = track == null ? "" : track.optString("id");
        boolean active = !id.isEmpty() && id.equals(currentId);
        String trackName = track == null ? "Без названия" : track.optString("title", "Без названия");
        String performer = track == null ? "" : track.optString("artist", "");
        index.setText(active ? "▶" : String.valueOf(position + 1));
        index.setTextColor(active ? NightwellDesign.PRIMARY : NightwellDesign.MUTED);
        title.setText(trackName);
        artist.setText(performer);
        setContentDescription((active ? "Сейчас играет. " : "") + trackName
            + (performer.isEmpty() ? "" : ". " + performer));
        setBackground(NightwellDesign.ripple(getContext(),
            active ? NightwellDesign.SELECTED : NightwellDesign.RAISED,
            NightwellDesign.RADIUS_CONTROL, false));
    }
}
