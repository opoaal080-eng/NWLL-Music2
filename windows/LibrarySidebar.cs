using System.Windows;
using System.Windows.Controls;

namespace Nightwell.Native;

public partial class MainWindow {
 bool librarySidebarOpen=false;
 void SidebarBackClick(object sender,RoutedEventArgs e)=>Show("Главная");
 void SettingsClick(object sender,RoutedEventArgs e)=>Settings();
 void PremiumClick(object sender,RoutedEventArgs e)=>PremiumWindow();
 void BottomLibraryClick(object sender,RoutedEventArgs e)=>Show("Избранное");
 async void LibraryAdditionalClick(object sender,RoutedEventArgs e){
  var menu=new ContextMenu{PlacementTarget=(UIElement)sender,
   Placement=System.Windows.Controls.Primitives.PlacementMode.Bottom};
  var connectionStatus=new MenuItem{Header="●  Проверка API. Подключаемся",IsEnabled=false,
   Padding=new Thickness(12,9,12,9)};
  menu.Items.Add(connectionStatus);
  menu.Items.Add(new Separator());
  foreach(var label in new[]{"Слушать вместе","Подборки дня","Плейлисты в поиске","Перенос плейлистов"}){
   var item=new MenuItem{Header=label,Padding=new Thickness(12,9,12,9)};
   item.Click+=async(_,_)=>{
    if(label=="Слушать вместе")TogetherWindow();
    else if(label=="Подборки дня")await Guard(()=>BrowsePlaylists(true));
    else if(label=="Плейлисты в поиске")await Guard(()=>BrowsePlaylists(false));
    else NativeTransfer();
   };
   menu.Items.Add(item);
  }
  menu.IsOpen=true;
  try{
   await api.Request("api/me");
   connectionStatus.Header="●  API доступен. Подключено";
  }catch{
   connectionStatus.Header="●  API недоступен. Нет подключения";
  }
 }
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
   ownedPlaylistCache[p.id]=shown.ToList();
   SaveOwnedPlaylistCache(p.id,shown);
   Tracks.ItemsSource=shown;
   Status.Text="";
  });
 }
}
