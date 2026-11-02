"""Check the *published* GitHub Pages layout, not a local injected stylesheet.

Run after push to develop. Poll until Pages serves the new HTML revision
because the static-site deployment may lag behind the Git commit.
"""
import time
import os
from playwright.sync_api import sync_playwright

URL=os.environ.get("PAGES_URL","https://cyrox007.github.io/lands-and-ages/")
EXPECTED="strategy-hud-20261102-v3"
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
        page.goto(URL+"?viewport-check="+name,wait_until="domcontentloaded",timeout=30000)
        page.wait_for_function("Boolean(window.__strategyDebug)",timeout=20000)
        metrics=page.evaluate("""() => {
          const c=document.querySelector('#gameMap').getBoundingClientRect();
          const shell=document.querySelector('.shell');
          const dock=document.querySelector('.game-dock');
          return {
            canvas:[c.x,c.y,c.width,c.height],
            viewport:[innerWidth,innerHeight],
            shellPosition:getComputedStyle(shell).position,
            dockDisplay:getComputedStyle(dock).display,
            sidebarDisplay:getComputedStyle(document.querySelector('.sidebar')).display,
            pageScroll:[document.documentElement.scrollWidth,document.documentElement.scrollHeight],
            topBar:document.querySelector('.masthead').getBoundingClientRect().toJSON(),
            stats:document.querySelector('.top-stats').getBoundingClientRect().toJSON(),
            dockRect:dock.getBoundingClientRect().toJSON(),
            questCollapsed:document.querySelector('#missionToggle').getAttribute('aria-expanded'),
            questContentsDisplay:getComputedStyle(document.querySelector('#missionContents')).display,
            cssHref:document.querySelector('link[rel="stylesheet"]').href
          };
        }""")
        assert abs(metrics["canvas"][0])<2 and abs(metrics["canvas"][1])<2,(name,metrics)
        assert abs(metrics["canvas"][2]-width)<2,(name,metrics)
        assert abs(metrics["canvas"][3]-height)<2,(name,metrics)
        assert metrics["shellPosition"]=="fixed",(name,metrics)
        assert metrics["dockDisplay"]=="flex" and metrics["sidebarDisplay"]=="none",(name,metrics)
        assert metrics["questCollapsed"]=="false" and metrics["questContentsDisplay"]=="none",(name,metrics)
        assert metrics["stats"]["top"]<metrics["dockRect"]["top"],(name,metrics)
        assert metrics["dockRect"]["top"]>=height*.75,(name,metrics)
        if width<=750 and height>510:
            gap=page.evaluate("""() => document.querySelector('.panel-head').getBoundingClientRect().left -
              document.querySelector('.mission-card').getBoundingClientRect().right""")
            assert gap>=3,(name,"overlapping upper controls",gap)

        assert metrics["pageScroll"][0]<=width+1 and metrics["pageScroll"][1]<=height+1,(name,metrics)
        page.locator('#missionToggle').click()
        assert page.locator('#missionContents').is_visible(),name
        if width<=750 and height>510:
            assert not page.locator('.panel-head').is_visible(),name
        page.locator('#missionToggle').click()
        page.locator('[data-hud-panel="build"]').click()
        assert page.locator(".sidebar").is_visible(),(name,metrics)
        page.locator('[data-build-category="raw"]').click()
        assert page.locator('#buildPanel [data-tool="logger"]').is_visible(),name
        assert not page.locator('#buildPanel [data-tool="mill"]').is_visible(),name
        page.locator('[data-hud-panel="build"]').click()
        assert not page.locator(".sidebar").is_visible(),name
        print(name,metrics,flush=True)
        context.close()
    browser.close()
print("Live GitHub Pages layout validated for all viewport sizes.")
