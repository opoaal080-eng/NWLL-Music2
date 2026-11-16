using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Data;

namespace Nightwell.Native;

// Desktop navigation follows the native iPhone hierarchy but uses a persistent
// library rail, an in-window queue and full-workspace account/settings panels.
public partial class MainWindow
{
    Grid? desktopShell;
    Grid? desktopWorkspace;
    Border? desktopSidebar;
    ColumnDefinition? sidebarColumn;
    readonly Dictionary<string, Button> sectionButtons = new();
    Border? queuePane, settingsPane, profilePane;
    ListBox? queueList, playlistDirectory;
    TextBlock? accountSummary, queueSummary;
    Button? signInButton, signOutButton, libraryBackButton;
    Slider? transitionControl, normalizationControl;
    TextBlock? transitionText, normalizationText;
    CheckBox? autoDownloadsControl, syncedLyricsControl;
    bool settingsReady;

    static readonly Brush RailBackground = new SolidColorBrush(Color.FromRgb(19, 19, 21));
    static readonly Brush PaneBackground = new SolidColorBrush(Color.FromRgb(18, 18, 20));
    static readonly Brush SelectedBackground = new SolidColorBrush(Color.FromRgb(56, 56, 59));
    static readonly Brush SecondaryText = new SolidColorBrush(Color.FromRgb(178, 178, 182));

    void SetupDesktopLayout()
    {
        var existing = Content as Grid;
        if (existing == null) return;
        Content = null;

        MinWidth = 970;
        MinHeight = 640;
        Width = 1220;
        Height = 810;

        desktopShell = new Grid { Background = (Brush)FindResource("WindowBrush") };
        sidebarColumn = new ColumnDefinition { Width = new GridLength(224) };
        desktopShell.ColumnDefinitions.Add(sidebarColumn);
        desktopShell.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        desktopSidebar = CreateSidebar();
        Grid.SetColumn(desktopSidebar, 0);
        desktopShell.Children.Add(desktopSidebar);
        existing.Margin = new Thickness(20, 18, 20, 18);
        desktopWorkspace = existing;
        Grid.SetColumn(existing, 1);
        desktopShell.Children.Add(existing);
        Content = desktopShell;

        // The home page has only the primary listening actions.
        HomeHeading.HorizontalAlignment = HorizontalAlignment.Center;
        HomeHeading.Margin = new Thickness(20, 54, 20, 0);
        if (HomeHeading.Children.Count >= 3)
        {
            if (HomeHeading.Children[0] is TextBlock eyebrow)
            {
                eyebrow.Text = "ТВОЯ МУЗЫКА";
                eyebrow.TextAlignment = TextAlignment.Center;
            }
            if (HomeHeading.Children[1] is TextBlock heading)
            {
                heading.FontSize = 49;
                heading.FontWeight = FontWeights.Bold;
                heading.TextAlignment = TextAlignment.Center;
            }
            if (HomeHeading.Children[2] is TextBlock subtitle)
            {
                subtitle.Text = "Музыка под твоё настроение";
                subtitle.TextAlignment = TextAlignment.Center;
            }
        }
        if (HomeControls.Children.Count > 2 && HomeControls.Children[2] is StackPanel)
            HomeControls.Children.RemoveAt(2);

        CreatePlaylistDirectory();
        CreateQueuePane();
        CreateSettingsPane();
        CreateProfilePane();
        UpdateSidebarSelection();
    }

