package fun.nightwell.music;

public final class ArtistAttributionTest {
    private static void eq(Object left,Object right,String why) {
        if(!left.equals(right))throw new AssertionError(why+": "+left+" != "+right);
    }
    private static void yes(boolean check,String why) {
        if(!check)throw new AssertionError(why);
    }
    public static void main(String[] args){
        ArtistAttribution.Result a=ArtistAttribution.resolve(
            "Клава Кока — Покинула чат","uploaded_by","soundcloud",null,true,null,null);
        eq(a.artist,"Клава Кока","artist from title");
        eq(a.title,"Покинула чат","song title");
        eq(a.uploader,"uploaded_by","separate uploader");
        ArtistAttribution.Result b=ArtistAttribution.resolve(
            "Покинула чат","uploaded_by","soundcloud",null,true,null,null);
        eq(b.artist,ArtistAttribution.UNKNOWN,"must not show uploader as musician");
        yes(!b.attributed,"must not open unverified artist");
        ArtistAttribution.Result c=ArtistAttribution.resolve(
            "Песня","posted_by","soundcloud",null,true,"Реальный артист",null);
        eq(c.artist,"Реальный артист","dedicated credit");
        ArtistAttribution.Result d=ArtistAttribution.resolve(
            "Клава Кока, NILETTO - Краш","someaccount","soundcloud",null,true,null,null);
        eq(d.artist,"Клава Кока, NILETTO","featured artists");
        ArtistAttribution.Result e=ArtistAttribution.resolve(
            "Песня","Artist","local",null,false,null,null);
        eq(e.artist,"Artist","local musician");
        ArtistAttribution.Result f=ArtistAttribution.resolve(
            "Песня - Remix","uploaded_by","soundcloud",null,true,null,null);
        eq(f.artist,ArtistAttribution.UNKNOWN,"version is not an artist");
        System.out.println("Artist attribution Java tests passed");
    }
}
