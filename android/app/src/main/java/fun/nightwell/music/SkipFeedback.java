package fun.nightwell.music;

import android.content.Context;
import org.json.JSONObject;
import java.util.*;

/** Short, reversible discovery cooldown after repeated early skips. */
final class SkipFeedback {
    static final long WEEK=7L*86400000, COOLDOWN=48L*3600000;
    static int next(int count,long last,long now) {
        return now>=last && now-last<WEEK ? Math.min(20,count+1) : 1;
    }
    static boolean blocked(int count,long last,long now) {
        return count>=2 && now>=last && now-last<COOLDOWN;
    }
    private static String scope(String origin,String account) { return origin+"|"+account; }
    static Set<String> recentIDs(Context context,String origin,String account) {
        Set<String> ids=new HashSet<>();
        try {
            String value=context.getSharedPreferences("skip-feedback",Context.MODE_PRIVATE)
                .getString(scope(origin,account),"{}");
            JSONObject data=new JSONObject(value);
            long now=System.currentTimeMillis();
            Iterator<String> it=data.keys();
            while(it.hasNext()) {
                String id=it.next();JSONObject event=data.optJSONObject(id);
                if(event!=null&&blocked(event.optInt("n"),event.optLong("t"),now))ids.add(id);
            }
        }catch(Exception ignored){}
        return ids;
    }
    static synchronized void record(Context context,String origin,String account,String id) {
        if(id==null||id.isEmpty()||id.length()>80||account==null||account.isEmpty()||account.equals("device"))return;
        try {
            android.content.SharedPreferences p=context.getSharedPreferences("skip-feedback",Context.MODE_PRIVATE);
            String key=scope(origin,account);
            JSONObject old=new JSONObject(p.getString(key,"{}")), result=new JSONObject();
            long now=System.currentTimeMillis();
            JSONObject previous=old.optJSONObject(id);
            int count=next(previous==null?0:previous.optInt("n"),
                previous==null?0:previous.optLong("t"),now);
            List<String> valid=new ArrayList<>();
            Iterator<String> it=old.keys();
            while(it.hasNext()) {
                String candidate=it.next();
                JSONObject item=old.optJSONObject(candidate);
                if(!candidate.equals(id)&&item!=null&&now>=item.optLong("t")
                    && now-item.optLong("t")<WEEK)valid.add(candidate);
            }
            valid.sort((a,b)->Long.compare(old.optJSONObject(b).optLong("t"),old.optJSONObject(a).optLong("t")));
            for(int i=0;i<Math.min(199,valid.size());i++)
                result.put(valid.get(i),old.optJSONObject(valid.get(i)));
            result.put(id,new JSONObject().put("n",count).put("t",now));
            p.edit().putString(key,result.toString()).apply();
        }catch(Exception ignored){}
    }
}
