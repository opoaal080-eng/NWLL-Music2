# Nightwell Music, исходники приложений (21.10.2026)

В архив включены **только исходники приложений** iOS, Android и Windows. Серверные файлы, веб-сервер и резервная история Git удалены из этой копии. Оригинальный восстановленный архив не изменён.

## Структура
- `NightwellMusic/`, `NativeTests/`, `project.yml`, `.github/workflows/build-ios.yml` — iOS (Swift, XcodeGen).
- `android/` — Android (Gradle, Java).
- `windows/` — Windows (WPF, .NET 8).
- `design-assets/` — изображения и оформление, относящиеся к клиентам.

## Что подтверждено
Файлы приложений извлечены из восстановленного проекта. В Android build.gradle указано versionName 1.1.6-autumn, в Windows csproj Version 1.1.1. Совпадение с более новыми установленными приложениями **1.2.0 не подтверждено**. Проект нельзя считать точной копией последних установленных версий.

## Как собрать
- iOS: macOS + Xcode + XcodeGen; `xcodegen generate`, затем сборка через Xcode или GitHub Actions.
- Android: JDK 17, Android SDK 35, Gradle (см. конфигурацию), `gradle :app:assembleDebug` из каталога android.
- Windows: Windows + .NET 8 SDK, `dotnet publish windows/Nightwell.Native.csproj -c Release -r win-x64 --self-contained true`.

**Проверка ограничена:** в текущем Linux-окружении отсутствуют Xcode, Gradle, dotnet и adb. Поэтому успешная нативная сборка не подтверждена. Для установки Android поверх прежней версии также требуется тот же ключ подписи.
