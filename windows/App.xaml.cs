using System.Windows;
using System.Windows.Interop;
using System.Runtime.InteropServices;
namespace Nightwell.Native;
public partial class App:Application {
 protected override void OnStartup(StartupEventArgs e){
  EventManager.RegisterClassHandler(typeof(Window),FrameworkElement.LoadedEvent,new RoutedEventHandler((sender,_)=>{
   if(sender is not Window window)return;
   try{
    var handle=new WindowInteropHelper(window).Handle;if(handle==IntPtr.Zero)return;
    int enabled=1,caption=0x000F0F0F,text=0x00ECECEC;
    if(DwmSetWindowAttribute(handle,20,ref enabled,4)!=0)DwmSetWindowAttribute(handle,19,ref enabled,4);
    DwmSetWindowAttribute(handle,35,ref caption,4);DwmSetWindowAttribute(handle,36,ref text,4);
   }catch(DllNotFoundException){}catch(EntryPointNotFoundException){}
  }));
  base.OnStartup(e);
 }
 [DllImport("dwmapi.dll")]static extern int DwmSetWindowAttribute(IntPtr handle,int attribute,ref int value,int size);
}
