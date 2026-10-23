package fun.nightwell.music;

import org.json.*;
import java.util.*;
import java.text.Normalizer;

/** Metadata only: parsing and duplicate removal run on the device's worker. */
final class TransferPreparation {
    static String key(String s) {
        return Normalizer.normalize(s,Normalizer.Form.NFKC).toLowerCase(Locale.ROOT)
            .replace('ё','е').replaceAll("[^\\p{L}\\p{N}]+"," ").trim();
    }
    static JSONArray parse(String raw) throws Exception {
        String text=raw.replaceFirst("^\\uFEFF","").trim();
        if(text.getBytes(java.nio.charset.StandardCharsets.UTF_8).length>1024*1024)throw new Exception("Максимальный размер 1 МБ");
        JSONArray rows=new JSONArray();
        if(text.startsWith("[")||text.startsWith("{")) {
            Object value=new JSONTokener(text).nextValue();
            JSONArray array=value instanceof JSONArray?(JSONArray)value:((JSONObject)value).optJSONArray("tracks");
            if(array==null)throw new Exception("В JSON нужен массив tracks");
            for(int i=0;i<array.length();i++) {
                JSONObject item=array.getJSONObject(i);if(item.optJSONObject("track")!=null)item=item.getJSONObject("track");
                Object artists=item.opt("artist");if(artists==null)artists=item.opt("artists");
                String artist="";
                if(artists instanceof JSONArray){JSONArray a=(JSONArray)artists;for(int j=0;j<a.length();j++){Object v=a.get(j);artist+=(j>0?", ":"")+(v instanceof JSONObject?((JSONObject)v).optString("name"):String.valueOf(v));}}
                else if(artists instanceof JSONObject)artist=((JSONObject)artists).optString("name");
                else if(artists instanceof String)artist=(String)artists;
                JSONObject row=track(item.optString("title",item.optString("name")),artist);
                double seconds=item.optDouble("duration",0);if(seconds<=0)seconds=item.optDouble("duration_ms",item.optDouble("durationMs",0))/1000;
                if(Double.isFinite(seconds)&&seconds>0&&seconds<86400)row.put("duration",seconds);
                rows.put(row);
            }
        } else {
            boolean csv=false;
            for(char delimiter:new char[]{'\t',';',','}) {
                List<List<String>> table=csv(text,delimiter);if(table.isEmpty())continue;
                int ti=-1,ai=-1;
                for(int i=0;i<table.get(0).size();i++) {String k=key(table.get(0).get(i)).replace(" ","");
                    if(Arrays.asList("title","track","trackname","song","songname","название","названиетрека","трек").contains(k))ti=i;
                    if(Arrays.asList("artist","artists","artistname","artistnames","исполнитель","исполнители").contains(k))ai=i;
                }
                if(ti<0||ai<0)continue;csv=true;
                for(int i=1;i<table.size();i++){List<String> row=table.get(i);if(String.join("",row).trim().isEmpty())continue;
                    if(row.size()<=Math.max(ti,ai))throw new Exception("Неполная строка CSV: "+(i+1));
                    rows.put(track(row.get(ti),row.get(ai)));
                }break;
            }
            if(!csv)for(String line:text.split("\\r?\\n")){if(line.trim().isEmpty())continue;String[] parts=line.split("\\s+[—–-]\\s+|\\t",2);
                if(parts.length!=2)throw new Exception("Нужен формат «Исполнитель — Название» или CSV с заголовком");rows.put(track(parts[1],parts[0]));}
        }
        if(rows.length()>1000)throw new Exception("Раздели список на части до 1000 треков");
        Set<String> seen=new HashSet<>();JSONArray unique=new JSONArray();
        for(int i=0;i<rows.length();i++){JSONObject row=rows.getJSONObject(i);if(seen.add(key(row.getString("artist"))+"\n"+key(row.getString("title"))))unique.put(row);}
        if(unique.length()==0)throw new Exception("В списке нет треков");return unique;
    }
    private static JSONObject track(String title,String artist)throws Exception {
        title=title.trim();artist=artist.trim();
        if(title.isEmpty()||artist.isEmpty()||title.length()>300||artist.length()>300)throw new Exception("Проверь название и исполнителя трека");
        return new JSONObject().put("title",title).put("artist",artist);
    }
    private static List<List<String>> csv(String text,char delimiter)throws Exception {
        List<List<String>> rows=new ArrayList<>();List<String> row=new ArrayList<>();StringBuilder field=new StringBuilder();boolean quoted=false;
        for(int i=0;i<text.length();i++){char c=text.charAt(i);
            if(c=='"'){if(quoted&&i+1<text.length()&&text.charAt(i+1)=='"'){field.append('"');i++;}else quoted=!quoted;}
            else if(!quoted&&(c==delimiter||c=='\n'||c=='\r')){row.add(field.toString());field.setLength(0);if(c!=delimiter){rows.add(row);row=new ArrayList<>();if(c=='\r'&&i+1<text.length()&&text.charAt(i+1)=='\n')i++;}}
            else field.append(c);
        }
        // Non-CSV text may include unmatched quotes; let the TXT parser handle it.
        if(quoted)return Collections.emptyList();row.add(field.toString());rows.add(row);return rows;
    }
}
