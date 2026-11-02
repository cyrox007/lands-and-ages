'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path');
const {Game}=require('../engine.js'),M=require('../mill-pack.js');
function run(g,seconds){for(let k=0;k<Math.ceil(seconds*10);k++)g.step(.1);}
test('пакет содержит независимые слои и стадии',()=>{
  assert.equal(M.id,'mill');
  assert.equal(Object.keys(M.layers).length,17);
  assert.deepEqual(M.states.destruction,['fresh_ruins','old_ruins','overgrown_ruins']);
  for(const name of Object.values(M.layers)){
    const svg=fs.readFileSync(path.join(__dirname,'../',M.path,name),'utf8');
    assert.match(svg,/^<svg /);
    assert.match(svg,/<\/svg>$/);
  }
  for(const phase of M.states.construction)
    assert.ok(M.constructionLayers(phase).length>0,phase);
  assert.equal(M.stateLayers('fresh_ruins').includes('fresh'),true);
  assert.equal(M.stateLayers('old_ruins').includes('old'),true);
});
test('мельник работает только при доступном зерне, а мука хранится отдельно',()=>{
  const g=new Game(),mill=g.buildings.find(b=>b.type==='mill');
  const i=g.millInterior(mill);
  assert.equal(i.input.grain,0);assert.equal(i.output.flour,0);
  assert.equal(i.worker,true);assert.equal(i.working,false);
  mill.goods.grain=4;
  assert.equal(g.millInterior(mill).working,true);
  run(g,6.2);
  assert.equal(mill.goods.grain,2);
  assert.equal(mill.goods.flour,1);
  assert.equal(g.millInterior(mill).output.flour,1);
});
test('повреждения, полное уничтожение и старение руин сохраняют занятую клетку',()=>{
  const g=new Game(),mill=g.buildings.find(b=>b.type==='mill');
  const {id,x,y}=mill;
  assert.equal(g.damageMill(id,40).phase,'damaged');
  assert.equal(g.millState(mill).integrity,60);
  assert.equal(g.damageMill(id,75).phase,'fresh_ruins');
  assert.equal(g.buildingAt(x,y).id,id);
  assert.equal(g.readyToProduce(mill),false);
  assert.equal(g.canBuild('road',x,y).ok,false);
  assert.equal(g.clearMillRuins(id).ok,false);
  run(g,100.1);
  assert.equal(g.millState(mill).phase,'old_ruins');
  run(g,650);
  assert.equal(g.millState(mill).phase,'overgrown_ruins');
  assert.equal(g.buildingAt(x,y).id,id);
});
test('реставрация сохраняет идентификатор здания, требует ресурсов и времени',()=>{
  const g=new Game(),mill=g.buildings.find(b=>b.type==='mill');
  g.damageMill(mill.id,100);
  const noStone=g.restoreMill(mill.id);
  assert.equal(noStone.ok,false);
  g.warehouse().goods.stone=3;
  const coins=g.coins,boards=g.warehouse().goods.boards;
  assert.equal(g.restoreMill(mill.id).ok,true);
  assert.equal(g.coins,coins-24);
  assert.equal(g.warehouse().goods.boards,boards-3);
  assert.equal(g.millState(mill).phase,'restoring');
  run(g,9);
  assert.equal(g.millState(mill).phase,'restoring');
  run(g,9);
  assert.equal(g.millState(mill).phase,'operational');
  assert.equal(g.buildingAt(mill.x,mill.y).id,mill.id);
});
test('старые сохранения получают пакет, новые сохраняют этапы разрушения',()=>{
  const g=new Game(),b=g.buildings.find(b=>b.type==='mill');
  g.damageMill(b.id,100);
  const saved=g.save(),copy=Game.restore(saved);
  assert.ok(copy);assert.equal(copy.save(),saved);
  const old=JSON.parse(saved);
  delete old.buildings.find(b=>b.type==='mill').mill;
  const migrated=Game.restore(JSON.stringify(old));
  assert.ok(migrated);
  assert.equal(migrated.millState(migrated.buildings.find(b=>b.type==='mill')).phase,'operational');
});
test('расчистка старых руин освобождает участок, свежие не исчезают',()=>{
  const g=new Game(),b=g.buildings.find(b=>b.type==='mill');
  g.damageMill(b.id,100);
  assert.equal(g.clearMillRuins(b.id).ok,false);
  run(g,101);
  assert.equal(g.clearMillRuins(b.id).ok,true);
  assert.equal(g.buildingAt(b.x,b.y),null);
});
