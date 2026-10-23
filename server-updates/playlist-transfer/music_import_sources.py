"""Read playlist metadata only. No audio downloads or third-party credentials."""
import csv
import html
import io
import json
import re
import unicodedata
from html.parser import HTMLParser
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, quote, urlencode, urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

LIMIT = 1000
MAX_BYTES = 1024 * 1024
PROVIDERS = {'vk': 'ВК Музыка', 'spotify': 'Spotify', 'yandex': 'Яндекс Музыка'}
HOSTS = {'vk.com', 'vk.ru', 'm.vk.com', 'm.vk.ru', 'open.spotify.com',
         'music.yandex.ru', 'music.yandex.com', 'music.yandex.by', 'music.yandex.kz'}

class SourceError(ValueError): pass

def norm(value):
    return ' '.join(re.findall(r'[^\W_]+', unicodedata.normalize('NFKC', str(value)).casefold().replace('ё', 'е')))

def row(title, artist, duration=None):
    if not isinstance(title, str) or not isinstance(artist, str) or not title.strip() or not artist.strip():
        raise SourceError('У каждого трека должны быть название и исполнитель')
    if len(title)>300 or len(artist)>300:
        raise SourceError('Слишком длинное название или имя исполнителя')
    result = {'title': html.unescape(title).strip(), 'artist': html.unescape(artist).strip()}
    if isinstance(duration, (int, float)) and not isinstance(duration, bool) and 0<duration<86400:
        result['duration'] = duration
    return result

def deduplicate(items):
    if not items: raise SourceError('В списке нет треков с названием и исполнителем')
    if len(items)>LIMIT: raise SourceError('За один перенос можно обработать до 1000 треков. Разделите список на части')
    seen, unique = set(), []
    for item in items:
        key=(norm(item['artist']),norm(item['title']))
        if key not in seen: seen.add(key); unique.append(item)
    return unique, len(items)-len(unique)

def parse_text(text):
    if not isinstance(text,str) or not text.strip() or len(text.encode('utf-8'))>MAX_BYTES:
        raise SourceError('Выберите HTML/CSV/TXT/JSON до 1 МБ или вставьте список треков')
    text=text.lstrip('\ufeff').strip()
    if text.startswith('<'):
        return parse_html(text, 'spotify')['tracks']
    if text.startswith(('[','{')):
        try:
            data=json.loads(text);data=data.get('tracks') if isinstance(data,dict) else data
            if not isinstance(data,list): raise SourceError('JSON должен содержать массив tracks')
            if len(data)>LIMIT: raise SourceError('Не больше 1000 треков за перенос')
            if any(not isinstance(t,dict) for t in data):raise SourceError('Каждая строка JSON должна содержать title и artist')
            result=[]
            for t in data:
                artists=t.get('artist') or t.get('artists') or ''
                if isinstance(artists,list):
                    artists=', '.join(a.get('name','') if isinstance(a,dict) else str(a) for a in artists)
                elif isinstance(artists,dict):
                    artists=artists.get('name','')
                duration=t.get('duration')
                if duration is None and isinstance(t.get('durationMs'),(int,float)):
                    duration=t['durationMs']/1000
                result.append(row(t.get('title',''),artists,duration))
            return result
        except (json.JSONDecodeError,AttributeError) as e: raise SourceError('Не удалось прочитать JSON со списком треков') from e
    first=text.splitlines()[0]
    title_keys={'title','track','trackname','song','songname','название','названиетрека','трек'}
    artist_keys={'artist','artists','artistname','artistnames','исполнитель','исполнители'}
    clean=lambda v: re.sub(r'[^\wа-яё]', '', str(v).casefold())
    separator=next((s for s in ('\t',';',',') if s in first),None)
    if separator:
        try:
            table=list(csv.reader(io.StringIO(text),delimiter=separator,strict=True))
            keys=[clean(v.lstrip('\ufeff')) for v in table[0]]
            ti=next((i for i,k in enumerate(keys) if k in title_keys),None)
            ai=next((i for i,k in enumerate(keys) if k in artist_keys),None)
            if ti is not None and ai is not None:
                result=[]
                for number,values in enumerate(table[1:],2):
                    if not values or not any(v.strip() for v in values):continue
                    if max(ti,ai)>=len(values):raise SourceError('Неполная строка CSV: '+str(number))
                    result.append(row(values[ti],values[ai]))
                    if len(result)>LIMIT:raise SourceError('Не больше 1000 треков за перенос')
                return result
        except csv.Error as e:raise SourceError('Проверьте кавычки и разделители CSV') from e
    result=[]
    for number,line in enumerate(text.splitlines(),1):
        if not line.strip():continue
        parts=re.split(r'\s+[—–-]\s+|\t',line,maxsplit=1)
        if len(parts)!=2:raise SourceError('Строка '+str(number)+': используйте формат «Исполнитель — Название» или CSV с колонками artist/title')
        result.append(row(parts[1],parts[0]))
        if len(result)>LIMIT:raise SourceError('Не больше 1000 треков за перенос')
    return result

