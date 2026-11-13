"""Versioned, fail-closed patch for the supplied Nightwell search handler.

Only known search, recommendation and discovery-scheduler functions change.
Compatible optional source-policy modules are updated with backups as well.
The rest of app.py is preserved byte for byte. No original server configuration
or credentials are bundled in this package.
"""
from __future__ import annotations

import argparse
import ast
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys


MARKER = "# NIGHTWELL_SEARCH_RECALL_V2_SC_PRIMARY"
HELPER = "nightwell_search_recall.py"
OPTIONAL_MODULE = "full_version_search.py"
POLICY_MODULES = {
    "adaptive_wave.py": ("adaptive-wave/adaptive_wave.py", {
        "a479ea57e2268e126b6ff79eb0034d7a0396026338b2014f7b463d9898ae64d1",
        "2c19c64e61d778cad03c93980b3125e04ace4bc5d542833909a42455f34c0666"}),
    "wave_ranker.py": ("adaptive-wave/wave_ranker.py", {
        "2bfd16804d79bb6e56d49642100fac43e6dd0569c4b6c4c9d34e852ff28b8b68"}),
    "audius_catalog.py": ("audius/audius_catalog.py", {
        "d735a2921260a94999cda1a8f4e668afd3b5806d834cf8b4ff445bf74099910d"}),
}
EXPECTED_TRACKS = "74b159f773de008717a8c4a8c7a6e535a59471d2b2b241d1e834e6a3ce03a50b"
EXPECTED_DISCOVERY = "d5765481c83323c4f324da8dcd0aaa5ef63d6cc933852f36876b53b239b8da6e"
EXPECTED_RECOMMENDATIONS = "a802283758b80306d0c81102d7e373f2136dac2275c98b8e05ceef109c65e2f4"
PATCHED_RECOMMENDATIONS = "c6800fadcb056a29ef0cbc4597f43183478d92ebe94837639d4bf29acd8cc7cd"
EXPECTED_SCHEDULER = "a7b9324f0f1c75e04b749df4181b5757043b8b40e1cf2e648f37c7a73aea0907"
DISCOVERY_RETURN = "        return set(ids),'' if set(ids)-exclude_ids else 'SoundCloud: ищем следующую подборку треков'"
DISCOVERY_PATCHED = """        # NIGHTWELL_SEARCH_RECALL_V1: retain upstream order without changing wave sets.
        if search and search_state is not None:
            search_state['ranked_ids'] = list(dict.fromkeys(ids))
""" + DISCOVERY_RETURN

PREVIOUS_ROUTE = '''async def tracks(request:Request,q:str='',provider:str=''):
    # NIGHTWELL_SEARCH_RECALL_V1
    from nightwell_search_recall import rank_track
    q=q.strip().casefold()[:200];needle=search_text(q);tokens=set(needle.split())
    provider=provider.strip().casefold()
    if provider not in ('','audius','soundcloud'):fail(400,'Неизвестный музыкальный источник')
    found=set();message='';search_state={};account=session(request,False)
    audius_message='';audius_found=set();upstream_ranks={}
    if q and account and provider!='soundcloud' and audius_provider.configured():
        try:
            discovered=await asyncio.wait_for(
                asyncio.to_thread(audius_provider.search_tracks,q[:120],25),timeout=4.5)
            if discovered:
                await run_in_threadpool(audius_bridge.store_tracks,core.db,discovered)
                for position,item in enumerate(discovered):
                    if isinstance(item,dict) and item.get('id'):
                        ident=str(item['id']);audius_found.add(ident)
                        upstream_ranks.setdefault(ident,position)
        except asyncio.TimeoutError:
            audius_message='Audius отвечает слишком долго, проверяем другие источники'
        except audius_provider.AudiusUnavailable as error:
            audius_message=str(error)
        except Exception:
            audius_message='Audius временно недоступен'

    def relevant(row):
        text=search_text(row['title']+' '+row['artist']+' '+row['album'])
        words=set(text.split())
        return bool(needle and (needle in text or tokens <= words))
    def source(row):
        return json.loads(row['rights']).get('source') or 'local'
    # A same-title track from Audius must not suppress SoundCloud originals.
    # Explicit source selection continues to query only that source.
    if q and account and provider!='audius' and sc.configured():
        queries=list(dict.fromkeys([q,needle]))
        found,message=await discover_soundcloud(account,[v for v in queries if v],search=True,search_state=search_state)
        for position,ident in enumerate(search_state.get('ranked_ids',[])):
            upstream_ranks.setdefault(str(ident),position)
    with core.db() as c:rows=c.execute('SELECT * FROM tracks ORDER BY title').fetchall()
    matched=[r for r in rows if account and json.loads(r['rights']).get('status')=='approved'
             and (not q or r['id'] in found or relevant(r))
             and (not provider or not q or source(r)==provider)]
    if q:
        matched.sort(key=lambda row:rank_track(row,q,upstream_ranks))
    return {'tracks':[public(r) for r in matched],
            'soundcloud_message':'' if search_state.get('pending') else message,
            'search_pending':search_state.get('pending',False),
            'search_checked':search_state.get('checked',0),
            'search_total':search_state.get('total',0),
            'search_retry_after':search_state.get('retry_after',2),
            'search_message':search_state.get('message',''),
            'audius_message':audius_message}'''

