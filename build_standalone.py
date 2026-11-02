"""Bundle the strategy, CSS, JS and alpha WebP artwork into one offline HTML."""
from pathlib import Path
import re,json,base64
root=Path(__file__).resolve().parent
html=(root/'index.html').read_text('utf8')
html=re.sub(r'<link rel="stylesheet" href="style\.css(?:\?[^"]+)?">','<style>'+ (root/'style.css').read_text('utf8')+'</style>',html)
html=re.sub(r'<script defer src="(?:engine|visual-model|mill-pack|ui)\.js(?:\?[^"]+)?"></script>','',html)
assets={p.stem:'data:image/webp;base64,'+base64.b64encode(p.read_bytes()).decode('ascii') for p in sorted((root/'assets').glob('*.webp'))}
assert len(assets)==12
mill_assets={p.stem.replace('mill-','').replace('states-','').replace('-',''):'data:image/webp;base64,'+
             base64.b64encode(p.read_bytes()).decode('ascii')
             for p in sorted((root/'assets/buildings/mill').glob('mill-states-*.webp'))+
               list((root/'assets/buildings/mill').glob('mill-parts.webp'))}
assert set(mill_assets)=={'start','end','parts'}
detail_assets={name:'data:image/webp;base64,'+base64.b64encode(
    (root/'assets/buildings/mill'/filename).read_bytes()).decode('ascii')
    for name,filename in {'body':'mill-detailed-body.webp',
                          'rotor':'mill-detailed-rotor.webp'}.items()}
scripts=('window.StrategyAssets='+json.dumps(assets,separators=(',',':'))+';\n'+
         'window.StrategyMillAtlases='+json.dumps(mill_assets,separators=(',',':'))+';\n'+
         'window.StrategyMillDetailAssets='+json.dumps(detail_assets,separators=(',',':'))+';\n'+
         (root/'engine.js').read_text('utf8')+'\n;\n'+
         (root/'visual-model.js').read_text('utf8')+'\n;\n'+
         (root/'mill-pack.js').read_text('utf8')+'\n;\n'+
         (root/'ui.js').read_text('utf8'))
assert '</script' not in scripts.lower()
html=html.replace('</body>','<script>'+scripts+'</script>\n</body>')
(root/'play.html').write_text(html,'utf8')
print('play.html:',(root/'play.html').stat().st_size,'bytes,',len(assets),'embedded image assets')
