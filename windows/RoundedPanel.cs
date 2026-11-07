using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
namespace Nightwell.Native;
public sealed class RoundedPanel:Border {
 protected override void OnRenderSizeChanged(SizeChangedInfo info){
  base.OnRenderSizeChanged(info);
  var geometry=new RectangleGeometry(new Rect(0,0,Math.Max(0,ActualWidth),Math.Max(0,ActualHeight)),CornerRadius.TopLeft,CornerRadius.TopLeft);geometry.Freeze();Clip=geometry;
 }
}
