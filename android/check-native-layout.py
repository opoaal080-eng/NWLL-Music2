"""Exercise real native layouts on a small phone and in landscape, without a server."""
from pathlib import Path
import subprocess,time,xml.etree.ElementTree as ET,re
from PIL import Image
out=Path(__file__).resolve().parent/'native-smoke';out.mkdir(parents=True,exist_ok=True)
def adb(*args):return subprocess.run(['adb',*args],check=True,capture_output=True,text=True,timeout=35).stdout
def capture(name):
    last_error=""
    for attempt in range(8):
        try:
            adb('shell','rm','-f','/sdcard/layout.xml')
            result=adb('shell','uiautomator','dump','/sdcard/layout.xml')
            adb('pull','/sdcard/layout.xml',str(out/(name+'.xml')))
            root=ET.parse(out/(name+'.xml')).getroot()
            assert any(n.get('package')=='fun.nightwell.music' for n in root.iter('node')), 'App hierarchy is not ready'
            break
        except (subprocess.CalledProcessError,subprocess.TimeoutExpired,ET.ParseError,AssertionError) as error:
            last_error=str(error)+" "+str(getattr(error,'stdout',''))+" "+str(getattr(error,'stderr',''))
            if attempt==7:
                for args in [('shell','screencap','-p','/sdcard/layout-failed.png'),('pull','/sdcard/layout-failed.png',str(out/(name+'-failed.png')))]:
                    subprocess.run(['adb',*args],timeout=35,check=False,capture_output=True)
                raise RuntimeError(name+': '+last_error) from error
            time.sleep(2)
    adb('shell','screencap','-p','/sdcard/layout.png');adb('pull','/sdcard/layout.png',str(out/(name+'.png')))
    root=ET.parse(out/(name+'.xml')).getroot();nodes=list(root.iter('node'))
    assert not any('WebView' in n.get('class','') for n in nodes)
    assert not any('isn\'t responding' in n.get('text','') for n in nodes),name
    texts=[n.get('text','') for n in nodes]
    if name.startswith('player'):
        assert any(n.get('content-desc','').startswith('Устройство вывода:') for n in nodes),(name,'Audio route missing')
        assert not any(n.get('text')=='Nightwell Music' for n in nodes),'Mini player overlaps full player'
        if name in ['player-720','player-1080']:
            assert any(n.get('content-desc') in ['Добавить в избранное','Убрать из избранного'] and n.get('clickable')=='true' for n in nodes),(name,'Favourite action missing')
            button=next(n for n in nodes if n.get('text')=='▶')
            left,top,right,bottom=map(int,re.findall(r'\d+',button.get('bounds')))
            assert bottom-top>=(120 if name=='player-720' else 150),(name,'Play button clipped',button.attrib)
    if name.startswith('wave-settings-'):
        assert all(text in texts for text in ['Настроить подборку','Характер','Настроение','Язык']),(name,texts)
        assert any('Открытия' in text for text in texts),(name,'Wave options missing')
    if name.startswith('premium-sound-'):
        assert any('Звук под вас' in text for text in texts),(name,texts)
        assert 'Эквалайзер' in texts,(name,texts)
    if name.startswith('premium-appearance-'):
        assert 'Ваше оформление' in texts,(name,texts)
    if name.startswith('menu-'):
        assert all(tab in texts for tab in ['Главная','Поиск','Избранное','Плейлисты','Офлайн','Настройки']),(name,texts)
        if 'Выйти' not in texts:
            scroller=next(n for n in nodes if n.get('scrollable')=='true')
            left,top,right,bottom=map(int,re.findall(r'\d+',scroller.get('bounds')))
            adb('shell','input','swipe',str((left+right)//2),str(bottom-20),str((left+right)//2),str(top+20),'350')
            time.sleep(.5)
            adb('shell','uiautomator','dump','/sdcard/menu-bottom.xml')
            adb('pull','/sdcard/menu-bottom.xml',str(out/(name+'-bottom.xml')))
            bottom_nodes=list(ET.parse(out/(name+'-bottom.xml')).getroot().iter('node'))
            assert any(n.get('text')=='Выйти' for n in bottom_nodes),(name,'Logout not reachable by scrolling')
    for n in nodes:
        if n.get('clickable')!='true' or n.get('enabled')!='true':continue
        values=list(map(int,re.findall(r'\d+',n.get('bounds',''))))
        if len(values)==4:assert values[2]>values[0] and values[3]>values[1],(name,n.attrib)
    if name.startswith('lyrics-'):
        assert any('Белый свет' in text for text in texts),(name,'Inline lyrics missing')
        assert any(n.get('content-desc','').startswith('Устройство вывода:') for n in nodes),(name,'Lyrics hid player controls')
    if name.startswith('Главная'):
        image=Image.open(out/(name+'.png')).convert('RGB')
        for symbol in ['⌕','☰','▶']:
            button=next(n for n in nodes if n.get('text')==symbol)
            left,top,right,bottom=map(int,re.findall(r'\d+',button.get('bounds')))
            width,height=right-left,bottom-top
            crop=image.crop((left+width*.2,top+height*.2,right-width*.2,bottom-height*.2))
            bright=sum(1 for red,green,blue in crop.getdata() if red>=230 and green>=150 and blue>=75)
            assert bright>20,(name,symbol,'Control has no visible icon',bright)
    print('Verified',name)
try:
    for width,height,density in [(1080,2400,420),(720,1280,320)]:
        adb('shell','wm','size',f'{width}x{height}');adb('shell','wm','density',str(density))
        for page in ['premium-sound','premium-appearance','Главная','Поиск','Избранное','Плейлисты','Офлайн','player','lyrics','settings','auth','queue','menu','wave-settings']:
            adb('shell','am','force-stop','fun.nightwell.music')
            adb('shell','am','start','-W','-n','fun.nightwell.music/.MainActivity','--ez','nativeSmoke','true','--es','screen',page)
            time.sleep(1);capture(page+'-'+str(width))
    adb('shell','settings','put','system','accelerometer_rotation','0');adb('shell','settings','put','system','user_rotation','1')
    adb('shell','am','force-stop','fun.nightwell.music');adb('shell','am','start','-W','-n','fun.nightwell.music/.MainActivity','--ez','nativeSmoke','true','--es','screen','player');time.sleep(1);capture('player-landscape')
    adb('shell','am','start','-W','-a','android.intent.action.VIEW','-d','nightwell://track/80adb8c0f574439fac645585493e955a','fun.nightwell.music')
    assert 'fun.nightwell.music' in adb('shell','dumpsys','activity','activities')
finally:
    adb('shell','wm','size','reset');adb('shell','wm','density','reset');adb('shell','settings','put','system','user_rotation','0')
print('Android native screens and custom protocol activation passed')