    Border CreateSidebar()
    {
        var rail = new Border
        {
            Background = RailBackground,
            BorderBrush = (Brush)FindResource("LineBrush"),
            BorderThickness = new Thickness(0, 0, 1, 0),
            Padding = new Thickness(13, 22, 13, 16)
        };
        var dock = new DockPanel { LastChildFill = true };
        rail.Child = dock;

        var brand = new StackPanel { Margin = new Thickness(11, 0, 0, 24) };
        brand.Children.Add(new TextBlock { Text = "N", FontSize = 38, FontWeight = FontWeights.Black });
        brand.Children.Add(new TextBlock { Text = "NIGHTWELL MUSIC", FontSize = 10, FontWeight = FontWeights.SemiBold,
            Foreground = SecondaryText, Margin = new Thickness(1, -3, 0, 0) });
        DockPanel.SetDock(brand, System.Windows.Controls.Dock.Top);
        dock.Children.Add(brand);

        var footer = new StackPanel();
        footer.Children.Add(new Border { Height = 1, Background = (Brush)FindResource("LineBrush"),
            Margin = new Thickness(10, 7, 10, 11) });
        AddAction(footer, "⚙", "Настройки", OpenSettingsPane);
        AddAction(footer, "◉", "Профиль", OpenProfilePane);
        DockPanel.SetDock(footer, System.Windows.Controls.Dock.Bottom);
        dock.Children.Add(footer);

        var list = new StackPanel();
        AddSectionTitle(list, "МЕДИАТЕКА");
        AddSection(list, "⌂", "Главная");
        AddSection(list, "⌕", "Поиск");
        AddSection(list, "♡", "Избранное");
        AddSection(list, "♫", "Плейлисты");
        AddSection(list, "↓", "Офлайн");
        AddSeparator(list);
        AddSectionTitle(list, "ВОСПРОИЗВЕДЕНИЕ");
        AddAction(list, "♬", "Слушать вместе", TogetherWindow);
        AddAction(list, "◷", "Продолжить здесь", () => _ = Guard(ContinueHere));
        AddAction(list, "☷", "Настроить подборку", () => _ = Guard(TasteSettings));
        AddSeparator(list);
        AddSectionTitle(list, "ДОПОЛНИТЕЛЬНО");
        AddAction(list, "✧", "Подборки дня", () => _ = Guard(() => BrowsePlaylists(true)));
        AddAction(list, "⇩", "Перенести музыку", NativeTransfer);
        AddAction(list, "◇", "Nightwell Premium", OpenPremiumPane);
        AddAction(list, "✦", "Только фон", () => BackgroundClick(this, new RoutedEventArgs()));

        dock.Children.Add(new ScrollViewer
        {
            Content = list,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled
        });
        return rail;
    }

    void AddSectionTitle(StackPanel list, string text)
    {
        list.Children.Add(new TextBlock
        {
            Text = text, Foreground = SecondaryText, FontSize = 10, FontWeight = FontWeights.SemiBold,
            Margin = new Thickness(12, 5, 0, 10)
        });
    }

    void AddSeparator(StackPanel list)
    {
        list.Children.Add(new Border { Height = 1,
            Background = (Brush)FindResource("LineBrush"), Margin = new Thickness(8, 19, 8, 18) });
    }

    Button RailButton(string symbol, string label)
    {
        var contents = new StackPanel { Orientation = Orientation.Horizontal, Width = 184 };
        contents.Children.Add(new TextBlock
        {
            Text = symbol, FontSize = 19, Width = 32, VerticalAlignment = VerticalAlignment.Center
        });
        contents.Children.Add(new TextBlock
        {
            Text = label, FontSize = 14, VerticalAlignment = VerticalAlignment.Center,
            TextTrimming = TextTrimming.CharacterEllipsis
        });
        return new Button
        {
            Content = contents, Height = 44, MinHeight = 44, Padding = new Thickness(7, 5, 4, 5),
            BorderThickness = new Thickness(1), BorderBrush = Brushes.Transparent,
            Background = Brushes.Transparent, Margin = new Thickness(0, 2, 0, 2),
            Style = (Style)FindResource("QuietButton"), ToolTip = label
        };
    }

    void AddSection(StackPanel list, string symbol, string screenName)
    {
        var button = RailButton(symbol, screenName);
        button.Click += (_, _) => Show(screenName);
        sectionButtons[screenName] = button;
        list.Children.Add(button);
    }

    void AddAction(StackPanel list, string symbol, string title, Action action)
    {
        var button = RailButton(symbol, title);
        button.Click += (_, _) => action();
        list.Children.Add(button);
    }

