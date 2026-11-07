using System.Diagnostics;
using System.Windows;
using System.Windows.Media;

namespace Nightwell.Native;

// A single softly blended ambient wash. No strip geometries or sharp color bands.
// Drawn behind both the Home page and the large player; artwork colors fade smoothly.
public sealed class RibbonScene : FrameworkElement {
 readonly Stopwatch clock=Stopwatch.StartNew();
 readonly RadialGradientBrush[] glows=new RadialGradientBrush[3];
 bool hooked;
 double last,phase=.8,energy;
 Window? owner;
 Color first=Color.FromRgb(112,112,112),second=Color.FromRgb(91,91,91);
 Color targetFirst=Color.FromRgb(112,112,112),targetSecond=Color.FromRgb(91,91,91);
 public bool Playing{get;set;}
 public bool Focused{get;set;}
 public double Intensity{get;set;}=1;
 public double? PreviewPhase{get;set;}
 public long RenderedFrames{get;private set;}

 public RibbonScene(){
  IsHitTestVisible=false;
  for(int i=0;i<glows.Length;i++){
   glows[i]=new RadialGradientBrush{
    RadiusX=1,RadiusY=1,
    GradientOrigin=new Point(.5,.5),
    Center=new Point(.5,.5)
   };
   glows[i].GradientStops.Add(new GradientStop(first,0));
   glows[i].GradientStops.Add(new GradientStop(Color.FromArgb(0,first.R,first.G,first.B),1));
  }
  Loaded+=(_,_)=>{owner=Window.GetWindow(this);if(owner!=null)owner.StateChanged+=OwnerStateChanged;Refresh();};
  IsVisibleChanged+=(_,_)=>Refresh();
  Unloaded+=(_,_)=>{Detach();if(owner!=null)owner.StateChanged-=OwnerStateChanged;owner=null;};
 }
 public void SetPalette(Color a,Color b){targetFirst=Muted(a);targetSecond=Muted(b);}
 static Color Muted(Color color)=>Color.FromRgb(
  (byte)Math.Clamp((int)color.R,28,166),
  (byte)Math.Clamp((int)color.G,28,166),
  (byte)Math.Clamp((int)color.B,28,166));
 public void ResetPalette()=>SetPalette(Color.FromRgb(112,112,112),Color.FromRgb(91,91,91));
 void OwnerStateChanged(object? sender,EventArgs args)=>Refresh();
 void Refresh(){
  if(IsVisible&&IsLoaded&&owner?.WindowState!=WindowState.Minimized){
   if(!hooked){last=clock.Elapsed.TotalSeconds;CompositionTarget.Rendering+=Frame;hooked=true;}
  }else Detach();
 }
 void Detach(){if(hooked)CompositionTarget.Rendering-=Frame;hooked=false;}
 void Frame(object? sender,EventArgs args){
  double now=clock.Elapsed.TotalSeconds;
  int fps=(RenderCapability.Tier>>16)==0?(Playing?15:4):(Playing?24:8);
  if(now-last<1.0/fps)return;
  double dt=Math.Clamp(now-last,0,.12);last=now;
  energy+=((Playing?.50:.14)-energy)*Math.Min(1,dt*1.5);
  phase+=dt*(Playing?.11:.025);
  first=Blend(first,targetFirst,dt*1.3);
  second=Blend(second,targetSecond,dt*1.3);
  InvalidateVisual();
 }
 static Color Blend(Color a,Color b,double amount){
  amount=Math.Clamp(amount,0,1);
  return Color.FromRgb(
   (byte)(a.R+(b.R-a.R)*amount),
   (byte)(a.G+(b.G-a.G)*amount),
   (byte)(a.B+(b.B-a.B)*amount));
 }
 static Color Alpha(Color color,int alpha)=>Color.FromArgb(
  (byte)Math.Clamp(alpha,0,255),color.R,color.G,color.B);
 protected override void OnRender(DrawingContext dc){
  base.OnRender(dc);
  double width=ActualWidth,height=ActualHeight;
  if(width<2||height<2)return;
  RenderedFrames++;
  double t=PreviewPhase??phase;
  double level=PreviewPhase.HasValue?(Playing?.65:.15):energy;
  dc.PushClip(new RectangleGeometry(new Rect(0,0,width,height)));

  // Continuous base gradient covers the full surface, including all corners.
  var background=new LinearGradientBrush{
   StartPoint=new Point(0,0),EndPoint=new Point(.95,1),
   GradientStops={
    new GradientStop(Color.FromRgb(13,13,15),0),
    new GradientStop(Color.FromRgb(18,18,21),.52),
    new GradientStop(Color.FromRgb(12,12,14),1)
   }
  };
  dc.DrawRectangle(background,null,new Rect(0,0,width,height));

  // Wide translucent falloffs gently mix artwork hues; no thin ribbons.
  var positions=new[]{
   new Point(.30+.045*Math.Sin(t*.58),.24+.045*Math.Cos(t*.45)),
   new Point(.78+.055*Math.Sin(t*.34),.52+.05*Math.Cos(t*.41)),
   new Point(.45+.04*Math.Sin(t*.52),.94)
  };
  for(int i=0;i<glows.Length;i++){
   var color=i==1?second:Blend(first,second,i==2?.55:.12);
   var brush=glows[i];
   brush.GradientStops[0].Color=Alpha(color,100);
   brush.GradientStops[1].Color=Alpha(color,0);
   dc.PushOpacity((i==2?.16:.25)+level*.085);
   dc.DrawEllipse(brush,null,new Point(width*positions[i].X,height*positions[i].Y),
    width*(i==1?.88:1.04),height*(i==2?.98:1.12));
   dc.Pop();
  }
  dc.Pop();
 }
}
