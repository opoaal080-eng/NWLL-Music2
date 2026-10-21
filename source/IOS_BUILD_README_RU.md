# Сборка восстановленного Nightwell Music для iOS

Добавлены отсутствовавший `NightwellMusic/NightwellMusic.entitlements` и проверка входных файлов `scripts/verify-ios-build-inputs.py`. Обновлён `.github/workflows/build-ios.yml`.

`project.yml` уже содержит настройку XcodeGen и генерирует `NightwellMusic/Info.plist` при `xcodegen generate`; вручную добавлять второй Info.plist не нужно. Исходники Swift, ресурсы и тесты сохранены.

Сборка в GitHub Actions: Actions → Build Nightwell Music iOS (Recovered) → Run workflow. Для результата требуется macOS runner и Xcode. После успешной сборки скачайте артефакт `Nightwell-Music-iOS-unsigned`. IPA **не подписан**, для установки нужна подпись.

Важно: эта восстановленная версия пока не подтверждена как точная копия последней iOS-сборки. Настоящая сборка Xcode в этом архиве не выполнялась.