    void UpdateSidebarSelection()
    {
        foreach (var pair in sectionButtons)
        {
            bool active = pair.Key == screen || (pair.Key == "Плейлисты" && playlist.Length > 0);
            pair.Value.Background = active ? SelectedBackground : Brushes.Transparent;
            pair.Value.Foreground = active ? Brushes.White : SecondaryText;
            pair.Value.BorderBrush = active ? (Brush)FindResource("LineBrush") : Brushes.Transparent;
        }
    }

    void ToggleDesktopSidebar()
    {
        if (desktopSidebar == null || sidebarColumn == null) return;
        var expanded = desktopSidebar.Visibility != Visibility.Visible;
        desktopSidebar.Visibility = expanded ? Visibility.Visible : Visibility.Collapsed;
        sidebarColumn.Width = new GridLength(expanded ? 224 : 0);
        NavigationMenu.ToolTip = expanded ? "Скрыть медиатеку" : "Показать медиатеку";
    }

    void CreatePlaylistDirectory()
    {
        if (Library.Children.OfType<Grid>().FirstOrDefault(g => Grid.GetRow(g) == 2) is not Grid tracksArea)
            return;
        playlistDirectory = new ListBox
        {
            Visibility = Visibility.Collapsed,
            Background = (Brush)FindResource("SurfaceBrush"),
            BorderThickness = new Thickness(0),
            DisplayMemberPath = "name",
            FontSize = 17,
            Padding = new Thickness(8),
            ToolTip = "Двойной щелчок открывает плейлист"
        };
        playlistDirectory.MouseDoubleClick += async (_, _) =>
        {
            if (playlistDirectory.SelectedItem is Playlist chosen) await OpenPlaylistAsync(chosen);
        };
        Panel.SetZIndex(playlistDirectory, 5);
        tracksArea.Children.Add(playlistDirectory);

        libraryBackButton = new Button
        {
            Content = "‹", FontSize = 25, Style = (Style)FindResource("IconButton"),
            Visibility = Visibility.Collapsed, ToolTip = "Назад к плейлистам", Margin = new Thickness(0, 0, 9, 0)
        };
        libraryBackButton.Click += (_, _) => Show("Плейлисты");
        if (Library.Children.OfType<Grid>().FirstOrDefault(g => Grid.GetRow(g) == 0) is Grid headingArea)
        {
            if (headingArea.ColumnDefinitions.Count == 2)
            {
                headingArea.ColumnDefinitions.Insert(0, new ColumnDefinition { Width = GridLength.Auto });
                foreach (UIElement child in headingArea.Children)
                    if (Grid.GetColumn(child) > 0 || child != libraryBackButton)
                        Grid.SetColumn(child, Grid.GetColumn(child) + 1);
            }
            Grid.SetColumn(libraryBackButton, 0);
            headingArea.Children.Add(libraryBackButton);
        }
    }

    async Task OpenPlaylistAsync(Playlist chosen)
    {
        CloseDesktopPanes();
        playlist = chosen.id;
        screen = chosen.name;
        Home.Visibility = Visibility.Collapsed;
        Library.Visibility = Visibility.Visible;
        PlayerPage.Visibility = Visibility.Collapsed;
        Dock.Visibility = Visibility.Visible;
        Ribbon.Visibility = Visibility.Collapsed;
        Heading.Text = chosen.name;
        LibraryEyebrow.Text = "ПЛЕЙЛИСТ";
        SearchOptions.Visibility = Visibility.Collapsed;
        CollectionActions.Visibility = Visibility.Visible;
        CollectionActions.ToolTip = "Действия с плейлистом";
        if (playlistDirectory != null) playlistDirectory.Visibility = Visibility.Collapsed;
        if (libraryBackButton != null) libraryBackButton.Visibility = Visibility.Visible;
        UpdateSidebarSelection();
        await Guard(async () =>
        {
            var result = await api.Request("api/playlists/" + chosen.id + "/tracks");
            if (playlist != chosen.id) return;
            shown = ParseTracks(result);
            Tracks.ItemsSource = shown;
        });
    }

