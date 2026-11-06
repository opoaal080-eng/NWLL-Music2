"""Explicit wave preferences. No audio-language/mood claims without metadata."""
import re

OPTIONS = {
    'character': [('balanced', 'На мой вкус'), ('discover', 'Открытия'), ('favorites', 'Избранное')],
    'mood': [('any', 'Любое'), ('energetic', 'Бодрое'), ('calm', 'Спокойное'), ('happy', 'Весёлое'), ('sad', 'Грустное')],
    'language': [('any', 'Любой'), ('ru', 'Русский'), ('foreign', 'Иностранный'), ('instrumental', 'Без слов')],
}
MOODS = {
    'energetic': ('energetic dance workout phonk edm энергичная танцевальная фонк', 'dance workout'),
    'calm': ('calm chill ambient acoustic lofi спокойная акустика релакс', 'chill ambient'),
    'happy': ('happy upbeat disco funk весёлая диско', 'happy upbeat'),
    'sad': ('sad melancholic melancholy грустная меланхолия', 'sad melancholic'),
}

def preferences(values):
    result = {}
    for name, choices in OPTIONS.items():
        value = values.get(name, choices[0][0])
        if value not in {key for key, _ in choices}:
            raise ValueError('Некорректная настройка подборки: ' + name)
        result[name] = value
    return result

def text(track):
    value = dict(track)
    return ' '.join(str(value.get(k) or '') for k in ('title', 'artist', 'album', 'genre', 'tags')).casefold()

def language(track):
    value = dict(track)
    explicit = str(value.get('language') or '').casefold()
    if explicit in ('ru', 'rus', 'russian'): return 'ru'
    if explicit in ('instrumental', 'zxx'): return 'instrumental'
    if explicit and explicit not in ('und', 'unknown'): return 'foreign'
    label = text(track)
    if re.search(r'\b(instrumental|инструментал|инструментальная|без слов|karaoke|караоке)\b', label): return 'instrumental'
    # This is a metadata hint, not speech recognition.
    if re.search('[а-яё]', label): return 'ru'
    if re.search('[a-z]', label): return 'foreign'
    return 'unknown'

def eligible(track, settings, favorites, heard):
    tid = track['id']
    if settings['character'] == 'favorites' and tid not in favorites: return False
    if settings['character'] == 'discover' and tid in (favorites | heard): return False
    return settings['language'] == 'any' or language(track) == settings['language']

def boost(track, settings):
    mood = settings['mood']
    if mood == 'any': return 0
    tokens = set(re.findall(r'[^\W_]+', text(track)))
    wanted = set(MOODS[mood][0].split())
    other = set().union(*(set(v[0].split()) for k, v in MOODS.items() if k != mood)) - wanted
    return min(72, len(tokens & wanted) * 24) - min(16, len(tokens & other) * 6)

def seeds(original, settings):
    if settings['mood'] == 'any' and settings['language'] == 'any': return original
    mood = MOODS.get(settings['mood'], ('', 'music'))[1]
    prefix = {'ru': 'русская музыка', 'foreign': 'english music', 'instrumental': 'instrumental'}.get(settings['language'], '')
    return [str((prefix + ' ' + mood).strip()), *original[:1]]
