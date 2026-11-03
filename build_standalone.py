"""Bundle the strategy, CSS, JS and alpha WebP artwork into one offline HTML."""
from pathlib import Path
import re,json,base64
root=Path(__file__).resolve().parent
html=(root/'index.html').read_text('utf8')
html=re.sub(r'<link rel="stylesheet" href="style\.css(?:\?[^"]+)?">','<style>'+ (root/'style.css').read_text('utf8')+'</style>',html)
html=re.sub(r'<script defer src="(?:engine|visual-model|mill-pack|resource-pack|worker-art|painted-motion|profession-actions|profession-frames|ui)\.js(?:\?[^"]+)?"></script>','',html)
assets={p.stem:'data:image/webp;base64,'+base64.b64encode(p.read_bytes()).decode('ascii') for p in sorted((root/'assets').glob('*.webp'))}
assert len(assets)==12
mill_files={'start':'mill-states-start.webp',
            'end':'mill-states-end.webp','parts':'mill-parts.webp'}
mill_assets={name:'data:image/webp;base64,'+
             base64.b64encode((root/'assets/buildings/mill'/filename).read_bytes()).decode('ascii')
             for name,filename in mill_files.items()}
assert set(mill_assets)=={'start','end','parts'}
detail_assets={name:'data:image/webp;base64,'+base64.b64encode(
    (root/'assets/buildings/mill'/filename).read_bytes()).decode('ascii')
    for name,filename in {'body':'mill-detailed-body.webp',
                          'rotor':'mill-detailed-rotor.webp'}.items()}
resources='data:image/webp;base64,'+base64.b64encode(
    (root/'assets/resources/construction-resources.webp').read_bytes()).decode('ascii')
hq_sprite='data:image/webp;base64,'+base64.b64encode(
    (root/'assets/buildings/headquarters/headquarters-level1.webp').read_bytes()).decode('ascii')
painted_people='data:image/webp;base64,'+base64.b64encode(
    (root/'assets/characters/painted-people.webp').read_bytes()).decode('ascii')
logger_atlases={state:'data:image/webp;base64,'+base64.b64encode(\n    (root/'assets/characters/logger'/('logger-'+state+'.webp')).read_bytes()).decode('ascii')\n    for state in ('idle','walk','fell_tree','carry_logs')}\nworker_portraits={p.stem:'data:image/webp;base64,'+base64.b64encode(p.read_bytes()).decode('ascii')
                  for p in sorted((root/'assets/workers').glob('*.webp')) if p.stem!='walk-reference-se'}
scripts=('window.StrategyLoggerAtlases='+json.dumps(logger_atlases,separators=(',',':'))+';\n'+\n         'window.StrategyHQSprite='+json.dumps(hq_sprite)+';\n'+
         'window.StrategyPaintedPeople='+json.dumps(painted_people)+';\n'+
         'window.StrategyWorkerPortraits='+json.dumps(worker_portraits)+';\n'+
         'window.StrategyResourceAtlas='+json.dumps(resources)+';\n'+
         'window.StrategyAssets='+json.dumps(assets,separators=(',',':'))+';\n'+
         'window.StrategyMillAtlases='+json.dumps(mill_assets,separators=(',',':'))+';\n'+
         'window.StrategyMillDetailAssets='+json.dumps(detail_assets,separators=(',',':'))+';\n'+
         (root/'engine.js').read_text('utf8')+'\n;\n'+
         (root/'visual-model.js').read_text('utf8')+'\n;\n'+
         (root/'mill-pack.js').read_text('utf8')+'\n;\n'+
         (root/'resource-pack.js').read_text('utf8')+'\n;\n'+
         (root/'worker-art.js').read_text('utf8')+'\n;\n'+
         (root/'painted-motion.js').read_text('utf8')+'\n;\n'+
         (root/'profession-actions.js').read_text('utf8')+'\n;\n'+
         (root/'profession-frames.js').read_text('utf8')+'\n;\n'+
         (root/'ui.js').read_text('utf8'))
assert '</script' not in scripts.lower()
html=html.replace('</body>','<script>'+scripts+'</script>\n</body>')
(root/'play.html').write_text(html,'utf8')
print('play.html:',(root/'play.html').stat().st_size,'bytes,',len(assets),'embedded image assets')
