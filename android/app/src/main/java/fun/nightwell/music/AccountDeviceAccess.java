package fun.nightwell.music;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.Build;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;
import org.json.JSONObject;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.security.MessageDigest;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

/** Server-issued device credential is not the playback hand-off ID. */
final class AccountDeviceAccess {
    private static final String ALIAS = "nightwell.account-device.v1";
    private static final String PREFS = "nw-device-credentials";
    private AccountDeviceAccess() {}

    private static SecretKey key() throws Exception {
        KeyStore store = KeyStore.getInstance("AndroidKeyStore");
        store.load(null);
        if (store.containsAlias(ALIAS)) return (SecretKey) store.getKey(ALIAS, null);
        KeyGenerator generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
        generator.init(new KeyGenParameterSpec.Builder(ALIAS,
                KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build());
        return generator.generateKey();
    }

    private static String storageKey(String origin, String account) throws Exception {
        byte[] digest = MessageDigest.getInstance("SHA-256")
                .digest((origin + "|" + account).getBytes(StandardCharsets.UTF_8));
        StringBuilder result = new StringBuilder();
        for (byte b : digest) result.append(String.format(java.util.Locale.ROOT, "%02x", b & 0xff));
        return result.toString();
    }

    private static JSONObject read(Context context, String origin, String account) throws Exception {
        SharedPreferences prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        String encrypted = prefs.getString(storageKey(origin, account), null);
        if (encrypted == null) return null;
        String[] pieces = encrypted.split(":", 2);
        if (pieces.length != 2) throw new java.io.IOException("Повреждён ключ устройства.");
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.DECRYPT_MODE, key(),
                new GCMParameterSpec(128, Base64.decode(pieces[0], Base64.NO_WRAP)));
        byte[] plain = cipher.doFinal(Base64.decode(pieces[1], Base64.NO_WRAP));
        JSONObject credential = new JSONObject(new String(plain, StandardCharsets.UTF_8));
        if (credential.optString("device_id").isEmpty() || credential.optString("device_token").isEmpty())
            throw new java.io.IOException("Некорректный сохранённый ключ устройства.");
        return credential;
    }

    private static void save(Context context, String origin, String account, JSONObject credential) throws Exception {
        Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
        cipher.init(Cipher.ENCRYPT_MODE, key());
        String encrypted = Base64.encodeToString(cipher.getIV(), Base64.NO_WRAP) + ":" +
                Base64.encodeToString(cipher.doFinal(credential.toString().getBytes(StandardCharsets.UTF_8)),
                        Base64.NO_WRAP);
        boolean saved = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
                .putString(storageKey(origin, account), encrypted).commit();
        if (!saved) throw new java.io.IOException("Не удалось защитить ключ устройства.");
    }

    static String token(Context context, String origin, String account) {
        if (account == null || account.isEmpty()) return "";
        try {
            JSONObject credential = read(context, origin, account);
            return credential == null ? "" : credential.optString("device_token", "");
        } catch (Exception ignored) {
            // Do not fall back to plaintext or invent a replacement credential.
            return "";
        }
    }

    static void bind(NativeAPI api, String account) throws Exception {
        api.updateDeviceToken("");
        if (account == null || account.isEmpty()) return;
        JSONObject saved = read(api.context, api.origin, account);
        JSONObject request = new JSONObject();
        request.put("platform", "android");
        String manufacturer = Build.MANUFACTURER == null ? "" : Build.MANUFACTURER.trim();
        String model = Build.MODEL == null ? "Android" : Build.MODEL.trim();
        request.put("name", (manufacturer + " " + model).trim().substring(0,
                Math.min(80, (manufacturer + " " + model).trim().length())));
        if (saved != null) {
            request.put("device_id", saved.getString("device_id"));
            request.put("device_token", saved.getString("device_token"));
            api.updateDeviceToken(saved.getString("device_token"));
        }
        try {
            JSONObject response = api.request("api/devices/register", "POST", request);
            if (!response.optBoolean("ok")) throw new java.io.IOException("Сервер не подтвердил устройство.");
            JSONObject credential = new JSONObject();
            credential.put("device_id", response.getString("device_id"));
            credential.put("device_token", response.getString("device_token"));
            save(api.context, api.origin, account, credential);
            api.updateDeviceToken(credential.getString("device_token"));
        } catch (NetworkRetry.HttpFailure error) {
            if (error.status == 404) { // Old server without Account Access.
                api.updateDeviceToken("");
                return;
            }
            throw error;
        }
    }
}
