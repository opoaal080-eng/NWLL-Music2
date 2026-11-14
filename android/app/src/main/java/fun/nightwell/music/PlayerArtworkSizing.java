package fun.nightwell.music;

/**
 * Artwork size in dp, independent of display density and network/player state.
 * Fits the real content column, including landscape, without clipping controls.
 */
final class PlayerArtworkSizing {
    private PlayerArtworkSizing() { }

    static int sizeDp(int screenWidthDp, int screenHeightDp, boolean classic) {
        int width = Math.max(1, screenWidthDp);
        int height = Math.max(1, screenHeightDp);
        int contentWidth = Math.max(96, width - (classic ? 48 : 40));
        boolean landscape = width > height;
        float heightFraction = landscape ? 0.50f : height < 700 ? 0.39f : 0.46f;
        int usableHeight = Math.max(96, Math.round(height * heightFraction));
        int visualMaximum = classic ? 330 : 440;
        return Math.min(visualMaximum, Math.min(contentWidth, usableHeight));
    }
}
