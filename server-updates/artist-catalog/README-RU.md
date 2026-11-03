# Nightwell Music — серверный каталог исполнителей

Маршруты:
- GET /api/artists?q=имя&limit=16 — исполнители, количество треков, image_url.
- GET /api/artists/profile?name=имя — профиль исполнителя и доступные для проигрывания треки.

Каталог пополняется из действующего /api/tracks и не меняет идентификаторы треков. Данные сохраняются отдельно для каждого аккаунта. Поиск зависит от полноты действующего каталога: данный модуль не импортирует все мировые музыкальные записи.

Быстрая установка в Windows (если сервер использует app.py, app, identity и /api/tracks):
1. Распаковать Nightwell-Artist-Catalog-Server.zip из GitHub Actions.
2. Запустить Install_Artist_Catalog.bat. По умолчанию используется
   C:\Nightwell Music\nightwell-music. Можно передать другой путь первым аргументом.
3. Установщик проверит структуру, сделает резервную копию app.py и добавит модуль.
   При несовместимой версии он откажется менять сервер. После установки перезапустить
   уже существующий батник запуска Nightwell, новый сервер запускать не нужно.

Ручная установка, если автоматическая проверка не прошла:
1. Скопировать artist_catalog.py рядом с работающим app.py.
2. После создания FastAPI app и регистрации /api/tracks подключить:

    from artist_catalog import install as install_artist_catalog
    install_artist_catalog(app, identity, db_path=r"C:\Nightwell Music\nightwell-music\artist_catalog.sqlite3")

Функция identity(request) должна возвращать идентификатор авторизованного аккаунта либо None. Если у действующего приложения авторизация называется иначе, передать эквивалентный адаптер. В репозитории нет работающего app.py, поэтому инсталляция вручную необходима и не означает, что сервер уже обновился.

Отдельные фотографии из собственного облака:
1. Загрузить разрешённые к использованию портреты в свой Cloudflare R2/CDN либо другой доступный HTTPS-хостинг.
2. Создать JSON-файл artist_images.json, например:

    {"Имя исполнителя": "https://YOUR-REAL-CDN.example/artists/artist.webp"}

3. В батнике запуска до команды Python прописать реальные значения:
    set "NW_ARTIST_IMAGE_MAP=C:\Nightwell Music\nightwell-music\artist_images.json"
    set "NW_ARTIST_IMAGE_HOSTS=your-real-cdn-host.example"

Только URL с разрешённых HTTPS-хостов попадают в API. Фото из альбомов не используются для профиля артиста, при отсутствии портрета показываются инициалы. JSON перечитывается после изменений.

Не включено получение профилей и аватаров из SoundCloud API: их условия ограничивают создание сторонних страниц артистов. Источник: https://developers.soundcloud.com/docs/api/terms-of-use.

Тестирование:
    python -m unittest discover -s server-updates/artist-catalog -p "test_*.py" -v
