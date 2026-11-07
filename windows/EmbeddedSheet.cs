using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace Nightwell.Native;

// Keeps existing Sheet callers and the Windows design-preview workflow compatible.
// In the running app, Show and Close operate an in-window surface, not a new window.
public sealed class EmbeddedSheet : Window {
 readonly MainWindow host;
 readonly bool standalone;
 public EmbeddedSheet(MainWindow owner){
  host=owner;
  standalone=Environment.GetCommandLineArgs().Any(a=>a is "--design-preview" or "--native-smoke");
 }
 public new bool IsVisible=>standalone?base.IsVisible:host.IsEmbeddedSheetVisible(this);
 public new void Show(){
  if(standalone)base.Show();
  else host.PresentEmbeddedSheet(this);
 }
 public new void Close(){
  if(standalone)base.Close();
  else host.HideEmbeddedSheet(this);
 }
}

public partial class MainWindow {
 readonly List<EmbeddedSheet> sheetStack=new();
 EmbeddedSheet? visibleSheet;
 internal bool IsEmbeddedSheetVisible(EmbeddedSheet sheet)=>sheetStack.Contains(sheet);
 internal void PresentEmbeddedSheet(EmbeddedSheet sheet){
  sheetStack.Remove(sheet);
  sheetStack.Add(sheet);
  RenderEmbeddedSheet();
 }
 internal void HideEmbeddedSheet(EmbeddedSheet sheet){
  sheetStack.Remove(sheet);
  RenderEmbeddedSheet();
 }
 void RenderEmbeddedSheet(){
  if(visibleSheet!=null&&EmbeddedSheetBody.Content is UIElement current){
   EmbeddedSheetBody.Content=null;
   visibleSheet.Content=current;
  }
  visibleSheet=sheetStack.Count>0?sheetStack[^1]:null;
  if(visibleSheet==null){
   EmbeddedSheetLayer.Visibility=Visibility.Collapsed;
   return;
  }
  var sheet=visibleSheet;
  var body=sheet.Content as UIElement;
  sheet.Content=null;
  EmbeddedSheetBody.Content=body;
  EmbeddedSheetTitle.Text=sheet.Title.Replace("Nightwell · ","");
  EmbeddedSheetFrame.Width=Math.Max(290,Math.Min(sheet.Width,ActualWidth-30));
  EmbeddedSheetFrame.Height=Math.Max(240,Math.Min(sheet.Height,ActualHeight-30));
  EmbeddedSheetLayer.Visibility=Visibility.Visible;
 }
 void EmbeddedSheetCloseClick(object sender,RoutedEventArgs e){
  if(visibleSheet!=null)HideEmbeddedSheet(visibleSheet);
 }
 void EmbeddedSheetOutsideClick(object sender,MouseButtonEventArgs e){
  if(visibleSheet!=null)HideEmbeddedSheet(visibleSheet);
 }
}
