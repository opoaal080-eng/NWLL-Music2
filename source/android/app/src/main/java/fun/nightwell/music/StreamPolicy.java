package fun.nightwell.music;

import java.net.URI;
import java.util.Locale;

final class StreamPolicy {
    // Restored/catalogue tracks may explicitly contain is_remote=false even
    // though their source is remote. That default must not force a full file.
    static boolean usesHls(boolean remote, String source, String sourceURL) {
        if (remote || "soundcloud".equalsIgnoreCase(source)) return true;
        try {
            String host = new URI(sourceURL).getHost();
            if (host == null) return false;
            host = host.toLowerCase(Locale.ROOT);
            return host.equals("soundcloud.com") || host.endsWith(".soundcloud.com");
        } catch (Exception ignored) { return false; }
    }
}
