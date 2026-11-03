'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const Wood=require('../woodcutting.js');
const {Game}=require('../engine.js');

test('восемь видимых фаз топора имеют разное положение кисти и лезвия',()=>{
  assert.equal(Wood.FRAMES,8);
  assert.equal(Wood.FPS,7);
  assert.equal(Wood.frameAt(0),0);
  assert.equal(Wood.frameAt(4/7),4);
  assert.equal(Wood.frameAt(8/7),0);
  assert.equal(Wood.frameAt(-5),0);
  assert.equal(Wood.frameAt(NaN),0);
  const poses=Array.from({length:8},(_,f)=>Wood.poseAt(f));
  assert.equal(new Set(poses.map(p=>p.head.join(','))).size,8);
  assert.equal(new Set(poses.map(p=>p.hand.join(','))).size,8);
  assert.deepEqual(Wood.poseAt(8),Wood.poseAt(0));
});

test('удар создаёт стружку и короткую отдачу дерева',()=>{
  assert.equal(Wood.impact(3),false);
  assert.equal(Wood.impact(4),true);
  assert.equal(Wood.impact(5),true);
  assert.equal(Wood.impact(6),false);
  assert.notEqual(Wood.sway(4/7),0);
  assert.notEqual(Wood.sway(5/7),0);
  assert.equal(Wood.sway(1/7),0);
});

test('анимированный топор и рука рисуются поверх рабочего для всех направлений',()=>{
  const commands=[];
  const ctx={};
  for(const method of ['save','restore','translate','scale','beginPath','moveTo',
    'lineTo','quadraticCurveTo','stroke','arc','fill','rotate','closePath']){
    ctx[method]=(...args)=>commands.push([method,...args]);
  }
  for(const dir of ['se','sw','ne','nw']){
    for(let frame=0;frame<8;frame++){
      const before=commands.length;
      assert.equal(Wood.draw(ctx,120,180,44,frame,dir),true);
      const drawn=commands.slice(before);
      assert.ok(drawn.some(c=>c[0]==='quadraticCurveTo'));
      assert.ok(drawn.some(c=>c[0]==='arc'));
      assert.ok(drawn.filter(c=>c[0]==='stroke').length>=5);
      assert.equal(drawn.at(-1)[0],'restore');
    }
  }
  assert.equal(Wood.draw(ctx,120,180,0,0),false);
});

test('настоящий лесоруб получает рабочую фазу с длительным рублением',()=>{
  const game=new Game(1729,'settlement');
  const logger=game.addBuilding('logger',12,9);
  assert.equal(game.assignWorkers(logger.id,1).ok,true);
  let agent;
  for(let i=0;i<260;i++){
    game.step(.1);
    agent=game.workAgents.find(a=>a.buildingId===logger.id);
    if(agent?.phase==='work'&&agent.progress>.2)break;
  }
  assert.equal(agent?.phase,'work');
  const before=game.tiles.reduce((n,t)=>n+(t.wood||0),0);
  assert.equal(game.workAgents.filter(a=>a.phase==='work').length,1);
  for(let i=0;i<60;i++)game.step(.1);
  assert.equal(agent.phase,'work','рубка продолжается дольше одной анимационной петли');
  assert.equal(game.tiles.reduce((n,t)=>n+(t.wood||0),0),before);
  assert.ok(Wood.frameAt(agent.progress)>=0);
});
