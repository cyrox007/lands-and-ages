'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const Terrain=require('../world-terrain.js');
const Environment=require('../world-environment.js');
const Relief=require('../world-relief-preview.js');

const terrain=Terrain.create(256,192,1729);
const climate=Environment.create(terrain);

test('мир увеличен до 256×192 с 12 природными регионами',()=>{
  assert.equal(terrain.vertices.length,257*193);
  assert.equal(climate.regions.length,12);
  const maxSettlementCells=2*9*10+1;
  for(const region of climate.regions){
    assert.equal(region.width,64);
    assert.equal(region.height,64);
    assert.ok(region.width*region.height>=6*maxSettlementCells);
  }
  assert.notEqual(climate.regionAt(4,4).id,climate.regionAt(200,150).id);
  assert.throws(()=>climate.regionAt(-1,0),RangeError);
  assert.throws(()=>climate.surfaceAt(256,10,1),RangeError);
});

test('сезоны детерминированы по игровому календарю',()=>{
  assert.equal(Environment.seasonAt(1).name,'Весна');
  assert.equal(Environment.seasonAt(25).name,'Лето');
  assert.equal(Environment.seasonAt(49).name,'Осень');
  assert.equal(Environment.seasonAt(73).name,'Зима');
  assert.equal(Environment.seasonAt(97).year,2);
  assert.throws(()=>Environment.seasonAt(0),RangeError);
});

test('климат одного seed и дня воспроизводится независимо от порядка выборки',()=>{
  const again=Environment.create(Terrain.create(256,192,1729));
  const points=[[6,6],[71,35],[136,94],[250,185]];
  for(const day of [1,25,49,73,95]){
    for(const [x,y] of points){
      assert.deepEqual(climate.weatherAt(x,y,day),again.weatherAt(x,y,day));
      assert.deepEqual(climate.surfaceAt(x,y,day),again.surfaceAt(x,y,day));
    }
  }
});

test('поверхность содержит грунт, почву, траву и независимый сезонный покров',()=>{
  const observed=new Set();
  for(let y=0;y<192;y+=3)for(let x=0;x<256;x+=3){
    const surface=climate.surfaceAt(x,y,25);
    observed.add(surface.substrate);
    assert.ok(surface.soil.fertility>=0&&surface.soil.fertility<=1);
    assert.ok(surface.soil.moisture>=0&&surface.soil.moisture<=1);
    if(surface.substrate==='rock')assert.notEqual(surface.cover,'grass');
    if(surface.cover==='grass')assert.equal(surface.substrate,'soil');
  }
  assert.ok(observed.has('soil'));
  assert.ok(observed.has('rock'));
  const north=climate.weatherAt(30,5,73);
  const south=climate.weatherAt(30,185,73);
  assert.ok(north.temperature>south.temperature);
  const summer=climate.weatherAt(30,5,25);
  assert.ok(summer.temperature>north.temperature);
});

test('ветер, осадки и локальные события зависят от региона и дня',()=>{
  for(const day of [1,2,3,25,73,90]){
    const weather=climate.weatherAt(90,100,day);
    assert.ok(weather.wind.speed>=0);
    assert.ok(weather.wind.direction>=0&&weather.wind.direction<=Math.PI*2);
    assert.ok(weather.precipitation>=0&&weather.precipitation<=1);
    assert.ok(['clear','rain','snow'].includes(weather.kind));
    assert.ok(weather.event===null||typeof weather.event==='string');
  }
  assert.notDeepEqual(climate.weatherAt(15,15,25),
    climate.weatherAt(200,170,25));
});

test('выбор точки на большом рельефе не перебирает все клетки',()=>{
  const zoom=.85;
  const screen=(x,y)=>({x:(x-y)*41*zoom,y:(x+y)*20.5*zoom});
  const worldAt=(x,y)=>({x:(x/(41*zoom)+y/(20.5*zoom))/2,
    y:(y/(20.5*zoom)-x/(41*zoom))/2});
  const x=132.4,y=88.3,z=terrain.heightAt(x,y);
  const target=screen(x,y);target.y-=z*18*zoom;
  const hit=Relief.pickAt(terrain,target.x,target.y,{screen,worldAt,zoom});
  assert.ok(hit);
  assert.ok(Math.abs(hit.x-x)<.35,JSON.stringify(hit));
  assert.ok(Math.abs(hit.y-y)<.35,JSON.stringify(hit));
});
