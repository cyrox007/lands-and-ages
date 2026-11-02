"""Check the *published* GitHub Pages layout, not a local injected stylesheet.

Run after push to develop. Poll until Pages serves the new HTML revision
because the static-site deployment may lag behind the Git commit.
"""
import time
import os
from playwright.sync_api import sync_playwright

URL=os.environ.get("PAGES_URL","https://cyrox007.github.io/lands-and-ages/")
EXPECTED="resource-atlas-20261102-v16"
DEADLINE=time.monotonic()+240

with sync_playwright() as pw:
    browser=pw.chromium.launch(headless=True,args=["--no-sandbox"])
    context=browser.new_context(viewport={"width":1280,"height":800})
    page=context.new_page()
    last_error="Page not loaded"
    while time.monotonic()<DEADLINE:
        try:
            response=page.goto(URL+"?pages-layout-check="+str(int(time.time())),
                               wait_until="domcontentloaded",timeout=20000)
            if response is None or response.status>=400:
                last_error=f"HTTP {response.status if response else 'no response'}"
            else:
                marker=page.locator('meta[name="strategy-pages-layout"]').get_attribute("content")
                if marker==EXPECTED:
                    print("GitHub Pages now serves updated HTML:",marker)
                    break
                last_error=f"Expected marker {EXPECTED}; published marker={marker!r}"
        except Exception as exc:
            last_error=str(exc)
        print("Pages publication not ready:",last_error[:240],flush=True)
        time.sleep(12)
    else:
        raise AssertionError("GitHub Pages did not serve the required layout revision: "+last_error)
    context.close()
    for name,width,height,mobile in [
        ("published-desktop",1280,800,False),
        ("published-mobile",393,852,True),
        ("published-narrow",320,568,True),
        ("published-landscape",844,390,True),
    ]:
        context=browser.new_context(viewport={"width":width,"height":height},
                                    is_mobile=mobile,has_touch=mobile)
        page=context.new_page()
        errors=[];failed=[]
        page.on("pageerror",lambda e:errors.append(str(e)))
        page.on("requestfailed",lambda req:failed.append(req.url))
        response=page.goto(URL+"?viewport-check="+name,wait_until="domcontentloaded",timeout=30000)
        try:
            page.wait_for_function("Boolean(window.__strategyDebug)",timeout=20000)
        except Exception:
            print("Live game boot failure",name,
                  "HTTP",response.status if response else None,
                  "errors",errors,"failed requests",failed,
                  "scripts",page.eval_on_selector_all('script[src]','els=>els.map(el=>el.src)'),
                  "body",page.locator('body').inner_text()[:350],flush=True)
            raise
        assert page.evaluate("window.__strategyDebug().groundTextureWidth")==1804
        assert page.evaluate("window.__strategyDebug().groundTextureHeight")==902
        assert page.evaluate("window.__strategyDebug().groundMaterialMode")=="nonperiodic-world-raster"
        paving=page.evaluate('window.__strategyDebug().roadPaving(15,10)')
        # The published default is a new settlement, not the older mission:
        # do not hardcode the road topology at a specific coordinate.
        assert paving['stones']==9+15*paving['mask'].bit_count(),(name,paving)
        assert paving['kind'] in ('isolated','end','straight','corner','junction','crossroads'),(name,paving)
        assert page.evaluate("window.__strategyDebug().roadSpritesCached")>0

        samples=page.evaluate('''() => [500,884,1268].map(x=>window.__strategyDebug().groundSample(x,450))''')
        assert len({tuple(v) for v in samples})>1,(name,"384px repeating square",samples)
        assert page.evaluate("window.__strategyDebug().treeArtCount")>0
        assert page.evaluate("window.__strategyDebug().rockDeposits")>0
        page.wait_for_function("window.__strategyDebug().resourcePack().loaded",timeout=20000)
        assert page.evaluate("window.__strategyDebug().resourcePack().count")==10

        assert page.evaluate("window.__strategyDebug().millRotorState(5).blades")==4
        assert page.evaluate("window.__strategyDebug().millRotorState(5).bakedSprite")==False
        page.wait_for_function("window.__strategyDebug().millPackage().loaded===3",timeout=20000)
        assert page.evaluate("window.__strategyDebug().millPackage().total")==3
        page.wait_for_function("window.__strategyDebug().millPackage().detailedLoaded===2",timeout=20000)
        layout=page.evaluate("window.__strategyDebug().millPackage().layout")
        assert layout["rotorWidth"]<layout["width"]*.55
        body=page.evaluate("window.__strategyDebug().millGroundLayout('body')")
        survey=page.evaluate("window.__strategyDebug().millGroundLayout('survey')")
        level1=body["top"]+body["height"]*284/316
        level2=survey["top"]+survey["size"]*135/176
        assert abs(level1-level2)<.001,(name,"floating construction foundation")

        assert page.evaluate("window.__strategyDebug().millPackage().raster")==True
        assert page.evaluate("window.__strategyDebug().millPackage().source")=="approved-imagegen-sheets"
        # 2×2 preview and the geometry of adjacent completed roads.
        blocked=page.evaluate("window.__strategyDebug().placement('mill',14,9)")
        assert blocked["size"]=={"w":2,"h":2}
        assert len(blocked["cells"])==4
        assert blocked["ok"]==False
        assert any("дорог" in (c["error"] or "") for c in blocked["cells"])
        assert page.evaluate("window.__strategyDebug().placement('mill',14,8).size")=={"w":2,"h":2}

        assert page.evaluate("window.__strategyDebug().waterGroupCount")>0
        for res in ['logs','bread','flour','stone','grain','boards','vegetables']:
            pose=page.evaluate('(res)=>window.__strategyDebug().porterPoseForCargo(res)',res)
            assert pose['sheet']=='worker-porter-walk',(name,res,pose)
        metrics=page.evaluate("""() => {
          const c=document.querySelector('#gameMap').getBoundingClientRect();
          const shell=document.querySelector('.shell');
          const dock=document.querySelector('.game-dock');
          return {
            canvas:[c.x,c.y,c.width,c.height],
            viewport:[innerWidth,innerHeight],
            shellPosition:getComputedStyle(shell).position,
            dockDisplay:getComputedStyle(dock).display,
            sidebarDisplay:getComputedStyle(document.querySelector('.sidebar')).visibility,
            pageScroll:[document.documentElement.scrollWidth,document.documentElement.scrollHeight],
            topBar:document.querySelector('.masthead').getBoundingClientRect().toJSON(),
            stats:document.querySelector('.top-stats').getBoundingClientRect().toJSON(),
            dockRect:dock.getBoundingClientRect().toJSON(),
            questCollapsed:document.querySelector('#missionToggle').getAttribute('aria-expanded'),
            questContentsMaxHeight:getComputedStyle(document.querySelector('#missionContents')).maxHeight,
            questContentsPointerEvents:getComputedStyle(document.querySelector('#missionContents')).pointerEvents,
            cssHref:document.querySelector('link[rel="stylesheet"]').href
          };
        }""")
        assert abs(metrics["canvas"][0])<2 and abs(metrics["canvas"][1])<2,(name,metrics)
        assert abs(metrics["canvas"][2]-width)<2,(name,metrics)
        assert abs(metrics["canvas"][3]-height)<2,(name,metrics)
        assert metrics["shellPosition"]=="fixed",(name,metrics)
        assert metrics["dockDisplay"]=="flex" and metrics["sidebarDisplay"]=="hidden",(name,metrics)
        assert metrics["questCollapsed"]=="false",(name,metrics)
        assert metrics["questContentsMaxHeight"]=="0px" and metrics["questContentsPointerEvents"]=="none",(name,metrics)
        assert metrics["stats"]["top"]<metrics["dockRect"]["top"],(name,metrics)
        assert metrics["dockRect"]["top"]>=height*.75,(name,metrics)
        if width<=750 and height>510:
            gap=page.evaluate("""() => document.querySelector('.panel-head').getBoundingClientRect().left -
              document.querySelector('.mission-card').getBoundingClientRect().right""")
            assert gap>=3,(name,"overlapping upper controls",gap)

        assert metrics["pageScroll"][0]<=width+1 and metrics["pageScroll"][1]<=height+1,(name,metrics)
        page.locator('#missionToggle').click()
        page.locator('#missionContents').wait_for(state="visible",timeout=3000)
        if width<=750 and height>510:
            assert not page.locator('.panel-head').is_visible(),name
        page.locator('#missionToggle').click()
        page.locator('[data-hud-panel="build"]').click()
        assert page.locator(".sidebar").is_visible(),(name,metrics)
        page.locator('[data-build-category="raw"]').click()
        assert page.locator('#buildPanel [data-tool="logger"]').is_visible(),name
        assert not page.locator('#buildPanel [data-tool="mill"]').is_visible(),name
        page.locator('[data-hud-panel="build"]').click()
        assert page.locator('.sidebar').evaluate('(el)=>getComputedStyle(el).pointerEvents')=='none',name
        page.locator('.sidebar').wait_for(state="hidden",timeout=3000)
        print(name,metrics,flush=True)
        context.close()
    browser.close()
print("Live GitHub Pages layout validated for all viewport sizes.")
