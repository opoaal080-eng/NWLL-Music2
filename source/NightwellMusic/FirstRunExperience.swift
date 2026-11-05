import SwiftUI

// Shown only on the first launch on this device, independent of account login.
struct NightwellFirstLaunch: View {
    let completed: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page = 0
    @State private var artists = Set<String>()
    @State private var mood = "any"

    private let ink = Color(red: 0.035, green: 0.035, blue: 0.045)
    private let lemon = Color(red: 0.93, green: 1, blue: 0.18)
    private let suggestions = ["Кино", "Баста", "Дмитриенко", "Мияги", "Кадышева", "MACAN",
                               "Клава Кока", "Дора", "The Weeknd", "Billie Eilish", "Imagine Dragons", "Måneskin"]
    private let moods = [("any","Любое"),("energetic","Энергично"),("calm","Спокойно"),("happy","Весело")]

    private var headline: String {
        switch page {
        case 0: return "Твоя волна. Твоя музыка."
        case 1: return "Подборки под любой момент"
        case 2: return "Слушай даже без интернета"
        default: return "Настроим твой вкус"
        }
    }
    private var description: String {
        switch page {
        case 0: return "Nightwell постепенно узнаёт, что тебе нравится, и предлагает новые треки."
        case 1: return "Для учёбы, прогулок, поездок и настроения. Всё в одном месте."
        case 2: return "Сохраняй любимые треки и плейлисты, чтобы они были рядом без сети."
        default: return "Выбери несколько исполнителей. Это поможет улучшить первые рекомендации."
        }
    }
    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                HStack {
                    HStack(spacing: 8) {
                        Image(systemName: "waveform").font(.system(size: 21, weight: .bold))
                        Text("NIGHTWELL").font(.system(size: 15, weight: .heavy, design: .rounded)).tracking(3)
                    }
                    .foregroundStyle(.white)
                    Spacer()
                    if page < 3 {
                        Button("Пропустить") { finish() }
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
                .padding(.top, 12)
                .padding(.bottom, 16)

                Group {
                    if page == 3 { preferences }
                    else { illustration }
                }
                .frame(height: max(210, min(geo.size.height * 0.46, 430)))
                .frame(maxWidth: .infinity)
                Spacer(minLength: 8)
                Text(headline)
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .tracking(-1.2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                Text(description)
                    .font(.system(size: 16))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.62))
                    .lineSpacing(4)
                    .padding(.top, 13)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 14)
                HStack(spacing: 8) {
                    ForEach(0..<4, id: \.self) { index in
                        Capsule()
                            .fill(index == page ? lemon : .white.opacity(0.23))
                            .frame(width: index == page ? 29 : 7, height: 7)
                    }
                    Spacer()
                    Button {
                        if page < 3 { withAnimation(reduceMotion ? nil : .spring(response: 0.42, dampingFraction: 0.86)) { page += 1 } }
                        else { finish() }
                    } label: {
                        HStack(spacing: 10) {
                            Text(page == 3 ? "Начать слушать" : "Далее")
                            Image(systemName: page == 3 ? "checkmark" : "arrow.right")
                        }
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(ink)
                        .padding(.horizontal, 21)
                        .frame(height: 54)
                        .background(lemon, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 16)
            }
            .padding(.horizontal, 25)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(ink.ignoresSafeArea())
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: page)
        }
    }
    private var illustration: some View {
        ZStack {
            let shades: [Color] = page == 0
                ? [Color(red: 0.83, green: 0.08, blue: 0.54), Color(red: 0.17, green: 0.08, blue: 0.44)]
                : page == 1
                ? [Color(red: 0.3, green: 0.17, blue: 0.85), Color(red: 0.02, green: 0.27, blue: 0.35)]
                : [Color(red: 0.10, green: 0.45, blue: 0.94), Color(red: 0.02, green: 0.11, blue: 0.37)]
            RoundedRectangle(cornerRadius: 48)
                .fill(LinearGradient(colors: shades, startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(RoundedRectangle(cornerRadius: 48).stroke(.white.opacity(0.24), lineWidth: 1))
                .shadow(color: shades[0].opacity(0.28), radius: 45, y: 18)
            Circle().fill(.white.opacity(0.09)).frame(width: 280, height: 280).blur(radius: 22).offset(x: 86, y: -110)
            if page == 0 {
                ZStack {
                    Circle().stroke(.white.opacity(0.17), lineWidth: 2).frame(width: 250, height: 250)
                    Circle().stroke(.white.opacity(0.14), lineWidth: 2).frame(width: 195, height: 195)
                    Image(systemName: "waveform.path")
                        .font(.system(size: 95, weight: .medium))
                        .foregroundStyle(lemon)
                        .shadow(color: lemon.opacity(0.42), radius: 35)
                }
                VStack {
                    Spacer()
                    HStack(spacing: 9) {
                        sampleChip("Твой ритм", icon: "sparkles")
                        sampleChip("Открытия", icon: "music.note")
                    }
                    .padding(.bottom, 28)
                }
            } else if page == 1 {
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        playlistTile("НОЧНОЙ ГОРОД", tint: .purple, icon: "moon.stars.fill")
                        playlistTile("В ДВИЖЕНИИ", tint: .orange, icon: "bolt.fill")
                    }
                    HStack(spacing: 12) {
                        playlistTile("ДЛЯ СЕБЯ", tint: .pink, icon: "heart.fill")
                        playlistTile("НА РАССВЕТЕ", tint: .cyan, icon: "sunrise.fill")
                    }
                }
                .padding(23)
                .rotationEffect(.degrees(-6))
            } else {
                VStack(spacing: 18) {
                    RoundedRectangle(cornerRadius: 25)
                        .fill(.white.opacity(0.19))
                        .frame(width: 188, height: 188)
                        .overlay {
                            Image(systemName: "airplane")
                                .font(.system(size: 78, weight: .light))
                                .foregroundStyle(lemon)
                        }
                    Text("Вне сети. В твоём ритме.")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 50))
                        .foregroundStyle(lemon)
                }
            }
        }
        .padding(.vertical, 6)
    }
    private func sampleChip(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 15).padding(.vertical, 11)
            .background(.black.opacity(0.25), in: Capsule())
    }
    private func playlistTile(_ title: String, tint: Color, icon: String) -> some View {
        RoundedRectangle(cornerRadius: 24)
            .fill(LinearGradient(colors: [tint.opacity(0.92), tint.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: icon).font(.system(size: 35, weight: .thin))
                    Spacer()
                    Text(title).font(.system(size: 13, weight: .heavy)).lineLimit(2)
                }
                .foregroundStyle(.white)
                .padding(15)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.18)))
    }
    private var preferences: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text("Любимые исполнители").font(.system(size: 18, weight: .bold))
                Spacer()
                Text("\(artists.count) выбрано").font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(suggestions, id: \.self) { artist in
                    Button {
                        if artists.contains(artist) { artists.remove(artist) }
                        else { artists.insert(artist) }
                    } label: {
                        HStack(spacing: 6) {
                            Text(artist).lineLimit(1).minimumScaleFactor(0.78)
                            Spacer(minLength: 2)
                            if artists.contains(artist) { Image(systemName: "checkmark.circle.fill") }
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(artists.contains(artist) ? ink : .white)
                        .padding(.horizontal, 10).frame(height: 36)
                        .background(artists.contains(artist) ? lemon : .white.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain)
                }
            }
            Text("Настроение").font(.system(size: 16, weight: .bold)).padding(.top, 6)
            HStack(spacing: 6) {
                ForEach(moods, id: \.0) { item in
                    Button(item.1) { mood = item.0 }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(mood == item.0 ? ink : .white)
                        .padding(.horizontal, 9).padding(.vertical, 10)
                        .background(mood == item.0 ? lemon : .white.opacity(0.09), in: Capsule())
                }
            }
            Spacer(minLength: 0)
        }
        .padding(19)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 34))
    }
    private func finish() {
        RecommendationOrder.seedTaste(artists: Array(artists), mood: mood)
        completed()
    }
}
