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
  return {TILE,HEIGHT_SCALE,geometry,render,pick,summary,barycentric};
});