    void AfterDesktopNavigation(string next)
    {
        CloseDesktopPanes();
        if (playlistDirectory != null)
        {
            playlistDirectory.Visibility = next == "Плейлисты" ? Visibility.Visible : Visibility.Collapsed;
            if (next == "Плейлисты") playlistDirectory.ItemsSource = playlists.ToList();
        }
        if (libraryBackButton != null)
            libraryBackButton.Visibility = playlist.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        if (next == "Плейлисты")
        {
            CollectionActions.Content = "＋";
            CollectionActions.ToolTip = "Создать плейлист";
        }
        else
        {
            CollectionActions.Content = "\uE712";
            CollectionActions.ToolTip = "Действия с коллекцией";
        }
        UpdateSidebarSelection();
    }

    void CreatePlaylistFromDirectory()
    {
        Prompt("Новый плейлист", "Название", async name =>
        {
            if (string.IsNullOrWhiteSpace(name)) return;
            await api.Request("api/playlists", "POST", new { name });
            await LoadAccount();
            Show("Плейлисты");
        });
    }

    void CreateQueuePane()
    {
        queueList = new ListBox { DisplayMemberPath = "title", FontSize = 14, Background = Brushes.Transparent };
        queueList.MouseDoubleClick += async (_, _) =>
        {
            if (queueList.SelectedItem is not Track selected) return;
            if (roomCode.Length > 0) await Guard(() => RoomCommand("track", selected.id));
            else
            {
                int target = queue.FindIndex(t => t.id == selected.id);
                if (target < 0) return;
                index = target;
                PlayCurrent();
            }
            ToggleDesktopQueue(false);
        };
        var panelContent = new StackPanel();
        panelContent.Children.Add(new TextBlock { Text = "Очередь воспроизведения", FontSize = 21,
            FontWeight = FontWeights.Bold, Margin = new Thickness(0, 0, 0, 10) });
        queueSummary = new TextBlock { Foreground = SecondaryText, Margin = new Thickness(0, 0, 0, 15) };
        panelContent.Children.Add(queueSummary);
        queuePane = new Border { Background = RailBackground, CornerRadius = new CornerRadius(22),
            BorderBrush = (Brush)FindResource("LineBrush"), BorderThickness = new Thickness(1),
            Padding = new Thickness(20), Width = 320, HorizontalAlignment = HorizontalAlignment.Right,
            Visibility = Visibility.Collapsed };
        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        panelContent.Children.Add(new Button { Content = "Готово", Style = (Style)FindResource("QuietButton"),
            HorizontalAlignment = HorizontalAlignment.Left, Command = null });
        if (panelContent.Children[panelContent.Children.Count - 1] is Button close) close.Click += (_, _) => ToggleDesktopQueue(false);
        grid.Children.Add(panelContent);
        Grid.SetRow(queueList, 1);
        grid.Children.Add(queueList);
        queuePane.Child = grid;
        AddDesktopOverlay(queuePane, 50);
    }

    void ToggleDesktopQueue(bool? show = null)
    {
        if (queuePane == null || queueList == null) return;
        bool visible = show ?? queuePane.Visibility != Visibility.Visible;
        if (visible) CloseDesktopPanes();
        queuePane.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
        if (!visible) return;
        queueList.ItemsSource = queue.ToList();
        if (queueSummary != null) queueSummary.Text = queue.Count + " треков";
    }

