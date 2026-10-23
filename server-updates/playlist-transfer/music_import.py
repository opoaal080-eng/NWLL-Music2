"""Account-scoped playlist transfer jobs. Uses the host's authorized catalog/playlist API."""
import asyncio
import difflib
import json
import re
import sqlite3
import time
import uuid
from pathlib import Path
from contextlib import contextmanager

import httpx
from fastapi import HTTPException, Request
from music_import_sources import MAX_BYTES, PROVIDERS, SourceError, norm, read_source

ACTIVE={'reading','matching','saving'}
VERSIONS={'remix','ремикс','live','concert','концерт','acoustic','акустика','instrumental','караоке','karaoke','sped','slowed','cover','кавер','remaster','remastered','ремастер','extended','edit','reverb','акустическая'}

# Strip presentation labels, but keep version markers such as live/remix.
def searchable(value):
    value = re.sub(r"\b(?:official\s+(?:music\s+)?(?:video|audio)|lyrics?\s+video|official|lyrics?|hq|hd|4k)\b", " ", str(value), flags=re.I)
    return norm(value)

def transliterate(value):
    letters = dict(zip('абвгдежзийклмнопрстуфхцчшщыэюя',
        ['a','b','v','g','d','e','zh','z','i','y','k','l','m','n','o','p','r','s','t','u','f','h','ts','ch','sh','sch','y','e','yu','ya']))
    return ''.join(letters.get(c,c) for c in norm(value).replace('ь','').replace('ъ',''))

def search_queries(item, mode):
    artist, title = item['artist'], item['title']
    queries = [artist + ' ' + title]
    if mode != 'safe':
        queries += [searchable(artist) + ' ' + searchable(title), title + ' ' + artist]
    if mode == 'wide':
        primary = re.split(r'\s+(?:feat\.?|ft\.?|featuring|&|и)\s+|[,;]',artist,flags=re.I)[0].strip()
        queries += [primary + ' ' + searchable(title), transliterate(artist + ' ' + title), title]
    seen=set(); result=[]
    for query in queries:
        key=norm(query)
        if key and key not in seen:seen.add(key);result.append(query)
    return result[:6]

def _similar(left, right):
    left, right = searchable(left), searchable(right)
    if not left or not right: return 0.0
    if left == right: return 1.0
    if transliterate(left) == transliterate(right): return .97
    score = difflib.SequenceMatcher(None, left, right, autojunk=False).ratio()
    # Distinguish a slightly different spelling from a completely different song.
    x, y = set(left.split()), set(right.split())
    if x and y:
        score = max(score, len(x & y) / max(len(x), len(y)))
    return score

def _candidate_parts(candidate):
    raw_title = str(candidate.get('title', ''))
    title = norm(raw_title)
    uploader = norm(candidate.get('artist', ''))
    if not title: return []
    parts = [(title, uploader, False)]
    # Split *before* norm(): norm removes punctuation and separators.
    for sep in (' - ', ' – ', ' — ', ' | ', ' : '):
        if sep in raw_title:
            first, second = raw_title.split(sep, 1)
            if norm(first) and norm(second):
                parts.extend(((norm(second), norm(first), True), (norm(first), norm(second), True)))
    return parts

def select_match(source, candidates, mode='balanced'):
    a, b = norm(source.get('title', '')), norm(source.get('artist', ''))
    if not a or not b: return None, 'Недостаточно данных для проверки'
    ranked = {}
    limits = {'safe': (.95, .90, .93), 'balanced': (.89, .85, .89), 'wide': (.85, .80, .85)}
    min_title, min_artist, min_score = limits.get(mode, limits['balanced'])
    for candidate in candidates:
        if not isinstance(candidate, dict) or not re.fullmatch(r'[A-Za-z0-9_-]{1,100}', str(candidate.get('id', ''))): continue
        duration = candidate.get('duration')
        if source.get('duration') and isinstance(duration, (int, float)) and duration > 0:
            if abs(source['duration'] - duration) > max(14, source['duration'] * .13): continue
        for title, artist, composite in _candidate_parts(candidate):
            if (set(a.split()) & VERSIONS) != (set(title.split()) & VERSIONS): continue
            ts, ars = _similar(a, title), _similar(b, artist)
            score = .65 * ts + .35 * ars
            if ts < min_title or ars < min_artist or score < min_score: continue
            # A composite title explicitly identifies the real performer.
            # Uploader names should not be used as independent evidence.
            key = str(candidate['id'])
            if key not in ranked or ranked[key][0] < score: ranked[key] = (score, candidate)
    ranked = sorted(ranked.values(), key=lambda v: -v[0])
    if not ranked: return None, 'Не найдено надёжного совпадения'
    if len(ranked) > 1 and ranked[0][0] < .999 and ranked[0][0] - ranked[1][0] < .025:
        return None, 'Несколько похожих версий — нужна ручная проверка'
    return ranked[0][1], ''

