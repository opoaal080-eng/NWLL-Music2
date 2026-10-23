package fun.nightwell.music;
import android.content.Context;
import android.graphics.*;
import android.view.View;

/** Audio reactive ribbons on one native canvas. */
final class RibbonView extends View {
 private final Paint paint=new Paint(Paint.ANTI_ALIAS_FLAG);
 private final Path path=new Path();
 private boolean running,playing;
 private long flashAt,lastFrame;
 private double phase,colorPhase,energy;
 double colorSpeed=1;
 private boolean auraVoice=true,auraLow=true,auraMid=true,auraHigh=true;
 void setAuraResponse(boolean voice,boolean low,boolean mid,boolean high){auraVoice=voice;auraLow=low;auraMid=mid;auraHigh=high;invalidate();}
 double premiumSpeed=1,premiumIntensity=1;String premiumTheme="nightwell";
 private java.util.function.DoubleSupplier meter=()->0;
 private java.util.function.IntToDoubleFunction bands=i->0;
 RibbonView(Context c){super(c);setLayerType(View.LAYER_TYPE_HARDWARE,null);}
 void meter(java.util.function.DoubleSupplier m){meter=m;}
 void bands(java.util.function.IntToDoubleFunction b){bands=b;}
 void running(boolean value){running=value;lastFrame=0;if(value)postInvalidateOnAnimation();}
 void playing(boolean value){playing=value;if(running)postInvalidateOnAnimation();}
 void flash(){flashAt=android.os.SystemClock.uptimeMillis();invalidate();}
 @Override protected void onAttachedToWindow(){super.onAttachedToWindow();if(running)postInvalidateOnAnimation();}
 private static final int[][] PALETTE={{135,87,255},{239,98,193},{255,153,92},{91,189,255}};
 private static final int[][] AUTUMN_PALETTE={{255,120,62},{195,87,255},{77,182,255},{255,88,183}};
 private int auraColor(double phase){
  int[][] palette=premiumTheme.equals("nightwell")?AUTUMN_PALETTE:PALETTE;
  double wrapped=(phase%4+4)%4;int index=(int)wrapped;
  double f=wrapped-index,blend=f*f*(3-2*f);
  int[] a=palette[index],b=palette[(index+1)%4];
  return Color.rgb((int)(a[0]+(b[0]-a[0])*blend),(int)(a[1]+(b[1]-a[1])*blend),(int)(a[2]+(b[2]-a[2])*blend));
 }
 @Override protected void onDraw(Canvas canvas){
  super.onDraw(canvas);
  final float w=getWidth(),h=getHeight();if(w<1||h<1)return;
  double raw=0;try{raw=meter.getAsDouble();}catch(RuntimeException ignored){}
  if(!Double.isFinite(raw))raw=0;
  raw=playing?Math.max(0,Math.min(1,raw*premiumIntensity)):0;
  // Use independently measured PCM envelopes; combine any enabled ranges.
  double selected=0;int enabled=0;
  boolean[] choices={auraVoice,auraLow,auraMid,auraHigh};
  for(int i=0;i<4;i++)if(choices[i]){
   double value=0;try{value=bands.applyAsDouble(i);}catch(RuntimeException ignored){}
   if(Double.isFinite(value)){selected+=Math.max(0,Math.min(1,value));enabled++;}
  }
  raw=playing&&enabled>0?Math.min(1,selected/enabled*premiumIntensity):0;
  energy+=(raw-energy)*(raw>energy?.55:.2);
  long now=android.os.SystemClock.uptimeMillis();
  double delta=lastFrame==0?1.0/30:Math.min(.1,(now-lastFrame)/1000.0);lastFrame=now;
  phase+=delta*.8*premiumSpeed;
  colorPhase+=delta*.9*colorSpeed;
  float density=getResources().getDisplayMetrics().density;
  float burst=Math.max(0,1-(now-flashAt)/700f);
  paint.setStyle(Paint.Style.STROKE);paint.setStrokeCap(Paint.Cap.ROUND);
  final double cx=w*.5,cy=h*.54;
  for(int side=0;side<3;side++){
   double dx=side==0?-w*.72:side==1?w*.72:0,dy=side==2?-h*.78:-h*.36;
   double length=Math.hypot(dx,dy);
   double hue=colorPhase+side*.8+(premiumTheme.equals("aurora")?1:premiumTheme.equals("ocean")?2:premiumTheme.equals("sunset")?3:0);
   paint.setShader(new LinearGradient((float)cx,(float)cy,(float)(cx+dx),(float)(cy+dy),
    new int[]{Color.TRANSPARENT,Color.TRANSPARENT,auraColor(hue),auraColor(hue+.6),auraColor(hue+1.2)},new float[]{0,.08f,.3f,.68f,1},Shader.TileMode.CLAMP));
   for(int band=17;band>=0;band--){
    double lane=(band-8.5)/17.0;
    path.reset();
    for(int i=6;i<=64;i++){
     double u=i/64.0;
     double spread=Math.sin(u*Math.PI*.5);
     double bend=(Math.sin(u*9-phase+lane*3)*(.045+energy*.045)+lane*.26)*Math.min(w,h)*spread;
     double x=cx+dx*u-dy/length*bend,y=cy+dy*u+dx/length*bend;
     if(i==6)path.moveTo((float)x,(float)y);else path.lineTo((float)x,(float)y);
    }
    int alpha=(int)(255*Math.min(.82,(.24+energy*.30+burst*.16)*(1-Math.abs(lane)*.9)));
    paint.setAlpha(alpha);paint.setStrokeWidth((float)((9+band*.8+energy*19)*density));
    canvas.drawPath(path,paint);
   }
  }
  paint.setShader(null);
  if(running&&isShown()&&getWindowVisibility()==VISIBLE)postInvalidateDelayed(playing?33:67);
 }
}
