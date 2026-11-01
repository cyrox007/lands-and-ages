"""Chromium smoke: 4 viewports, pointer controls, construction, save/load.

The sandbox blocks navigation, so HTML/CSS/JS are injected and localStorage is
shimmed. This verifies UI behavior, not real-origin browser storage permissions.
"""
import re
import base64
import shutil
from pathlib import Path
from playwright.sync_api import sync_playwright

root=Path(__file__).resolve().parents[1]
html=re.sub(r'<link rel="stylesheet" href="style.css">','',(root/'index.html').read_text('utf8'))
html=re.sub(r'<script defer src="(?:engine|visual-model|ui)\.js"></script>','',html)
css=(root/'style.css').read_text('utf8')
engine=(root/'engine.js').read_text('utf8')
visual=(root/'visual-model.js').read_text('utf8')
ui=(root/'ui.js').read_text('utf8')
assets={p.stem:'data:image/webp;base64,'+base64.b64encode(p.read_bytes()).decode('ascii') for p in (root/'assets').glob('*.webp')}

def mount(page,prior=None):
    page.set_content(html)
    page.add_style_tag(content=css)
    page.evaluate('''(prior) => {
      const s=new Map(prior||[]);
      Object.defineProperty(window,'localStorage',{configurable:true,value:{
        getItem(k){return s.get(k)??null},setItem(k,v){s.set(k,String(v))},
        removeItem(k){s.delete(k)},clear(){s.clear()},entries(){return Array.from(s)}
      }});
    }''',prior)
    page.add_script_tag(content=engine)
    page.add_script_tag(content=visual)
    page.evaluate('(assets) => { window.StrategyAssets=assets; }',assets)
    page.add_script_tag(content=ui)

def tap_cell(page,x,y,mobile):
    page.evaluate("document.querySelector('#gameMap').scrollIntoView({block:'start'})")
    p=page.evaluate("([x,y]) => {\n      const r=document.querySelector('#gameMap').getBoundingClientRect();\n      const s=window.__strategyDebug().screen(x,y);\n      return {x:r.left+s.x,y:r.top+s.y};\n    }",[x,y])
    assert p['x']>=0 and p['y']>=0,p
    if mobile: page.touchscreen.tap(p['x'],p['y'])
    else:page.mouse.click(p['x'],p['y'])

def check(browser,name,w,h,mobile):
    context=browser.new_context(viewport={'width':w,'height':h},is_mobile=mobile,has_touch=mobile)
    page=context.new_page();errors=[]
    page.on('pageerror',lambda error: errors.append(str(error)))
    mount(page)
    page.wait_for_function('Boolean(window.__strategyDebug)')
    assert page.locator('#dayStat').inner_text()=='1'
    assert page.evaluate('document.documentElement.scrollWidth')<=w+1,name
    assert page.evaluate('window.__strategyDebug().buildings')==7
    page.wait_for_function('window.__strategyDebug().spritesReady===8',timeout=20000)
    page.wait_for_function('window.__strategyDebug().workerSheetsReady===4',timeout=20000)
    assert page.evaluate('window.__strategyDebug().projection')=='isometric'
    assert page.evaluate('window.__strategyDebug().visualVersion')=='0.4.3'
    # Sprite atlases are genuine frame sheets. Their cropped poses have different pixels.
    pixel_diffs=page.evaluate('''() => {
      const modes=['worker-porter-walk','worker-porter-carry','worker-builder-walk','worker-builder-work'];
      return modes.map(mode=>{
        const img=new Image();img.src=window.StrategyAssets[mode];
        const c=document.createElement('canvas');c.width=96;c.height=128;
        const g=c.getContext('2d',{willReadFrequently:true});
        g.drawImage(img,0,0,96,128,0,0,96,128);
        const a=g.getImageData(0,0,96,128).data.slice();
        g.clearRect(0,0,96,128);g.drawImage(img,5*96,0,96,128,0,0,96,128);
        const b=g.getImageData(0,0,96,128).data;
        let differences=0;for(let i=0;i<a.length;i+=4)
          if(a[i]!==b[i]||a[i+1]!==b[i+1]||a[i+2]!==b[i+2]||a[i+3]!==b[i+3])differences++;
        return differences;
      });
    }''')
    assert min(pixel_diffs)>100,('Static frames masquerading as animation',pixel_diffs)
    clock_before=page.evaluate('window.__strategyDebug().animationClock')
    page.wait_for_timeout(170)
    assert page.evaluate('window.__strategyDebug().animationClock')>clock_before
    page.locator('#pauseBtn').click()
    paused_before=page.evaluate('window.__strategyDebug().animationClock')
    page.wait_for_timeout(170)
    paused_after=page.evaluate('window.__strategyDebug().animationClock')
    assert paused_after==paused_before,('Animation playing during pause',paused_before,paused_after)
    page.locator('#pauseBtn').click()
    assert page.evaluate('window.__strategyDebug().roadKind(16,10)')=='end'
    assert page.evaluate('window.__strategyDebug().roadKind(15,10)')=='straight'
    assert page.evaluate('window.__strategyDebug().tileCache')>0
    assert page.locator('#gameMap').bounding_box()['width']>min(250,w*.7)
    assert page.evaluate('window.__strategyDebug().mission.stage')==0
    assert page.locator('#missionTitle').inner_text()=='Почини главную дорогу'
    page.locator('#missionTool').click()
    assert page.locator('[data-tool="road"]').get_attribute('aria-pressed')=='true'
    tap_cell(page,17,10,mobile)
    page.wait_for_function('window.__strategyDebug().sites.length===1')
    assert page.evaluate('window.__strategyDebug().stageAt(17,10)')=='foundation'
    assert page.evaluate('window.__strategyDebug().roadKind(16,10)')=='end'
    assert page.evaluate('window.__strategyDebug().mission.stage')==0, 'queued road is not finished road'
    assert page.evaluate('window.__strategyDebug().coins')<=173
    assert page.locator('#constructionList .construction-item').count()==1
    page.locator('#saveBtn').click()
    saved=page.evaluate('localStorage.entries()')
    assert saved
    page.close();page=context.new_page()
    page.on('pageerror',lambda error: errors.append(str(error)))
    mount(page,saved)
    page.wait_for_function('Boolean(window.__strategyDebug)')
    assert page.evaluate('window.__strategyDebug().mission.stage')==0
    assert page.evaluate('window.__strategyDebug().sites[0].type')=='road'
    page.wait_for_function('window.__strategyDebug().spritesReady===8',timeout=20000)
    page.evaluate('window.__strategyDebug().step(23)')
    page.wait_for_function('window.__strategyDebug().mission.stage>=1')
    assert page.evaluate('window.__strategyDebug().roadKind(17,10)')=='straight'
    assert page.evaluate('window.__strategyDebug().stageAt(17,10)') is None
    page.locator('#pauseBtn').click()
    assert page.evaluate('window.__strategyDebug().paused') is True
    page.locator('#pauseBtn').click()
    assert page.evaluate('window.__strategyDebug().paused') is False
    before=page.evaluate('window.__strategyDebug().zoom')
    page.locator('#zoomIn').click()
    assert page.evaluate('window.__strategyDebug().zoom')>before
    page.locator('#helpBtn').click()
    assert page.locator('#helpDialog').is_visible()
    page.locator('#closeHelp').click()
    assert not page.locator('#helpDialog').is_visible()
    page.locator('#pauseBtn').click()  # Help opened a pause; capture the visible map.
    page.wait_for_timeout(180)
    assert not errors,(name,errors)
    page.screenshot(path=str(root/'docs'/('screenshot-'+name+'.png')),full_page=True)
    print(name,{'siteSaved':True,'roadCompletedAfterLoading':True,'errors':len(errors),'horizontalOverflow':False})
    context.close()

