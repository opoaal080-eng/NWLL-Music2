package fun.nightwell.music;

import android.content.Context;
import android.widget.SeekBar;

/**
 * Single iOS-style progress track. The native secondary progress displays
 * buffered audio inside the same bar, never as a second stripe above it.
 */
final class PreparingSeekBar extends SeekBar {
    private boolean preparing;
    private float prepared;

    PreparingSeekBar(Context context) {
        super(context);
    }

    void setPreparation(boolean active, double fraction) {
        preparing = active;
        prepared = Double.isFinite(fraction)
            ? (float) Math.max(0, Math.min(1, fraction)) : 0f;
        // Preparation state is still available for accessibility and
        // transport controls, but it does not draw a second progress bar.
        setContentDescription(preparing
            ? "Подготовка следующего трека, " + Math.round(prepared * 100) + "%"
            : "Прогресс воспроизведения");
    }
}