def canonical(provider, value):
    if not isinstance(provider,str) or provider not in PROVIDERS:raise SourceError('Выберите музыкальный сервис')
    if not isinstance(value,str) or len(value)>2000:raise SourceError('Некорректная ссылка')
    p=urlsplit(value.strip())
    if p.scheme!='https' or p.hostname not in HOSTS or p.username or p.password or p.port not in (None,443):
        raise SourceError('Нужна HTTPS-ссылка на плейлист выбранного сервиса')
    if provider=='spotify' and p.hostname=='open.spotify.com':
        m=re.fullmatch(r'/(?:intl-[a-z]+/)?playlist/([A-Za-z0-9]{22})/?',p.path)
        if m:return 'https://open.spotify.com/embed/playlist/'+m[1]
    if provider=='yandex' and p.hostname.startswith('music.yandex.'):
        m=re.fullmatch(r'/users/([^/]+)/playlists/(\d+)/?',p.path)
        if m:return 'https://api.music.yandex.net/users/'+quote(m[1],safe='')+'/playlists/'+m[2]
        m=re.fullmatch(r'/playlists/([a-fA-F0-9-]{36})/?',p.path)
        if m:return 'https://api.music.yandex.net/playlist/'+m[1]
    if provider=='vk' and p.hostname in {'vk.com','vk.ru','m.vk.com','m.vk.ru'}:
        label=p.path
        if p.path in ('/music','/audio'):
            q=parse_qs(p.query);label='/' + q.get('z',q.get('act',['']))[0].split('/')[0]
        m=re.fullmatch(r'/(?:music/playlist/|audio_playlist)(-?\d+_\d+(?:_[A-Za-z0-9]+)?)/?',label)
        if m:return 'https://vk.com/music/playlist/'+m[1]
    raise SourceError('Не удалось распознать плейлист. Скопируйте ссылку через «Поделиться» или загрузите CSV/TXT')

class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self,req,fp,code,msg,headers,newurl):return None

def fetch(url):
    # URLs are generated by canonical(), never taken from HTML or JSON responses.
    try:
        req=Request(url,headers={'User-Agent':'Mozilla/5.0 (compatible; NightwellPlaylistImport/1.0)', 'Accept':'text/html,application/json','Accept-Encoding':'identity'})
        with build_opener(NoRedirect()).open(req,timeout=15) as response:
            raw=response.read(4*MAX_BYTES+1)
            if len(raw)>4*MAX_BYTES:raise SourceError('Список слишком большой. Используйте CSV/TXT')
            return raw.decode('utf-8-sig',errors='replace')
    except (HTTPError,URLError,TimeoutError,OSError) as e:
        raise SourceError('Сервис не отдал публичный плейлист. Откройте к нему доступ или загрузите CSV/TXT') from e

class Documents(HTMLParser):
    def __init__(self):super().__init__(convert_charrefs=True);self.docs=[];self.active=False;self.data=[];self.audio=[]
    def handle_starttag(self,tag,attrs):
        attrs=dict(attrs)
        if tag=='script':
            self.active=attrs.get('id')=='__NEXT_DATA__' or attrs.get('type') in ('application/ld+json','application/json');self.data=[]
        if 'data-audio' in attrs:
            try:self.audio.append(json.loads(attrs['data-audio']))
            except (ValueError,TypeError):pass
    def handle_data(self,data):
        if self.active:self.data.append(data)
    def handle_endtag(self,tag):
        if tag=='script' and self.active:
            try:self.docs.append(json.loads(''.join(self.data)))
            except ValueError:pass
            self.active=False