ROUTE = '''async def tracks(request:Request,q:str='',provider:str=''):
    # NIGHTWELL_SEARCH_RECALL_V2_SC_PRIMARY
    from nightwell_search_recall import rank_track, relevant_track
    q=q.strip().casefold()[:200];needle=search_text(q);tokens=set(needle.split())
    provider=provider.strip().casefold()
    if provider not in ('','audius','soundcloud'):fail(400,'Неизвестный музыкальный источник')
    found=set();message='';search_state={};account=session(request,False)
    audius_message='';upstream_ranks={};sc_attempted=False
    def source(row):
        return json.loads(row['rights']).get('source') or 'local'
    def load_rows():
        with core.db() as c:return c.execute('SELECT * FROM tracks ORDER BY title').fetchall()
    if q and account and provider!='audius' and sc.configured():
        sc_attempted=True
        queries=list(dict.fromkeys([q,needle]))
        try:
            found,message=await discover_soundcloud(account,[v for v in queries if v],search=True,search_state=search_state)
        except sc.SoundCloudError as error:
            message=str(error);search_state['pending']=False
        for position,ident in enumerate(search_state.get('ranked_ids',[])):
            upstream_ranks.setdefault(str(ident),position)
    rows=load_rows()
    soundcloud_relevant=[r for r in rows if json.loads(r['rights']).get('status')=='approved'
        and source(r)=='soundcloud' and relevant_track(r,q)] if q and account else []
    # A pending primary search is not an empty completed search. Clients poll
    # it; an explicit Audius request remains available as a bounded fallback.
    fallback_allowed=not search_state.get('pending',False) and (not sc_attempted or not soundcloud_relevant)
    use_audius=provider=='audius' or (not provider and fallback_allowed)
    if q and account and use_audius and audius_provider.configured():
        try:
            discovered=await asyncio.wait_for(
                asyncio.to_thread(audius_provider.search_tracks,q[:120],25),timeout=4.5)
            if discovered:
                await run_in_threadpool(audius_bridge.store_tracks,core.db,discovered)
                for position,item in enumerate(discovered):
                    if isinstance(item,dict) and item.get('id'):
                        upstream_ranks.setdefault(str(item['id']),position)
        except asyncio.TimeoutError:
            audius_message='Audius отвечает слишком долго'
        except audius_provider.AudiusUnavailable as error:
            audius_message=str(error)
        except Exception:
            audius_message='Audius временно недоступен'
        rows=load_rows()
    matched=[r for r in rows if account and json.loads(r['rights']).get('status')=='approved'
             and (not q or r['id'] in found or relevant_track(r,q))
             and (not provider or not q or source(r)==provider)
             and (not q or provider or use_audius or source(r)!='audius')]
    if q:
        matched.sort(key=lambda row:rank_track(row,q,upstream_ranks))
    return {'tracks':[public(r) for r in matched],
            'soundcloud_message':'' if search_state.get('pending') else message,
            'search_pending':search_state.get('pending',False),
            'search_checked':search_state.get('checked',0),
            'search_total':search_state.get('total',0),
            'search_retry_after':search_state.get('retry_after',2),
            'search_message':search_state.get('message',''),
            'audius_message':audius_message}'''