    Border MakeWorkspacePane(string title, out StackPanel contents)
    {
        var frame = new Border { Background = PaneBackground, BorderBrush = (Brush)FindResource("LineBrush"),
            BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(24),
            Padding = new Thickness(34, 22, 34, 20), Visibility = Visibility.Collapsed };
        var grid = new Grid();
        grid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        grid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        var top = new DockPanel { Margin = new Thickness(0, 0, 0, 22) };
        var done = new Button { Content = "Готово", Style = (Style)FindResource("PrimaryButton"), MinWidth = 100 };
        done.Click += (_, _) => CloseDesktopPanes();
        DockPanel.SetDock(done, System.Windows.Controls.Dock.Right);
        top.Children.Add(done);
        top.Children.Add(new TextBlock { Text = title, FontSize = 29, FontWeight = FontWeights.Bold,
            VerticalAlignment = VerticalAlignment.Center });
        grid.Children.Add(top);

        contents = new StackPanel { MaxWidth = 610, HorizontalAlignment = HorizontalAlignment.Left };
        var scroll = new ScrollViewer { Content = contents, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        Grid.SetRow(scroll, 1);
        grid.Children.Add(scroll);
        frame.Child = grid;
        AddDesktopOverlay(frame, 65);
        return frame;
    }

    void AddDesktopOverlay(Border element, int layer)
    {
        if (desktopWorkspace == null) return;
        Grid.SetRow(element, 0);
        Grid.SetRowSpan(element, 4);
        Panel.SetZIndex(element, layer);
        desktopWorkspace.Children.Add(element);
    }

    void CloseDesktopPanes()
    {
        if (settingsPane != null) settingsPane.Visibility = Visibility.Collapsed;
        if (profilePane != null) profilePane.Visibility = Visibility.Collapsed;
        if (queuePane != null) queuePane.Visibility = Visibility.Collapsed;
    }

    void ShowDesktopPane(Border? selected)
    {
        CloseDesktopPanes();
        if (selected != null) selected.Visibility = Visibility.Visible;
    }

    void CreateSettingsPane()
    {
        settingsPane = MakeWorkspacePane("Настройки", out var content);
        content.Children.Add(SectionLabel("ВОСПРОИЗВЕДЕНИЕ"));
        var playback = new StackPanel();
        transitionText = new TextBlock();
        transitionControl = new Slider { Minimum = 0, Maximum = 5, TickFrequency = .1,
            IsSnapToTickEnabled = true, Margin = new Thickness(0, 8, 0, 20) };
        transitionControl.ValueChanged += (_, _) =>
        {
            if (!settingsReady) return;
            transition = transitionControl.Value;
            if (transitionText != null) transitionText.Text = $"Переход между треками · {transition:0.0} с";
            SaveSettings();
        };
        normalizationText = new TextBlock();
        normalizationControl = new Slider { Minimum = 0, Maximum = 100, TickFrequency = 10,
            IsSnapToTickEnabled = true, Margin = new Thickness(0, 8, 0, 8) };
        normalizationControl.ValueChanged += (_, _) =>
        {
            if (!settingsReady) return;
            normalization = (int)normalizationControl.Value;
            if (normalizationText != null) normalizationText.Text = $"Одинаковая громкость · {normalization}%";
            SaveSettings();
        };
        playback.Children.Add(transitionText);
        playback.Children.Add(transitionControl);
        playback.Children.Add(normalizationText);
        playback.Children.Add(normalizationControl);
        playback.Children.Add(new TextBlock { Text = "Для применения выравнивания громкости перезапусти приложение.",
            TextWrapping = TextWrapping.Wrap, Foreground = SecondaryText, FontSize = 12 });
        content.Children.Add(SettingsCard(playback));
        content.Children.Add(SectionLabel("МЕДИАТЕКА"));
        var library = new StackPanel();
        autoDownloadsControl = new CheckBox { Content = "Автозагрузка избранного" };
        autoDownloadsControl.Click += (_, _) =>
        {
            if (!settingsReady) return;
            autoDownload = autoDownloadsControl.IsChecked == true;
            SaveMobileSettings();
        };
        syncedLyricsControl = new CheckBox { Content = "Текст в такт" };
        syncedLyricsControl.Click += (_, _) =>
        {
            if (!settingsReady) return;
            syncLyrics = syncedLyricsControl.IsChecked == true;
            renderedLyric = int.MinValue;
            SaveMobileSettings();
        };
        library.Children.Add(autoDownloadsControl);
        library.Children.Add(syncedLyricsControl);
        content.Children.Add(SettingsCard(library));
        content.Children.Add(SectionLabel("ТВОЙ РИТМ"));
        var taste = RailButton("☷", "Настроить подборку");
        taste.Click += (_, _) => _ = Guard(TasteSettings);
        content.Children.Add(taste);
    }

    TextBlock SectionLabel(string title) => new() { Text = title, FontSize = 11,
        Foreground = SecondaryText, FontWeight = FontWeights.SemiBold, Margin = new Thickness(2, 20, 0, 12) };

    void OpenSettingsPane()
    {
        settingsReady = false;
        if (transitionControl != null) transitionControl.Value = transition;
        if (normalizationControl != null) normalizationControl.Value = normalization;
        if (transitionText != null) transitionText.Text = $"Переход между треками · {transition:0.0} с";
        if (normalizationText != null) normalizationText.Text = $"Одинаковая громкость · {normalization}%";
        if (autoDownloadsControl != null) autoDownloadsControl.IsChecked = autoDownload;
        if (syncedLyricsControl != null) syncedLyricsControl.IsChecked = syncLyrics;
        settingsReady = true;
        ShowDesktopPane(settingsPane);
    }

    void CreateProfilePane()
    {
        profilePane = MakeWorkspacePane("Профиль", out var content);
        content.Children.Add(new Border { Width = 74, Height = 74, CornerRadius = new CornerRadius(20),
            HorizontalAlignment = HorizontalAlignment.Left, Background = SelectedBackground,
            Child = new TextBlock { Text = "N", FontSize = 38, FontWeight = FontWeights.Black,
                HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center } });
        content.Children.Add(new TextBlock { Text = "Nightwell Music", FontSize = 22,
            FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 18, 0, 7) });
        accountSummary = new TextBlock { Foreground = SecondaryText, Margin = new Thickness(0, 0, 0, 20) };
        content.Children.Add(accountSummary);
        content.Children.Add(SectionLabel("АККАУНТ"));
        signInButton = RailButton("◉", "Войти или зарегистрироваться");
        signInButton.Click += (_, _) => Login();
        content.Children.Add(signInButton);
        signOutButton = RailButton("↗", "Выйти из аккаунта");
        signOutButton.Click += async (_, _) =>
        {
            await Guard(async () =>
            {
                await api.Request("api/logout", "POST");
                api.Clear();
                await AudioCommand(() => player.Stop());
                roomCode = "";
                roomCancellation?.Cancel();
                queue = [];
                catalog = [];
                likes = [];
                playlists = [];
                account = "";
                Show("Главная");
            });
        };
        content.Children.Add(signOutButton);
        var continueButton = RailButton("◷", "Продолжить здесь");
        continueButton.Click += (_, _) => _ = Guard(ContinueHere);
        content.Children.Add(continueButton);
    }

