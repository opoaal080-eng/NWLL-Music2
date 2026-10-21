package fun.nightwell.music;
import android.content.Context;
import org.json.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;

final class OfflineStore {
    static void importFile(Context context,String origin,android.net.Uri uri)throws Exception {
        String name="Локальный трек";
        try(android.database.Cursor cursor=context.getContentResolver().query(uri,null,null,null,null)){if(cursor!=null&&cursor.moveToFirst()){int index=cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME);if(index>=0)name=cursor.getString(index);}}
        byte[] bytes=NativeAPI.read(context.getContentResolver().openInputStream(uri),LIMIT);
        String id="local_"+java.util.UUID.randomUUID().toString().replace("-","");
        File root=directory(context,origin,"device");
        String mime=context.getContentResolver().getType(uri);
        JSONObject meta=new JSONObject().put("id",id).put("title",name).put("artist","На этом устройстве").put("_offline",true).put("_offline_account","device").put("_mime",mime==null?"audio/mpeg":mime);
        atomic(new File(root,id+".m4a"),bytes);atomic(new File(root,id+".json"),meta.toString().getBytes(StandardCharsets.UTF_8));
    }
    static synchronized void saveStream(Context context,String origin,String account,JSONObject track,InputStream input)throws Exception {
        String id=track.getString("id");if(!valid(id))throw new IOException("Invalid track");
        File root=directory(context,origin,account),target=new File(root,id+".m4a"),temp=new File(root,id+".download.tmp");
        long size=0;byte[] header=new byte[8];int headerSize=0;
        try{
            try(FileOutputStream out=new FileOutputStream(temp)){
                byte[] buffer=new byte[16384];int n;while((n=input.read(buffer))!=-1){size+=n;if(size>LIMIT)throw new IOException("Слишком большой файл");if(headerSize<8){int copy=Math.min(n,8-headerSize);System.arraycopy(buffer,0,header,headerSize,copy);headerSize+=copy;}out.write(buffer,0,n);}out.getFD().sync();
            }
            if(size<=256||headerSize<8||!new String(header,4,4,StandardCharsets.US_ASCII).equals("ftyp"))throw new IOException("Invalid audio");
            JSONObject meta=new JSONObject(track.toString()).put("_offline",true).put("_offline_account",account).put("offline_bytes",size);
            byte[] bytes=meta.toString().getBytes(StandardCharsets.UTF_8);if(bytes.length>2*1024*1024)throw new IOException("Metadata too large");
            if(!temp.renameTo(target))throw new IOException("Unable to save");atomic(new File(root,id+".json"),bytes);
        }finally{temp.delete();}
    }
    static final int LIMIT=32*1024*1024;
    private static boolean valid(String s){return s!=null&&s.matches("[A-Za-z0-9_-]{1,80}");}
    private static File directory(Context context,String origin,String account) throws Exception {
        if(!valid(account))throw new IOException("Invalid account");
        byte[] hash=MessageDigest.getInstance("SHA-256").digest((origin.replaceAll("/+$","")+"|"+account).getBytes(StandardCharsets.UTF_8));
        StringBuilder key=new StringBuilder();for(byte b:hash)key.append(String.format("%02x",b&255));
        String scope=account.matches("local_[a-f0-9]{64}")?account.substring(6):key.toString();
        File root=new File(new File(context.getFilesDir(),"offline"),scope);if(!root.isDirectory()&&!root.mkdirs())throw new IOException("Storage unavailable");return root;
    }
    static synchronized File audio(Context context,String origin,String account,String id){
        try{if(!valid(id))return null;File root=directory(context,origin,account),file=new File(root,id+".m4a");return file.isFile()&&new File(root,id+".json").isFile()?file:null;}catch(Exception e){return null;}
    }
    private static void atomic(File file,byte[] data) throws IOException {
        File temp=new File(file.getParentFile(),file.getName()+".tmp");
        try(FileOutputStream out=new FileOutputStream(temp)){out.write(data);out.getFD().sync();}
        if(!temp.renameTo(file)){temp.delete();throw new IOException("Unable to save");}
    }
    static synchronized String operation(Context context,String origin,String raw){
        try{
            JSONObject body=new JSONObject(raw);String op=body.getString("op");
            if(op.equals("listAll")){
                JSONArray tracks=new JSONArray();File[] dirs=new File(context.getFilesDir(),"offline").listFiles();
                if(dirs!=null)for(File dir:dirs)if(dir.isDirectory()&&dir.getName().matches("[a-f0-9]{64}")){
                    File[] files=dir.listFiles();if(files==null)continue;
                    for(File f:files)if(f.getName().endsWith(".json")&&f.length()<=2*1024*1024){
                        try{byte[] data=new byte[(int)f.length()];try(DataInputStream in=new DataInputStream(new FileInputStream(f))){in.readFully(data);}
                            JSONObject t=new JSONObject(new String(data,StandardCharsets.UTF_8));String id=t.optString("id");
                            if(valid(id)&&new File(dir,id+".m4a").isFile())tracks.put(t.put("_offline",true).put("_offline_account","local_"+dir.getName()));
                        }catch(Exception ignored){}
                    }
                }
                return new JSONObject().put("tracks",tracks).toString();
            }
            String account=body.optString("account","device");File root=directory(context,origin,account);
            if(op.equals("list")){
                JSONArray tracks=new JSONArray();File[] files=root.listFiles();if(files!=null)for(File f:files)if(f.getName().endsWith(".json")&&f.length()<2*1024*1024){
                    try{byte[] data=new byte[(int)f.length()];try(DataInputStream in=new DataInputStream(new FileInputStream(f))){in.readFully(data);}JSONObject t=new JSONObject(new String(data,StandardCharsets.UTF_8));if(audio(context,origin,account,t.optString("id"))!=null)tracks.put(t);}catch(Exception ignored){}
                }return new JSONObject().put("tracks",tracks).toString();
            }
            String id=body.getString("id");if(!valid(id))throw new IOException("Invalid track");File audio=new File(root,id+".m4a"),meta=new File(root,id+".json");
            if(op.equals("remove")){meta.delete();audio.delete();return "{\"ok\":true}";}
            String encoded=body.optString("audio");if(!op.equals("save")||encoded.length()>LIMIT*4/3+4)throw new IOException("Invalid audio");
            byte[] bytes=android.util.Base64.decode(encoded,android.util.Base64.DEFAULT);if(bytes.length<=256||bytes.length>LIMIT||!new String(bytes,4,4,StandardCharsets.US_ASCII).equals("ftyp"))throw new IOException("Invalid audio");
            JSONObject track=body.getJSONObject("track");if(!track.optString("id").equals(id))throw new IOException("Invalid metadata");track.put("_offline",true).put("_offline_account",account).put("offline_bytes",bytes.length);
            byte[] metadata=track.toString().getBytes(StandardCharsets.UTF_8);if(metadata.length>2*1024*1024)throw new IOException("Metadata too large");
            atomic(audio,bytes);atomic(meta,metadata);return new JSONObject().put("ok",true).put("size",bytes.length).toString();
        }catch(Exception e){return "{\"error\":\"Не удалось сохранить трек на устройстве\"}";}
    }
}