RECOMMENDATION_DISCOVERY = '''    discovery_ids=set();excluded_set=set(excluded)
    heard={e['track_id'] for e in events if e['listened']>=10}
    if settings['character']=='discover':heard.update(playlist_member_ids)
    hidden_ids,hidden_artists=sync_preferences(s['user_id']) if settings['character']!='favorites' else (set(),set())
    def permitted(row):
        return (row['id'] not in excluded_set and eligible(row,settings,favorites,heard)
                and row['id'] not in hidden_ids and normalize_artist(row['artist']) not in hidden_artists)
    def refresh_rows():
        with core.db() as c:incoming=c.execute('SELECT * FROM tracks').fetchall()
        return [r for r in incoming if json.loads(r['rights']).get('status')=='approved']
    target=20 if wave else 60
    sc_message="SoundCloud не настроен: задай NW_SC_CLIENT_ID и NW_SC_CLIENT_SECRET в окне запуска сервера"
    if settings['character']!='favorites':
        seeds=[a for a,v in sorted(artist_scores.items(),key=lambda pair:pair[1],reverse=True) if v>0][:2]
        if not seeds:seeds=[r['artist'] for r in rows[:2]] or ['русский поп','русский хип хоп']
        seeds=preference_seeds(seeds,settings)
        # SoundCloud is primary for both recommendations and My Wave.
        if sc.configured():
            soundcloud_count=sum(1 for r in rows if json.loads(r['rights']).get('source')=='soundcloud' and permitted(r))
            if mix and soundcloud_count>=target:
                with core.db() as c:cached=c.execute('SELECT track_ids FROM soundcloud_discovery WHERE user_id=?',(s['user_id'],)).fetchone()
                discovery_ids.update(json.loads(cached['track_ids']) if cached else [])
                sc_message=''
                schedule_discovery(s,seeds,excluded_set)
            else:
                try:
                    sc_ids,sc_message=await discover_soundcloud(s,seeds,advance=wave or bool(mix),exclude_ids=excluded_set)
                    discovery_ids.update(sc_ids)
                except sc.SoundCloudError as error:sc_message=str(error)
            rows=refresh_rows()
        soundcloud_count=sum(1 for r in rows if json.loads(r['rights']).get('source')=='soundcloud' and permitted(r))
        # Query Audius only when the primary source cannot fill this response.
        # Count after exclusion, mood/language, history and hidden-artist filters.
        if soundcloud_count<target and audius_provider.configured():
            try:
                for seed_name in list(dict.fromkeys(seeds))[:2]:
                    items=await asyncio.wait_for(asyncio.to_thread(audius_provider.search_tracks,seed_name,25),timeout=3.5)
                    if items:
                        await run_in_threadpool(audius_bridge.store_tracks,core.db,items)
                        discovery_ids.update(str(item['id']) for item in items if isinstance(item,dict) and item.get('id'))
                    rows=refresh_rows()
                    if sum(1 for r in rows if json.loads(r['rights']).get('source') in ('soundcloud','audius') and permitted(r))>=target:break
            except (audius_provider.AudiusUnavailable,asyncio.TimeoutError):
                pass
            except Exception as error:
                print('[Audius wave] fallback search failed:',type(error).__name__,flush=True)
            schedule_audius_wave()
            rows=refresh_rows()
'''


def patch_recommendations(contents: str) -> str:
    if MARKER in contents:
        if digest(contents.encode()) != PATCHED_RECOMMENDATIONS:
            raise ValueError("Установленный патч подборки изменён")
        return contents
    if digest(contents.encode()) != EXPECTED_RECOMMENDATIONS:
        raise ValueError("Версия обработчика подборок отличается от проверенной")
    start=contents.index('    discovery_ids=set();excluded_set=set(excluded)')
    end=contents.index('    personalized=bool(',start)
    updated=contents[:start]+RECOMMENDATION_DISCOVERY+contents[end:]
    old_filters="""    heard={e['track_id'] for e in events if e['listened']>=10}
    # 'Открытия' must never play a track already saved in ANY user's playlist.
    if settings['character']=='discover':
        heard.update(playlist_member_ids)
    rows=[r for r in rows if eligible(r,settings,favorites,heard)]
    if settings['character']!='favorites':
        hidden_ids,hidden_artists=sync_preferences(s['user_id'])
        rows=[r for r in rows if r['id'] not in hidden_ids and normalize_artist(r['artist']) not in hidden_artists]
"""
    if updated.count(old_filters)!=1:raise ValueError("Не найдены проверенные фильтры подборки")
    updated=updated.replace(old_filters,'    rows=[r for r in rows if permitted(r)]\n',1)
    updated=updated.replace("# Audius comes first; other permitted sources remain available as fallback.","# SoundCloud comes first; Audius only fills the remaining shortage.",1)
    updated=updated.replace("return {'audius':0,'soundcloud':1}.get(provider,2)","return {'soundcloud':0,'audius':1}.get(provider,2)",1)
    selection="        choice=next((r for r in candidates if not artists(r['artist'])&last_artists),candidates[0])"
    if updated.count(selection)!=1:raise ValueError("Не найден проверенный выбор трека")
    updated=updated.replace(selection,"        candidates=[r for r in candidates if provider_priority(r)==provider_priority(ranked[0])]\n"+selection,1)
    updated=updated.replace("    s=session(request,False)","    "+MARKER+"\n    s=session(request,False)",1)
    ast.parse(updated)
    return updated


