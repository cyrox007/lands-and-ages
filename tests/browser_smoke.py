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
html=re.sub(r'<link rel="stylesheet" href="style\.css(?:\?[^"]+)?">','',(root/'index.html').read_text('utf8'))
html=re.sub(r'<script defer src="(?:engine|visual-model|ui)\.js(?:\?[^"]+)?"></script>','',html)
css=(root/'style.css').read_text('utf8')
engine=(root/'engine.js').read_text('utf8')
visual=(root/'visual-model.js').read_text('utf8')
ui=(root/'ui.js').read_text('utf8')
assets={p.stem:'data:image/webp;base64,'+base64.b64encode(p.read_bytes()).decode('ascii') for p in (root/'assets').glob('*.webp')}

def mount(page,prior=None,boot="mission"):
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
    page.evaluate('(scenario) => { window.__strategyBoot=scenario; }',boot)
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
    # Walk cycle is tied to real traveled grid distance, not animationClock.
    page.evaluate('window.__strategyDebug().step(2)')
    assert page.evaluate('window.__strategyDebug().workerPose("porter",0).travelled')>0
    page.locator('#pauseBtn').click()
    t=page.evaluate('window.__strategyDebug().workerPose("porter",0).travelled')
    page.wait_for_timeout(90)
    assert page.evaluate('window.__strategyDebug().workerPose("porter",0).travelled')==t
    page.locator('#pauseBtn').click()
    assert page.evaluate('window.__strategyDebug().productionAt("bakery")') is False
    assert page.evaluate('window.__strategyDebug().visualVersion')=='0.5.0-dev'
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
    box=page.locator('#gameMap').bounding_box()
    assert abs(box['width']-w)<2,(name,box,w)
    assert abs(box['height']-h)<2,(name,box,h)
    assert page.evaluate('window.__strategyDebug().mission.stage')==0
    assert page.locator('#missionTitle').inner_text()=='Почини главную дорогу'
    hud=page.evaluate('''() => {
      const box=s=>{const r=document.querySelector(s).getBoundingClientRect();return [r.x,r.y,r.width,r.height]};
      return {header:box('.masthead'),stats:box('.top-stats'),dock:box('.game-dock'),
        quest:box('.mission-card'),map:box('#gameMap'),
        sidebar:getComputedStyle(document.querySelector('#buildPanel')).visibility,
        missionOpen:document.querySelector('#missionToggle').getAttribute('aria-expanded')}
    }''')
    assert abs(hud['map'][2]-w)<2 and abs(hud['map'][3]-h)<2,(name,hud)
    assert hud['dock'][1] > h*.75,(name,hud)
    assert hud['sidebar']=='hidden' and hud['missionOpen']=='false',(name,hud)
    assert hud['quest'][1]>hud['header'][1],(name,hud)
    if w<=750 and h>510:
        horizontal_gap=page.evaluate('''() => {
          const quest=document.querySelector('.mission-card').getBoundingClientRect();
          const zoom=document.querySelector('.panel-head').getBoundingClientRect();
          return zoom.left-quest.right;
        }''')
        assert horizontal_gap>=3,(name,'quest overlaps camera',horizontal_gap)

    assert page.locator('#missionToggle').get_attribute('aria-expanded')=='false'
    page.locator('#missionToggle').click()
    assert page.locator('#missionToggle').get_attribute('aria-expanded')=='true'
    if w<=750 and h>510:
        assert not page.locator('.panel-head').is_visible(),(name,'camera must recede when quest expanded')

    page.locator('#missionTool').click()
    assert page.locator('.game-dock [data-tool="road"]').get_attribute('aria-pressed')=='true'
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
    page.locator('[data-hud-panel="settings"]').click()
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
    page.locator('#missionToggle').click()
    page.locator('#missionTool').click()
    tap_cell(page,8,11,mobile)
    page.wait_for_function('window.__strategyDebug().sites.some(s=>s.type==="house")')
    assert page.evaluate('window.__strategyDebug().mission.stage')==2
    page.evaluate('window.__strategyDebug().step(45)')
    page.wait_for_function('window.__strategyDebug().mission.stage===3')
    page.locator('#missionToggle').click()
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
# A genuinely new settlement boots with one building, full viewport and overlay HUD.
with sync_playwright() as pw:
    browser=pw.chromium.launch(headless=True,args=['--no-sandbox'],executable_path=shutil.which('chromium') or None)
    for name,w,h,mobile in [('settlement-desktop',1280,850,False),('settlement-mobile',393,852,True)]:
        context=browser.new_context(viewport={'width':w,'height':h},is_mobile=mobile,has_touch=mobile)
        page=context.new_page();errors=[];page.on('pageerror',lambda e: errors.append(str(e)))
        mount(page,boot='settlement')
        page.wait_for_function('Boolean(window.__strategyDebug)')
        assert page.evaluate('window.__strategyDebug().scenario')=='settlement'
        assert page.evaluate('window.__strategyDebug().buildings')==1
        assert page.evaluate('window.__strategyDebug().freeWorkers')==4
        box=page.locator('#gameMap').bounding_box()
        assert abs(box['width']-w)<2 and abs(box['height']-h)<2
        assert page.evaluate('document.documentElement.scrollHeight')<=h+1
        page.locator('[data-hud-panel="build"]').click()
        assert page.locator('.shell').get_attribute('data-panel')=='build'
        page.locator('[data-build-category="raw"]').click()
        assert page.locator('[data-build-category="raw"]').get_attribute('aria-pressed')=='true'
        page.locator('#buildPanel [data-tool="field"]').click()
        assert page.locator('#buildPanel [data-tool="field"]').get_attribute('aria-pressed')=='true'
        page.locator('[data-crop="barley"]').click()
        assert page.locator('[data-crop="barley"]').get_attribute('aria-pressed')=='true'
        page.locator('[data-hud-panel="stocks"]').click()
        assert page.locator('#stoneStock').is_visible()
        # Actual new-game pointer flow: place a logger, finish its site and staff it.
        page.locator('[data-hud-panel="build"]').click()
        page.locator('[data-build-category="raw"]').click()
        page.locator('#buildPanel [data-tool="logger"]').click()
        tap_cell(page,12,9,mobile)
        page.wait_for_function('window.__strategyDebug().sites.some(s=>s.type==="logger")')
        page.evaluate('window.__strategyDebug().step(45)')
        page.wait_for_function('window.__strategyDebug().buildings===2')
        page.locator('.game-dock [data-tool="inspect"]').click()
        tap_cell(page,12,9,mobile)
        page.wait_for_function('document.querySelector(".staff-controls") !== null')
        assert page.locator('.staff-controls').is_visible()
        assert page.locator('.staff-controls span').inner_text()=='Рабочие: 1 / 1'
        assert page.evaluate('window.__strategyDebug().freeWorkers')==3
        page.locator('.staff-controls button[aria-label="Снять работника"]').click()
        assert page.evaluate('window.__strategyDebug().freeWorkers')==4
        page.locator('.staff-controls button[aria-label="Назначить работника"]').click()
        assert page.evaluate('window.__strategyDebug().freeWorkers')==3
        assert not errors,(name,errors)
        print(name,{'oneHQ':True,'fullViewport':True,'overlaidHUD':True,'errors':0})
        context.close()
    browser.close()

