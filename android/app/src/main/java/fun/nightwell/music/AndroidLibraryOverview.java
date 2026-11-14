package fun.nightwell.music;

import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.Shader;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import org.json.JSONArray;
import org.json.JSONObject;

/** Library entry point. Preview rows retain the complete favorites playback context. */
final class AndroidLibraryOverview extends ScrollView {
    interface Actions {
        void openFavorites();
        void openPlaylists();
        void openOffline();
        void openDailyPlaylists();
        void openSmartPlaylists();
        void play(JSONObject track, JSONArray fullQueue);
        void menu(JSONObject track);
    }
    interface CoverBinder { void bind(ImageView image, JSONObject track); }

    private final LinearLayout content;
    private TextView smartDetail;
    private View smartTile;

    AndroidLibraryOverview(Context context, JSONArray favorites, int totalLikes,
                           int playlistCount, int offlineCount, Actions actions,
                           CoverBinder covers) {
        super(context);
        setClipToPadding(false);
        setVerticalScrollBarEnabled(false);
        content = column();
        content.setPadding(0, dp(4), 0, dp(16));
        addView(content, new ScrollView.LayoutParams(-1, -2));

        LinearLayout hero = row();
        hero.setMinimumHeight(dp(112));
        Heart heart = new Heart(context);
        LinearLayout.LayoutParams heartSize = new LinearLayout.LayoutParams(dp(80), dp(84));
        heartSize.setMarginEnd(dp(16));
        hero.addView(heart, heartSize);
        LinearLayout names = column();
        TextView title = text("Избранное", 23, Color.WHITE, true);
        names.addView(title);
        TextView count = text(count(totalLikes, "трек", "трека", "треков"), 15, 0xff929099, false);
        count.setPadding(0, dp(7), 0, 0);
        names.addView(count);
        hero.addView(names, new LinearLayout.LayoutParams(0, -2, 1));
        hero.addView(text("›", 28, 0xff88858f, false));
        clickable(hero, "Избранное, " + count.getText(), actions::openFavorites);
        content.addView(hero);

        JSONArray fullQueue = favorites == null ? new JSONArray() : favorites;
        for (int i = 0; i < Math.min(3, fullQueue.length()); i++) {
            JSONObject track = fullQueue.optJSONObject(i);
            if (track == null) continue;
            LinearLayout preview = row();
            preview.setPadding(0, dp(6), 0, dp(6));
            ImageView cover = new ImageView(context);
            cover.setScaleType(ImageView.ScaleType.CENTER_CROP);
            cover.setBackground(rounded(0xff25232c, 8));
            cover.setClipToOutline(true);
            cover.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
            LinearLayout.LayoutParams coverSize = new LinearLayout.LayoutParams(dp(56), dp(56));
            coverSize.setMarginEnd(dp(12));
            preview.addView(cover, coverSize);
            if (covers != null) covers.bind(cover, track);
            LinearLayout labels = column();
            String trackTitle = track.optString("title", "Без названия");
            TextView name = text(trackTitle, 16, Color.WHITE, false);
            name.setSingleLine(true); name.setEllipsize(TextUtils.TruncateAt.END);
            TextView artist = text(track.optString("artist", ""), 14, 0xff99969f, false);
            artist.setSingleLine(true); artist.setEllipsize(TextUtils.TruncateAt.END);
            artist.setPadding(0, dp(4), 0, 0);
            labels.addView(name); labels.addView(artist);
            preview.addView(labels, new LinearLayout.LayoutParams(0, -2, 1));
            TextView more = text("•••", 16, 0xffb3afba, true);
            more.setGravity(Gravity.CENTER);
            clickable(more, "Действия с треком «" + trackTitle + "»", () -> actions.menu(track));
            preview.addView(more, new LinearLayout.LayoutParams(dp(44), dp(48)));
            preview.setOnClickListener(v -> actions.play(track, fullQueue));
            preview.setFocusable(true);
            content.addView(preview);
        }
        TextView heading = text("Ещё в медиатеке", 21, Color.WHITE, true);
        if (android.os.Build.VERSION.SDK_INT >= 28) heading.setAccessibilityHeading(true);
        heading.setPadding(0, dp(30), 0, dp(12));
        content.addView(heading);
        boolean largeText = getResources().getConfiguration().fontScale >= 1.4f;
        LinearLayout tiles = null;
        View[] entries = {
            tile("Плейлисты", "♫", count(playlistCount, "плейлист", "плейлиста", "плейлистов"), actions::openPlaylists),
            tile("Офлайн", "↓", count(offlineCount, "трек", "трека", "треков"), actions::openOffline),
            tile("Подборки дня", "✦", "Для тебя", actions::openDailyPlaylists),
            tile("Умные плейлисты", "≋", "Premium", actions::openSmartPlaylists)
        };
        for (int i = 0; i < entries.length; i++) {
            if (largeText || i % 2 == 0) { tiles = row(); content.addView(tiles); }
            LinearLayout.LayoutParams size = new LinearLayout.LayoutParams(0, -2, 1);
            if (!largeText && i % 2 == 0) size.setMarginEnd(dp(12));
            tiles.addView(entries[i], size);
        }
    }

