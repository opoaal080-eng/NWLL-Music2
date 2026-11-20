# Подпись Nightwell Music с виджетами

Приложение использует WidgetKit и общий контейнер App Group.

- Bundle ID приложения: `fun.nightwell.music`
- Bundle ID виджета: `fun.nightwell.music.widgets`
- Общий App Group: `group.fun.nightwell.music`

Для отображения названий и обложек **оба исполняемых файла**
`NightwellMusic.app` и `NightwellWidgets.appex` должны быть подписаны
одним Team ID, а оба provisioning profile должны разрешать этот App Group.

Если подпись была сделана без App Groups, виджет будет установлен, но
будет показывать «Нет синхронизации / Нужна подпись с App Group».
Это ограничение iOS и не исправляется повторной установкой того же IPA.

Убедитесь, что App Group зарегистрирован в Apple Developer и включён
в App ID приложения и расширения. При переподписи IPA важно не
удалять расширение `PlugIns/NightwellWidgets.appex`.

Для диагностики подписи на macOS:

```sh
codesign -d --entitlements :- Payload/NightwellMusic.app
codesign -d --entitlements :- Payload/NightwellMusic.app/PlugIns/NightwellWidgets.appex
```

В обоих результатах найдите
`com.apple.security.application-groups` и `group.fun.nightwell.music`.
Также проверьте, что этот App Group присутствует в provisioning profiles.
Неподписанная IPA из GitHub Actions содержит только заготовку прав, а
не действующую подпись Apple.

После правильной установки: запустите Nightwell Music, включите трек,
дождитесь обложки и повторно откройте домашний экран. WidgetKit
сам определяет частоту обновления виджетов.
