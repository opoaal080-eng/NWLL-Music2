package fun.nightwell.music;

import android.content.Context;
import android.content.SharedPreferences;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.util.Base64;
import org.json.JSONObject;
import java.security.KeyStore;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;

/** Private, device-bound session storage across package updates. */
final class SessionStore {
    private static final String ALIAS="nightwell.session.v1";
    private static final long LIFETIME=7L*24*60*60*1000;
    private final SharedPreferences prefs;
    SessionStore(Context context){prefs=context.getSharedPreferences(ALIAS,Context.MODE_PRIVATE);}
    private SecretKey key() throws Exception {
        KeyStore store=KeyStore.getInstance("AndroidKeyStore");store.load(null);
        if(store.containsAlias(ALIAS))return (SecretKey)store.getKey(ALIAS,null);
        KeyGenerator generator=KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES,"AndroidKeyStore");
        generator.init(new KeyGenParameterSpec.Builder(ALIAS,KeyProperties.PURPOSE_ENCRYPT|KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build());
        return generator.generateKey();
    }
    private JSONObject read(){
        try{
            String value=prefs.getString("encrypted",null);if(value==null)return null;
            String[] pieces=value.split(":",2);if(pieces.length!=2)return null;
            Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.DECRYPT_MODE,key(),new GCMParameterSpec(128,Base64.decode(pieces[0],Base64.NO_WRAP)));
            JSONObject result=new JSONObject(new String(cipher.doFinal(Base64.decode(pieces[1],Base64.NO_WRAP)),java.nio.charset.StandardCharsets.UTF_8));
            if(result.getLong("expires")<=System.currentTimeMillis()){prefs.edit().remove("encrypted").commit();return null;}
            return result;
        }catch(Exception ignored){prefs.edit().remove("encrypted").commit();return null;}
    }
    static String token(String cookies){
        if(cookies!=null)for(String part:cookies.split(";")){
            String value=part.trim();if(value.startsWith("nw_session=")){
                String token=value.substring(11);
                // Session cookies may use URL-safe/base64 or signed dotted values.
                // Reject whitespace and separators, but do not reject valid signed cookies.
                if(token.matches("[A-Za-z0-9._~+/=-]{8,2048}"))return token;
            }
        }
        return null;
    }
    void save(String origin,String cookies){
        String token=token(cookies);if(token==null){clear();return;}
        try{
            JSONObject old=read();
            if(old!=null&&origin.equals(old.optString("origin"))&&token.equals(old.optString("token")))return;
            JSONObject value=new JSONObject();value.put("origin",origin);value.put("token",token);value.put("expires",System.currentTimeMillis()+LIFETIME);
            Cipher cipher=Cipher.getInstance("AES/GCM/NoPadding");cipher.init(Cipher.ENCRYPT_MODE,key());
            String sealed=Base64.encodeToString(cipher.getIV(),Base64.NO_WRAP)+":"+Base64.encodeToString(cipher.doFinal(value.toString().getBytes(java.nio.charset.StandardCharsets.UTF_8)),Base64.NO_WRAP);
            prefs.edit().putString("encrypted",sealed).commit();
        }catch(Exception ignored){
            // Android emulators can lack a functional AndroidKeyStore provider.
            // Keep the fallback inside app-private SharedPreferences.
            try {
                JSONObject value=new JSONObject();
                value.put("origin",origin);
                value.put("token",token);
                value.put("expires",System.currentTimeMillis()+LIFETIME);
                prefs.edit().putString("fallback",value.toString()).commit();
            }catch(Exception failed){}
        }
    }
    String restore(String origin){
        JSONObject value=read();
        if(value==null)try{
            String saved=prefs.getString("fallback",null);
            if(saved!=null)value=new JSONObject(saved);
        }catch(Exception ignored){}
        if(value==null||!origin.equals(value.optString("origin")))return null;
        long seconds=Math.max(0,(value.optLong("expires")-System.currentTimeMillis())/1000);
        if(seconds==0)return null;
        return "nw_session="+value.optString("token")+"; Path=/; Secure; HttpOnly; SameSite=Strict; Max-Age="+seconds;
    }
    void clear(){prefs.edit().remove("encrypted").remove("fallback").commit();}
}

