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
      V.porterAppearance(entity.carrying).bodySheet;
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
    if(innerWidth<=750&&type!=='field'){
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
  // All elevated sprites cast light from the upper-left towards lower-right.
  // Transparent layered gradients add volume without expensive canvas filters.
  function castShadow(x,y,t,h,scale=1,strength=.3){
    ctx.save();
    ctx.translate(x+t*.23*scale,y+h*.33*scale);
    ctx.rotate(-.15);
    const rx=t*.55*scale,ry=h*.27*scale;
    const g=ctx.createRadialGradient(0,0,1,0,0,rx);
    g.addColorStop(0,'rgba(15,30,24,'+strength+')');
    g.addColorStop(.53,'rgba(17,35,26,'+(strength*.55)+')');
    g.addColorStop(1,'rgba(17,35,26,0)');
    ctx.fillStyle=g;ctx.scale(1,ry/rx);
    ctx.beginPath();ctx.ellipse(0,0,rx,rx,0,0,Math.PI*2);ctx.fill();
    ctx.restore();
  }
  // Natural ground is rendered ONCE as a single world-sized raster.
  // No modulo/repeating 384px pattern and no per-cell grass diamonds:
  // hidden logical cells are used only for gameplay and interactions.
  const tileArtCache=new Map(); // Legacy diagnostic: should remain empty.
  const BASE_TILE=82;
  const groundSurface=document.createElement('canvas');
  groundSurface.width=Math.ceil((W+H)*BASE_TILE/2);
  groundSurface.height=Math.ceil((W+H)*BASE_TILE/4);
  let groundSeed=null;
  function groundPoint(x,y){
    return {x:(H+x-y)*BASE_TILE/2,y:(x+y)*BASE_TILE/4};
  }
  function clipWorld(){
    const outline=[screen(0,0),screen(W,0),screen(W,H),screen(0,H)];
    ctx.beginPath();ctx.moveTo(outline[0].x,outline[0].y);
    for(let k=1;k<outline.length;k++)ctx.lineTo(outline[k].x,outline[k].y);
    ctx.closePath();ctx.clip();
  }
  function paintGround(){
    const g=groundSurface.getContext('2d');
    const seedValue=(game.seed|0)>>>0;
    let state=(seedValue^0x6bd87243)>>>0;
    const rand=()=>((state=(Math.imul(state,1664525)+1013904223)>>>0)/4294967296);
    const gw=groundSurface.width,gh=groundSurface.height;
    g.clearRect(0,0,gw,gh);
    // A single clipping polygon makes even the map edges independent of cells.
    g.beginPath();
    for(const [i,p] of [[0,groundPoint(0,0)],[1,groundPoint(W,0)],
      [2,groundPoint(W,H)],[3,groundPoint(0,H)]]){
      if(i===0)g.moveTo(p.x,p.y);else g.lineTo(p.x,p.y);
    }
    g.closePath();g.save();g.clip();
    g.fillStyle='#6f8d61';g.fillRect(0,0,gw,gh);
    const wash=(x,y,rx,ry,rgb,opacity)=>{
      g.save();g.translate(x,y);g.scale(rx,ry);
      const gradient=g.createRadialGradient(0,0,.06,0,0,1);
      gradient.addColorStop(0,'rgba('+rgb+','+opacity+')');
      gradient.addColorStop(.48,'rgba('+rgb+','+(opacity*.52)+')');
      gradient.addColorStop(1,'rgba('+rgb+',0)');
      g.fillStyle=gradient;g.fillRect(-1,-1,2,2);
      g.restore();
    };
    // Broad overlapping vegetation and dry-ground patterns intentionally
    // cross tile boundaries. All positions are seeded in continuous space.
    for(let i=0;i<155;i++){
      const x=rand()*gw,y=rand()*gh,r=35+rand()*145;
      const tint=['38,85,55','157,160,101','92,126,76','115,100,68','165,163,111'][i%5];
      wash(x,y,r,r*(.38+rand()*.6),tint,.10+rand()*.13);
    }
    // Biome influence is a feathered region, not an individual grass tile.
    // A forest cell only locates a soft canopy footprint with irregular offset.
    for(let y=0;y<H;y++)for(let x=0;x<W;x++){
      const tile=game.tiles[id(x,y)];
      if(tile.terrain!=='forest'&&tile.terrain!=='hills')continue;
      const p=groundPoint(x+.5+(rand()-.5)*.68,y+.5+(rand()-.5)*.68);
      const radius=BASE_TILE*(tile.terrain==='forest'?1.0:1.22);
      wash(p.x,p.y,radius,radius*.48,
        tile.terrain==='forest'?'33,76,44':'135,121,91',
        tile.terrain==='forest'?.19:.15);
    }
    // Thousands of varied small natural details, with no grid iteration.
    for(let k=0;k<11000;k++){
      const x=rand()*gw,y=rand()*gh,length=.9+rand()*5.5;
      g.globalAlpha=.08+rand()*.23;
      g.strokeStyle=k%7===0?'#dfd8a3':k%3===0?'#315f41':'#a1b585';
      g.lineWidth=.4+rand()*.8;
      g.beginPath();g.moveTo(x,y);
      g.quadraticCurveTo(x+rand()*3-1.5,y-length*.48,
        x+rand()*4-2,y-length);g.stroke();
    }
    for(let k=0;k<430;k++){
      const x=rand()*gw,y=rand()*gh,r=.7+rand()*2.5;
      g.globalAlpha=.12+rand()*.2;
      g.fillStyle=k%3?'#bdab82':'#53614a';
      g.beginPath();g.ellipse(x,y,r,r*.45,rand()*Math.PI,0,Math.PI*2);g.fill();
    }
    g.globalAlpha=1;g.restore();
    groundSeed=game.seed|0;
  }
  function drawGround(){
    if(groundSeed!==(game.seed|0))paintGround();
    const origin=screen(0,0);
    ctx.drawImage(groundSurface,origin.x-H*BASE_TILE*zoom/2,origin.y,
      groundSurface.width*zoom,groundSurface.height*zoom);
  }
  function landscapePatches(){
    // Soft geology stains live in the base terrain; individual stone deposits
    // are depth-sorted tall objects so they are visible and cast real shadows.
    const t=tileSize(),h=tileHeight();
    for(let y=0;y<H;y++)for(let x=0;x<W;x++){
      const tile=game.tiles[id(x,y)];
      if(tile.terrain!=='hills')continue;
      const p=screen(x+.5,y+.5);
      blob(p.x,p.y,t*.52,h*.35,'#897d67',.20);
      for(let k=0;k<5;k++){
        const xx=p.x+t*(Math.sin(x*17+y*29+k*7)*.36);
        const yy=p.y+h*(Math.cos(y*11+x*7+k*3)*.26);
        blob(xx,yy,t*.018,h*.026,'#d1c1a3',.28);
      }
    }
  }
  function rockDeposit(x,y){
    const tile=game.tiles[id(x,y)],stock=Math.max(0,tile.stone||0);
    if(stock===0)return;
    const t=tileSize(),h=tileHeight(),p=screen(x+.5,y+.5);
    const abundance=Math.max(.36,Math.min(1,stock/55));
    const shapes=Math.max(2,Math.ceil(abundance*5));
    castShadow(p.x,p.y+h*.14,t,h,1.42,.46);
    // An asymmetric cluster of tall boulders: highlight / lit side /
    // shaded side / dark fissures, with coarse scree around the base.
    const offsets=[[-.30,.07,.70],[-.05,-.09,1.16],[.26,.04,.81],
      [-.16,.25,.67],[.22,.24,.53]];
    for(let i=0;i<shapes;i++){
      const [ox,oy,size]=offsets[i],cx=p.x+t*ox,base=p.y+h*oy;
      const w=t*(.20+.13*size),z=h*(.50+.48*size)*Math.min(1,.4+abundance*.7);
      const left=[cx-w*.57,base-h*.04],right=[cx+w*.68,base+h*.08];
      const top=[cx-w*.10,base-z],ridge=[cx+w*.26,base-z*.76];
      poly([left,top,ridge,[cx+w*.11,base-h*.06]],i%2?'#7d8580':'#8c8a7d','#505c55',.95*zoom);
      poly([[cx+w*.11,base-h*.06],ridge,right,[cx+w*.34,base+h*.08]],
        i%2?'#555f5b':'#616962','#46514d',.85*zoom);
      poly([left,[cx-w*.36,base-z*.52],top,[cx+w*.11,base-z*.61]],
        i%2?'#bbc0af':'#d1cab8',null);
      line(top[0]-w*.08,top[1]+h*.06,cx-w*.32,base-z*.44,'#eee3ca',1.15*zoom);
      line(cx+w*.16,base-z*.40,cx+w*.30,base-z*.21,'#424e49',1.25*zoom);
      line(cx-w*.05,base-z*.29,cx+w*.035,base-z*.11,'#67726b',.85*zoom);
    }
    for(let i=0;i<11;i++){
      const dx=Math.sin(i*8.7+x+y)*t*.52,dy=Math.cos(i*5.7+y)*h*.33;
      const rr=t*(.015+(i%4)*.009);
      poly([[p.x+dx-rr,p.y+dy],[p.x+dx-rr*.1,p.y+dy-h*.08],
        [p.x+dx+rr,p.y+dy+h*.02]],i%3?'#a4a399':'#d4c7b1');
    }
    if(stock<18)blob(p.x,p.y+h*.1,t*.18,h*.09,'#4d5046',.18);
  }
  const waterGroupCache=new WeakMap();
  function waterGroups(){
    if(waterGroupCache.has(game))return waterGroupCache.get(game);
    const seen=new Set(),groups=[];
    for(let y=0;y<H;y++)for(let x=0;x<W;x++){
      const start=id(x,y);
      if(seen.has(start)||game.tiles[start].terrain!=='water')continue;
      const cells=[],queue=[[x,y]];seen.add(start);
      for(let k=0;k<queue.length;k++){
        const [cx,cy]=queue[k];cells.push([cx,cy]);
        for(const [nx,ny] of [[cx-1,cy],[cx+1,cy],[cx,cy-1],[cx,cy+1]]){
          if(nx<0||ny<0||nx>=W||ny>=H||seen.has(id(nx,ny))||
            game.tiles[id(nx,ny)].terrain!=='water')continue;
          seen.add(id(nx,ny));queue.push([nx,ny]);
        }
      }
      groups.push(cells);
    }
    waterGroupCache.set(game,groups);return groups;
  }
  function waterOutline(cells,t,h,spread=1){
    const candidates=[];
    for(const [x,y] of cells){
      const p=screen(x+.5,y+.5);
      for(let i=0;i<16;i++){
        const theta=i*Math.PI/8;
        const irregular=1+.045*Math.sin(theta*3+x*4+y*6);
        candidates.push({x:p.x+Math.cos(theta)*t*.54*spread*irregular,
          y:p.y+Math.sin(theta)*h*.57*spread*irregular});
      }
    }
    candidates.sort((a,b)=>a.x-b.x||a.y-b.y);
    const cross=(o,a,b)=>(a.x-o.x)*(b.y-o.y)-(a.y-o.y)*(b.x-o.x);
    const hull=[];
    for(const p of candidates){
      while(hull.length>=2&&cross(hull[hull.length-2],hull[hull.length-1],p)<=0)hull.pop();
      hull.push(p);
    }
    const n=hull.length;hull.pop();const lower=n-1;
    for(let k=candidates.length-2;k>=0;k--){
      const p=candidates[k];
      while(hull.length>=lower+2&&cross(hull[hull.length-2],hull[hull.length-1],p)<=0)hull.pop();
      hull.push(p);
    }
    hull.pop();return hull;
  }
  function waterPath(outline){
    if(outline.length<3)return;
    ctx.beginPath();
    const mid=(a,b)=>({x:(a.x+b.x)/2,y:(a.y+b.y)/2});
    const start=mid(outline[outline.length-1],outline[0]);
    ctx.moveTo(start.x,start.y);
    for(let i=0;i<outline.length;i++){
      const p=outline[i],next=outline[(i+1)%outline.length],m=mid(p,next);
      ctx.quadraticCurveTo(p.x,p.y,m.x,m.y);
    }
    ctx.closePath();
  }
  function drawWaterBodies(){
    const t=tileSize(),h=tileHeight();
    for(const cells of waterGroups()){
      const outer=waterOutline(cells,t,h,1.20);
      waterPath(outer);ctx.fillStyle='#846f53';ctx.globalAlpha=.42;ctx.fill();ctx.globalAlpha=1;
      const outline=waterOutline(cells,t,h,1.04);
      waterPath(outline);
      const minY=Math.min(...outline.map(p=>p.y)),maxY=Math.max(...outline.map(p=>p.y));
      const grad=ctx.createLinearGradient(0,minY,0,maxY);
      grad.addColorStop(0,'#4d9ca2');grad.addColorStop(.5,'#367f8f');grad.addColorStop(1,'#215d72');
      ctx.fillStyle=grad;ctx.fill();ctx.strokeStyle='#b2b38a';ctx.lineWidth=Math.max(2,4*zoom);ctx.stroke();
      ctx.save();waterPath(outline);ctx.clip();
      for(const [x,y] of cells){
        const p=screen(x+.5,y+.5),phase=animationClock*1.9+(x*13+y*7);
        for(let k=0;k<3;k++){
          const sx=p.x-t*.33+k*t*.17+Math.sin(phase+k)*t*.027;
          const sy=p.y+h*(k-1)*.20+Math.sin(phase*.7+k)*h*.05;
          line(sx,sy,sx+t*(.14+.04*(k%2)),sy-h*.036,'#b9e3d6',
             Math.max(.65,(1.4+.15*k)*zoom));
        }
        blob(p.x-t*.12+Math.sin(phase)*t*.025,p.y+h*.04,t*.32,h*.19,'#9ac4b9',.06);
      }
      ctx.restore();
      for(let i=0;i<outline.length;i+=Math.max(3,Math.floor(outline.length/13))){
        const p=outline[i],v=i+cells.length;
        if(v%3===0)continue;
        // Reeds and shoreline stones belong to the shoreline, not a square tile.
        blob(p.x,p.y+h*.01,t*.045,h*.027,v%4?'#b0a58c':'#5c675b',.9);
        for(let k=0;k<3;k++){
          const dx=(k-1)*t*.012,offset=Math.sin(v+k*2)*t*.012;
          line(p.x+dx,p.y,p.x+dx+offset,p.y-h*(.23+k*.03),'#8da66f',Math.max(.8,1.4*zoom));
        }
      }
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
  // Cached 2.5D trees: birch, oak and pine have different silhouettes,
  // independent sapling/young/mature/old/stump/regrowth sprites. Only the
  // small wind sway is redrawn per frame; trunks and foliage are rasterized once.
  const treeSpriteCache=new Map();
  function treeSprite(species,stage,variation){
    const key=species+':'+stage+':'+variation;
    if(treeSpriteCache.has(key))return treeSpriteCache.get(key);
    const c=document.createElement('canvas');c.width=196;c.height=240;
    const g=c.getContext('2d');g.lineCap='round';
    let seed=(variation*18741+species.length*1327+stage.length*79)>>>0;
    const rand=()=>((seed=(Math.imul(seed,1664525)+1013904223)>>>0)/4294967296);
    const path=(points,fill)=>{
      g.beginPath();g.moveTo(...points[0]);
      for(const p of points.slice(1))g.lineTo(...p);
      g.closePath();g.fillStyle=fill;g.fill();
    };
    const ellipse=(x,y,rx,ry,color)=>{
      g.fillStyle=color;g.beginPath();g.ellipse(x,y,rx,ry,0,0,Math.PI*2);g.fill();
    };
    const stump=stage==='stump'||stage==='regrowing';
    const small=stage==='sapling'||stage==='regrowing';
    const width=stump?17:stage==='sapling'?4:stage==='young'?8:stage==='old'?18:13;
    const top=stump?211:stage==='sapling'?140:stage==='young'?107:stage==='old'?48:72;
    const trunk=species==='birch'?'#d1c9ae':'#715039';
    const grad=g.createLinearGradient(98-width/2,0,98+width/2,0);
    grad.addColorStop(0,species==='birch'?'#7c8074':'#483326');
    grad.addColorStop(.35,trunk);grad.addColorStop(.72,species==='birch'?'#f3ead1':'#97714a');
    grad.addColorStop(1,'#46372c');
    path([[91,233],[90-width*.38,top+16],[95-width*.22,top],[102+width*.30,top+3],
      [106+width*.45,232],[100,230]],grad);
    // Visible growth rings after an actual felling.
    if(stump){
      ellipse(97,top+1,width*.72,5,'#a68660');
      ellipse(97,top+1,width*.45,3,'#d3b48b');
      ellipse(97,top+1,width*.18,1.5,'#806544');
      if(stage==='regrowing'){
        g.strokeStyle='#487d42';g.lineWidth=3;
        g.beginPath();g.moveTo(108,231);g.quadraticCurveTo(113,212,110,201);g.stroke();
        ellipse(105,207,8,4,'#729e5c');ellipse(116,204,8,5,'#8dab68');
      }
    }else{
      if(species==='birch')for(let k=0;k<5;k++){
        const y=top+24+k*(216-top)/5;
        g.strokeStyle='#56574c';g.lineWidth=2.4;
        g.beginPath();g.moveTo(96-width*.3,y);g.lineTo(100+width*.12,y+4);g.stroke();
      }
      // Uneven branches remain legible between foliage patches.
      for(let i=0;i<7;i++){
        const by=top+30+i*(190-top)/8,side=i%2?-1:1;
        g.strokeStyle=species==='birch'?'#858474':'#675039';
        g.lineWidth=Math.max(2,width*.3-i*.23);
        g.beginPath();g.moveTo(99,by+12);
        g.quadraticCurveTo(99+side*(19+rand()*9),by-5,
          99+side*(25+rand()*18),by-20-rand()*12);g.stroke();
      }
      if(species==='pine'){
        for(let layer=5;layer>=0;layer--){
          const cy=top+23+layer*25,spread=(24+layer*7)*(stage==='sapling'?.6:1);
          path([[98,cy-40],[98-spread*.65,cy+7],[98-spread,cy+18],
            [98,cy+11],[98+spread,cy+18],[98+spread*.65,cy+7]],
            layer%2?'#305b40':'#416a48');
          for(let k=0;k<16;k++){
            const px=98+(rand()-.5)*spread*1.45,py=cy-10+rand()*27;
            g.strokeStyle=k%3?'#689266':'#9aaa77';g.globalAlpha=.38;
            g.lineWidth=1;g.beginPath();g.moveTo(px,py);g.lineTo(px-3,py-7);g.stroke();
          }g.globalAlpha=1;
        }
      }else{
        const crown=species==='birch'?['#7ca16d','#a1b47c','#578866','#c0c391']:
          ['#365e42','#4e7850','#72965d','#9eaf72'];
        const radius=stage==='sapling'?26:stage==='young'?43:stage==='old'?70:59;
        for(let layer=0;layer<3;layer++){
          const y=top+36+layer*23;
          for(let k=0;k<11;k++){
            const angle=(k/11)*Math.PI*2+rand()*.2,rad=radius*(.25+rand()*.54);
            const px=98+Math.cos(angle)*rad,py=y+Math.sin(angle)*rad*.52;
            const rx=radius*(.28+rand()*.15),ry=rx*.65;
            const gradient=g.createRadialGradient(px-rx*.35,py-ry*.45,2,px,py,rx*1.1);
            gradient.addColorStop(0,crown[(k+2)%4]);
            gradient.addColorStop(.65,crown[(k+layer)%4]);
            gradient.addColorStop(1,layer===2?'#294c39':'#47684b');
            ellipse(px,py,rx,ry,gradient);
          }
        }
        for(let k=0;k<80;k++){
          const px=98+(rand()-.5)*radius*1.8,py=top+20+rand()*(radius*1.3);
          ellipse(px,py,1.2+rand()*2,1+rand()*1.5,
            k%3===0?'#cad3a0':k%2===0?'#173c2e':'#9db77c');
        }
      }
    }
    treeSpriteCache.set(key,c);return c;
  }
  function tree(x,y,variation=0){
    const tile=game.tiles[id(x,y)];
    const stage=game.treeStage(tile);
    if(!stage)return;
    const species=tile.tree?.species||'oak';
    // Leave enough off-grid variation that forest rows do not trace diamonds.
    const jitterX=((x*23+y*37+x*y*3)%19-9)*.037;
    const jitterY=((x*17+y*13+x*y*5)%17-8)*.037;
    const p=screen(x+.5+jitterX,y+.5+jitterY),t=tileSize(),h=tileHeight();
    const sprite=treeSprite(species,stage,variation%4);
    const isSmall=stage==='sapling'||stage==='regrowing'||stage==='stump';
    const scale=stage==='stump'?.31:stage==='regrowing'?.37:stage==='sapling'?.45:
      stage==='young'?.72:stage==='old'?1.19:1;
    const w=t*1.14*scale,ht=h*3.05*scale;
    castShadow(p.x,p.y+h*.10,t,h,scale*1.04,.30);
    blob(p.x,p.y+h*.20,t*.33*scale,h*.13,'#153a2d',.26);
    const wind=(!isSmall?Math.sin(animationClock*.8+x*.6+y*.9)*.009:0);
    ctx.save();ctx.translate(p.x,p.y+h*.18);ctx.rotate(wind);
    ctx.drawImage(sprite,-w/2,-ht,w,ht);ctx.restore();
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
  // Road tiles are cached as isometric cobblestone sprites. The atlas
  // is drawn once per topology (0..15) and surface variation (0..3),
  // not reconstructed from hundreds of stones every animation frame.
  const roadSpriteCache=new Map();
  const ROAD_SOURCE_TILE=192,ROAD_CANVAS_W=192,ROAD_CANVAS_H=112;
  const ROAD_CENTER_X=96,ROAD_CENTER_Y=56;
  const ROAD_STONE_COLORS=['#c9b9a0','#af9b80','#d4c4a9','#978670',
    '#bba78c','#a3947a','#c2ae90','#8d806d'];

  function makeRoadSprite(mask,variation){
    const key=mask*4+variation;
    if(roadSpriteCache.has(key))return roadSpriteCache.get(key);
    const surface=document.createElement('canvas');
    surface.width=ROAD_CANVAS_W;surface.height=ROAD_CANVAS_H;
    const g=surface.getContext('2d'),plan=V.cobblestonePlan(mask);
    g.lineJoin='round';g.lineCap='round';
    const project=(x,y)=>({
      x:ROAD_CENTER_X+(x-y)*ROAD_SOURCE_TILE/2,
      y:ROAD_CENTER_Y+(x+y)*ROAD_SOURCE_TILE/4
    });
    const quad=(coords,fill,stroke=null,lineWidth=1)=>{
      const vertices=coords.map(([x,y])=>project(x,y));
      g.beginPath();g.moveTo(vertices[0].x,vertices[0].y);
      for(let i=1;i<vertices.length;i++)g.lineTo(vertices[i].x,vertices[i].y);
      g.closePath();g.fillStyle=fill;g.fill();
      if(stroke){g.lineWidth=lineWidth;g.strokeStyle=stroke;g.stroke();}
      return vertices;
    };
    const armQuad=(dx,dy,u0,u1,v0,v1)=>{
      const at=(u,v)=>[dx*u-dy*v,dy*u+dx*v];
      return [at(u0,v0),at(u1,v0),at(u1,v1),at(u0,v1)];
    };
    const centerQuad=(a,b,c,d)=>[[a,c],[b,c],[b,d],[a,d]];
    // Continuous dark compacted-earth shoulder, with one consistent
    // pavement width at both ends of each neighbouring road.
    for(const arm of plan.arms){
      quad(armQuad(arm.dx,arm.dy,0,.508,-.275,.275),'#715e47');
      quad(armQuad(arm.dx,arm.dy,0,.507,-.235,.235),'#9b8a70');
    }
    quad(centerQuad(-.275,.275,-.275,.275),'#715e47');
    quad(centerQuad(-.235,.235,-.235,.235),'#9b8a70');
    let count=0;
    const stone=(corners,seed)=>{
      const n=((seed*1664525+variation*1013904223)>>>0);
      const color=ROAD_STONE_COLORS[n%ROAD_STONE_COLORS.length];
      const vertices=quad(corners,color,'#675943',1.35);
      const p0=vertices[0],p1=vertices[1],p3=vertices[3];
      // Thin sunny upper edge and an irregular mineral fleck.
      g.strokeStyle='#f3dfc1';g.globalAlpha=.52;g.lineWidth=.85;
      g.beginPath();g.moveTo(p0.x+.8,p0.y+.2);
      g.lineTo(p1.x-.7,p1.y-.3);g.stroke();
      if((n%4)===0){
        g.fillStyle='#f4e7d1';g.globalAlpha=.24;
        g.beginPath();g.ellipse(
          (p0.x+p1.x+p3.x)/3,(p0.y+p1.y+p3.y)/3,
          1.15,.65,.3,0,Math.PI*2);g.fill();
      }
      g.globalAlpha=1;count++;
    };
    // Every arm has five staggered rows of three real, differently shaded
    // stone blocks. End rows meet in the shared road border at u=.5.
    for(const arm of plan.arms){
      for(const s of arm.stones){
        const gap=.006,shift=((s.row+s.col+variation)%2)*.004;
        stone(armQuad(arm.dx,arm.dy,
          Math.max(.14,s.u0+gap+shift),Math.min(.5,s.u1-gap),
          s.v0+gap,s.v1-gap),
          arm.bit*311+s.row*37+s.col*71);
      }
    }
    // Paving at the central connection covers arm overlaps and avoids the
    // old large smooth diamond on bends, T-junctions and crossroads.
    for(const c of plan.center){
      const gap=.009;
      stone(centerQuad(c.x0+gap,c.x1-gap,c.y0+gap,c.y1-gap),
        c.row*101+c.col*43+mask*17);
    }
    surface.dataset.stones=String(count);
    roadSpriteCache.set(key,surface);
    return surface;
  }
  function road(x,y){
    const mask=V.roadMask(game.roads,x,y,W,H);
    const variation=((x*13+y*23+x*y*3)%4+4)%4;
    const img=makeRoadSprite(mask,variation);
    const p=screen(x+.5,y+.5),scale=tileSize()/ROAD_SOURCE_TILE;
    ctx.drawImage(img,
      p.x-ROAD_CENTER_X*scale,p.y-ROAD_CENTER_Y*scale,
      ROAD_CANVAS_W*scale,ROAD_CANVAS_H*scale);
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
      if(!mask){
        // Procedural quarry and future buildings have no alpha mask atlas yet.
        if(u>.13&&u<.87&&v>.18)return b;
        continue;
      }
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
      // Flour dust and millstone vibration only; rotor is drawn exactly once
      // by drawWindmill() whether the mill is running or idle.
      for(let i=0;i<4;i++){
        const f=(clock*.46+i*.25)%1;
        blob(p.x-t*(.12-.11*f),p.y-h*(.29+.08*f),t*.013,h*.018,
          '#f9e4bb',.70*(1-f));
      }
      blob(p.x-t*.015,p.y-h*.21,t*(.055+.016*Math.sin(clock*8)),
        h*.035,'#ddbd8a',.42);
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
  function drawCitizen(x,y,t,active=false,kind='idle'){
    // Visual representation derived from staffed slots; only porter/builder are autonomous agents.
    const colors={logger:'#678e67',quarry:'#ae9b82',farm:'#b9a365',sawmill:'#927f55',
      mill:'#b2a68b',bakery:'#b98a65',idle:'#9ab3a0'};
    const c=colors[kind]||'#a1b8a5',sway=active?Math.sin(animationClock*6)*t*.023:Math.sin(animationClock*.9)*t*.006;
    castShadow(x,y+t*.028,t,t/2,.26,.22);
    blob(x,y+t*.025,t*.07,t*.022,'#0c251e',.28);
    line(x-t*.018,y-t*.04,x-t*.024+sway,y+t*.017,'#493c33',Math.max(.9,1.35*zoom));
    line(x+t*.018,y-t*.04,x+t*.025-sway,y+t*.017,'#493c33',Math.max(.9,1.35*zoom));
    blob(x+sway*.35,y-t*.13,t*.056,t*.075,c,.98);
    blob(x+sway*.45,y-t*.245,t*.035,t*.043,'#e3bc91',1);
    line(x-t*.04,y-t*.16,x-t*.065+sway,y-t*.09,'#d5ac84',Math.max(.8,1.3*zoom));
    line(x+t*.04,y-t*.16,x+t*.07-sway,y-t*(active?.12:.10),'#d5ac84',Math.max(.8,1.3*zoom));
  }
  // A single independent windmill rotor. No baked-in static blades:
  // the old mill.webp is deliberately NOT rendered at any point.
  const millRotors=new Map();
  function windmillAngle(id,active){
    const prior=millRotors.get(id)||{angle:(id*.23)%(Math.PI*2),clock:animationClock};
    const dt=Math.min(.1,Math.max(0,animationClock-prior.clock));
    if(active)prior.angle=(prior.angle+dt*1.7)%(Math.PI*2);
    prior.clock=animationClock;millRotors.set(id,prior);
    return prior.angle;
  }
  function drawWindmill(b,p,t,h,active){
    const left=p.x-t*.37,right=p.x+t*.37,top=p.y-h*1.50,base=p.y+h*.19;
    // Stone tower: three lit wall facets, clipped bands of hand-laid masonry,
    // timber roof and chimney are all part of the same depth-correct structure.
    poly([[left,top+h*.18],[p.x-t*.04,top-h*.03],[p.x+t*.10,top+h*.12],
      [p.x+t*.04,base],[left-t*.03,base+h*.08]],'#b7a991','#554d41',1.2*zoom);
    poly([[p.x+t*.10,top+h*.12],[right,top+h*.30],[right+t*.025,base+h*.08],
      [p.x+t*.04,base]],'#827967','#45473f',1.1*zoom);
    poly([[left,top+h*.18],[p.x+t*.04,top+h*.04],[right,top+h*.30],
      [p.x-t*.02,top+h*.50]],'#d0bf9e',null);
    for(let row=0;row<7;row++){
      const y=top+h*.34+row*h*.18;
      line(left+t*.03,y,p.x+t*.028,y+h*.025,'#777361',.95*zoom);
      line(p.x+t*.075,y+h*.04,right-t*.018,y+h*.12,'#54584e',.95*zoom);
      for(let col=0;col<3;col++){
        const x=left+t*(.07+col*.11+(row%2)*.04);
        line(x,y-t*.003,x+t*.015,y+h*.085,'#99917f',.8*zoom);
      }
    }
    // Mill cap with stepped timber shingle layers and a visible overhang.
    const roofPeak=[p.x-t*.05,top-h*.45];
    poly([[left-t*.10,top+h*.18],roofPeak,[p.x+t*.025,top-h*.16],
      [p.x+t*.035,top+h*.27]],'#895c3c','#54392c',1.1*zoom);
    poly([roofPeak,[p.x+t*.20,top-h*.26],[right+t*.06,top+h*.30],
      [p.x+t*.035,top+h*.27]],'#5b4234','#412e28',1.1*zoom);
    for(let k=0;k<4;k++){
      const fy=top-h*.18+k*h*.11;
      line(p.x+t*.02,fy,p.x+t*(.09+k*.065),fy+h*.05,'#bf9060',.85*zoom);
    }
    // Door and windows add scale and contrast to the stone structure.
    poly([[p.x-t*.12,base],[p.x-t*.12,base-h*.54],[p.x+t*.035,base-h*.53],
      [p.x+t*.035,base]],'#40352d','#d7b98d',1.3*zoom);
    poly([[p.x+t*.06,top+h*.61],[p.x+t*.19,top+h*.69],
      [p.x+t*.19,top+h*1.00],[p.x+t*.06,top+h*.91]],'#33362f','#bdac8a',1.1*zoom);
    line(p.x+t*.12,top+h*.66,p.x+t*.12,top+h*.97,'#d5b883',1.1*zoom);
    for(let k=0;k<3;k++){
      const y=base+h*(.10+k*.07);
      line(p.x-t*.19,y,p.x+t*.12,y+h*.035,'#968571',1.5*zoom);
    }
    // Only one set of four vanes. The same rotor freezes in place whenever
    // the mill lacks staff, road access, input material, or the game is paused.
    const cx=p.x+t*.14,cy=p.y-h*1.12,angle=windmillAngle(b.id,active);
    blob(cx+t*.015,cy+h*.055,t*.15,h*.16,'#252822',.48);
    for(let i=0;i<4;i++){
      const a=angle+i*Math.PI/2,u=Math.cos(a),v=Math.sin(a),vx=-v,vy=u;
      const inner=t*.11,outer=t*.48,w=t*.073;
      poly([[cx+u*inner+vx*w,cy+v*inner+vy*w*.55],
        [cx+u*outer+vx*w*.74,cy+v*outer+vy*w*.72],
        [cx+u*outer-vx*w*.74,cy+v*outer-vy*w*.72],
        [cx+u*inner-vx*w,cy+v*inner-vy*w*.55]],
        i%2===0?'#d8c399':'#c8b186','#654d35',1*zoom);
      line(cx+u*inner,cy+v*inner,cx+u*outer,cy+v*outer,
        '#785435',Math.max(1.2,2.0*zoom));
      for(let k=1;k<4;k++){
        const f=inner+(outer-inner)*k/4;
        line(cx+u*f+vx*w*.75,cy+v*f+vy*w*.5,
          cx+u*f-vx*w*.75,cy+v*f-vy*w*.5,'#8c6f49',.9*zoom);
      }
    }
    blob(cx,cy,t*.049,h*.065,'#916e47');
    blob(cx-t*.014,cy-h*.015,t*.016,h*.02,'#f1d5a1',.7);
  }
  function drawBuilding(b){
    const {w:renderedWidth,h:imageHeight,p}=buildingRect(b),t=tileSize(),h=tileHeight(),connected=game.connected(b);
    castShadow(p.x,p.y+h*.08,t,h,1.43,.37);
    diamond(p.x,p.y,.75,'#263d3133');
    if(b.type==='mill'){
      drawWindmill(b,p,t,h,V.productionActive(b,connected,game.readyToProduce(b)));
    }else if(b.type==='quarry'){
      // A working quarry remains visibly industrial even once its nearby
      // stone outcrops have been depleted.
      diamond(p.x,p.y,.77,'#615c50','#b8a58a');
      for(let k=0;k<5;k++){
        const xx=p.x+t*((k%3-1)*.16),yy=p.y+h*(Math.floor(k/3)*.20-.02);
        poly([[xx-t*.11,yy],[xx-t*.04,yy-h*(.18+.03*k)],
          [xx+t*.09,yy-h*.10],[xx+t*.15,yy+h*.05]],
          k%2?'#a3a69b':'#bcb5a2','#4d554f',1.0*zoom);
        line(xx-t*.03,yy-h*.13,xx+t*.03,yy-h*.16,
          '#e3d7bd',.9*zoom);
      }
      for(const side of [-1,1]){
        line(p.x+t*side*.35,p.y+h*.14,p.x+t*side*.35,p.y-h*.56,
          '#9e774d',2.7*zoom);
      }
      line(p.x-t*.35,p.y-h*.49,p.x+t*.35,p.y-h*.49,'#d2a56f',3.1*zoom);
      line(p.x-t*.35,p.y-h*.07,p.x+t*.35,p.y-h*.07,'#d2a56f',2.0*zoom);
      line(p.x+t*.27,p.y-h*.48,p.x+t*.42,p.y+h*.08,'#75583d',1.6*zoom);
    }else if(!sprite(b.type,p.x,p.y+h*.33,renderedWidth,imageHeight)){
      diamond(p.x,p.y-.23*t,.84,COLORS[b.type]);
      ctx.textAlign='center';ctx.font=`bold ${Math.max(12,t*.32)}px sans-serif`;ctx.fillStyle='#f8eac6';
      ctx.fillText(DEF[b.type].symbol,p.x,p.y-h*.12);
    }
    const active=V.productionActive(b,connected,game.readyToProduce(b));
    if(active&&!['logger','quarry','farm'].includes(b.type))drawProductionEffect(b,p,t,h);
    if(game.scenario==='settlement'&&(game.staff[b.id]||0)>0&&!['logger','quarry','farm'].includes(b.type)){
      const pos=screen(b.x+.91,b.y+.79);
      drawCitizen(pos.x,pos.y+h*.06,t,active,b.type);
    }
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
      const phase=V.constructionVisualPhase(site),palette=MATERIAL_COLORS[site.type]||MATERIAL_COLORS.generic;
      const [wall,roof,dark]=palette;
      const x=pos.x,y=pos.y+t*.06,half=t*.34,depth=h*.26;
      castShadow(x,y,t,h,1.16,.30);
      // The stakes, measured ropes and material piles are present first,
      // before any builder can begin erecting walls.
      diamond(x,y,.78,'#6d5c4599','#bea078');
      for(const side of [-1,1]){
        const sx=x+side*half;
        line(sx,y-depth*.35,sx,y-depth*.35-h*.20,'#dbb584',2*zoom);
        line(sx,y-depth*.35-h*.17,sx-side*t*.12,y-depth*.65-h*.16,
          '#f0d8a5',.9*zoom);
      }
      if(phase==='survey'){
        poly([[x-half,y],[x,y-depth],[x+half,y],[x,y+depth]],
          '#77674f66','#e2c597',1*zoom);
        for(let k=0;k<3;k++){
          const yy=y+h*(.16+k*.045);
          line(x-t*.36,yy,x-t*.19,yy-h*.035,'#a27b4c',2.2*zoom);
        }
      }else{
        // Stone foundation: three visible masonry faces and a raised sill.
        poly([[x-half,y],[x,y-depth],[x+half,y],[x,y+depth]],
          '#c0b29a','#6e675a',1.2*zoom);
        poly([[x-half,y],[x,y+depth],[x,y+depth+h*.16],[x-half,y+h*.14]],
          '#9d927d','#60594f',1.05*zoom);
        poly([[x,y+depth],[x+half,y],[x+half,y+h*.14],[x,y+depth+h*.16]],
          '#756f64','#514c44',1.05*zoom);
        for(let k=0;k<4;k++)
          line(x-half*.9+k*t*.14,y+h*.11,x-half*.8+(k+.34)*t*.14,y+h*.14,
            '#ddd3bc',.75*zoom);
        const height=phase==='foundation'?0:phase==='frame'?h*.92:phase==='walls'?h*1.48:h*1.66;
        if(height>0){
          // Timber corner posts and progressive cross braces.
          const corners=[[x-half,y],[x,y-depth],[x+half,y],[x,y+depth]];
          for(const [px,py] of corners){
            line(px,py,px,py-height,'#69482f',Math.max(2.2,4.2*zoom));
            line(px-t*.006,py-height,px+t*.012,py-height,'#d3a16b',1.8*zoom);
          }
          poly(corners.slice(0,3).map(([px,py])=>[px,py-height]),
            '#b9926199','#7b5b42',.8*zoom);
          line(x-half,y-height,x,y-depth-height,'#c39a63',3*zoom);
          line(x,y-depth-height,x+half,y-height,'#c39a63',3*zoom);
          if(phase==='frame'){
            for(const side of [-1,1])
              line(x+side*half,y-height*.12,x,y-depth-height*.74,
                '#d1a475',2.0*zoom);
          }
          if(phase==='walls'||phase==='roof'){
            // Lit front and shaded side walls; openings remain dark windows.
            poly([[x-half,y],[x-half,y-height],[x,y-depth-height],[x,y-depth]],
              wall,'#574a39',1*zoom);
            poly([[x,y-depth],[x,y-depth-height],[x+half,y-height],[x+half,y]],
              dark,'#3f382f',1*zoom);
            for(let row=0;row<5;row++){
              const y0=y-height*(.15+row*.16);
              line(x-half+t*.018,y0,x-t*.015,y0-h*.13,'#d4b389',.65*zoom);
              line(x+t*.015,y0-h*.13,x+half-t*.01,y0,'#3e392f',.65*zoom);
            }
            poly([[x-t*.12,y-h*.20],[x-t*.12,y-height*.52],[x+t*.005,y-height*.60],
              [x+t*.005,y-h*.22]],'#362e27','#dac5a4',1*zoom);
            poly([[x+t*.13,y-height*.58],[x+t*.23,y-height*.62],
              [x+t*.23,y-height*.86],[x+t*.13,y-height*.82]],
              '#283a35','#d0b17f',1*zoom);
          }
          if(phase==='roof'){
            const peak=y-height-h*.48;
            const completion=clamp((ratio-.77)/.23,0,1);
            // The gable frame appears before tiles cover it.
            line(x-half-t*.03,y-height,x,peak,'#b7814a',3*zoom);
            line(x,peak,x+half+t*.05,y-height,'#b7814a',3*zoom);
            line(x,peak,x,y-depth-height-h*.33,'#e1b585',2*zoom);
            poly([[x-half-t*.05,y-height],[x,peak],[x,y-depth-height-h*.33],
              [x-half*.20,y-depth-height]],'#7a5539','#4c352a',1*zoom);
            poly([[x,peak],[x+half+t*.05,y-height],[x+half*.23,y-depth-height],
              [x,y-depth-height-h*.33]],'#4c3e35','#332d27',1*zoom);
            // Shingle courses are added as the LAST phase advances.
            const courses=Math.max(1,Math.ceil(completion*5));
            for(let row=0;row<courses;row++){
              const f=(row+1)/6;
              line(x-half*(1-f),y-height-h*.44*(1-f),
                x+t*.025,y-depth-height-h*.31*(1-f),'#aa7b54',1.2*zoom);
              line(x+t*.03,y-depth-height-h*.31*(1-f),
                x+half*f,y-height-h*.04*(1-f),'#8b6545',1.1*zoom);
            }
          }
          // Scaffolding changes height with the actual build stage.
          const scaffTop=y-height-h*.12;
          for(const side of [-1,1]){
            const sx=x+side*half*1.24;
            line(sx,y+h*.15,sx,scaffTop,'#bd915d',2.3*zoom);
            line(sx-side*t*.09,y+h*.11,sx,scaffTop,'#947247',1.6*zoom);
          }
          line(x-half*1.24,y-height*.47,x+half*1.24,y-height*.47,
            '#d5ae79',2.1*zoom);
        }
      }
      // Physical deliveries must be visible in the builder's work area.
      for(let k=0;k<Math.min(5,have);k++){
        const xx=x-t*.53+t*(k%3)*.09,yy=y+h*(.29+Math.floor(k/3)*.10);
        line(xx,yy,xx+t*.20,yy-h*.06,'#b88754',Math.max(2,3.6*zoom));
        line(xx,yy-h*.028,xx+t*.20,yy-h*.087,'#e3bc82',.85*zoom);
      }
      for(let k=0;k<Math.min(5,deliveredStone);k++){
        const xx=x+t*(.35+(k%3)*.075),yy=y+h*(.23+Math.floor(k/3)*.10);
        poly([[xx-t*.04,yy],[xx,yy-h*.11],[xx+t*.06,yy-h*.05],
          [xx+t*.07,yy+h*.035]],k%2?'#92938a':'#c1b8a6','#595a53',.7*zoom);
      }
      if(materialsReady&&ratio>0){
        const f=(animationClock*.7+site.id*.13)%1;
        for(let k=0;k<4;k++){
          blob(x+t*(.04+k*.11),y-h*(.35+f*.19),t*.01,h*.016,
            '#dbd0aa',.28*(1-f));
        }
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
    castShadow(p.x,footY,t,h,.34,.25);
    // 100% frame-sheet playback. No static character sprite or global bobbing.
    if(!workerSprite(b,'builder',p.x,footY,t*.48)){
      blob(p.x,footY-h*.24,t*.10,h*.20,'#dda93f');
    }
  }
  function drawCargo(cargo,x,y,t,h){
    if(!cargo)return;
    const n=cargo.amount;
    ctx.save();ctx.lineCap='round';
    if(cargo.res==='logs'||cargo.res==='boards'){
      for(let i=0;i<Math.min(n,3);i++){
        const sy=y+h*(i*.07-.04),length=t*(cargo.res==='logs'?.37:.33);
        line(x-length*.43,sy,x+length*.57,sy-h*.08,
          cargo.res==='logs'?'#79502c':'#be9668',Math.max(3,t*.065));
        line(x-length*.43,sy,x+length*.57,sy-h*.08,
          '#d9ad74',Math.max(.7,t*.012));
        blob(x-length*.43,sy,t*.035,h*.048,'#e1b783',1);
      }
    }else if(cargo.res==='grain'){
      for(let k=0;k<6;k++){
        const ang=(k-2.5)*.23;
        line(x,y+h*.08,x+Math.sin(ang)*t*.13,y-h*.30,'#bca465',Math.max(1,t*.018));
        blob(x+Math.sin(ang)*t*.12,y-h*.26,t*.028,h*.05,'#e3c779',1);
      }
      line(x-t*.08,y-h*.04,x+t*.08,y-h*.05,'#d1b48b',Math.max(2,t*.03));
    }else if(cargo.res==='flour'){
      blob(x,y-h*.11,t*.17,h*.24,'#f0e4cb',1);
      poly([[x-t*.12,y-h*.26],[x+t*.1,y-h*.26],[x+t*.07,y-h*.37],[x-t*.08,y-h*.37]],
        '#d8c6a5','#8f826b',1);
      line(x-t*.075,y-h*.08,x+t*.09,y-h*.08,'#b5a485',1.1*zoom);
    }else if(cargo.res==='stone'){
      for(let k=0;k<Math.min(n,3);k++){
        const sx=x+t*(k-.8)*.10,sy=y+h*(k%2)*.06;
        poly([[sx-t*.085,sy],[sx-t*.035,sy-h*.15],[sx+t*.063,sy-h*.11],
          [sx+t*.092,sy+h*.02]],'#a9a8a1','#6b706e',1);
      }
    }else if(cargo.res==='vegetables'){
      for(let k=0;k<3;k++){
        const sx=x+t*(k-1)*.09,sy=y+h*(k%2)*.08;
        blob(sx,sy,t*.06,h*.10,k===1?'#cb9b42':'#9bbb62');
        line(sx,sy-h*.08,sx-t*.025,sy-h*.18,'#426f3c',2*zoom);
      }
    }else if(cargo.res==='bread'){
      blob(x,y-h*.09,t*.16,h*.17,'#c98d4e');
      for(let k=0;k<3;k++)line(x-t*.075+k*t*.06,y-h*.16,
        x-t*.05+k*t*.06,y-h*.22,'#f6c985',1.2*zoom);
    }
    ctx.restore();
  }
  function drawWorkAgent(a){
    const b=game.buildings.find(v=>v.id===a.buildingId);if(!b)return;
    const p=screen(a.x,a.y),t=tileSize(),h=tileHeight();
    castShadow(p.x,p.y+h*.20,t,h,.3,.19);
    const moving=a.phase==='arrive'||a.phase==='out'||a.phase==='return';
    drawCitizen(p.x,p.y+h*.19,t,moving||a.phase==='work',b.type);
    if(a.carrying)drawCargo(a.carrying,p.x+t*.17,p.y-h*.08,t,h);
    if(a.phase==='work'){
      const wave=Math.sin(animationClock*9+a.buildingId);
      if(b.type==='logger'){
        line(p.x+t*.045,p.y-h*.11,p.x+t*(.17+.06*wave),p.y-h*(.40+.05*wave),'#94673b',2.5*zoom);
        line(p.x+t*(.17+.06*wave),p.y-h*(.40+.05*wave),
          p.x+t*(.25+.06*wave),p.y-h*(.43+.05*wave),'#c3d4cd',3*zoom);
      }else if(b.type==='quarry'){
        line(p.x+t*.035,p.y-h*.10,p.x+t*(.18+.06*wave),p.y-h*(.39+.03*wave),'#876544',2*zoom);
        line(p.x+t*(.13+.06*wave),p.y-h*(.41+.03*wave),
          p.x+t*(.25+.06*wave),p.y-h*(.36+.03*wave),'#d0d4ca',3*zoom);
      }else if(b.type==='farm')line(p.x+t*.04,p.y-h*.10,p.x+t*.22,p.y-h*(.31+.04*wave),'#b8ad76',2*zoom);
    }
  }
  function drawCarrier(c){
    const p=screen(c.x+.5,c.y+.5),t=tileSize(),h=tileHeight();
    const footY=p.y+h*.26;
    castShadow(p.x,footY,t,h,.32,.24);
    if(!workerSprite(c,'porter',p.x,footY,t*.48)){
      blob(p.x,footY-h*.23,t*.10,h*.20,'#aa8255');
    }
    // Never draw a second, baked-in sack: this is the ONLY visible load.
    const appearance=V.porterAppearance(c.carrying);
    if(appearance.cargo)drawCargo(c.carrying,p.x+t*.13,p.y-h*.07,t,h);
  }
  function draw(){
    ctx.setTransform(dpr,0,0,dpr,0,0);
    ctx.fillStyle='#233f38';ctx.fillRect(0,0,width,height);
    // Camera-agnostic culling: project map coordinates, discard tiles outside
    // the viewport with an extended margin for tall buildings and trees.
    const margin=tileSize()*2.6;
    const visible=(p)=>p.x>-margin&&p.y>-margin*1.5&&p.x<width+margin&&p.y<height+margin;
    drawGround();
    ctx.save();clipWorld();landscapePatches();drawWaterBodies();ctx.restore();
    for(const field of game.fields||[])if(visible(screen(field.x+.5,field.y+.5)))drawField(field);
    for(let y=0;y<H;y++)for(let x=0;x<W;x++)if(game.roads[id(x,y)]){
      if(visible(screen(x+.5,y+.5)))road(x,y);
    }
    // Sorted by the ground-point depth: buildings, vegetation and moving
    // porters occlude each other in a coherent painter's-order projection.
    const objects=[];
    for(let y=0;y<H;y++)for(let x=0;x<W;x++){
      const tile=game.tiles[id(x,y)];if(!visible(screen(x+.5,y+.5)))continue;
      if(tile.terrain==='forest')objects.push({x,y,depth:x+y+.65,type:'forest'});
      if(tile.terrain==='hills'&&tile.stone>0&&!game.buildingAt(x,y)&&!game.siteAt(x,y))
        objects.push({x,y,depth:x+y+.67,type:'rocks'});
      if(tile.terrain==='ruin')objects.push({x,y,depth:x+y+.65,type:'ruin'});
       if(tile.terrain==='grass'&&!game.roads[id(x,y)]&&!game.buildingAt(x,y)&&!game.siteAt(x,y)&&!game.fieldAt(x,y)&&
          (x*31+y*47+x*y*11)%13===0)objects.push({x,y,depth:x+y+.60,type:'bush'});
    }
    for(const b of game.buildings)if(visible(screen(b.x+.5,b.y+.5)))objects.push({x:b.x,y:b.y,depth:b.x+b.y+.75,type:'building',b});
    for(const site of game.construction)if(visible(screen(site.x+.5,site.y+.5)))objects.push({x:site.x,y:site.y,depth:site.x+site.y+.73,type:'site',site});
    for(const b of game.builders)if(visible(screen(b.x+.5,b.y+.5)))objects.push({x:b.x,y:b.y,depth:b.x+b.y+.90,type:'builder',b});
    for(const c of game.carriers)if(visible(screen(c.x+.5,c.y+.5)))objects.push({x:c.x,y:c.y,depth:c.x+c.y+.90,type:'carrier',c});
    for(const agent of game.workAgents||[])if(visible(screen(agent.x,agent.y)))
      objects.push({x:agent.x,y:agent.y,depth:agent.x+agent.y+.90,type:'resident-worker',agent});
    if(game.scenario==='settlement'){
      const home=game.warehouse(),count=Math.min(7,game.availableWorkers());
      for(let k=0;k<count;k++){
        const x=home.x+.15+(k%4)*.22,y=home.y+1.2+Math.floor(k/4)*.25;
        objects.push({x,y,depth:x+y+.92,type:'villager'});
      }
    }
    objects.sort((a,b)=>a.depth-b.depth||a.x-b.x);
    for(const o of objects){
      if(o.type==='forest')tree(o.x,o.y,(o.x*5+o.y*9)%6);
      else if(o.type==='rocks')rockDeposit(o.x,o.y);
      else if(o.type==='ruin')ruins(o.x,o.y);
       else if(o.type==='bush')bush(o.x,o.y,(o.x*3+o.y*7)%11);
      else if(o.type==='villager'){
        const p=screen(o.x,o.y);drawCitizen(p.x,p.y,tileSize(),false,'idle');
      }
      else if(o.type==='building')drawBuilding(o.b);
      else if(o.type==='site')drawSite(o.site);
      else if(o.type==='builder')drawBuilder(o.b);
      else if(o.type==='resident-worker')drawWorkAgent(o.agent);
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
  $('missionFocus').addEventListener('click',()=>{focusMission();setMissionExpanded(false);});
  $('missionTool').addEventListener('click',()=>{selectTool($('missionTool').dataset.actionTool);if(game.missionProgress().stage!==3)focusMission();setMissionExpanded(false);});
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
     if(game.scenario==='settlement')setPanel('news');
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
    if(paused&&mode!=='inspect'){notify('Снимите игру с паузы, чтобы строить и исследовать.');return;}
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
  document.querySelectorAll('[data-tool]').forEach(b=>b.addEventListener('click',()=>{
    selectTool(b.dataset.tool);
    if(b.closest('.game-dock'))setPanel('none');
  }));
  $('surveyBtn').addEventListener('click',()=>selectTool('excavate'));
  const shell=document.querySelector('.shell');
  function setPanel(panel){
    shell.dataset.panel=panel;
    document.querySelectorAll('[data-hud-panel]').forEach(btn=>
      btn.setAttribute('aria-expanded',String(panel===btn.dataset.hudPanel)));
  }
  document.querySelectorAll('[data-hud-panel]').forEach(btn=>btn.addEventListener('click',()=>{
    setPanel(shell.dataset.panel===btn.dataset.hudPanel?'none':btn.dataset.hudPanel);
  }));
  document.querySelectorAll('[data-close-panel]').forEach(btn=>btn.addEventListener('click',()=>setPanel('none')));
  const buildPanel=$('buildPanel');
  document.querySelectorAll('[data-build-category]').forEach(btn=>btn.addEventListener('click',()=>{
    buildPanel.dataset.category=btn.dataset.buildCategory;
    document.querySelectorAll('[data-build-category]').forEach(tab=>
      tab.setAttribute('aria-pressed',String(tab===btn)));
  }));
  const missionCard=$('missionCard'),missionToggle=$('missionToggle');
  function setMissionExpanded(expanded){
    missionCard.classList.toggle('expanded',expanded);
    missionToggle.setAttribute('aria-expanded',String(expanded));
    missionToggle.title=expanded?'Свернуть задание':'Развернуть задание';
    missionToggle.querySelector('.sr-only').textContent=missionToggle.title;
  }
  missionToggle.addEventListener('click',()=>setMissionExpanded(!missionCard.classList.contains('expanded')));
  canvas.addEventListener('pointerdown',()=>{if(shell.dataset.panel!=='none')setPanel('none');});
  document.querySelectorAll('[data-crop]').forEach(b=>b.addEventListener('click',()=>{
    selectedCrop=b.dataset.crop;
    document.querySelectorAll('[data-crop]').forEach(btn=>btn.setAttribute('aria-pressed',String(btn===b)));
    selectTool('field');
    if(innerWidth<=750)setPanel('none');
  }));
  document.querySelectorAll('[data-pan]').forEach(b=>b.addEventListener('click',()=>{
    const delta={left:[-2,0],right:[2,0],up:[0,-2],down:[0,2]}[b.dataset.pan];
    camera.x=clamp(camera.x+delta[0],-1,W+1);camera.y=clamp(camera.y+delta[1],-1,H+1);
  }));
  $('zoomIn').addEventListener('click',()=>zoomBy(.2));$('zoomOut').addEventListener('click',()=>zoomBy(-.2));
  $('taxSlider').addEventListener('input',e=>{game.setTax(Number(e.target.value));$('taxValue').textContent=game.tax+'%';persist();});
  function setPaused(value){
    paused=Boolean(value);
    game.setPaused(paused);
    $('pauseBtn').textContent=paused?'▶ ПРОДОЛЖИТЬ':'Ⅱ ПАУЗА';
    $('mapOverlay').hidden=!paused;
    if(paused)notify('Пауза: камера и осмотр доступны, строительство и работа остановлены.');
  }
  $('pauseBtn').addEventListener('click',()=>setPaused(!paused));
  $('speedBtn').addEventListener('click',()=>{speed=speed===1?2:speed===2?4:1;$('speedBtn').textContent='×'+speed;});
  $('saveBtn').addEventListener('click',()=>notify(persist()?'Игра сохранена в этом браузере.':'Сохранение недоступно: проверь разрешения браузера.'));
  $('helpBtn').addEventListener('click',()=>{setPaused(true);$('helpDialog').showModal();});
  $('closeHelp').addEventListener('click',()=>$('helpDialog').close());
  $('resetBtn').addEventListener('click',()=>{
    if(!window.confirm('Начать новую карту? Текущий прогресс будет потерян.'))return;
    game=new Game().startMission();setPanel('none');setMissionExpanded(false);resetMotion();stageShown=-2;winShown=false;selectTool('road');camera.x=17;camera.y=10;setPaused(false);persist();updateHUD();notify('Начато первое испытание!');
  });
  $('freeBtn').addEventListener('click',()=>{
    if(!window.confirm('Начать свободную игру без задач? Текущий прогресс будет заменён.'))return;
    game=new Game(1729,'settlement');setPanel('none');setMissionExpanded(false);resetMotion();stageShown=-2;winShown=false;camera.x=11.5;camera.y=10;selectTool('inspect');setPaused(false);persist();updateHUD();notify('Свободное поселение основано.');
  });
  window.addEventListener('keydown',e=>{
    if(e.target.closest('input,button,dialog'))return;
    if(e.code==='Space'){e.preventDefault();setPaused(!paused);}
    if(e.key==='Escape'){setPanel('none');setMissionExpanded(false);selectTool('inspect');}
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
  if(restored)notify(game.scenario==='legacy'?'Восстановлено старое испытание. Для старта с одного здания: Меню → Новое поселение.':'Прогресс поселения восстановлен.');
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
    buildings:game.buildings.length,trees:game.tiles.filter(t=>t.terrain==='forest').map(t=>({stage:game.treeStage(t),age:t.tree?.age||0,wood:t.wood})),waterTiles:game.tiles.filter(t=>t.terrain==='water').length,sites:game.construction.map(s=>({type:s.type,x:s.x,y:s.y,boards:s.goods.boards,required:s.required.boards,progress:s.progress,duration:s.duration})),builders:game.builders.map(b=>({site:b.site,phase:b.phase,x:b.x,y:b.y})),carriers:game.carriers.filter(c=>c.job).length,science:game.science,
    culture:game.culture,diplomacy:game.diplomacy,military:game.military,mission:game.missionProgress(),paused,mode,zoom,projection:'isometric',visualVersion:'0.5.3-cobblestone',roadKind:(x,y)=>V.roadKind(V.roadMask(game.roads,x,y,W,H)),roadPaving:(x,y)=>{
      const mask=V.roadMask(game.roads,x,y,W,H);
      const plan=V.cobblestonePlan(mask);
      return {mask,kind:V.roadKind(mask),stones:plan.center.length+
        plan.arms.reduce((sum,arm)=>sum+arm.stones.length,0)};
    },roadSpritesCached:roadSpriteCache.size,stageAt:(x,y)=>{const site=game.siteAt(x,y);return site?V.constructionStage(site):null;},tileCache:tileArtCache.size,treeArtCount:treeSpriteCache.size,waterGroupCount:waterGroups().length,groundTextureWidth:groundSurface.width,groundTextureHeight:groundSurface.height,
    groundMaterialMode:'nonperiodic-world-raster',
    groundSample:(x,y)=>Array.from(groundSurface.getContext('2d',{willReadFrequently:true}).getImageData(x,y,1,1).data),
    spritesReady,workerSheetsReady,animationClock,productionAt:(type)=>{const b=game.buildings.find(v=>v.type===type);return b?V.productionActive(b,game.connected(b),game.readyToProduce(b)):false;},workerPose:(role,index=0)=>workerState((role==='builder'?game.builders:game.carriers)[index],role),porterPoseForCargo:(res)=>workerState({...game.carriers[0],carrying:res?{res,amount:1}:null},'porter'),workerAtlas:(role,mode)=>{const img=workerSheets[`worker-${role}-${mode}`];return img?.naturalWidth?{width:img.naturalWidth,height:img.naturalHeight}:null;},screen:(x,y)=>screen(x+.5,y+.5),step:(n)=>{for(let i=0;i<n*10;i++){if(!paused){game.step(.1);animationClock+=.1;updateMotion();}}updateHUD();draw();}});
})();