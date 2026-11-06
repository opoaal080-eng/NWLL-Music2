using System.Windows;
using System.Windows.Media;
using System.Diagnostics;
namespace Nightwell.Native;
// Subtle monochrome Ambient Flow, not the previous Halloween halo.
public sealed class RibbonScene:FrameworkElement {
 readonly Stopwatch clock=Stopwatch.StartNew(); double last; bool hooked;
 public bool Playing{get;set;}
 public RibbonScene(){IsVisibleChanged+=(_,_)=>Refresh();Loaded+=(_,_)=>Refresh();Unloaded+=(_,_)=>Detach();}
 void Refresh(){if(IsVisible&&!hooked){CompositionTarget.Rendering+=Frame;hooked=true;}else if(!IsVisible)Detach();}
 void Detach(){if(hooked)CompositionTarget.Rendering-=Frame;hooked=false;}
 void Frame(object? sender,EventArgs e){if(clock.Elapsed.TotalSeconds-last<(Playing?1.0/20:1.0/4))return;last=clock.Elapsed.TotalSeconds;InvalidateVisual();}
 protected override void OnRender(DrawingContext dc) {
  if(ActualWidth<2||ActualHeight<2)return;
  double w=ActualWidth,h=ActualHeight,t=clock.Elapsed.TotalSeconds*(Playing?.18:.035);
  for(int strand=0;strand<4;strand++){
   double baseY=.26+strand*.14,offset=strand*1.65;
   var geometry=new StreamGeometry();
   using(var ctx=geometry.Open()){
    for(int i=0;i<=72;i++){
     double u=i/72.0;
     double wave=Math.Sin(u*5.4+t+offset)*(.055+(Playing?.025:.009));
     double fold=Math.Sin(u*10.2-t*.7+strand)*.02;
     var point=new Point(w*(-.15+u*1.30),h*(baseY+wave+fold));
     if(i==0)ctx.BeginFigure(point,false,false);else ctx.LineTo(point,true,false);
    }
   }
   geometry.Freeze();
   byte alpha=(byte)(Playing?37:15);
   var brush=new SolidColorBrush(Color.FromArgb(alpha,(byte)(196+strand*9),(byte)(204+strand*8),230));brush.Freeze();
   var pen=new Pen(brush,Math.Min(w,h)*(.063+strand*.009)){StartLineCap=PenLineCap.Round,EndLineCap=PenLineCap.Round,LineJoin=PenLineJoin.Round};pen.Freeze();
   dc.DrawGeometry(null,pen,geometry);
  }
 }
}