    void OpenProfilePane()
    {
        if (accountSummary != null) accountSummary.Text = account.Length > 0 ? "Аккаунт подключён" : "Войди, чтобы синхронизировать музыку";
        if (signInButton != null) signInButton.Visibility = account.Length == 0 ? Visibility.Visible : Visibility.Collapsed;
        if (signOutButton != null) signOutButton.Visibility = account.Length > 0 ? Visibility.Visible : Visibility.Collapsed;
        ShowDesktopPane(profilePane);
    }

    void OpenPremiumPane()
    {
        var panel = new StackPanel();
        panel.Children.Add(Label("Nightwell Premium"));
        var state = new TextBlock { Text = "Проверяем подписку…",
            TextWrapping = TextWrapping.Wrap, Foreground = SecondaryText, Margin = new Thickness(0, 12, 0, 16) };
        panel.Children.Add(state);
        var premiumWindow = Sheet("Premium", panel, 330);
        _ = Guard(async () =>
        {
            if (account.Length == 0) { state.Text = "Войди в аккаунт, чтобы проверить подписку."; return; }
            var value = await api.Request("api/premium/me");
            bool active = value.TryGetProperty("premium", out var premium) && premium.GetBoolean();
            if (premiumWindow.IsVisible) state.Text = active ? "Подписка активна" : "Подписка не активна";
        });
    }
}
