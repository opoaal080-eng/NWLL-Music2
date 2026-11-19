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
        // The source artwork is portrait. Stretching its fronds to a desktop
        // workspace made them HUGE. Keep each silhouette pinned to its original
        // screen edge, at a restrained fraction of the screen size.
        var anchors = new[] { new Point(0, .42), new Point(1, .20), new Point(1, .90) };
        var sizes = new[] { 0.58, 0.55, 0.61 };
        var degrees = new[] { 1.0, -1.15, 0.9 };
        var durations = new[] { 7.6, 8.2, 9.0 };
        VicePalmFoliage.Children.Clear();
        try
        {
            for (int index = 0; index < 3; index++)
            {
                var image = new BitmapImage(new Uri(
                    $"pack://application:,,,/vice_fronds_{index}.png", UriKind.Absolute));
                var rotation = new RotateTransform();
                var transforms = new TransformGroup();
                transforms.Children.Add(new ScaleTransform(sizes[index], sizes[index]));
                transforms.Children.Add(rotation);
                var fronds = new Image
                {
                    Source = image,
                    Stretch = Stretch.Fill,
                    Opacity = .82,
                    IsHitTestVisible = false,
                    RenderTransform = transforms,
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
