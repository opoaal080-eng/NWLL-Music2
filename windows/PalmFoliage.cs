using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Media.Imaging;

namespace Nightwell.Native;

public partial class MainWindow
{
    // Precompute dark foreground silhouettes once from the bundled sunset.
    // The sky does not move. Independent, gentle rotation affects only palm leaves.
    void SetupPalmFoliage()
    {
        try
        {
            var source = new BitmapImage(new Uri("pack://application:,,,/vice_sunset.jpg"));
            var bitmap = new FormatConvertedBitmap(source, PixelFormats.Bgra32, null, 0);
            int width = bitmap.PixelWidth, height = bitmap.PixelHeight;
            if (width < 2 || height < 2) return;
            int stride = checked(width * 4);
            byte[] pixels = new byte[checked(stride * height)];
            bitmap.CopyPixels(pixels, stride, 0);
            var points = new[] { new Point(0, .42), new Point(1, .20), new Point(1, .90) };
            var periods = new[] { 5.9, 6.7, 7.9 };
            var sway = new[] { 0.75, -0.85, 0.65 };
            for (int layer = 0; layer < 3; layer++)
            {
                byte[] foliage = new byte[pixels.Length];
                for (int y = 0; y < height; y++)
                {
                    double ny = (double)y / height;
                    for (int x = 0; x < width; x++)
                    {
                        double nx = (double)x / width;
                        int region = nx < .55 ? 0 : ny < .56 ? 1 : 2;
                        if (region != layer) continue;
                        int i = y * stride + x * 4;
                        int blue = pixels[i], green = pixels[i + 1], red = pixels[i + 2];
                        // Sky is colorful; palms are dark purple/near-black.
                        double a = Math.Min(1, Math.Max(0, (70 - red) / 25.0))
                                 * Math.Min(1, Math.Max(0, (48 - green) / 18.0))
                                 * Math.Min(1, Math.Max(0, (100 - blue) / 28.0));
                        byte alpha = (byte)Math.Round(225 * a);
                        foliage[i] = (byte)(blue * alpha / 255);
                        foliage[i + 1] = (byte)(green * alpha / 255);
                        foliage[i + 2] = (byte)(red * alpha / 255);
                        foliage[i + 3] = alpha;
                    }
                }
                var imageBitmap = new WriteableBitmap(width, height, 96, 96, PixelFormats.Pbgra32, null);
                imageBitmap.WritePixels(new Int32Rect(0, 0, width, height), foliage, stride, 0);
                imageBitmap.Freeze();
                var rotate = new RotateTransform();
                var foliageImage = new Image
                {
                    Source = imageBitmap,
                    Stretch = Stretch.Fill,
                    IsHitTestVisible = false,
                    RenderTransform = rotate,
                    RenderTransformOrigin = points[layer],
                    CacheMode = new BitmapCache()
                };
                VicePalmFoliage.Children.Add(foliageImage);
                var movement = new DoubleAnimation(-sway[layer], sway[layer],
                    TimeSpan.FromSeconds(periods[layer] / 2))
                {
                    AutoReverse = true,
                    RepeatBehavior = RepeatBehavior.Forever,
                    EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut }
                };
                rotate.BeginAnimation(RotateTransform.AngleProperty, movement);
            }
        }
        catch (Exception)
        {
            // A damaged optional effect must never prevent music playback.
            VicePalmFoliage.Children.Clear();
        }
    }
}
