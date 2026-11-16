using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;

namespace Nightwell.Native;

/// <summary>Single consistent stroke-based icon family; independent of OS icon fonts.</summary>
internal static class NightwellIcons
{
    static readonly Brush DefaultStroke = new SolidColorBrush(Color.FromRgb(231, 232, 235));
    internal static Path Draw(string kind, double size = 20, Brush? stroke = null, bool filled = false)
    {
        string data = kind switch
        {
            "home" => "M3,10 L12,3 L21,10 V21 H14 V15 H10 V21 H3 Z",
            "search" => "M11,3 A8,8 0 1 0 11,19 A8,8 0 1 0 11,3 M17,17 L22,22",
            "heart" => "M12,21 L4,13 C-3,5 7,-1 12,6 C17,-1 27,5 20,13 Z",
            "playlist" => "M3,5 H17 M3,10 H17 M3,15 H11 M17,14 V5 L22,4 V15 M17,17 C13,15 11,19 14,21 C17,23 20,20 20,18",
            "download" => "M12,3 V16 M6,10 L12,16 L18,10 M4,20 H20",
            "together" => "M8,12 A4,4 0 1 0 8,4 A4,4 0 1 0 8,12 M16,12 A3,3 0 1 0 16,6 A3,3 0 1 0 16,12 M2,21 V18 C2,13 14,13 14,18 V21 M15,15 C20,14 22,16 22,20",
            "continue" => "M4,12 H20 M14,6 L20,12 L14,18 M4,5 V19",
            "sliders" => "M4,6 H20 M4,12 H20 M4,18 H20 M9,4 V8 M15,10 V14 M11,16 V20",
            "sparkle" => "M12,2 L14.7,9.3 L22,12 L14.7,14.7 L12,22 L9.3,14.7 L2,12 L9.3,9.3 Z",
            "upload" => "M12,17 V3 M6,9 L12,3 L18,9 M4,16 V21 H20 V16",
            "premium" => "M2,8 L7,3 L12,8 L17,3 L22,8 L20,20 H4 Z M2,8 L8,13 L12,8 L16,13 L22,8",
            "settings" => "M12,2 V5 M12,19 V22 M2,12 H5 M19,12 H22 M5,5 L7,7 M17,17 L19,19 M19,5 L17,7 M7,17 L5,19 M12,8 A4,4 0 1 0 12,16 A4,4 0 1 0 12,8",
            "user" => "M12,3 A4,4 0 1 0 12,11 A4,4 0 1 0 12,3 M4,21 V18 C4,13 20,13 20,18 V21",
            "devices" => "M2,5 H17 V16 H2 Z M6,20 H13 M9.5,16 V20 M19,9 H23 V21 H17 V9 Z",
            "family" => "M7,10 A3,3 0 1 0 7,4 A3,3 0 1 0 7,10 M17,10 A3,3 0 1 0 17,4 A3,3 0 1 0 17,10 M2,20 V17 C2,13 12,13 12,17 V20 M12,20 V17 C12,13 22,13 22,17 V20",
            "logout" => "M9,3 H4 V21 H9 M13,8 L18,12 L13,16 M7,12 H18",
            "play" => "M8,4 L20,12 L8,20 Z",
            "pause" => "M7,4 V20 M17,4 V20",
            "previous" => "M5,5 V19 M19,5 L7,12 L19,19 Z",
            "next" => "M19,5 V19 M5,5 L17,12 L5,19 Z",
            "shuffle" => "M3,6 H6 C13,6 10,18 18,18 H21 M17,14 L21,18 L17,22 M3,18 H6 C9,18 10,14 12,12 M17,2 L21,6 L17,10 M13,6 H21",
            "repeat" => "M17,3 L21,7 L17,11 M3,11 V7 C3,5 4,4 7,4 H21 M7,21 L3,17 L7,13 M21,13 V17 C21,19 20,20 17,20 H3",
            "volume" => "M3,9 H7 L12,5 V19 L7,15 H3 Z M16,9 C18,11 18,13 16,15 M19,6 C23,9 23,15 19,18",
            "back" => "M15,4 L7,12 L15,20",
            "down" => "M5,9 L12,16 L19,9",
            "more" => "M12,4 A1,1 0 1 0 12,6 A1,1 0 1 0 12,4 M12,11 A1,1 0 1 0 12,13 A1,1 0 1 0 12,11 M12,18 A1,1 0 1 0 12,20 A1,1 0 1 0 12,18",
            "close" => "M5,5 L19,19 M19,5 L5,19",
            "music" => "M9,18 V5 L20,3 V16 M9,9 L20,7 M9,18 C6,16 2,18 3,21 C4,24 9,23 9,20 M20,16 C17,14 13,16 14,19 C15,22 20,21 20,18",
            _ => "M5,12 H19"
        };
        var path = new Path
        {
            Data = Geometry.Parse(data),
            Stroke = stroke ?? DefaultStroke,
            StrokeThickness = kind is "play" or "pause" ? 2.6 : 1.75,
            StrokeStartLineCap = PenLineCap.Round,
            StrokeEndLineCap = PenLineCap.Round,
            StrokeLineJoin = PenLineJoin.Round,
            Stretch = Stretch.Uniform,
            Width = size,
            Height = size,
            Fill = filled ? (stroke ?? DefaultStroke) : Brushes.Transparent,
            SnapsToDevicePixels = true
        };
        return path;
    }

    internal static string Symbol(string symbol) => symbol switch
    {
        "⌂" => "home", "⌕" => "search", "♡" => "heart", "♫" => "playlist",
        "↓" => "download", "♬" => "together", "◷" => "continue", "☷" => "sliders",
        "✧" => "sparkle", "⇩" => "upload", "◇" => "premium",
        "⚙" => "settings", "◉" => "user", "↗" => "logout", "‹" => "back",
        _ => "music"
    };
}

public partial class MainWindow
{
    void SetPlayVector(Button button, bool playing)
    {
        string state = playing ? "pause" : "play";
        if (button.Content is Path && Equals(button.Tag, state)) return;
        button.Content = NightwellIcons.Draw(state, button == HomePlay ? 31 : button == MiniPlay ? 20 : 26,
            Brushes.White, state == "play");
        button.Tag = state;
    }

    void SetHeartVector(bool active)
    {
        var color = active ? Brushes.White : (Brush)FindResource("TextBrush");
        FullLike.Content = NightwellIcons.Draw("heart", 22, color, active);
        MiniLike.Content = NightwellIcons.Draw("heart", 22, color, active);
    }

    void ApplyPlayerVectorIcons()
    {
        SetPlayVector(HomePlay, false);
        SetPlayVector(FullPlay, false);
        SetPlayVector(MiniPlay, false);
        SetHeartVector(false);
        ShuffleButton.Content = NightwellIcons.Draw("shuffle", 21);
        RepeatButton.Content = NightwellIcons.Draw("repeat", 21);
        NavigationMenu.Content = NightwellIcons.Draw("playlist", 21);
        CollectionActions.Content = NightwellIcons.Draw("more", 20);
    }
}