with sync_playwright() as pw:
    browser=pw.chromium.launch(headless=True,args=['--no-sandbox'],executable_path=shutil.which('chromium') or None)
    for name,w,h,mobile in [('desktop',1280,850,False),('mobile-393',393,852,True),('mobile-320',320,568,True),('landscape',844,390,True)]:
        check(browser,name,w,h,mobile)
    browser.close()

# End-to-end first campaign: all real pointer interactions and simulation.
def test_complete_campaign(browser,mobile=False):
    w,h=(393,852) if mobile else (1280,850)
    ctx=browser.new_context(viewport={'width':w,'height':h},is_mobile=mobile,has_touch=mobile)
    page=ctx.new_page();errors=[];page.on('pageerror',lambda e:errors.append(str(e)));mount(page)
    page.wait_for_function('window.__strategyDebug().spritesReady===8',timeout=20000)
    assert page.evaluate('window.__strategyDebug().mission.stage')==0
    tap_cell(page,17,10,mobile)
    page.wait_for_function('window.__strategyDebug().sites.length===1')
    assert page.evaluate('window.__strategyDebug().mission.stage')==0
    page.evaluate('window.__strategyDebug().step(24)')
    page.wait_for_function('window.__strategyDebug().mission.stage>=1')
    page.evaluate('window.__strategyDebug().step(175)')
    page.wait_for_function('window.__strategyDebug().mission.stage===2')
    page.locator('#missionTool').click()
    tap_cell(page,8,11,mobile)
    page.wait_for_function('window.__strategyDebug().sites.some(s=>s.type==="house")')
    assert page.evaluate('window.__strategyDebug().mission.stage')==2
    page.evaluate('window.__strategyDebug().step(45)')
    page.wait_for_function('window.__strategyDebug().mission.stage===3')
    page.locator('#missionChoices button').first.click()
    page.locator('#missionTool').click()
    tap_cell(page,12,11,mobile)
    page.wait_for_function('window.__strategyDebug().sites.some(s=>s.type==="market")')
    assert page.evaluate('window.__strategyDebug().mission.done') is False
    page.evaluate('window.__strategyDebug().step(105)')
    page.wait_for_function('window.__strategyDebug().mission.done===true',timeout=30000)
    page.wait_for_function('document.querySelector("#missionTitle").textContent==="Долина восстановлена!"',timeout=6000)
    assert not errors,errors
    print('campaign',('mobile' if mobile else 'desktop'),'complete; errors 0')
    ctx.close()

with sync_playwright() as pw:
    browser=pw.chromium.launch(headless=True,args=['--no-sandbox'],executable_path=shutil.which('chromium') or None)
    for mobile in (False,True):test_complete_campaign(browser,mobile)
    browser.close()