def patch_scheduler(contents: str) -> str:
    """Expose the existing bounded SC task so fallback can await its outcome."""
    marker='    # NIGHTWELL_SC_PRIMARY_SCHEDULER_V2'
    old_guard="    if old and not old.done() or len(SC_BACKGROUND)>=16:return"
    new_guard="    if old and not old.done():return old\n    if len(SC_BACKGROUND)>=16:return"
    callback="    job.add_done_callback(finished)"
    if marker in contents:
        original=contents.replace(marker+'\n','',1).replace(new_guard,old_guard,1).replace(callback+'\n    return job',callback,1)
        if digest(original.encode())!=EXPECTED_SCHEDULER:
            raise ValueError("Установленный планировщик SoundCloud изменён")
        return contents
    if digest(contents.encode())!=EXPECTED_SCHEDULER:
        raise ValueError("Версия планировщика SoundCloud отличается от проверенной")
    updated=contents.replace('\n','\n'+marker+'\n',1).replace(old_guard,new_guard,1)
    return updated.replace(callback,callback+'\n    return job',1)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def functions(contents: str) -> dict:
    return {node.name: node for node in ast.parse(contents).body
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))}


def patch(contents: str) -> str:
    nodes = functions(contents)
    if not all(name in nodes for name in ("tracks", "discover_soundcloud", "recommendations", "schedule_discovery")):
        raise ValueError("Не найдены совместимые обработчики поиска и подборки; файлы не изменены")
    route = ast.get_source_segment(contents, nodes["tracks"])
    discovery = ast.get_source_segment(contents, nodes["discover_soundcloud"])
    recommendations = ast.get_source_segment(contents, nodes["recommendations"])
    scheduler = ast.get_source_segment(contents, nodes["schedule_discovery"])
    normalized_route = route.replace("\r\n", "\n")
    normalized_discovery = discovery.replace("\r\n", "\n")
    normalized_recommendations = recommendations.replace("\r\n", "\n")
    if normalized_route not in (ROUTE,PREVIOUS_ROUTE) and digest(normalized_route.encode()) != EXPECTED_TRACKS:
        raise ValueError("Версия поиска в app.py отличается от проверенной; файлы не изменены")
    original_discovery = normalized_discovery.replace(DISCOVERY_PATCHED,DISCOVERY_RETURN,1)
    if digest(original_discovery.encode()) != EXPECTED_DISCOVERY:
        raise ValueError("Версия SoundCloud в app.py отличается от проверенной; файлы не изменены")
    if discovery.count(DISCOVERY_RETURN) != 1:
        raise ValueError("Не найдена однозначная точка сохранения порядка SoundCloud")
    route_ending = "\r\n" if "\r\n" in route else "\n"
    discovery_ending = "\r\n" if "\r\n" in discovery else "\n"
    patched_discovery = discovery if DISCOVERY_PATCHED in normalized_discovery else discovery.replace(DISCOVERY_RETURN, DISCOVERY_PATCHED.replace("\n", discovery_ending))
    recommendations_ending = "\r\n" if "\r\n" in recommendations else "\n"
    patched_recommendations = patch_recommendations(normalized_recommendations).replace("\n",recommendations_ending)
    scheduler_ending = "\r\n" if "\r\n" in scheduler else "\n"
    patched_scheduler = patch_scheduler(scheduler.replace("\r\n", "\n")).replace("\n",scheduler_ending)
    replacements = [(route, ROUTE.replace("\n", route_ending)),
                    (discovery, patched_discovery), (recommendations,patched_recommendations), (scheduler,patched_scheduler)]
    updated = contents
    for old, new in replacements:
        if updated.count(old) != 1:
            raise ValueError("Неоднозначный обработчик; файлы не изменены")
        updated = updated.replace(old, new, 1)
    ast.parse(updated)
    return updated


