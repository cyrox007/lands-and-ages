'use strict';
const test=require('node:test'),assert=require('node:assert/strict');
const fs=require('node:fs'),path=require('node:path');
const {Game}=require('../engine.js'),M=require('../mill-pack.js');
function run(g,seconds){for(let k=0;k<Math.ceil(seconds*10);k++)g.step(.1);}
test('игра загружает утверждённые растровые атласы вместо SVG',()=>{
  assert.equal(M.id,'mill');
  assert.equal(M.version,3);
  assert.equal(Object.keys(M.atlases).length,3);
  assert.equal(Object.keys(M.sprites).length,22);
  assert.deepEqual(M.states.destruction,['fresh_ruins','old_ruins','overgrown_ruins']);
  for(const file of Object.values(M.atlases)){
    const data=fs.readFileSync(path.join(__dirname,'../',M.path,file));
    assert.equal(data.subarray(0,4).toString('ascii'),'RIFF');
    assert.equal(data.subarray(8,12).toString('ascii'),'WEBP');
    assert.ok(data.length>30000,'спрайт-лист должен содержать настоящую детализацию');
  }
  for(const file of [M.detailed.body,M.detailed.rotor]){
    const bytes=fs.readFileSync(path.join(__dirname,'../',M.path,file));
    assert.equal(bytes.subarray(0,4).toString('ascii'),'RIFF');
    assert.ok(bytes.length>25000,'детализированный спрайт не должен быть пустым');
  }
  const art=M.layout(82,41);
  assert.equal(art.width,82*2.28);
  assert.ok(Math.abs(art.hubX+art.width*.125)<1e-7);
  assert.ok(art.rotorWidth<art.width*.55);
  assert.ok(art.hubY<0);
  assert.equal(M.detailed.bodySize.w,360);
  assert.equal(M.detailed.hub.y,148);
  for(const name of ['body_assembled','rotor','grain_sacks','flour_sacks','millstone',
    'working_miller','survey','frame','walls','almost',
    'damaged','fresh_ruins','old_ruins','overgrown_ruins','restoring'])
    assert.ok(M.sprites[name],name);
  for(const phase of M.states.construction)
    assert.ok(M.sprites[M.constructionSprite(phase)],phase);
  assert.equal(M.stateSprite('fresh_ruins'),'fresh_ruins');
  assert.equal(M.stateSprite('old_ruins'),'old_ruins');
  assert.notEqual(M.sprites.body_assembled.atlas,M.sprites.old_ruins.atlas);
});
test('мельник работает только при доступном зерне, а мука хранится отдельно',()=>{
  const g=new Game(),mill=g.buildings.find(b=>b.type==='mill');
  const i=g.millInterior(mill);
  assert.equal(i.input.grain,0);assert.equal(i.output.flour,0);
  assert.equal(i.worker,true);assert.equal(i.working,false);
  mill.goods.grain=4;
  assert.equal(g.millInterior(mill).working,true);
  g.produce(mill,6.2);
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
