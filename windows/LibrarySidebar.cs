using System.Windows;
using System.Windows.Controls;

namespace Nightwell.Native;

public partial class MainWindow {
 bool librarySidebarOpen=false;
 void ToggleLibrarySidebarClick(object sender,RoutedEventArgs e){
  librarySidebarOpen=!librarySidebarOpen;
  LibrarySideColumn.Width=new GridLength(librarySidebarOpen?344:0,GridUnitType.Pixel);
  LibrarySidebar.Visibility=librarySidebarOpen?Visibility.Visible:Visibility.Collapsed;
  SidebarToggle.Content=librarySidebarOpen?"Скрыть медиатеку":"Медиатека";
 }
 void SidebarFavoritesClick(object sender,RoutedEventArgs e)=>Show("Избранное");
 void SidebarPlaylistsClick(object sender,RoutedEventArgs e)=>Show("Плейлисты");
 void SidebarCreatePlaylistClick(object sender,RoutedEventArgs e){
  if(account.Length==0){Login();return;}
  Prompt("Новый плейлист","Название",async name=>{
   await api.Request("api/playlists","POST",new{name});
   await LoadAccount();
   Show("Плейлисты");
  });
 }
 async void SidebarPlaylistSelected(object sender,SelectionChangedEventArgs e){
  if(SidebarPlaylists.SelectedItem is not Playlist p||api==null)return;
  await Guard(async()=>{
   Show("Плейлисты");
   playlist=p.id;
   Heading.Text=p.name;
   SidebarPlaylists.Visibility=Visibility.Collapsed;
   Library.Visibility=Visibility.Visible;
   Status.Text="Загружаем плейлист…";
   var response=await api.Request("api/playlists/"+Uri.EscapeDataString(p.id)+"/tracks");
   if(screen!="Плейлисты"||playlist!=p.id)return;
   shown=ParseTracks(response);
   Tracks.ItemsSource=shown;
   Status.Text="";
  });
 }
}
