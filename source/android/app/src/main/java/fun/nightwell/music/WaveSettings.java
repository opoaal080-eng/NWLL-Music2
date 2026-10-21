package fun.nightwell.music;
import android.content.Context;
import org.json.JSONObject;

final class WaveSettings {
    static final String[][] VALUES={{"balanced","discover","favorites"},{"any","energetic","calm","happy","sad"},{"any","ru","foreign","instrumental"}};
    static final String[][] LABELS={{"На мой вкус","Открытия","Избранное"},{"Любое","Бодрое","Спокойное","Весёлое","Грустное"},{"Любой","Русский","Иностранный","Без слов"}};
    static final String[] KEYS={"character","mood","language"},TITLES={"Характер","Настроение","Язык"};
    final int[] selected=new int[3];
    WaveSettings(JSONObject value){for(int i=0;i<3;i++)for(int j=0;j<VALUES[i].length;j++)if(VALUES[i][j].equals(value.optString(KEYS[i])))selected[i]=j;}
    JSONObject json(){JSONObject result=new JSONObject();try{for(int i=0;i<3;i++)result.put(KEYS[i],VALUES[i][selected[i]]);}catch(Exception ignored){}return result;}
    String query(){StringBuilder value=new StringBuilder();for(int i=0;i<3;i++)value.append('&').append(KEYS[i]).append('=').append(VALUES[i][selected[i]]);return value.toString();}
    static WaveSettings read(Context context,String origin,String account){try{return new WaveSettings(new JSONObject(context.getSharedPreferences("wave-settings",0).getString(origin+"|"+account,"{}")));}catch(Exception ignored){return new WaveSettings(new JSONObject());}}
    void save(Context context,String origin,String account){context.getSharedPreferences("wave-settings",0).edit().putString(origin+"|"+account,json().toString()).apply();}
}
