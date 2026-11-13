import SwiftUI
import UIKit

/// Native UIButton menu. Constructed on track changes, never on a player
/// progress tick or from a blocking SwiftUI sheet presentation.
struct NightwellPlayerNativeMenu: UIViewRepresentable {
    let snapshot: NightwellPlayerActionSnapshot?
    let onEqualizer: () -> Void
    let onSeededRhythm: (Track) -> Void
    let onLyrics: () -> Void
    let onClip: (URL?, Track) -> Void
    let onHide: (Track) -> Void
    let onDownload: (Track) -> Void
    let onEnqueue: (Track, Bool) -> Void
    let onAddPlaylist: (Track, Playlist) -> Void
    let onQuality: (String) -> Void
    let onAnimationChanged: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        button.tintColor = .white
        button.showsMenuAsPrimaryAction = true
        button.changesSelectionAsPrimaryAction = false
        button.accessibilityLabel = "Действия с треком"
        button.menu = UIMenu(children: [])
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        let coordinator = context.coordinator
        coordinator.onEqualizer = onEqualizer
        coordinator.onSeededRhythm = onSeededRhythm
        coordinator.onLyrics = onLyrics
        coordinator.onClip = onClip
        coordinator.onHide = onHide
        coordinator.onDownload = onDownload
        coordinator.onEnqueue = onEnqueue
        coordinator.onAddPlaylist = onAddPlaylist
        coordinator.onQuality = onQuality
        coordinator.onAnimationChanged = onAnimationChanged
        guard coordinator.snapshot?.id != snapshot?.id else { return }
        coordinator.snapshot = snapshot
        button.menu = coordinator.menu()
    }

    final class Coordinator {
        var snapshot: NightwellPlayerActionSnapshot?
        var onEqualizer: (() -> Void)?
        var onSeededRhythm: ((Track) -> Void)?
        var onLyrics: (() -> Void)?
        var onClip: ((URL?, Track) -> Void)?
        var onHide: ((Track) -> Void)?
        var onDownload: ((Track) -> Void)?
        var onEnqueue: ((Track, Bool) -> Void)?
        var onAddPlaylist: ((Track, Playlist) -> Void)?
        var onQuality: ((String) -> Void)?
        var onAnimationChanged: (() -> Void)?

        func menu() -> UIMenu {
            let quality = UIMenu(title: "Качество звука",
                                 image: UIImage(systemName: "waveform"),
                                 children: [
                qualityAction("Авто", "auto"),
                qualityAction("Низкое", "low"),
                qualityAction("Среднее", "medium"),
                qualityAction("Высокое", "high")
            ])
            var actions: [UIMenuElement] = [
                quality,
                UIAction(title: "Эквалайзер",
                         image: UIImage(systemName: "slider.vertical.3")) { [weak self] _ in
                    self?.onEqualizer?()
                },
                UIAction(title: snapshot?.lyricsVisible == true ? "Обложка" : "Текст песни",
                         image: UIImage(systemName: "text.alignleft")) { [weak self] _ in
                    self?.onLyrics?()
                }
            ]
            // Artwork animation only applies to the immersive full-screen cover.
            if snapshot?.coverStyle != "classic" {
                actions.append(UIAction(
                    title: animationEnabled ? "Отключить анимацию обложки" : "Включить анимацию обложки",
                    image: UIImage(systemName: "livephoto")
                ) { [weak self] _ in
                    let enabled = self?.animationEnabled ?? true
                    UserDefaults.standard.set(!enabled, forKey: "nw-animated-album-artwork")
                    self?.onAnimationChanged?()
                })
            }
            if let track = snapshot?.track {
                actions.append(UIAction(title: "Играть следующим",
                                        image: UIImage(systemName: "text.line.first.and.arrowtriangle.forward")) { [weak self] _ in
                    self?.onEnqueue?(track, true)
                })
                actions.append(UIAction(title: "Добавить в очередь",
                                        image: UIImage(systemName: "text.badge.plus")) { [weak self] _ in
                    self?.onEnqueue?(track, false)
                })
                actions.append(UIAction(title: "Твой ритм по треку",
                                        image: UIImage(systemName: "waveform.path")) { [weak self] _ in
                    self?.onSeededRhythm?(track)
                })
                // Keep the action visible even when prefetch failed or the
                // YouTube API temporarily reached its quota. A tap retries.
                actions.append(UIAction(
                    title: snapshot?.clipURL == nil ? "Найти клип" : "Клип",
                    image: UIImage(systemName: "play.rectangle")
                ) { [weak self] _ in
                    guard let self else { return }
                    self.onClip?(self.snapshot?.clipURL, track)
                })
                let hidden = snapshot?.recommendationHidden == true
                actions.append(UIAction(title: hidden ? "Вернуть в рекомендации" : "Не рекомендовать",
                                        image: UIImage(systemName: "hand.thumbsdown")) { [weak self] _ in
                    self?.onHide?(track)
                })
                let downloaded = snapshot?.downloaded == true
                actions.append(UIAction(title: downloaded ? "Удалить загрузку" : "Скачать",
                                        image: UIImage(systemName: downloaded ? "trash" : "arrow.down.to.line")) { [weak self] _ in
                    self?.onDownload?(track)
                })
                if let base = snapshot?.shareBaseURL {
                    let url = base.appendingPathComponent("track/" + track.id)
                    actions.append(UIAction(title: "Поделиться",
                                            image: UIImage(systemName: "square.and.arrow.up")) { _ in
                        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
                        guard let scene = UIApplication.shared.connectedScenes
                            .compactMap({ $0 as? UIWindowScene })
                            .first(where: { $0.activationState == .foregroundActive }),
                              let root = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return }
                        var target = root
                        while let presented = target.presentedViewController { target = presented }
                        controller.popoverPresentationController?.sourceView = target.view
                        controller.popoverPresentationController?.sourceRect =
                            CGRect(x: target.view.bounds.midX, y: target.view.bounds.midY,
                                   width: 1, height: 1)
                        target.present(controller, animated: true)
                    })
                }
                if let playlists = snapshot?.playlists, !playlists.isEmpty {
                    actions.append(UIMenu(title: "Добавить в плейлист",
                                          image: UIImage(systemName: "text.badge.plus"),
                                          children: playlists.map { list in
                        UIAction(title: list.name) { [weak self] _ in
                            self?.onAddPlaylist?(track, list)
                        }
                    }))
                }
            }
            return UIMenu(children: actions)
        }

        private var animationEnabled: Bool {
            UserDefaults.standard.object(forKey: "nw-animated-album-artwork") as? Bool ?? true
        }

        private func qualityAction(_ title: String, _ value: String) -> UIAction {
            let selected = UserDefaults.standard.string(forKey: "nw-audio-quality") ?? "auto"
            let isSelected = selected == value || (value == "low" && selected == "economy")
            return UIAction(title: title, state: isSelected ? .on : .off) { [weak self] _ in
                UserDefaults.standard.set(value, forKey: "nw-audio-quality")
                self?.onQuality?(value)
            }
        }
    }
}