def metadata(raw,provider):
    parser=Documents();items=[];counts=[];names=[]
    try:documents=[json.loads(raw)]
    except ValueError:parser.feed(raw);documents=parser.docs
    def visit(value,context='',depth=0):
        if depth>35:return
        if isinstance(value,list):
            for v in value:visit(v,context,depth+1)
        elif isinstance(value,dict):
            for key in ('trackCount','track_count','totalTracks','numberOfItems'):
                count=value.get(key)
                if isinstance(count,int) and not isinstance(count,bool):counts.append(count)
            if context in ('playlist','entity','result') and isinstance(value.get('name',value.get('title')),str):names.append(value.get('name',value.get('title')))
            title=value.get('title',value.get('name'));artists=value.get('artists',value.get('byArtist'))
            if not artists and context=='trackList':artists=value.get('subtitle')
            if isinstance(artists,dict):artists=[artists]
            if isinstance(artists,list):artists=', '.join(a.get('name','') if isinstance(a,dict) else str(a) for a in artists)
            if isinstance(title,str) and isinstance(artists,str) and artists.strip() and (context in ('tracks','track','trackList','item','itemListElement') or value.get('@type')=='MusicRecording' or value.get('type')=='track'):
                duration=value.get('duration_ms',value.get('durationMs'))
                try:
                    seconds=duration/1000 if isinstance(duration,(int,float)) else value.get('duration')
                    if duration is None and provider=='spotify' and isinstance(seconds,(int,float)):seconds/=1000
                    items.append(row(title,artists,seconds))
                except SourceError:pass
                if len(items)>LIMIT:raise SourceError('Не больше 1000 треков за перенос')
                return
            for key,v in value.items():
                if isinstance(v,(list,dict)):visit(v,key,depth+1)
    for doc in documents:visit(doc)
    if provider=='vk':
        for audio in parser.audio:
            if isinstance(audio,list) and len(audio)>5:
                try:items.append(row(audio[3],audio[4],audio[5]))
                except SourceError:pass
    unique,duplicates=deduplicate(items)
    total=max(counts) if counts else None
    if total is not None and total<len(unique):total=None
    complete=total in (len(unique),len(items)) if total is not None else False
    warning='' if complete else ('Сервис сообщил о '+str(total)+' треках, прочитано '+str(len(unique))+'. ' if total is not None else 'Сервис не подтвердил полноту списка. ')+'Для полного переноса можно загрузить CSV/TXT.'
    return {'name':names[0][:80] if names else 'Плейлист из '+PROVIDERS[provider], 'tracks':unique,'duplicates':duplicates,'source_total':total,'complete':complete,'warning':warning}

class PlaylistHTML(HTMLParser):
    """Read saved markup as data. Never execute scripts or load linked resources."""
    VOID = {'area','base','br','col','embed','hr','img','input','link','meta','param','source','track','wbr'}
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.root={'tag':'root','attrs':{},'children':[]};self.stack=[self.root];self.nodes=0
    def handle_starttag(self,tag,attrs):
        self.nodes+=1
        if self.nodes>50000 or len(self.stack)>128:
            raise SourceError('Слишком сложная HTML-страница. Экспортируйте список в CSV или разделите файл')
        # Browsers commonly omit closing table/list tags.
        closers={'tr':{'tr'},'td':{'td','th'},'th':{'td','th'},'li':{'li'}}
        if tag in closers:
            for i in range(len(self.stack)-1,0,-1):
                if self.stack[i]['tag'] in closers[tag]:self.stack=self.stack[:i];break
                if self.stack[i]['tag'] in {'table','ul','ol'}:break
        node={'tag':tag,'attrs':dict(attrs),'children':[]}
        self.stack[-1]['children'].append(node)
        if tag not in self.VOID:self.stack.append(node)
    def handle_startendtag(self,tag,attrs):
        self.handle_starttag(tag,attrs)
        if tag not in self.VOID:self.handle_endtag(tag)
    def handle_endtag(self,tag):
        for i in range(len(self.stack)-1,0,-1):
            if self.stack[i]['tag']==tag:self.stack=self.stack[:i];break
    def handle_data(self,data):self.stack[-1]['children'].append(data)

def html_nodes(node):
    for child in node['children']:
        if isinstance(child,dict):
            yield child
            yield from html_nodes(child)

def html_text(node):
    if node['tag'] in {'script','style','template','noscript'}:return ''
    return ' '.join(' '.join(html_text(c) if isinstance(c,dict) else c for c in node['children']).split())