    /** Reflect a verified paid tier without rebuilding or losing the overview scroll. */
    void setSmartAvailable(boolean available) {
        if (smartDetail == null || smartTile == null) return;
        String detail = available ? "Для тебя" : "Premium";
        smartDetail.setText(detail);
        smartTile.setContentDescription("Умные плейлисты, " + detail);
    }

    void setBottomInset(int px) {
        content.setPadding(0, dp(4), 0, Math.max(dp(16), px));
    }

    private View tile(String title, String symbol, String detail, Runnable action) {
        LinearLayout tile = row();
        tile.setMinimumHeight(dp(80));
        tile.setPadding(0, dp(8), 0, dp(8));
        TextView icon = text(symbol, 29, 0xffe7e5ed, false);
        icon.setGravity(Gravity.CENTER);
        icon.setBackground(rounded(0x0dffffff, 12));
        LinearLayout.LayoutParams iconSize = new LinearLayout.LayoutParams(dp(48), dp(48));
        iconSize.setMarginEnd(dp(8));
        tile.addView(icon, iconSize);
        LinearLayout labels = column();
        labels.addView(text(title, 15, Color.WHITE, true));
        TextView subtitle = text(detail, 12, 0xff8c8994, false);
        subtitle.setPadding(0, dp(4), 0, 0);
        labels.addView(subtitle);
        tile.addView(labels, new LinearLayout.LayoutParams(0, -2, 1));
        if ("Умные плейлисты".equals(title)) {
            smartDetail = subtitle;
            smartTile = tile;
        }
        clickable(tile, title + ", " + detail, action);
        return tile;
    }
    private void clickable(View view, String label, Runnable action) {
        view.setContentDescription(label);
        view.setFocusable(true);
        view.setOnClickListener(v -> action.run());
    }
    private LinearLayout column() {
        LinearLayout layout = new LinearLayout(getContext());
        layout.setOrientation(LinearLayout.VERTICAL);
        return layout;
    }
    private LinearLayout row() {
        LinearLayout layout = new LinearLayout(getContext());
        layout.setOrientation(LinearLayout.HORIZONTAL);
        layout.setGravity(Gravity.CENTER_VERTICAL);
        return layout;
    }
    private TextView text(String value, int size, int color, boolean bold) {
        TextView label = new TextView(getContext());
        label.setText(value); label.setTextSize(size); label.setTextColor(color);
        label.setTypeface(Typeface.DEFAULT, bold ? Typeface.BOLD : Typeface.NORMAL);
        label.setIncludeFontPadding(false);
        return label;
    }
    private GradientDrawable rounded(int color, int radius) {
        GradientDrawable shape = new GradientDrawable();
        shape.setColor(color); shape.setCornerRadius(dp(radius));
        return shape;
    }
    private int dp(int value) { return Math.round(value * getResources().getDisplayMetrics().density); }
    private static String count(int value, String one, String few, String many) {
        int n = Math.max(0, value), end = n % 100;
        return n + " " + (end >= 11 && end <= 14 ? many : n % 10 == 1 ? one
            : n % 10 >= 2 && n % 10 <= 4 ? few : many);
    }
    private static final class Heart extends View {
        private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Path path = new Path();
        Heart(Context context) {
            super(context); setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO);
            path.moveTo(50, 93);
            path.cubicTo(38, 83, 2, 58, 4, 29);
            path.cubicTo(6, 3, 37, 1, 50, 22);
            path.cubicTo(66, -1, 96, 5, 97, 31);
            path.cubicTo(98, 57, 69, 82, 50, 93);
            paint.setShader(new LinearGradient(8, 8, 92, 95,
                new int[]{0xffebcaff, 0xffba7af5, 0xff6b45bf}, null, Shader.TileMode.CLAMP));
        }
        @Override protected void onDraw(Canvas canvas) {
            super.onDraw(canvas);
            canvas.save(); canvas.scale(getWidth() / 100f, getHeight() / 100f);
            canvas.rotate(-8, 50, 50);
            canvas.drawPath(path, paint); canvas.restore();
        }
    }
}
