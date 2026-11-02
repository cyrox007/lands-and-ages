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
html=re.sub(r'<script defer src="(?:engine|visual-model|mill-pack|resource-pack|worker-art|painted-motion|ui)\.js(?:\?[^"]+)?"></script>','',html)
css=(root/'style.css').read_text('utf8')
engine=(root/'engine.js').read_text('utf8')
visual=(root/'visual-model.js').read_text('utf8')
mill_pack=(root/'mill-pack.js').read_text('utf8')
resource_pack=(root/'resource-pack.js').read_text('utf8')
worker_art=(root/'worker-art.js').read_text('utf8')
painted_motion=(root/'painted-motion.js').read_text('utf8')
ui=(root/'ui.js').read_text('utf8')
assets={p.stem:'data:image/webp;base64,'+base64.b64encode(p.read_bytes()).decode('ascii') for p in (root/'assets').glob('*.webp')}
mill_files={'start':'mill-states-start.webp',
            'end':'mill-states-end.webp','parts':'mill-parts.webp'}
mill_assets={name:'data:image/webp;base64,'+
             base64.b64encode((root/'assets/buildings/mill'/filename).read_bytes()).decode('ascii')
             for name,filename in mill_files.items()}
detail_assets={name:'data:image/webp;base64,'+base64.b64encode(
    (root/'assets/buildings/mill'/file).read_bytes()).decode('ascii')
    for name,file in {'body':'mill-detailed-body.webp','rotor':'mill-detailed-rotor.webp'}.items()}

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
    page.add_script_tag(content=mill_pack)
    page.add_script_tag(content=resource_pack)
    page.add_script_tag(content=worker_art)
    page.add_script_tag(content=painted_motion)
    page.evaluate('(uri) => { window.StrategyResourceAtlas=uri; }',
        'data:image/webp;base64,'+base64.b64encode(
          (root/'assets/resources/construction-resources.webp').read_bytes()).decode('ascii'))
    page.evaluate('(uri) => { window.StrategyPaintedPeople=uri; }',
        'data:image/webp;base64,'+base64.b64encode(
          (root/'assets/characters/painted-people.webp').read_bytes()).decode('ascii'))
    page.evaluate('(assets) => { window.StrategyAssets=assets; }',assets)
    page.evaluate('(assets) => { window.StrategyMillAtlases=assets; }',mill_assets)
    page.evaluate('(assets) => { window.StrategyMillDetailAssets=assets; }',detail_assets)
    page.evaluate('(scenario) => { window.__strategyBoot=scenario; }',boot)
    page.evaluate('''() => {
      const draw=CanvasRenderingContext2D.prototype.drawImage;
      window.__obsoleteMillDrawCount=0;
      window.__paintedDrawCount=0;
      CanvasRenderingContext2D.prototype.drawImage=function(image,...args){
        if(this.canvas?.id==='gameMap' && image instanceof HTMLImageElement && image.src===window.StrategyAssets?.mill)
          window.__obsoleteMillDrawCount++;
        if(this.canvas?.id==='gameMap' && image instanceof HTMLImageElement && image.src===window.StrategyPaintedPeople)
          window.__paintedDrawCount++;
        return draw.call(this,image,...args);
      };
    }''')
    page.add_script_tag(content=ui)

