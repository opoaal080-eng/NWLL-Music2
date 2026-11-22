from pathlib import Path
import hashlib, subprocess, time, re, xml.etree.ElementTree as ET
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
    # Android 10 first-run immersive education hides the app behind a system overlay.
    # Confirm the emulator-only onboarding so screenshots test Nightwell, not Android UI.
    subprocess.run(['adb','shell','settings','put','secure',
        'immersive_mode_confirmations','confirmed'],check=False,capture_output=True)

    # Real artwork already in the repository, installed only in the emulator's debug cache.
    covers = ["../design-assets/halloween-landscape.webp",
              "../NightwellMusic/Assets.xcassets/SeasonPortrait.imageset/background.jpg",
              "app/src/main/res/drawable/brand_logo.png",
              "../NightwellMusic/Assets.xcassets/SeasonLandscape.imageset/background.jpg"]
    package = "fun.nightwell.music"
    cache = "cache/nightwell-covers-v1"
    adb("shell","run-as",package,"mkdir","-p",cache)
    for index, source in enumerate(covers):
        key = hashlib.sha256(f"https://music.nightwell.fun//api/covers/smoke-{index}".encode()).hexdigest()
        with open(source,"rb") as cover:
            subprocess.run(["adb","shell","-T","run-as",package,"tee",f"{cache}/{key}.image"],
                           stdin=cover,stdout=subprocess.DEVNULL,check=True)
    for width,height,density in [(720,1280,320),(1080,2340,440)]:
        adb("shell","wm","size",f"{width}x{height}")
        adb("shell","wm","density",str(density))
        launch("Главная")
        values=capture("home-"+str(width))
        assert find("Открыть меню",values) is None
        click("Вкладка «Медиатека»")
        library=capture("library-"+str(width))
        assert find("Настройки",library) is not None and find("Ещё в медиатеке",library) is not None
        assert sum(n.get("content-desc","").startswith("Действия с треком «") for n in library)==3
        if width==1080:
            for label in ("Плейлисты","Офлайн","Подборки дня","Умные плейлисты"):
                assert find(label,library) is not None,label
            click("Дополнительно")
            extra=capture("library-actions")
            for label in ("Слушать вместе","Перенос плейлистов","Обращения и поддержка"):
                assert find(label,extra) is not None,label
            assert find("Выйти",extra) is None
            click("Закрыть")
            click("Настройки");capture("library-settings")
            adb("shell","input","keyevent","4")
            click("Вкладка «Главная»");click("Открыть профиль")
            profile=capture("profile")
            assert find("Статистика",profile) is not None and find("Выйти",profile) is not None
    launch("player")
    player=capture("full-player")
    assert find("Свернуть плеер",player) is not None
    assert not any(n.get("text","").upper() in ("СЕЙЧАС ИГРАЕТ","NIGHTWELL MUSIC") for n in player)
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
    print('Library, player, profile, playlist import and cancellation passed')
finally:
    adb('shell','wm','size','reset');adb('shell','wm','density','reset')
    (out/'errors.txt').write_text(adb('logcat','-d','-s','AndroidRuntime:E'))
