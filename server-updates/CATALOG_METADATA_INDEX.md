# Локальный каталог Audius / SoundCloud для Nightwell Music

Модуль `catalog_metadata_index.py` скачивает **только метаданные**: название, исполнителя, длительность, исходный ID, ссылку на страницу и обложку. Аудиофайлы не скачиваются. Результат хранится в SQLite (`nightwell_catalog.sqlite`) с полнотекстовым индексом FTS5. Повторные поиски по уже собранному каталогу работают локально.

## Как запустить на Windows (Python 3.10+)

В папке `server-updates`:

```bat
py -3 catalog_metadata_index.py index --sources audius --db D:\Nightwell\nightwell_catalog.sqlite --max-tracks 50000 --max-pages 250
py -3 catalog_metadata_index.py stats --db D:\Nightwell\nightwell_catalog.sqlite
py -3 catalog_metadata_index.py search "Кино Группа крови" --db D:\Nightwell\nightwell_catalog.sqlite
```

Можно положить запросы и имена артистов в UTF-8 файл `queries.txt`, по одному запросу на строку, затем:

```bat
py -3 catalog_metadata_index.py index --sources audius --db D:\Nightwell\nightwell_catalog.sqlite --seed-file queries.txt --max-tracks 100000
```

Для SoundCloud нужен **официальный доступ к API** и отдельная проверка прав на сохранение метаданных. Убедись, что хранение такой информации соответствует условиям доступа, прежде чем включать:

```bat
set SOUNDCLOUD_CLIENT_ID=ВАШ_CLIENT_ID
set SOUNDCLOUD_CLIENT_SECRET=ВАШ_CLIENT_SECRET
py -3 catalog_metadata_index.py index --sources soundcloud --db D:\Nightwell\nightwell_catalog.sqlite --seed-file queries.txt --max-tracks 100000 --allow-soundcloud-metadata-store
```

Альтернатива: указать готовый действующий `SOUNDCLOUD_ACCESS_TOKEN` вместо `CLIENT_ID/CLIENT_SECRET`. **Никогда не публикуй токены и секреты в GitHub.**

### Как использовать на сервере

```python
from catalog_metadata_index import open_db, search_tracks

db = open_db(r"D:\Nightwell\nightwell_catalog.sqlite")
candidates = search_tracks(db, "исполнитель название", limit=30)
# [{'source': 'audius', 'source_id': '...', 'title': ..., 'artist': ..., ...}, ...]
```

Запрос к базе **не создаёт проигрываемый трек Nightwell автоматически**. В основном сервере (которого нет в этом репозитории) надо сделать следующий шаг: брать `source + source_id` и разрешать их существующим модулем Audius/SoundCloud в привычный формат API `/api/tracks`. В момент воспроизведения существующий плеер запрашивает стрим по правилам соответствующего источника. Так поиск работает локально, а сетевое обращение за аудио остаётся при прослушивании.

Важно: не возвращай в API клиента записи с вымышленным `id`, пока сервер не умеет воспроизводить/сохранять такие ID.

### Быстрый поиск для основного сервера по HTTP

После индексации можно поднять локальный процесс, который вообще не обращается к Audius/SoundCloud при поиске:

```bat
py -3 catalog_search_service.py --db D:\Nightwell\nightwell_catalog.sqlite --port 8099
```

С основного Python/Go-сервера сделай внутренний запрос:

```text
GET http://127.0.0.1:8099/catalog/search?q=artist%20title&limit=20
```

Ответ: `{"tracks":[{"source":"audius","source_id":"...",...}],"metadata_only":true}`. Это **только кандидаты**, не готовые воспроизводимые Nightwell ID. Существующий сервер должен преобразовать `source_id` через свой Audius/SoundCloud resolver до возврата клиенту. Никакого аудио в индексаторе нет. Порт доступен только на `127.0.0.1`, наружу его открывать не нужно.

### Поведение и ограничения

- Прогресс хранится в таблице `jobs` после каждой страницы. Повторная команда продолжает обход с последнего успешно сохранённого курсора.
- Для Audius обходятся опубликованные страницы `/tracks/latest`, а при `--seed-file` дополнительно `/tracks/search`. Для SoundCloud используется официальный поиск `/tracks` с `linked_partitioning` по списку запросов.
- Обход **не гарантирует весь каталог**: провайдеры не предоставляют бесконечную выгрузку через эти конечные точки. Сохраняется только фактически полученное, в пределах `--max-pages`, `--max-tracks` и лимитов API.
- Ошибки 429 и временные 5xx повторяются с паузами. Для защиты сервера и API между запросами есть задержка.
- Поиск использует точные токены и более широкий запасной запрос, чтобы находить кандидатов при лишних словах. Сопоставление опечаток и выбор корректной версии продолжаются на стороне клиента.
- SQLite-файл можно переносить на другой сервер и резервировать. Для работы поиска после первичной индексации постоянные API-запросы не нужны, но доступность треков, их удаление и ссылки на поток со временем могут меняться.

**Документация:** https://docs.audius.co/api/ , https://developers.soundcloud.com/docs/ , https://help.soundcloud.com/hc/en-us/articles/115003446727-SoundCloud-Public-APIs
