package fun.nightwell.music;

/** Frame-rate-independent audio envelopes shared by the four Ambient Flow streams. */
final class AmbientFlowState {
    final double[] levels = new double[4];
    private final double[] adaptive = {.07, .07, .07, .07};
    double time;
    void reset() { java.util.Arrays.fill(levels, 0); java.util.Arrays.fill(adaptive, .07); }
    void update(double[] incoming, boolean[] enabled, double intensity, double speed, double elapsed) {
        double dt = Double.isFinite(elapsed) ? Math.max(0, Math.min(.1, elapsed)) : 0;
        double gain = Double.isFinite(intensity) ? Math.max(0, Math.min(3, intensity)) : 1;
        double rate = Double.isFinite(speed) ? Math.max(.2, Math.min(3, speed)) : 1;
        double energy = 0;
        for (int i = 0; i < 4; i++) {
            boolean active = i < enabled.length && enabled[i];
            double sample = active && i < incoming.length && Double.isFinite(incoming[i])
                    ? Math.max(0, Math.min(1, incoming[i])) : 0;
            adaptive[i] += (sample - adaptive[i]) * (1 - Math.exp(-dt / 2));
            double target = active ? Math.min(1, sample / Math.max(.025, adaptive[i] * 1.5) * gain) : 0;
            levels[i] += (target - levels[i]) * (1 - Math.exp(-dt / (target > levels[i] ? .09 : .55)));
            if (!active || gain == 0) levels[i] = 0;
            energy += levels[i] / 4;
        }
        time += dt * rate * (.16 + energy * .48);
    }
}
