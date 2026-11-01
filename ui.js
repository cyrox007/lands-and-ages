/* Strategy 0.4 — visible construction sites, real building crew and logistics. */
(function(){
  'use strict';
  const E=window.StrategyEngine;
  if(!E){document.body.textContent='Ошибка: экономическая симуляция не загрузилась.';return;}
  const {Game,W,H,DEF,COLORS,id}=E;
  const $=x=>document.getElementById(x);
  const canvas=$('gameMap'),ctx=canvas.getContext('2d',{alpha:false});
  const STORAGE='lands-ages:campaign:v1';
  let restored=null;
  try{restored=Game.restore(localStorage.getItem(STORAGE));}catch(_){/* restricted storage */}
  let game=restored||new Game().startMission();
  let mode='inspect',paused=false,speed=1,zoom=innerWidth<600?.88:1;
  const camera={x:restored?10:17,y:restored?10:10};
  let width=800,height=500,dpr=1,last=0,lastDraw=0,lastHud=0,lastSave=0,hover=null;
  let pointer=null,toastUntil=0;
  const TRAITS={grass:'#69875d',forest:'#47755b',hills:'#998a6c',water:'#478b9c',ruin:'#ae9c7b'};
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
  const clamp=(x,a,b)=>Math.max(a,Math.min(b,x));
  function persist(){try{localStorage.setItem(STORAGE,game.save());return true;}catch(_){return false;}}
  function notify(s){$('toast').textContent=s;$('toast').classList.add('visible');toastUntil=performance.now()+2800;}
  function selectTool(type){
    mode=type;
    for(const b of document.querySelectorAll('[data-tool]')){
      const active=b.dataset.tool===type;b.classList.toggle('active',active);b.setAttribute('aria-pressed',String(active));
    }
    const tool=type==='inspect'?'Осмотр: коснись клетки карты.':type==='excavate'?'Исследование: выбери древние руины (15 монет).':
      type==='road'?'Дорога: 2 монеты + 1 доска. Носильщики доставят материал, строители проложат путь.':
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
  function terrainTile(x,y){
    const tile=game.tiles[id(x,y)],type=tile.terrain;
    const p=screen(x+.5,y+.5),t=tileSize(),h=tileHeight();
    let color=TRAITS[type]||TRAITS.grass;
    if(type==='grass')color=(x*17+y*11)%9<3?'#719064':(x*13+y*19)%7<2?'#5e8158':'#66885e';
    diamond(p.x,p.y,1.016,color,'#324f3e47');
    if(type==='grass'){
      const k=(x*29+y*17)%7;
      if(k<3){line(p.x-t*.19,p.y+h*.07,p.x-t*.17,p.y-h*.025,'#b4ba7a66',1.6*zoom);
        line(p.x+t*.17,p.y-h*.025,p.x+t*.19,p.y-h*.092,'#d0c59477',1.3*zoom);}
    }else if(type==='water'){
      poly([[p.x,p.y-h*.39],[p.x+t*.43,p.y],[p.x,p.y+h*.39],[p.x-t*.43,p.y]],'#508ca0');
      line(p.x-t*.15,p.y-h*.05,p.x+t*.10,p.y-h*.11,'#a5d5d7a8',1.5*zoom);
    }else if(type==='hills'){
      poly([[p.x-t*.20,p.y+h*.08],[p.x-t*.015,p.y-h*.55],[p.x+t*.20,p.y+h*.06],[p.x,p.y+h*.22]],'#93836d');
      poly([[p.x-t*.20,p.y+h*.08],[p.x-t*.015,p.y-h*.55],[p.x,p.y+h*.22]],'#c0b295');
      line(p.x-t*.015,p.y-h*.55,p.x+t*.20,p.y+h*.06,'#e0d0a37d',1.5);
    }else if(type==='ruin'){
      diamond(p.x,p.y,.79,'#c1b390');
    }
  }
  function tree(x,y,variant=0){
    const p=screen(x+.5,y+.5),t=tileSize(),h=tileHeight();
    const lean=(variant%3-1)*t*.055;
    poly([[p.x-t*.20,p.y+h*.19],[p.x,p.y+h*.32],[p.x+t*.19,p.y+h*.15],[p.x,p.y]],'#183b2f40');
    ctx.fillStyle='#675338';ctx.fillRect(p.x-t*.028+lean,p.y-h*.51,t*.056,h*.60);
    for(const [height,wide,c] of [[.37,.30,'#24543f'],[.60,.27,'#326c4a'],[.83,.21,'#4a8153']]){
      poly([[p.x+lean,p.y-h*(height+1.13)],[p.x-t*wide+lean,p.y-h*height],[p.x+t*wide+lean,p.y-h*height]],c);
      line(p.x+lean,p.y-h*(height+1.12),p.x-t*wide*.65+lean,p.y-h*(height+.05),'#8da76c66',1.3);
    }
  }
  function ruins(x,y){
    const p=screen(x+.5,y+.5),t=tileSize(),h=tileHeight();
    diamond(p.x,p.y,.70,'#b5a68d');
    const block=(xx,yy,wide,high,fill)=>{ctx.fillStyle=fill;ctx.fillRect(xx,yy,wide,high);};
    block(p.x-t*.19,p.y-h*.78,t*.13,h*.87,'#d6c6a8');
    block(p.x-t*.15,p.y-h*.90,t*.23,h*.13,'#e2d4ba');
    block(p.x+t*.16,p.y-h*.55,t*.12,h*.62,'#cfc09e');
    block(p.x+t*.11,p.y-h*.65,t*.21,h*.13,'#dac8a6');
    if(!game.excavated.includes(id(x,y))){
      ctx.fillStyle='#fff0ac';ctx.textAlign='center';ctx.font=`bold ${Math.max(10,15*zoom)}px sans-serif`;
      ctx.fillText('?',p.x+t*.32,p.y-h*.53);
    }
  }
  function road(x,y){
    const p=screen(x+.5,y+.5),t=tileSize(),h=tileHeight();
    diamond(p.x,p.y,.46,'#957f62');
    const dirs=[[1,0],[-1,0],[0,1],[0,-1]];
    for(const [dx,dy] of dirs){
      const nx=x+dx,ny=y+dy;
      if(nx<0||nx>=W||ny<0||ny>=H||!game.roads[id(nx,ny)])continue;
      const np=screen(nx+.5,ny+.5);
      line(p.x,p.y,(p.x+np.x)/2,(p.y+np.y)/2,'#69563f',Math.max(5,t*.25));
      line(p.x,p.y,(p.x+np.x)/2,(p.y+np.y)/2,'#c0a27b',Math.max(3,t*.195));
      line(p.x,p.y,(p.x+np.x)/2,(p.y+np.y)/2,'#ddc29c77',Math.max(1,t*.025));
    }
    diamond(p.x,p.y,.30,'#b29a75');
    if((x+y)%3===0){line(p.x-t*.13,p.y+h*.035,p.x+t*.04,p.y+h*.07,'#f2d8ae66',1);}
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
  function drawBuilding(b){
    const {w:renderedWidth,h:imageHeight,p}=buildingRect(b),t=tileSize(),h=tileHeight(),connected=game.connected(b);
    diamond(p.x,p.y,.75,'#263d3180');
    if(!sprite(b.type,p.x,p.y+h*.33,renderedWidth,imageHeight)){
      diamond(p.x,p.y-.23*t,.84,COLORS[b.type]);
      ctx.textAlign='center';ctx.font=`bold ${Math.max(12,t*.32)}px sans-serif`;ctx.fillStyle='#f8eac6';
      ctx.fillText(DEF[b.type].symbol,p.x,p.y-h*.12);
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
    const ratio=clamp(site.progress/site.duration,0,1);
    const isRoad=site.type==='road';
    // Earthworks, footprint and material stacks exist before the final road/building.
    diamond(pos.x,pos.y,.89,'#705b46','#d7b98a',1.4);
    poly([[pos.x-t*.34,pos.y-h*.05],[pos.x,pos.y-h*.28],
      [pos.x+t*.30,pos.y-h*.04],[pos.x,pos.y+h*.19]],isRoad?'#a38a69':'#554c3d');
    if(isRoad){
      // A partially finished road is NOT part of the transport graph yet.
      diamond(pos.x,pos.y,.22+.60*ratio,'#bd9f79','#e4c696',1);
      for(let i=0;i<4;i++){
        const a=i*Math.PI/2+Math.PI/4;
        line(pos.x+Math.cos(a)*t*.13,pos.y+Math.sin(a)*h*.15,
          pos.x+Math.cos(a)*t*(.20+.08*ratio),pos.y+Math.sin(a)*h*(.20+.08*ratio),'#79614d',Math.max(1,2*zoom));
      }
    }else{
      // Silhouette materializes gradually, clipped by construction progress.
      const b={type:site.type,x:site.x,y:site.y};
      const rect=buildingRect(b);
      if(ratio>.035&&sprites[site.type]?.naturalWidth){
        ctx.save();ctx.beginPath();ctx.rect(rect.x,rect.y+rect.h*(1-ratio),rect.w,rect.h*ratio);ctx.clip();
        ctx.globalAlpha=.28+.65*ratio;
        sprite(site.type,rect.p.x,rect.p.y+h*.33,rect.w,rect.h);
        ctx.restore();
      }
      const tower=h*(1.9+.6*ratio),span=t*.45;
      for(const sign of [-1,1]){
        const x=pos.x+sign*span;
        line(x,pos.y+h*.18,x,pos.y-tower,'#ad7a43',Math.max(2.5,4*zoom));
        line(x,pos.y-tower*.65,x-sign*t*.19,pos.y-tower*.35,'#cf9a53',Math.max(1.7,2.5*zoom));
      }
      line(pos.x-span,pos.y-tower*.85,pos.x+span,pos.y-tower*.85,'#d9ae69',Math.max(2,3.2*zoom));
      line(pos.x-span,pos.y-tower*.48,pos.x+span,pos.y-tower*.48,'#d9ae69',Math.max(2,3.2*zoom));
    }
    // On-site wooden planks and progress badge.
    if(have>0){const count=Math.min(4,have);
      for(let k=0;k<count;k++)line(pos.x-t*.34,pos.y+h*(.17+k*.035),pos.x-t*.12,pos.y+h*(.06+k*.035),'#e0bd7a',Math.max(2,3*zoom));
    }
    const label=have<need?`▥ ${have}/${need}`:`⚒ ${Math.floor(ratio*100)}%`;
    ctx.save();ctx.textAlign='center';ctx.font=`bold ${Math.max(10,12.5*zoom)}px sans-serif`;
    ctx.lineWidth=3;ctx.strokeStyle='#29261d';ctx.fillStyle='#fff4cf';
    ctx.strokeText(label,pos.x,pos.y-tileHeight()*(isRoad?.75:2.0));
    ctx.fillText(label,pos.x,pos.y-tileHeight()*(isRoad?.75:2.0));ctx.restore();
    const bw=Math.max(26,t*.72),by=pos.y+h*(isRoad?.46:.22);
    ctx.fillStyle='#24332b';ctx.fillRect(pos.x-bw/2,by,bw,Math.max(3,5*zoom));
    ctx.fillStyle=have<need?'#c5a369':'#a5df9a';
    ctx.fillRect(pos.x-bw/2,by,bw*(have<need?Math.min(1,have/Math.max(1,need))*.32:.32+.68*ratio),Math.max(3,5*zoom));
  }
  function drawBuilder(b){
    const p=screen(b.x+.5,b.y+.5),t=tileSize(),h=tileHeight();
    ctx.fillStyle='#111c1755';ctx.beginPath();ctx.ellipse(p.x,p.y+h*.13,t*.115,h*.13,0,0,Math.PI*2);ctx.fill();
    const bob=b.phase==='travel'&&!paused?Math.sin(performance.now()*.008+b.id*1.6)*h*.05:0;
    const size=t*.34;
    if(!sprite('carrier',p.x,p.y+h*.15+bob,size,size*1.72)){
      ctx.fillStyle='#eab56b';ctx.beginPath();ctx.arc(p.x,p.y-h*.20,Math.max(3,t*.075),0,Math.PI*2);ctx.fill();
    }
    if(b.site!==null){ctx.textAlign='center';ctx.font=`bold ${Math.max(10,t*.21)}px sans-serif`;
      ctx.fillStyle='#ffe5a1';ctx.fillText('⚒',p.x+t*.20,p.y-h*.20);}
  }
  function drawCarrier(c){
    const p=screen(c.x+.5,c.y+.5),t=tileSize(),h=tileHeight();
    ctx.fillStyle='#172c2955';ctx.beginPath();ctx.ellipse(p.x,p.y+h*.10,t*.13,h*.14,0,0,Math.PI*2);ctx.fill();
    const step=c.job&&!paused?Math.sin(performance.now()*.009+c.id*2)*h*.09:0;
    const size=t*.48;
    if(!sprite('carrier',p.x,p.y+h*.17+step,size,size*1.75)){
      ctx.fillStyle=c.carrying?'#efc782':'#f1deab';ctx.beginPath();ctx.arc(p.x,p.y-h*.25,Math.max(3,t*.105),0,Math.PI*2);ctx.fill();
    }
    if(c.carrying){ctx.fillStyle='#f8e5a3';ctx.font=`bold ${Math.max(9,t*.18)}px sans-serif`;ctx.textAlign='center';ctx.fillText(c.carrying.amount,p.x+t*.2,p.y-h*.30);}
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
    }
    for(const b of game.buildings)if(visible(screen(b.x+.5,b.y+.5)))objects.push({x:b.x,y:b.y,depth:b.x+b.y+.75,type:'building',b});
    for(const site of game.construction)if(visible(screen(site.x+.5,site.y+.5)))objects.push({x:site.x,y:site.y,depth:site.x+site.y+.73,type:'site',site});
    for(const b of game.builders)if(visible(screen(b.x+.5,b.y+.5)))objects.push({x:b.x,y:b.y,depth:b.x+b.y+.90,type:'builder',b});
    for(const c of game.carriers)if(visible(screen(c.x+.5,c.y+.5)))objects.push({x:c.x,y:c.y,depth:c.x+c.y+.90,type:'carrier',c});
    objects.sort((a,b)=>a.depth-b.depth||a.x-b.x);
    for(const o of objects){
      if(o.type==='forest')tree(o.x,o.y,(o.x*5+o.y*9)%6);
      else if(o.type==='ruin')ruins(o.x,o.y);
      else if(o.type==='building')drawBuilding(o.b);
      else if(o.type==='site')drawSite(o.site);
      else if(o.type==='builder')drawBuilder(o.b);
      else drawCarrier(o.c);
    }
    const mission=game.missionProgress();
    if(mission.target&&mission.stage!==3){
      const spot=screen(mission.target.x+.5,mission.target.y+.5);
      const pulse=.62+.24*Math.sin(performance.now()*.003);
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
      $('missionStep').textContent='СВОБОДНАЯ ИГРА';$('missionTitle').textContent='Развивай поселение';
      $('missionText').textContent='Строй дороги, прокладывай цепочки снабжения и исследуй мир в собственном темпе.';
      $('missionDetail').textContent='Ты можешь начать испытание кнопкой «Новое испытание» внизу страницы.';
      $('missionFill').style.width='100%';focus.hidden=true;tool.hidden=true;choose.hidden=true;return;
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
      fill.style.width=`${Math.round(site.delivered<site.boards?site.delivered/Math.max(1,site.boards)*30:30+70*site.progress/site.duration)}%`;
      progress.append(fill);
      const details=document.createElement('small');details.textContent=`Доски ${site.delivered}/${site.boards} · работа ${Math.floor(site.progress/site.duration*100)}%`;
      row.append(name,where,progress,details);sites.append(row);
    }
    $('dayStat').textContent=hud.day;$('coinStat').textContent=hud.coins;
    $('popStat').textContent=hud.population;$('moraleStat').textContent=hud.morale+'%';
    for(const k of ['science','culture','diplomacy','military'])$(k+'Stat').textContent=hud[k];
    for(const k of ['logs','boards','grain','flour','bread'])$(k+'Stock').textContent=hud.goods[k];
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
  }
  function act(cell){
    const {x,y}=cell;if(x<0||x>=W||y<0||y>=H){notify('За пределами карты');return;}
    if(mode==='inspect'){inspectAt(x,y);return;}
    if(mode==='excavate'){
      const result=game.excavate(x,y);if(!result.ok)notify(result.error);
      else{notify('Найденная печать пополнила знания и культурное наследие.');persist();}
      inspectAt(x,y);updateHUD();return;
    }
    const result=game.build(mode,x,y);
    if(!result.ok)notify(result.error);
    else{notify(mode==='road'?'Дорожная стройка заложена — ждём носильщика и строителей.':DEF[mode].name+': площадка заложена, материалы в пути.');inspectAt(x,y);persist();}
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
    game=new Game().startMission();stageShown=-2;winShown=false;selectTool('road');camera.x=17;camera.y=10;setPaused(false);persist();updateHUD();notify('Начато первое испытание!');
  });
  $('freeBtn').addEventListener('click',()=>{
    if(!window.confirm('Начать свободную игру без задач? Текущий прогресс будет заменён.'))return;
    game=new Game();stageShown=-2;winShown=false;camera.x=10;camera.y=10;selectTool('inspect');setPaused(false);persist();updateHUD();notify('Свободное поселение основано.');
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
  resize();selectTool(!restored?'road':'inspect');updateHUD();
  if(restored)notify('Прогресс поселения восстановлен.');
  function loop(now){
    if(!last)last=now;
    const dt=Math.max(0,Math.min(.08,(now-last)/1000));last=now;
    if(!paused)game.step(dt*speed);
    // At most 60 render updates per second; simulation time uses actual frame delta.
    if(now-lastDraw>=16.6){draw();lastDraw=now;}
    if(now-lastHud>=450){updateHUD();lastHud=now;}
    if(now-lastSave>=15000){persist();lastSave=now;}
    if(toastUntil&&now>toastUntil){$('toast').classList.remove('visible');toastUntil=0;}
    requestAnimationFrame(loop);
  }
  requestAnimationFrame(loop);
  window.__strategyDebug=()=>({day:game.day,coins:game.coins,resources:{...game.warehouse().goods},
    buildings:game.buildings.length,sites:game.construction.map(s=>({type:s.type,x:s.x,y:s.y,boards:s.goods.boards,required:s.required.boards,progress:s.progress,duration:s.duration})),builders:game.builders.map(b=>({site:b.site,phase:b.phase,x:b.x,y:b.y})),carriers:game.carriers.filter(c=>c.job).length,science:game.science,
    culture:game.culture,diplomacy:game.diplomacy,military:game.military,mission:game.missionProgress(),paused,mode,zoom,projection:'isometric',spritesReady,screen:(x,y)=>screen(x+.5,y+.5),step:(n)=>{for(let i=0;i<n*10;i++)game.step(.1);updateHUD();draw();}});
})();
