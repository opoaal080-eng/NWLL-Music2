package fun.nightwell.music;

/** Plain JVM contract tests for responsive player cover geometry. */
public final class PlayerArtworkSizingTest {
    private static void check(int expected, int actual) {
        if (expected != actual) throw new AssertionError("Expected " + expected + ", got " + actual);
    }

    public static void main(String[] args) {
        check(320, PlayerArtworkSizing.sizeDp(360, 800, false));
        check(312, PlayerArtworkSizing.sizeDp(360, 800, true));
        check(249, PlayerArtworkSizing.sizeDp(360, 640, false));
        check(180, PlayerArtworkSizing.sizeDp(800, 360, false));
        check(440, PlayerArtworkSizing.sizeDp(840, 1200, false));
        for (int[] display : new int[][]{{320,568},{360,780},{412,915},{800,360},{960,600}}) {
            for (boolean classic : new boolean[]{false,true}) {
                int size = PlayerArtworkSizing.sizeDp(display[0],display[1],classic);
                if (size > display[0] - (classic ? 48 : 40)
                    || size > (classic ? 330 : 440) || size < 96) {
                    throw new AssertionError("Artwork clips: "+display[0]+"x"+display[1]);
                }
            }
        }
        System.out.println("PlayerArtworkSizing passed");
    }
}
