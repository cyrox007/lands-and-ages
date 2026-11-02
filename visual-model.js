/* Deterministic 2.5D visual state helpers. Visual-only; saves stay in engine.js. */
(function(root,factory){
  const api=factory();
  if(typeof module==='object'&&module.exports)module.exports=api;
  if(root)root.StrategyVisual=api;
})(typeof globalThis==='object'?globalThis:this,function(){
  'use strict';
  const N=1,E=2,S=4,W=8;
  function roadMask(roads,x,y,width,height){
    if(x<0||y<0||x>=width||y>=height||!roads[y*width+x])return 0;
    let mask=0;
    if(y>0&&roads[(y-1)*width+x])mask|=N;
    if(x<width-1&&roads[y*width+x+1])mask|=E;
    if(y<height-1&&roads[(y+1)*width+x])mask|=S;
    if(x>0&&roads[y*width+x-1])mask|=W;
    return mask;
  }
  function roadKind(mask){
    const bits=[N,E,S,W].filter(d=>mask&d).length;
    if(bits===0)return 'isolated';
    if(bits===1)return 'end';
    if(bits===2)return mask===(N|S)||mask===(E|W)?'straight':'corner';
    return bits===3?'junction':'crossroads';
  }
  // Isometric paving layout: every finished road arm meets its neighbour
  // precisely at the shared half-cell boundary. Stones have no simulation state.
  function cobblestonePlan(mask){
    const directions=[[N,0,-1],[E,1,0],[S,0,1],[W,-1,0]];
    const arms=[];
    for(const [bit,dx,dy] of directions){
      if(!(mask&bit))continue;
      const stones=[];
      for(let row=0;row<5;row++)for(let col=0;col<3;col++){
        stones.push({
          row,col,
          u0:.14+row*.072,u1:.14+(row+1)*.072,
          v0:-.22+col*(.44/3),v1:-.22+(col+1)*(.44/3)
        });
      }
      arms.push({bit,dx,dy,stones});
    }
    const center=[];
    for(let row=0;row<3;row++)for(let col=0;col<3;col++){
      center.push({
        row,col,
        x0:-.22+row*(.44/3),x1:-.22+(row+1)*(.44/3),
        y0:-.22+col*(.44/3),y1:-.22+(col+1)*(.44/3)
      });
    }
    return {arms,center};
  }
  // Only actual completed construction work determines visual stages.
  function constructionStage(site){
    const need=site.required?.boards||0,have=site.goods?.boards||0;
    if(have<need)return 'foundation';
    const ratio=Math.max(0,Math.min(1,(site.progress||0)/Math.max(.001,site.duration||1)));
    if(ratio<.20)return 'foundation';
    if(ratio<.50)return 'frame';
    if(ratio<.78)return 'walls';
    return 'roof';
  }
  // Detailed art phase: material delivery happens BEFORE the foundation
  // grows; each later step is driven by actual builder progress.
  function constructionVisualPhase(site){
    const required=site.required||{},goods=site.goods||{};
    if((goods.boards||0)<(required.boards||0)||
       (goods.stone||0)<(required.stone||0))return 'survey';
    const progress=Math.max(0,Math.min(1,
      (site.progress||0)/Math.max(.001,site.duration||1)));
    if(progress<.18)return 'foundation';
    if(progress<.46)return 'frame';
    if(progress<.77)return 'walls';
    return 'roof';
  }
  // Screen-facing directions; game uses world grid diagonally projected on screen.
  function facing(entity){
    const dest=entity.path?.[entity.segment+1];
    if(!dest)return {direction:'se',moving:false};
    const dx=dest.x-entity.x,dy=dest.y-entity.y;
    if(Math.abs(dx)+Math.abs(dy)<.001)return {direction:'se',moving:false};
    const sx=dx-dy,sy=dx+dy;
    return {direction:(sy<0?'n':'s')+(sx<0?'w':'e'),moving:true};
  }
  // Atlas frames follow actual simulated time and worker state; idle has no motion.
  // Pausing stops animationClock advancement in UI, so both workers freeze in place.
  function animationFrame(state,simulatedSeconds,id=0){
    if(state==='idle')return 0;
    if(state!=='walk'&&state!=='work')return 0;
    if(!Number.isFinite(simulatedSeconds))return 0;
    const fps=state==='work'?9:11;
    return ((Math.floor(Math.max(0,simulatedSeconds)*fps+id*2)%8)+8)%8;
  }
  // A pair of legs moves because of simulated displacement, not wall-clock time.
  function gaitFrame(travelled,cellDistancePerCycle=.68){
    if(!Number.isFinite(travelled)||travelled<0||!Number.isFinite(cellDistancePerCycle)||cellDistancePerCycle<=0)return 0;
    return Math.floor(((travelled/cellDistancePerCycle)%1)*8+1e-8)%8;
  }
  // Cargo is always drawn as a separate resource-specific object.
  // The legacy 'worker-porter-carry' atlas has an unremovable painted sack:
  // using it together with a real cargo draws TWO different loads.
  // Until a blank-handed carrying atlas is generated, use the clean animated
  // porter body for every delivery and draw exactly the current resource.
  function porterAppearance(carrying){
    return {bodySheet:'worker-porter-walk',cargo:carrying?.res||null};
  }
  // Don't animate unpowered, disconnected or resource-starved factories.
  function productionActive(building,connected,ready){
    return Boolean(building && connected && ready && Number.isFinite(building.progress) && building.progress>0 &&
      ['logger','quarry','sawmill','farm','mill','bakery'].includes(building.type));
  }
  return {N,E,S,W,roadMask,roadKind,cobblestonePlan,constructionStage,constructionVisualPhase,facing,animationFrame,gaitFrame,productionActive,porterAppearance};
});