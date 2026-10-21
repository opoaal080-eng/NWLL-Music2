package fun.nightwell.music;

import java.nio.ByteBuffer;
import androidx.media3.common.C;
import androidx.media3.common.audio.BaseAudioProcessor;
import androidx.media3.common.audio.AudioProcessor;

/** Five peaking filters on the decoded PCM path; no additional player or output. */
@androidx.annotation.OptIn(markerClass=androidx.media3.common.util.UnstableApi.class)
final class PremiumEqualizer extends BaseAudioProcessor {
 private volatile double[] requested=new double[5];private volatile long until;
 private final FiveBandEQ engine=new FiveBandEQ();private int channels,rate;
 void set(double[] values,long expiry){double[] clean=new double[5];if(values!=null&&values.length==5)for(int i=0;i<5;i++)clean[i]=Double.isFinite(values[i])?Math.max(-6,Math.min(6,values[i])):0;requested=clean;until=expiry;}
 @Override protected AudioFormat onConfigure(AudioFormat f)throws AudioProcessor.UnhandledAudioFormatException{
  if(f.encoding!=C.ENCODING_PCM_16BIT)throw new AudioProcessor.UnhandledAudioFormatException(f);
  channels=f.channelCount;rate=f.sampleRate;engine.reset();return f;
 }
 @Override public void queueInput(ByteBuffer input){engine.configure(System.currentTimeMillis()<until?requested:new double[5],rate,channels);input.order(java.nio.ByteOrder.LITTLE_ENDIAN);ByteBuffer output=replaceOutputBuffer(input.remaining()).order(java.nio.ByteOrder.LITTLE_ENDIAN);int channel=0;while(input.remaining()>=2){double x=engine.sample(input.getShort()/32768.0,channel);output.putShort((short)Math.round(Math.max(-1,Math.min(32767.0/32768,x))*32768));channel=(channel+1)%channels;}output.flip();}
 @Override protected void onFlush(){engine.reset();}
}
