from pathlib import Path
import ast
import pytest
from install_audius import patch, install, rollback, BEGIN

SOURCE = '''import server as core
app = object()
def session(request, required=True): return {'user_id': 'x'}
def public(row):
    rights = {}
    return {'source': rights.get('source'), 'is_remote': rights.get('source')=='soundcloud'}
def tracks(request, q=''): pass
def track(conn, tid, request): pass
def stream(tid, request): pass
def cover(tid, request): pass
def listening(request): pass
def recommendations(request): pass
# /api/tracks /api/stream/{tid}
if __name__ == '__main__':
    print('existing launch')
'''


def setup(root):
    (root/'app.py').write_text(SOURCE, encoding='utf-8')
    (root/'wave_preferences.py').write_text('# current preferences',encoding='utf-8')
    (root/'music_import.py').write_text('# current import with local fixes',encoding='utf-8')


def test_patch_idempotent_and_before_main():
    changed=patch(SOURCE)
    assert patch(changed)==changed
    assert changed.count(BEGIN)==1
    assert changed.index(BEGIN)<changed.index('if __name__')
    assert "in ('soundcloud', 'audius')" in changed
    ast.parse(changed)


def test_install_and_rollback_keep_accounts_import_and_preferences(tmp_path):
    setup(tmp_path)
    (tmp_path/'accounts.db').write_bytes(b'accounts')
    first=install(tmp_path)
    assert len(first['changed'])==5
    assert install(tmp_path)['changed']==[]
    assert (tmp_path/'music_import.py').read_text()=='# current import with local fixes'
    rollback(first['backup'])
    assert (tmp_path/'app.py').read_text()==SOURCE
    assert not (tmp_path/'audius_provider.py').exists()
    assert (tmp_path/'accounts.db').read_bytes()==b'accounts'


def test_unknown_server_and_newer_wave_not_overwritten(tmp_path):
    with pytest.raises(ValueError):
        patch('print("other server")')
    setup(tmp_path)
    (tmp_path/'adaptive_wave.py').write_text('# future version')
    with pytest.raises(ValueError,match='другая версия'):
        install(tmp_path)
    assert (tmp_path/'app.py').read_text()==SOURCE
    assert not (tmp_path/'audius_catalog.py').exists()


def test_rollback_refuses_to_destroy_subsequent_changes(tmp_path):
    setup(tmp_path)
    result=install(tmp_path)
    (tmp_path/'app.py').write_text('# later updates')
    with pytest.raises(ValueError):
        rollback(result['backup'])
    assert (tmp_path/'app.py').read_text()=='# later updates'


def test_install_accepts_previous_wave_release(tmp_path):
    setup(tmp_path)
    source=Path(__file__).resolve().parents[2]/'adaptive-wave'/'adaptive_wave.py'
    data=source.read_text()
    start=data.index('        # Optional sources share')
    stop=data.index('        return payload',start)
    (tmp_path/'adaptive_wave.py').write_text(data[:start]+data[stop:])
    assert install(tmp_path)['changed']
