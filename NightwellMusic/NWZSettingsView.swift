import SwiftUI
import UIKit

struct NWZSettingsView: View, Equatable {
    // Parent playback updates do not invalidate this independent page.
    static func == (lhs: Self, rhs: Self) -> Bool { true }
    @Environment(\.nightwellAppearance) private var appearance
    @AppStorage(NWZ.enabledKey) private var enabled = true
    @AppStorage(NWZ.modeKey) private var mode = NWZ.Mode.balanced.rawValue
    @State private var stats = OfflineStore.cachedCompressionStats() ?? OfflineStore.CompressionStats()
    @State private var busy = false
    @State private var done = 0
    @State private var total = 0
    @State private var status = ""
    @State private var job: Task<Void, Never>?
    @State private var loaded = OfflineStore.cachedCompressionStats() != nil
    @State private var refreshJob: Task<Void, Never>?
    @State private var refreshing = false
    @State private var stopping = false

    private func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
    private var percent: Double {
        stats.original > 0 ? 100 * Double(stats.saved) / Double(stats.original) : 0
    }
    private func refresh() {
        guard !refreshing, !busy else { return }
        refreshing = true
        refreshJob = Task.detached(priority: .background) {
            // Let the page transition finish before disk enumeration starts.
            do { try await Task.sleep(nanoseconds: 250_000_000) }
            catch { return }
            let result = OfflineStore.compressionStats(cancelled: { Task.isCancelled })
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                stats = result; loaded = true; refreshing = false; refreshJob = nil
            }
        }
    }
    private func stop() {
        stopping = true
        job?.cancel()
    }
    private func start() {
        guard !busy, enabled, NWZ.permitted else {
            status = "Сжатие недоступно в режиме энергосбережения или при перегреве."
            return
        }
        refreshJob?.cancel(); refreshJob = nil; refreshing = false
        busy = true; stopping = false; done = 0; total = 0; status = "Проверяем загрузки…"
        let baseline = stats
        let selected = NWZ.Mode(rawValue: mode) ?? .balanced
        job = Task.detached(priority: .background) {
            let candidates = OfflineStore.compressionCandidates(cancelled: { Task.isCancelled })
            await MainActor.run { total = candidates.count }
            var converted = 0, unchanged = 0, skipped = 0, failed = 0
            var saved: Int64 = 0
            var lastPublish = ProcessInfo.processInfo.systemUptime
            for raw in candidates {
                if Task.isCancelled || !NWZ.enabled || !NWZ.permitted { break }
                let id = raw.deletingPathExtension().lastPathComponent
                let protected = await MainActor.run { NativePlayer.shared.protectedOfflineIDs.contains(id) }
                if protected { skipped += 1 }
                else {
                    do {
                        if let result = try OfflineStore.prepareCompression(raw, mode: selected,
                            cancelled: { Task.isCancelled || !NWZ.enabled }) {
                            defer { OfflineStore.discardCompression(result) }
                            let gain = try await MainActor.run {
                                guard !Task.isCancelled, NWZ.enabled,
                                      !NativePlayer.shared.protectedOfflineIDs.contains(id) else { return Int64(0) }
                                return try OfflineStore.installCompression(result)
                            }
                            if gain > 0 { converted += 1; saved += gain }
                            else { skipped += 1 }
                        } else if Task.isCancelled || !NWZ.enabled || !NWZ.permitted { break }
                        else { unchanged += 1 }
                    } catch { failed += 1 }
                }
                // O(1) progress from successful installs, not O(N) full
                // rescans after each track. Limit SwiftUI layout updates to 3/s.
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastPublish >= 0.35 {
                    let processed = converted + unchanged + skipped + failed
                    var interim = baseline
                    interim.stored = max(0, baseline.stored - saved)
                    interim.packed += converted
                    interim.plain = max(0, baseline.plain - converted)
                    let snapshot = interim
                    await MainActor.run {
                        var transaction = Transaction(); transaction.disablesAnimations = true
                        withTransaction(transaction) { done = processed; stats = snapshot }
                    }
                    lastPublish = now
                }
                if !Task.isCancelled { try? await Task.sleep(nanoseconds: 20_000_000) }
            }
            let paused = Task.isCancelled || !NWZ.enabled || !NWZ.permitted
            // One exact reconciliation at completion, even after cancellation.
            let report = OfflineStore.compressionStats()
            await MainActor.run {
                stats = report; loaded = true; done = converted + unchanged + skipped + failed
                busy = false; stopping = false; job = nil
                status = (paused ? "Остановлено. " : "Готово. ") +
                    "Сжато: \(converted), без экономии: \(unchanged), пропущено: \(skipped), ошибок: \(failed). Освобождено \(bytes(saved))."
            }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Nightwell Compression", systemImage: "archivebox")
                .font(.system(size: 18, weight: .semibold))
            Toggle("Сжимать новые загрузки", isOn: $enabled)
                .onChange(of: enabled) { value in if !value && busy { stop() } }
            Text("Без перекодирования AAC. Исходные байты восстанавливаются полностью. Уже сжатые треки остаются доступными и после отключения.")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
            Text("Степень сжатия").font(.system(size: 14, weight: .medium))
            Picker("Степень сжатия", selection: $mode) {
                ForEach(NWZ.Mode.allCases) { option in Text(option.title).tag(option.rawValue) }
            }
            .pickerStyle(.segmented)
            .disabled(!enabled || busy)
            Text(mode == NWZ.Mode.maximum.rawValue
                 ? "Все блоки проверяются тремя алгоритмами. Больше времени и расхода батареи при загрузке."
                 : mode == NWZ.Mode.fast.rawValue
                 ? "Минимальная нагрузка, один быстрый алгоритм."
                 : "Быстрые алгоритмы и выборочное усиленное сжатие.")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
            Divider().overlay(.white.opacity(0.12))
            Text("Память устройства").font(.system(size: 16, weight: .semibold))
            if loaded {
                Text(bytes(stats.saved))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(appearance.accent)
                Text("Сэкономлено \(String(format: "%.2f", percent))% от исходного размера аудио")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(appearance.accent.opacity(0.32))
                        Capsule().fill(.white.opacity(0.65))
                            .frame(width: proxy.size.width * CGFloat(stats.original > 0 ? min(1, Double(stats.stored) / Double(stats.original)) : 0))
                    }
                }.frame(height: 8)
                statRow("До сжатия", bytes(stats.original))
                statRow("На диске (аудио)", bytes(stats.stored))
                statRow("Сжатых NWZ", String(stats.packed))
                statRow("Обычных M4A", String(stats.plain))
                if stats.damaged > 0 { statRow("Неполных записей", String(stats.damaged)) }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Подсчитываем…").font(.system(size: 30, weight: .bold, design: .rounded))
                    ForEach(["До сжатия", "На диске (аудио)", "Сжатых NWZ", "Обычных M4A"], id: \.self) { label in
                        statRow(label, "—")
                    }
                }
                .redacted(reason: .placeholder)
                .accessibilityLabel("Загрузка статистики")
            }
            Text("Размеры файлов без обложек, кеша и системных накладных расходов. AAC уже сжат, поэтому экономия может быть небольшой или нулевой.")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            Divider().overlay(.white.opacity(0.12))
            if busy {
                ProgressView(value: Double(done), total: Double(max(1, total)))
                Text("Обработано \(done) из \(total)").font(.system(size: 13)).monospacedDigit()
                Button(stopping ? "Останавливаем…" : "Остановить", action: stop)
                    .disabled(stopping)
                    .buttonStyle(.plain).foregroundStyle(appearance.accent)
            } else {
                Button(action: start) {
                    Label("Сжать старые загрузки", systemImage: "arrow.down.circle")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .disabled(!enabled || !loaded || stats.plain == 0)
                .opacity(!enabled || !loaded || stats.plain == 0 ? 0.45 : 1)
            }
            if !status.isEmpty { Text(status).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7)) }
            Text("Текущий и подготовленный следующий трек пропускаются. Сжатие останавливается при выходе из раздела, перегреве или энергосбережении.")
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
            Button(refreshing ? "Обновляем…" : "Обновить статистику", action: refresh)
                .disabled(refreshing || busy)
                .font(.system(size: 13, weight: .medium)).buttonStyle(.plain)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 24))
        .onAppear { refresh() }
        .onDisappear {
            refreshJob?.cancel(); refreshJob = nil; refreshing = false
            job?.cancel()
        }
    }
    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.white.opacity(0.62))
            Spacer()
            Text(value).monospacedDigit()
        }.font(.system(size: 13))
    }
}
