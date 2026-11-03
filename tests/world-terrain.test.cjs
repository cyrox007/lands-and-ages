'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const Terrain=require('../world-terrain.js');
const Relief=require('../world-relief-preview.js');
const {Game}=require('../engine.js');

test('высотное поле создаётся из общих вершин по seed',()=>{
  const m=Terrain.create(26,18,1729),same=Terrain.create(26,18,1729);
  const another=Terrain.create(26,18,1730);
  assert.equal(m.vertices.length,27*19);
  assert.deepEqual(m.vertices,same.vertices);
  assert.notDeepEqual(m.vertices,another.vertices);
  assert.equal(m.gameplayConnected,false,'физика текущей экономики ещё не заменена');
  assert.ok(m.minimum<0&&m.maximum>6);
  assert.throws(()=>m.vertexAt(-1,0),RangeError);
  assert.throws(()=>m.heightAt(26.1,3),RangeError);
});

test('рельеф содержит равнины, низины, холмы, овраги, плоскогорье и горы',()=>{
  const m=Terrain.create(26,18,1729),stats=Relief.summary(m);
  for(const region of ['plain','lowland','hills','ravine','plateau','mountains'])
    assert.ok(stats.regions[region]>3,region);
  const points=Object.fromEntries(m.regions.map(r=>[r.id,m.heightAt(r.x,r.y)]));
  assert.ok(points.lowland<points.plain);
  assert.ok(points.ravine<points.plain);
  assert.ok(points.hills>points.plain+1);
  assert.ok(points.plateau>points.hills+2);
  assert.ok(points.mountains>points.plateau);
});

test('поверхность непрерывна на границах всех соседних клеток',()=>{
  const m=Terrain.create(26,18,1729);
  for(let y=0;y<=18;y++)for(let x=0;x<=26;x++)
    assert.ok(Math.abs(m.heightAt(x,y)-m.vertexAt(x,y))<1e-5);
  for(let y=1;y<18;y++)for(let x=1;x<26;x++){
    const alongY=m.heightAt(x-.0000001,y+.35);
    const oppositeY=m.heightAt(x+.0000001,y+.35);
    const alongX=m.heightAt(x+.35,y-.0000001);
    const oppositeX=m.heightAt(x+.35,y+.0000001);
    assert.ok(Math.abs(alongY-oppositeY)<.0001);
    assert.ok(Math.abs(alongX-oppositeX)<.0001);
  }
});

test('нормаль, уклон и проекция учитывают физическую высоту Z',()=>{
  const m=Terrain.create(26,18,1729);
  for(const {x,y} of m.regions){
    const n=m.normalAt(x,y),len=Math.hypot(n.x,n.y,n.z);
    assert.ok(Math.abs(len-1)<1e-10);
    assert.ok(n.z>0);
    assert.ok(m.slopeAt(x,y)>=0);
    const z=m.heightAt(x,y);
    const projection=Terrain.project(x,y,z,{originX:415,originY:200});
    const back=Terrain.unproject(projection.x,projection.y,z,
      {originX:415,originY:200});
    assert.ok(Math.abs(back.x-x)<1e-9);
    assert.ok(Math.abs(back.y-y)<1e-9);
    assert.equal(back.z,z);
    const flat=Terrain.project(x,y,0,{originX:415,originY:200});
    assert.ok(Math.abs(projection.y-flat.y+z*18)<1e-8);
  }
});

test('каждый треугольник можно выбрать с экрана по барицентрическим координатам',()=>{
  const m=Terrain.create(26,18,1729),mesh=Relief.geometry(m);
  const point=Terrain.project(8.4,6.3,m.heightAt(8.4,6.3),mesh.options);
  const found=Relief.pick(m,mesh,point.x,point.y,
    {x:mesh.originX,y:mesh.originY},1);
  // origin относится к проекции мировой точки (0,0), а не к началу canvas.
  assert.ok(found);
  assert.ok(Math.abs(found.x-8.4)<.35);
  assert.ok(Math.abs(found.y-6.3)<.35);
  assert.ok(Math.abs(found.z-m.heightAt(found.x,found.y))<1e-6);
});

test('проектирование рельефа не меняет игровую партию',()=>{
  const game=new Game(1729,'settlement'),before=game.save();
  const model=Terrain.create(game.w,game.h,game.seed);
  assert.ok(model.heightAt(13.5,9.5)<=model.maximum);
  assert.equal(game.save(),before);
  assert.equal(Game.restore(before).save(),before);
});
