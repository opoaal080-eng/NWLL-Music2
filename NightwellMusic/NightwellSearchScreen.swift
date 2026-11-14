import SwiftUI
import UIKit

/// One scroll container owns the search controls, suggestions, artists and lazy track rows.
struct NightwellSearchScreen: View {
    @EnvironmentObject private var store: MusicStore
    @Environment(\.nightwellBottomContentInset) private var bottomContentInset
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @Binding var collapsed: Bool
    let revealRequest: Int
    let openArtist: (String) -> Void
    @State private var searchCaretX: CGFloat = 16
    @State private var searchFieldOriginX: CGFloat = 50
    @State private var searchFocused = false
    @State private var focusRequest = 0

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Поиск").font(.largeTitle.bold()).id("nightwell-search-top")
                    HStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 20))
                            .foregroundStyle(.white.opacity(0.86))

                        NightwellSearchCaretField(
                            text: $store.query,
                            caretX: $searchCaretX,
                            focused: $searchFocused,
                            focusRequest: focusRequest
                        )
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                        .background {
                            // Measure the text field's actual origin in the pill.
                            // A hard-coded offset drifts across devices and fonts.
                            GeometryReader { field in
                                Color.clear.preference(
                                    key: NightwellSearchFieldOriginPreference.self,
                                    value: field.frame(in: .named("nightwellSearchPill")).minX
                                )
                            }
                        }
                        .onChange(of: store.query) { _ in store.scheduleSearch() }

                        if !store.query.isEmpty {
                            Button { store.query = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 23))
                                    .foregroundStyle(.white.opacity(0.78))
                            }
                        }
                    }
                    // Keep the pill exactly the same size while typing,
                    // showing the keyboard, or animating either highlight.
                    .frame(height: 54)
                    .padding(.horizontal, 18)
                    .coordinateSpace(name: "nightwellSearchPill")
                    .background {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .opacity(0.48)
                            .overlay {
                                NightwellSearchCaretLight(
                                    x: searchFieldOriginX + searchCaretX,
                                    active: searchFocused && !collapsed
                                )
                                .animation(.easeOut(duration: 0.10), value: searchCaretX)
                                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                            }
                    }
                    .onPreferenceChange(NightwellSearchFieldOriginPreference.self) { origin in
                        if abs(searchFieldOriginX - origin) > 0.5 {
                            searchFieldOriginX = origin
                        }
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(.white.opacity(0.22), lineWidth: 1)
                    }
                    .overlay {
                        NightwellSearchEdgeSweep(active: !collapsed)
                            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(key: SearchBarBottomPreference.self,
                                value: geometry.frame(in: .named("nightwell-search-scroll")).maxY)
                        }
                    }
                    // Instant local suggestions from already available search results.
                    // Never make a network request merely to populate these pills.
                    let normalizedQuery = store.query.trimmingCharacters(in: .whitespacesAndNewlines)
                    let searchCompletions: [String] = {
                        guard normalizedQuery.count >= 2 else { return [] }
                        var seen = Set<String>()
                        var values: [String] = []
                        for track in store.results.prefix(80) {
                            for candidate in [track.title, track.artist] {
                                let candidate = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !candidate.isEmpty,
                                      candidate.localizedCaseInsensitiveContains(normalizedQuery),
                                      candidate.localizedCaseInsensitiveCompare(normalizedQuery) != .orderedSame
                                else { continue }
                                if seen.insert(candidate.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                                                 locale: .current)).inserted {
                                    values.append(candidate)
                                }
                                if values.count == 3 { return values }
                            }
                        }
                        return values
                    }()
                    if !searchCompletions.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            ForEach(searchCompletions, id: \.self) { completion in
                                Button {
                                    store.query = completion
                                    store.scheduleSearch()
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: "magnifyingglass")
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(.white.opacity(0.65))
                                        Text(completion)
                                            .font(.system(size: 14))
                                            .lineLimit(1)
                                        Spacer(minLength: 0)
                                        Image(systemName: "arrow.up.left")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.white.opacity(0.45))
                                    }
                                    .padding(.horizontal, 12)
                                    .frame(height: 36)
                                    .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    if !store.searchMessage.isEmpty { Text(store.searchMessage).font(.caption).foregroundStyle(.secondary) }
                    // Prepared off the UI thread. Never rescan the whole catalogue while typing.
                    let combinedArtists = store.searchArtistSuggestions
                    if !combinedArtists.isEmpty {
                        Text("Исполнители").font(.headline)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 9) {
                                ForEach(combinedArtists) { artist in
                                    Button { openArtist(artist.name) } label: {
                                        HStack(spacing: 8) {
                                            ArtistPortrait(name: artist.name, imageURL: artist.image_url, size: 30)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(artist.name).font(.system(size: 13, weight: .medium))
                                                if let count = artist.track_count {
                                                    Text("\(count) треков").font(.system(size: 10)).foregroundStyle(.secondary)
                                                }
                                            }
                                        }
                                        .padding(.horizontal, 10).padding(.vertical, 6)
                                        .background(.white.opacity(0.09), in: Capsule())
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    // Owned results are ranked first in the same list, without
                    // blocking input while remote providers are still searching.
                    TrackList(tracks: store.results, embedded: true)
                }.padding(.horizontal, 20)
            }
            .coordinateSpace(name: "nightwell-search-scroll")
            .contentMargins(.bottom, bottomContentInset, for: .scrollContent)
            .contentMargins(.bottom, bottomContentInset, for: .scrollIndicators)
            .scrollDismissesKeyboard(.interactively)
            .onPreferenceChange(SearchBarBottomPreference.self) { bottom in
                guard bottom.isFinite, store.screen == .search else { return }
                // Hysteresis prevents a changing header height from flickering at the boundary.
                let next = collapsed ? bottom < 24 : bottom <= 0
                if next != collapsed {
                    withAnimation(reducedMotion ? nil : .easeInOut(duration: 0.18)) { collapsed = next }
                }
            }
            .onChange(of: revealRequest) { _, _ in
                withAnimation(reducedMotion ? nil : .easeOut(duration: 0.22)) {
                    proxy.scrollTo("nightwell-search-top", anchor: .top)
                }
                focusRequest += 1
            }
            .onChange(of: store.query) { _, _ in
                proxy.scrollTo("nightwell-search-top", anchor: .top)
            }
            .onAppear { collapsed = false }
        }
    }
}

