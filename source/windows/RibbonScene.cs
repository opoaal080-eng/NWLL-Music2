using System.Windows;
using System.Windows.Media;
using System.Diagnostics;
namespace Nightwell.Native;
public sealed class RibbonScene:FrameworkElement {
 readonly Stopwatch clock=Stopwatch.StartNew();double last;bool hooked;
 public bool Playing{get;set;}
 public RibbonScene(){IsVisibleChanged+=(_,_)=>Refresh();Loaded+=(_,_)=>Refresh();Unloaded+=(_,_)=>Detach();}
 void Refresh(){if(IsVisible&&!hooked){CompositionTarget.Rendering+=Frame;hooked=true;}else if(!IsVisible)Detach();}
 void Detach(){if(hooked)CompositionTarget.Rendering-=Frame;hooked=false;}
 void Frame(object? sender,EventArgs e){if(clock.Elapsed.TotalSeconds-last<1.0/30)return;last=clock.Elapsed.TotalSeconds;InvalidateVisual();}
 protected override void OnRender(DrawingContext dc){double t=clock.Elapsed.TotalSeconds*(Playing?.45:.14),radius=Math.Min(ActualWidth*.4,ActualHeight*.4);for(int strand=0;strand<18;strand++){double lane=strand/17.0-.5,r=radius*(1+lane*.22);var shape=new StreamGeometry();using(var c=shape.Open()){for(int i=0;i<=72;i++){double a=i/72.0*Math.PI*2;var p=new Point(ActualWidth/2+r*(Math.Cos(a)*.95+Math.Sin(a*2+t)*.24),ActualHeight/2+r*(Math.Sin(a)*.64+Math.Sin(a*2-t)*.28+lane*Math.Sin(a*2+t)*.3));if(i==0)c.BeginFigure(p,false,true);else c.LineTo(p,true,false);}}shape.Freeze();dc.DrawGeometry(null,new Pen(new SolidColorBrush(strand%6==0?Color.FromArgb(107,176,143,110):Color.FromArgb(83,148,125,173)),.9),shape);}}
}
