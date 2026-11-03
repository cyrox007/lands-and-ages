/* Региональный климат и многослойная поверхность большого мира. */
(function(root,factory){
  const api=factory(typeof module==='object'&&module.exports?
    require('./world-terrain.js'):root.StrategyTerrain);
  if(typeof module==='object'&&module.exports)module.exports=api;
  if(root)root.StrategyEnvironment=api;
})(typeof globalThis==='object'?globalThis:this,function(Terrain){
  'use strict';
  const REGION_SIZE=64,SEASON_DAYS=24;
  const SEASONS=['Весна','Лето','Осень','Зима'];
  const clamp=(n,a,b)=>Math.max(a,Math.min(b,n));
  function hash(x,y,seed){
    let n=(Math.imul(x,374761393)+Math.imul(y,668265263)+Math.imul(seed,1442695041))|0;
    n=Math.imul(n^(n>>>13),1274126177);
    return ((n^(n>>>16))>>>0)/4294967296;
  }
  function seasonAt(day,seasonDays=SEASON_DAYS){
    if(!Number.isInteger(day)||day<1)throw new RangeError('Некорректный игровой день');
    const index=Math.floor((day-1)/seasonDays)%4;
    return {index,name:SEASONS[index],day:((day-1)%seasonDays)+1,
      year:Math.floor((day-1)/(seasonDays*4))+1};
  }
  function create(terrain,{regionSize=REGION_SIZE,seasonDays=SEASON_DAYS}={}){
    if(!terrain||typeof terrain.heightAt!=='function'||!Number.isInteger(regionSize)||
       regionSize<16||!Number.isInteger(seasonDays)||seasonDays<2)
      throw new TypeError('Некорректная модель природного мира');
    const seed=terrain.seed|0;
    const columns=Math.ceil(terrain.width/regionSize);
    const rows=Math.ceil(terrain.height/regionSize);
    const regions=[];
    for(let ry=0;ry<rows;ry++)for(let rx=0;rx<columns;rx++){
      const x=rx*regionSize,y=ry*regionSize;
      const width=Math.min(regionSize,terrain.width-x);
      const height=Math.min(regionSize,terrain.height-y);
      regions.push(Object.freeze({
        id:rx+':'+ry,rx,ry,x,y,width,height,
        centerX:x+width/2,centerY:y+height/2,
        humidity:clamp(.31+hash(rx,ry,seed+200)*.56,.15,.95)
      }));
    }
    function regionAt(x,y){
      if(!Number.isFinite(x)||!Number.isFinite(y)||x<0||y<0||
        x>=terrain.width||y>=terrain.height)throw new RangeError('Точка вне мира');
      return regions[Math.floor(y/regionSize)*columns+Math.floor(x/regionSize)];
    }
    const weatherCache=new Map();
    function weatherFor(region,day){
      const key=region.id+':'+day;
      if(weatherCache.has(key))return weatherCache.get(key);
      const season=seasonAt(day,seasonDays);
      const tempShift=[-1,8,-2,-11][season.index];
      const normal=19-27*region.centerY/terrain.height+
        (hash(region.rx,region.ry,seed+403)-.5)*5;
      const variation=(hash(day,region.rx+region.ry*19,seed+404)-.5)*6;
      const temperature=normal+tempShift+variation;
      const chance=hash(day,region.rx+region.ry*31,seed+405);
      const rain=chance<region.humidity*.65;
      const precipitation=rain?(.2+hash(day,region.rx+region.ry*37,seed+406)*.8):0;
      const wind=2+hash(day,region.rx+region.ry*41,seed+407)*20;
      const direction=hash(Math.floor(day/3),region.rx+region.ry*13,seed+408)*Math.PI*2;
      let event=null;
      if(precipitation>.83&&wind>15)event=temperature<1?'Метель':'Шторм';
      else if(precipitation>.85&&region.humidity>.7)event='Ливень';
      else if(!rain&&wind>19)event='Сильный ветер';
      else if(!rain&&temperature>29&&region.humidity<.4)event='Засуха';
      const result=Object.freeze({day,season,regionId:region.id,
        temperature,precipitation,kind:rain?(temperature<1?'snow':'rain'):'clear',
        wind:{speed:wind,direction},event});
      if(weatherCache.size>240)weatherCache.clear();
      weatherCache.set(key,result);
      return result;
    }
    function weatherAt(x,y,day){
      return weatherFor(regionAt(x,y),day);
    }
    function surfaceAt(x,y,day){
      const region=regionAt(x,y),weather=weatherFor(region,day);
      const h=terrain.heightAt(x+.5,y+.5);
      const slope=terrain.slopeAt(x+.5,y+.5);
      const moisture=clamp(.12+region.humidity*.63+weather.precipitation*.33-
        clamp(h,0,12)*.022,0,1);
      const fertility=clamp(.2+.66*hash(x,y,seed+712)+moisture*.14-
        Math.max(0,slope-.5)*.12,0,1);
      const isWater=h< -1.35;
      const substrate=isWater?'water':h>6||slope>1.65?'rock':
        moisture<.35&&hash(x,y,seed+713)>.3?'sand':'soil';
      const soilType=substrate==='soil'?
        (fertility>.68?'чернозём':fertility>.38?'суглинок':'бедная почва'):null;
      const temperature=weather.temperature-
        (region.centerY-y)*27/terrain.height-
        (h-terrain.heightAt(region.centerX,region.centerY))*.55;
      let snowDepth=0;
      if(temperature<1){
        // Снег суммируется по ограниченному окну прошедших дней, без обновления всей карты.
        for(let offset=0;offset<7;offset++){
          if(day-offset<1)break;
          const old=weatherFor(region,day-offset);
          if(old.temperature<2&&old.kind==='snow')
            snowDepth+=old.precipitation*(1-offset*.1);
        }
        snowDepth=clamp(snowDepth/2,0,1);
      }
      const ice=isWater&&temperature< -2;
      const grass=substrate==='soil'?
        clamp(fertility*(.42+moisture*.7)*(temperature< -7?.18:1),0,1):0;
      const cover=ice?'ice':isWater?'water':snowDepth>.19?'snow':
        substrate==='soil'&&grass>.34?'grass':substrate==='soil'?'bare':substrate;
      return {x,y,height:h,slope,regionId:region.id,substrate,
        soil:{type:soilType,fertility,moisture},vegetation:{grass},
        snowDepth,ice,temperature,cover,weather};
    }
    return Object.freeze({width:terrain.width,height:terrain.height,seed,
      regionSize,seasonDays,regions:Object.freeze(regions),
      regionAt,weatherAt,surfaceAt,seasonAt:day=>seasonAt(day,seasonDays)});
  }
  return {create,seasonAt,REGION_SIZE,SEASON_DAYS,SEASONS};
});
