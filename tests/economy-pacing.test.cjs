'use strict';

const test=require('node:test');
const assert=require('node:assert/strict');
const {Game,ECONOMY_PACE,productionTime}=require('../engine.js');

function run(game,seconds){
  for(let i=0;i<Math.ceil(seconds*10);i++)game.step(.1);
}

test('в новом поселении добыча и изготовление больше не мгновенные',()=>{
  assert.deepEqual(ECONOMY_PACE.gathering,{logger:12,quarry:14,farm:10});
  assert.deepEqual(ECONOMY_PACE.fields.growing,{wheat:30,barley:26,vegetables:34});
  for(const [type,time] of Object.entries(ECONOMY_PACE.production)){
    assert.equal(productionTime(type,'settlement'),time,type);
    assert.ok(productionTime(type,'legacy')<time,type);
  }
});

test('лесоруб не может срубить дерево раньше конца своей работы',()=>{
  const g=new Game(1729,'settlement');
  const logger=g.addBuilding('logger',12,9);
  assert.equal(g.assignWorkers(logger.id,1).ok,true);
  let agent;
  for(let i=0;i<200;i++){
    g.step(.1);
    agent=g.workAgents.find(a=>a.buildingId===logger.id);
    if(agent?.phase==='work')break;
  }
  assert.equal(agent?.phase,'work','лесоруб дошёл до дерева');
  const before=g.tiles.reduce((sum,t)=>sum+(t.wood||0),0);
  run(g,11.2);
  assert.equal(agent.phase,'work');
  assert.equal(g.tiles.reduce((sum,t)=>sum+(t.wood||0),0),before,
    'дерево не убывает до завершения рубки');
  run(g,1.1);
  assert.equal(agent.phase,'return');
  assert.ok(g.tiles.reduce((sum,t)=>sum+(t.wood||0),0)<before,
    'брёвна появляются только после законченной работы');
});

test('заводской цикл не ускоряется вслед за кадрами анимации',()=>{
  const g=new Game(1729,'settlement');
  const mill=g.addBuilding('sawmill',14,9,{logs:8});
  assert.equal(g.assignWorkers(mill.id,1).ok,true);
  assert.equal(g.readyToProduce(mill),true);
  run(g,14);
  assert.equal(mill.goods.boards,0);
  run(g,2);
  assert.ok(mill.goods.boards>=1,'готовые доски появились после производственного цикла');
  assert.ok(Math.abs(g.clock-16)<.001,
    'время учитывается с допуском накопления float');
});

test('поле не созревает моментально после подготовки',()=>{
  const g=new Game(1729,'settlement');
  const farm=g.addBuilding('farm',13,9);
  assert.equal(g.assignWorkers(farm.id,1).ok,true);
  assert.equal(g.placeField(13,8,'wheat').ok,true);
  run(g,7.1);
  assert.equal(g.fields[0].stage,'clearing');
  run(g,1);
  assert.equal(g.fields[0].stage,'sown');
  run(g,6.1);
  assert.equal(g.fields[0].stage,'sown');
  run(g,1);
  assert.equal(g.fields[0].stage,'growing');
  run(g,27);
  assert.equal(g.fields[0].stage,'growing');
});

test('сохранение во время добычи не сбрасывает время и перенос ресурсов',()=>{
  const g=new Game(1729,'settlement');
  const logger=g.addBuilding('logger',12,9);
  assert.equal(g.assignWorkers(logger.id,1).ok,true);
  run(g,8);
  const restored=Game.restore(g.save());
  assert.ok(restored);
  assert.equal(restored.save(),g.save());
  run(g,20);
  run(restored,20);
  assert.equal(restored.save(),g.save());
});
