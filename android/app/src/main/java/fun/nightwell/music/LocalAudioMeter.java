package fun.nightwell.music;

import android.os.SystemClock;
import androidx.media3.common.C;
import androidx.media3.exoplayer.audio.TeeAudioProcessor;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/** Observes decoded PCM without changing it or opening the microphone. */
@androidx.annotation.OptIn(markerClass = androidx.media3.common.util.UnstableApi.class)
final class LocalAudioMeter implements TeeAudioProcessor.AudioBufferSink {
    private int channels=2, encoding=C.ENCODING_PCM_16BIT, window=2205, frames;
    private double low, dc, sum, bassSum, lowAlpha, dcAlpha;
    private double midLow, midHigh, trebleLow, midLowAlpha, midHighAlpha, trebleAlpha;
    private double voiceSum, midSum, highSum;
    private volatile double level;
    private volatile double voiceLevel, bassLevel, midLevel, highLevel;
    private volatile long updated;
    @Override public void flush(int rate,int count,int format) {
        channels=Math.max(1,count);encoding=format;window=Math.max(1,rate/20);
        lowAlpha=1-Math.exp(-2*Math.PI*220/rate);
        dcAlpha=1-Math.exp(-2*Math.PI*30/rate);
        midLowAlpha=1-Math.exp(-2*Math.PI*300/rate);
        midHighAlpha=1-Math.exp(-2*Math.PI*3000/rate);
        trebleAlpha=1-Math.exp(-2*Math.PI*6000/rate);
        frames=0;low=dc=midLow=midHigh=trebleLow=sum=bassSum=voiceSum=midSum=highSum=0;
        level=voiceLevel=bassLevel=midLevel=highLevel=0;updated=0;
    }
    @Override public void handleBuffer(ByteBuffer input) {
        ByteBuffer b=input.duplicate().order(ByteOrder.LITTLE_ENDIAN);
        int bytes=encoding==C.ENCODING_PCM_FLOAT?4:encoding==C.ENCODING_PCM_16BIT?2:0;
        if(bytes==0)return;
        while(b.remaining()>=bytes*channels){
            double mono=0,power=0;
            for(int c=0;c<channels;c++){
                double value=bytes==4?b.getFloat():b.getShort()/32768.0;
                if(!Double.isFinite(value))value=0;
                mono+=value/channels;power+=value*value/channels;
            }
            dc+=dcAlpha*(mono-dc);low+=lowAlpha*(mono-dc-low);
            midLow+=midLowAlpha*(mono-midLow);
            midHigh+=midHighAlpha*(mono-midHigh);
            trebleLow+=trebleAlpha*(mono-trebleLow);
            double voice=midHigh-midLow;
            double mid=midHigh-low;
            double high=mono-trebleLow;
            sum+=power;bassSum+=low*low;
            voiceSum+=voice*voice;midSum+=mid*mid;highSum+=high*high;
            if(++frames>=window){
                level=Math.min(1,Math.sqrt(sum/frames)*.7+Math.sqrt(bassSum/frames)*3.8);
                bassLevel=Math.min(1,Math.sqrt(bassSum/frames)*4.0);
                voiceLevel=Math.min(1,Math.sqrt(voiceSum/frames)*3.0);
                midLevel=Math.min(1,Math.sqrt(midSum/frames)*2.6);
                highLevel=Math.min(1,Math.sqrt(highSum/frames)*3.0);
                updated=SystemClock.elapsedRealtime();frames=0;sum=bassSum=voiceSum=midSum=highSum=0;
            }
        }
    }
    double band(int index,boolean playing){
        long age=SystemClock.elapsedRealtime()-updated;
        if(!playing||age>=1000)return 0;
        double value=index==0?voiceLevel:index==1?bassLevel:index==2?midLevel:highLevel;
        return value*Math.exp(-Math.max(0,age-150)/333.0);
    }
    double level(boolean playing){long age=SystemClock.elapsedRealtime()-updated;return playing&&age<1000?level*Math.exp(-Math.max(0,age-150)/333.0):0;}
}