class Jobs:
    def __init__(self,path):
        self.path=str(path);self.tasks=set()
        with self.db() as db:
            db.execute('''CREATE TABLE IF NOT EXISTS music_import_jobs(
                id TEXT PRIMARY KEY,user_id TEXT NOT NULL,state TEXT NOT NULL,updated REAL NOT NULL,data TEXT NOT NULL)''')
    @contextmanager
    def db(self):
        db=sqlite3.connect(self.path,timeout=10);db.row_factory=sqlite3.Row
        try:
            with db:yield db
        finally:db.close()
    def get(self,key,user):
        with self.db() as db:r=db.execute('SELECT * FROM music_import_jobs WHERE id=? AND user_id=?',(key,user)).fetchone()
        if not r:raise HTTPException(404,'Перенос не найден')
        data=json.loads(r['data']);data.update(id=r['id'],state=r['state'])
        if r['state'] in ACTIVE and r['updated']<time.time()-120:
            data['state']='error';data['message']='Перенос прерван. Можно повторить поиск или сохранить уже найденные треки.';self.put(key,user,data)
        return data
    def put(self,key,user,data):
        with self.db() as db:
            db.execute('BEGIN IMMEDIATE')
            current=db.execute('SELECT state,data FROM music_import_jobs WHERE id=? AND user_id=?',(key,user)).fetchone()
            if current and current['state']=='cancelled' and data['state']!='cancelled':
                data={**data,'state':'cancelled','message':json.loads(current['data'])['message']}
            db.execute('UPDATE music_import_jobs SET state=?,updated=?,data=? WHERE id=? AND user_id=?',(data['state'],time.time(),json.dumps(data,ensure_ascii=False),key,user))
    def create(self,user,provider):
        with self.db() as db:
            db.execute('BEGIN IMMEDIATE')
            db.execute("DELETE FROM music_import_jobs WHERE updated<? AND state NOT IN ('reading','matching','saving')",(time.time()-7*86400,))
            live=db.execute("SELECT user_id FROM music_import_jobs WHERE state IN ('reading','matching','saving') AND updated>?",(time.time()-120,)).fetchall()
            if any(r[0]==user for r in live):raise HTTPException(409,'У вас уже выполняется перенос. Откройте его из списка ниже')
            if len(live)>=2:raise HTTPException(429,'Сейчас выполняются другие переносы. Повторите через минуту')
            key=uuid.uuid4().hex
            data={'id':key,'state':'reading','provider':provider,'name':'Перенос музыки','message':'Читаем список треков','total':0,'progress':0,'matched':0,'saved':0,'duplicates':0,'items':[],'warning':'','playlist_id':None}
            db.execute('INSERT INTO music_import_jobs VALUES(?,?,?,?,?)',(key,user,'reading',time.time(),json.dumps(data)))
        return data
    def launch(self,coroutine):
        task=asyncio.create_task(coroutine);self.tasks.add(task);task.add_done_callback(self.tasks.discard)
    def cancelled(self,key,user):return self.get(key,user)['state']=='cancelled'

async def host(client,method,path,**kwargs):
    response=await asyncio.wait_for(client.request(method,path,**kwargs),35)
    if not response.is_success:
        if response.status_code in (401,403):raise SourceError('Сессия завершилась. Войдите снова и повторите перенос')
        raise SourceError('Сервер не выполнил операцию. Уже сохранённые треки остаются в плейлисте')
    return response.json()

