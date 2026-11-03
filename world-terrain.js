/* Высотная модель карты: общие вершины, геометрия склонов, детерминированный рельеф. */
(function(root,factory){
  const api=factory();
  if(typeof module==='object'&&module.exports)module.exports=api;
  if(root)root.StrategyTerrain=api;
})(typeof globalThis==='object'?globalThis:this,function(){
  'use strict';

  const REGIONS=[
    {id:'plain',name:'Равнина',x:.37,y:.67},
    {id:'lowland',name:'Низина',x:.13,y:.75},
    {id:'hills',name:'Холмы',x:.21,y:.27},
    {id:'ravine',name:'Овраг',x:.49,y:.49},
    {id:'plateau',name:'Плоскогорье',x:.72,y:.27},
    {id:'mountains',name:'Горы',x:.84,y:.76}
  ];
  const clamp=(value,min,max)=>Math.max(min,Math.min(max,value));
  const smooth=(a,b,v)=>{
    const t=clamp((v-a)/(b-a),0,1);
    return t*t*(3-2*t);
  };
  const gaussian=(x,y,cx,cy,rx,ry)=>{
    const a=(x-cx)/rx,b=(y-cy)/ry;
    return Math.exp(-2*(a*a+b*b));
  };
  function hash(x,y,seed){
    let n=(Math.imul(x,374761393)+Math.imul(y,668265263)+
      Math.imul(seed,1442695041))|0;
    n=Math.imul(n^(n>>>13),1274126177);
    return ((n^(n>>>16))>>>0)/4294967295;
  }
  function noise(x,y,seed){
    const i=Math.floor(x),j=Math.floor(y),u=smooth(0,1,x-i),v=smooth(0,1,y-j);
    const a=hash(i,j,seed)*(1-u)+hash(i+1,j,seed)*u;
    const b=hash(i,j+1,seed)*(1-u)+hash(i+1,j+1,seed)*u;
    return (a*(1-v)+b*v)*2-1;
  }
  function shapes(u,v){
    const hills=gaussian(u,v,.21,.28,.16,.24);
    const lowland=gaussian(u,v,.14,.76,.19,.18);
    const mesaRadius=Math.hypot((u-.71)/.15,(v-.28)/.21);
    const plateau=1-smooth(.78,1.37,mesaRadius);
    const curved=.50+.045*Math.sin(v*12.5+1.2);
    const trench=Math.exp(-.5*((u-curved)/.035)**2);
    const ravine=trench*smooth(.12,.26,v)*(1-smooth(.78,.96,v));
    const mountains=gaussian(u,v,.85,.73,.17,.30);
    const ridge=gaussian(u,v,.90,.59,.092,.16);
    return {hills,lowland,plateau,ravine,mountains,ridge};
  }
  function sampleHeight(x,y,width,height,seed){
    const u=x/width,v=y/height,s=shapes(u,v);
    const gentle=.30*noise(x/6,y/6,seed)+.12*noise(x/2.6,y/2.6,seed+17);
    const undulation=.24+gentle;
    const hills=2.9*s.hills*(.78+.22*Math.cos(u*52+v*19));
    const lowland=-2.6*s.lowland;
    const mesa=4.9*s.plateau;
    const trench=-3.2*s.ravine;
    const ridge=6.9*s.mountains*(.72+.28*Math.sin(u*62-v*33)**2)+
      2.6*s.ridge;
    const flatness=1-.82*s.plateau;
    return undulation*flatness+hills+lowland+mesa+trench+ridge;
  }
  function regionAt(x,y,width,height){
    const u=x/width,v=y/height,s=shapes(u,v);
    if(s.mountains>.16||s.ridge>.34)return 'mountains';
    if(s.plateau>.28)return 'plateau';
    if(s.ravine>.28)return 'ravine';
    if(s.lowland>.25)return 'lowland';
    if(s.hills>.25)return 'hills';
    return 'plain';
  }
  function create(width,height,seed=1729){
    if(!Number.isInteger(width)||!Number.isInteger(height)||
       width<2||height<2||width>512||height>512)
      throw new RangeError('Недопустимый размер карты высот');
    const vertices=new Float32Array((width+1)*(height+1));
    let min=Infinity,max=-Infinity;
    for(let y=0;y<=height;y++)for(let x=0;x<=width;x++){
      const h=sampleHeight(x,y,width,height,seed|0);
      vertices[y*(width+1)+x]=h;
      min=Math.min(min,h);max=Math.max(max,h);
    }
    const vertexAt=(x,y)=>{
      if(!Number.isInteger(x)||!Number.isInteger(y)||
         x<0||x>width||y<0||y>height)
        throw new RangeError('Вершина за пределами карты');
      return vertices[y*(width+1)+x];
    };
    function triangle(x,y){
      if(!Number.isFinite(x)||!Number.isFinite(y)||
        x<0||y<0||x>width||y>height)
        throw new RangeError('Точка за пределами карты');
      const i=Math.min(width-1,Math.floor(x));
      const j=Math.min(height-1,Math.floor(y));
      const u=x-i,v=y-j;
      const h00=vertexAt(i,j),h10=vertexAt(i+1,j);
      const h01=vertexAt(i,j+1),h11=vertexAt(i+1,j+1);
      if(u+v<=1)return {height:h00+(h10-h00)*u+(h01-h00)*v,
        dx:h10-h00,dy:h01-h00};
      return {height:h11+(h01-h11)*(1-u)+(h10-h11)*(1-v),
        dx:h11-h01,dy:h11-h10};
    }
    const heightAt=(x,y)=>triangle(x,y).height;
    const slopeAt=(x,y)=>Math.hypot(triangle(x,y).dx,triangle(x,y).dy);
    function normalAt(x,y){
      const t=triangle(x,y),length=Math.hypot(t.dx,t.dy,1);
      return {x:-t.dx/length,y:-t.dy/length,z:1/length};
    }
    return Object.freeze({
      width,height,seed:seed|0,vertices,minimum:min,maximum:max,
      vertexAt,heightAt,slopeAt,normalAt,
      regionAt:(x,y)=>regionAt(x,y,width,height),
      regions:REGIONS.map(r=>({...r,x:r.x*width,y:r.y*height})),
      // Физический мир пока не подключён к старой экономике.
      gameplayConnected:false
    });
  }
  function project(x,y,z=0,{tileWidth=82,heightScale=18,originX=0,originY=0}={}){
    return {x:originX+(x-y)*tileWidth/2,
      y:originY+(x+y)*tileWidth/4-z*heightScale};
  }
  function unproject(x,y,z=0,{tileWidth=82,heightScale=18,originX=0,originY=0}={}){
    const a=(x-originX)/(tileWidth/2);
    const b=(y-originY+z*heightScale)/(tileWidth/4);
    return {x:(a+b)/2,y:(b-a)/2,z};
  }
  return {create,project,unproject,REGIONS};
});