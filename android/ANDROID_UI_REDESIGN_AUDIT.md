# Android Nightwell Music: UI audit and first verified change set

Source of truth: `main` at `c90fdf5199aff9e905b8fc5cf2a55ca339f8b724`, Android Java View code and SwiftUI code under `NightwellMusic/`. Audit performed from source, **not** from a running Android/iOS screen comparison.

| Surface | Code finding | Root cause | Action in this PR |
| --- | --- | --- | --- |
| All pages, especially landscape | Insets padding only used top/bottom | Root `MainActivity.build()` omitted left/right system cutout insets | Shared `NightwellDesign.applySafeArea` handles bars, cutouts and IME |
| Header and mini-player | Icon hit areas 40–44dp | Hardcoded widths in `MainActivity.build()` | Main controls use 48dp touch targets |
| Player cover | Size tied to fixed screen-height thresholds and allowed width beyond the content column | `MainActivity.addCover()` | Pure `PlayerArtworkSizing.sizeDp`, constrained in landscape/compact/large layouts |
| Playback queue | Every adapter bind built new nested views | `MainActivity.showQueue().getView()` ignored `convertView` | Added recyclable, accessible `NightwellQueueRow` |
| Common UI | Different spacing, radii, touch heights across views | Scattered constants despite existing `NightwellDesign` | Added common design geometry tokens and applied to several controls |
| Dialog movement | Entrance animation runs regardless of system preference | `MainActivity.styleSheet()` | Respect disabled system animators |
| Navigation/search/library/settings | Visual parity unknown from code alone | No before/after screenshots examined for this audit | Still needs device screenshot review and screen-by-screen polish |

## Design reference

The native Android app is written with Java `View`/`LinearLayout`/`TextView`; no Compose migration was attempted. The iOS reference is SwiftUI (`NightwellMusic/App.swift`, `NativePlayerViews.swift`) with consistent typography, grayscale surfaces, and cover-derived scenery. Visual identity should be translated to Android, not copied pixel-for-pixel.

## Existing behavior intentionally untouched

No changes to server endpoints, authentication, subscription logic, persistence keys, offline data, stream loading, playback, recommendation algorithms or playlist ordering.

## Testing

- Added plain Java geometry tests for compact, typical, large and landscape covers.
- The Android GitHub Actions workflow now runs for PRs targeting `main`.
- The hosted emulator workflow has been extended to collect `check-native-layout.py` screenshots in addition to existing menu/import checks.
- **Test execution and visual equality are not asserted here.** Consult this PR's Actions checks/artifacts before merging. No claim of an APK or iOS parity without successful CI and screenshot review.

## Remaining implementation tasks

1. Visually compare Android screenshots from compact, standard, large and landscape devices with iOS reference captures. Investigate any cropped/tight player controls, real keyboard insets, and large font scaling.
2. Split other monolithic `MainActivity` UI builders into reusable components, keeping model and API logic stable.
3. Unify search cards, favorites and playlists, offline rows, account, Premium, lyrics, settings and transfer sheets with a single screen-scale system and transitions.
4. Test accessibility touch targets, text scaling, animator scale disabled, navigation controls, screen readers, and state preservation on rotation.
5. Verify rendering quality on a physical Android device and do an independent regression review before release.