def parse_html(raw,provider):
    if not isinstance(raw,str) or len(raw.encode('utf-8'))>MAX_BYTES:
        raise SourceError('HTML-файл должен быть не больше 1 МБ')
    parser=PlaylistHTML();parser.feed(raw);parser.close()
    nodes=list(html_nodes(parser.root));items=[]
    titles={'title','track','trackname','song','songname','название','названиетрека','трек'}
    artists={'artist','artists','artistname','artistnames','исполнитель','исполнители'}
    clean=lambda s:re.sub(r'[^\wа-яё]','',s.casefold())
    def add(title,artist):
        items.append(row(title,artist))
        if len(items)>LIMIT:raise SourceError('Не больше 1000 треков за перенос')
    # Explicit tables are portable across exports, independent of CSS classes.
    for table in (n for n in nodes if n['tag']=='table'):
        ti=ai=None
        for tr in (n for n in html_nodes(table) if n['tag']=='tr'):
            cells=[c for c in tr['children'] if isinstance(c,dict) and c['tag'] in {'td','th'}]
            values=[html_text(c) for c in cells];keys=[clean(v) for v in values]
            nt=next((i for i,k in enumerate(keys) if k in titles),None)
            na=next((i for i,k in enumerate(keys) if k in artists),None)
            if nt is not None and na is not None:ti,ai=nt,na;continue
            if ti is not None and ai is not None and any(values):
                if max(ti,ai)>=len(values):raise SourceError('В HTML-таблице есть неполная строка трека')
                add(values[ti],values[ai])
    if not items:
        title_classes={'audio_row__title','d-track__title','track-title','track__title','track-name'}
        artist_classes={'audio_row__performers','d-track__artists','track-artist','track__artist','track-artists'}
        row_classes={'audio_row','d-track','track-row','track','track-item'}
        def classes(n):return set((n['attrs'].get('class') or '').split())
        def field(n,kind):
            a=n['attrs'];prop=a.get('itemprop','')
            return bool(classes(n)&(title_classes if kind=='title' else artist_classes)) or prop==('name' if kind=='title' else 'byArtist') or a.get('data-testid')==('track-name' if kind=='title' else 'track-artist')
        for node in nodes:
            a=node['attrs']
            if a.get('data-title') and a.get('data-artist'):
                add(a['data-title'],a['data-artist']);continue
            if not (classes(node)&row_classes or a.get('data-testid')=='tracklist-row' or a.get('itemtype','').rstrip('/').endswith('/MusicRecording')):continue
            descendants=list(html_nodes(node))
            tn=next((n for n in descendants if field(n,'title')),None)
            an=next((n for n in descendants if field(n,'artist')),None)
            # Spotify saved rows use links rather than stable CSS names.
            if tn is None:tn=next((n for n in descendants if n['tag']=='a' and re.search(r'/(?:intl-[a-z]+/)?track/[^/]+',n['attrs'].get('href') or '')),None)
            if an is None:
                links=[n for n in descendants if n['tag']=='a' and re.search(r'/artist/[^/]+',n['attrs'].get('href') or '')]
                artist=', '.join(html_text(n) for n in links)
            else:artist=html_text(an)
            if tn is not None and artist:add(html_text(tn),artist)
    result=None
    if not items:
        try:result=metadata(raw,provider)
        except SourceError as e:
            raise SourceError('В HTML не найден список с названиями и исполнителями. Сохраните страницу после загрузки треков или используйте CSV/TXT/JSON') from e
    if result is None:
        unique,duplicates=deduplicate(items)
        title=next((html_text(n) for n in nodes if n['tag']=='title' and html_text(n)),None)
        result={'name':(title or 'Плейлист из '+PROVIDERS[provider])[:80],'tracks':unique,'duplicates':duplicates,'source_total':None}
    # A saved page may contain only loaded rows, even when embedded metadata has a count.
    result.update(complete=False,warning='HTML может содержать только загруженную часть плейлиста. Перед сохранением сверьте число треков с оригиналом.')
    return result

def read_source(body,loader=fetch):
    provider=body.get('provider')
    if not isinstance(provider,str) or provider not in PROVIDERS:raise SourceError('Выберите сервис')
    name=body.get('name','')
    if not isinstance(name,str) or len(name)>80:raise SourceError('Название плейлиста должно быть не длиннее 80 символов')
    if body.get('text'):
        text=body['text']
        if not isinstance(text,str) or len(text.encode('utf-8'))>MAX_BYTES:raise SourceError('Файл должен быть не больше 1 МБ')
        if text.lstrip('\ufeff \r\n\t').startswith('<'):result=parse_html(text,provider)
        else:
            tracks,duplicates=deduplicate(parse_text(text))
            result={'name':name.strip() or 'Перенос из '+PROVIDERS[provider], 'tracks':tracks,'duplicates':duplicates,'source_total':len(tracks)+duplicates,'complete':True,'warning':''}
    else:result=metadata(loader(canonical(provider,body.get('url',''))),provider)
    if name.strip():result['name']=name.strip()
    return result
