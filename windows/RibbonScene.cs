using System.Diagnostics;
using System.Windows;
using System.Windows.Media;
namespace Nightwell.Native;
// A bounded vector scene. No blur effects, audio capture, or extra media decoder.
public sealed class RibbonScene:FrameworkElement {
 readonly Stopwatch clock=Stopwatch.StartNew();
 readonly RadialGradientBrush[] glows=new RadialGradientBrush[3];
 readonly LinearGradientBrush[] silk=new LinearGradientBrush[3];
 readonly SolidColorBrush edgeBrush=new(Color.FromArgb(52,155,155,155));
 readonly LinearGradientBrush shade=new(Color.FromArgb(130,12,12,12),Color.FromArgb(10,12,12,12),0);
 double last,phase=.8,energy,speed=.07;bool hooked;Window? owner;
 Color first=Color.FromRgb(123,123,123),second=Color.FromRgb(106,106,106),targetFirst=Color.FromRgb(123,123,123),targetSecond=Color.FromRgb(106,106,106);
 public bool Playing{get;set;}public bool Focused{get;set;}public double Intensity{get;set;}=1;
 public double? PreviewPhase{get;set;}
 public long RenderedFrames{get;private set;}
 public RibbonScene(){
  IsHitTestVisible=false;
  for(int i=0;i<3;i++){
   glows[i]=new RadialGradientBrush();glows[i].GradientStops.Add(new GradientStop(first,0));glows[i].GradientStops.Add(new GradientStop(Color.FromArgb(0,first.R,first.G,first.B),1));
   silk[i]=new LinearGradientBrush{StartPoint=new Point(0,0),EndPoint=new Point(.3,1)};
   foreach(var offset in new[]{0.0,.24,.52,.75,1.0})silk[i].GradientStops.Add(new GradientStop(Colors.Transparent,offset));
  }
  Loaded+=(_,_)=>{owner=Window.GetWindow(this);if(owner!=null)owner.StateChanged+=OwnerStateChanged;Refresh();};
  IsVisibleChanged+=(_,_)=>Refresh();Unloaded+=(_,_)=>{Detach();if(owner!=null)owner.StateChanged-=OwnerStateChanged;owner=null;};
 }
 public void SetPalette(Color a,Color b){targetFirst=Muted(a);targetSecond=Muted(b);}
 static Color Muted(Color value)=>Color.FromRgb((byte)Math.Clamp((int)value.R,25,184),(byte)Math.Clamp((int)value.G,25,184),(byte)Math.Clamp((int)value.B,25,184));
 public void ResetPalette()=>SetPalette(Color.FromRgb(123,123,123),Color.FromRgb(106,106,106));
 void OwnerStateChanged(object? sender,EventArgs args)=>Refresh();
 void Refresh(){if(IsVisible&&IsLoaded&&owner?.WindowState!=WindowState.Minimized){if(!hooked){last=clock.Elapsed.TotalSeconds;CompositionTarget.Rendering+=Frame;hooked=true;}}else Detach();}
 void Detach(){if(hooked)CompositionTarget.Rendering-=Frame;hooked=false;}
 void Frame(object? sender,EventArgs args){
  double now=clock.Elapsed.TotalSeconds;int fps=(RenderCapability.Tier>>16)==0?(Playing?15:4):(Playing?24:8);
  if(now-last<1.0/fps)return;double dt=Math.Clamp(now-last,0,.12);last=now;
  energy+=( (Playing?.38+.38*Math.Clamp(Intensity,0,1):.10)-energy)*Math.Min(1,dt*2.0);
  speed+=((Playing?.19:.045)-speed)*Math.Min(1,dt*1.5);phase+=dt*speed;
  first=Blend(first,targetFirst,dt*1.6);second=Blend(second,targetSecond,dt*1.6);InvalidateVisual();
 }
 static Color Blend(Color a,Color b,double amount){amount=Math.Clamp(amount,0,1);return Color.FromRgb((byte)(a.R+(b.R-a.R)*amount),(byte)(a.G+(b.G-a.G)*amount),(byte)(a.B+(b.B-a.B)*amount));}
 static Color Alpha(Color color,int alpha)=>Color.FromArgb((byte)Math.Clamp(alpha,0,255),color.R,color.G,color.B);
 protected override void OnRender(DrawingContext dc){
  base.OnRender(dc);double w=ActualWidth,h=ActualHeight;if(w<2||h<2)return;RenderedFrames++;
  double t=PreviewPhase??phase,level=PreviewPhase.HasValue?(Playing?.76:.12):energy;
  dc.PushClip(new RectangleGeometry(new Rect(0,0,w,h)));
  dc.PushOpacity(Focused?.30:1);
  for(int i=0;i<3;i++){
   Color color=i==1?second:first;var glow=glows[i];glow.GradientStops[0].Color=Alpha(color,135);glow.GradientStops[1].Color=Alpha(color,0);
   double x=i==0?.72+.10*Math.Sin(t*.7):i==1?.34+.10*Math.Cos(t*.55):.94;
   double y=i==0?.31+.12*Math.Cos(t*.47):i==1?.80+.08*Math.Sin(t*.6):.83;
   dc.PushOpacity(i==0?.34+level*.20:i==1?.22+level*.12:.13);
   dc.DrawEllipse(glow,null,new Point(w*x,h*y),w*(i==2?.40:.65),h*(i==1?.65:.90));dc.Pop();
  }
  for(int layer=0;layer<3;layer++){
   const int steps=36;var band=new StreamGeometry();var edge=new StreamGeometry();
   double offset=layer*1.17;
   double Center(double u)=>h*(.50+layer*.07+.12*Math.Sin(u*4.8+t+offset)+.045*Math.Sin(u*9.1-t*.65+offset));
   double Thickness(double u)=>h*(.030+layer*.007+(.045+level*.025)*Math.Pow(Math.Sin(u*Math.PI),2));
   using(var path=band.Open()){
    for(int i=0;i<=steps;i++){double u=i/(double)steps;var point=new Point(w*(-.16+u*1.32),Center(u)-Thickness(u));if(i==0)path.BeginFigure(point,true,true);else path.LineTo(point,true,false);}
    for(int i=steps;i>=0;i--){double u=i/(double)steps;path.LineTo(new Point(w*(-.16+u*1.32),Center(u)+Thickness(u)),true,false);}
   }
   using(var path=edge.Open())for(int i=0;i<=steps;i++){double u=i/(double)steps;var point=new Point(w*(-.16+u*1.32),Center(u)-Thickness(u)*.94);if(i==0)path.BeginFigure(point,false,false);else path.LineTo(point,true,false);}
   band.Freeze();edge.Freeze();Color tint=layer==1?second:first;
   var brush=silk[layer];int[] opacity={0,7,Playing?48:29,17,0};for(int i=0;i<opacity.Length;i++)brush.GradientStops[i].Color=Alpha(tint,opacity[i]);
   dc.DrawGeometry(brush,null,band);edgeBrush.Color=Alpha(Blend(tint,Color.FromRgb(190,190,190),.35),Playing?46:23);dc.DrawGeometry(null,new Pen(edgeBrush,.8),edge);
  }
  dc.Pop();dc.DrawRectangle(shade,null,new Rect(0,0,w,h));dc.Pop();
 }
}
