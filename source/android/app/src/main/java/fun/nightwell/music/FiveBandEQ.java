package fun.nightwell.music;

/** Five two-octave peaking filters. Unity preamp, with a peak limiter per channel. */
final class FiveBandEQ {
 private double[] applied;
 private double[][] co=new double[5][5],z1,z2;
 private double[] limiter;
 private int rate,channels;
 private double release;
 private boolean neutral=true;
 void configure(double[] values,int sampleRate,int count){
  if(values==null||values.length!=5||sampleRate<=0||count<=0)throw new IllegalArgumentException();
  for(double value:values)if(!Double.isFinite(value)||Math.abs(value)>6)throw new IllegalArgumentException();
  if(rate==sampleRate&&channels==count&&java.util.Arrays.equals(values,applied))return;
  boolean format=rate!=sampleRate||channels!=count;
  neutral=true;for(double value:values)neutral&=value==0;
  rate=sampleRate;channels=count;applied=values.clone();
  if(format||neutral||z1==null){z1=new double[count][5];z2=new double[count][5];limiter=new double[count];java.util.Arrays.fill(limiter,1);}
  release=1-Math.exp(-1/(.024*rate));
  double[] frequencies={60,250,1000,4000,12000};
  for(int i=0;i<5;i++){
   double a=Math.pow(10,values[i]/40),w=2*Math.PI*Math.min(frequencies[i],rate*.45)/rate;
   double sine=Math.sin(w),alpha=sine*Math.sinh(Math.log(2)*w/sine),c=Math.cos(w),d=1+alpha/a;
   co[i]=new double[]{(1+alpha*a)/d,-2*c/d,(1-alpha*a)/d,-2*c/d,(1-alpha/a)/d};
  }
 }
 double sample(double input,int channel){
  if(channel<0||channel>=channels)throw new IllegalArgumentException();
  double x=Double.isFinite(input)?input:0;
  if(neutral)return Math.max(-1,Math.min(1,x));
  for(int i=0;i<5;i++){double[] c=co[i];double y=c[0]*x+z1[channel][i];z1[channel][i]=c[1]*x-c[3]*y+z2[channel][i];z2[channel][i]=c[2]*x-c[4]*y;x=y;}
  if(!Double.isFinite(x))return 0;
  double target=Math.abs(x)>.98?.98/Math.abs(x):1;
  limiter[channel]=Math.min(target,limiter[channel]+(1-limiter[channel])*release);
  return Math.max(-1,Math.min(1,x*limiter[channel]));
 }
 void reset(){applied=null;z1=z2=null;}
}