# Regression: a browser caching the old 0.4 stylesheet must never turn
# the 0.5 HUD back into a scrolling document. Inline critical geometry wins.
legacy_css=css.split('/* 0.5: The viewport IS the game.')[0]
with sync_playwright() as pw:
    browser=pw.chromium.launch(headless=True,args=['--no-sandbox'],executable_path=shutil.which('chromium') or None)
    for name,w,h,mobile in [('cached-style-desktop',1280,800,False),('cached-style-mobile',393,852,True)]:
        context=browser.new_context(viewport={'width':w,'height':h},is_mobile=mobile,has_touch=mobile)
        page=context.new_page();page.set_content(html)
        page.add_style_tag(content=legacy_css)
        page.evaluate('''() => Object.defineProperty(window,'localStorage',{configurable:true,value:{
          getItem(){return null},setItem(){},removeItem(){}}})''')
        page.add_script_tag(content=engine)
        page.add_script_tag(content=visual)
        page.evaluate('(assets) => { window.StrategyAssets=assets; }',assets)
        page.add_script_tag(content=ui)
        page.wait_for_function('Boolean(window.__strategyDebug)')
        metrics=page.evaluate('''() => {
          const c=document.querySelector('#gameMap').getBoundingClientRect();
          const v=document.querySelector('.shell'),m=document.querySelector('.map-container');
          return {width:c.width,height:c.height,left:c.left,top:c.top,
            viewportWidth:innerWidth,viewportHeight:innerHeight,
            bodyOverflow:getComputedStyle(document.body).overflow,
            shellPosition:getComputedStyle(v).position,
            mapPosition:getComputedStyle(m).position,
            dockDisplay:getComputedStyle(document.querySelector('.game-dock')).display,
            scrollHeight:document.documentElement.scrollHeight}
        }''')
        assert abs(metrics['width']-w)<2 and abs(metrics['height']-h)<2,(name,metrics)
        assert abs(metrics['left'])<2 and abs(metrics['top'])<2,(name,metrics)
        assert metrics['scrollHeight']<=h+1,(name,metrics)
        assert metrics['bodyOverflow']=='hidden' and metrics['shellPosition']=='fixed',(name,metrics)
        assert metrics['dockDisplay']=='flex',(name,metrics)
        page.locator('[data-hud-panel="build"]').click()
        assert page.locator('.sidebar').is_visible(),name
        print(name,metrics)
        context.close()
    browser.close()
