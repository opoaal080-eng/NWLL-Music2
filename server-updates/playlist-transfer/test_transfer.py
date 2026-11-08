import asyncio
import tempfile
import unittest
from pathlib import Path
import httpx
from fastapi import FastAPI, Request
from music_import import install, select_match, search_queries
from music_import_sources import parse_text

class MatchingTests(unittest.TestCase):
    def test_decorations_and_transliteration(self):
        source={'title':'Звезда','artist':'Кино'}
        hit={'id':'a','title':'Кино - Звезда (Official Audio)','artist':'Uploader'}
        self.assertEqual(select_match(source,[hit],'wide')[0]['id'],'a')
        self.assertEqual(select_match(source,[{'id':'b','title':'Zvezda','artist':'Kino'}],'wide')[0]['id'],'b')
    def test_wrong_versions_artists_and_duration_rejected(self):
        src={'title':'Song','artist':'Artist','duration':180}
        for candidate in [dict(id='a',title='Song remix',artist='Artist',duration=180),
                          dict(id='a',title='Song',artist='Other',duration=180),
                          dict(id='a',title='Song',artist='Artist',duration=40)]:
            self.assertIsNone(select_match(src,[candidate],'wide')[0])
    def test_queries_expand_and_deduplicate(self):
        from music_import_sources import norm
        q=search_queries({'artist':'Кино','title':'Звезда'},'wide')
        self.assertEqual(len(q),len(set(map(norm,q))))
        self.assertIn('Звезда',q);self.assertIn('kino zvezda',q)
        self.assertEqual(len(search_queries({'artist':'Кино','title':'Звезда'},'safe')),1)
    def test_prepared_metadata_compatible(self):
        self.assertEqual(parse_text('[{"title":"Song","artist":"Artist","duration":180}]')[0]['duration'],180)

class FlowTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.temp=tempfile.TemporaryDirectory();self.app=FastAPI();self.created=[];self.saved=[]
        @self.app.get('/api/tracks')
        async def tracks(q:str=''):
            return {'tracks':[{'id':'track1','title':'Song','artist':'Artist'}]}
        @self.app.post('/api/playlists')
        async def create(request:Request):
            self.created.append(await request.json());return {'playlist':{'id':'playlist1'}}
        @self.app.post('/api/playlists/{pid}/tracks/{tid}')
        async def add(pid:str,tid:str):self.saved.append((pid,tid));return {'ok':True}
        self.jobs=install(self.app,lambda r:r.headers.get('x-user'),lambda r:r.headers.get('x-csrf-token')=='test',Path(self.temp.name)/'jobs.db')
        self.client=httpx.AsyncClient(transport=httpx.ASGITransport(app=self.app),base_url='http://test',headers={'x-user':'owner','x-csrf-token':'test'})
    async def asyncTearDown(self):
        await self.client.aclose()
        if self.jobs.tasks:await asyncio.gather(*self.jobs.tasks,return_exceptions=True)
        self.temp.cleanup()
    async def wait_state(self,key,state):
        for _ in range(100):
            value=(await self.client.get('/api/imports/'+key)).json()
            if value['state']==state:return value
            if value['state']=='error':self.fail(value['message'])
            await asyncio.sleep(.01)
        self.fail('job did not finish')
    async def test_heavy_legacy_server_search_is_disabled(self):
        result=await self.client.post('/api/imports',json={'provider':'yandex','name':'Old','text':'Artist - Song'})
        self.assertEqual(result.status_code,426)

    async def test_invalid_matched_track_is_rejected(self):
        bad={'provider':'yandex','name':'Test','items':[{'title':'Song','artist':'Artist','track_id':'../../internal'}]}
        result=await self.client.post('/api/imports/client',json=bad)
        self.assertEqual(result.status_code,422)

    async def test_analyze_commit_idempotency_and_owner(self):
        result=await self.client.post('/api/imports/client',json={'provider':'yandex','name':'Test','mode':'wide','items':[
            {'artist':'Artist','title':'Song','track_id':'track1','found_title':'Song','found_artist':'Artist'},
            {'artist':'Missing','title':'Lost song','track_id':None,'reason':'Не найден в каталоге'}]})
        self.assertEqual(result.status_code,200);key=result.json()['id']
        job=await self.wait_state(key,'ready');self.assertEqual(job['matched'],1);self.assertEqual(self.created,[])
        self.assertEqual(len([item for item in job['items'] if not item['track_id']]),1)
        self.assertEqual((await self.client.get('/api/imports/'+key,headers={'x-user':'other'})).status_code,404)
        self.assertEqual((await self.client.post('/api/imports/'+key+'/commit',headers={'x-csrf-token':'wrong'})).status_code,403)
        await asyncio.gather(self.client.post('/api/imports/'+key+'/commit'),self.client.post('/api/imports/'+key+'/commit'))
        done=await self.wait_state(key,'done');self.assertEqual(done['saved'],1)
        await self.client.post('/api/imports/'+key+'/commit')
        self.assertEqual(len(self.created),1);self.assertEqual(self.saved,[('playlist1','track1')])

if __name__=='__main__':unittest.main()