private struct SearchBarBottomPreference: PreferenceKey {
    static var defaultValue: CGFloat { .infinity }
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

// Soft white search illumination tracks the actual UIKit text insertion caret.
// UIKit supplies precise caret coordinates even when a long query scrolls horizontally.
private struct NightwellSearchCaretField: UIViewRepresentable {
    @Binding var text: String
    @Binding var caretX: CGFloat
    @Binding var focused: Bool
    var focusRequest = 0

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField(frame: .zero)
        field.delegate = context.coordinator
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        field.textColor = .white
        field.tintColor = .white
        field.font = .systemFont(ofSize: 17, weight: .medium)
        field.attributedPlaceholder = NSAttributedString(
            string: "Трек или исполнитель",
            attributes: [.foregroundColor: UIColor.white.withAlphaComponent(0.44)]
        )
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.keyboardAppearance = .dark
        field.returnKeyType = .search
        field.clearButtonMode = .never
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.lastFocusRequest != focusRequest {
            context.coordinator.lastFocusRequest = focusRequest
            DispatchQueue.main.async {
                if field.window != nil { field.becomeFirstResponder() }
            }
        }
        if field.text != text {
            field.text = text
            context.coordinator.reportCaret(field)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: NightwellSearchCaretField
        var lastFocusRequest = 0
        init(parent: NightwellSearchCaretField) { self.parent = parent }

        @objc func changed(_ field: UITextField) {
            let value = field.text ?? ""
            if parent.text != value { parent.text = value }
            reportCaret(field)
        }

        func textFieldDidChangeSelection(_ field: UITextField) { reportCaret(field) }
        func textFieldDidBeginEditing(_ field: UITextField) {
            DispatchQueue.main.async { self.parent.focused = true }
            reportCaret(field)
        }
        func textFieldDidEndEditing(_ field: UITextField) {
            DispatchQueue.main.async { self.parent.focused = false }
        }
        func textFieldShouldReturn(_ field: UITextField) -> Bool {
            field.resignFirstResponder()
            return true
        }
        func reportCaret(_ field: UITextField) {
            guard let range = field.selectedTextRange else { return }
            // Do not mutate SwiftUI state during a UIViewRepresentable update.
            DispatchQueue.main.async {
                guard field.window != nil else { return }
                let x = field.caretRect(for: range.end).midX
                if abs(self.parent.caretX - x) > 0.5 { self.parent.caretX = x }
            }
        }
    }
}

// The caret's soft white halo is drawn across the *whole* search pill.
// Keeping it behind the text prevents clipping at the UITextField's left edge.
private struct NightwellSearchFieldOriginPreference: PreferenceKey {
    static var defaultValue: CGFloat = 50
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct NightwellSearchCaretLight: View {
    let x: CGFloat
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active || reduceMotion)) { timeline in
                let seconds = timeline.date.timeIntervalSinceReferenceDate
                let pulse = reduceMotion ? 1.0 : 0.94 + 0.06 * sin(seconds * 10)
                let center = min(max(14, x), geometry.size.width - 14)

                Circle()
                    .fill(RadialGradient(
                        colors: [
                            .white.opacity(active ? 0.23 * pulse : 0),
                            .white.opacity(active ? 0.09 * pulse : 0),
                            .clear
                        ],
                        center: .center, startRadius: 0, endRadius: 42
                    ))
                    .frame(width: 84, height: 84)
                    .blur(radius: 4)
                    .position(x: center, y: geometry.size.height / 2)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// Two fast white highlights move across the top and bottom of the search
// field. This view is only used in an overlay; it never affects field size.
private struct NightwellSearchEdgeSweep: View {
    var active = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || !active)) { timeline in
                let seconds = timeline.date.timeIntervalSinceReferenceDate
                let progress = reduceMotion ? 0.5 : seconds.truncatingRemainder(dividingBy: 1.65) / 1.65
                let width = geometry.size.width
                let x = -60 + (width + 120) * CGFloat(progress)

                ZStack {
                    Capsule()
                        .fill(LinearGradient(
                            colors: [.clear, .white.opacity(0.9), .clear],
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .frame(width: 94, height: 2.4)
                        .position(x: x, y: 1.5)

                    Capsule()
                        .fill(LinearGradient(
                            colors: [.clear, .white.opacity(0.22), .clear],
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .frame(width: 105, height: 10)
                        .blur(radius: 3.0)
                        .position(x: x, y: 2)

                    Capsule()
                        .fill(LinearGradient(
                            colors: [.clear, .white.opacity(0.72), .clear],
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .frame(width: 78, height: 2.2)
                        .position(x: x - 20, y: geometry.size.height - 1.5)

                    Capsule()
                        .fill(LinearGradient(
                            colors: [.clear, .white.opacity(0.18), .clear],
                            startPoint: .leading, endPoint: .trailing
                        ))
                        .frame(width: 90, height: 9)
                        .blur(radius: 2.8)
                        .position(x: x - 20, y: geometry.size.height - 2)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

