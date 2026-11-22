package fun.nightwell.music;

import android.content.Context;
import android.content.res.Configuration;
import android.graphics.Canvas;
import android.graphics.LinearGradient;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.Shader;
import android.graphics.Typeface;
import android.text.TextUtils;
import android.view.Gravity;
import android.view.View;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;
import org.json.JSONArray;
import org.json.JSONObject;

/** The overview reads the same sorted snapshot and artwork cache as Favorites. */
final class AndroidLibraryOverview extends ScrollView {
    private final MainActivity activity;
    private final LinearLayout content;
    private final boolean compact;
    private TextView offlineDetail, smartDetail;

    AndroidLibraryOverview(MainActivity activity, JSONArray favorites, int liked, int playlists,
                           ArtworkCache artwork, String origin) {
        super(activity);
        this.activity = activity;
        Configuration config = getResources().getConfiguration();
        compact = config.screenHeightDp < 740;
        setVerticalScrollBarEnabled(false);
        content = column();
        content.setPadding(dp(4), dp(4), dp(4), dp(16));
        addView(content);
        addFavorites(liked);
        for (int i = 0; i < Math.min(3, favorites.length()); i++) {
            JSONObject track = favorites.optJSONObject(i);
            if (track != null) addTrack(track, favorites, artwork, origin);
        }

        TextView sections = label("Ещё в медиатеке", 20, 0xfff7f7f8, true);
        sections.setPadding(0, dp(compact ? 10 : 22), 0, dp(compact ? 6 : 10));
        if (android.os.Build.VERSION.SDK_INT >= 28) sections.setAccessibilityHeading(true);
        content.addView(sections);
        View[] tiles = {
            tile("Плейлисты", "playlist", count(playlists,"плейлист","плейлиста","плейлистов"),
                () -> activity.navigate("Плейлисты")),
            tile("Офлайн", "download", "…", () -> activity.navigate("Офлайн")),
            tile("Подборки дня", "sparkles", "Для тебя", activity::dailyPublicPlaylists),
            tile("Умные плейлисты", "waveform", "Для тебя", () -> activity.feature("smart"))
        };
        boolean oneColumn = config.fontScale >= 1.4f || config.screenWidthDp < 315;
        for (int i = 0; i < tiles.length;) {
            LinearLayout pair = row();
            pair.setBaselineAligned(false);
            content.addView(pair);
            pair.addView(tiles[i++], new LinearLayout.LayoutParams(0,-2,1));
            if (!oneColumn && i < tiles.length) {
                LinearLayout.LayoutParams second = new LinearLayout.LayoutParams(0,-2,1);
                second.setMarginStart(dp(12));
                pair.addView(tiles[i++], second);
            }
        }
    }

    private void addFavorites(int liked) {
        LinearLayout hero = row();
        hero.setMinimumHeight(dp(compact ? 96 : 112));
        LinearLayout.LayoutParams art = new LinearLayout.LayoutParams(dp(compact ? 70 : 76),dp(compact ? 72 : 80));
        art.setMarginEnd(dp(12));
        hero.addView(new FavoriteHeart(getContext()), art);
        LinearLayout copy = column();
        copy.addView(label("Избранное",22,0xfffafafa,true));
        TextView total = label(count(liked,"трек","трека","треков"),15,0xff949498,false);
        total.setPadding(0,dp(7),0,0);
        copy.addView(total);
        hero.addView(copy, new LinearLayout.LayoutParams(0,-2,1));
        hero.addView(icon("chevron",0xff77777c), new LinearLayout.LayoutParams(dp(16),dp(20)));
        action(hero, () -> activity.navigate("Избранное"));
        content.addView(hero);
    }

    private void addTrack(JSONObject track, JSONArray fullQueue, ArtworkCache cache, String origin) {
        LinearLayout preview = row();
        preview.setPadding(dp(8),dp(5),dp(5),dp(5));
        preview.setMinimumHeight(dp(compact ? 65 : 80));
        ImageView cover = new ImageView(getContext());
        cover.setScaleType(ImageView.ScaleType.CENTER_CROP);
        cover.setBackground(NightwellDesign.surface(getContext(),0xff212126,8,false));
        cover.setClipToOutline(true);
        cover.setImportantForAccessibility(View.IMPORTANT_FOR_ACCESSIBILITY_NO);
        int side = dp(compact ? 48 : 56);
        LinearLayout.LayoutParams art = new LinearLayout.LayoutParams(side,side);
        art.setMarginEnd(dp(12));
        preview.addView(cover,art);
        cache.load(cover,origin,track.optString("cover_url"));
        String title = track.optString("title","Без названия");
        LinearLayout copy = column();
        TextView name = label(title,16,0xfff6f6f7,false);
        name.setTypeface(Typeface.create("sans-serif-medium",0));
        TextView by = label(track.optString("artist"),15,0xff929296,false);
        for (TextView line : new TextView[]{name,by}) {
            line.setSingleLine(true);
            line.setEllipsize(TextUtils.TruncateAt.END);
            copy.addView(line);
        }
        by.setPadding(0,dp(4),0,0);
        preview.addView(copy,new LinearLayout.LayoutParams(0,-2,1));
        NativeIconButton more = new NativeIconButton(getContext());
        more.setText("⋯");
        more.setGravity(Gravity.CENTER);
        more.setTextColor(0xfffafafa);
        more.setContentDescription("Действия с треком «" + title + "»");
        action(more, () -> activity.trackMenu(track));
        preview.addView(more,new LinearLayout.LayoutParams(dp(54),dp(48)));
        action(preview, () -> activity.play(track,fullQueue,false));
        content.addView(preview);
    }

