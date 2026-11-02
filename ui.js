/* Strategy 0.4.4 — distance-driven gait, persistent facing and live production effects. */
(function(){
  'use strict';
  const E=window.StrategyEngine,V=window.StrategyVisual;
  if(!E||!V){document.body.textContent='Ошибка: игровые модули не загрузились.';return;}
  const {Game,W,H,DEF,COLORS,id}=E;
  const $=x=>document.getElementById(x);
  const canvas=$('gameMap'),ctx=canvas.getContext('2d',{alpha:false});
  const STORAGE='lands-ages:campaign:v1';
  let restored=null;
  try{restored=Game.restore(localStorage.getItem(STORAGE));}catch(_){/* restricted storage */}
  let game=restored||(window.__strategyBoot==='mission'?new Game().startMission():new Game(1729,'settlement'));
  let selectedCrop='wheat';
  let mode='inspect',paused=false,speed=1,zoom=innerWidth<600?.88:1;
  const camera={x:game.scenario==='settlement'?11.5:17,y:10};
  let width=800,height=500,dpr=1,last=0,lastDraw=0,lastHud=0,lastSave=0,hover=null;
  let pointer=null,toastUntil=0;
  const TRAITS={grass:'#69875d',forest:'#456f54',hills:'#998a6c',water:'#478b9c',ruin:'#ae9c7b'};
  const MATERIAL_COLORS={warehouse:['#b38b55','#dcc497','#7f5f3a'],house:['#8f5f42','#ceb184','#73482f'],logger:['#6f5840','#c5aa7b','#5e4630'],sawmill:['#82624a','#d4b88b','#684b36'],farm:['#8e764d','#d7bf7b','#7e663f'],mill:['#a59a83','#ddd0b0','#7e7360'],bakery:['#9f6c45','#dfc6a0','#865237'],generic:['#8f694e','#d3b186','#6d4f38']};
  const ASSET_NAMES=['warehouse','house','logger','sawmill','farm','mill','bakery','carrier'];
  const sprites={},spriteMasks={};let spritesReady=0;
  for(const name of ASSET_NAMES){
    const img=new Image();sprites[name]=img;
    img.onload=()=>{
      spritesReady++;
      // Low-resolution transparency mask for correct pointer selection of roof
      // and other visible sprite regions, rather than the tile below them.
      const off=document.createElement('canvas');off.width=128;
      off.height=Math.max(1,Math.round(128*img.naturalHeight/img.naturalWidth));
      const octx=off.getContext('2d',{willReadFrequently:true});
      octx.drawImage(img,0,0,off.width,off.height);
      try{spriteMasks[name]={w:off.width,h:off.height,data:octx.getImageData(0,0,off.width,off.height).data};}catch(_){/* Canvas taint fallback: cell picking */}
      const label=$('assetsStatus');if(label)label.textContent='2.5D · '+spritesReady+'/8 объектов';
    };
    img.onerror=()=>{sprites[name]=null;};
    img.src=(window.StrategyAssets&&window.StrategyAssets[name])||('assets/'+name+'.webp');
  }
  // Four atlas sheets contain 8 independently drawn poses x 4 directions.
  // Loaded separately to keep the eight legacy buildings and their selection masks intact.
  const WORKER_FRAME_W=96,WORKER_FRAME_H=128;
  const WORKER_SHEETS=['worker-porter-walk','worker-porter-carry','worker-builder-walk','worker-builder-work'];
  const workerSheets={};let workerSheetsReady=0;
  for(const name of WORKER_SHEETS){
    const img=new Image();workerSheets[name]=img;
    img.onload=()=>{workerSheetsReady++;const label=$('assetsStatus');
      if(label&&spritesReady===8)label.textContent=`2.5D · 8 зданий + ${workerSheetsReady}/4 анимации`;};
    img.onerror=()=>{workerSheets[name]=null;};
    img.src=(window.StrategyAssets&&window.StrategyAssets[name])||('assets/'+name+'.webp');
  }
  let animationClock=0;
  // Transient rendering data, derived from real simulated displacement. Never saved.
  const motion=new Map();
  function updateMotion(){
    const active=new Set();
    for(const [role,people] of [['porter',game.carriers],['builder',game.builders]])for(const e of people){
      const key=role+':'+e.id;active.add(key);
      const prior=motion.get(key)||{x:e.x,y:e.y,distance:0,workTime:0,direction:'se'};
      const distance=Math.hypot(e.x-prior.x,e.y-prior.y);
      const facing=V.facing(e);
      const moving=(role==='porter'?Boolean(e.job):e.phase==='travel')&&facing.moving;
      if(moving&&distance>0&&distance<1.51){
        prior.distance+=distance;
        prior.direction=facing.direction;
      }else if(facing.moving){prior.direction=facing.direction;}
      if(role==='builder'&&e.phase==='work'&&e.site!==null)prior.workTime=animationClock;
      prior.x=e.x;prior.y=e.y;
      motion.set(key,prior);
    }
    for(const key of motion.keys())if(!active.has(key))motion.delete(key);
  }
  function resetMotion(){motion.clear();updateMotion();}

  const facingRow={se:0,sw:1,ne:2,nw:3};
  function workerState(entity,role){
    const face=V.facing(entity);
    const moving=role==='builder'?entity.phase==='travel'&&face.moving:!!entity.job&&face.moving;
    const working=role==='builder'&&entity.phase==='work'&&entity.site!==null;
    const sheet=role==='builder'?(working?'worker-builder-work':'worker-builder-walk'):
      (entity.carrying?'worker-porter-carry':'worker-porter-walk');
    const state=working?'work':moving?'walk':'idle';
    const previous=motion.get(role+':'+entity.id);
    // One 8-pose walking cycle per 0.68 grid cells, matching stride to distance.
    // A worker can no longer march in place or glide with a wall-clock animation.
    const frame=state==='walk'?V.gaitFrame(previous?.distance??0):
      V.animationFrame(state,animationClock,entity.id);
    const direction=face.moving?face.direction:(previous?.direction||'se');
    return {sheet,state,frame,row:facingRow[direction]??0,direction,travelled:previous?.distance||0};
  }
  function workerSprite(entity,role,px,py,size){
    const pose=workerState(entity,role),img=workerSheets[pose.sheet];
    if(!img?.naturalWidth)return false;
    // Character feet stay locked to the simulation tile; only drawn limbs change.
    ctx.drawImage(img,pose.frame*WORKER_FRAME_W,pose.row*WORKER_FRAME_H,
      WORKER_FRAME_W,WORKER_FRAME_H,px-size*.5,py-size*WORKER_FRAME_H/WORKER_FRAME_W,size,size*WORKER_FRAME_H/WORKER_FRAME_W);
    return true;
  }
  const clamp=(x,a,b)=>Math.max(a,Math.min(b,x));
  function persist(){try{localStorage.setItem(STORAGE,game.save());return true;}catch(_){return false;}}
  function notify(s){$('toast').textContent=s;$('toast').classList.add('visible');toastUntil=performance.now()+2800;}
  function selectTool(type){
    mode=type;
    if(innerWidth<=750&&type!=='inspect'&&type!=='field'){
      const container=document.querySelector('.shell');
      if(container)container.dataset.panel='none';
      document.querySelectorAll('[data-hud-panel]').forEach(btn=>btn.setAttribute('aria-expanded','false'));
    }
    for(const b of document.querySelectorAll('[data-tool]')){
      const active=b.dataset.tool===type;b.classList.toggle('active',active);b.setAttribute('aria-pressed',String(active));
    }
    const tool=type==='inspect'?'Осмотр: коснись клетки карты.':type==='excavate'?'Исследование: выбери древние руины (15 монет).':
      type==='road'?'Дорога: 2 монеты + 1 доска. Носильщики доставят материал, строители проложат путь.':
      type==='field'?'Поле: выбери культуру, затем свободный участок до 3 клеток от фермы. Урожай растёт только с назначенным земледельцем.':
      'Заложить стройку: '+DEF[type].name+' — '+DEF[type].cost+' монет, '+DEF[type].boards+' досок; доставка и работа занимают время.';
    $('mapHint').textContent=tool;
  }
  function zoomBy(delta){zoom=clamp(zoom+delta,.62,2.20);$('zoomLabel').textContent=Math.round(zoom*100)+'%';}
  function tileSize(){return 82*zoom;}
  function tileHeight(){return tileSize()/2;}
  // The logical simulation remains on its original square grid. Only the
  // projection changes; pointer-to-world inversion uses the exact dual basis.
  function screen(x,y){
    const halfW=tileSize()/2,quarterH=tileHeight()/2;
    return {x:width/2+(x-y-camera.x+camera.y)*halfW,
      y:height/2+(x+y-camera.x-camera.y)*quarterH};
  }
  function worldAt(px,py){
    const u=(px-width/2)/(tileSize()/2),v=(py-height/2)/(tileHeight()/2);
    return {x:camera.x+(u+v)/2,y:camera.y+(v-u)/2};
  }
  function cellAt(px,py){const c=worldAt(px,py);return {x:Math.floor(c.x),y:Math.floor(c.y)};}
  function resize(){
    const box=canvas.getBoundingClientRect();width=Math.max(1,box.width);height=Math.max(1,box.height);
    dpr=Math.min(window.devicePixelRatio||1,window.innerWidth<750?1.5:2);
    canvas.width=Math.round(width*dpr);canvas.height=Math.round(height*dpr);
    ctx.setTransform(dpr,0,0,dpr,0,0);$('zoomLabel').textContent=Math.round(zoom*100)+'%';
    draw();
  }
  function poly(points,fill,stroke=null,lineWidth=1){
    ctx.beginPath();ctx.moveTo(points[0][0],points[0][1]);
    for(let k=1;k<points.length;k++)ctx.lineTo(points[k][0],points[k][1]);
    ctx.closePath();ctx.fillStyle=fill;ctx.fill();
    if(stroke){ctx.strokeStyle=stroke;ctx.lineWidth=lineWidth;ctx.stroke();}
  }
  function diamond(cx,cy,scale=1,fill='#5f7e54',stroke=null){
    const rx=tileSize()*scale/2,ry=tileHeight()*scale/2;
    poly([[cx,cy-ry],[cx+rx,cy],[cx,cy+ry],[cx-rx,cy]],fill,stroke,.75);
  }
  function line(x,y,tx,ty,color,size){ctx.strokeStyle=color;ctx.lineWidth=size;ctx.lineCap='round';ctx.beginPath();ctx.moveTo(x,y);ctx.lineTo(tx,ty);ctx.stroke();}
  function blob(x,y,rx,ry,fill,alpha=1){ctx.save();ctx.globalAlpha=alpha;ctx.fillStyle=fill;ctx.beginPath();ctx.ellipse(x,y,rx,ry,0,0,Math.PI*2);ctx.fill();ctx.restore();}
  function rectIso(cx,cy,w,hgt,fill,stroke=null){poly([[cx-w/2,cy],[cx,cy-hgt/2],[cx+w/2,cy],[cx,cy+hgt/2]],fill,stroke,.8);}
  // Static painterly tile atlases are created once per terrain variation, not every frame.
  const tileArtCache=new Map();
  function tileArt(type,variation){
    const key=type+':'+variation;
    if(tileArtCache.has(key))return tileArtCache.get(key);
    const c=document.createElement('canvas');c.width=160;c.height=80;
    const g=c.getContext('2d');
    const base={grass:'#64865c',forest:'#476a50',water:'#427f91',hills:'#9e8a6b',ruin:'#aa9676'}[type]||'#64865c';
    const colors={grass:['#8cad76','#426b48','#71945d','#bfd090'],forest:['#668b61','#2c583f','#517851','#8fa874'],water:['#71aab4','#356e8a','#5895a6','#a0d2ce'],hills:['#c4ab85','#887252','#aa9170','#d5c4a0'],ruin:['#d1bea0','#8f795e','#b09e7b','#e1d2b3']}[type]||[];
    let seed=((variation+1)*1597334677^type.length*38127)>>>0;
    const rand=()=>((seed=(Math.imul(seed,1664525)+1013904223)>>>0)/4294967296);
    g.beginPath();g.moveTo(80,0);g.lineTo(160,40);g.lineTo(80,80);g.lineTo(0,40);g.closePath();g.clip();
    g.fillStyle=base;g.fillRect(0,0,160,80);
    for(let i=0;i<235;i++){
      const x=rand()*160,y=rand()*80,w=1+rand()*12,h=.4+rand()*3;
      g.globalAlpha=.035+rand()*(type==='water'?.15:.12);
      g.fillStyle=colors[i%colors.length];g.beginPath();g.ellipse(x,y,w,h,rand()*.7-.35,0,Math.PI*2);g.fill();
    }
    g.globalAlpha=1;
    if(type==='grass'||type==='forest')for(let i=0;i<16;i++){
      const x=rand()*160,y=rand()*80;
      g.strokeStyle=i%3?'#e0c99c55':'#1f473550';g.lineWidth=.7+rand();
      g.beginPath();g.moveTo(x,y+3);g.lineTo(x-2+rand()*4,y-1-rand()*5);g.stroke();
    }
    if(type==='water')for(let i=0;i<9;i++){
      const x=rand()*160,y=rand()*80;
      g.strokeStyle='#c5ece1';g.globalAlpha=.13+rand()*.3;g.lineWidth=1+rand();
      g.beginPath();g.moveTo(x,y);g.lineTo(x+9+rand()*18,y-2);g.stroke();
    }
    g.globalAlpha=1;
    tileArtCache.set(key,c);return c;
  }
  function terrainTile(x,y){
    const type=game.tiles[id(x,y)].terrain,p=screen(x+.5,y+.5),t=tileSize(),h=tileHeight();
    const variation=((x*19+y*31+x*y*7)%7+7)%7;
    const art=tileArt(type,variation);
    // Tiny overlap hides sub-pixel gaps from camera motion / fractional zoom.
    ctx.drawImage(art,p.x-t*.502,p.y-h*.502,t*1.004,h*1.004);
    if(type==='hills'){
      poly([[p.x-t*.22,p.y+h*.06],[p.x-t*.015,p.y-h*.43],[p.x+t*.22,p.y+h*.06],[p.x,p.y+h*.22]],'#a48c70');
      poly([[p.x-t*.22,p.y+h*.06],[p.x-t*.015,p.y-h*.43],[p.x,p.y+h*.22]],'#cdb38c');
      line(p.x-t*.06,p.y-h*.23,p.x-t*.015,p.y-h*.38,'#e8d9b565',1.4*zoom);
    }
  }
  function drawField(f){
    const p=screen(f.x+.5,f.y+.5),t=tileSize(),h=tileHeight();
    diamond(p.x,p.y,.94,'#70543a','#a7885d');
    const rows=5,cols=5,seed=f.crop==='vegetables'?'#81a95b':f.crop==='barley'?'#e3c17b':'#dac16d';
    for(let j=0;j<rows;j++)for(let k=0;k<cols;k++){
      const u=(k+.5)/cols,v=(j+.5)/rows;
      const x=p.x+(u-v)*t*.40,y=p.y+(u+v-1)*h*.40;
      if(f.stage==='clearing'){line(x-t*.02,y,x+t*.02,y+h*.02,'#ad8b64',1.3*zoom);continue;}
      const tall=f.stage==='ripe'?.18:f.stage==='growing'?.13:.06;
      const sway=f.stage==='ripe'?Math.sin(animationClock*1.4+k+j)*t*.009:0;
      line(x,y,x+sway,y-h*tall,f.stage==='sown'?'#729254':seed,Math.max(.8,1.3*zoom));
      if(f.stage==='ripe')blob(x+sway,y-h*tall,t*.017,h*.04,seed,.95);
    }
    if(f.stage==='ripe'){
      ctx.fillStyle='#fff1b9';ctx.textAlign='center';ctx.font=`bold ${Math.max(9,11*zoom)}px sans-serif`;
      ctx.fillText('✓',p.x,p.y-h*.64);
    }
  }
  function bush(x,y,variation){
    const p=screen(x+.5,y+.5),t=tileSize(),h=tileHeight();
    const dx=((variation%5)-2)*t*.09,dy=((variation%3)-1)*h*.12;
    blob(p.x+dx,p.y+dy+h*.08,t*.15,h*.06,'#182c25',.3);
    for(let j=0;j<4;j++){
      const ox=(j-1.5)*t*.055;
      blob(p.x+dx+ox,p.y+dy-h*(.06+(j%2)*.08),t*.085,h*.16,
        j%2?'#52794e':'#739963',.9);
    }
  }
  function tree(x,y,variant=0){
    const p=screen(x+.5,y+.5),t=tileSize(),h=tileHeight();
    const scale=.95+((variant%5)-2)*.04,lean=(variant%3-1)*t*.03;
    blob(p.x,p.y+h*.14,t*.21*scale,h*.12*scale,'#10241c',.28);
    ctx.fillStyle='#6a4a2e';ctx.fillRect(p.x-t*.028+lean,p.y-h*.47,t*.056,h*.54);
    ctx.fillStyle='#553a24';ctx.fillRect(p.x-t*.012+lean,p.y-h*.54,t*.024,h*.10);
    const greens=[['#345f47',-.30,-.36,.18,.14],['#497857',.08,-.40,.20,.15],['#5f8b62',-.10,-.56,.24,.17],['#3c6b4d',.18,-.58,.17,.13],['#6e9a69',0,-.72,.20,.14]];
    for(const [c,ox,oy,rx,ry] of greens){blob(p.x+t*ox*scale+lean,p.y+h*oy*scale,t*rx*scale,h*ry*scale,c,.98);}    
    for(let i=0;i<3;i++)blob(p.x+t*((variant+i*7)%9-4)*.02,p.y-h*(.30+i*.11),t*.03,h*.02,'#8fb47e',.35);
  }
  function ruins(x,y){
    const p=screen(x+.5,y+.5),t=tileSize(),h=tileHeight();
    diamond(p.x,p.y,.75,'#b9aa8b','#7c6956');
    ctx.fillStyle='#d7c7a8';ctx.fillRect(p.x-t*.21,p.y-h*.84,t*.10,h*.76);
    ctx.fillStyle='#bfa985';ctx.fillRect(p.x-t*.02,p.y-h*.62,t*.14,h*.48);
    ctx.fillStyle='#e1d5bb';ctx.fillRect(p.x-t*.24,p.y-h*.96,t*.18,h*.12);
    ctx.fillStyle='#d2c09b';ctx.fillRect(p.x+t*.12,p.y-h*.70,t*.20,h*.12);
    line(p.x-t*.18,p.y-h*.20,p.x+t*.05,p.y-h*.28,'#8a755c',1.3*zoom);
    if(!game.excavated.includes(id(x,y))){
      ctx.fillStyle='#fff0ac';ctx.textAlign='center';ctx.font=`bold ${Math.max(10,15*zoom)}px sans-serif`;
      ctx.fillText('?',p.x+t*.32,p.y-h*.53);
    }
  }
  function road(x,y){
    const mask=V.roadMask(game.roads,x,y,W,H),p=screen(x+.5,y+.5),t=tileSize(),h=tileHeight();
    // Every arm is oriented in the *projected grid* rather than screen cardinal axes.
    // Each adjacent cell draws the other half of this same road strip.
    const dirs=[[V.N,0,-1],[V.E,1,0],[V.S,0,1],[V.W,-1,0]];
    const halfWidth=t*.091;
    for(const [bit,dx,dy] of dirs){
      if(!(mask&bit))continue;
      const np=screen(x+.5+dx,y+.5+dy);
      const ex=(p.x+np.x)/2,ey=(p.y+np.y)/2;
      const vx=ex-p.x,vy=ey-p.y,len=Math.hypot(vx,vy)||1;
      const nx=-vy/len,ny=vx/len;
      const strip=(w,color)=>poly([
        [p.x+nx*w,p.y+ny*w],[ex+nx*w,ey+ny*w],
        [ex-nx*w,ey-ny*w],[p.x-nx*w,p.y-ny*w]],color);
      strip(halfWidth*1.13,'#594735');strip(halfWidth,'#a98a62');
      strip(halfWidth*.77,'#c7aa80');
      for(let j=1;j<4;j++){
        const k=j/4,qx=p.x+vx*k,qy=p.y+vy*k;
        line(qx-nx*halfWidth*.76,qy-ny*halfWidth*.76,qx+nx*halfWidth*.76,qy+ny*halfWidth*.76,'#8a765c88',.7*zoom);
      }
    }
    const kind=V.roadKind(mask);
    diamond(p.x,p.y,kind==='isolated'?.33:.385,'#b89a73','#77604788');
    diamond(p.x,p.y,kind==='crossroads'?.25:.21,'#d4b68c');
    if(kind==='end'){
      blob(p.x,p.y,t*.037,h*.027,'#e0cba8',.75);
    }
  }
  function sprite(name,cx,cy,w,h){
    const img=sprites[name];if(!img||!img.complete||!img.naturalWidth)return false;
    ctx.drawImage(img,cx-w/2,cy-h,w,h);return true;
  }
  const BUILDING_SCALES={warehouse:1.21,house:1.17,logger:1.16,sawmill:1.2,farm:1.19,mill:1.24,bakery:1.18};
  function buildingRect(b){
    const p=screen(b.x+.5,b.y+.5),t=tileSize(),h=tileHeight();
    const w=t*(BUILDING_SCALES[b.type]||1.60),img=sprites[b.type];
    const height=img&&img.naturalWidth?w*img.naturalHeight/img.naturalWidth:t*1.4;
    return {x:p.x-w/2,y:p.y+h*.33-height,w,h:height,p};
  }
  function pickBuilding(px,py){
    const sorted=game.buildings.slice().sort((a,b)=>(b.x+b.y)-(a.x+a.y));
    for(const b of sorted){
      const rect=buildingRect(b),u=(px-rect.x)/rect.w,v=(py-rect.y)/rect.h;
      if(u<0||u>=1||v<0||v>=1)continue;
      const mask=spriteMasks[b.type];
      if(!mask)continue;
      const ix=Math.min(mask.w-1,Math.floor(u*mask.w)),iy=Math.min(mask.h-1,Math.floor(v*mask.h));
      if(mask.data[(iy*mask.w+ix)*4+3]>70)return b;
    }
    return null;
  }
  // Visual-only work cycles: no resource creation, no simulation mutations.
  // Use animationClock, which freezes on pause. An idle building has no motion.
  function drawProductionEffect(b,p,t,h){
    const clock=animationClock;
    if(b.type==='bakery'){
      // Hearth glow from the entrance; chimney smoke follows the real baking cycle.
      const warm=.20+.10*Math.sin(clock*9+b.id);
      blob(p.x+t*.18,p.y-h*.09,t*.10,h*.12,'#ffb35a',warm);
      for(let i=0;i<4;i++){
        const f=(clock*.28+i*.25)%1;
        blob(p.x-t*.11+t*.055*f,p.y-t*.91-t*.19*f,t*(.035+.025*f),h*(.055+.035*f),'#eee2c9',.28*(1-f));
      }
    }else if(b.type==='sawmill'){
      // Blade reciprocates above the log; dust only when wood is being processed.
      const k=Math.sin(clock*13+b.id),bladeX=p.x+t*(.12+.09*k);
      line(bladeX,p.y-h*.28,bladeX+t*.06,p.y-h*.55,'#eef0df',Math.max(1.3,2*zoom));
      line(bladeX+t*.015,p.y-h*.25,bladeX+t*.08,p.y-h*.50,'#5c6260',Math.max(.8,1*zoom));
      for(let i=0;i<4;i++){
        const f=(clock*.62+i*.25)%1;
        blob(p.x+t*(.17+.08*f),p.y-h*(.12+.15*f),t*.011,h*.024,'#e8c58c',.55*(1-f));
      }
    }else if(b.type==='mill'){
      // Flour particles at the open grindstone. Static painted sails remain
      // static until a separate blade-free mill artwork can support real rotation.
      for(let i=0;i<4;i++){
        const f=(clock*.46+i*.25)%1;
        blob(p.x-t*(.12-.11*f),p.y-h*(.29+.08*f),t*.013,h*.018,'#f9e4bb',.70*(1-f));
      }
      const ring=.055+.016*Math.sin(clock*8);
      blob(p.x-t*.015,p.y-h*.21,t*ring,h*.035,'#ddbd8a',.42);
    }else if(b.type==='quarry'){
      const swing=Math.sin(clock*8+b.id);
      const toolX=p.x+t*(.13+.055*swing),toolY=p.y-h*(.32+.065*Math.abs(swing));
      line(p.x+t*.11,p.y-h*.06,toolX,toolY,'#a17643',Math.max(1.4,2.4*zoom));
      line(toolX-t*.08,toolY-h*.04,toolX+t*.08,toolY+h*.01,'#e0e1d9',Math.max(1.3,2.2*zoom));
      for(let i=0;i<3;i++){
        const f=(clock*.75+i/3)%1;
        blob(p.x+t*(.14+.03*i+f*.06),p.y-h*(.1+.10*f),t*.012,h*.022,'#c6ba9b',.55*(1-f));
      }
    }else if(b.type==='farm'){
      const sway=Math.sin(clock*3+b.id);
      for(let i=0;i<5;i++){
        const x=p.x+t*(-.25+i*.125),y=p.y+h*(.12+(i%2)*.035);
        line(x,y,x+t*(sway*.028),y-h*(.22+(i%3)*.025),'#d5ae53',Math.max(.9,1.45*zoom));
      }
    }else if(b.type==='logger'){
      const swing=Math.sin(clock*9+b.id);
      line(p.x+t*.27,p.y+h*.1,p.x+t*(.29+.075*swing),p.y-h*.19,'#bd8f54',Math.max(1.4,2.4*zoom));
      line(p.x+t*(.29+.075*swing),p.y-h*.19,p.x+t*(.36+.075*swing),p.y-h*.21,'#dde1d4',Math.max(2,3.3*zoom));
    }
  }
  function drawBuilding(b){
    const {w:renderedWidth,h:imageHeight,p}=buildingRect(b),t=tileSize(),h=tileHeight(),connected=game.connected(b);
    diamond(p.x,p.y,.75,'#263d3180');
    if(b.type==='quarry'){
      diamond(p.x,p.y,.72,'#716c60','#c8b894');
      for(let k=0;k<6;k++){
        const ox=((k%3)-1)*t*.17,oy=Math.floor(k/3)*h*.16;
        poly([[p.x+ox-t*.10,p.y+oy],[p.x+ox-t*.02,p.y+oy-h*.22],[p.x+ox+t*.10,p.y+oy-h*.12],[p.x+ox+t*.15,p.y+oy+h*.09]],
          ['#a9a99f','#c1bcb0','#888b84'][k%3],'#55564f',1);
      }
    }else if(!sprite(b.type,p.x,p.y+h*.33,renderedWidth,imageHeight)){
      diamond(p.x,p.y-.23*t,.84,COLORS[b.type]);
      ctx.textAlign='center';ctx.font=`bold ${Math.max(12,t*.32)}px sans-serif`;ctx.fillStyle='#f8eac6';
      ctx.fillText(DEF[b.type].symbol,p.x,p.y-h*.12);
    }
    const active=V.productionActive(b,connected,game.readyToProduce(b));
    if(active)drawProductionEffect(b,p,t,h);
    if(!connected){
      ctx.textAlign='center';ctx.font=`bold ${Math.max(14,t*.28)}px sans-serif`;
      ctx.fillStyle='#ffd1a0';ctx.strokeStyle='#703f2b';ctx.lineWidth=3;
      ctx.strokeText('!',p.x+t*.29,p.y-h*.25);ctx.fillText('!',p.x+t*.29,p.y-h*.25);
    }
  }
  function drawSite(site){
    const pos=screen(site.x+.5,site.y+.5),t=tileSize(),h=tileHeight();
    const need=site.required.boards||0,have=site.goods.boards||0;
    const requiredStone=site.required.stone||0,deliveredStone=site.goods.stone||0,materialsReady=have>=need&&deliveredStone>=requiredStone;
    const ratio=clamp(site.progress/site.duration,0,1),stage=V.constructionStage(site);
    const isRoad=site.type==='road';
    diamond(pos.x,pos.y,.89,'#705b46','#d7b98a',1.4);
    poly([[pos.x-t*.34,pos.y-h*.05],[pos.x,pos.y-h*.28],[pos.x+t*.30,pos.y-h*.04],[pos.x,pos.y+h*.19]],isRoad?'#aa8d66':'#5a5042');
    if(isRoad){
      const width=.14+.34*ratio;
      diamond(pos.x,pos.y,width,'#be9d73','#ead2a8',1);
      line(pos.x-t*.18,pos.y-h*.03,pos.x+t*.18,pos.y+h*.03,'#7e6448',Math.max(1.4,2.1*zoom));
      for(let i=0;i<3;i++)blob(pos.x-t*.11+i*t*.09,pos.y+h*(.02+i*.01),t*.025,h*.015,'#735b41',.45);
      if(!materialsReady){line(pos.x-t*.24,pos.y-h*.14,pos.x+t*.12,pos.y-h*.02,'#d9be91',1.4);}
    }else{
      const rect=buildingRect({type:site.type,x:site.x,y:site.y});
      const [wall,roof,shadow]=(MATERIAL_COLORS[site.type]||MATERIAL_COLORS.generic);
      // stage 1: foundation and marked corners
      diamond(pos.x,pos.y,.70,'#8e7154','#e0c494',1);
      line(pos.x-t*.24,pos.y-h*.08,pos.x-t*.10,pos.y-h*.22,'#d8be8e',1.5);
      line(pos.x+t*.24,pos.y-h*.08,pos.x+t*.10,pos.y-h*.22,'#d8be8e',1.5);
      line(pos.x-t*.24,pos.y+h*.08,pos.x-t*.10,pos.y+h*.22,'#d8be8e',1.5);
      line(pos.x+t*.24,pos.y+h*.08,pos.x+t*.10,pos.y+h*.22,'#d8be8e',1.5);
      if(stage==='frame'||stage==='walls'||stage==='roof'){
        const wallH=rect.h*(ratio<.45?.14:ratio<.72?.28:.40);
        ctx.fillStyle=wall;ctx.fillRect(rect.x+rect.w*.20,rect.y+rect.h*.62-wallH,rect.w*.44,wallH);
        ctx.fillStyle=shadow;ctx.fillRect(rect.x+rect.w*.64,rect.y+rect.h*.66-wallH,rect.w*.16,wallH*.92);
      }
      if(stage==='frame'||stage==='walls'||stage==='roof'){
        // frame and scaffolding
        for(const s of [-1,1]){
          const x=pos.x+s*t*.20;
          line(x,pos.y+h*.16,x,pos.y-h*.72,'#b9854a',Math.max(2,3*zoom));
          line(x,pos.y-h*.52,x-s*t*.11,pos.y-h*.30,'#d3a563',Math.max(1.5,2.4*zoom));
        }
        line(pos.x-t*.20,pos.y-h*.62,pos.x+t*.20,pos.y-h*.62,'#d7af73',Math.max(1.6,2.8*zoom));
        line(pos.x-t*.20,pos.y-h*.35,pos.x+t*.20,pos.y-h*.35,'#d7af73',Math.max(1.6,2.8*zoom));
      }
      if(stage==='roof'){
        poly([[rect.x+rect.w*.18,rect.y+rect.h*.56],[rect.x+rect.w*.47,rect.y+rect.h*.36],[rect.x+rect.w*.80,rect.y+rect.h*.54],[rect.x+rect.w*.51,rect.y+rect.h*.69]],roof,'#f1ddbb',1);
      }
      if(stage==='roof'&&ratio>.94&&sprites[site.type]?.naturalWidth){
        ctx.save();ctx.globalAlpha=.55+.35*(ratio-.86)/.14;
        sprite(site.type,rect.p.x,rect.p.y+h*.33,rect.w,rect.h);
        ctx.restore();
      }
    }
    if(have>0){const count=Math.min(4,have);
      for(let k=0;k<count;k++)line(pos.x-t*.34,pos.y+h*(.17+k*.035),pos.x-t*.12,pos.y+h*(.06+k*.035),'#e0bd7a',Math.max(2,3*zoom));
    }
    const label=have<need?`▥ ${have}/${need}`:deliveredStone<requiredStone?`◆ ${deliveredStone}/${requiredStone}`:`⚒ ${Math.floor(ratio*100)}%`;
    ctx.save();ctx.textAlign='center';ctx.font=`bold ${Math.max(10,12.5*zoom)}px sans-serif`;
    ctx.lineWidth=3;ctx.strokeStyle='#29261d';ctx.fillStyle='#fff4cf';
    ctx.strokeText(label,pos.x,pos.y-tileHeight()*(isRoad?.75:2.0));
    ctx.fillText(label,pos.x,pos.y-tileHeight()*(isRoad?.75:2.0));ctx.restore();
    const bw=Math.max(26,t*.72),by=pos.y+h*(isRoad?.46:.22);
    ctx.fillStyle='#24332b';ctx.fillRect(pos.x-bw/2,by,bw,Math.max(3,5*zoom));
    ctx.fillStyle=!materialsReady?'#c5a369':'#a5df9a';
    ctx.fillRect(pos.x-bw/2,by,bw*(!materialsReady?Math.min(1,(have+deliveredStone)/Math.max(1,need+requiredStone))*.32:.32+.68*ratio),Math.max(3,5*zoom));
  }
  function drawBuilder(b){
    const p=screen(b.x+.5,b.y+.5),t=tileSize(),h=tileHeight();
    const footY=p.y+h*.26;
    // 100% frame-sheet playback. No static character sprite or global bobbing.
    if(!workerSprite(b,'builder',p.x,footY,t*.48)){
      blob(p.x,footY-h*.24,t*.10,h*.20,'#dda93f');
    }
  }
  function drawCarrier(c){
    const p=screen(c.x+.5,c.y+.5),t=tileSize(),h=tileHeight();
    const footY=p.y+h*.26;
    if(!workerSprite(c,'porter',p.x,footY,t*.48)){
      blob(p.x,footY-h*.23,t*.10,h*.20,'#aa8255');
    }
    if(c.carrying){
      ctx.fillStyle='#f9e0a1';ctx.textAlign='center';
      ctx.font=`bold ${Math.max(8,t*.14)}px sans-serif`;
      ctx.fillText(String(c.carrying.amount),p.x+t*.24,p.y-h*.46);
    }
  }
  function draw(){
    ctx.setTransform(dpr,0,0,dpr,0,0);
    ctx.fillStyle='#233f38';ctx.fillRect(0,0,width,height);
    // Camera-agnostic culling: project map coordinates, discard tiles outside
    // the viewport with an extended margin for tall buildings and trees.
    const margin=tileSize()*2.6;
    const visible=(p)=>p.x>-margin&&p.y>-margin*1.5&&p.x<width+margin&&p.y<height+margin;
    for(let y=0;y<H;y++)for(let x=0;x<W;x++){
      const pos=screen(x+.5,y+.5);if(visible(pos))terrainTile(x,y);
    }
    for(const field of game.fields||[])if(visible(screen(field.x+.5,field.y+.5)))drawField(field);
    for(let y=0;y<H;y++)for(let x=0;x<W;x++)if(game.roads[id(x,y)]){
      if(visible(screen(x+.5,y+.5)))road(x,y);
    }
    // Sorted by the ground-point depth: buildings, vegetation and moving
    // porters occlude each other in a coherent painter's-order projection.
    const objects=[];
    for(let y=0;y<H;y++)for(let x=0;x<W;x++){
      const tile=game.tiles[id(x,y)];if(!visible(screen(x+.5,y+.5)))continue;
      if(tile.terrain==='forest'&&tile.wood>0)objects.push({x,y,depth:x+y+.65,type:'forest'});
      if(tile.terrain==='ruin')objects.push({x,y,depth:x+y+.65,type:'ruin'});
       if(tile.terrain==='grass'&&!game.roads[id(x,y)]&&!game.buildingAt(x,y)&&!game.siteAt(x,y)&&!game.fieldAt(x,y)&&
          (x*31+y*47+x*y*11)%13===0)objects.push({x,y,depth:x+y+.60,type:'bush'});
    }
    for(const b of game.buildings)if(visible(screen(b.x+.5,b.y+.5)))objects.push({x:b.x,y:b.y,depth:b.x+b.y+.75,type:'building',b});
    for(const site of game.construction)if(visible(screen(site.x+.5,site.y+.5)))objects.push({x:site.x,y:site.y,depth:site.x+site.y+.73,type:'site',site});
    for(const b of game.builders)if(visible(screen(b.x+.5,b.y+.5)))objects.push({x:b.x,y:b.y,depth:b.x+b.y+.90,type:'builder',b});
    for(const c of game.carriers)if(visible(screen(c.x+.5,c.y+.5)))objects.push({x:c.x,y:c.y,depth:c.x+c.y+.90,type:'carrier',c});
    objects.sort((a,b)=>a.depth-b.depth||a.x-b.x);
    for(const o of objects){
      if(o.type==='forest')tree(o.x,o.y,(o.x*5+o.y*9)%6);
      else if(o.type==='ruin')ruins(o.x,o.y);
       else if(o.type==='bush')bush(o.x,o.y,(o.x*3+o.y*7)%11);
      else if(o.type==='building')drawBuilding(o.b);
      else if(o.type==='site')drawSite(o.site);
      else if(o.type==='builder')drawBuilder(o.b);
      else drawCarrier(o.c);
    }
    const mission=game.missionProgress();
    if(mission.target&&mission.stage!==3){
      const spot=screen(mission.target.x+.5,mission.target.y+.5);
      const pulse=.62+.24*Math.sin(animationClock*.8);
      diamond(spot.x,spot.y,1.1,'#e0d38055','#f8eea7',3);
      ctx.textAlign='center';ctx.font=`bold ${Math.max(10,16*zoom)}px sans-serif`;
      ctx.fillStyle='#fff4cb';ctx.globalAlpha=pulse;
      ctx.fillText(mission.stage===0?'▼ ПОЧИНИТЬ':mission.stage===1?'▼ ПЕКАРНЯ':'▼ ПОСТРОИТЬ ДОМ',spot.x,spot.y-tileSize()*.50);
      ctx.globalAlpha=1;
    }
    if(hover&&hover.x>=0&&hover.x<W&&hover.y>=0&&hover.y<H){
      const p=screen(hover.x+.5,hover.y+.5);
      const buildable=mode==='road'||DEF[mode]?game.canBuild(mode,hover.x,hover.y).ok:true;
      diamond(p.x,p.y,1,buildable?'#b3ffca37':'#ff886635',buildable?'#dbf8bd':'#ffae86');
    }
    ctx.strokeStyle='#d3d0a840';ctx.lineWidth=2;ctx.strokeRect(.5,.5,width-1,height-1);
  }
  const PATHS={wealth:{name:'Торговля',type:'market',stat:'wealth',desc:'Построй рынок у дороги и дождись первой продажи хлеба.'},
    science:{name:'Наука',type:'academy',stat:'science',desc:'Построй академию у дороги и обеспечь её досками.'},
    culture:{name:'Культура',type:'theatre',stat:'culture',desc:'Построй театр у дороги и обеспечь его хлебом.'},
    diplomacy:{name:'Дипломатия',type:'embassy',stat:'diplomacy',desc:'Построй посольство у дороги и доставь туда ресурсы.'},
    military:{name:'Оборона',type:'barracks',stat:'military',desc:'Построй казармы у дороги и обеспечь снабжение.'}};
  let stageShown=-2,winShown=false;
  function updateMission(){
    const m=game.missionProgress(),card=$('missionCard'),focus=$('missionFocus'),choose=$('missionChoices'),tool=$('missionTool');
    if(!m.active){
      if(game.scenario==='settlement'){
        const milestones=[
          ['Построй лесничество и назначь лесоруба',game.buildings.some(b=>b.type==='logger'&&(game.staff[b.id]||0)>0)],
          ['Построй каменоломню, проложи дорогу и назначь рабочего',game.buildings.some(b=>b.type==='quarry'&&(game.staff[b.id]||0)>0)],
          ['Построй ферму и назначь земледельца',game.buildings.some(b=>b.type==='farm'&&(game.staff[b.id]||0)>0)],
          ['Заложи поле и собери первый урожай',game.fields.some(f=>f.harvests>0)],
          ['Доставь камень и овощи на общий склад',game.warehouse().goods.stone>0&&game.warehouse().goods.vegetables>0],
          ['Построй мельницу и пекарню, испеки первый хлеб',game.stats.baked>=3]
        ];
        const complete=milestones.filter(m=>m[1]).length,upcoming=milestones.find(m=>!m[1]);
        $('missionStep').textContent='РАЗВИТИЕ ПОСЕЛЕНИЯ · '+complete+'/6';
        $('missionTitle').textContent=upcoming?'Следующий шаг':'Первое хозяйство создано!';
        $('missionText').textContent=upcoming?upcoming[0]:'Все первичные ресурсы и переработка работают. Продолжай развивать поселение.';
        $('missionDetail').textContent='Нажми на предприятие для назначения работников. Дороги и материалы должны физически соединять производство и склад.';
        $('missionFill').style.width=(complete/6*100)+'%';
        if(stageShown>=0&&complete>stageShown)notify('Цель поселения выполнена: '+complete+'/6');
        stageShown=complete;
      }else{
        $('missionStep').textContent='СВОБОДНАЯ ИГРА';
        $('missionTitle').textContent='Развивай поселение';
        $('missionText').textContent='Строй дороги, прокладывай цепочки снабжения и исследуй мир.';
        $('missionDetail').textContent='Тестовая кампания доступна через системное меню.';
        $('missionFill').style.width='100%';
      }
      focus.hidden=true;tool.hidden=true;choose.hidden=true;return;
    }
    if(m.stage!==stageShown){
      if(stageShown>=0&&m.stage>stageShown)notify(m.done?'Победа! Первое испытание пройдено.':'Задача выполнена! Следующий шаг открыт.');
      stageShown=m.stage;
    }
    $('missionStep').textContent=m.done?'ИСПЫТАНИЕ ПРОЙДЕНО':`ИСПЫТАНИЕ ДОЛИНЫ · ЭТАП ${m.stage+1} / 4`;
    $('missionFill').style.width=(m.done?100:(m.stage*25+m.progress*25))+'%';
    let title='',detail='',desc='',targetTool='inspect';
    if(m.done){title='Долина восстановлена!';desc='Жители обеспечены хлебом, а государство выбрало путь развития. Можешь продолжать строить или начать заново.';
      detail='Поздравляем с первой победой в «Землях и эпохах». Функции симуляции остаются доступны.';}
    else if(m.stage===0){title='Почини главную дорогу';desc='Заложи участок на подсвеченной клетке между мельницей и пекарней. Носильщики должны привезти доску, а строители — завершить дорогу.';
      const site=game.siteAt(17,10);
      detail=site?`Стройка: ${game.siteStage(site)}. Доски ${site.goods.boards}/${site.required.boards}, возведено ${Math.floor(site.progress/site.duration*100)}%.`:
        'Выбери дорогу, затем подсвеченный ромб. Стоимость — 2 монеты и 1 доска. Дорога заработает после окончания стройки.';
      targetTool='road';}
    else if(m.stage===1){title='Верни хлеб на стол';desc='Пекарня снова соединена с дорогой. Носильщики должны привезти муку и дрова, после чего испечь 3 хлеба.';
      detail=`Испечено: ${Math.min(3,game.stats.baked)} / 3. Ускорь время до ×4, если хочешь. Следи за движением носильщиков.`;}
    else if(m.stage===2){title='Расширь поселение';desc='Заложи второй дом у дороги. Снабди стройку досками и дождись окончания работы строителей.';
      const site=game.construction.find(s=>s.type==='house');
      detail=site?`Дом строится: ${game.siteStage(site)}. Доски ${site.goods.boards}/${site.required.boards}; готовность ${Math.floor(site.progress/site.duration*100)}%.`:
        'Выбери дом, потом свободную клетку рядом с дорогой (подсвечена рекомендуемая точка).';targetTool='house';}
    else if(m.stage===3&&!m.chosen){title='Выбери путь государства';desc='У тебя есть работающая экономика и жильё. Какое направление станет первым приоритетом?' ;
      detail='Выбор повлияет на финальную задачу испытания. Все пять путей останутся доступны для развития после победы.';}
    else{const path=PATHS[m.chosen];title='Первый шаг: '+path.name;desc=path.desc;targetTool=path.type;
      const site=game.construction.find(s=>s.type===path.type);
      detail=site?`Возводится ${DEF[path.type].name.toLowerCase()}: ${game.siteStage(site)}. Доски ${site.goods.boards}/${site.required.boards}, готовность ${Math.floor(site.progress/site.duration*100)}%.`:
        `Результат развития: ${game.stats.developed[m.chosen]}/3. Построй ${DEF[path.type].name.toLowerCase()} у дороги, дождись завершения и первой продукции.`;}
    $('missionTitle').textContent=title;$('missionText').textContent=desc;$('missionDetail').textContent=detail;
    focus.hidden=!m.target||m.done;tool.hidden=m.done||(m.stage===3&&!m.chosen)||m.stage===1;
    tool.textContent=targetTool==='road'?'═ ВЫБРАТЬ ДОРОГУ':targetTool==='house'?'⌂ ВЫБРАТЬ ДОМ':`✦ ВЫБРАТЬ: ${DEF[targetTool]?.name||''}`;
    tool.dataset.actionTool=targetTool;
    choose.hidden=!(m.stage===3&&!m.chosen);
    if(!choose.hidden&&!choose.children.length){for(const [key,path] of Object.entries(PATHS)){
      const btn=document.createElement('button');btn.type='button';btn.textContent=path.name;
      btn.addEventListener('click',()=>{if(game.choosePath(key)){persist();updateMission();notify('Направление выбрано: '+path.name);}});choose.append(btn);
    }}
    if(m.done&&!winShown){winShown=true;persist();}
  }
  function focusMission(){const m=game.missionProgress();if(!m.target)return;camera.x=m.target.x+.5;camera.y=m.target.y+.5;draw();}
  $('missionFocus').addEventListener('click',focusMission);
  $('missionTool').addEventListener('click',()=>{selectTool($('missionTool').dataset.actionTool);if(game.missionProgress().stage!==3)focusMission();});
  function updateHUD(){
    const hud=game.hud();updateMission();
    const sites=$('constructionList');sites.replaceChildren();
    if(!hud.sites.length){const p=document.createElement('p');p.textContent='Пока нет строек. Выбери дорогу или здание на карте.';sites.append(p);}
    for(const site of hud.sites){
      const row=document.createElement('div');row.className='construction-item';
      const name=document.createElement('b');name.textContent=site.type==='road'?'═ Дорога':DEF[site.type].name;
      const where=document.createElement('span');where.textContent=`(${site.x},${site.y}) · ${site.state}`;
      const progress=document.createElement('div');progress.className='site-meter';
      const fill=document.createElement('span');
      fill.style.width=`${Math.round(site.delivered<site.boards||site.deliveredStone<site.stone?(site.delivered+site.deliveredStone)/Math.max(1,site.boards+site.stone)*30:30+70*site.progress/site.duration)}%`;
      progress.append(fill);
      const details=document.createElement('small');details.textContent=`Доски ${site.delivered}/${site.boards}${site.stone?' · Камень '+site.deliveredStone+'/'+site.stone:''} · работа ${Math.floor(site.progress/site.duration*100)}%`;
      row.append(name,where,progress,details);sites.append(row);
    }
    $('dayStat').textContent=hud.day;$('coinStat').textContent=hud.coins;
    $('popStat').textContent=hud.population;$('moraleStat').textContent=hud.morale+'%';
    for(const k of ['science','culture','diplomacy','military'])$(k+'Stat').textContent=hud[k];
    for(const k of ['logs','boards','stone','grain','vegetables','flour','bread'])$(k+'Stock').textContent=hud.goods[k];
     $('freeWorkers').textContent=hud.scenario==='settlement'?hud.freeWorkers:'—';
     $('workforceHint').textContent=hud.scenario==='settlement'?'Свободные жители: '+hud.freeWorkers+' · Носильщики: '+game.carriers.length+' · Строители: '+game.builders.length:'Тестовая миссия: работники назначены автоматически';
    $('taxSlider').value=hud.tax;$('taxValue').textContent=hud.tax+'%';
    const list=$('eventLog');list.replaceChildren();
    for(const event of game.log.slice(0,6)){
      const li=document.createElement('li'),time=document.createElement('time'),description=document.createElement('span');
      time.textContent='День '+event.day;description.textContent=event.text;li.append(time,description);list.append(li);
    }
  }
  function inspectAt(x,y){const data=game.inspect(x,y);$('tileInfo').replaceChildren();
    const title=document.createElement('strong'),desc=document.createElement('span');
     title.textContent=data.title;desc.textContent=data.desc;$('tileInfo').append(title,desc);
     if(game.scenario==='settlement'){
       shell.dataset.panel='news';
       document.querySelectorAll('[data-hud-panel]').forEach(btn=>btn.setAttribute('aria-expanded',String(btn.dataset.hudPanel==='news')));
     }
     const b=game.buildingAt(x,y);
     if(b&&game.scenario==='settlement'&&DEF[b.type].workers){
       const row=document.createElement('div');row.className='staff-controls';
       const label=document.createElement('span');label.textContent='Рабочие: '+(game.staff[b.id]||0)+' / '+DEF[b.type].workers;
       const minus=document.createElement('button');minus.type='button';minus.textContent='−';minus.setAttribute('aria-label','Снять работника');
       const plus=document.createElement('button');plus.type='button';plus.textContent='+';plus.setAttribute('aria-label','Назначить работника');
       for(const [btn,d] of [[minus,-1],[plus,1]])btn.addEventListener('click',()=>{
         const result=game.assignWorkers(b.id,(game.staff[b.id]||0)+d);
         if(!result.ok)notify(result.error);else persist();
         inspectAt(x,y);updateHUD();
       });
       row.append(label,minus,plus);$('tileInfo').append(row);
     }
  }
  function act(cell){
    const {x,y}=cell;if(x<0||x>=W||y<0||y>=H){notify('За пределами карты');return;}
    if(mode==='inspect'){inspectAt(x,y);return;}
    if(mode==='excavate'){
      const result=game.excavate(x,y);if(!result.ok)notify(result.error);
      else{notify('Найденная печать пополнила знания и культурное наследие.');persist();}
      inspectAt(x,y);updateHUD();return;
    }
    const result=mode==='field'?game.placeField(x,y,selectedCrop):game.build(mode,x,y);
    if(!result.ok)notify(result.error);
    else{
       notify(mode==='field'?'Поле заложено. Назначь земледельца на ближайшую ферму.':
         mode==='road'?'Дорожная стройка заложена — ждём носильщика и строителей.':DEF[mode].name+': площадка заложена, материалы в пути.');
       inspectAt(x,y);persist();
     }
    updateHUD();
  }
  function canvasPointer(e){const rect=canvas.getBoundingClientRect();return {x:e.clientX-rect.left,y:e.clientY-rect.top};}
  canvas.addEventListener('pointerdown',e=>{
    if(pointer)return;
    if(e.pointerType==='touch'&&e.cancelable)e.preventDefault();
    const p=canvasPointer(e);pointer={id:e.pointerId,x:p.x,y:p.y,prevX:p.x,prevY:p.y,moved:false};
    try{canvas.setPointerCapture(e.pointerId);}catch(_){}
  });
  canvas.addEventListener('pointermove',e=>{
    const p=canvasPointer(e);
    if(!pointer){hover=cellAt(p.x,p.y);return;}
    if(e.pointerId!==pointer.id)return;
    if(Math.hypot(p.x-pointer.x,p.y-pointer.y)>7)pointer.moved=true;
    if(pointer.moved){const deltaX=(p.x-pointer.prevX)/(tileSize()/2);
      const deltaY=(p.y-pointer.prevY)/(tileHeight()/2);
      camera.x=clamp(camera.x-(deltaX+deltaY)/2,-3,W+3);
      camera.y=clamp(camera.y-(deltaY-deltaX)/2,-3,H+3);hover=null;}
    pointer.prevX=p.x;pointer.prevY=p.y;
  });
  const endPointer=e=>{
    if(!pointer||e.pointerId!==pointer.id)return;
    const p=canvasPointer(e);if(!pointer.moved&&e.type==='pointerup'){
      const hit=mode==='inspect'?pickBuilding(p.x,p.y):null;
      act(hit?{x:hit.x,y:hit.y}:cellAt(p.x,p.y));
    }
    pointer=null;
  };
  canvas.addEventListener('pointerup',endPointer);
  canvas.addEventListener('pointercancel',endPointer);
  canvas.addEventListener('lostpointercapture',()=>{pointer=null;});
  canvas.addEventListener('pointerleave',()=>{if(!pointer)hover=null;});
  canvas.addEventListener('wheel',e=>{if(e.cancelable)e.preventDefault();zoomBy(e.deltaY<0?.12:-.12);},{passive:false});
  document.querySelectorAll('[data-tool]').forEach(b=>b.addEventListener('click',()=>selectTool(b.dataset.tool)));
  $('surveyBtn').addEventListener('click',()=>selectTool('excavate'));
  const shell=document.querySelector('.shell');
  document.querySelectorAll('[data-hud-panel]').forEach(b=>b.addEventListener('click',()=>{
    const panel=b.dataset.hudPanel;
    shell.dataset.panel=shell.dataset.panel===panel?'none':panel;
    document.querySelectorAll('[data-hud-panel]').forEach(btn=>btn.setAttribute('aria-expanded',String(shell.dataset.panel===btn.dataset.hudPanel)));
  }));
  document.querySelectorAll('[data-crop]').forEach(b=>b.addEventListener('click',()=>{
    selectedCrop=b.dataset.crop;
    document.querySelectorAll('[data-crop]').forEach(btn=>btn.setAttribute('aria-pressed',String(btn===b)));
    selectTool('field');
    if(innerWidth<=750)shell.dataset.panel='none';
  }));
  document.querySelectorAll('[data-pan]').forEach(b=>b.addEventListener('click',()=>{
    const delta={left:[-2,0],right:[2,0],up:[0,-2],down:[0,2]}[b.dataset.pan];
    camera.x=clamp(camera.x+delta[0],-1,W+1);camera.y=clamp(camera.y+delta[1],-1,H+1);
  }));
  $('zoomIn').addEventListener('click',()=>zoomBy(.2));$('zoomOut').addEventListener('click',()=>zoomBy(-.2));
  $('taxSlider').addEventListener('input',e=>{game.setTax(Number(e.target.value));$('taxValue').textContent=game.tax+'%';persist();});
  function setPaused(value){paused=value;$('pauseBtn').textContent=paused?'▶ ПРОДОЛЖИТЬ':'Ⅱ ПАУЗА';$('mapOverlay').hidden=!paused;}
  $('pauseBtn').addEventListener('click',()=>setPaused(!paused));
  $('speedBtn').addEventListener('click',()=>{speed=speed===1?2:speed===2?4:1;$('speedBtn').textContent='×'+speed;});
  $('saveBtn').addEventListener('click',()=>notify(persist()?'Игра сохранена в этом браузере.':'Сохранение недоступно: проверь разрешения браузера.'));
  $('helpBtn').addEventListener('click',()=>{setPaused(true);$('helpDialog').showModal();});
  $('closeHelp').addEventListener('click',()=>$('helpDialog').close());
  $('resetBtn').addEventListener('click',()=>{
    if(!window.confirm('Начать новую карту? Текущий прогресс будет потерян.'))return;
    game=new Game().startMission();shell.dataset.panel='none';resetMotion();stageShown=-2;winShown=false;selectTool('road');camera.x=17;camera.y=10;setPaused(false);persist();updateHUD();notify('Начато первое испытание!');
  });
  $('freeBtn').addEventListener('click',()=>{
    if(!window.confirm('Начать свободную игру без задач? Текущий прогресс будет заменён.'))return;
    game=new Game(1729,'settlement');shell.dataset.panel='none';resetMotion();stageShown=-2;winShown=false;camera.x=11.5;camera.y=10;selectTool('inspect');setPaused(false);persist();updateHUD();notify('Свободное поселение основано.');
  });
  window.addEventListener('keydown',e=>{
    if(e.target.closest('input,button,dialog'))return;
    if(e.code==='Space'){e.preventDefault();setPaused(!paused);}
    if(e.key==='Escape')selectTool('inspect');
    if(e.key==='+'||e.key==='=')zoomBy(.15);
    if(e.key==='-')zoomBy(-.15);
    const pan={ArrowLeft:[-1,0],ArrowRight:[1,0],ArrowUp:[0,-1],ArrowDown:[0,1]}[e.code];
    if(pan){e.preventDefault();camera.x=clamp(camera.x+pan[0],-1,W+1);camera.y=clamp(camera.y+pan[1],-1,H+1);}
  });
  document.addEventListener('visibilitychange',()=>{if(document.hidden){setPaused(true);persist();}});
  window.addEventListener('blur',()=>{setPaused(true);persist();});
  window.addEventListener('beforeunload',persist);
  new ResizeObserver(resize).observe(canvas);
  window.addEventListener('resize',resize);
  resetMotion();resize();selectTool(!restored&&game.mission.active?'road':'inspect');updateHUD();
  if(restored)notify('Прогресс поселения восстановлен.');
  function loop(now){
    if(!last)last=now;
    const dt=Math.max(0,Math.min(.08,(now-last)/1000));last=now;
    if(!paused){game.step(dt*speed);animationClock+=dt*speed;updateMotion();}
    // At most 60 render updates per second; simulation time uses actual frame delta.
    if(now-lastDraw>=16.6){draw();lastDraw=now;}
    if(now-lastHud>=450){updateHUD();lastHud=now;}
    if(now-lastSave>=15000){persist();lastSave=now;}
    if(toastUntil&&now>toastUntil){$('toast').classList.remove('visible');toastUntil=0;}
    requestAnimationFrame(loop);
  }
  requestAnimationFrame(loop);
  window.__strategyDebug=()=>({day:game.day,coins:game.coins,scenario:game.scenario,staff:{...game.staff},freeWorkers:game.availableWorkers(),fields:game.fields.map(f=>({...f})),resources:{...game.warehouse().goods},
    buildings:game.buildings.length,sites:game.construction.map(s=>({type:s.type,x:s.x,y:s.y,boards:s.goods.boards,required:s.required.boards,progress:s.progress,duration:s.duration})),builders:game.builders.map(b=>({site:b.site,phase:b.phase,x:b.x,y:b.y})),carriers:game.carriers.filter(c=>c.job).length,science:game.science,
    culture:game.culture,diplomacy:game.diplomacy,military:game.military,mission:game.missionProgress(),paused,mode,zoom,projection:'isometric',visualVersion:'0.5.0-dev',roadKind:(x,y)=>V.roadKind(V.roadMask(game.roads,x,y,W,H)),stageAt:(x,y)=>{const site=game.siteAt(x,y);return site?V.constructionStage(site):null;},tileCache:tileArtCache.size,spritesReady,workerSheetsReady,animationClock,productionAt:(type)=>{const b=game.buildings.find(v=>v.type===type);return b?V.productionActive(b,game.connected(b),game.readyToProduce(b)):false;},workerPose:(role,index=0)=>workerState((role==='builder'?game.builders:game.carriers)[index],role),workerAtlas:(role,mode)=>{const img=workerSheets[`worker-${role}-${mode}`];return img?.naturalWidth?{width:img.naturalWidth,height:img.naturalHeight}:null;},screen:(x,y)=>screen(x+.5,y+.5),step:(n)=>{for(let i=0;i<n*10;i++){game.step(.1);animationClock+=.1;updateMotion();}updateHUD();draw();}});
})();