def tap_cell(page,x,y,mobile,confirm=True):
    page.evaluate("document.querySelector('#gameMap').scrollIntoView({block:'start'})")
    p=page.evaluate("([x,y]) => {\n      const r=document.querySelector('#gameMap').getBoundingClientRect();\n      const s=window.__strategyDebug().screen(x,y);\n      return {x:r.left+s.x,y:r.top+s.y};\n    }",[x,y])
    assert p['x']>=0 and p['y']>=0,p
    if mobile:
        page.touchscreen.tap(p['x'],p['y'])
        if confirm and page.evaluate('window.__strategyDebug().mode') not in ('inspect','excavate'):
            page.touchscreen.tap(p['x'],p['y'])
    else:
        page.mouse.click(p['x'],p['y'])

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
    # Проверяем, что новые 4×8 атласы действительно декодируются и рисуются в Canvas.
    illustrated=page.evaluate("""async () => {
      const art=window.StrategyWorkerArt;
      if(!art)return {error:'нет генератора'};
      const results=[];
      for(const role of [...art.roles,...art.villagerRoles]){
        const svg=art.atlas(role,art.villagerRoles.includes(role)?'idle':'walk');
        const url=URL.createObjectURL(new Blob([svg],{type:'image/svg+xml'}));
        const img=new Image();
        try{
          await new Promise((resolve,reject)=>{
            img.onload=resolve;img.onerror=()=>reject(Error('SVG: '+role));
            img.src=url;
          });
          const c=document.createElement('canvas');
          c.width=img.naturalWidth;c.height=img.naturalHeight;
          const g=c.getContext('2d');g.drawImage(img,0,0);
          let rendered=0;
          for(let row=0;row<4;row++)for(let frame=0;frame<8;frame++)
            if(g.getImageData(frame*96+48,row*128+65,1,1).data[3]>0)rendered++;
          results.push({role,width:img.naturalWidth,height:img.naturalHeight,rendered});
        }finally{URL.revokeObjectURL(url);}
      }
      return {results};
    }""")
    assert 'error' not in illustrated,illustrated
    assert len(illustrated['results'])==9
    for result in illustrated['results']:
        assert result['width']==768 and result['height']==512,result
        assert result['rendered']==32,result

    assert page.evaluate('window.__strategyDebug().projection')=='isometric'
    assert page.evaluate('window.__strategyDebug().rockDeposits')>0
    page.wait_for_function('window.__strategyDebug().resourcePack().loaded',timeout=20000)
    assert page.evaluate('window.__strategyDebug().resourcePack().count')==10
    # При отсутствии доставки игровые запасы на стройке равны нулю.
    items=page.evaluate('window.__strategyDebug().resourcePack().construction')
    assert all(all(m['visible']==0 for m in site['materials']) for site in items)

    page.wait_for_function('window.__strategyDebug().millPackage().loaded===3',timeout=20000)
    assert page.evaluate('window.__strategyDebug().millPackage().total')==3
    page.wait_for_function('window.__strategyDebug().millPackage().detailedLoaded===2',timeout=20000)
    layout=page.evaluate('window.__strategyDebug().millPackage().layout')
    assert layout['width']>0
    assert layout['hubX']<0 and layout['hubY']<0
    assert layout['rotorWidth']<layout['width']*.55
    body=page.evaluate("window.__strategyDebug().millGroundLayout('body')")
    survey=page.evaluate("window.__strategyDebug().millGroundLayout('survey')")
    frame=page.evaluate("window.__strategyDebug().millGroundLayout('frame')")
    levels=[body['top']+body['height']*284/316,
            survey['top']+survey['size']*135/176,
            frame['top']+frame['size']*157/176]
    assert max(levels)-min(levels)<.001,(name,'разные высоты основания мельницы',levels)
    assert survey['size']*168/176 < 164,(name,'площадка вылезает за 2×2',survey)

    assert page.evaluate('window.__strategyDebug().millPackage().raster') is True
    assert page.evaluate('window.__strategyDebug().millPackage().source')=='approved-imagegen-sheets'
    assert page.evaluate('window.__strategyDebug().millRotorState(5).blades')==4
    assert page.evaluate('window.__strategyDebug().millRotorState(5).bakedSprite') is False
    assert page.evaluate('window.__strategyDebug().millRotorState(5).angle') is not None
    assert page.evaluate('window.__obsoleteMillDrawCount')==0,'отдельный корпус не должен рисовать старые лопасти'
    # When stopped, rotor angle is not animated by wall clock.
    mill_angle=page.evaluate('window.__strategyDebug().millRotorState(5).angle')
    page.locator('#pauseBtn').click()
    page.wait_for_timeout(90)
    assert page.evaluate('window.__strategyDebug().millRotorState(5).angle')==mill_angle
    page.locator('#pauseBtn').click()

    # Walk cycle is tied to real traveled grid distance, not animationClock.
    page.evaluate('window.__strategyDebug().step(2)')
    assert page.evaluate('window.__strategyDebug().workerPose("porter",0).travelled')>0
    page.locator('#pauseBtn').click()
    before=page.evaluate('window.__strategyDebug()')
    tap_cell(page,17,10,mobile)
    assert page.evaluate('window.__strategyDebug().sites.length')==0,'pause must reject road order'
    assert page.evaluate('window.__strategyDebug().coins')==before['coins']
    page.evaluate('window.__strategyDebug().step(20)')
    assert page.evaluate('window.__strategyDebug().day')==before['day']
    assert page.evaluate('window.__strategyDebug().animationClock')==before['animationClock']
    t=page.evaluate('window.__strategyDebug().workerPose("porter",0).travelled')
    page.wait_for_timeout(90)
    assert page.evaluate('window.__strategyDebug().workerPose("porter",0).travelled')==t
    page.locator('#pauseBtn').click()
    assert page.evaluate('window.__strategyDebug().productionAt("bakery")') is False
    assert page.evaluate('window.__strategyDebug().visualVersion')=='0.5.8-resource-sprites'
    assert page.evaluate("window.__strategyDebug().placement('mill',14,9).size")=={'w':2,'h':2}
    blocked=page.evaluate("window.__strategyDebug().placement('mill',14,9)")
    assert blocked['ok'] is False
    assert any('дорог' in (cell['error'] or '') for cell in blocked['cells'])
    free=page.evaluate("window.__strategyDebug().placement('mill',14,8)")
    assert len(free['cells'])==4
    # Old carry atlas has a painted sack. Actual carrier renders clean walk
    # poses and draws only one resource on top, even for bread / flour / logs.
    for cargo in ['logs','boards','stone','grain','vegetables','flour','bread']:
        pose=page.evaluate('(res)=>window.__strategyDebug().porterPoseForCargo(res)',cargo)
        assert pose['sheet']=='worker-porter-walk',(name,cargo,pose)
    unloaded=page.evaluate('window.__strategyDebug().porterPoseForCargo(null)')
    assert unloaded['sheet']=='worker-porter-walk'

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
    for x,kind,mask,stones in [(15,'straight',10,39),(16,'end',8,24)]:
        paved=page.evaluate('(x)=>window.__strategyDebug().roadPaving(x,10)',x)
        assert paved['kind']==kind,(name,paved)
        assert paved['mask']==mask,(name,paved)
        assert paved['stones']==stones,(name,paved)
    assert page.evaluate('window.__strategyDebug().roadSpritesCached')>0

    assert page.evaluate('window.__strategyDebug().groundTextureWidth')==1804
    assert page.evaluate('window.__strategyDebug().groundTextureHeight')==902
    assert page.evaluate('window.__strategyDebug().groundMaterialMode')=='nonperiodic-world-raster'
    samples=page.evaluate('''() => [500,884,1268].map(x=>window.__strategyDebug().groundSample(x,450))''')
    assert all(p[3]==255 for p in samples),(name,samples)
    assert len({tuple(v) for v in samples})>1,(name,'texture repeats at 384px',samples)
    assert 'createPattern(' not in ui and 'function terrainTile(' not in ui,'no recurring square tiles'
    assert page.evaluate('window.__strategyDebug().treeArtCount')>0
    assert page.evaluate('window.__strategyDebug().waterGroupCount')>0
    assert page.evaluate('window.__strategyDebug().tileCache')==0,'grass diamond tiles must not render'
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
    if mobile:
        tap_cell(page,17,10,mobile,confirm=False)
        assert page.evaluate('window.__strategyDebug().sites.length')==0
        assert page.evaluate('window.__strategyDebug().touchPlacement')=={'x':17,'y':10,'mode':'road'}
        tap_cell(page,17,10,mobile,confirm=False)
    else:
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
    # Construction visuals are driven by delivery and actual work progress.
    assert page.evaluate("typeof window.__strategyDebug().constructionArtAt")== 'function'

    paved=page.evaluate('window.__strategyDebug().roadPaving(17,10)')
    assert paved['stones']==39,(name,paved)
    assert page.evaluate('window.__strategyDebug().roadSpritesCached')>0

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
        residents=page.evaluate('window.__strategyDebug().villagers()')
        assert len(residents)==4,(name,residents)
        assert len(set(r['variant'] for r in residents))==4
        page.wait_for_function('window.__strategyDebug().paintedReady()',timeout=20000)
        size=page.evaluate('window.__strategyDebug().paintedSize()')
        assert size=={'width':1056,'height':144},(name,size)
        assert len(page.evaluate('window.__strategyDebug().paintedRoles'))==11
        assert page.evaluate('window.__strategyDebug().paintedCounts().idle')>0
        page.wait_for_function('window.__paintedDrawCount>=4',timeout=20000)
        # Не ограничиваемся портретами: в Chromium реально рисуются все действия.
        motion_pixels=page.evaluate("""async () => {
          const art=window.StrategyPaintedMotion;
          const source=new Image();
          source.src=window.StrategyPaintedPeople;
          await source.decode();
          const result={};
          for(const action of art.STATES){
            const render=(frame)=>{
              const c=document.createElement('canvas');
              c.width=140;c.height=180;
              const g=c.getContext('2d',{willReadFrequently:true});
              art.draw(g,source,7,action,frame,'se',70,165,75,0);
              return g.getImageData(0,0,c.width,c.height).data;
            };
            const a=render(0),b=render(2);
            let differences=0,alpha=0;
            for(let i=0;i<a.length;i+=4){
              if(a[i+3]>0)alpha++;
              if(a[i]!==b[i]||a[i+1]!==b[i+1]||
                a[i+2]!==b[i+2]||a[i+3]!==b[i+3])differences++;
            }
            result[action]={differences,alpha};
          }
          return result;
        }""")
        assert all(v['alpha']>200 and v['differences']>40
                   for v in motion_pixels.values()),(name,motion_pixels)
        assert all(r['variant'].startswith('villager-') for r in residents)
        assert all(r['y']>=10.5 for r in residents),(name,residents)
        assert all(not(10<=r['x']<12 and 8<=r['y']<10) for r in residents)
        page.wait_for_function("""() => {
          const roles=window.__strategyDebug().villagerRoles;
          return roles.length===4&&roles.every(role=>{
            const atlas=window.StrategyWorkerArt.atlas(role,'idle');
            return atlas.includes('data-direction="nw" data-frame="7"');
          });
        }""")
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