    private View tile(String title, String symbol, String detail, Runnable tap) {
        LinearLayout tile = row();
        tile.setMinimumHeight(dp(compact ? 64 : 72));
        NavigationMenuIcon icon = icon(symbol,0xffe9e9eb);
        int pad = dp(compact ? 9 : 10);
        icon.setPadding(pad,pad,pad,pad);
        icon.setBackground(NightwellDesign.surface(getContext(),0x0fffffff,12,false));
        int side = dp(compact ? 42 : 44);
        LinearLayout.LayoutParams box = new LinearLayout.LayoutParams(side,side);
        box.setMarginEnd(dp(8));
        tile.addView(icon,box);
        LinearLayout copy = column();
        TextView name = label(title,15,0xfff5f5f6,true);
        name.setTypeface(Typeface.create("sans-serif-medium",0));
        copy.addView(name);
        TextView value = label(detail,12,0xff8f8f93,false);
        value.setPadding(0,dp(4),0,0);
        copy.addView(value);
        tile.addView(copy,new LinearLayout.LayoutParams(0,-2,1));
        if (symbol.equals("download")) offlineDetail = value;
        if (symbol.equals("waveform")) smartDetail = value;
        action(tile,tap);
        return tile;
    }

    void setOfflineCount(int tracks) { offlineDetail.setText(count(tracks,"трек","трека","треков")); }
    void setSmartAvailable(boolean allowedOrUnknown) { smartDetail.setText(allowedOrUnknown ? "Для тебя" : "Premium"); }
    private static String count(int n,String one,String few,String many) {
        int tens = n%100, units = n%10;
        String word = tens>=11 && tens<=14 ? many : units==1 ? one : units>=2 && units<=4 ? few : many;
        return n + " " + word;
    }
    private void action(View item,Runnable action) {
        item.setBackground(NightwellDesign.plainButton(getContext(),12));
        item.setOnClickListener(v -> action.run());
        item.setFocusable(true);
    }
    private TextView label(String value,int size,int color,boolean bold) {
        TextView label = new TextView(getContext());
        label.setText(value); label.setTextSize(size); label.setTextColor(color);
        label.setTypeface(Typeface.DEFAULT,bold ? Typeface.BOLD : Typeface.NORMAL);
        label.setIncludeFontPadding(false);
        return label;
    }
    private LinearLayout row() {
        LinearLayout layout = new LinearLayout(getContext());
        layout.setGravity(Gravity.CENTER_VERTICAL);
        return layout;
    }
    private LinearLayout column() {
        LinearLayout layout = new LinearLayout(getContext());
        layout.setOrientation(LinearLayout.VERTICAL);
        return layout;
    }
    private NavigationMenuIcon icon(String symbol,int color) { return new NavigationMenuIcon(getContext(),symbol,color); }
    private int dp(int value) { return NightwellDesign.dp(getContext(),value); }

    private static final class FavoriteHeart extends View {
        private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private final Path heart = new Path();

        FavoriteHeart(Context context) {
            super(context);
            setImportantForAccessibility(IMPORTANT_FOR_ACCESSIBILITY_NO);
            heart.moveTo(50,92);
            heart.cubicTo(38,84,4,60,4,32);
            heart.cubicTo(4,7,35,0,50,22);
            heart.cubicTo(67,-1,96,7,96,31);
            heart.cubicTo(98,57,68,82,50,92);
            heart.close();
            paint.setShader(new LinearGradient(8,8,92,95,
                new int[]{0xffebcaff,0xffba7af5,0xff6b45bf},null,Shader.TileMode.CLAMP));
        }
        @Override protected void onDraw(Canvas canvas) {
            canvas.save();
            canvas.scale(getWidth()/100f,getHeight()/100f);
            canvas.rotate(-8,50,50);
            canvas.drawPath(heart,paint);
            canvas.restore();
        }
    }
}
