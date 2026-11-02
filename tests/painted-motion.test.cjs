'use strict';
const test=require('node:test');
const assert=require('node:assert/strict');
const Motion=require('../painted-motion.js');

function canvasCalls(){
  const calls=[];
  const ctx={};
  for(const name of ['save','restore','translate','scale','rotate',
    'beginPath','rect','clip','drawImage']){
    ctx[name]=(...args)=>calls.push([name,...args]);
  }
  return {ctx,calls};
}

test('подробные персонажи используют утверждённые размеры и состояния',()=>{
  assert.equal(Motion.WIDTH,96);
  assert.equal(Motion.HEIGHT,144);
  assert.equal(Motion.FRAMES,8);
  assert.deepEqual(Motion.DIRECTIONS,['se','sw','ne','nw']);
  assert.deepEqual(Motion.STATES,['idle','walk','work','carry']);
  assert.equal(Motion.characterRole('porter'),'villager-man-1');
  assert.equal(Motion.characterRole('builder'),'builder');
});

test('ходьба действительно изменяет позу, опора остаётся на месте',()=>{
  const first=Motion.pose('walk',0,'se');
  const second=Motion.pose('walk',2,'se');
  assert.notDeepEqual(first,second);
  assert.notEqual(second.legA,first.legA);
  assert.equal(Motion.pose('walk',10,'se').frame,2);
  assert.equal(Motion.pose('work',3,'sw').mirror,true);
  assert.equal(Motion.pose('carry',3,'nw').mirror,true);
  assert.throws(()=>Motion.pose('fly',0,'se'),/Неизвестное/);
  assert.throws(()=>Motion.pose('walk',0,'up'),/Неизвестное/);
});

test('отрисовка покоя и действий использует художественный атлас',()=>{
  const image={naturalWidth:1056,naturalHeight:144};
  for(const action of Motion.STATES){
    const {ctx,calls}=canvasCalls();
    assert.equal(Motion.draw(ctx,image,7,action,2,'sw',250,340,44,3),true);
    const draws=calls.filter(c=>c[0]==='drawImage');
    assert.equal(draws.length,action==='idle'?1:3);
    assert.deepEqual(draws[0].slice(1,6),[image,7*96,0,96,144]);
    const translation=calls.find(c=>c[0]==='translate');
    assert.deepEqual(translation,['translate',250,340]);
    assert.ok(calls.some(c=>c[0]==='scale'&&c[1]<0));
    assert.equal(calls.at(-1)[0],'restore');
  }
  const {ctx,calls}=canvasCalls();
  assert.equal(Motion.draw(ctx,null,1,'walk',0,'se',0,0,44),false);
  assert.equal(Motion.draw(ctx,{naturalWidth:100},-1,'idle',0,'se',0,0,44),false);
  assert.equal(calls.length,0);
});