def install(app,identity,csrf,path):
    jobs=Jobs(path)
    def who(request,mutate=False):
        user=identity(request)
        if not user:raise HTTPException(401,'Войдите в Nightwell Music')
        if mutate and not csrf(request):raise HTTPException(403,'Неверный CSRF токен')
        return str(user)
    def client(request):
        # Only same-app API calls carry the Nightwell session. Provider fetches never do.
        headers={key:value for key,value in request.headers.items() if key.lower() in ('cookie','x-csrf-token','origin','user-agent')}
        return httpx.AsyncClient(transport=httpx.ASGITransport(app=app),base_url=str(request.base_url),headers=headers,follow_redirects=False)
    async def read_and_match(key,user,body,request):
        data=jobs.get(key,user)
        try:
            source=await asyncio.to_thread(read_source,body)
            mode=body.get('mode','balanced')
            if jobs.cancelled(key,user):return
            data.update({k:v for k,v in source.items() if k!='tracks'})
            data.update(state='matching',total=len(source['tracks']),items=[{**t,'track_id':None,'reason':'Ещё не проверен'} for t in source['tracks']],message='Ищем треки в Nightwell')
            jobs.put(key,user,data)
            async with client(request) as api:
                catalog=(await host(api,'GET','/api/tracks')).get('tracks',[])
                if not isinstance(catalog,list):raise SourceError('Не удалось прочитать каталог Nightwell')
                exact,artists={},{}
                for candidate in catalog:
                    if not isinstance(candidate,dict):continue
                    title,artist=norm(candidate.get('title','')),norm(candidate.get('artist',''))
                    exact.setdefault((title,artist),[]).append(candidate)
                    group=artists.setdefault(artist,[])
                    if len(group)<1000:group.append(candidate)
                # Single-flight remote search and bounded cache protect music playback.
                gate=asyncio.Semaphore(1)
                query_cache={}
                last_search=[0.0]
                async def cached_search(query):
                    cache_key=norm(query)
                    cached=query_cache.get(cache_key)
                    if cached and (not cached.get('search_pending') or time.monotonic()-cached.get('_at',0)<1.5):return cached
                    await asyncio.sleep(max(0,0.45-(time.monotonic()-last_search[0])))
                    last_search[0]=time.monotonic()
                    response=await host(api,'GET','/api/tracks',params={'q':query})
                    response['_at']=time.monotonic()
                    query_cache[cache_key]=response
                    return response
                async def match(index,item):
                    async with gate:
                        if jobs.cancelled(key,user):return
                        local=exact.get((norm(item["title"]),norm(item["artist"])),artists.get(norm(item["artist"]),[]))
                        found,reason=await asyncio.to_thread(select_match,item,local,mode)
                        if found is None:
                            # Additional queries only when the stricter query found no good match.
                            queries=search_queries(item,mode)
                            seen_queries=set()
                            pending=False
                            for query in queries:
                                if norm(query) in seen_queries: continue
                                seen_queries.add(norm(query))
                                if jobs.cancelled(key,user):return
                                for attempt in range(6 if mode == 'wide' else 4):
                                    jobs.put(key,user,data)
                                    result=await cached_search(query)
                                    candidates=result.get('tracks',[])
                                    if not isinstance(candidates,list):raise SourceError('Поиск вернул неверный ответ')
                                    found,reason=await asyncio.to_thread(select_match,item,candidates[:200],mode)
                                    pending=bool(result.get('search_pending'))
                                    if found or not pending:break
                                    await asyncio.sleep(min(3,max(1,float(result.get('search_retry_after',1.5)))))
                                if found:break
                            if found is None and pending:reason='Поиск ещё не завершён. Можно повторить позже'
                        if jobs.cancelled(key,user):return
                        item['track_id']=str(found['id']) if found else None;item['reason']=reason
                        if found:item['found_title']=str(found.get('title',''));item['found_artist']=str(found.get('artist',''))
                        data['progress']+=1;data['matched']+=int(found is not None)
                        data['message']='Проверено '+str(data['progress'])+' из '+str(data['total'])
                # Batches keep memory and the host's search load bounded.
                for start in range(0,len(data['items']),1):
                    results=await asyncio.gather(*(match(i,data['items'][i]) for i in range(start,min(start+1,len(data['items'])))),return_exceptions=True)
                    jobs.put(key,user,data)
                    error=next((r for r in results if isinstance(r,BaseException)),None)
                    if error:raise error
                    if jobs.cancelled(key,user):return
            data.update(state='ready',message='Найдено '+str(data['matched'])+' из '+str(data['total'])+'. Проверьте результат перед сохранением.')
            jobs.put(key,user,data)
        except asyncio.CancelledError:raise
        except Exception as error:
            if not jobs.cancelled(key,user):
                data.update(state='error',message=str(error) if isinstance(error,SourceError) else 'Не удалось завершить перенос. Проверьте подключение и повторите.')
                jobs.put(key,user,data)
    async def save(key,user,request):
        data=jobs.get(key,user)
        try:
            async with client(request) as api:
                if not data.get('playlist_id'):
                    result=await host(api,'POST','/api/playlists',json={'name':data['name']})
                    playlist=result.get('playlist',result)
                    pid=str(playlist.get('id','')) if isinstance(playlist,dict) else ''
                    if not re.fullmatch(r'[A-Za-z0-9_-]{1,100}',pid):raise SourceError('Сервер не вернул созданный плейлист')
                    data['playlist_id']=pid;jobs.put(key,user,data)
                done=set(data.get('saved_ids',[]))
                for item in data['items']:
                    tid=item.get('track_id')
                    if not tid or tid in done:continue
                    if jobs.cancelled(key,user):return
                    await host(api,'POST','/api/playlists/'+data['playlist_id']+'/tracks/'+tid,json={})
                    done.add(tid);data['saved_ids']=list(done);data['saved']=len(done);data['message']='Добавлено '+str(len(done))+' треков';jobs.put(key,user,data)
                data.update(state='done',message='Готово. В плейлисте '+str(data['saved'])+' треков. Не найдено: '+str(data['total']-data['matched'])+'.')
                jobs.put(key,user,data)
        except asyncio.CancelledError:raise
        except Exception as error:
            if not jobs.cancelled(key,user):
                data.update(state='error',message=str(error) if isinstance(error,SourceError) else 'Сохранение прервано. Можно повторить, уже добавленные треки сохранятся.')
                jobs.put(key,user,data)
    def view(data,summary=False):
        if summary or data['state'] in ACTIVE:return {**data,'items':[]}
        return data
    @app.get('/api/imports')
    def listing(request:Request):
        user=who(request)
        with jobs.db() as db:keys=[r[0] for r in db.execute('SELECT id FROM music_import_jobs WHERE user_id=? ORDER BY updated DESC LIMIT 10',(user,))]
        return {'jobs':[view(jobs.get(key,user),True) for key in keys]}
    @app.post('/api/imports')
    async def create(request:Request):
        user=who(request,True)
        parts=[];size=0
        async for chunk in request.stream():
            size+=len(chunk)
            if size>MAX_BYTES*6+12000:raise HTTPException(413,'Список должен быть не больше 1 МБ')
            parts.append(chunk)
        raw=b''.join(parts)
        try:body=json.loads(raw)
        except (ValueError,UnicodeDecodeError):raise HTTPException(422,'Неверный формат списка')
        if not isinstance(body,dict) or set(body)-{'provider','name','url','text','mode'} or not isinstance(body.get('provider'),str) or body.get('provider') not in PROVIDERS:raise HTTPException(422,'Проверьте источник переноса')
        if body.get('mode','balanced') not in ('safe','balanced','wide'):raise HTTPException(422,'Неизвестный режим поиска')
        if not isinstance(body.get('text',''),str) or not isinstance(body.get('url',''),str):raise HTTPException(422,'Нужна ссылка или текстовый список')
        if len(body.get('text','').encode('utf-8'))>MAX_BYTES:raise HTTPException(413,'Список должен быть не больше 1 МБ')
        data=jobs.create(user,body['provider']);jobs.launch(read_and_match(data['id'],user,body,request));return data
    @app.get('/api/imports/{key}')
    def status(key:str,request:Request):return view(jobs.get(key,who(request)))
    @app.post('/api/imports/{key}/cancel')
    def cancel(key:str,request:Request):
        user=who(request,True);data=jobs.get(key,user)
        if data['state'] not in ('done','cancelled'):
            data.update(state='cancelled',message='Перенос остановлен. Уже сохранённые треки остаются в плейлисте.');jobs.put(key,user,data)
        return data
    @app.post('/api/imports/{key}/commit')
    async def commit(key:str,request:Request):
        user=who(request,True);data=jobs.get(key,user)
        if data['state'] in ('done','saving'):return view(data)
        if data['state'] not in ('ready','error') or not data.get('matched'):raise HTTPException(409,'Сначала дождитесь поиска совпадений')
        data.update(state='saving',message='Создаём плейлист')
        with jobs.db() as db:
            changed=db.execute("UPDATE music_import_jobs SET state='saving',updated=?,data=? WHERE id=? AND user_id=? AND state IN ('ready','error')",(time.time(),json.dumps(data,ensure_ascii=False),key,user)).rowcount
        if changed:jobs.launch(save(key,user,request))
        return view(jobs.get(key,user))
    app.state.music_import_jobs=jobs
    return jobs
