# Nightwell Music: только последние изменения

В комплекте только серверный каталог исполнителей, исправление
путаницы между именем музыканта и загрузчика SoundCloud и выбор качества
из существующих у SoundCloud AAC HLS-потоков. Старые модули оплаты,
почты, переноса плейлистов и ежедневных подборок НЕ включены.

## Установка

1. Распакуй ZIP отдельно, не поверх работающего сервера.
2. Запусти Check_Latest_Server.bat. По умолчанию используется
   C:\Nightwell Music\nightwell-music и выполняется только проверка.
3. Останови сервер и запусти Install_Latest_Server.bat.
4. Перезапусти прежним серверным батником. Не нужен Docker.

Создаётся backups/nw-latest-... с исходными файлами.
Для отката вызови installer.py --rollback с путём к этой резервной папке.
Если структура app.py неизвестна или маршруты конфликтуют, установщик
остановится и сохранит оригиналы.

## SoundCloud: доступное качество

GET /api/audio-quality/options?track_id=TRACK&quality=high
GET /api/audio-quality/stream/TRACK?quality=high&format=hls

auto: лучшая доступная AAC HLS-версия, обычно 160, иначе 96 кбит/с.
economy: 96 кбит/с, если доступно, иначе 160.
high: 160 кбит/с, если доступно, иначе 96.

Варианты берутся из официального SoundCloud API /tracks/{URN}/streams.
НЕТ перекодировки и искусственных 320 кбит/с. Ответ options содержит
actual_kbps, selected_quality, fallback, message, source, чтобы приложение
показывало реально доступный битрейт. Поток stream даёт 307 на
выбранный подписанный SoundCloud AAC HLS URL. Если официальных вариантов
нет или API недоступен, возвращается стандартный /api/stream, без
ложного указания качества.

## Настройка доступа к SoundCloud API

NW_SC_CLIENT_ID — client ID зарегистрированного приложения SoundCloud.
NW_SC_CLIENT_SECRET — секрет приложения SoundCloud.

Секреты должны оставаться в переменных окружения сервера, не в GitHub.
Сервер использует официальный OAuth client_credentials. Для приватных и
ограниченных треков может потребоваться другой способ авторизации.
Реквизиты API SoundCloud не включены в архив.

## Важно о клиентах и интеграции

Новый серверный маршрут не переключает качество в старых IPA/APK.
Для воспроизведения клиент должен передать выбранное quality в
/api/audio-quality/stream, а сообщение получить из /api/audio-quality/options.
Если приложение продолжает использовать старый /api/stream, качество не
изменится.

Сервер ищет SoundCloud URN или permalink в ответе действующего /api/tracks
с авторизацией текущего аккаунта. Если исходный сервер хранит только
внутренние идентификаторы, нужна интеграция с реальным app.py. Исходный
app.py в репозитории отсутствует. Модуль также принимает собственные
проверенные callbacks track_provider, streams_provider и token_provider.

Для имени исполнителя теперь приоритет у официального SoundCloud
metadata_artist. Имя аккаунта загрузчика хранится отдельно.
Индекс аккаунтов и права доступа не смешиваются.

Справка SoundCloud:
https://developers.soundcloud.com/blog/api-streaming-urls/
https://developers.soundcloud.com/docs/api/


## Разделение Happ и прямых соединений

Для Windows в режиме Happ Proxy доступен HTTP-прокси
`http://127.0.0.1:10809`. В текущем обновлении только исходящие запросы
SoundCloud OAuth и SoundCloud API в `audio_quality.py` идут через Happ.
Остальная работа Nightwell Music, Caddy, база данных, авторизация,
премиум и Nightwell Chat не перенаправляются в Happ.

При необходимости переопредели локальный адрес ДО запуска сервера:

```bat
set "NW_SC_PROXY=http://127.0.0.1:10809"
call "Start_Nightwell.bat"
```

НЕ задавай глобальные `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY` для
всего сервера. НЕ включай TUN. Если Happ отключён, запросы к SoundCloud
через новые клиенты завершатся ошибкой, но не утекут в прямой канал.

Для существующего загрузчика SoundCloud в основном `app.py` используй
`soundcloud_proxy.py` при создании ТОЛЬКО его сетевых клиентов:

```python
from soundcloud_proxy import (
    soundcloud_async_client, soundcloud_requests_session,
    soundcloud_ytdlp_options,
)

# httpx: только обращения к SoundCloud
async with soundcloud_async_client(timeout=12) as client:
    response = await client.get("https://api.soundcloud.com/...")

# requests: отдельная сессия только SoundCloud
sc_session = soundcloud_requests_session()

# yt-dlp: параметры одного SoundCloud-запроса
ydl_opts = soundcloud_ytdlp_options({"quiet": True})
```

Используй обычный прямой HTTP-клиент для собственных API и платежей.
Не нужно проксировать входящие соединения на 80/443, Caddyfile не меняется.

Важно: без исходного работающего `app.py` нельзя автоматически изменить
его существующие `/api/stream` и загрузчик. Кроме того,
`/api/audio-quality/stream` отдаёт HTTP 307 на SoundCloud CDN.
Если клиент сам открывает этот URL, его последующее соединение
НЕ идёт через серверный Happ. Чтобы CDN тоже всегда проходил через Happ,
надо заменить прямой редирект серверной потоковой отдачей с поддержкой
Range/HLS и пересылкой медиа через прокси. Этот пакет не заявляет такую
функцию и не меняет существующий рабочий аудиопоток.

Если установленный рабочий сервер использует `soundcloud_import.py` с
`NW_SC_PROXY`, этого параметра достаточно, чтобы его `/api/stream`
передавал SoundCloud CDN-сегменты через Happ. В старой версии Nightwell
этот режим уже реализован. Для обновлённого или другого `app.py`
проверь поведение маршрута перед включением на рабочем сервере.
