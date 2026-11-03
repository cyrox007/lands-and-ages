/* Поиск пути и ориентация персонажа в изометрической сетке. */
(function(root,factory){
  const api=factory();
  if(typeof module==='object'&&module.exports)module.exports=api;
  if(root)root.StrategyNavigation=api;
})(typeof globalThis==='object'?globalThis:this,function(){
  'use strict';

  const SIDES=[[1,0],[0,1],[-1,0],[0,-1]];
  const cell=point=>({x:Math.floor(point.x),y:Math.floor(point.y)});
  const inside=(x,y,w,h)=>x>=0&&x<w&&y>=0&&y<h;
  const distance=(a,b)=>Math.abs(a.x-b.x)+Math.abs(a.y-b.y);
  const centre=point=>({x:point.x+.5,y:point.y+.5});

  function facing(from,to,fallback='se'){
    if(!from||!to)return fallback;
    const dx=to.x-from.x,dy=to.y-from.y;
    if(Math.abs(dx)+Math.abs(dy)<.00001)return fallback;
    const horizontal=dx-dy,vertical=dx+dy;
    return (vertical<0?'n':'s')+(horizontal<0?'w':'e');
  }

  function route(w,h,from,to,walkable){
    if(!from||!to)return null;
    const start=cell(from),goal=cell(to);
    if(!inside(start.x,start.y,w,h)||!inside(goal.x,goal.y,w,h)||
       !walkable(start.x,start.y)||!walkable(goal.x,goal.y))return null;
    const begin=start.y*w+start.x,end=goal.y*w+goal.x;
    const best=new Float64Array(w*h).fill(Infinity);
    const previous=new Int32Array(w*h).fill(-1);
    const settled=new Uint8Array(w*h),open=[begin];
    best[begin]=0;
    while(open.length){
      let bestIndex=0,bestScore=Infinity;
      for(let i=0;i<open.length;i++){
        const node=open[i],x=node%w,y=Math.floor(node/w);
        const score=best[node]+Math.abs(goal.x-x)+Math.abs(goal.y-y);
        if(score<bestScore){bestScore=score;bestIndex=i;}
      }
      const node=open.splice(bestIndex,1)[0];
      if(settled[node])continue;
      if(node===end){
        const points=[];
        for(let n=end;n!==-1;n=previous[n])
          points.push({x:n%w,y:Math.floor(n/w)});
        return points.reverse();
      }
      settled[node]=1;
      const x=node%w,y=Math.floor(node/w);
      for(const [dx,dy] of SIDES){
        const nx=x+dx,ny=y+dy;
        if(!inside(nx,ny,w,h)||!walkable(nx,ny))continue;
        const next=ny*w+nx;
        if(settled[next]||best[node]+1>=best[next])continue;
        best[next]=best[node]+1;previous[next]=node;open.push(next);
      }
    }
    return null;
  }

  function perimeter(object,w,h){
    const width=object.size?.w||1,height=object.size?.h||1;
    const result=[],visited=new Set();
    for(let y=object.y;y<object.y+height;y++)
      for(let x=object.x;x<object.x+width;x++)
        for(const [dx,dy] of SIDES){
          const tx=x+dx,ty=y+dy,key=ty*w+tx;
          if(!inside(tx,ty,w,h)||visited.has(key)||
             (tx>=object.x&&tx<object.x+width&&
              ty>=object.y&&ty<object.y+height))continue;
          visited.add(key);result.push({x:tx,y:ty});
        }
    return result;
  }

  function approach(w,h,from,object,walkable){
    let selected=null;
    for(const target of perimeter(object,w,h)){
      if(!walkable(target.x,target.y))continue;
      const path=route(w,h,from,target,walkable);
      if(!path)continue;
      if(!selected||path.length<selected.length)selected=path;
    }
    return selected;
  }

  function nearest(w,h,from,walkable){
    if(!from)return null;
    const start=cell(from);
    if(!inside(start.x,start.y,w,h))return null;
    if(walkable(start.x,start.y))return start;
    const visited=new Uint8Array(w*h),queue=[start];
    visited[start.y*w+start.x]=1;
    for(let i=0;i<queue.length;i++){
      const {x,y}=queue[i];
      for(const [dx,dy] of SIDES){
        const nx=x+dx,ny=y+dy;
        if(!inside(nx,ny,w,h))continue;
        const key=ny*w+nx;
        if(visited[key])continue;
        if(walkable(nx,ny))return {x:nx,y:ny};
        visited[key]=1;queue.push({x:nx,y:ny});
      }
    }
    return null;
  }

  // Положение видимого ствола совпадает с разбросом в рендере деревьев.
  function treeCentre(x,y){
    const dx=((x*23+y*37+x*y*3)%19-9)*.037;
    const dy=((x*17+y*13+x*y*5)%17-8)*.037;
    return {x:x+.5+dx,y:y+.5+dy};
  }

  function treeTrunk(x,y){
    const base=treeCentre(x,y);
    // Нижняя точка спрайта находится выше экранной опоры рабочего на 0,1h.
    return {x:base.x-.1,y:base.y-.1};
  }

  function contactPoint(approachCell,anchor,margin=.08){
    const clamp=(value,min,max)=>Math.max(min,Math.min(max,value));
    return {
      x:clamp(anchor.x,approachCell.x+margin,approachCell.x+1-margin),
      y:clamp(anchor.y,approachCell.y+margin,approachCell.y+1-margin)
    };
  }

  function screenDistance(from,to,tileSize=82){
    const dx=from.x-to.x,dy=from.y-to.y;
    return Math.hypot((dx-dy)*tileSize/2,(dx+dy)*tileSize/4);
  }

  function atContact(agent,target,anchor,tolerance=.09){
    const workerCell=cell(agent),targetCell=cell(target);
    if(distance(workerCell,targetCell)!==1)return false;
    const contact=contactPoint(workerCell,anchor);
    return Math.hypot(agent.x-contact.x,agent.y-contact.y)<=tolerance;
  }

  return {SIDES,cell,centre,distance,facing,route,perimeter,approach,nearest,
    treeCentre,treeTrunk,contactPoint,screenDistance,atContact};
});
