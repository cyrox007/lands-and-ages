/* Просмотр настоящей сетки высот на действующей тестовой карте. */
(function(root,factory){
  const api=factory(typeof module==='object'&&module.exports?
    require('./world-terrain.js'):root.StrategyTerrain);
  if(typeof module==='object'&&module.exports)module.exports=api;
  if(root)root.StrategyReliefPreview=api;
})(typeof globalThis==='object'?globalThis:this,function(Terrain){
  'use strict';

  const TILE=82,HEIGHT_SCALE=18;
  const PALETTE={
    plain:[109,25,43],lowland:[163,25,36],hills:[91,31,43],
    ravine:[27,27,39],plateau:[58,25,49],mountains:[204,11,49]
  };
  function barycentric(point,a,b,c){
    const denominator=(b.y-c.y)*(a.x-c.x)+(c.x-b.x)*(a.y-c.y);
    if(Math.abs(denominator)<1e-9)return null;
    const u=((b.y-c.y)*(point.x-c.x)+(c.x-b.x)*(point.y-c.y))/denominator;
    const v=((c.y-a.y)*(point.x-c.x)+(a.x-c.x)*(point.y-c.y))/denominator;
    const w=1-u-v;
    return Math.min(u,v,w)>=-0.0001?{u,v,w}:null;
  }
  function geometry(model){
    const originX=(model.height+1)*TILE/2+38;
    const originY=Math.ceil(model.maximum)*HEIGHT_SCALE+43;
    const width=Math.ceil((model.width+model.height+2)*TILE/2+80);
    const height=Math.ceil(originY+(model.width+model.height)*TILE/4-
      (model.minimum-1.8)*HEIGHT_SCALE+56);
    const options={tileWidth:TILE,heightScale:HEIGHT_SCALE,originX,originY};
    const vertex=(x,y)=>Terrain.project(x,y,model.vertexAt(x,y),options);
    return {originX,originY,width,height,vertex,options};
  }
  function tiles(model,mesh){
    const result=[];
    for(let y=0;y<model.height;y++)for(let x=0;x<model.width;x++){
      const p00=mesh.vertex(x,y),p10=mesh.vertex(x+1,y);
      const p01=mesh.vertex(x,y+1),p11=mesh.vertex(x+1,y+1);
      result.push({x,y,kind:model.regionAt(x+.5,y+.5),
        normal:model.normalAt(x+.5,y+.5),
        triangles:[[p00,p10,p01],[p11,p01,p10]],
        world:[[{x,y},{x:x+1,y},{x,y:y+1}],
          [{x:x+1,y:y+1},{x,y:y+1},{x:x+1,y}]]});
    }
    result.sort((a,b)=>a.x+a.y-b.x-b.y||a.x-b.x);
    return result;
  }
  function polygon(ctx,points,fill,stroke=null){
    ctx.beginPath();ctx.moveTo(points[0].x,points[0].y);
    for(let i=1;i<points.length;i++)ctx.lineTo(points[i].x,points[i].y);
    ctx.closePath();ctx.fillStyle=fill;ctx.fill();
    if(stroke){ctx.strokeStyle=stroke;ctx.lineWidth=.38;ctx.stroke();}
  }
  function color(kind,normal,variation=0){
    const [h,s,l]=PALETTE[kind]||PALETTE.plain;
    const light=Math.max(.48,Math.min(1.25,.79+normal.z*.17+
      normal.x*.35+normal.y*.32));
    return 'hsl('+h+','+s+'%,'+Math.max(19,Math.min(69,
      l*light+variation)).toFixed(1)+'%)';
  }
  function contours(ctx,model,entries){
    ctx.save();ctx.lineWidth=.55;ctx.strokeStyle='rgba(27,38,30,.36)';
    const start=Math.floor(model.minimum),end=Math.ceil(model.maximum);
    for(const tile of entries){
      for(let k=0;k<2;k++){
        const points=tile.triangles[k],world=tile.world[k];
        const heights=world.map(p=>model.vertexAt(p.x,p.y));
        for(let level=start;level<=end;level+=1.5){
          const intersections=[];
          for(const [a,b] of [[0,1],[1,2],[2,0]]){
            const h0=heights[a],h1=heights[b];
            if((level<=h0&&level<=h1)||(level>h0&&level>h1)||
              Math.abs(h1-h0)<1e-8)continue;
            const t=(level-h0)/(h1-h0);
            intersections.push({x:points[a].x+(points[b].x-points[a].x)*t,
              y:points[a].y+(points[b].y-points[a].y)*t});
          }
          if(intersections.length!==2)continue;
          ctx.beginPath();ctx.moveTo(intersections[0].x,intersections[0].y);
          ctx.lineTo(intersections[1].x,intersections[1].y);ctx.stroke();
        }
      }
    }
    ctx.restore();
  }
  function sides(ctx,model,mesh){
    const base=model.minimum-1.8,basePoint=(x,y)=>
      Terrain.project(x,y,base,mesh.options);
    for(let x=0;x<model.width;x++){
      polygon(ctx,[mesh.vertex(x,model.height),mesh.vertex(x+1,model.height),
        basePoint(x+1,model.height),basePoint(x,model.height)],
        '#435747','rgba(26,43,36,.55)');
    }
    for(let y=0;y<model.height;y++){
      polygon(ctx,[mesh.vertex(model.width,y),mesh.vertex(model.width,y+1),
        basePoint(model.width,y+1),basePoint(model.width,y)],
        '#334b42','rgba(22,37,30,.55)');
    }
  }
  function render(model){
    const mesh=geometry(model),canvas=document.createElement('canvas');
    canvas.width=mesh.width;canvas.height=mesh.height;
    const ctx=canvas.getContext('2d',{alpha:true}),entries=tiles(model,mesh);
    ctx.clearRect(0,0,canvas.width,canvas.height);
    for(const tile of entries){
      const base=color(tile.kind,tile.normal);
      for(const triangle of tile.triangles)
        polygon(ctx,triangle,base,'rgba(35,48,35,.13)');
    }
    contours(ctx,model,entries);
    sides(ctx,model,mesh);
    return {...mesh,canvas,triangles:entries.length*2};
  }
  function pick(model,mesh,x,y,origin,zoom=1){
    const target={x:(x-origin.x)/zoom+mesh.originX,
      y:(y-origin.y)/zoom+mesh.originY};
    let result=null;
    for(const entry of tiles(model,mesh)){
      for(let i=0;i<2;i++){
        const factors=barycentric(target,...entry.triangles[i]);
        if(!factors)continue;
        const points=entry.world[i],weights=[factors.u,factors.v,factors.w];
        const px=weights.reduce((sum,w,k)=>sum+w*points[k].x,0);
        const py=weights.reduce((sum,w,k)=>sum+w*points[k].y,0);
        result={x:px,y:py,z:model.heightAt(px,py),
          region:model.regionAt(px,py),cell:{x:entry.x,y:entry.y}};
      }
    }
    return result;
  }
  function summary(model){
    const counts={};
    for(let y=0;y<model.height;y++)for(let x=0;x<model.width;x++){
      const region=model.regionAt(x+.5,y+.5);
      counts[region]=(counts[region]||0)+1;
    }
    return {width:model.width,height:model.height,seed:model.seed,
      minimum:model.minimum,maximum:model.maximum,regions:counts,
      vertices:model.vertices.length,connected:model.gameplayConnected};
  }

  // Большой мир рисуется только видимыми чанками. Цельный Canvas не создаётся.
  const CHUNK_SIZE=16,CACHE_LIMIT=16;
  const SURFACE_COLORS={
    grass:[103,30,42],bare:[33,36,43],soil:[33,36,43],
    sand:[42,40,62],rock:[36,11,45],snow:[206,24,86],
    water:[194,43,46],ice:[194,34,75]
  };
  function surfaceColor(surface,normal){
    const [h,s,l]=SURFACE_COLORS[surface.cover]||SURFACE_COLORS.grass;
    const lighting=Math.max(.66,Math.min(1.17,.86+normal.z*.16+
      normal.x*.27+normal.y*.24));
    const variation=(surface.soil.fertility-.5)*5;
    return 'hsl('+h+','+s+'%,'+
      Math.max(21,Math.min(91,l*lighting+variation)).toFixed(1)+'%)';
  }
  function renderChunk(model,environment,cx,cy,day,size=CHUNK_SIZE){
    const x0=cx*size,y0=cy*size;
    if(x0<0||y0<0||x0>=model.width||y0>=model.height)
      throw new RangeError('Чанк вне карты');
    const w=Math.min(size,model.width-x0),h=Math.min(size,model.height-y0);
    const left=-h*TILE/2-3,top=-(model.maximum+2)*HEIGHT_SCALE-3;
    const canvas=document.createElement('canvas');
    canvas.width=Math.ceil((w+h)*TILE/2+6);
    canvas.height=Math.ceil((w+h)*TILE/4+
      (model.maximum-model.minimum+4)*HEIGHT_SCALE+6);
    const ctx=canvas.getContext('2d',{alpha:true});
    const vertex=(x,y)=>Terrain.project(x-x0,y-y0,model.vertexAt(x,y),
      {tileWidth:TILE,heightScale:HEIGHT_SCALE,originX:-left,originY:-top});
    const entries=[];
    for(let y=y0;y<y0+h;y++)for(let x=x0;x<x0+w;x++){
      const p00=vertex(x,y),p10=vertex(x+1,y);
      const p01=vertex(x,y+1),p11=vertex(x+1,y+1);
      entries.push({x,y,normal:model.normalAt(x+.5,y+.5),
        surface:environment.surfaceAt(x,y,day),
        triangles:[[p00,p10,p01],[p11,p01,p10]],
        world:[[{x,y},{x:x+1,y},{x,y:y+1}],
          [{x:x+1,y:y+1},{x,y:y+1},{x:x+1,y}]]});
    }
    entries.sort((a,b)=>a.x+a.y-b.x-b.y||a.x-b.x);
    for(const tile of entries){
      const fill=surfaceColor(tile.surface,tile.normal);
      for(const triangle of tile.triangles)
        polygon(ctx,triangle,fill,'rgba(30,39,36,.11)');
    }
    contours(ctx,model,entries);
    return {x:x0,y:y0,left,top,canvas,day,tiles:entries.length};
  }
  function drawVisible(model,environment,ctx,{width,height,zoom,screen,worldAt,
    day,cache=new Map(),chunkSize=CHUNK_SIZE}){
    const bounds={minX:Infinity,minY:Infinity,maxX:-Infinity,maxY:-Infinity};
    for(const elevation of [model.minimum,model.maximum]){
      for(const px of [-TILE*zoom,width+TILE*zoom])
        for(const py of [-TILE*zoom,height+TILE*zoom]){
          const p=worldAt(px,py+elevation*HEIGHT_SCALE*zoom);
          bounds.minX=Math.min(bounds.minX,p.x);
          bounds.minY=Math.min(bounds.minY,p.y);
          bounds.maxX=Math.max(bounds.maxX,p.x);
          bounds.maxY=Math.max(bounds.maxY,p.y);
        }
    }
    const maxCx=Math.ceil(model.width/chunkSize)-1;
    const maxCy=Math.ceil(model.height/chunkSize)-1;
    const minCx=Math.max(0,Math.floor(bounds.minX/chunkSize));
    const minCy=Math.max(0,Math.floor(bounds.minY/chunkSize));
    const endCx=Math.min(maxCx,Math.floor(bounds.maxX/chunkSize));
    const endCy=Math.min(maxCy,Math.floor(bounds.maxY/chunkSize));
    const chunks=[];
    for(let cy=minCy;cy<=endCy;cy++)
      for(let cx=minCx;cx<=endCx;cx++)chunks.push({cx,cy});
    chunks.sort((a,b)=>a.cx+a.cy-b.cx-b.cy||a.cx-b.cx);
    let rendered=0;
    for(const {cx,cy} of chunks){
      const key=day+':'+cx+':'+cy;
      let chunk=cache.get(key);
      if(!chunk){
        chunk=renderChunk(model,environment,cx,cy,day,chunkSize);
        cache.set(key,chunk);rendered++;
        if(cache.size>CACHE_LIMIT)cache.delete(cache.keys().next().value);
      }else{
        cache.delete(key);cache.set(key,chunk);
      }
      const p=screen(chunk.x,chunk.y);
      ctx.drawImage(chunk.canvas,p.x+chunk.left*zoom,p.y+chunk.top*zoom,
        chunk.canvas.width*zoom,chunk.canvas.height*zoom);
    }
    return {visibleChunks:chunks.length,renderedChunks:rendered,cachedChunks:cache.size};
  }
  function pickAt(model,px,py,{screen,worldAt,zoom=1}){
    const candidates=new Set();
    const samples=Math.max(3,Math.ceil((model.maximum-model.minimum)*2));
    for(let k=0;k<=samples;k++){
      const z=model.minimum+(model.maximum-model.minimum)*k/samples;
      const p=worldAt(px,py+z*HEIGHT_SCALE*zoom);
      for(let dy=-1;dy<=1;dy++)for(let dx=-1;dx<=1;dx++){
        const x=Math.floor(p.x)+dx,y=Math.floor(p.y)+dy;
        if(x>=0&&y>=0&&x<model.width&&y<model.height)
          candidates.add(y*model.width+x);
      }
    }
    let result=null;
    for(const index of candidates){
      const x=index%model.width,y=Math.floor(index/model.width);
      const vertex=(vx,vy)=>{
        const p=screen(vx,vy);
        p.y-=model.vertexAt(vx,vy)*HEIGHT_SCALE*zoom;
        return p;
      };
      const p00=vertex(x,y),p10=vertex(x+1,y);
      const p01=vertex(x,y+1),p11=vertex(x+1,y+1);
      const tris=[[p00,p10,p01],[p11,p01,p10]];
      const world=[[{x,y},{x:x+1,y},{x,y:y+1}],
        [{x:x+1,y:y+1},{x,y:y+1},{x:x+1,y}]];
      for(let i=0;i<2;i++){
        const bary=barycentric({x:px,y:py},...tris[i]);
        if(!bary)continue;
        const points=world[i],weights=[bary.u,bary.v,bary.w];
        const wx=weights.reduce((sum,v,j)=>sum+v*points[j].x,0);
        const wy=weights.reduce((sum,v,j)=>sum+v*points[j].y,0);
        if(!result||x+y>result.cell.x+result.cell.y)
          result={x:wx,y:wy,z:model.heightAt(wx,wy),
            region:model.regionAt(wx,wy),cell:{x,y}};
      }
    }
    return result;
  }
  return {TILE,HEIGHT_SCALE,geometry,render,pick,summary,barycentric,
    renderChunk,drawVisible,pickAt,CHUNK_SIZE};
});