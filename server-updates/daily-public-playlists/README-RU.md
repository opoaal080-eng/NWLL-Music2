# Ежедневные подборки Nightwell Music

Файл `daily_public_playlists.py` устанавливается на Windows-сервер Nightwell Music, а не в приложения.

1. Скопировать в `C:\Nightwell Music\nightwell-music\daily_public_playlists.py`.
2. В модуле, где создаётся FastAPI `app` и устанавливаются API-маршруты, импортировать:
   `from daily_public_playlists import install as install_daily_public_playlists`
3. После создания `app` зарегистрировать:
   `install_daily_public_playlists(app, identity, DB_PATH)`
   Где `identity(request)` — существующая серверная функция авторизации,
   `DB_PATH` — путь к SQLite-БД Nightwell Music (те же аргументы, что у модуля переноса музыки).
4. Перезапустить сервер. Проверить авторизованным запросом `GET /api/daily-public-playlists`.

Подборки формируются по публичному каталогу. Для каждого аккаунта и UTC-дня
результат стабилен и кэшируется в SQLite на 14 дней. Обновление «раз в день»
ленивое: новый дневной список создаётся при первом открытии раздела после 00:00 UTC.
Это не фоновая задача и не публикация чужих приватных плейлистов.
Три раздела пока формируются псевдослучайным образом; индивидуальные рекомендации
по прослушиваниям пока не реализованы.
