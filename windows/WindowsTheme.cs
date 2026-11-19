using System;
using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace Nightwell.Native;

public partial class MainWindow
{
    // Keep theme selection local to this Windows device, separate from server
    // account settings and the debounced playback settings file.
    string visualTheme = "vice";
    readonly List<ComboBox> visualThemeSelectors = new();
    string ThemeSettingsPath => Path.Combine(NativeAPI.Storage, "windows-appearance.json");

    void InitializeVisualTheme()
    {
        string preferred = "vice";
        try
        {
            using var json = JsonDocument.Parse(File.ReadAllText(ThemeSettingsPath));
            if (json.RootElement.TryGetProperty("theme", out var value))
                preferred = value.GetString() == "standard" ? "standard" : "vice";
        }
        catch { /* First run uses the existing Vice Nights look. */ }
        ApplyVisualTheme(preferred, false);
    }

    ComboBox CreateVisualThemeSelector()
    {
        var picker = new ComboBox { MinWidth = 218, HorizontalAlignment = HorizontalAlignment.Stretch,
                                    ToolTip = "Переключить оформление всех разделов Nightwell Music" };
        picker.Items.Add("Стандартная · чёрно-белая");
        picker.Items.Add("Vice Nights · закат");
        picker.SelectedIndex = visualTheme == "standard" ? 0 : 1;
        picker.SelectionChanged += (_, _) =>
        {
            if (picker.SelectedIndex < 0) return;
            ApplyVisualTheme(picker.SelectedIndex == 0 ? "standard" : "vice");
        };
        visualThemeSelectors.Add(picker);
        return picker;
    }

    void SetThemeToken(string key, string hex)
    {
        var color = (Color)ColorConverter.ConvertFromString(hex);
        // Prefer changing the shared brush, which updates already-created panels,
        // styles and popups without rebuilding their content or losing state.
        if (Application.Current.Resources[key] is SolidColorBrush brush && !brush.IsFrozen)
            brush.Color = color;
        else
            Application.Current.Resources[key] = new SolidColorBrush(color);
    }

    void ApplyVisualTheme(string requested, bool save = true)
    {
        bool vice = requested != "standard";
        visualTheme = vice ? "vice" : "standard";
        var palette = new Dictionary<string, (string basic, string vice)>
        {
            ["WindowBrush"] = ("#101011", "#15101C"),
            ["SurfaceBrush"] = ("#171719", "#201828"),
            ["RaisedBrush"] = ("#242426", "#32263E"),
            ["InputBrush"] = ("#202023", "#2C2236"),
            ["HoverBrush"] = ("#333337", "#493651"),
            ["LineBrush"] = ("#48484C", "#654E70"),
            ["TextBrush"] = ("#F6F6F7", "#FFF8FC"),
            ["SecondaryBrush"] = ("#BEBEC3", "#DAC8DE"),
            ["MutedBrush"] = ("#96969B", "#B4A0BD"),
            ["AccentBrush"] = ("#E1E1E5", "#FFBDD2"),
            ["AccentSurfaceBrush"] = ("#37373A", "#533C60"),
            ["SelectionBrush"] = ("#38383C", "#62436B"),
            ["RailBrush"] = ("#171719", "#231A2B"),
            ["PaneBrush"] = ("#1B1B1E", "#2A2132"),
            ["SidebarSelectionBrush"] = ("#3A3A3E", "#654571"),
            ["SideSecondaryBrush"] = ("#BEBEC3", "#CAB6D0"),
            ["DockBrush"] = ("#EB1C1C1F", "#E72D2137"),
            ["PrimaryButtonBrush"] = ("#EB353539", "#E94A3159"),
            ["PrimaryHoverBrush"] = ("#EE4C4C51", "#ED644375"),
            ["PrimaryPressedBrush"] = ("#F066666B", "#F0785582"),
            ["QuietHoverBrush"] = ("#403C3C40", "#4F71516F"),
            ["QuietPressedBrush"] = ("#65545459", "#6D815B7D"),
            ["PlayerButtonBrush"] = ("#DF28282C", "#D53A2D42"),
            ["PlayerHoverBrush"] = ("#F13F3F44", "#EC63445D"),
            ["PlayerPressedBrush"] = ("#EF56565D", "#EF75556B"),
            ["PlayerOutlineBrush"] = ("#B9C5C5C9", "#D5F4C7DE"),
            ["PlayerHoverOutlineBrush"] = ("#F3E5E5E8", "#FFFFE1F2"),
            ["PlayerActionBrush"] = ("#D627272A", "#C9433046"),
            ["PlayerActionHoverBrush"] = ("#EF444449", "#E95D425B"),
            ["PlayerActionPressedBrush"] = ("#EA5A5A60", "#ED75516D"),
            ["PlayerActionOutlineBrush"] = ("#9BB4B4BA", "#BDECC1D8"),
            ["PlayerActiveBrush"] = ("#E24A4A4F", "#E76A4063"),
            ["SliderActiveBrush"] = ("#DEDEE2", "#FBC6DB"),
            ["SliderInactiveBrush"] = ("#5B5B60", "#725A77"),
            ["SliderThumbBrush"] = ("#F4F4F6", "#FFE7F3")
        };
        foreach (var item in palette)
            SetThemeToken(item.Key, vice ? item.Value.vice : item.Value.basic);

        // Vice Nights owns the home/library background; artwork-based ambient
        // still owns the full-screen player in BOTH themes.
        ViceSunsetBackdrop.Visibility = vice ? Visibility.Visible : Visibility.Collapsed;
        ViceScrim.Visibility = vice ? Visibility.Visible : Visibility.Collapsed;
        VicePalmFoliage.Visibility = vice && PlayerPage.Visibility != Visibility.Visible
            ? Visibility.Visible : Visibility.Collapsed;
        if (desktopShell != null) desktopShell.Background = (Brush)FindResource("WindowBrush");
        if (desktopSidebar != null) desktopSidebar.Background = (Brush)FindResource("RailBrush");
        if (queuePane != null) queuePane.Background = (Brush)FindResource("RailBrush");
        if (settingsPane != null) settingsPane.Background = (Brush)FindResource("PaneBrush");
        if (profilePane != null) profilePane.Background = (Brush)FindResource("PaneBrush");
        if (familyPane != null) familyPane.Background = (Brush)FindResource("PaneBrush");
        Dock.Background = (Brush)FindResource("DockBrush");
        MiniProgress.Background = (Brush)FindResource("AccentBrush");

        // Ensure toggles refresh with the new palette even when their state
        // has not changed since the previous theme.
        ShuffleButton.Tag = null;
        RepeatButton.Tag = null;
        SetMode(ShuffleButton, shuffle);
        SetMode(RepeatButton, repeat > 0);
        UpdateSidebarSelection();
        foreach (var picker in visualThemeSelectors.ToArray())
        {
            if (!picker.IsLoaded && picker.Parent == null) { visualThemeSelectors.Remove(picker); continue; }
            int index = vice ? 1 : 0;
            if (picker.SelectedIndex != index) picker.SelectedIndex = index;
        }
        if (!save) return;
        try
        {
            Directory.CreateDirectory(NativeAPI.Storage);
            string file = ThemeSettingsPath;
            string temp = file + ".tmp";
            File.WriteAllText(temp, JsonSerializer.Serialize(new { theme = visualTheme }));
            File.Move(temp, file, true);
        }
        catch { /* Appearance still changes without filesystem access. */ }
    }
}
