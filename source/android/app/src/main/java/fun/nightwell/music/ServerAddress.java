package fun.nightwell.music;

import java.net.URI;
import java.net.URISyntaxException;

final class ServerAddress {
    static String normalize(String input) {
        try {
            URI uri = new URI(input.trim());
            if (!"https".equalsIgnoreCase(uri.getScheme()) || uri.getHost() == null
                    || uri.getUserInfo() != null || uri.getQuery() != null || uri.getFragment() != null
                    || (!uri.getPath().isEmpty() && !"/".equals(uri.getPath()))
                    || uri.getPort() == 0 || uri.getPort() > 65535) return null;
            return new URI("https", null, uri.getHost().toLowerCase(java.util.Locale.ROOT),
                    uri.getPort(), "/", null, null).toASCIIString();
        } catch (URISyntaxException | NullPointerException ex) { return null; }
    }

    static boolean sameOrigin(String server, String destination) {
        try {
            URI a = new URI(server), b = new URI(destination);
            return "https".equalsIgnoreCase(b.getScheme()) && b.getUserInfo() == null
                    && a.getHost() != null && a.getHost().equalsIgnoreCase(b.getHost())
                    && port(a) == port(b);
        } catch (URISyntaxException | NullPointerException ex) { return false; }
    }
    private static int port(URI uri) { return uri.getPort() == -1 ? 443 : uri.getPort(); }
}
