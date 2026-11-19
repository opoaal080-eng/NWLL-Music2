from pathlib import Path
import subprocess, time, re, xml.etree.ElementTree as ET
out=Path('import-menu-checks');out.mkdir(exist_ok=True)
def adb(*args):
    return subprocess.run(['adb',*args],check=True,capture_output=True,text=True,timeout=40).stdout
def nodes():
    for attempt in range(8):
        try:
            adb('shell','uiautomator','dump','/sdcard/import-window.xml')
            adb('pull','/sdcard/import-window.xml',str(out/'window.xml'))
            result=list(ET.parse(out/'window.xml').getroot().iter('node'))
            if result:return result
        except (subprocess.SubprocessError,ET.ParseError):pass
        time.sleep(2)
    raise AssertionError('No UI hierarchy')
def tap(node):
    x,y,r,b=map(int,re.findall(r'\d+',node.get('bounds')))
    adb('shell','input','tap',str((x+r)//2),str((y+b)//2));time.sleep(1)
def find(label, values=None):
    for n in values or nodes():
        if n.get('text')==label or n.get('content-desc')==label:return n
    return None
def click(label):
    node=find(label);assert node is not None,(label,[(n.get('text'),n.get('content-desc')) for n in nodes()]);tap(node)
def capture(name):
    values=nodes();adb('shell','screencap','-p','/sdcard/import-screen.png');adb('pull','/sdcard/import-screen.png',str(out/(name+'.png')))
    (out/(name+'.xml')).write_text((out/'window.xml').read_text())
    return values
def launch(screen):
    adb('shell','am','force-stop','fun.nightwell.music')
    adb('shell','am','start','-W','-n','fun.nightwell.music/.MainActivity','--ez','nativeSmoke','true','--es','screen',screen);time.sleep(2)
try:
    adb('shell','input','keyevent','82')
    for width,height,density in [(1080,1920,420),(720,1280,320)]:
        adb('shell','wm','size',f'{width}x{height}');adb('shell','wm','density',str(density));launch('menu')
        # iOS-style Additional is a bottom sheet, not the old popup menu.
        for attempt in range(8):
            values=capture('more-'+str(width))
            if find('Слушать вместе',values) is not None:break
            time.sleep(1)
        assert find('Слушать вместе',values) is not None,'Additional sheet is missing'
        assert find('Перенос плейлистов',values) is not None,'Transfer link is missing'
        assert find('Обращения и поддержка',values) is not None,'Support link is missing'
    adb('shell','wm','size','reset');adb('shell','wm','density','reset')
    launch('Главная')
    home=capture('home-bottom-nav')
    assert find('Медиатека',home) is not None,'Bottom navigation is missing'
    assert find('Открыть профиль',home) is not None,'Profile avatar button is missing'
    click('Медиатека')
    overview=capture('library-bottom-nav')
    assert find('Избранное',overview) is not None,'Library has no favorites entry'
    assert find('Плейлисты',overview) is not None,'Library has no playlists entry'
    assert find('Офлайн',overview) is not None,'Library has no offline entry'
    click('Поиск')
    search=capture('search-bottom-nav')
    assert find('Медиатека',search) is not None,'Navigation was removed after screen change'
    launch('Плейлисты')
    capture('playlists-iphone-layout')
    assert find('Плейлисты') is not None,'Playlist title is missing'
    launch('settings')
    settings=capture('settings-hub')
    assert find('Кастомизация',settings) is not None,'Settings hub missing customization'
    click('Темы')
    themes=capture('themes-picker')
    assert any('Vice Nights' in (n.get('text') or '') for n in themes),'Vice Nights theme picker is missing'
    launch('profile')
    profile=capture('profile')
    assert find('Устройства и семья',profile) is not None,'Device and family screen is missing'
    fixture=out/'nightwell-playlist.csv';fixture.write_text('artist,title\nNightwell,Import Test',encoding='utf-8')
    adb('push',str(fixture),'/sdcard/Download/nightwell-playlist.csv')
    launch('transfer');capture('transfer-empty');click('Выбрать файл')
    values=capture('document-picker');assert any('documentsui' in n.get('package','') for n in values),'System picker did not open'
    # Storage Access Framework may start in Recent; use Downloads if needed.
    if find('nightwell-playlist.csv') is None:
        drawer=find('Show roots')
        if drawer is None:drawer=find('Open navigation drawer')
        if drawer is not None:tap(drawer)
        download=find('Downloads')
        if download is None:download=find('Download')
        if download is not None:tap(download)
    click('nightwell-playlist.csv');time.sleep(2)
    values=capture('transfer-file-loaded')
    assert any('Nightwell,Import Test' in n.get('text','') for n in values),'Document text was not imported'
    click('Выбрать файл');adb('shell','input','keyevent','4');time.sleep(1)
    assert any('Nightwell,Import Test' in n.get('text','') for n in nodes()),'Cancelling picker lost the imported text'
    print('iOS-style bottom navigation, library and profile header, menu, SAF import and cancellation passed')
finally:
    adb('shell','wm','size','reset');adb('shell','wm','density','reset')
    (out/'errors.txt').write_text(adb('logcat','-d','-s','AndroidRuntime:E'))
