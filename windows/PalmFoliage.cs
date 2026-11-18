using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;

namespace Nightwell.Native;

public partial class MainWindow
{
    // Each frond PNG has a transparent background. The permanent sky contains
    // no stationary palms, so moving these images actually moves the foliage.
    void SetupPalmFoliage()
    {
        var anchors = new[] { new Point(0, .42), new Point(1, .20), new Point(1, .90) };
        var degrees = new[] { 3.0, -3.4, 2.8 };
        var durations = new[] { 6.4, 7.2, 8.3 };
        VicePalmFoliage.Children.Clear();
        try
        {
            for (int index = 0; index < 3; index++)
            {
                var image = new BitmapImage(new Uri(
                    $"pack://application:,,,/vice_fronds_{index}.png", UriKind.Absolute));
                var rotation = new RotateTransform();
                var fronds = new Image
                {
                    Source = image,
                    Stretch = Stretch.Fill,
                    IsHitTestVisible = false,
                    RenderTransform = rotation,
                    RenderTransformOrigin = anchors[index],
                    CacheMode = new BitmapCache()
                };
                VicePalmFoliage.Children.Add(fronds);
                var movement = new DoubleAnimation(-degrees[index], degrees[index],
                    TimeSpan.FromSeconds(durations[index] / 2))
                {
                    AutoReverse = true,
                    RepeatBehavior = RepeatBehavior.Forever,
                    EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut }
                };
                rotation.BeginAnimation(RotateTransform.AngleProperty, movement);
            }
        }
        catch
        {
            // An optional visual must not stop playback or startup.
            VicePalmFoliage.Children.Clear();
        }
    }
}