def prepare(target: Path) -> dict[str, bytes]:
    app = target / "app.py"
    if not app.is_file() or app.is_symlink():
        raise ValueError("Нужна папка сервера с обычным файлом app.py")
    raw = app.read_bytes()
    # utf-8-sig reading normally discards BOM; retain it exactly if present.
    bom = b"\xef\xbb\xbf" if raw.startswith(b"\xef\xbb\xbf") else b""
    contents = raw[len(bom):].decode("utf-8")
    updated = patch(contents)
    helper = Path(__file__).with_name(HELPER).read_bytes()
    ast.parse(helper.decode("utf-8"))
    if (target / HELPER).is_symlink():
        raise ValueError("Нельзя перезаписывать символическую ссылку " + HELPER)
    desired = {"app.py": bom + updated.encode("utf-8"), HELPER: helper}
    full_version = target / OPTIONAL_MODULE
    if full_version.is_symlink():
        raise ValueError("Нельзя перезаписывать символическую ссылку " + OPTIONAL_MODULE)
    if full_version.is_file():
        from full_version_patch import patch as patch_full_version
        desired[OPTIONAL_MODULE] = patch_full_version(full_version.read_bytes().decode("utf-8")).encode("utf-8")
    for name,(relative,known) in POLICY_MODULES.items():
        destination=target/name
        if destination.is_symlink():raise ValueError("Нельзя перезаписывать символическую ссылку "+name)
        if not destination.is_file() and not (name=='wave_ranker.py' and (target/'adaptive_wave.py').is_file()):continue
        source=Path(__file__).resolve().parent.parent/relative
        text=source.read_text(encoding='utf-8-sig').replace('\r\n','\n')
        ast.parse(text)
        previous=destination.read_bytes() if destination.is_file() else b''
        normalized=previous.decode('utf-8-sig').replace('\r\n','\n')
        if previous and digest(normalized.encode()) not in known|{digest(text.encode())}:
            raise ValueError("Версия "+name+" отличается от проверенной; файлы не изменены")
        ending='\r\n' if b'\r\n' in previous else '\n'
        prefix=b'\xef\xbb\xbf' if previous.startswith(b'\xef\xbb\xbf') else b''
        desired[name]=prefix+text.replace('\n',ending).encode('utf-8')
    return desired


def install(target) -> Path | None:
    target = Path(target).expanduser().resolve()
    desired = prepare(target)
    changed = {name: data for name, data in desired.items()
               if not (target / name).is_file() or (target / name).read_bytes() != data}
    if not changed:
        return None
    backup = target / "backups" / ("nw-search-recall-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S-%f"))
    backup.mkdir(parents=True, exist_ok=False)
    manifest = {"target": str(target), "files": []}
    for name, data in changed.items():
        old = target / name
        previous = old.read_bytes() if old.is_file() else None
        if previous is not None:
            (backup / name).write_bytes(previous)
        manifest["files"].append({"name": name, "previous": previous is not None, "installed_sha256": digest(data)})
    (backup / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
    written = []
    try:
        for name, data in changed.items():
            temporary = target / (name + ".nw-search-new")
            temporary.write_bytes(data)
            os.replace(temporary, target / name)
            written.append(name)
    except BaseException:
        for name in reversed(written):
            previous = backup / name
            if previous.is_file():
                shutil.copy2(previous, target / name)
            else:
                (target / name).unlink(missing_ok=True)
        raise
    finally:
        for name in changed:
            (target / (name + ".nw-search-new")).unlink(missing_ok=True)
    return backup


def rollback(backup):
    backup = Path(backup).expanduser().resolve()
    manifest = json.loads((backup / "manifest.json").read_text(encoding="utf-8"))
    target = Path(manifest["target"]).resolve()
    for item in manifest["files"]:
        name = item["name"]
        if name not in ("app.py", HELPER, OPTIONAL_MODULE, *POLICY_MODULES):
            raise ValueError("Неожиданный файл в резервной копии")
        current = target / name
        if current.is_symlink() or not current.is_file() or digest(current.read_bytes()) != item["installed_sha256"]:
            raise ValueError("Файл изменён после установки: " + name)
        if item["previous"] and not (backup / name).is_file():
            raise ValueError("Отсутствует исходная резервная копия: " + name)
    for item in manifest["files"]:
        name = item["name"]
        if item["previous"]:
            shutil.copy2(backup / name, target / name)
        else:
            (target / name).unlink()
    return target


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--target", type=Path)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--rollback", type=Path)
    args = parser.parse_args(argv)
    try:
        if args.rollback:
            print("Восстановлено:", rollback(args.rollback))
        elif args.target:
            if args.check:
                target = args.target.expanduser().resolve()
                desired = prepare(target)
                print(json.dumps({"target": str(target), "files": [
                    {"name": name, "changed": not (target / name).is_file() or (target / name).read_bytes() != data}
                    for name, data in desired.items()]}, ensure_ascii=False, indent=2))
            else:
                saved = install(args.target)
                print("Установлено. Резервная копия:" if saved else "Изменения уже установлены.", saved or "")
                print("Перезапусти сервер своим прежним способом.")
        else:
            parser.error("Укажи --target с папкой сервера или --rollback с резервной копией")
        return 0
    except (OSError, ValueError, SyntaxError) as error:
        print("Изменения остановлены: " + str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
